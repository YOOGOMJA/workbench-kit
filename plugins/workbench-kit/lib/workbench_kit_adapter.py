"""Read-only adapter for the public workbench kernel contracts."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
from collections.abc import Sequence
from typing import Any

from workbench_kit_json import (
    DuplicateJsonMember,
    InvalidJsonConstant,
    strict_json_loads,
)


REQUIRED_CAPABILITIES = {
    "workspace.schema/v1",
    "workspace.doctor/v1",
    "workspace.legacy-inventory/v1",
}
BOOTSTRAP_CAPABILITY = "workspace.legacy-inventory-bootstrap/v1"
ENGINE_MANIFEST_CAPABILITY = "engine.manifest/v1"
LEGACY_INVENTORY_CONTRACT = "workbench-legacy-inventory/v1"
BOOTSTRAP_APPROVAL_CONTRACT = "workbench-bootstrap-authority-approval/v1"
ENGINE_MANIFEST_CONTRACT = "workbench-plugin-manifest/v1"
GIT_OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
HOME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
INVENTORY_FIELDS = (
    "contract_version", "source_revision", "authority", "home_set", "homes",
    "active_claims", "origin_replacements", "complete", "blockers",
)
AUTHORITY_FIELDS = (
    "authority_identity", "default_ref", "default_revision", "descriptor_digest",
    "bootstrap_revision",
)
HOME_SET_FIELDS = ("contract_version", "digest", "source_revision")
HOME_FIELDS = ("home", "origin_url", "membership", "pagination", "claims")
PAGINATION_FIELDS = ("complete", "pages_fetched", "end_cursor", "failure")
FAILURE_FIELDS = ("code", "ref", "cursor")
CLAIM_FIELDS = (
    "claim_id", "task_claim_id", "task_contract", "issue", "home", "parent",
    "branch", "lifecycle_digest", "lifecycle_state", "classification",
    "submission", "source_revision", "pr_head_revision", "ancestry_complete", "repos",
)
SUBMISSION_FIELDS = ("pull_request", "head_revision", "current")
REPO_FIELDS = ("owner", "branch", "role")
ACTIVE_CLAIM_FIELDS = (
    "source", "claim_id", "operation_id", "task_claim_id", "owner", "branch",
    "context_policy_set_digest", "source_revision", "pr_head_revision", "lifecycle_digest",
)
REPLACEMENT_FIELDS = (
    "home", "previous_origin_url", "current_origin_url", "status",
)
BLOCKER_FIELDS = ("code", "ref")
DOCTOR_FIELDS = ("contract_version", "ready", "writer_coordination")
COORDINATION_FIELDS = (
    "authority_identity", "origin_url", "default_ref", "default_ref_revision",
    "default_ref_protected", "descriptor_digest", "ref", "revision", "readable",
    "legacy_inventory_readable", "push_permission", "permission_source", "push_ready",
    "blocker",
)
COORDINATION_REF = "refs/heads/workbench-coordination/writer-claims"
ENGINE_MANIFEST_FIELDS = (
    "contract_version", "plugin", "source", "included_paths", "excluded_paths", "nodes",
    "digest",
)
PLUGIN_FIELDS = ("name", "version")
SOURCE_FIELDS = ("ref", "revision")
EXCLUSION_FIELDS = ("path", "match")
MANIFEST_NODE_FIELDS = ("path", "node_type", "mode", "digest", "link_target")
ENGINE_SOURCE_REF = "https://github.com/YOOGOMJA/workbench-kit#plugins/workbench"
ENGINE_EXCLUSIONS = [
    {"path": ".DS_Store", "match": "exact"},
    {"path": ".git/", "match": "prefix"},
    {"path": "lib/__pycache__/", "match": "prefix"},
]


class AdapterError(Exception):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


def require_object(value: Any, ref: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AdapterError("public-contract-invalid", ref)
    return value


def require_array(value: Any, ref: str) -> list[Any]:
    if not isinstance(value, list):
        raise AdapterError("public-contract-invalid", ref)
    return value


def inventory_error(ref: str) -> None:
    raise AdapterError("legacy-inventory-unavailable", ref)


def inventory_object(value: Any, fields: tuple[str, ...], ref: str) -> dict[str, Any]:
    if not isinstance(value, dict) or tuple(value) != fields:
        inventory_error(ref)
    return value


def inventory_array(value: Any, ref: str) -> list[Any]:
    if not isinstance(value, list):
        inventory_error(ref)
    return value


def inventory_text(value: Any, ref: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        inventory_error(ref)
    return value


def inventory_home(value: Any, ref: str) -> str:
    result = inventory_text(value, ref)
    if HOME.fullmatch(result) is None or result.isdigit():
        inventory_error(ref)
    return result


def inventory_oid(value: Any, ref: str, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or GIT_OID.fullmatch(value) is None:
        inventory_error(ref)
    return value


def inventory_digest(value: Any, ref: str) -> str:
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        inventory_error(ref)
    return value


def positive_integer(value: Any, ref: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        inventory_error(ref)
    return value


def pseudo_claim_id(task_claim_id: str, owner: str, branch: str) -> str:
    manifest = (
        "workbench-legacy-writer-identity/v1\n"
        f"task_claim_id\t{task_claim_id}\nowner\t{owner}\nbranch\t{branch}\n"
    )
    return "legacy-v1-" + hashlib.sha256(manifest.encode("utf-8")).hexdigest()


def resolve_workbench_binary() -> str:
    requested = os.environ.get("WORKBENCH_KIT_WORKBENCH_BIN", "workbench")
    if os.sep in requested:
        path = pathlib.Path(requested).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path.resolve())
        raise AdapterError("public-adapter-unavailable", requested)
    resolved = shutil.which(requested)
    if resolved is None:
        raise AdapterError("public-adapter-unavailable", requested)
    return resolved


def run_public_json(
    binary: str,
    argv: Sequence[str],
    workspace: pathlib.Path,
    allowed_exits: set[int],
) -> tuple[dict[str, Any], int]:
    ref = "workbench " + " ".join(argv)
    try:
        completed = subprocess.run(
            [binary, *argv],
            cwd=workspace,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise AdapterError("public-adapter-unavailable", ref) from error
    if completed.stderr:
        raise AdapterError("public-adapter-stderr", ref)
    if completed.returncode not in allowed_exits:
        raise AdapterError("public-adapter-exit", ref)
    try:
        stdout = completed.stdout.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AdapterError("public-json-invalid", ref) from error
    if not stdout.endswith("\n"):
        raise AdapterError("public-json-invalid", ref)
    try:
        value = strict_json_loads(stdout)
    except (
        DuplicateJsonMember,
        InvalidJsonConstant,
        json.JSONDecodeError,
    ) as error:
        raise AdapterError("public-json-invalid", ref) from error
    return require_object(value, ref), completed.returncode


def validate_contract(
    document: dict[str, Any],
    workspace: pathlib.Path,
    require_bootstrap: bool = False,
    require_engine_manifest: bool = False,
) -> str:
    ref = "workbench contract show"
    if document.get("contract_version") != "workbench-contract/v1":
        raise AdapterError("public-contract-invalid", ref)
    engine = require_object(document.get("engine"), f"{ref}.engine")
    if engine.get("name") != "workbench" or not isinstance(engine.get("version"), str):
        raise AdapterError("public-engine-mismatch", ref)
    if SEMVER.fullmatch(engine["version"]) is None:
        raise AdapterError("public-engine-mismatch", ref)
    workspace_contract = require_object(document.get("workspace"), f"{ref}.workspace")
    root = workspace_contract.get("root")
    if not isinstance(root, str) or pathlib.Path(root).resolve() != workspace:
        raise AdapterError("caller-root-mismatch", str(root))
    schema = workspace_contract.get("schema")
    if schema not in ("workbench/v1", "workbench/v2"):
        raise AdapterError("public-contract-invalid", f"{ref}.workspace.schema")
    supported = require_object(document.get("supported"), f"{ref}.supported")
    inventory_contracts = require_array(
        supported.get("legacy_inventory_contracts"),
        f"{ref}.supported.legacy_inventory_contracts",
    )
    if LEGACY_INVENTORY_CONTRACT not in inventory_contracts:
        raise AdapterError("public-contract-missing", LEGACY_INVENTORY_CONTRACT)
    capabilities = require_array(document.get("capabilities"), f"{ref}.capabilities")
    if not all(isinstance(item, str) for item in capabilities):
        raise AdapterError("public-contract-invalid", f"{ref}.capabilities")
    missing = sorted(REQUIRED_CAPABILITIES - set(capabilities))
    if missing:
        raise AdapterError("public-capability-missing", missing[0])
    if schema == "workbench/v1" or require_bootstrap:
        if "bootstrap_authority_approval_contracts" not in supported:
            raise AdapterError("public-contract-missing", BOOTSTRAP_APPROVAL_CONTRACT)
        approval_contracts = require_array(
            supported.get("bootstrap_authority_approval_contracts"),
            f"{ref}.supported.bootstrap_authority_approval_contracts",
        )
        if BOOTSTRAP_APPROVAL_CONTRACT not in approval_contracts:
            raise AdapterError("public-contract-missing", BOOTSTRAP_APPROVAL_CONTRACT)
        if BOOTSTRAP_CAPABILITY not in capabilities:
            raise AdapterError("public-capability-missing", BOOTSTRAP_CAPABILITY)
    if require_engine_manifest:
        if "engine_manifest_contracts" not in supported:
            raise AdapterError("public-contract-missing", ENGINE_MANIFEST_CONTRACT)
        manifest_contracts = require_array(
            supported["engine_manifest_contracts"],
            f"{ref}.supported.engine_manifest_contracts",
        )
        if ENGINE_MANIFEST_CONTRACT not in manifest_contracts:
            raise AdapterError("public-contract-missing", ENGINE_MANIFEST_CONTRACT)
        if ENGINE_MANIFEST_CAPABILITY not in capabilities:
            raise AdapterError("public-capability-missing", ENGINE_MANIFEST_CAPABILITY)
    return schema


def validate_doctor(document: dict[str, Any], status: int) -> None:
    ref = "workbench doctor"
    if tuple(document) != DOCTOR_FIELDS or document.get("contract_version") != "workbench-doctor/v1":
        raise AdapterError("public-contract-invalid", ref)
    ready = document.get("ready")
    if not isinstance(ready, bool) or (ready and status != 0) or (not ready and status != 1):
        raise AdapterError("public-contract-invalid", ref)
    coordination = require_object(
        document.get("writer_coordination"), f"{ref}.writer_coordination"
    )
    if tuple(coordination) != COORDINATION_FIELDS:
        raise AdapterError("public-contract-invalid", f"{ref}.writer_coordination")

    def optional_text(field: str) -> str | None:
        value = coordination[field]
        if value is not None and (
            not isinstance(value, str)
            or not value
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
        ):
            raise AdapterError("public-contract-invalid", f"{ref}.{field}")
        return value

    for field in ("authority_identity", "origin_url", "default_ref", "permission_source"):
        optional_text(field)
    for field in ("default_ref_revision", "revision"):
        value = optional_text(field)
        if value is not None and GIT_OID.fullmatch(value) is None:
            raise AdapterError("public-contract-invalid", f"{ref}.{field}")
    descriptor_digest = optional_text("descriptor_digest")
    if descriptor_digest is not None and SHA256.fullmatch(descriptor_digest) is None:
        raise AdapterError("public-contract-invalid", f"{ref}.descriptor_digest")
    for field in (
        "default_ref_protected", "readable", "legacy_inventory_readable", "push_ready"
    ):
        if not isinstance(coordination[field], bool):
            raise AdapterError("public-contract-invalid", f"{ref}.{field}")
    if coordination["ref"] != COORDINATION_REF:
        raise AdapterError("public-contract-invalid", f"{ref}.ref")
    if coordination["push_permission"] not in ("allowed", "denied", "unknown"):
        raise AdapterError("public-contract-invalid", f"{ref}.push_permission")

    blocker = coordination["blocker"]
    if blocker is not None:
        if not isinstance(blocker, dict) or tuple(blocker) != BLOCKER_FIELDS:
            raise AdapterError("public-contract-invalid", f"{ref}.blocker")
        if blocker.get("code") != "writer-lock-unavailable" or blocker.get("ref") != COORDINATION_REF:
            raise AdapterError("public-contract-invalid", f"{ref}.blocker")
    computed_ready = all(
        (
            coordination["authority_identity"] is not None,
            coordination["origin_url"] is not None,
            coordination["default_ref"] is not None,
            coordination["default_ref_revision"] is not None,
            coordination["default_ref_protected"],
            coordination["descriptor_digest"] is not None,
            coordination["readable"],
            coordination["legacy_inventory_readable"],
            coordination["push_permission"] == "allowed",
            coordination["permission_source"] is not None,
            coordination["push_ready"],
        )
    )
    if ready != computed_ready or (ready and blocker is not None) or (not ready and blocker is None):
        raise AdapterError("public-contract-invalid", ref)


def validate_inventory(
    document: dict[str, Any], status: int, command: str
) -> list[dict[str, Any]]:
    ref = f"workbench legacy-inventory {command}"
    inventory_object(document, INVENTORY_FIELDS, ref)
    if document["contract_version"] != LEGACY_INVENTORY_CONTRACT:
        inventory_error(ref)
    source_revision = inventory_oid(document["source_revision"], f"{ref}.source_revision")

    authority = inventory_object(document["authority"], AUTHORITY_FIELDS, f"{ref}.authority")
    inventory_text(authority["authority_identity"], f"{ref}.authority_identity")
    default_ref = inventory_text(authority["default_ref"], f"{ref}.default_ref")
    if not default_ref.startswith("refs/heads/"):
        inventory_error(f"{ref}.default_ref")
    if inventory_oid(authority["default_revision"], f"{ref}.default_revision") != source_revision:
        inventory_error(f"{ref}.default_revision")
    inventory_digest(authority["descriptor_digest"], f"{ref}.descriptor_digest")
    inventory_oid(authority["bootstrap_revision"], f"{ref}.bootstrap_revision")

    home_set = inventory_object(document["home_set"], HOME_SET_FIELDS, f"{ref}.home_set")
    if home_set["contract_version"] != "workbench-legacy-home-set/v1":
        inventory_error(f"{ref}.home_set.contract_version")
    inventory_digest(home_set["digest"], f"{ref}.home_set.digest")
    if inventory_oid(home_set["source_revision"], f"{ref}.home_set.source_revision") != source_revision:
        inventory_error(f"{ref}.home_set.source_revision")

    tasks: list[dict[str, Any]] = []
    projected_writers: list[dict[str, Any]] = []
    homes = inventory_array(document["homes"], f"{ref}.homes")
    home_names: list[str] = []
    identities: set[tuple[str, str]] = set()
    pagination_complete = True
    for home_value in homes:
        home = inventory_object(home_value, HOME_FIELDS, f"{ref}.homes[]")
        home_name = inventory_home(home["home"], f"{ref}.home")
        home_names.append(home_name)
        inventory_text(home["origin_url"], f"{ref}.origin_url")
        if home["membership"] not in ("current", "removed", "origin-replaced"):
            inventory_error(f"{ref}.membership")

        pagination = inventory_object(
            home["pagination"], PAGINATION_FIELDS, f"{ref}.pagination"
        )
        if not isinstance(pagination["complete"], bool):
            inventory_error(f"{ref}.pagination.complete")
        pages = pagination["pages_fetched"]
        if not isinstance(pages, int) or isinstance(pages, bool) or pages < 0:
            inventory_error(f"{ref}.pagination.pages_fetched")
        if pagination["end_cursor"] is not None:
            inventory_text(pagination["end_cursor"], f"{ref}.pagination.end_cursor")
        failure = pagination["failure"]
        if failure is not None:
            failure = inventory_object(failure, FAILURE_FIELDS, f"{ref}.pagination.failure")
            inventory_text(failure["code"], f"{ref}.pagination.failure.code")
            inventory_text(failure["ref"], f"{ref}.pagination.failure.ref")
            if failure["cursor"] is not None:
                inventory_text(failure["cursor"], f"{ref}.pagination.failure.cursor")
        expected_complete = failure is None and pagination["end_cursor"] is None
        if pagination["complete"] != expected_complete:
            inventory_error(f"{ref}.pagination.complete")
        pagination_complete = pagination_complete and pagination["complete"]

        claims = inventory_array(home["claims"], f"{ref}.claims")
        claim_ids: list[str] = []
        for claim_value in claims:
            claim = inventory_object(claim_value, CLAIM_FIELDS, f"{ref}.claim")
            claim_id = inventory_text(claim["claim_id"], f"{ref}.claim_id")
            task_claim_id = inventory_text(
                claim["task_claim_id"], f"{ref}.task_claim_id"
            )
            if claim_id != task_claim_id:
                inventory_error(f"{ref}.claim_id")
            claim_ids.append(claim_id)
            identity = (home_name, claim_id)
            if identity in identities or claim["home"] != home_name:
                inventory_error(f"{ref}.claim.home")
            identities.add(identity)
            if claim["task_contract"] != "workbench-task/v1":
                inventory_error(f"{ref}.task_contract")
            positive_integer(claim["issue"], f"{ref}.issue")
            if claim["parent"] is not None:
                positive_integer(claim["parent"], f"{ref}.parent")
            inventory_text(claim["branch"], f"{ref}.branch")
            inventory_digest(claim["lifecycle_digest"], f"{ref}.lifecycle_digest")
            lifecycle_states = {
                "task-claimed", "task-active", "task-submitted", "task-verified",
                "task-completed", "task-abandoned", "task-cleaned",
            }
            if claim["lifecycle_state"] not in lifecycle_states:
                inventory_error(f"{ref}.lifecycle_state")
            expected_classification = (
                "cleaned-v1" if claim["lifecycle_state"] == "task-cleaned" else "active-v1"
            )
            if claim["classification"] != expected_classification:
                inventory_error(f"{ref}.classification")

            submission = claim["submission"]
            if submission is not None:
                submission = inventory_object(
                    submission, SUBMISSION_FIELDS, f"{ref}.submission"
                )
                positive_integer(submission["pull_request"], f"{ref}.pull_request")
                inventory_oid(submission["head_revision"], f"{ref}.submission.head_revision")
                if submission["current"] is not True:
                    inventory_error(f"{ref}.submission.current")
            source = inventory_oid(
                claim["source_revision"], f"{ref}.claim.source_revision", nullable=True
            )
            pr_head = inventory_oid(
                claim["pr_head_revision"], f"{ref}.pr_head_revision", nullable=True
            )
            if submission is None and pr_head is not None:
                inventory_error(f"{ref}.pr_head_revision")
            if submission is not None and submission["head_revision"] != pr_head:
                inventory_error(f"{ref}.submission.head_revision")
            if not isinstance(claim["ancestry_complete"], bool):
                inventory_error(f"{ref}.ancestry_complete")
            if claim["classification"] == "active-v1" and (
                source is None or claim["ancestry_complete"] is not True
            ):
                inventory_error(f"{ref}.ancestry_complete")

            repos = inventory_array(claim["repos"], f"{ref}.repos")
            repo_identities: list[tuple[str, str, str]] = []
            for repo_value in repos:
                repo = inventory_object(repo_value, REPO_FIELDS, f"{ref}.repo")
                owner = inventory_home(repo["owner"], f"{ref}.repo.owner")
                branch = inventory_text(repo["branch"], f"{ref}.repo.branch")
                if repo["role"] not in ("work", "reference"):
                    inventory_error(f"{ref}.repo.role")
                repo_identities.append((owner, branch, repo["role"]))
                if claim["classification"] == "active-v1" and repo["role"] == "work":
                    projected_writers.append(
                        {
                            "source": "legacy-v1",
                            "claim_id": pseudo_claim_id(task_claim_id, owner, branch),
                            "operation_id": None,
                            "task_claim_id": task_claim_id,
                            "owner": owner,
                            "branch": branch,
                            "context_policy_set_digest": None,
                            "source_revision": source,
                            "pr_head_revision": pr_head,
                            "lifecycle_digest": claim["lifecycle_digest"],
                        }
                    )
            if repo_identities != sorted(repo_identities) or len(repo_identities) != len(
                set(repo_identities)
            ):
                inventory_error(f"{ref}.repos")

            if claim["classification"] == "active-v1":
                tasks.append(
                    {
                        "source": "legacy-inventory:homes[].claims",
                        "home": home_name,
                        "claim_id": claim_id,
                        "task_claim_id": task_claim_id,
                        "task_contract": claim["task_contract"],
                        "issue": claim["issue"],
                        "parent": claim["parent"],
                        "branch": claim["branch"],
                        "lifecycle_state": claim["lifecycle_state"],
                        "lifecycle_digest": claim["lifecycle_digest"],
                        "source_revision": source,
                        "pr_head_revision": pr_head,
                        "ancestry_complete": claim["ancestry_complete"],
                    }
                )
        if claim_ids != sorted(claim_ids) or len(claim_ids) != len(set(claim_ids)):
            inventory_error(f"{ref}.claims")
    if home_names != sorted(home_names) or len(home_names) != len(set(home_names)):
        inventory_error(f"{ref}.homes")

    active_claims = inventory_array(document["active_claims"], f"{ref}.active_claims")
    for active_value in active_claims:
        active = inventory_object(active_value, ACTIVE_CLAIM_FIELDS, f"{ref}.active_claim")
        if active["source"] != "legacy-v1":
            inventory_error(f"{ref}.active_claim.source")
        inventory_text(active["claim_id"], f"{ref}.active_claim.claim_id")
        if active["operation_id"] is not None or active["context_policy_set_digest"] is not None:
            inventory_error(f"{ref}.active_claim")
        inventory_text(active["task_claim_id"], f"{ref}.active_claim.task_claim_id")
        inventory_home(active["owner"], f"{ref}.active_claim.owner")
        inventory_text(active["branch"], f"{ref}.active_claim.branch")
        inventory_oid(active["source_revision"], f"{ref}.active_claim.source_revision")
        inventory_oid(
            active["pr_head_revision"], f"{ref}.active_claim.pr_head_revision", nullable=True
        )
        inventory_digest(active["lifecycle_digest"], f"{ref}.active_claim.lifecycle_digest")
    active_order = [
        (item["source"], item["claim_id"], item["branch"]) for item in active_claims
    ]
    if active_order != sorted(active_order) or len(active_order) != len(
        {item["claim_id"] for item in active_claims}
    ):
        inventory_error(f"{ref}.active_claims")
    projected_writers.sort(key=lambda item: (item["source"], item["claim_id"], item["branch"]))
    if active_claims != projected_writers:
        inventory_error(f"{ref}.active_claims")

    replacements = inventory_array(
        document["origin_replacements"], f"{ref}.origin_replacements"
    )
    replacement_homes: list[str] = []
    replacement_available = True
    for replacement_value in replacements:
        replacement = inventory_object(
            replacement_value, REPLACEMENT_FIELDS, f"{ref}.origin_replacement"
        )
        replacement_homes.append(
            inventory_home(replacement["home"], f"{ref}.origin_replacement.home")
        )
        inventory_text(
            replacement["previous_origin_url"], f"{ref}.previous_origin_url"
        )
        if replacement["current_origin_url"] is not None:
            inventory_text(replacement["current_origin_url"], f"{ref}.current_origin_url")
        if replacement["status"] not in (
            "unchanged", "removed-clean", "removed-in-use", "replaced-clean",
            "replaced-in-use", "unavailable",
        ):
            inventory_error(f"{ref}.origin_replacement.status")
        replacement_available = replacement_available and replacement["status"] != "unavailable"
    if replacement_homes != sorted(replacement_homes) or len(replacement_homes) != len(
        set(replacement_homes)
    ):
        inventory_error(f"{ref}.origin_replacements")

    blockers = inventory_array(document["blockers"], f"{ref}.blockers")
    for blocker_value in blockers:
        blocker = inventory_object(blocker_value, BLOCKER_FIELDS, f"{ref}.blocker")
        inventory_text(blocker["code"], f"{ref}.blocker.code")
        inventory_text(blocker["ref"], f"{ref}.blocker.ref")
    blocker_order = [(item["code"], item["ref"]) for item in blockers]
    if blocker_order != sorted(blocker_order):
        inventory_error(f"{ref}.blockers")

    expected_complete = (
        not blockers and pagination_complete and replacement_available
    )
    if not isinstance(document["complete"], bool) or document["complete"] != expected_complete:
        inventory_error(f"{ref}.complete")
    if status != 0 or not document["complete"]:
        inventory_error(ref)
    return tasks


def validate_engine_manifest(document: dict[str, Any], engine_version: str) -> None:
    ref = "workbench engine-manifest show"
    if tuple(document) != ENGINE_MANIFEST_FIELDS:
        raise AdapterError("public-contract-invalid", ref)
    if document["contract_version"] != ENGINE_MANIFEST_CONTRACT:
        raise AdapterError("public-contract-invalid", f"{ref}.contract_version")
    plugin = require_object(document["plugin"], f"{ref}.plugin")
    if tuple(plugin) != PLUGIN_FIELDS or plugin.get("name") != "workbench":
        raise AdapterError("public-contract-invalid", f"{ref}.plugin")
    if plugin.get("version") != engine_version or SEMVER.fullmatch(engine_version) is None:
        raise AdapterError("public-engine-mismatch", ref)
    source = require_object(document["source"], f"{ref}.source")
    if tuple(source) != SOURCE_FIELDS or source.get("ref") != ENGINE_SOURCE_REF:
        raise AdapterError("public-contract-invalid", f"{ref}.source")
    if not isinstance(source.get("revision"), str) or SHA256.fullmatch(source["revision"]) is None:
        raise AdapterError("public-contract-invalid", f"{ref}.source.revision")
    if document["included_paths"] != ["."]:
        raise AdapterError("public-contract-invalid", f"{ref}.included_paths")
    exclusions = require_array(document["excluded_paths"], f"{ref}.excluded_paths")
    if exclusions != ENGINE_EXCLUSIONS or any(
        not isinstance(item, dict) or tuple(item) != EXCLUSION_FIELDS for item in exclusions
    ):
        raise AdapterError("public-contract-invalid", f"{ref}.excluded_paths")

    nodes = require_array(document["nodes"], f"{ref}.nodes")
    node_paths: list[str] = []
    for node_value in nodes:
        node = require_object(node_value, f"{ref}.node")
        if tuple(node) != MANIFEST_NODE_FIELDS:
            raise AdapterError("public-contract-invalid", f"{ref}.node")
        path = node.get("path")
        if not isinstance(path, str) or not path or "\x00" in path:
            raise AdapterError("public-contract-invalid", f"{ref}.node.path")
        if path != ".":
            pure = pathlib.PurePosixPath(path)
            if pure.is_absolute() or pure.as_posix() != path or ".." in pure.parts:
                raise AdapterError("public-contract-invalid", f"{ref}.node.path")
        node_paths.append(path)
        node_type = node.get("node_type")
        mode = node.get("mode")
        link_target = node.get("link_target")
        if node_type == "file":
            valid_node = mode in ("100644", "100755") and link_target is None
        elif node_type == "directory":
            valid_node = (
                isinstance(mode, str)
                and re.fullmatch(r"04[0-7]{4}", mode) is not None
                and link_target is None
            )
        elif node_type == "symlink":
            valid_node = mode == "120000" and isinstance(link_target, str) and bool(link_target)
        else:
            valid_node = False
        if not valid_node:
            raise AdapterError("public-contract-invalid", f"{ref}.node")
        if not isinstance(node.get("digest"), str) or SHA256.fullmatch(node["digest"]) is None:
            raise AdapterError("public-contract-invalid", f"{ref}.node.digest")
    if node_paths != sorted(node_paths) or len(node_paths) != len(set(node_paths)) or not nodes:
        raise AdapterError("public-contract-invalid", f"{ref}.nodes")
    if not isinstance(document["digest"], str) or SHA256.fullmatch(document["digest"]) is None:
        raise AdapterError("public-contract-invalid", f"{ref}.digest")
    if nodes[0]["path"] != "." or nodes[0]["node_type"] != "directory":
        raise AdapterError("public-contract-invalid", f"{ref}.nodes")

    def canonical_line(value: Any) -> bytes:
        return (
            json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
        ).encode("utf-8")

    tree_bytes = bytearray(b"workbench-plugin-tree/v1\n")
    for path in document["included_paths"]:
        tree_bytes.extend(canonical_line(["included_path", path]))
    for exclusion in exclusions:
        tree_bytes.extend(
            canonical_line(["excluded_path", exclusion["path"], exclusion["match"]])
        )
    for node in nodes:
        tree_bytes.extend(
            canonical_line(
                [
                    "node",
                    node["path"],
                    node["node_type"],
                    node["mode"],
                    node["digest"],
                    node["link_target"],
                ]
            )
        )
    expected_revision = "sha256:" + hashlib.sha256(tree_bytes).hexdigest()
    if source["revision"] != expected_revision:
        raise AdapterError("public-contract-invalid", f"{ref}.source.revision")
    digest_input = dict(document)
    digest_input["digest"] = None
    expected_digest = "sha256:" + hashlib.sha256(canonical_line(digest_input)).hexdigest()
    if document["digest"] != expected_digest:
        raise AdapterError("public-contract-invalid", f"{ref}.digest")


def inspect_public_kernel(
    workspace: pathlib.Path,
    authority_approval_file: pathlib.Path | None = None,
    inventory_mode: str | None = None,
    include_engine_manifest: bool = False,
) -> dict[str, Any]:
    workspace = workspace.resolve()
    if inventory_mode not in (None, "show", "bootstrap-show"):
        raise AdapterError("public-inventory-mode-invalid", str(inventory_mode))
    binary = resolve_workbench_binary()
    contract, _ = run_public_json(
        binary, ("contract", "show", "--format", "json"), workspace, {0}
    )
    schema = validate_contract(
        contract,
        workspace,
        require_bootstrap=inventory_mode == "bootstrap-show",
        require_engine_manifest=include_engine_manifest,
    )
    doctor, doctor_status = run_public_json(
        binary, ("doctor", "--format", "json"), workspace, {0, 1}
    )
    validate_doctor(doctor, doctor_status)
    use_bootstrap = schema == "workbench/v1" or inventory_mode == "bootstrap-show"
    if schema == "workbench/v1" and inventory_mode == "show":
        raise AdapterError("public-inventory-mode-invalid", "show")
    if use_bootstrap:
        if authority_approval_file is None:
            raise AdapterError(
                "bootstrap-authority-approval-required",
                "--authority-approval-file",
            )
        approval = authority_approval_file.expanduser().resolve()
        inventory_argv = (
            "legacy-inventory",
            "bootstrap-show",
            "--authority-approval-file",
            str(approval),
            "--format",
            "json",
        )
        inventory_command = "bootstrap-show"
    else:
        inventory_argv = ("legacy-inventory", "show", "--format", "json")
        inventory_command = "show"
    inventory, inventory_status = run_public_json(
        binary, inventory_argv, workspace, {0, 1}
    )
    active = validate_inventory(inventory, inventory_status, inventory_command)
    snapshot = {
        "contract": contract,
        "doctor": doctor,
        "legacy_inventory": inventory,
        "legacy_inventory_command": inventory_command,
        "active_v1_tasks": active,
    }
    if include_engine_manifest:
        manifest, _ = run_public_json(
            binary,
            ("engine-manifest", "show", "--format", "json"),
            workspace,
            {0},
        )
        validate_engine_manifest(manifest, contract["engine"]["version"])
        snapshot["engine_manifest"] = manifest
    return snapshot
