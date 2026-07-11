#!/usr/bin/env python3
"""Strict closed-home inputs for legacy writer projection."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from typing import Any, Dict, Iterable, List, Tuple


AUTHORITY_FIELDS = (
    "contract_version",
    "authority_identity",
    "origin_url",
    "default_ref",
    "workspace_home",
    "hosting_adapter",
    "hosting_ref",
)
BOOTSTRAP_APPROVAL_FIELDS = (
    "contract_version",
    "approval_id",
    "proposed_descriptor",
    "default_revision",
    "protection",
    "actor",
    "approved_at",
    "source_ref",
)
PROTECTION_FIELDS = (
    "ref",
    "revision",
    "direct_task_actor_writes",
    "verified_at",
    "evidence_ref",
)
BOOTSTRAP_VERIFICATION_FIELDS = (
    "contract_version",
    "approval_digest",
    "authenticated",
    "repository_identity_verified",
    "default_ref_protected",
    "direct_task_actor_writes",
    "observed_default_revision",
    "permission_source",
)
HOME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
OID = re.compile(r"[0-9a-f]{40}([0-9a-f]{24})?\Z")
DEFAULT_REF = re.compile(r"refs/heads/[A-Za-z0-9._/-]+\Z")
RFC3339_UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")

OBSERVATION_FIELDS = (
    "contract_version",
    "source_revision",
    "homes",
    "origin_replacements",
    "blockers",
)
HOME_FIELDS = ("home", "origin_url", "membership", "pagination", "claims")
PAGINATION_FIELDS = ("complete", "pages_fetched", "end_cursor", "failure")
FAILURE_FIELDS = ("code", "ref", "cursor")
CLAIM_FIELDS = (
    "claim_id",
    "task_claim_id",
    "task_contract",
    "issue",
    "home",
    "parent",
    "branch",
    "lifecycle_digest",
    "lifecycle_state",
    "classification",
    "submission",
    "source_revision",
    "pr_head_revision",
    "ancestry_complete",
    "repos",
)
SUBMISSION_FIELDS = ("pull_request", "head_revision", "current")
REPO_FIELDS = ("owner", "branch", "role")
REPLACEMENT_FIELDS = (
    "home",
    "previous_origin_url",
    "current_origin_url",
    "status",
)
BLOCKER_FIELDS = ("code", "ref")
ACTIVE_CLAIM_FIELDS = (
    "source",
    "claim_id",
    "operation_id",
    "task_claim_id",
    "owner",
    "branch",
    "context_policy_set_digest",
    "source_revision",
    "pr_head_revision",
    "lifecycle_digest",
)


def unique_object(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON member: {}".format(key))
        value[key] = item
    return value


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("{} must be a non-empty string".format(field))
    if "\t" in value or "\n" in value or "\r" in value:
        raise ValueError("{} must be a single-line value without TAB".format(field))
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("{} must not contain controls".format(field))
    return value


def require_printable_ascii(value: Any, field: str) -> str:
    text = require_text(value, field)
    if not text.isascii() or any(ord(char) == 127 for char in text):
        raise ValueError("{} must be printable ASCII".format(field))
    return text


def require_home(value: Any, field: str) -> str:
    home = require_text(value, field)
    if HOME.fullmatch(home) is None or home.isdigit():
        raise ValueError("{} does not match the canonical home grammar".format(field))
    return home


def require_fields(value: Any, fields: Tuple[str, ...], name: str) -> Dict[str, Any]:
    if not isinstance(value, dict) or tuple(value) != fields:
        raise ValueError("{} fields or order do not match the contract".format(name))
    return value


def require_digest(value: Any, field: str) -> str:
    if not isinstance(value, str) or DIGEST.fullmatch(value) is None:
        raise ValueError("{} must be a canonical SHA-256 digest".format(field))
    return value


def require_oid(value: Any, field: str) -> str:
    if not isinstance(value, str) or OID.fullmatch(value) is None:
        raise ValueError("{} must be a lowercase Git object ID".format(field))
    return value


def validate_authority(value: Any, require_hosting: bool = False) -> Dict[str, Any]:
    require_fields(value, AUTHORITY_FIELDS, "workspace authority")
    if value["contract_version"] != "workbench-workspace-authority/v1":
        raise ValueError("unsupported workspace authority contract")
    require_printable_ascii(value["authority_identity"], "authority_identity")
    origin = require_printable_ascii(value["origin_url"], "origin_url")
    default_ref = require_printable_ascii(value["default_ref"], "default_ref")
    if DEFAULT_REF.fullmatch(default_ref) is None or ".." in default_ref or "//" in default_ref:
        raise ValueError("default_ref must be a canonical full branch ref")
    require_home(value["workspace_home"], "workspace_home")
    adapter = value["hosting_adapter"]
    hosting_ref = value["hosting_ref"]
    if (adapter is None) != (hosting_ref is None):
        raise ValueError("hosting_adapter and hosting_ref must be null or present together")
    if require_hosting and adapter is None:
        raise ValueError("bootstrap authority requires an explicit hosting adapter and ref")
    if adapter is not None:
        require_printable_ascii(adapter, "hosting_adapter")
        require_printable_ascii(hosting_ref, "hosting_ref")
    if adapter == "github" and re.fullmatch(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", origin
    ) is None:
        raise ValueError("GitHub origin_url must be canonical HTTPS with .git suffix")
    return value


def load_authority(file: str) -> Dict[str, Any]:
    with open(file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    return validate_authority(value)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def load_bootstrap_approval(file: str) -> Tuple[Dict[str, Any], bytes]:
    with open(file, "rb") as handle:
        raw = handle.read()
    if not raw.endswith(b"\n") or b"\r" in raw:
        raise ValueError("bootstrap approval must be canonical LF-terminated JSON")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    except UnicodeDecodeError as exc:
        raise ValueError("bootstrap approval must be UTF-8") from exc
    require_fields(value, BOOTSTRAP_APPROVAL_FIELDS, "bootstrap authority approval")
    if value["contract_version"] != "workbench-bootstrap-authority-approval/v1":
        raise ValueError("unsupported bootstrap authority approval contract")
    require_printable_ascii(value["approval_id"], "approval_id")
    descriptor = validate_authority(value["proposed_descriptor"], require_hosting=True)
    default_revision = require_oid(value["default_revision"], "default_revision")
    protection = require_fields(value["protection"], PROTECTION_FIELDS, "bootstrap protection")
    if protection["ref"] != descriptor["default_ref"]:
        raise ValueError("bootstrap protection ref does not match the proposed descriptor")
    if protection["revision"] != default_revision:
        raise ValueError("bootstrap protection revision does not match default_revision")
    if protection["direct_task_actor_writes"] != "blocked":
        raise ValueError("bootstrap protection must block direct task-actor writes")
    for key in ("ref", "evidence_ref"):
        require_printable_ascii(protection[key], "protection." + key)
    for key in ("verified_at",):
        if not isinstance(protection[key], str) or RFC3339_UTC.fullmatch(protection[key]) is None:
            raise ValueError("protection.verified_at must be RFC 3339 UTC")
    for key in ("actor", "source_ref"):
        require_printable_ascii(value[key], key)
    if not isinstance(value["approved_at"], str) or RFC3339_UTC.fullmatch(value["approved_at"]) is None:
        raise ValueError("approved_at must be RFC 3339 UTC")
    if canonical_json(value) != raw:
        raise ValueError("bootstrap approval must use the exact canonical JSON serialization")
    return value, raw


def atomic_write(path: str, raw: bytes) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    fd, temporary = tempfile.mkstemp(prefix=".workbench-bootstrap-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_bootstrap_verification(
    approval: Dict[str, Any], approval_raw: bytes, verification_file: str
) -> None:
    with open(verification_file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    require_fields(value, BOOTSTRAP_VERIFICATION_FIELDS, "bootstrap authority verification")
    if value["contract_version"] != "workbench-bootstrap-authority-verification/v1":
        raise UntrustedApproval()
    expected_digest = "sha256:" + hashlib.sha256(approval_raw).hexdigest()
    if value["approval_digest"] != expected_digest:
        raise UntrustedApproval()
    if value["authenticated"] is not True:
        raise UntrustedApproval()
    if value["repository_identity_verified"] is not True:
        raise UntrustedApproval()
    if value["default_ref_protected"] is not True:
        raise UntrustedApproval()
    if value["direct_task_actor_writes"] != "blocked":
        raise UntrustedApproval()
    if value["observed_default_revision"] != approval["default_revision"]:
        raise UntrustedApproval()
    if value["permission_source"] != approval["proposed_descriptor"]["hosting_ref"]:
        raise UntrustedApproval()


def parse_registry(file: str) -> List[Tuple[str, str]]:
    with open(file, "rb") as handle:
        raw = handle.read()
    if raw and (not raw.endswith(b"\n") or b"\r" in raw):
        raise ValueError("codebase registry must be LF-terminated")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("codebase registry must be UTF-8") from exc
    rows: List[Tuple[str, str]] = []
    seen = set()
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        if line != line.lstrip() or ":" not in line:
            raise ValueError("malformed codebase registry line {}".format(lineno))
        name, origin_field = line.split(":", 1)
        require_home(name, "codebase home")
        if name in seen:
            raise ValueError("duplicate codebase home: {}".format(name))
        seen.add(name)
        if name != name.rstrip() or origin_field != " " + origin_field.strip():
            raise ValueError("noncanonical whitespace in codebase registry line {}".format(lineno))
        origin = origin_field[1:]
        require_text(origin, "codebase origin_url")
        rows.append((name, origin))
    return rows


def home_set(authority_file: str, registry_file: str) -> Dict[str, Any]:
    authority = load_authority(authority_file)
    rows = [(authority["workspace_home"], authority["origin_url"])]
    rows.extend(parse_registry(registry_file))
    homes = [home for home, _ in rows]
    if len(homes) != len(set(homes)):
        raise ValueError("workspace and codebase homes must be unique")
    rows.sort(key=lambda item: item[0])
    manifest = "workbench-legacy-home-set/v1\n" + "".join(
        "home\t{}\t{}\n".format(home, origin) for home, origin in rows
    )
    return {
        "contract_version": "workbench-legacy-home-set/v1",
        "digest": "sha256:" + hashlib.sha256(manifest.encode("utf-8")).hexdigest(),
        "homes": [{"home": home, "origin_url": origin} for home, origin in rows],
    }


def registry_snapshot(
    authority_file: str, registry_file: str, source_revision: str
) -> Dict[str, Any]:
    authority = load_authority(authority_file)
    require_oid(source_revision, "source_revision")
    with open(authority_file, "rb") as handle:
        descriptor_digest = "sha256:" + hashlib.sha256(handle.read()).hexdigest()
    with open(registry_file, "rb") as handle:
        registry_raw = handle.read()
    codebases = [
        {"home": home, "origin_url": origin}
        for home, origin in sorted(parse_registry(registry_file), key=lambda item: item[0])
    ]
    return {
        "contract_version": "workbench-codebase-registry-snapshot/v1",
        "source_revision": source_revision,
        "authority_identity": authority["authority_identity"],
        "descriptor_digest": descriptor_digest,
        "registry_digest": "sha256:" + hashlib.sha256(registry_raw).hexdigest(),
        "workspace": {
            "home": authority["workspace_home"],
            "origin_url": authority["origin_url"],
        },
        "codebases": codebases,
    }


def pseudo_claim_id(task_claim_id: str, owner: str, branch: str) -> str:
    manifest = (
        "workbench-legacy-writer-identity/v1\n"
        "task_claim_id\t{}\nowner\t{}\nbranch\t{}\n".format(task_claim_id, owner, branch)
    )
    return "legacy-v1-" + hashlib.sha256(manifest.encode("utf-8")).hexdigest()


def validate_blocker(value: Any) -> Dict[str, Any]:
    require_fields(value, BLOCKER_FIELDS, "legacy inventory blocker")
    require_text(value["code"], "blocker.code")
    require_text(value["ref"], "blocker.ref")
    return value


def validate_claim(value: Any, home: str) -> Dict[str, Any]:
    require_fields(value, CLAIM_FIELDS, "legacy task claim")
    require_text(value["claim_id"], "claim_id")
    require_text(value["task_claim_id"], "task_claim_id")
    if value["claim_id"] != value["task_claim_id"]:
        raise ValueError("legacy task claim identities must match")
    if value["task_contract"] != "workbench-task/v1":
        raise ValueError("legacy inventory claim must be workbench-task/v1")
    if not isinstance(value["issue"], int) or isinstance(value["issue"], bool) or value["issue"] <= 0:
        raise ValueError("legacy claim issue must be a positive integer")
    if value["home"] != home:
        raise ValueError("legacy claim home does not match its inventory home")
    if value["parent"] is not None and (
        not isinstance(value["parent"], int)
        or isinstance(value["parent"], bool)
        or value["parent"] <= 0
    ):
        raise ValueError("legacy claim parent must be null or a positive integer")
    require_text(value["branch"], "branch")
    require_digest(value["lifecycle_digest"], "lifecycle_digest")
    lifecycle_states = {
        "task-claimed",
        "task-active",
        "task-submitted",
        "task-verified",
        "task-completed",
        "task-abandoned",
        "task-cleaned",
    }
    if value["lifecycle_state"] not in lifecycle_states:
        raise ValueError("invalid legacy lifecycle state")
    expected_classification = (
        "cleaned-v1" if value["lifecycle_state"] == "task-cleaned" else "active-v1"
    )
    if value["classification"] != expected_classification:
        raise ValueError("legacy active classification does not match lifecycle")
    submission = value["submission"]
    if submission is not None:
        require_fields(submission, SUBMISSION_FIELDS, "legacy submission")
        if (
            not isinstance(submission["pull_request"], int)
            or isinstance(submission["pull_request"], bool)
            or submission["pull_request"] <= 0
        ):
            raise ValueError("legacy submission pull request must be positive")
        require_oid(submission["head_revision"], "submission.head_revision")
        if submission["current"] is not True:
            raise ValueError("retained legacy submission must be current")
    source_revision = value["source_revision"]
    pr_head_revision = value["pr_head_revision"]
    if source_revision is not None:
        require_oid(source_revision, "source_revision")
    if pr_head_revision is not None:
        require_oid(pr_head_revision, "pr_head_revision")
    if submission is None and pr_head_revision is not None:
        raise ValueError("legacy PR head requires a current submission")
    if submission is not None and submission["head_revision"] != pr_head_revision:
        raise ValueError("legacy submission head does not match pr_head_revision")
    if not isinstance(value["ancestry_complete"], bool):
        raise ValueError("ancestry_complete must be boolean")
    if value["classification"] == "active-v1" and (
        source_revision is None or value["ancestry_complete"] is not True
    ):
        raise ValueError("active legacy claim requires complete source ancestry")
    repos = value["repos"]
    if not isinstance(repos, list):
        raise ValueError("legacy claim repos must be an array")
    for repo in repos:
        require_fields(repo, REPO_FIELDS, "legacy repo")
        require_home(repo["owner"], "legacy repo owner")
        require_text(repo["branch"], "legacy repo branch")
        if repo["role"] not in ("work", "reference"):
            raise ValueError("legacy repo role is invalid")
    if repos != sorted(repos, key=lambda item: (item["owner"], item["branch"], item["role"])):
        raise ValueError("legacy claim repos are not canonically sorted")
    if len(repos) != len({(item["owner"], item["branch"], item["role"]) for item in repos}):
        raise ValueError("duplicate legacy repo row")
    return value


def validate_home(value: Any) -> Dict[str, Any]:
    require_fields(value, HOME_FIELDS, "legacy inventory home")
    home = require_home(value["home"], "home")
    require_text(value["origin_url"], "origin_url")
    if value["membership"] not in ("current", "removed", "origin-replaced"):
        raise ValueError("invalid legacy home membership")
    pagination = require_fields(value["pagination"], PAGINATION_FIELDS, "legacy pagination")
    if not isinstance(pagination["complete"], bool):
        raise ValueError("pagination.complete must be boolean")
    if (
        not isinstance(pagination["pages_fetched"], int)
        or isinstance(pagination["pages_fetched"], bool)
        or pagination["pages_fetched"] < 0
    ):
        raise ValueError("pagination.pages_fetched must be a nonnegative integer")
    if pagination["end_cursor"] is not None:
        require_text(pagination["end_cursor"], "pagination.end_cursor")
    failure = pagination["failure"]
    if failure is not None:
        require_fields(failure, FAILURE_FIELDS, "pagination failure")
        require_text(failure["code"], "pagination.failure.code")
        require_text(failure["ref"], "pagination.failure.ref")
        if failure["cursor"] is not None:
            require_text(failure["cursor"], "pagination.failure.cursor")
    if pagination["complete"] != (failure is None and pagination["end_cursor"] is None):
        raise ValueError("pagination completeness does not match its terminal cursor/failure")
    claims = value["claims"]
    if not isinstance(claims, list):
        raise ValueError("legacy home claims must be an array")
    for claim in claims:
        validate_claim(claim, home)
    if claims != sorted(claims, key=lambda item: item["claim_id"]):
        raise ValueError("legacy home claims are not sorted by claim_id")
    if len(claims) != len({item["claim_id"] for item in claims}):
        raise ValueError("duplicate legacy task claim")
    return value


def validate_replacement(value: Any) -> Dict[str, Any]:
    require_fields(value, REPLACEMENT_FIELDS, "legacy origin replacement")
    require_home(value["home"], "origin replacement home")
    require_text(value["previous_origin_url"], "previous_origin_url")
    if value["current_origin_url"] is not None:
        require_text(value["current_origin_url"], "current_origin_url")
    statuses = {
        "unchanged",
        "removed-clean",
        "removed-in-use",
        "replaced-clean",
        "replaced-in-use",
        "unavailable",
    }
    if value["status"] not in statuses:
        raise ValueError("invalid origin replacement status")
    return value


def build_inventory(
    authority_file: str,
    registry_file: str,
    default_revision: str,
    bootstrap_revision: str,
    observation_file: str,
) -> Dict[str, Any]:
    authority = load_authority(authority_file)
    require_oid(default_revision, "default_revision")
    require_oid(bootstrap_revision, "bootstrap_revision")
    with open(authority_file, "rb") as handle:
        descriptor_digest = "sha256:" + hashlib.sha256(handle.read()).hexdigest()
    current_home_set = home_set(authority_file, registry_file)
    observation = load_json(observation_file)
    require_fields(observation, OBSERVATION_FIELDS, "legacy adapter observation")
    if observation["contract_version"] != "workbench-legacy-observation/v1":
        raise ValueError("unsupported legacy adapter observation")
    if observation["source_revision"] != default_revision:
        raise ValueError("legacy observation does not bind the protected default revision")
    homes = observation["homes"]
    if not isinstance(homes, list):
        raise ValueError("legacy observation homes must be an array")
    for item in homes:
        validate_home(item)
    if homes != sorted(homes, key=lambda item: item["home"]):
        raise ValueError("legacy homes are not canonically sorted")
    if len(homes) != len({item["home"] for item in homes}):
        raise ValueError("duplicate legacy inventory home")
    current = {item["home"]: item["origin_url"] for item in current_home_set["homes"]}
    observed_current = {
        item["home"]: item["origin_url"] for item in homes if item["membership"] == "current"
    }
    if current != observed_current:
        raise ValueError("legacy observation does not cover the exact closed current home set")
    replacements = observation["origin_replacements"]
    if not isinstance(replacements, list):
        raise ValueError("origin_replacements must be an array")
    for item in replacements:
        validate_replacement(item)
    if replacements != sorted(replacements, key=lambda item: item["home"]):
        raise ValueError("origin replacements are not canonically sorted")
    if len(replacements) != len({item["home"] for item in replacements}):
        raise ValueError("duplicate origin replacement")
    blockers = observation["blockers"]
    if not isinstance(blockers, list):
        raise ValueError("legacy inventory blockers must be an array")
    for blocker in blockers:
        validate_blocker(blocker)
    if blockers != sorted(blockers, key=lambda item: (item["code"], item["ref"])):
        raise ValueError("legacy inventory blockers are not canonically sorted")

    active_claims: List[Dict[str, Any]] = []
    for home in homes:
        for claim in home["claims"]:
            if claim["classification"] != "active-v1":
                continue
            for repo in claim["repos"]:
                if repo["role"] != "work":
                    continue
                active_claims.append(
                    {
                        "source": "legacy-v1",
                        "claim_id": pseudo_claim_id(
                            claim["task_claim_id"], repo["owner"], repo["branch"]
                        ),
                        "operation_id": None,
                        "task_claim_id": claim["task_claim_id"],
                        "owner": repo["owner"],
                        "branch": repo["branch"],
                        "context_policy_set_digest": None,
                        "source_revision": claim["source_revision"],
                        "pr_head_revision": claim["pr_head_revision"],
                        "lifecycle_digest": claim["lifecycle_digest"],
                    }
                )
    active_claims.sort(key=lambda item: (item["source"], item["claim_id"], item["branch"]))
    if len(active_claims) != len({item["claim_id"] for item in active_claims}):
        raise ValueError("duplicate projected legacy writer claim")

    complete = (
        not blockers
        and all(item["pagination"]["complete"] for item in homes)
        and all(
            claim["classification"] != "active-v1" or claim["ancestry_complete"]
            for item in homes
            for claim in item["claims"]
        )
        and all(item["status"] != "unavailable" for item in replacements)
    )
    return {
        "contract_version": "workbench-legacy-inventory/v1",
        "source_revision": default_revision,
        "authority": {
            "authority_identity": authority["authority_identity"],
            "default_ref": authority["default_ref"],
            "default_revision": default_revision,
            "descriptor_digest": descriptor_digest,
            "bootstrap_revision": bootstrap_revision,
        },
        "home_set": {
            "contract_version": "workbench-legacy-home-set/v1",
            "digest": current_home_set["digest"],
            "source_revision": default_revision,
        },
        "homes": homes,
        "active_claims": active_claims,
        "origin_replacements": replacements,
        "complete": complete,
        "blockers": blockers,
    }


def load_json(file: str) -> Any:
    with open(file, "r", encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=unique_object)


def cmd_home_set(args: argparse.Namespace) -> None:
    value = home_set(args.authority_file, args.registry_file)
    if args.format == "json":
        json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")
    else:
        sys.stdout.write("digest={}\n".format(value["digest"]))
        for item in value["homes"]:
            sys.stdout.write("home={}\t{}\n".format(item["home"], item["origin_url"]))


def cmd_registry_snapshot(args: argparse.Namespace) -> None:
    value = registry_snapshot(args.authority_file, args.registry_file, args.source_revision)
    entries = [value["workspace"]] + value["codebases"]
    if args.owner is not None:
        matches = [item for item in entries if item["home"] == args.owner]
        if len(matches) != 1:
            raise ValueError("owner is not present in the protected codebase registry")
        entry = matches[0]
        if args.format == "shell":
            sys.stdout.write("source_revision={}\n".format(value["source_revision"]))
            sys.stdout.write("descriptor_digest={}\n".format(value["descriptor_digest"]))
            sys.stdout.write("registry_digest={}\n".format(value["registry_digest"]))
            sys.stdout.write("owner={}\n".format(entry["home"]))
            sys.stdout.write("origin_url={}\n".format(entry["origin_url"]))
            return
        value = dict(value)
        value["entry"] = entry
    if args.format != "json":
        raise ValueError("shell registry snapshot requires --owner")
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def cmd_bootstrap_approval(args: argparse.Namespace) -> None:
    approval, raw = load_bootstrap_approval(args.approval_file)
    validate_bootstrap_verification(approval, raw, args.verification_file)
    descriptor = approval["proposed_descriptor"]
    atomic_write(args.descriptor_output, canonical_json(descriptor))
    fields = (
        descriptor["origin_url"],
        descriptor["default_ref"],
        approval["default_revision"],
        descriptor["workspace_home"],
        descriptor["hosting_adapter"],
        descriptor["hosting_ref"],
        "sha256:" + hashlib.sha256(raw).hexdigest(),
    )
    sys.stdout.write("\t".join(fields) + "\n")


def cmd_inventory(args: argparse.Namespace) -> None:
    value = build_inventory(
        args.authority_file,
        args.registry_file,
        args.default_revision,
        args.bootstrap_revision,
        args.observation_file,
    )
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    if not value["complete"]:
        raise IncompleteInventory()


def cmd_unavailable_observation(args: argparse.Namespace) -> None:
    value = home_set(args.authority_file, args.registry_file)
    homes = []
    for item in value["homes"]:
        homes.append(
            {
                "home": item["home"],
                "origin_url": item["origin_url"],
                "membership": "current",
                "pagination": {
                    "complete": False,
                    "pages_fetched": 0,
                    "end_cursor": None,
                    "failure": {
                        "code": "trusted-adapter-unavailable",
                        "ref": item["origin_url"],
                        "cursor": None,
                    },
                },
                "claims": [],
            }
        )
    output = {
        "contract_version": "workbench-legacy-observation/v1",
        "source_revision": args.source_revision,
        "homes": homes,
        "origin_replacements": [],
        "blockers": [
            {
                "code": "legacy-writer-source-unavailable",
                "ref": "trusted-hosting-adapter",
            }
        ],
    }
    json.dump(output, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


class IncompleteInventory(Exception):
    pass


class UntrustedApproval(Exception):
    pass


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    home = commands.add_parser("home-set")
    home.add_argument("--authority-file", required=True)
    home.add_argument("--registry-file", required=True)
    home.add_argument("--format", choices=("json", "shell"), required=True)
    home.set_defaults(func=cmd_home_set)
    registry = commands.add_parser("registry-snapshot")
    registry.add_argument("--authority-file", required=True)
    registry.add_argument("--registry-file", required=True)
    registry.add_argument("--source-revision", required=True)
    registry.add_argument("--owner")
    registry.add_argument("--format", choices=("json", "shell"), required=True)
    registry.set_defaults(func=cmd_registry_snapshot)
    approval = commands.add_parser("bootstrap-approval")
    approval.add_argument("--approval-file", required=True)
    approval.add_argument("--verification-file", required=True)
    approval.add_argument("--descriptor-output", required=True)
    approval.set_defaults(func=cmd_bootstrap_approval)
    inventory = commands.add_parser("inventory")
    inventory.add_argument("--authority-file", required=True)
    inventory.add_argument("--registry-file", required=True)
    inventory.add_argument("--default-revision", required=True)
    inventory.add_argument("--bootstrap-revision", required=True)
    inventory.add_argument("--observation-file", required=True)
    inventory.set_defaults(func=cmd_inventory)
    unavailable = commands.add_parser("unavailable-observation")
    unavailable.add_argument("--authority-file", required=True)
    unavailable.add_argument("--registry-file", required=True)
    unavailable.add_argument("--source-revision", required=True)
    unavailable.set_defaults(func=cmd_unavailable_observation)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.func(args)
    except IncompleteInventory:
        return 1
    except UntrustedApproval:
        return 1
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
