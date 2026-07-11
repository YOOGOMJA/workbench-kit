"""Strict contracts and canonical encodings for governed workbench upgrades."""

from __future__ import annotations

import base64
import binascii
import copy
import hashlib
import json
import pathlib
import re
import unicodedata
from typing import Any, Iterable

from workbench_kit_json import (
    DuplicateJsonMember,
    InvalidJsonConstant,
    strict_json_loads,
)


SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
HOME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DEFAULT_REF = re.compile(r"^refs/heads/[A-Za-z0-9._/-]+$")
RFC3339_UTC = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z$"
)
BCP47 = re.compile(r"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$")
TREE_DIGEST = re.compile(r"^git-tree:(?:[0-9a-f]{40}|[0-9a-f]{64})$")
UPGRADE_ID = re.compile(r"^upgrade-[0-9a-f]{64}$")
WORKSPACE_ID = re.compile(r"^ws-[0-9a-f]{64}$")
EFFECT_ID = re.compile(r"^effect-[0-9]{4}$")

AUTHORITY_FIELDS = (
    "contract_version", "approval_id", "proposed_descriptor", "default_revision",
    "protection", "actor", "approved_at", "source_ref",
)
DESCRIPTOR_FIELDS = (
    "contract_version", "authority_identity", "origin_url", "default_ref",
    "workspace_home", "hosting_adapter", "hosting_ref",
)
PROTECTION_FIELDS = (
    "ref", "revision", "direct_task_actor_writes", "verified_at", "evidence_ref",
)
REVIEWED_OVERLAY_FIELDS = (
    "contract_version", "review_id", "content_base64", "content_digest", "actor",
    "reviewed_at", "source_ref",
)
PLAN_FIELDS = (
    "contract_version", "plan_digest", "classification_before", "target_classification",
    "embedded_engine", "provenance_before", "provenance_after", "workspace", "planner",
    "doctor", "legacy_inventory", "inputs", "engine_manifest", "plugin_equivalence",
    "removal_plan_basis_digest", "removal_approval", "active_v1_tasks", "preserved",
    "parent_directories", "artifacts", "operations", "blockers", "changed", "actionable",
)
EMBEDDED_FIELDS = ("before", "after", "equivalence_receipt_digest")
PROVENANCE_FIELDS = ("kind", "state", "receipt_digest", "ref")
WORKSPACE_FIELDS = (
    "root", "source_revision", "default_revision", "source_tree_digest", "migration_task",
)
MIGRATION_TASK_FIELDS = (
    "task_id", "claim_id", "task_contract", "branch", "index_digest",
)
PLANNER_FIELDS = ("contract_version", "plugin_version", "planner_revision")
DOCTOR_FIELDS = (
    "contract_version", "ready", "object_digest", "source_digest",
    "writer_coordination_digest",
)
LEGACY_FIELDS = (
    "contract_version", "command", "object_digest", "source_digest", "authority_revision",
    "home_set_digest", "complete",
)
ENGINE_MANIFEST_FIELDS = (
    "contract_version", "command", "object_digest", "source_digest",
    "content_revision", "manifest_digest",
)
INPUTS_FIELDS = ("language", "bootstrap_authority_approval", "reviewed_overlay")
LANGUAGE_FIELDS = ("contract_version", "tag", "source", "source_ref", "digest")
ACTIVE_FIELDS = ("contract_version", "source_inventory_object_digest", "tasks", "digest")
ACTIVE_TASK_FIELDS = (
    "source", "home", "claim_id", "task_claim_id", "task_contract", "issue", "parent",
    "branch", "lifecycle_state", "lifecycle_digest", "source_revision", "pr_head_revision",
    "ancestry_complete",
)
BLOCKER_FIELDS = ("code", "ref")
RECEIPT_INPUT_FIELDS = ("receipt", "object_digest", "source_digest")
PARENT_FIELDS = ("path", "before_type", "before_mode", "after_type", "after_mode")
ARTIFACT_FIELDS = (
    "path", "node_type", "mode", "content_base64", "link_target", "source_ref",
    "source_digest",
)
OPERATION_FIELDS = (
    "op", "path", "before_type", "before_mode", "before_digest", "after_type",
    "after_mode", "after_digest", "artifact_source_digest", "equivalence_receipt_ref",
)
GENERATOR_FIELDS = (
    "contract_version", "receipt_id", "generator_id", "generator_version", "source_revision",
    "compose_contract", "header_base64", "core_base64", "core_digest", "separator_base64",
    "settings_owned", "generated_nodes", "receipt_digest",
)
SETTINGS_OWNED_FIELDS = ("marketplace", "plugin_enabled")
GENERATED_NODE_FIELDS = ("path", "node_type", "mode")
RECEIPT_ARTIFACT_FIELDS = ("path", "node_type", "mode", "digest")
GENERATION_RECEIPT_FIELDS = (
    "contract_version", "generator_receipt_digest", "workspace_home", "language",
    "authority_descriptor_digest", "embedded_engine", "artifacts",
    "candidate_basis_digest",
)
GENERATION_EMBEDDED_FIELDS = ("state", "equivalence_receipt_digest")
MIGRATION_RECEIPT_FIELDS = (
    "contract_version", "source_revision", "source_tree_digest", "planner",
    "migration_task", "language", "authority_approval_object_digest",
    "authority_approval_source_digest", "reviewed_overlay_object_digest",
    "reviewed_overlay_source_digest", "legacy_inventory_object_digest",
    "legacy_inventory_source_digest", "active_v1_tasks_digest", "embedded_engine",
    "artifacts", "candidate_basis_digest",
)
EQUIVALENCE_FIELDS = (
    "contract_version", "receipt_id", "replacement_plugin", "public_contract",
    "required_capabilities", "legacy_source", "legacy_manifest_digest", "allowed_roots",
    "removable_nodes", "discovery_links", "verification_evidence",
)
REPLACEMENT_PLUGIN_FIELDS = (
    "plugin_name", "plugin_version", "source_revision", "plugin_manifest_digest", "source_ref",
)
PUBLIC_CONTRACT_FIELDS = (
    "contract_version", "engine_name", "engine_version", "supported_object_digest",
    "capabilities",
)
LEGACY_SOURCE_FIELDS = ("source_ref", "source_revision")
LEGACY_NODE_FIELDS = ("path", "node_type", "mode", "digest", "link_target")
EVIDENCE_FIELDS = ("evidence_id", "kind", "source_ref", "source_revision", "digest")
REMOVAL_APPROVAL_FIELDS = (
    "contract_version", "approval_id", "equivalence_receipt_id",
    "equivalence_receipt_digest", "approved_plan_basis_digest", "actor", "approved_at",
    "source_ref",
)
REMOVAL_BASIS_FIELDS = (
    "contract_version", "workspace_source_revision", "workspace_source_tree_digest",
    "migration_task_claim_id", "planner_revision", "legacy_inventory_digest",
    "equivalence_receipt_digest", "remove_operations",
)
RESULT_FIELDS = (
    "contract_version", "result_digest", "plan_digest", "classification_before",
    "target_classification", "embedded_engine", "provenance_final", "workspace",
    "transaction", "changed", "applied", "preserved", "active_v1_tasks",
    "validation", "blockers",
)
TRANSACTION_FIELDS = (
    "journal_id", "workspace_id", "stage", "direction", "cursor", "resumed",
)
APPLIED_FIELDS = ("op", "path", "before_digest", "after_digest")
VALIDATION_FIELDS = (
    "status", "classification_after", "basis_kind", "basis_digest", "blockers",
    "digest",
)
JOURNAL_FIELDS = (
    "contract_version", "journal_id", "workspace_id", "plan_digest",
    "plan_source_digest", "workspace", "stage", "direction", "cursor", "effects",
    "applied", "validation", "completion_result", "created_at", "updated_at",
)
EFFECT_FIELDS = (
    "effect_id", "kind", "path", "temp_path", "before", "after",
    "artifact_source_digest", "equivalence_receipt_ref",
)
NODE_IMAGE_FIELDS = ("node_type", "mode", "content_base64", "link_target", "digest")

CLASSIFICATIONS = {
    "generated-minimal", "embedded-legacy", "migration-staged", "already-current",
    "malformed", "unrecognized", "indeterminate",
}
EMBEDDED_STATES = {
    "absent", "present-verified", "present-unverified", "indeterminate",
}
RESERVED_PREFIXES = (".git", ".worktrees", ".codebases")
BASE_RECEIPT_ARTIFACT_PATHS = {
    ".claude/settings.json",
    ".gitattributes",
    ".gitignore",
    ".workbench/authority.json",
    ".workbench/policy.conf",
    ".workbench/profile.conf",
    ".workbench/schema",
    "AGENTS.md",
    "CLAUDE.md",
}
MIGRATION_ARTIFACT_SOURCES = {
    ".workbench/schema": "constant:workbench/v2",
    ".workbench/profile.conf": "render:workbench-profile/v1",
    ".workbench/policy.conf": "constant:workbench-policy/v1-conservative-ask",
    ".workbench/authority.json": (
        "input:bootstrap-authority-approval#proposed_descriptor"
    ),
    ".workbench/migration.json": "render:workbench-kit-migration-receipt/v1",
    "AGENTS.overlay.md": "input:reviewed-overlay#content",
    "AGENTS.md": "compose:workbench-kit-compose/v1",
    "CLAUDE.md": "compose:workbench-kit-compose/v1",
    ".claude/settings.json": "merge:claude-settings/v1",
    ".gitignore": "merge:gitignore/v1",
    ".gitattributes": "merge:gitattributes/v1",
}


class ContractError(ValueError):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


def fail(ref: str, code: str = "contract-invalid") -> None:
    raise ContractError(code, ref)


def canonical_bytes(value: Any) -> bytes:
    try:
        payload = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        raise ContractError("canonical-json-invalid", "value") from error
    return (payload + "\n").encode("utf-8")


def canonical_digest(
    value: Any, *, null_field: str | None = None, raw: bool = False
) -> str:
    if raw:
        if not isinstance(value, bytes):
            fail("raw-digest", "digest-input-invalid")
        payload = value
    else:
        normalized = copy.deepcopy(value)
        if null_field is not None:
            if not isinstance(normalized, dict) or null_field not in normalized:
                fail(null_field, "digest-input-invalid")
            normalized[null_field] = None
        payload = canonical_bytes(normalized)
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def workspace_identifier(root: str) -> str:
    payload = f"workbench-kit-workspace-id/v1\nroot\t{root}\n".encode("utf-8")
    return "ws-" + hashlib.sha256(payload).hexdigest()


def strict_load(raw: bytes, ref: str) -> Any:
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ContractError("json-invalid", ref) from error
    if not text.endswith("\n"):
        fail(ref, "json-invalid")
    try:
        return strict_json_loads(text)
    except (DuplicateJsonMember, InvalidJsonConstant, json.JSONDecodeError) as error:
        raise ContractError("json-invalid", ref) from error


def exact_object(value: Any, fields: tuple[str, ...], ref: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != set(fields) or len(value) != len(fields):
        fail(ref)
    return {field: value[field] for field in fields}


def text(value: Any, ref: str, *, ascii_only: bool = False) -> str:
    if not isinstance(value, str) or not value:
        fail(ref)
    if ascii_only and not value.isascii():
        fail(ref)
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        fail(ref)
    return value


def digest(value: Any, ref: str, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        fail(ref)
    return value


def oid(value: Any, ref: str, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or OID.fullmatch(value) is None:
        fail(ref)
    return value


def boolean(value: Any, ref: str) -> bool:
    if not isinstance(value, bool):
        fail(ref)
    return value


def array(value: Any, ref: str) -> list[Any]:
    if not isinstance(value, list):
        fail(ref)
    return value


def normalized_object(value: dict[str, Any], fields: Iterable[str]) -> dict[str, Any]:
    return {field: value[field] for field in fields}


def validate_descriptor(value: Any) -> dict[str, Any]:
    descriptor = exact_object(value, DESCRIPTOR_FIELDS, "proposed_descriptor")
    if descriptor["contract_version"] != "workbench-workspace-authority/v1":
        fail("proposed_descriptor.contract_version")
    for field in (
        "authority_identity", "origin_url", "default_ref", "workspace_home",
        "hosting_adapter", "hosting_ref",
    ):
        text(descriptor[field], f"proposed_descriptor.{field}", ascii_only=True)
    default_ref = descriptor["default_ref"]
    if DEFAULT_REF.fullmatch(default_ref) is None or ".." in default_ref or "//" in default_ref:
        fail("proposed_descriptor.default_ref")
    home = descriptor["workspace_home"]
    if HOME.fullmatch(home) is None or home.isdigit():
        fail("proposed_descriptor.workspace_home")
    if descriptor["hosting_adapter"] == "github" and re.fullmatch(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git",
        descriptor["origin_url"],
    ) is None:
        fail("proposed_descriptor.origin_url")
    return descriptor


def validate_authority_approval(value: Any) -> dict[str, Any]:
    approval = exact_object(value, AUTHORITY_FIELDS, "bootstrap-authority-approval")
    if approval["contract_version"] != "workbench-bootstrap-authority-approval/v1":
        fail("bootstrap-authority-approval.contract_version")
    text(approval["approval_id"], "approval_id", ascii_only=True)
    descriptor = validate_descriptor(approval["proposed_descriptor"])
    revision = oid(approval["default_revision"], "default_revision")
    protection = exact_object(approval["protection"], PROTECTION_FIELDS, "protection")
    if protection["ref"] != descriptor["default_ref"]:
        fail("protection.ref")
    if oid(protection["revision"], "protection.revision") != revision:
        fail("protection.revision")
    if protection["direct_task_actor_writes"] != "blocked":
        fail("protection.direct_task_actor_writes")
    if not isinstance(protection["verified_at"], str) or RFC3339_UTC.fullmatch(
        protection["verified_at"]
    ) is None:
        fail("protection.verified_at")
    text(protection["evidence_ref"], "protection.evidence_ref", ascii_only=True)
    text(approval["actor"], "actor", ascii_only=True)
    if not isinstance(approval["approved_at"], str) or RFC3339_UTC.fullmatch(
        approval["approved_at"]
    ) is None:
        fail("approved_at")
    text(approval["source_ref"], "source_ref", ascii_only=True)
    approval["proposed_descriptor"] = descriptor
    approval["protection"] = protection
    return approval


def parse_authority_approval(raw: bytes) -> dict[str, Any]:
    receipt = validate_authority_approval(strict_load(raw, "bootstrap-authority-approval"))
    if raw != canonical_bytes(receipt):
        fail("bootstrap-authority-approval", "canonical-source-required")
    return {
        "receipt": receipt,
        "object_digest": canonical_digest(receipt),
        "source_digest": canonical_digest(raw, raw=True),
    }


def validate_reviewed_overlay(value: Any) -> dict[str, Any]:
    receipt = exact_object(value, REVIEWED_OVERLAY_FIELDS, "reviewed-overlay")
    if receipt["contract_version"] != "workbench-kit-reviewed-overlay/v1":
        fail("reviewed-overlay.contract_version")
    text(receipt["review_id"], "reviewed-overlay.review_id", ascii_only=True)
    try:
        content = base64.b64decode(receipt["content_base64"], validate=True)
    except (TypeError, ValueError, binascii.Error) as error:
        raise ContractError("contract-invalid", "reviewed-overlay.content_base64") from error
    if base64.b64encode(content).decode("ascii") != receipt["content_base64"]:
        fail("reviewed-overlay.content_base64")
    try:
        content.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise ContractError("contract-invalid", "reviewed-overlay.content") from error
    if not content or not content.endswith(b"\n"):
        fail("reviewed-overlay.content")
    if digest(receipt["content_digest"], "reviewed-overlay.content_digest") != canonical_digest(
        content, raw=True
    ):
        fail("reviewed-overlay.content_digest")
    text(receipt["actor"], "reviewed-overlay.actor", ascii_only=True)
    if not isinstance(receipt["reviewed_at"], str) or RFC3339_UTC.fullmatch(
        receipt["reviewed_at"]
    ) is None:
        fail("reviewed-overlay.reviewed_at")
    text(receipt["source_ref"], "reviewed-overlay.source_ref", ascii_only=True)
    return receipt


def parse_reviewed_overlay(raw: bytes) -> dict[str, Any]:
    receipt = validate_reviewed_overlay(strict_load(raw, "reviewed-overlay"))
    content = decode_canonical_base64(
        receipt["content_base64"], "reviewed-overlay.content_base64"
    )
    return {
        "receipt": receipt,
        "object_digest": canonical_digest(receipt),
        "source_digest": canonical_digest(raw, raw=True),
        "content": content,
    }


def decode_canonical_base64(value: Any, ref: str) -> bytes:
    try:
        raw = base64.b64decode(value, validate=True)
    except (TypeError, ValueError, binascii.Error) as error:
        raise ContractError("contract-invalid", ref) from error
    if base64.b64encode(raw).decode("ascii") != value:
        fail(ref)
    return raw


def validate_generator_receipt(value: Any) -> dict[str, Any]:
    receipt = exact_object(value, GENERATOR_FIELDS, "generator-receipt")
    if receipt["contract_version"] != "workbench-kit-generator-receipt/v1":
        fail("generator-receipt.contract_version")
    text(receipt["receipt_id"], "generator-receipt.receipt_id", ascii_only=True)
    if receipt["generator_id"] != "workbench-kit:generate-workbench":
        fail("generator-receipt.generator_id")
    if not isinstance(receipt["generator_version"], str) or SEMVER.fullmatch(
        receipt["generator_version"]
    ) is None:
        fail("generator-receipt.generator_version")
    oid(receipt["source_revision"], "generator-receipt.source_revision")
    if receipt["compose_contract"] != "workbench-kit-compose/v1":
        fail("generator-receipt.compose_contract")
    header = decode_canonical_base64(receipt["header_base64"], "generator-receipt.header")
    core = decode_canonical_base64(receipt["core_base64"], "generator-receipt.core")
    separator = decode_canonical_base64(
        receipt["separator_base64"], "generator-receipt.separator"
    )
    if not header or not core or not separator:
        fail("generator-receipt.compose-bytes")
    if digest(receipt["core_digest"], "generator-receipt.core_digest") != canonical_digest(
        core, raw=True
    ):
        fail("generator-receipt.core_digest")
    settings = exact_object(
        receipt["settings_owned"], SETTINGS_OWNED_FIELDS, "generator-receipt.settings_owned"
    )
    expected_marketplace = {
        "source": {"source": "github", "repo": "YOOGOMJA/workbench-kit"}
    }
    if settings["marketplace"] != expected_marketplace or settings["plugin_enabled"] is not True:
        fail("generator-receipt.settings_owned")
    nodes = []
    for item in array(receipt["generated_nodes"], "generator-receipt.generated_nodes"):
        node = exact_object(item, GENERATED_NODE_FIELDS, "generator-receipt.generated_node")
        validate_relative_path(node["path"])
        if node["node_type"] == "file" and node["mode"] == "100644":
            pass
        elif (
            node["path"] == "CLAUDE.md"
            and node["node_type"] == "symlink"
            and node["mode"] == "120000"
        ):
            pass
        else:
            fail("generator-receipt.generated_node")
        nodes.append(node)
    validate_path_set([item["path"] for item in nodes], "generator-receipt.generated_nodes")
    nodes_by_path = {item["path"]: item for item in nodes}
    if nodes_by_path.get("AGENTS.md") != {
        "path": "AGENTS.md", "node_type": "file", "mode": "100644"
    } or nodes_by_path.get(".claude/settings.json") != {
        "path": ".claude/settings.json", "node_type": "file", "mode": "100644"
    }:
        fail("generator-receipt.generated_nodes")
    claude = nodes_by_path.get("CLAUDE.md")
    if claude not in (
        {"path": "CLAUDE.md", "node_type": "file", "mode": "100644"},
        {"path": "CLAUDE.md", "node_type": "symlink", "mode": "120000"},
    ):
        fail("generator-receipt.generated_nodes")
    receipt["settings_owned"] = settings
    receipt["generated_nodes"] = nodes
    if digest(receipt["receipt_digest"], "generator-receipt.receipt_digest") != canonical_digest(
        receipt, null_field="receipt_digest"
    ):
        fail("generator-receipt.receipt_digest")
    return receipt


def validate_link_target(path: str, target: Any, ref: str) -> str:
    if (
        not isinstance(target, str)
        or not target
        or "\x00" in target
        or "\\" in target
        or target.endswith("/")
        or "//" in target
        or unicodedata.normalize("NFC", target) != target
    ):
        fail(ref, "symlink-target-invalid")
    pure = pathlib.PurePosixPath(target)
    if pure.is_absolute():
        fail(ref, "symlink-target-invalid")
    resolved = list(pathlib.PurePosixPath(path).parent.parts)
    for part in pure.parts:
        if part in ("", "."):
            fail(ref, "symlink-target-invalid")
        if part == "..":
            if not resolved:
                fail(ref, "symlink-target-escape")
            resolved.pop()
        else:
            resolved.append(part)
    if not resolved:
        fail(ref, "symlink-target-invalid")
    validate_relative_path("/".join(resolved))
    return target


def validate_legacy_node(value: Any, ref: str) -> dict[str, Any]:
    node = exact_object(value, LEGACY_NODE_FIELDS, ref)
    validate_relative_path(node["path"])
    if node["node_type"] == "file":
        if node["mode"] not in ("100644", "100755") or node["link_target"] is not None:
            fail(ref)
    elif node["node_type"] == "symlink":
        if node["mode"] != "120000" or not isinstance(node["link_target"], str):
            fail(ref)
        validate_link_target(node["path"], node["link_target"], f"{ref}.link_target")
    else:
        fail(ref)
    digest(node["digest"], f"{ref}.digest")
    return node


def validate_preserved(value: Any, ref: str = "preserved") -> list[dict[str, Any]]:
    preserved = [
        validate_legacy_node(item, f"{ref}.node") for item in array(value, ref)
    ]
    validate_path_set(
        [item["path"] for item in preserved], ref, reject_ancestors=True
    )
    return preserved


def validate_equivalence_receipt(value: Any) -> dict[str, Any]:
    receipt = exact_object(value, EQUIVALENCE_FIELDS, "equivalence-receipt")
    if receipt["contract_version"] != "workbench-plugin-equivalence/v1":
        fail("equivalence-receipt.contract_version")
    text(receipt["receipt_id"], "equivalence-receipt.receipt_id", ascii_only=True)
    replacement = exact_object(
        receipt["replacement_plugin"], REPLACEMENT_PLUGIN_FIELDS, "replacement_plugin"
    )
    if replacement["plugin_name"] != "workbench":
        fail("replacement_plugin.plugin_name")
    if not isinstance(replacement["plugin_version"], str) or SEMVER.fullmatch(
        replacement["plugin_version"]
    ) is None:
        fail("replacement_plugin.plugin_version")
    oid(replacement["source_revision"], "replacement_plugin.source_revision")
    digest(replacement["plugin_manifest_digest"], "replacement_plugin.plugin_manifest_digest")
    text(replacement["source_ref"], "replacement_plugin.source_ref", ascii_only=True)

    public = exact_object(receipt["public_contract"], PUBLIC_CONTRACT_FIELDS, "public_contract")
    if public["contract_version"] != "workbench-contract/v1" or public["engine_name"] != "workbench":
        fail("public_contract")
    if public["engine_version"] != replacement["plugin_version"]:
        fail("public_contract.engine_version")
    digest(public["supported_object_digest"], "public_contract.supported_object_digest")
    capabilities = array(public["capabilities"], "public_contract.capabilities")
    if not capabilities or not all(isinstance(item, str) and item for item in capabilities):
        fail("public_contract.capabilities")
    if capabilities != sorted(capabilities) or len(capabilities) != len(set(capabilities)):
        fail("public_contract.capabilities")
    required = array(receipt["required_capabilities"], "required_capabilities")
    if (
        not required
        or not all(isinstance(item, str) and item for item in required)
        or required != sorted(required)
        or len(required) != len(set(required))
        or not set(required).issubset(capabilities)
    ):
        fail("required_capabilities")

    legacy_source = exact_object(receipt["legacy_source"], LEGACY_SOURCE_FIELDS, "legacy_source")
    text(legacy_source["source_ref"], "legacy_source.source_ref", ascii_only=True)
    oid(legacy_source["source_revision"], "legacy_source.source_revision")
    roots = array(receipt["allowed_roots"], "allowed_roots")
    for root in roots:
        validate_relative_path(root)
    validate_path_set(roots, "allowed_roots", reject_ancestors=True)
    if not roots:
        fail("allowed_roots")

    removable = [
        validate_legacy_node(item, "removable_node")
        for item in array(receipt["removable_nodes"], "removable_nodes")
    ]
    validate_path_set([item["path"] for item in removable], "removable_nodes", reject_ancestors=True)
    if not removable:
        fail("removable_nodes")
    for node in removable:
        if not any(node["path"].startswith(root + "/") for root in roots):
            fail("removable_nodes")
    discovery = [
        validate_legacy_node(item, "discovery_link")
        for item in array(receipt["discovery_links"], "discovery_links")
    ]
    validate_path_set([item["path"] for item in discovery], "discovery_links")
    removable_by_path = {item["path"]: item for item in removable}
    for link in discovery:
        if link["node_type"] != "symlink" or removable_by_path.get(link["path"]) != link:
            fail("discovery_links")

    manifest = {
        "contract_version": "workbench-legacy-engine-manifest/v1",
        "source_ref": legacy_source["source_ref"],
        "source_revision": legacy_source["source_revision"],
        "allowed_roots": roots,
        "removable_nodes": removable,
        "discovery_links": discovery,
    }
    if digest(receipt["legacy_manifest_digest"], "legacy_manifest_digest") != canonical_digest(
        manifest
    ):
        fail("legacy_manifest_digest")

    evidence = []
    for item in array(receipt["verification_evidence"], "verification_evidence"):
        row = exact_object(item, EVIDENCE_FIELDS, "verification_evidence.row")
        text(row["evidence_id"], "verification_evidence.evidence_id", ascii_only=True)
        if row["kind"] not in ("manifest-audit", "contract-test", "integration-test"):
            fail("verification_evidence.kind")
        text(row["source_ref"], "verification_evidence.source_ref", ascii_only=True)
        oid(row["source_revision"], "verification_evidence.source_revision")
        digest(row["digest"], "verification_evidence.digest")
        evidence.append(row)
    if evidence != sorted(evidence, key=lambda row: (row["kind"], row["evidence_id"])):
        fail("verification_evidence")
    if len({row["evidence_id"] for row in evidence}) != len(evidence) or {
        row["kind"] for row in evidence
    } != {"manifest-audit", "contract-test", "integration-test"}:
        fail("verification_evidence")

    receipt["replacement_plugin"] = replacement
    public["capabilities"] = capabilities
    receipt["public_contract"] = public
    receipt["required_capabilities"] = required
    receipt["legacy_source"] = legacy_source
    receipt["allowed_roots"] = roots
    receipt["removable_nodes"] = removable
    receipt["discovery_links"] = discovery
    receipt["verification_evidence"] = evidence
    return receipt


def validate_removal_approval(value: Any) -> dict[str, Any]:
    approval = exact_object(value, REMOVAL_APPROVAL_FIELDS, "removal-approval")
    if approval["contract_version"] != "workbench-kit-removal-approval/v1":
        fail("removal-approval.contract_version")
    for field in ("approval_id", "equivalence_receipt_id", "actor", "source_ref"):
        text(approval[field], f"removal-approval.{field}", ascii_only=True)
    digest(approval["equivalence_receipt_digest"], "removal-approval.equivalence_digest")
    digest(approval["approved_plan_basis_digest"], "removal-approval.plan_basis_digest")
    if not isinstance(approval["approved_at"], str) or RFC3339_UTC.fullmatch(
        approval["approved_at"]
    ) is None:
        fail("removal-approval.approved_at")
    return approval


def validate_engine_manifest(value: Any) -> dict[str, Any]:
    manifest = exact_object(value, ENGINE_MANIFEST_FIELDS, "engine_manifest")
    if manifest["contract_version"] != "workbench-plugin-manifest/v1":
        fail("engine_manifest.contract_version")
    if manifest["command"] != "engine-manifest show":
        fail("engine_manifest.command")
    for field in (
        "object_digest", "source_digest", "content_revision", "manifest_digest"
    ):
        digest(manifest[field], f"engine_manifest.{field}")
    return manifest


def validate_relative_path(path: Any, *, allow_dot: bool = False) -> str:
    if not isinstance(path, str) or not path or "\x00" in path or "\\" in path:
        fail("path", "path-invalid")
    if unicodedata.normalize("NFC", path) != path:
        fail(path, "path-invalid")
    if path == ".":
        if allow_dot:
            return path
        fail(path, "path-invalid")
    pure = pathlib.PurePosixPath(path)
    if (
        pure.is_absolute()
        or pure.as_posix() != path
        or path.endswith("/")
        or "//" in path
        or any(part in ("", ".", "..") for part in pure.parts)
    ):
        fail(path, "path-invalid")
    folded_parts = tuple(part.casefold() for part in pure.parts)
    if folded_parts[0] in RESERVED_PREFIXES or folded_parts[:2] == (
        "task", "codebases"
    ):
        fail(path, "path-reserved")
    return path


def node_digest(
    node_type: str,
    mode: str,
    *,
    content: bytes | None = None,
    link_target: str | None = None,
) -> str:
    if node_type == "file":
        if mode not in ("100644", "100755") or content is None or link_target is not None:
            fail("node", "node-invalid")
        payload = (
            "workbench-kit-node/v1\n"
            f"node_type\tfile\nmode\t{mode}\ncontent_length\t{len(content)}\n"
        ).encode("ascii") + content
    elif node_type == "symlink":
        if mode != "120000" or content is not None or not isinstance(link_target, str):
            fail("node", "node-invalid")
        target = link_target.encode("utf-8")
        if not target or b"\x00" in target:
            fail("node", "node-invalid")
        payload = (
            "workbench-kit-node/v1\n"
            f"node_type\tsymlink\nmode\t120000\ntarget_length\t{len(target)}\n"
        ).encode("ascii") + target
    elif node_type == "directory":
        if re.fullmatch(r"04[0-7]{4}", mode) is None or content is not None or link_target is not None:
            fail("node", "node-invalid")
        payload = (
            "workbench-kit-node/v1\n"
            f"node_type\tdirectory\nmode\t{mode}\n"
        ).encode("ascii")
    else:
        fail("node", "node-invalid")
    return canonical_digest(payload, raw=True)


def validate_receipt_input(
    value: Any,
    ref: str,
    receipt_validator: Any,
    *,
    canonical_source_required: bool = False,
) -> dict[str, Any]:
    projection = exact_object(value, RECEIPT_INPUT_FIELDS, ref)
    receipt = receipt_validator(projection["receipt"])
    if digest(projection["object_digest"], f"{ref}.object_digest") != canonical_digest(receipt):
        fail(f"{ref}.object_digest")
    source_digest = digest(projection["source_digest"], f"{ref}.source_digest")
    if canonical_source_required and source_digest != canonical_digest(
        canonical_bytes(receipt), raw=True
    ):
        fail(f"{ref}.source_digest")
    projection["receipt"] = receipt
    return projection


def decode_artifact(value: Any) -> tuple[dict[str, Any], bytes | None]:
    artifact = exact_object(value, ARTIFACT_FIELDS, "artifact")
    validate_relative_path(artifact["path"])
    text(artifact["source_ref"], "artifact.source_ref", ascii_only=True)
    source_digest = digest(artifact["source_digest"], "artifact.source_digest")
    if artifact["node_type"] == "file":
        if artifact["mode"] not in ("100644", "100755") or artifact["link_target"] is not None:
            fail("artifact")
        try:
            content = base64.b64decode(artifact["content_base64"], validate=True)
        except (TypeError, ValueError, binascii.Error) as error:
            raise ContractError("contract-invalid", "artifact.content_base64") from error
        if base64.b64encode(content).decode("ascii") != artifact["content_base64"]:
            fail("artifact.content_base64")
        if source_digest != canonical_digest(content, raw=True):
            fail("artifact.source_digest")
        return artifact, content
    if artifact["node_type"] == "symlink":
        if (
            artifact["mode"] != "120000"
            or artifact["content_base64"] is not None
            or not isinstance(artifact["link_target"], str)
            or not artifact["link_target"]
        ):
            fail("artifact")
        validate_link_target(
            artifact["path"], artifact["link_target"], "artifact.link_target"
        )
        target = artifact["link_target"].encode("utf-8")
        if source_digest != canonical_digest(target, raw=True):
            fail("artifact.source_digest")
        return artifact, None
    fail("artifact.node_type")


def validate_parent(value: Any) -> dict[str, Any]:
    parent = exact_object(value, PARENT_FIELDS, "parent_directory")
    validate_relative_path(parent["path"])
    if parent["after_type"] != "directory" or not isinstance(parent["after_mode"], str):
        fail("parent_directory.after")
    if re.fullmatch(r"04[0-7]{4}", parent["after_mode"]) is None:
        fail("parent_directory.after_mode")
    if parent["before_type"] is None:
        if parent["before_mode"] is not None or parent["after_mode"] != "040755":
            fail("parent_directory.before")
    elif parent["before_type"] == "directory":
        if (
            not isinstance(parent["before_mode"], str)
            or re.fullmatch(r"04[0-7]{4}", parent["before_mode"]) is None
            or parent["before_mode"] != parent["after_mode"]
        ):
            fail("parent_directory.before_mode")
    else:
        fail("parent_directory.before_type")
    return parent


def validate_operation(value: Any) -> dict[str, Any]:
    operation = exact_object(value, OPERATION_FIELDS, "operation")
    validate_relative_path(operation["path"])
    if operation["op"] not in ("create", "update", "remove"):
        fail("operation.op")
    before = (
        operation["before_type"], operation["before_mode"], operation["before_digest"]
    )
    after = (operation["after_type"], operation["after_mode"], operation["after_digest"])
    if operation["op"] == "create":
        if before != (None, None, None) or None in after:
            fail("operation.create")
        if operation["artifact_source_digest"] is None or operation["equivalence_receipt_ref"] is not None:
            fail("operation.create")
    elif operation["op"] == "update":
        if None in before or None in after:
            fail("operation.update")
        if operation["artifact_source_digest"] is None or operation["equivalence_receipt_ref"] is not None:
            fail("operation.update")
    else:
        if None in before or after != (None, None, None):
            fail("operation.remove")
        if operation["artifact_source_digest"] is not None:
            fail("operation.remove")
        text(operation["equivalence_receipt_ref"], "operation.equivalence_receipt_ref")
    for field in ("before_digest", "after_digest", "artifact_source_digest"):
        digest(operation[field], f"operation.{field}", nullable=True)
    for field in ("before_type", "after_type"):
        if operation[field] is not None and operation[field] not in ("file", "symlink"):
            fail(f"operation.{field}")
    for field, node_type in (("before_mode", operation["before_type"]), ("after_mode", operation["after_type"])):
        mode = operation[field]
        if node_type == "file" and mode not in ("100644", "100755"):
            fail(f"operation.{field}")
        if node_type == "symlink" and mode != "120000":
            fail(f"operation.{field}")
    return operation


def validate_path_set(paths: list[str], ref: str, *, reject_ancestors: bool = False) -> None:
    if paths != sorted(paths):
        fail(ref, "path-order-invalid")
    folded = [unicodedata.normalize("NFC", path).casefold() for path in paths]
    if len(paths) != len(set(paths)) or len(folded) != len(set(folded)):
        fail(ref, "path-collision")
    if reject_ancestors:
        ordered_folded = sorted(folded)
        for index, path in enumerate(ordered_folded):
            prefix = path + "/"
            if any(
                other.startswith(prefix) for other in ordered_folded[index + 1 :]
            ):
                fail(ref, "path-overlap")


def validate_language(value: Any) -> dict[str, Any]:
    language = exact_object(value, LANGUAGE_FIELDS, "language")
    if language["contract_version"] != "workbench-kit-language-decision/v1":
        fail("language.contract_version")
    tag = text(language["tag"], "language.tag", ascii_only=True)
    if BCP47.fullmatch(tag) is None:
        fail("language.tag")
    if language["source"] not in ("explicit-cli", "workspace-profile", "generation-input"):
        fail("language.source")
    text(language["source_ref"], "language.source_ref", ascii_only=True)
    if digest(language["digest"], "language.digest") != canonical_digest(
        language, null_field="digest"
    ):
        fail("language.digest")
    return language


def validate_receipt_artifacts(value: Any, ref: str) -> list[dict[str, Any]]:
    artifacts = []
    for item in array(value, ref):
        artifact = exact_object(item, RECEIPT_ARTIFACT_FIELDS, f"{ref}.artifact")
        validate_relative_path(artifact["path"])
        if artifact["node_type"] == "file":
            if artifact["mode"] not in ("100644", "100755"):
                fail(f"{ref}.artifact.mode")
        elif artifact["node_type"] == "symlink":
            if artifact["mode"] != "120000":
                fail(f"{ref}.artifact.mode")
        else:
            fail(f"{ref}.artifact.node_type")
        digest(artifact["digest"], f"{ref}.artifact.digest")
        artifacts.append(artifact)
    validate_path_set([item["path"] for item in artifacts], ref, reject_ancestors=True)
    return artifacts


def validate_generation_receipt(value: Any) -> dict[str, Any]:
    receipt = exact_object(value, GENERATION_RECEIPT_FIELDS, "generation-receipt")
    if receipt["contract_version"] != "workbench-kit-generation-receipt/v1":
        fail("generation-receipt.contract_version")
    digest(receipt["generator_receipt_digest"], "generation-receipt.generator")
    home = text(receipt["workspace_home"], "generation-receipt.workspace_home")
    if HOME.fullmatch(home) is None or home.isdigit():
        fail("generation-receipt.workspace_home")
    language = validate_language(receipt["language"])
    if (
        language["source"] != "generation-input"
        or language["source_ref"] != "generator:language"
    ):
        fail("generation-receipt.language")
    digest(
        receipt["authority_descriptor_digest"],
        "generation-receipt.authority_descriptor_digest",
    )
    embedded = exact_object(
        receipt["embedded_engine"],
        GENERATION_EMBEDDED_FIELDS,
        "generation-receipt.embedded_engine",
    )
    if embedded != {"state": "absent", "equivalence_receipt_digest": None}:
        fail("generation-receipt.embedded_engine")
    artifacts = validate_receipt_artifacts(
        receipt["artifacts"], "generation-receipt.artifacts"
    )
    if {item["path"] for item in artifacts} != BASE_RECEIPT_ARTIFACT_PATHS:
        fail("generation-receipt.artifacts")
    receipt["language"] = language
    receipt["embedded_engine"] = embedded
    receipt["artifacts"] = artifacts
    if digest(
        receipt["candidate_basis_digest"], "generation-receipt.candidate_basis_digest"
    ) != canonical_digest(receipt, null_field="candidate_basis_digest"):
        fail("generation-receipt.candidate_basis_digest")
    return receipt


def validate_migration_receipt(value: Any) -> dict[str, Any]:
    receipt = exact_object(value, MIGRATION_RECEIPT_FIELDS, "migration-receipt")
    if receipt["contract_version"] != "workbench-kit-migration-receipt/v1":
        fail("migration-receipt.contract_version")
    oid(receipt["source_revision"], "migration-receipt.source_revision")
    if not isinstance(receipt["source_tree_digest"], str) or TREE_DIGEST.fullmatch(
        receipt["source_tree_digest"]
    ) is None:
        fail("migration-receipt.source_tree_digest")
    planner = exact_object(receipt["planner"], PLANNER_FIELDS, "migration-receipt.planner")
    if planner["contract_version"] != "workbench-kit-planner/v1":
        fail("migration-receipt.planner.contract_version")
    if not isinstance(planner["plugin_version"], str) or SEMVER.fullmatch(
        planner["plugin_version"]
    ) is None:
        fail("migration-receipt.planner.plugin_version")
    oid(planner["planner_revision"], "migration-receipt.planner.planner_revision")
    task = exact_object(
        receipt["migration_task"], MIGRATION_TASK_FIELDS, "migration-receipt.migration_task"
    )
    text(task["task_id"], "migration-receipt.migration_task.task_id")
    text(task["claim_id"], "migration-receipt.migration_task.claim_id")
    if task["task_contract"] != "workbench-task/v1":
        fail("migration-receipt.migration_task.task_contract")
    text(task["branch"], "migration-receipt.migration_task.branch")
    digest(task["index_digest"], "migration-receipt.migration_task.index_digest")
    language = validate_language(receipt["language"])
    for field in (
        "authority_approval_object_digest",
        "authority_approval_source_digest",
        "legacy_inventory_object_digest",
        "legacy_inventory_source_digest",
        "active_v1_tasks_digest",
    ):
        digest(receipt[field], f"migration-receipt.{field}")
    reviewed_pair = (
        digest(
            receipt["reviewed_overlay_object_digest"],
            "migration-receipt.reviewed_overlay_object_digest",
            nullable=True,
        ),
        digest(
            receipt["reviewed_overlay_source_digest"],
            "migration-receipt.reviewed_overlay_source_digest",
            nullable=True,
        ),
    )
    if (reviewed_pair[0] is None) != (reviewed_pair[1] is None):
        fail("migration-receipt.reviewed_overlay")
    embedded = validate_embedded(
        receipt["embedded_engine"], "migration-receipt.embedded_engine"
    )
    artifacts = validate_receipt_artifacts(
        receipt["artifacts"], "migration-receipt.artifacts"
    )
    artifact_paths = {item["path"] for item in artifacts}
    expected_paths = set(BASE_RECEIPT_ARTIFACT_PATHS)
    if reviewed_pair[0] is not None:
        expected_paths.add("AGENTS.overlay.md")
    if artifact_paths != expected_paths:
        fail("migration-receipt.artifacts")
    receipt["planner"] = planner
    receipt["migration_task"] = task
    receipt["language"] = language
    receipt["embedded_engine"] = embedded
    receipt["artifacts"] = artifacts
    if digest(
        receipt["candidate_basis_digest"], "migration-receipt.candidate_basis_digest"
    ) != canonical_digest(receipt, null_field="candidate_basis_digest"):
        fail("migration-receipt.candidate_basis_digest")
    return receipt


def validate_active_tasks(value: Any) -> dict[str, Any]:
    projection = exact_object(value, ACTIVE_FIELDS, "active_v1_tasks")
    if projection["contract_version"] != "workbench-kit-active-v1-tasks/v1":
        fail("active_v1_tasks.contract_version")
    digest(projection["source_inventory_object_digest"], "active_v1_tasks.source")
    tasks = array(projection["tasks"], "active_v1_tasks.tasks")
    normalized_tasks = []
    identities = []
    for item in tasks:
        task = exact_object(item, ACTIVE_TASK_FIELDS, "active_v1_tasks.task")
        if task["source"] != "legacy-inventory:homes[].claims":
            fail("active_v1_tasks.task.source")
        home = text(task["home"], "active_v1_tasks.task.home", ascii_only=True)
        if HOME.fullmatch(home) is None or home.isdigit():
            fail("active_v1_tasks.task.home")
        text(task["claim_id"], "active_v1_tasks.task.claim_id")
        text(task["task_claim_id"], "active_v1_tasks.task.task_claim_id")
        if task["task_contract"] != "workbench-task/v1":
            fail("active_v1_tasks.task.task_contract")
        if not isinstance(task["issue"], int) or isinstance(task["issue"], bool) or task["issue"] <= 0:
            fail("active_v1_tasks.task.issue")
        if task["parent"] is not None and (
            not isinstance(task["parent"], int)
            or isinstance(task["parent"], bool)
            or task["parent"] <= 0
        ):
            fail("active_v1_tasks.task.parent")
        text(task["branch"], "active_v1_tasks.task.branch")
        text(task["lifecycle_state"], "active_v1_tasks.task.lifecycle_state")
        digest(task["lifecycle_digest"], "active_v1_tasks.task.lifecycle_digest")
        oid(task["source_revision"], "active_v1_tasks.task.source_revision")
        oid(task["pr_head_revision"], "active_v1_tasks.task.pr_head_revision", nullable=True)
        if task["ancestry_complete"] is not True:
            fail("active_v1_tasks.task.ancestry_complete")
        identities.append((task["home"], task["claim_id"]))
        normalized_tasks.append(task)
    if identities != sorted(identities) or len(identities) != len(set(identities)):
        fail("active_v1_tasks.tasks")
    projection["tasks"] = normalized_tasks
    if digest(projection["digest"], "active_v1_tasks.digest") != canonical_digest(
        projection, null_field="digest"
    ):
        fail("active_v1_tasks.digest")
    return projection


def validate_provenance(value: Any, ref: str) -> dict[str, Any]:
    provenance = exact_object(value, PROVENANCE_FIELDS, ref)
    if provenance["state"] not in ("absent", "valid", "stale", "invalid"):
        fail(f"{ref}.state")
    if provenance["state"] == "absent":
        if any(provenance[field] is not None for field in ("kind", "receipt_digest", "ref")):
            fail(ref)
    else:
        if provenance["kind"] not in ("generation", "migration"):
            fail(f"{ref}.kind")
        text(provenance["ref"], f"{ref}.ref")
        digest(
            provenance["receipt_digest"],
            f"{ref}.receipt_digest",
            nullable=provenance["state"] == "invalid",
        )
    return provenance


def validate_plan(value: Any) -> dict[str, Any]:
    plan = exact_object(value, PLAN_FIELDS, "upgrade-plan")
    if plan["contract_version"] != "workbench-kit-upgrade-plan/v1":
        fail("upgrade-plan.contract_version")
    if plan["classification_before"] not in CLASSIFICATIONS:
        fail("classification_before")
    if plan["target_classification"] not in CLASSIFICATIONS:
        fail("target_classification")

    embedded = exact_object(plan["embedded_engine"], EMBEDDED_FIELDS, "embedded_engine")
    if embedded["before"] not in EMBEDDED_STATES or embedded["after"] not in EMBEDDED_STATES:
        fail("embedded_engine")
    digest(
        embedded["equivalence_receipt_digest"],
        "embedded_engine.equivalence_receipt_digest",
        nullable=True,
    )
    if (
        "present-verified" in (embedded["before"], embedded["after"])
        and embedded["equivalence_receipt_digest"] is None
    ):
        fail("embedded_engine.equivalence_receipt_digest")

    workspace = exact_object(plan["workspace"], WORKSPACE_FIELDS, "workspace")
    root = pathlib.PurePath(text(workspace["root"], "workspace.root"))
    if not root.is_absolute():
        fail("workspace.root")
    oid(workspace["source_revision"], "workspace.source_revision")
    oid(workspace["default_revision"], "workspace.default_revision")
    if not isinstance(workspace["source_tree_digest"], str) or TREE_DIGEST.fullmatch(
        workspace["source_tree_digest"]
    ) is None:
        fail("workspace.source_tree_digest")
    migration_task = exact_object(
        workspace["migration_task"], MIGRATION_TASK_FIELDS, "workspace.migration_task"
    )
    text(migration_task["task_id"], "workspace.migration_task.task_id")
    text(migration_task["claim_id"], "workspace.migration_task.claim_id")
    if migration_task["task_contract"] not in ("workbench-task/v1", "workbench-task/v2"):
        fail("workspace.migration_task.task_contract")
    text(migration_task["branch"], "workspace.migration_task.branch")
    digest(migration_task["index_digest"], "workspace.migration_task.index_digest")
    workspace["migration_task"] = migration_task

    planner = exact_object(plan["planner"], PLANNER_FIELDS, "planner")
    if planner["contract_version"] != "workbench-kit-planner/v1":
        fail("planner.contract_version")
    if not isinstance(planner["plugin_version"], str) or SEMVER.fullmatch(
        planner["plugin_version"]
    ) is None:
        fail("planner.plugin_version")
    oid(planner["planner_revision"], "planner.planner_revision")

    doctor = exact_object(plan["doctor"], DOCTOR_FIELDS, "doctor")
    if doctor["contract_version"] != "workbench-doctor/v1":
        fail("doctor.contract_version")
    boolean(doctor["ready"], "doctor.ready")
    for field in ("object_digest", "source_digest", "writer_coordination_digest"):
        digest(doctor[field], f"doctor.{field}")

    legacy = exact_object(plan["legacy_inventory"], LEGACY_FIELDS, "legacy_inventory")
    if legacy["contract_version"] != "workbench-legacy-inventory/v1":
        fail("legacy_inventory.contract_version")
    if legacy["command"] not in ("show", "bootstrap-show"):
        fail("legacy_inventory.command")
    for field in ("object_digest", "source_digest", "home_set_digest"):
        digest(legacy[field], f"legacy_inventory.{field}")
    oid(legacy["authority_revision"], "legacy_inventory.authority_revision")
    if legacy["complete"] is not True:
        fail("legacy_inventory.complete")
    if legacy["authority_revision"] != workspace["default_revision"]:
        fail("legacy_inventory.authority_revision")

    inputs = exact_object(plan["inputs"], INPUTS_FIELDS, "inputs")
    inputs["language"] = validate_language(inputs["language"])
    if inputs["bootstrap_authority_approval"] is not None:
        inputs["bootstrap_authority_approval"] = validate_receipt_input(
            inputs["bootstrap_authority_approval"],
            "inputs.bootstrap_authority_approval",
            validate_authority_approval,
            canonical_source_required=True,
        )
        if (
            inputs["bootstrap_authority_approval"]["receipt"]["default_revision"]
            != workspace["default_revision"]
        ):
            fail("inputs.bootstrap_authority_approval.default_revision")
    if inputs["reviewed_overlay"] is not None:
        inputs["reviewed_overlay"] = validate_receipt_input(
            inputs["reviewed_overlay"],
            "inputs.reviewed_overlay",
            validate_reviewed_overlay,
        )
    if (legacy["command"] == "bootstrap-show") != (
        inputs["bootstrap_authority_approval"] is not None
    ):
        fail("inputs.bootstrap_authority_approval")
    engine_manifest = (
        validate_engine_manifest(plan["engine_manifest"])
        if plan["engine_manifest"] is not None
        else None
    )
    plugin_equivalence = (
        validate_receipt_input(
            plan["plugin_equivalence"],
            "plugin_equivalence",
            validate_equivalence_receipt,
        )
        if plan["plugin_equivalence"] is not None
        else None
    )
    removal_basis_digest = digest(
        plan["removal_plan_basis_digest"],
        "removal_plan_basis_digest",
        nullable=True,
    )
    removal_approval = (
        validate_receipt_input(
            plan["removal_approval"],
            "removal_approval",
            validate_removal_approval,
        )
        if plan["removal_approval"] is not None
        else None
    )

    blockers = []
    for item in array(plan["blockers"], "blockers"):
        blocker = exact_object(item, BLOCKER_FIELDS, "blocker")
        text(blocker["code"], "blocker.code")
        text(blocker["ref"], "blocker.ref")
        blockers.append(blocker)
    blocker_order = [(item["code"], item["ref"]) for item in blockers]
    if blocker_order != sorted(blocker_order):
        fail("blockers")

    preserved = validate_preserved(plan["preserved"])
    parents = [validate_parent(item) for item in array(plan["parent_directories"], "parent_directories")]
    parent_paths = [item["path"] for item in parents]
    if parent_paths != sorted(parent_paths, key=lambda path: (path.count("/"), path)):
        fail("parent_directories", "path-order-invalid")
    validate_path_set(sorted(parent_paths), "parent_directories")

    artifacts_with_content = [decode_artifact(item) for item in array(plan["artifacts"], "artifacts")]
    artifacts = [item[0] for item in artifacts_with_content]
    artifact_content = {item[0]["path"]: item[1] for item in artifacts_with_content}
    validate_path_set([item["path"] for item in artifacts], "artifacts")
    operations = [validate_operation(item) for item in array(plan["operations"], "operations")]
    operation_paths = [item["path"] for item in operations]
    if operations != sorted(operations, key=lambda item: (item["path"], item["op"])):
        fail("operations", "path-order-invalid")
    validate_path_set(operation_paths, "operations", reject_ancestors=True)
    expected_parent_paths = sorted(
        {
            "/".join(pathlib.PurePosixPath(path).parts[:index])
            for path in operation_paths
            for index in range(1, len(pathlib.PurePosixPath(path).parts))
        },
        key=lambda path: (path.count("/"), path),
    )
    if parent_paths != expected_parent_paths:
        fail("parent_directories", "parent-operation-mismatch")
    for operation_path in operation_paths:
        folded_operation = operation_path.casefold()
        for preserved_node in preserved:
            folded_preserved = preserved_node["path"].casefold()
            if (
                folded_operation == folded_preserved
                or folded_operation.startswith(folded_preserved + "/")
                or folded_preserved.startswith(folded_operation + "/")
            ):
                fail("preserved", "preserved-operation-overlap")

    artifact_by_path = {item["path"]: item for item in artifacts}
    modifying = [item for item in operations if item["op"] in ("create", "update")]
    if set(artifact_by_path) != {item["path"] for item in modifying}:
        fail("artifacts", "artifact-operation-mismatch")
    for operation in modifying:
        artifact = artifact_by_path[operation["path"]]
        content = artifact_content[operation["path"]]
        expected_after = node_digest(
            artifact["node_type"],
            artifact["mode"],
            content=content,
            link_target=artifact["link_target"],
        )
        if (
            operation["after_type"] != artifact["node_type"]
            or operation["after_mode"] != artifact["mode"]
            or operation["after_digest"] != expected_after
            or operation["artifact_source_digest"] != artifact["source_digest"]
        ):
            fail("operations", "artifact-operation-mismatch")

        expected_source_ref = MIGRATION_ARTIFACT_SOURCES.get(operation["path"])
        if expected_source_ref is None or artifact["source_ref"] != expected_source_ref:
            fail("operations", "operation-path-not-owned")
        if inputs["bootstrap_authority_approval"] is None:
            fail("operations", "bootstrap-authority-approval-required")
        expected_content = None
        if operation["path"] == ".workbench/schema":
            expected_content = b"workbench/v2\n"
        elif operation["path"] == ".workbench/profile.conf":
            expected_content = (
                "schema=workbench-profile/v1\nlanguage="
                + inputs["language"]["tag"]
                + "\n"
            ).encode("ascii")
        elif operation["path"] == ".workbench/policy.conf":
            expected_content = b"schema=workbench-policy/v1\n"
        elif operation["path"] == ".workbench/authority.json":
            expected_content = canonical_bytes(
                inputs["bootstrap_authority_approval"]["receipt"][
                    "proposed_descriptor"
                ]
            )
        elif operation["path"] == "AGENTS.overlay.md":
            if inputs["reviewed_overlay"] is None:
                fail("operations", "reviewed-overlay-required")
            expected_content = decode_canonical_base64(
                inputs["reviewed_overlay"]["receipt"]["content_base64"],
                "inputs.reviewed_overlay.content_base64",
            )
        elif operation["path"] == ".workbench/migration.json":
            migration_receipt = validate_migration_receipt(
                strict_load(content, ".workbench/migration.json")
            )
            reviewed_input = inputs["reviewed_overlay"]
            if (
                content != canonical_bytes(migration_receipt)
                or migration_receipt["source_revision"] != workspace["source_revision"]
                or migration_receipt["source_tree_digest"]
                != workspace["source_tree_digest"]
                or migration_receipt["planner"] != planner
                or migration_receipt["migration_task"] != migration_task
                or migration_receipt["language"] != inputs["language"]
                or migration_receipt["authority_approval_object_digest"]
                != inputs["bootstrap_authority_approval"]["object_digest"]
                or migration_receipt["authority_approval_source_digest"]
                != inputs["bootstrap_authority_approval"]["source_digest"]
                or migration_receipt["reviewed_overlay_object_digest"]
                != (reviewed_input["object_digest"] if reviewed_input else None)
                or migration_receipt["reviewed_overlay_source_digest"]
                != (reviewed_input["source_digest"] if reviewed_input else None)
                or migration_receipt["legacy_inventory_object_digest"]
                != legacy["object_digest"]
                or migration_receipt["legacy_inventory_source_digest"]
                != legacy["source_digest"]
                or migration_receipt["active_v1_tasks_digest"]
                != plan["active_v1_tasks"]["digest"]
                or migration_receipt["embedded_engine"] != embedded
            ):
                fail("artifacts", "migration-receipt-plan-drift")
        if expected_content is not None and content != expected_content:
            fail("artifacts", "artifact-content-drift")

    remove_operations = [item for item in operations if item["op"] == "remove"]
    if plugin_equivalence is not None:
        equivalence = plugin_equivalence["receipt"]
        if engine_manifest is None:
            fail("plugin_equivalence", "engine-manifest-required")
        if (
            embedded["equivalence_receipt_digest"]
            != plugin_equivalence["object_digest"]
            or engine_manifest["manifest_digest"]
            != equivalence["replacement_plugin"]["plugin_manifest_digest"]
            or planner["plugin_version"]
            != equivalence["replacement_plugin"]["plugin_version"]
        ):
            fail("plugin_equivalence", "plugin-equivalence-drift")
    elif "present-verified" in (embedded["before"], embedded["after"]):
        fail("plugin_equivalence", "plugin-equivalence-required")

    if remove_operations:
        if plugin_equivalence is None:
            fail("operations", "plugin-equivalence-required")
        equivalence = plugin_equivalence["receipt"]
        removable = equivalence["removable_nodes"]
        if [item["path"] for item in remove_operations] != [
            item["path"] for item in removable
        ]:
            fail("operations", "removal-manifest-mismatch")
        for operation, node in zip(remove_operations, removable):
            if (
                operation["before_type"] != node["node_type"]
                or operation["before_mode"] != node["mode"]
                or operation["before_digest"] != node["digest"]
                or operation["equivalence_receipt_ref"] != equivalence["receipt_id"]
            ):
                fail("operations", "removal-manifest-mismatch")
        basis = normalized_object({
            "contract_version": "workbench-kit-removal-plan-basis/v1",
            "workspace_source_revision": workspace["source_revision"],
            "workspace_source_tree_digest": workspace["source_tree_digest"],
            "migration_task_claim_id": migration_task["claim_id"],
            "planner_revision": planner["planner_revision"],
            "legacy_inventory_digest": legacy["object_digest"],
            "equivalence_receipt_digest": plugin_equivalence["object_digest"],
            "remove_operations": remove_operations,
        }, REMOVAL_BASIS_FIELDS)
        if removal_basis_digest != canonical_digest(basis):
            fail("removal_plan_basis_digest")
        required_blocker = {
            "code": "removal-approval-required",
            "ref": removal_basis_digest,
        }
        if removal_approval is None:
            if required_blocker not in blockers:
                fail("removal_approval", "removal-approval-required")
        else:
            approval = removal_approval["receipt"]
            if (
                approval["equivalence_receipt_id"] != equivalence["receipt_id"]
                or approval["equivalence_receipt_digest"]
                != plugin_equivalence["object_digest"]
                or approval["approved_plan_basis_digest"] != removal_basis_digest
                or required_blocker in blockers
            ):
                fail("removal_approval", "removal-approval-drift")
        if embedded["before"] != "present-verified" or embedded["after"] != "absent":
            fail("embedded_engine", "removal-state-invalid")
    elif any(
        value is not None
        for value in (removal_basis_digest, removal_approval)
    ):
        fail("removal_plan_basis_digest", "removal-operation-required")
    active_tasks = validate_active_tasks(plan["active_v1_tasks"])
    if active_tasks["source_inventory_object_digest"] != legacy["object_digest"]:
        fail("active_v1_tasks.source_inventory_object_digest")
    boolean(plan["changed"], "changed")
    boolean(plan["actionable"], "actionable")
    if plan["changed"] is not bool(operations):
        fail("changed")
    expected_actionable = bool(operations) and not blockers
    if plan["actionable"] != expected_actionable:
        fail("actionable")

    normalized = {
        "contract_version": plan["contract_version"],
        "plan_digest": plan["plan_digest"],
        "classification_before": plan["classification_before"],
        "target_classification": plan["target_classification"],
        "embedded_engine": embedded,
        "provenance_before": validate_provenance(
            plan["provenance_before"], "provenance_before"
        ),
        "provenance_after": validate_provenance(
            plan["provenance_after"], "provenance_after"
        ),
        "workspace": workspace,
        "planner": planner,
        "doctor": doctor,
        "legacy_inventory": legacy,
        "inputs": inputs,
        "engine_manifest": engine_manifest,
        "plugin_equivalence": plugin_equivalence,
        "removal_plan_basis_digest": removal_basis_digest,
        "removal_approval": removal_approval,
        "active_v1_tasks": active_tasks,
        "preserved": preserved,
        "parent_directories": parents,
        "artifacts": artifacts,
        "operations": operations,
        "blockers": blockers,
        "changed": plan["changed"],
        "actionable": plan["actionable"],
    }
    if digest(plan["plan_digest"], "plan_digest") != canonical_digest(
        normalized, null_field="plan_digest"
    ):
        fail("plan_digest")
    return normalized


def validate_workspace(value: Any, ref: str = "workspace") -> dict[str, Any]:
    workspace = exact_object(value, WORKSPACE_FIELDS, ref)
    root = pathlib.PurePath(text(workspace["root"], f"{ref}.root"))
    if not root.is_absolute():
        fail(f"{ref}.root")
    oid(workspace["source_revision"], f"{ref}.source_revision")
    oid(workspace["default_revision"], f"{ref}.default_revision")
    if not isinstance(workspace["source_tree_digest"], str) or TREE_DIGEST.fullmatch(
        workspace["source_tree_digest"]
    ) is None:
        fail(f"{ref}.source_tree_digest")
    task = exact_object(
        workspace["migration_task"], MIGRATION_TASK_FIELDS, f"{ref}.migration_task"
    )
    text(task["task_id"], f"{ref}.migration_task.task_id")
    text(task["claim_id"], f"{ref}.migration_task.claim_id")
    if task["task_contract"] not in ("workbench-task/v1", "workbench-task/v2"):
        fail(f"{ref}.migration_task.task_contract")
    text(task["branch"], f"{ref}.migration_task.branch")
    digest(task["index_digest"], f"{ref}.migration_task.index_digest")
    workspace["migration_task"] = task
    return workspace


def validate_embedded(value: Any, ref: str) -> dict[str, Any]:
    embedded = exact_object(value, EMBEDDED_FIELDS, ref)
    if embedded["before"] not in EMBEDDED_STATES or embedded["after"] not in EMBEDDED_STATES:
        fail(ref)
    digest(
        embedded["equivalence_receipt_digest"],
        f"{ref}.equivalence_receipt_digest",
        nullable=True,
    )
    if (
        "present-verified" in (embedded["before"], embedded["after"])
        and embedded["equivalence_receipt_digest"] is None
    ):
        fail(f"{ref}.equivalence_receipt_digest")
    return embedded


def validate_blockers(value: Any, ref: str) -> list[dict[str, Any]]:
    blockers = []
    for item in array(value, ref):
        blocker = exact_object(item, BLOCKER_FIELDS, f"{ref}.blocker")
        text(blocker["code"], f"{ref}.blocker.code")
        text(blocker["ref"], f"{ref}.blocker.ref")
        blockers.append(blocker)
    order = [(item["code"], item["ref"]) for item in blockers]
    if order != sorted(order) or len(order) != len(set(order)):
        fail(ref)
    return blockers


def validate_validation(value: Any) -> dict[str, Any]:
    validation = exact_object(value, VALIDATION_FIELDS, "validation")
    if validation["status"] not in ("pending", "passed", "failed"):
        fail("validation.status")
    blockers = validate_blockers(validation["blockers"], "validation.blockers")
    basis = (
        validation["classification_after"],
        validation["basis_kind"],
        validation["basis_digest"],
    )
    if validation["status"] == "pending":
        if basis != (None, None, None) or blockers:
            fail("validation.pending")
    elif validation["status"] == "passed":
        if (
            validation["classification_after"] not in CLASSIFICATIONS
            or validation["basis_kind"] not in ("migration-candidate", "removal-plan")
            or digest(validation["basis_digest"], "validation.basis_digest") is None
            or blockers
        ):
            fail("validation.passed")
    else:
        if not blockers:
            fail("validation.failed")
        if any(item is None for item in basis):
            if basis != (None, None, None):
                fail("validation.failed")
        elif (
            validation["classification_after"] not in CLASSIFICATIONS
            or validation["basis_kind"] not in ("migration-candidate", "removal-plan")
            or digest(validation["basis_digest"], "validation.basis_digest") is None
        ):
            fail("validation.failed")
    validation["blockers"] = blockers
    if digest(validation["digest"], "validation.digest") != canonical_digest(
        validation, null_field="digest"
    ):
        fail("validation.digest")
    return validation


def validate_applied(value: Any) -> list[dict[str, Any]]:
    applied = []
    for item in array(value, "applied"):
        operation = exact_object(item, APPLIED_FIELDS, "applied.operation")
        if operation["op"] not in ("create", "update", "remove"):
            fail("applied.operation.op")
        validate_relative_path(operation["path"])
        before = digest(
            operation["before_digest"], "applied.operation.before_digest", nullable=True
        )
        after = digest(
            operation["after_digest"], "applied.operation.after_digest", nullable=True
        )
        if operation["op"] == "create" and (before is not None or after is None):
            fail("applied.operation.create")
        if operation["op"] == "update" and (before is None or after is None):
            fail("applied.operation.update")
        if operation["op"] == "remove" and (before is None or after is not None):
            fail("applied.operation.remove")
        applied.append(operation)
    if applied != sorted(applied, key=lambda item: (item["path"], item["op"])):
        fail("applied", "path-order-invalid")
    validate_path_set([item["path"] for item in applied], "applied", reject_ancestors=True)
    return applied


def validate_result(value: Any) -> dict[str, Any]:
    result = exact_object(value, RESULT_FIELDS, "upgrade-result")
    if result["contract_version"] != "workbench-kit-upgrade-result/v1":
        fail("upgrade-result.contract_version")
    plan_digest = digest(result["plan_digest"], "result.plan_digest")
    if result["classification_before"] not in CLASSIFICATIONS:
        fail("result.classification_before")
    if result["target_classification"] not in CLASSIFICATIONS:
        fail("result.target_classification")
    embedded = validate_embedded(result["embedded_engine"], "result.embedded_engine")
    provenance = validate_provenance(result["provenance_final"], "result.provenance_final")
    workspace = validate_workspace(result["workspace"], "result.workspace")

    transaction = exact_object(result["transaction"], TRANSACTION_FIELDS, "result.transaction")
    if not isinstance(transaction["journal_id"], str) or UPGRADE_ID.fullmatch(
        transaction["journal_id"]
    ) is None:
        fail("result.transaction.journal_id")
    if transaction["journal_id"] != "upgrade-" + plan_digest.removeprefix("sha256:"):
        fail("result.transaction.journal_id")
    if not isinstance(transaction["workspace_id"], str) or WORKSPACE_ID.fullmatch(
        transaction["workspace_id"]
    ) is None:
        fail("result.transaction.workspace_id")
    if transaction["workspace_id"] != workspace_identifier(workspace["root"]):
        fail("result.transaction.workspace_id")
    if transaction["stage"] not in ("completed", "rolled-back"):
        fail("result.transaction.stage")
    if transaction["direction"] != "none":
        fail("result.transaction.direction")
    if (
        not isinstance(transaction["cursor"], int)
        or isinstance(transaction["cursor"], bool)
        or transaction["cursor"] < 0
    ):
        fail("result.transaction.cursor")
    boolean(transaction["resumed"], "result.transaction.resumed")

    applied = validate_applied(result["applied"])
    boolean(result["changed"], "result.changed")
    if result["changed"] is not bool(applied):
        fail("result.changed")
    preserved = validate_preserved(result["preserved"], "result.preserved")
    active = validate_active_tasks(result["active_v1_tasks"])
    validation = validate_validation(result["validation"])
    blockers = validate_blockers(result["blockers"], "result.blockers")

    if transaction["stage"] == "completed":
        if (
            validation["status"] != "passed"
            or validation["classification_after"] != result["target_classification"]
            or blockers
        ):
            fail("result.completed")
    elif (
        transaction["cursor"] != 0
        or validation["status"] != "failed"
        or result["changed"]
        or applied
        or blockers != validation["blockers"]
    ):
        fail("result.rolled-back")

    normalized = {
        "contract_version": result["contract_version"],
        "result_digest": result["result_digest"],
        "plan_digest": result["plan_digest"],
        "classification_before": result["classification_before"],
        "target_classification": result["target_classification"],
        "embedded_engine": embedded,
        "provenance_final": provenance,
        "workspace": workspace,
        "transaction": transaction,
        "changed": result["changed"],
        "applied": applied,
        "preserved": preserved,
        "active_v1_tasks": active,
        "validation": validation,
        "blockers": blockers,
    }
    if digest(result["result_digest"], "result.result_digest") != canonical_digest(
        normalized, null_field="result_digest"
    ):
        fail("result.result_digest")
    return normalized


def validate_node_image(value: Any, ref: str) -> dict[str, Any]:
    image = exact_object(value, NODE_IMAGE_FIELDS, ref)
    node_type = image["node_type"]
    if node_type == "absent":
        if any(image[field] is not None for field in NODE_IMAGE_FIELDS[1:]):
            fail(ref)
        return image
    if node_type == "directory":
        if (
            not isinstance(image["mode"], str)
            or re.fullmatch(r"04[0-7]{4}", image["mode"]) is None
            or image["content_base64"] is not None
            or image["link_target"] is not None
            or digest(image["digest"], f"{ref}.digest")
            != node_digest("directory", image["mode"])
        ):
            fail(ref)
        return image
    if node_type == "file":
        if image["mode"] not in ("100644", "100755") or image["link_target"] is not None:
            fail(ref)
        content = decode_canonical_base64(image["content_base64"], f"{ref}.content_base64")
        if digest(image["digest"], f"{ref}.digest") != node_digest(
            "file", image["mode"], content=content
        ):
            fail(ref)
        return image
    if node_type == "symlink":
        target = image["link_target"]
        if (
            image["mode"] != "120000"
            or image["content_base64"] is not None
            or not isinstance(target, str)
            or not target
            or "\x00" in target
            or digest(image["digest"], f"{ref}.digest")
            != node_digest("symlink", "120000", link_target=target)
        ):
            fail(ref)
        return image
    fail(f"{ref}.node_type")


def validate_effect(value: Any, journal_id: str) -> dict[str, Any]:
    effect = exact_object(value, EFFECT_FIELDS, "effect")
    if not isinstance(effect["effect_id"], str) or EFFECT_ID.fullmatch(effect["effect_id"]) is None:
        fail("effect.effect_id")
    if effect["kind"] not in ("ensure-directory", "create", "update", "remove"):
        fail("effect.kind")
    path = validate_relative_path(effect["path"])
    before = validate_node_image(effect["before"], "effect.before")
    after = validate_node_image(effect["after"], "effect.after")
    if before["node_type"] == "symlink":
        validate_link_target(path, before["link_target"], "effect.before.link_target")
    if after["node_type"] == "symlink":
        validate_link_target(path, after["link_target"], "effect.after.link_target")
    source_digest = digest(
        effect["artifact_source_digest"], "effect.artifact_source_digest", nullable=True
    )

    if effect["kind"] == "ensure-directory":
        if (
            before["node_type"] != "absent"
            or after["node_type"] != "directory"
            or after["mode"] != "040755"
            or effect["temp_path"] is not None
            or source_digest is not None
            or effect["equivalence_receipt_ref"] is not None
        ):
            fail("effect.ensure-directory")
    elif effect["kind"] in ("create", "update"):
        if effect["kind"] == "create":
            if before["node_type"] != "absent" or after["node_type"] not in (
                "file", "symlink"
            ):
                fail("effect.create")
        elif (
            before["node_type"] not in ("file", "symlink")
            or after["node_type"] not in ("file", "symlink")
        ):
            fail("effect.update")
        parent = pathlib.PurePosixPath(path).parent.as_posix()
        name = f".workbench-kit.{journal_id}.{effect['effect_id']}.tmp"
        expected_temp = name if parent == "." else f"{parent}/{name}"
        if (
            effect["temp_path"] != expected_temp
            or source_digest is None
            or effect["equivalence_receipt_ref"] is not None
        ):
            fail("effect.temp")
        if after["node_type"] == "file":
            content = decode_canonical_base64(
                after["content_base64"], "effect.after.content_base64"
            )
            expected_source = canonical_digest(content, raw=True)
        else:
            expected_source = canonical_digest(after["link_target"].encode("utf-8"), raw=True)
        if source_digest != expected_source:
            fail("effect.artifact_source_digest")
    else:
        parent = pathlib.PurePosixPath(path).parent.as_posix()
        name = f".workbench-kit.{journal_id}.{effect['effect_id']}.tmp"
        expected_temp = name if parent == "." else f"{parent}/{name}"
        if (
            before["node_type"] not in ("file", "symlink")
            or after["node_type"] != "absent"
            or effect["temp_path"] != expected_temp
            or source_digest is not None
        ):
            fail("effect.remove")
        text(effect["equivalence_receipt_ref"], "effect.equivalence_receipt_ref")

    effect["before"] = before
    effect["after"] = after
    return effect


def validate_journal(
    value: Any, plan: dict[str, Any] | None = None
) -> dict[str, Any]:
    journal = exact_object(value, JOURNAL_FIELDS, "upgrade-journal")
    normalized_plan = validate_plan(plan) if plan is not None else None
    if journal["contract_version"] != "workbench-kit-upgrade-journal/v1":
        fail("upgrade-journal.contract_version")
    if not isinstance(journal["journal_id"], str) or UPGRADE_ID.fullmatch(
        journal["journal_id"]
    ) is None:
        fail("journal.journal_id")
    if not isinstance(journal["workspace_id"], str) or WORKSPACE_ID.fullmatch(
        journal["workspace_id"]
    ) is None:
        fail("journal.workspace_id")
    plan_digest = digest(journal["plan_digest"], "journal.plan_digest")
    if journal["journal_id"] != "upgrade-" + plan_digest.removeprefix("sha256:"):
        fail("journal.journal_id")
    digest(journal["plan_source_digest"], "journal.plan_source_digest")
    workspace = validate_workspace(journal["workspace"], "journal.workspace")
    if journal["workspace_id"] != workspace_identifier(workspace["root"]):
        fail("journal.workspace_id")
    if journal["stage"] not in (
        "prepared", "applying", "validating", "rolling-back", "rolled-back", "completed"
    ):
        fail("journal.stage")
    if (
        not isinstance(journal["cursor"], int)
        or isinstance(journal["cursor"], bool)
        or journal["cursor"] < 0
    ):
        fail("journal.cursor")

    effects = [
        validate_effect(item, journal["journal_id"])
        for item in array(journal["effects"], "journal.effects")
    ]
    expected_ids = [f"effect-{index:04d}" for index in range(1, len(effects) + 1)]
    if [item["effect_id"] for item in effects] != expected_ids:
        fail("journal.effects")
    directory_effects = [item for item in effects if item["kind"] == "ensure-directory"]
    if effects[: len(directory_effects)] != directory_effects:
        fail("journal.effects")
    directory_paths = [item["path"] for item in directory_effects]
    if directory_paths != sorted(directory_paths, key=lambda path: (path.count("/"), path)):
        fail("journal.effects", "path-order-invalid")
    operations = effects[len(directory_effects) :]
    if operations != sorted(operations, key=lambda item: (item["path"], item["kind"])):
        fail("journal.effects", "path-order-invalid")
    validate_path_set(
        [item["path"] for item in operations], "journal.effects", reject_ancestors=True
    )
    folded_effect_paths = [item["path"].casefold() for item in effects]
    if len(folded_effect_paths) != len(set(folded_effect_paths)):
        fail("journal.effects", "path-collision")
    operation_paths = [item["path"].casefold() for item in operations]
    if any(
        not any(path.startswith(parent.casefold() + "/") for path in operation_paths)
        for parent in directory_paths
    ):
        fail("journal.effects", "parent-operation-mismatch")
    if normalized_plan is not None:
        if normalized_plan["plan_digest"] != journal["plan_digest"]:
            fail("journal.plan_digest")
        expected_effects: list[tuple[str, dict[str, Any]]] = []
        for parent in normalized_plan["parent_directories"]:
            if parent["before_type"] is None:
                expected_effects.append(("ensure-directory", parent))
        expected_effects.extend(
            (operation["op"], operation)
            for operation in normalized_plan["operations"]
        )
        if len(effects) != len(expected_effects):
            fail("journal.effects", "plan-effect-mismatch")
        for effect, (kind, planned) in zip(effects, expected_effects):
            if effect["kind"] != kind or effect["path"] != planned["path"]:
                fail("journal.effects", "plan-effect-mismatch")
            if kind == "ensure-directory":
                if (
                    effect["before"]["node_type"] != "absent"
                    or effect["after"]["node_type"] != "directory"
                    or effect["after"]["mode"] != planned["after_mode"]
                ):
                    fail("journal.effects", "plan-effect-mismatch")
            elif (
                effect["before"]["node_type"] != (planned["before_type"] or "absent")
                or effect["before"]["mode"] != planned["before_mode"]
                or effect["before"]["digest"] != planned["before_digest"]
                or effect["after"]["node_type"] != (planned["after_type"] or "absent")
                or effect["after"]["mode"] != planned["after_mode"]
                or effect["after"]["digest"] != planned["after_digest"]
                or effect["artifact_source_digest"]
                != planned["artifact_source_digest"]
                or effect["equivalence_receipt_ref"]
                != planned["equivalence_receipt_ref"]
            ):
                fail("journal.effects", "plan-effect-mismatch")

    applied = array(journal["applied"], "journal.applied")
    if not all(isinstance(item, str) for item in applied):
        fail("journal.applied")
    validation = validate_validation(journal["validation"])
    length = len(effects)
    cursor = journal["cursor"]
    prefix = expected_ids[:cursor]
    completion = journal["completion_result"]
    stage = journal["stage"]
    if stage == "prepared":
        valid_state = (
            journal["direction"] == "forward"
            and cursor == 0
            and applied == []
            and validation["status"] == "pending"
            and completion is None
        )
    elif stage == "applying":
        valid_state = (
            journal["direction"] == "forward"
            and cursor <= length
            and applied == prefix
            and validation["status"] == "pending"
            and completion is None
        )
    elif stage == "validating":
        valid_state = (
            journal["direction"] == "forward"
            and cursor == length
            and applied == expected_ids
            and validation["status"] == "pending"
            and completion is None
        )
    elif stage == "rolling-back":
        valid_state = (
            journal["direction"] == "reverse"
            and cursor <= length
            and applied == prefix
            and validation["status"] == "failed"
            and completion is None
        )
    elif stage == "rolled-back":
        valid_state = (
            journal["direction"] == "none"
            and cursor == 0
            and applied == []
            and validation["status"] == "failed"
            and completion is not None
        )
    else:
        valid_state = (
            journal["direction"] == "none"
            and cursor == length
            and applied == expected_ids
            and validation["status"] == "passed"
            and completion is not None
        )
    if not valid_state:
        fail("journal.stage-invariant")

    normalized_result = None
    if completion is not None:
        normalized_result = validate_result(completion)
        transaction = normalized_result["transaction"]
        expected_result_stage = "completed" if stage == "completed" else "rolled-back"
        if (
            normalized_result["plan_digest"] != journal["plan_digest"]
            or normalized_result["workspace"] != workspace
            or normalized_result["validation"] != validation
            or transaction["journal_id"] != journal["journal_id"]
            or transaction["workspace_id"] != journal["workspace_id"]
            or transaction["stage"] != expected_result_stage
            or transaction["direction"] != "none"
            or transaction["cursor"] != cursor
        ):
            fail("journal.completion_result")
        if stage == "completed":
            expected_operations = [
                {
                    "op": effect["kind"],
                    "path": effect["path"],
                    "before_digest": effect["before"]["digest"],
                    "after_digest": effect["after"]["digest"],
                }
                for effect in effects
                if effect["kind"] != "ensure-directory"
            ]
            if normalized_result["applied"] != expected_operations:
                fail("journal.completion_result.applied")
    for field in ("created_at", "updated_at"):
        if not isinstance(journal[field], str) or RFC3339_UTC.fullmatch(journal[field]) is None:
            fail(f"journal.{field}")

    return {
        "contract_version": journal["contract_version"],
        "journal_id": journal["journal_id"],
        "workspace_id": journal["workspace_id"],
        "plan_digest": journal["plan_digest"],
        "plan_source_digest": journal["plan_source_digest"],
        "workspace": workspace,
        "stage": journal["stage"],
        "direction": journal["direction"],
        "cursor": cursor,
        "effects": effects,
        "applied": applied,
        "validation": validation,
        "completion_result": normalized_result,
        "created_at": journal["created_at"],
        "updated_at": journal["updated_at"],
    }
