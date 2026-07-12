#!/usr/bin/env python3
"""Strict reducers for append-only writer coordination records."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, DefaultDict, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


LEDGER_HEADER = "workbench-writer-claims/v1"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
OID = re.compile(r"[0-9a-f]{40}([0-9a-f]{24})?\Z")
NAMESPACED_REF = re.compile(r"[a-z][a-z0-9-]*:[a-z][a-z0-9-]*/[A-Za-z0-9._-]+\Z")
UUID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z"
)
OWNER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")

ACTIVE_TASK_INVENTORY_FIELDS = {
    "contract_version",
    "source_revision",
    "descriptor_digest",
    "workspace_origin_url",
    "tasks",
    "complete",
    "blockers",
}
ACTIVE_TASK_FIELDS = {
    "home",
    "issue",
    "branch",
    "claim_id",
    "workspace_authority_descriptor_digest",
    "work_ref",
    "source_kind",
    "source_revision",
    "index_revision",
    "pull_request",
}

CLAIM_FIELDS = (
    "kind",
    "operation_id",
    "claim_id",
    "task_claim_id",
    "owner",
    "branch",
    "expected_path",
    "codebase_origin_url",
    "context_policy_set_digest",
    "action_instance_id",
    "policy_manifest_digest",
    "intent_digest",
    "authorization_ref",
    "state",
)

EFFECT_FIELDS = (
    "kind",
    "event_id",
    "operation_id",
    "claim_id",
    "device_id",
    "clone_id",
    "state",
)

OPERATION_FIELDS = (
    "contract_version",
    "operation_id",
    "claim_id",
    "task_claim_id",
    "owner",
    "branch",
    "expected_path",
    "codebase_origin_url",
    "registry_revision",
    "registry_digest",
    "context_policy_set_digest",
    "device_id",
    "clone_id",
    "action_instance_id",
    "intent_digest",
    "policy_manifest",
    "authorization_ref",
    "effect_owner_state",
    "worktree_ownership",
    "repo_record_ownership",
    "worktree_set_digest",
    "compensation_target",
    "compensation_reason",
    "compensation_next_step",
    "coordination_ref",
    "coordination_oid",
    "stage",
)

OPERATION_STAGES = {
    "prepared",
    "authorization-pending",
    "cancelled",
    "remote-claimed",
    "effect-owner-acquired",
    "worktree-create-pending",
    "worktree-ready",
    "record-create-pending",
    "record-ready",
    "compensation-pending",
    "handoff-ready",
    "consumed",
    "release-pending",
    "released",
}

WRITER_CONTENT_FIELDS = (
    "operation_id",
    "claim_id",
    "owner",
    "task_claim_id",
    "branch",
    "expected_path",
    "codebase_origin_url",
    "registry_revision",
    "registry_digest",
    "context_policy_set_digest",
    "action_instance_id",
    "intent_digest",
    "policy_manifest_digest",
    "authorization_ref",
)


def sha256(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def unique_object(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON member: {}".format(key))
        value[key] = item
    return value


def load_json(file: str) -> Any:
    with open(file, "r", encoding="utf-8") as handle:
        return json.load(handle, object_pairs_hook=unique_object)


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\t" in value or "\n" in value or "\r" in value:
        raise ValueError("{} must be a non-empty single-line value".format(field))
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("{} must not contain control characters".format(field))
    return value


def require_digest(value: Any, field: str) -> str:
    if not isinstance(value, str) or DIGEST.fullmatch(value) is None:
        raise ValueError("{} must be a canonical SHA-256 digest".format(field))
    return value


def parse_claim(parts: Sequence[str]) -> Dict[str, str]:
    if len(parts) != len(CLAIM_FIELDS):
        raise ValueError("malformed writer claim row")
    row = dict(zip(CLAIM_FIELDS, parts))
    for key in (
        "operation_id",
        "claim_id",
        "task_claim_id",
        "owner",
        "branch",
        "expected_path",
        "codebase_origin_url",
    ):
        require_text(row[key], key)
    require_digest(row["context_policy_set_digest"], "context_policy_set_digest")
    if row["state"] not in ("active", "released"):
        raise ValueError("invalid writer claim state")
    binding = (
        row["action_instance_id"],
        row["policy_manifest_digest"],
        row["intent_digest"],
    )
    if binding == ("null", "null", "null"):
        if row["authorization_ref"] != "null":
            raise ValueError("writer authorization requires an action binding")
        return row
    if "null" in binding:
        raise ValueError("writer action binding must be entirely null or present")
    require_text(row["action_instance_id"], "action_instance_id")
    require_digest(row["policy_manifest_digest"], "policy_manifest_digest")
    require_digest(row["intent_digest"], "intent_digest")
    if row["authorization_ref"] != "null":
        require_text(row["authorization_ref"], "authorization_ref")
    return row


def parse_effect(parts: Sequence[str]) -> Dict[str, str]:
    if len(parts) != len(EFFECT_FIELDS):
        raise ValueError("malformed effect-owner row")
    row = dict(zip(EFFECT_FIELDS, parts))
    for key in ("event_id", "operation_id", "claim_id", "device_id"):
        require_text(row[key], key)
    if UUID.fullmatch(row["clone_id"]) is None:
        raise ValueError("clone_id must be a lowercase UUID")
    if row["state"] not in ("acquired", "released"):
        raise ValueError("invalid effect-owner state")
    return row


def canonical_key(row: Mapping[str, str]) -> Tuple[Any, ...]:
    if row["kind"] == "claim":
        state_order = 0 if row["state"] == "active" else 1
        return (
            0,
            row["owner"],
            row["task_claim_id"],
            row["operation_id"],
            row["claim_id"],
            state_order,
        )
    return (1, row["operation_id"], row["claim_id"], row["event_id"])


def reduce_ledger(rows: List[Dict[str, str]]) -> None:
    claims: DefaultDict[Tuple[str, str], List[Dict[str, str]]] = defaultdict(list)
    effects: DefaultDict[Tuple[str, str], List[Dict[str, str]]] = defaultdict(list)
    for row in rows:
        key = (row["operation_id"], row["claim_id"])
        if row["kind"] == "claim":
            claims[key].append(row)
        else:
            effects[key].append(row)

    if set(effects) - set(claims):
        raise ValueError("effect-owner event references an unknown writer claim")

    for key, claim_rows in claims.items():
        states = [row["state"] for row in claim_rows]
        if states not in (["active"], ["active", "released"]):
            raise ValueError("writer claim must have one active row and at most one release")
        binding_fields = CLAIM_FIELDS[1:-1]
        first = claim_rows[0]
        for row in claim_rows[1:]:
            if any(row[field] != first[field] for field in binding_fields):
                raise ValueError("writer claim release binding mismatch")

        current: Optional[Tuple[str, str]] = None
        previous_event = ""
        seen_events = set()
        for event in effects.get(key, []):
            if event["event_id"] in seen_events or event["event_id"] <= previous_event:
                raise ValueError("effect-owner event IDs must be unique and monotonic")
            seen_events.add(event["event_id"])
            previous_event = event["event_id"]
            owner = (event["device_id"], event["clone_id"])
            if event["state"] == "acquired":
                if current is not None:
                    raise ValueError("effect owner cannot be acquired while already owned")
                if states[-1] == "released":
                    # A static set cannot place acquisition relative to claim release. The
                    # final null-owner check below is the verifiable file invariant.
                    pass
                current = owner
            else:
                if current != owner:
                    raise ValueError("effect-owner release does not match the current owner")
                current = None
        if states[-1] == "released" and current is not None:
            raise ValueError("writer claim cannot release while an effect owner is current")


def read_ledger(file: str) -> Tuple[List[Dict[str, str]], bytes]:
    with open(file, "rb") as handle:
        raw = handle.read()
    if not raw.endswith(b"\n") or b"\r" in raw:
        raise ValueError("writer ledger must be LF-terminated")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("writer ledger must be UTF-8") from exc
    lines = text[:-1].split("\n")
    if not lines or lines[0] != LEDGER_HEADER:
        raise ValueError("unsupported writer ledger contract")
    rows: List[Dict[str, str]] = []
    raw_rows = lines[1:]
    for line in raw_rows:
        if not line:
            raise ValueError("writer ledger contains an empty row")
        parts = line.split("\t")
        if parts[0] == "claim":
            rows.append(parse_claim(parts))
        elif parts[0] == "effect-owner":
            rows.append(parse_effect(parts))
        else:
            raise ValueError("unknown writer ledger row kind")
    if rows != sorted(rows, key=canonical_key):
        raise ValueError("writer ledger rows are not canonical")
    serialized = ["\t".join(row[field] for field in (CLAIM_FIELDS if row["kind"] == "claim" else EFFECT_FIELDS)) for row in rows]
    if len(serialized) != len(set(serialized)):
        raise ValueError("duplicate writer ledger row")
    reduce_ledger(rows)
    return rows, raw


def current_claim_state(claims: Sequence[Mapping[str, str]]) -> str:
    if not claims:
        return "absent"
    return claims[-1]["state"]


def latest_effect(effects: Sequence[Mapping[str, str]]) -> Optional[Dict[str, str]]:
    if not effects:
        return None
    event = effects[-1]
    return {
        "event_id": event["event_id"],
        "device_id": event["device_id"],
        "clone_id": event["clone_id"],
        "state": event["state"],
    }


def load_operation(file: str) -> Dict[str, Any]:
    with open(file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != set(OPERATION_FIELDS):
        raise ValueError("writer operation fields do not match the contract")
    if value["contract_version"] != "workbench-writer-operation/v1":
        raise ValueError("unsupported writer operation contract")
    for key in (
        "operation_id",
        "claim_id",
        "task_claim_id",
        "owner",
        "branch",
        "expected_path",
        "codebase_origin_url",
        "device_id",
    ):
        if not isinstance(value[key], str):
            raise ValueError("{} must be a string".format(key))
        require_text(value[key], key)
    if OWNER.fullmatch(value["owner"]) is None or value["owner"].isdigit():
        raise ValueError("writer operation owner must be a canonical home")
    if value["expected_path"] != "task/codebases/" + value["owner"]:
        raise ValueError("writer operation expected_path does not bind the owner")
    if UUID.fullmatch(value["clone_id"] if isinstance(value["clone_id"], str) else "") is None:
        raise ValueError("clone_id must be a lowercase UUID")
    require_digest(value["context_policy_set_digest"], "context_policy_set_digest")
    if not isinstance(value["registry_revision"], str) or re.fullmatch(
        r"[0-9a-f]{40}([0-9a-f]{24})?", value["registry_revision"]
    ) is None:
        raise ValueError("registry_revision must be a Git object ID")
    if not isinstance(value["registry_digest"], str):
        raise ValueError("registry_digest must be a string")
    require_digest(value["registry_digest"], "registry_digest")

    action_binding = (
        value["action_instance_id"],
        value["intent_digest"],
        value["policy_manifest"],
    )
    if action_binding != (None, None, None):
        if any(item is None for item in action_binding):
            raise ValueError("writer operation action binding must be entirely null or present")
        if not isinstance(value["action_instance_id"], str):
            raise ValueError("action_instance_id must be a string")
        require_text(value["action_instance_id"], "action_instance_id")
        if not isinstance(value["intent_digest"], str):
            raise ValueError("intent_digest must be a string")
        require_digest(value["intent_digest"], "intent_digest")
        manifest = value["policy_manifest"]
        if (
            not isinstance(manifest, dict)
            or set(manifest) != {"contract_version", "digest", "sources"}
            or manifest["contract_version"] != "workbench-policy-manifest/v1"
            or not isinstance(manifest["sources"], list)
        ):
            raise ValueError("invalid writer operation policy manifest")
        require_digest(manifest["digest"], "policy_manifest.digest")
        if value["authorization_ref"] is not None:
            if not isinstance(value["authorization_ref"], str):
                raise ValueError("authorization_ref must be null or a string")
            require_text(value["authorization_ref"], "authorization_ref")
    elif value["authorization_ref"] is not None:
        raise ValueError("writer authorization requires an action binding")

    if value["effect_owner_state"] not in ("none", "acquired", "released"):
        raise ValueError("invalid effect_owner_state")
    for key in ("worktree_ownership", "repo_record_ownership"):
        if value[key] not in ("none", "created", "adopted"):
            raise ValueError("invalid {}".format(key))
    worktree_digest = value["worktree_set_digest"]
    if worktree_digest is not None:
        if not isinstance(worktree_digest, str):
            raise ValueError("worktree_set_digest must be null or a digest")
        require_digest(worktree_digest, "worktree_set_digest")

    target = value["compensation_target"]
    reason = value["compensation_reason"]
    next_step = value["compensation_next_step"]
    if target is None:
        if reason is not None or next_step is not None:
            raise ValueError("null compensation target requires a null reason and cursor")
    else:
        if target not in ("reserved", "released"):
            raise ValueError("invalid compensation target")
        if reason not in (
            "ask",
            "deny",
            "authorization-deny",
            "handoff",
            "creation-failure",
            "cleanup",
        ):
            raise ValueError("invalid compensation reason")
        if next_step not in ("record", "worktree", "effect-owner", "claim", "finish"):
            raise ValueError("invalid compensation cursor")

    if value["coordination_ref"] != "refs/heads/workbench-coordination/writer-claims":
        raise ValueError("invalid writer coordination ref")
    oid = value["coordination_oid"]
    if oid is not None and (
        not isinstance(oid, str) or re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", oid) is None
    ):
        raise ValueError("coordination_oid must be null or a Git object ID")
    if value["stage"] not in OPERATION_STAGES:
        raise ValueError("invalid writer operation stage")
    if value["stage"] == "cancelled" and (
        value["effect_owner_state"] != "none"
        or value["worktree_ownership"] != "none"
        or value["repo_record_ownership"] != "none"
    ):
        raise ValueError("cancelled writer operation cannot own effects")
    if value["stage"] == "worktree-create-pending" and worktree_digest is None:
        raise ValueError("worktree-create-pending requires a worktree-set digest")
    if value["stage"] == "consumed" and (
        value["effect_owner_state"] != "acquired"
        or value["worktree_ownership"] == "none"
        or value["repo_record_ownership"] == "none"
        or worktree_digest is None
    ):
        raise ValueError("consumed writer operation requires every owned effect")
    if value["stage"] == "handoff-ready" and (
        value["effect_owner_state"] != "released"
        or value["worktree_ownership"] != "none"
        or value["repo_record_ownership"] != "none"
    ):
        raise ValueError("handoff-ready writer operation cannot retain local effects")
    return value


def write_json(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def write_ledger(file: str, rows: Sequence[Mapping[str, str]]) -> None:
    ordered = sorted(rows, key=canonical_key)
    lines = [LEDGER_HEADER]
    for row in ordered:
        fields = CLAIM_FIELDS if row["kind"] == "claim" else EFFECT_FIELDS
        lines.append("\t".join(row[field] for field in fields))
    raw = ("\n".join(lines) + "\n").encode("utf-8")
    with open(file, "wb") as handle:
        handle.write(raw)
    read_ledger(file)


def action_binding_from_resolution(file: Optional[str]) -> Tuple[Any, Any, Any, Any]:
    if file is None:
        return None, None, None, None
    with open(file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or value.get("contract_version") != "workbench-policy/v1":
        raise ValueError("invalid writer policy resolution")
    if value.get("decision") not in ("allow", "ask", "deny"):
        raise ValueError("writer policy decision is invalid")
    action = value.get("action_instance")
    if not isinstance(action, dict):
        raise ValueError("writer policy action instance is invalid")
    manifest = action.get("policy_manifest")
    if (
        not isinstance(manifest, dict)
        or set(manifest) != {"contract_version", "digest", "sources"}
        or manifest["contract_version"] != "workbench-policy-manifest/v1"
    ):
        raise ValueError("writer policy manifest is invalid")
    require_digest(manifest["digest"], "policy_manifest.digest")
    return action.get("id"), action.get("intent_digest"), manifest, value.get("authorization_ref")


def operation_value(args: argparse.Namespace) -> Dict[str, Any]:
    action_id, intent_digest, policy_manifest, authorization_ref = action_binding_from_resolution(
        args.policy_resolution_file
    )
    return {
        "contract_version": "workbench-writer-operation/v1",
        "operation_id": args.operation_id,
        "claim_id": args.claim_id,
        "task_claim_id": args.task_claim_id,
        "owner": args.owner,
        "branch": args.branch,
        "expected_path": args.expected_path,
        "codebase_origin_url": args.codebase_origin_url,
        "registry_revision": args.registry_revision,
        "registry_digest": args.registry_digest,
        "context_policy_set_digest": args.context_policy_set_digest,
        "device_id": args.device_id,
        "clone_id": args.clone_id,
        "action_instance_id": action_id,
        "intent_digest": intent_digest,
        "policy_manifest": policy_manifest,
        "authorization_ref": authorization_ref,
        "effect_owner_state": "none",
        "worktree_ownership": "none",
        "repo_record_ownership": "none",
        "worktree_set_digest": None,
        "compensation_target": None,
        "compensation_reason": None,
        "compensation_next_step": None,
        "coordination_ref": "refs/heads/workbench-coordination/writer-claims",
        "coordination_oid": args.coordination_oid,
        "stage": args.stage,
    }


def cmd_operation_create(args: argparse.Namespace) -> None:
    value = operation_value(args)
    # Reuse the strict parser as the single operation validator.
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(raw)
        load_operation(args.output)
    else:
        sys.stdout.write(raw)


def cmd_operation_update(args: argparse.Namespace) -> None:
    value = load_operation(args.file)
    for field in (
        "stage",
        "coordination_oid",
        "effect_owner_state",
        "worktree_ownership",
        "repo_record_ownership",
        "worktree_set_digest",
        "compensation_target",
        "compensation_reason",
        "compensation_next_step",
    ):
        item = getattr(args, field)
        if item is not None:
            value[field] = item
    if args.clear_compensation:
        value["compensation_target"] = None
        value["compensation_reason"] = None
        value["compensation_next_step"] = None
    if args.policy_resolution_file:
        action_id, intent_digest, manifest, authorization_ref = action_binding_from_resolution(
            args.policy_resolution_file
        )
        value["action_instance_id"] = action_id
        value["intent_digest"] = intent_digest
        value["policy_manifest"] = manifest
        value["authorization_ref"] = authorization_ref
    if args.clear_action_binding:
        value["action_instance_id"] = None
        value["intent_digest"] = None
        value["policy_manifest"] = None
        value["authorization_ref"] = None
    ordered = {field: value[field] for field in OPERATION_FIELDS}
    raw = json.dumps(ordered, ensure_ascii=False, separators=(",", ":")) + "\n"
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(raw)
    load_operation(args.output)


def cmd_ledger_append_claim(args: argparse.Namespace) -> None:
    rows, _ = read_ledger(args.file)
    if args.state == "active":
        operation = load_operation(args.operation_file)
        policy_digest = (
            "null" if operation["policy_manifest"] is None else operation["policy_manifest"]["digest"]
        )
        row = {
            "kind": "claim",
            "operation_id": operation["operation_id"],
            "claim_id": operation["claim_id"],
            "task_claim_id": operation["task_claim_id"],
            "owner": operation["owner"],
            "branch": operation["branch"],
            "expected_path": operation["expected_path"],
            "codebase_origin_url": operation["codebase_origin_url"],
            "context_policy_set_digest": operation["context_policy_set_digest"],
            "action_instance_id": operation["action_instance_id"] or "null",
            "policy_manifest_digest": policy_digest,
            "intent_digest": operation["intent_digest"] or "null",
            "authorization_ref": operation["authorization_ref"] or "null",
            "state": "active",
        }
        parse_claim(tuple(row[field] for field in CLAIM_FIELDS))
        if any(
            item["kind"] == "claim"
            and item["operation_id"] == row["operation_id"]
            and item["claim_id"] == row["claim_id"]
            for item in rows
        ):
            raise ValueError("writer claim identity already exists")
    else:
        matches = [
            item
            for item in rows
            if item["kind"] == "claim"
            and item["operation_id"] == args.operation_id
            and item["claim_id"] == args.claim_id
        ]
        if [item["state"] for item in matches] == ["active", "released"]:
            write_ledger(args.output, rows)
            return
        if [item["state"] for item in matches] != ["active"]:
            raise ValueError("writer claim cannot be released from its current state")
        row = dict(matches[0])
        row["state"] = "released"
    write_ledger(args.output, list(rows) + [row])


def cmd_ledger_append_effect(args: argparse.Namespace) -> None:
    rows, _ = read_ledger(args.file)
    row = {
        "kind": "effect-owner",
        "event_id": args.event_id,
        "operation_id": args.operation_id,
        "claim_id": args.claim_id,
        "device_id": args.device_id,
        "clone_id": args.clone_id,
        "state": args.state,
    }
    parse_effect(tuple(row[field] for field in EFFECT_FIELDS))
    if any(item["kind"] == "effect-owner" and item["event_id"] == args.event_id for item in rows):
        raise ValueError("effect-owner event ID already exists")
    write_ledger(args.output, list(rows) + [row])


def current_active_claims(rows: Sequence[Mapping[str, str]]) -> List[Mapping[str, str]]:
    grouped: DefaultDict[Tuple[str, str], List[Mapping[str, str]]] = defaultdict(list)
    for row in rows:
        if row["kind"] == "claim":
            grouped[(row["operation_id"], row["claim_id"])].append(row)
    return [claims[-1] for claims in grouped.values() if claims[-1]["state"] == "active"]


def writer_conflict(
    owner: str,
    legacy_home_set_digest: str,
    prospective: Mapping[str, str],
    rows: Sequence[Mapping[str, str]],
    legacy_claims: Sequence[Mapping[str, Any]],
) -> Tuple[str, List[Mapping[str, Any]]]:
    require_digest(legacy_home_set_digest, "legacy_home_set_digest")
    union: List[Mapping[str, Any]] = []
    for row in current_active_claims(rows):
        union.append(
            {
                "source": "ledger-v2",
                "claim_id": row["claim_id"],
                "operation_id": row["operation_id"],
                "task_claim_id": row["task_claim_id"],
                "owner": row["owner"],
                "branch": row["branch"],
                "context_policy_set_digest": row["context_policy_set_digest"],
                "source_revision": None,
                "pr_head_revision": None,
                "lifecycle_digest": None,
            }
        )
    union.extend(legacy_claims)
    if not any(
        row["source"] == "ledger-v2"
        and row["operation_id"] == prospective["operation_id"]
        and row["claim_id"] == prospective["claim_id"]
        for row in union
    ):
        union.append(
            {
                "source": "ledger-v2",
                "claim_id": prospective["claim_id"],
                "operation_id": prospective["operation_id"],
                "task_claim_id": prospective["task_claim_id"],
                "owner": prospective["owner"],
                "branch": prospective["branch"],
                "context_policy_set_digest": prospective["context_policy_set_digest"],
                "source_revision": None,
                "pr_head_revision": None,
                "lifecycle_digest": None,
            }
        )
    conflicts = [
        row
        for row in union
        if row["owner"] == owner
        and not (
            row["source"] == "ledger-v2"
            and row["operation_id"] == prospective["operation_id"]
            and row["claim_id"] == prospective["claim_id"]
        )
    ]
    manifest_rows = [row for row in union if row["owner"] == owner]
    manifest_rows.sort(key=lambda item: (item["source"], item["claim_id"], item["branch"]))
    writers = [
        (
            str(row["source"]),
            str(row["claim_id"]),
            "null" if row["operation_id"] is None else str(row["operation_id"]),
            str(row["task_claim_id"]),
            str(row["branch"]),
            "null" if row["context_policy_set_digest"] is None else str(row["context_policy_set_digest"]),
            "null" if row["source_revision"] is None else str(row["source_revision"]),
            "null" if row["pr_head_revision"] is None else str(row["pr_head_revision"]),
            "null" if row["lifecycle_digest"] is None else str(row["lifecycle_digest"]),
        )
        for row in manifest_rows
    ]
    writers.sort(key=lambda item: (item[0], item[1], item[4]))
    lines = [
        "workbench-writer-conflict/v1",
        "owner\t" + owner,
        "legacy_home_set\t" + legacy_home_set_digest,
    ]
    lines.extend("writer\t" + "\t".join(row) for row in writers)
    digest = sha256(("\n".join(lines) + "\n").encode("utf-8"))
    return digest, conflicts


def cmd_conflict(args: argparse.Namespace) -> None:
    rows, _ = read_ledger(args.ledger_file)
    legacy = load_json(args.legacy_inventory_file)
    expected_top = (
        "contract_version", "source_revision", "authority", "home_set", "homes",
        "active_claims", "origin_replacements", "complete", "blockers",
    )
    if not isinstance(legacy, dict) or set(legacy) != set(expected_top):
        raise ValueError("legacy inventory fields do not match the public contract")
    if (
        legacy["contract_version"] != "workbench-legacy-inventory/v1"
        or legacy["complete"] is not True
        or legacy["blockers"] != []
    ):
        raise ValueError("legacy inventory is not complete")
    home_set = legacy["home_set"]
    if not isinstance(home_set, dict) or set(home_set) != {
        "contract_version", "digest", "source_revision"
    }:
        raise ValueError("legacy home set fields do not match the contract")
    if (
        home_set["contract_version"] != "workbench-legacy-home-set/v1"
        or home_set["source_revision"] != legacy["source_revision"]
    ):
        raise ValueError("legacy home set does not bind the inventory revision")
    require_digest(home_set["digest"], "legacy_home_set.digest")
    legacy_claims = [validate_status_claim(item) for item in legacy["active_claims"]]
    prospective_operation = load_operation(args.operation_file)
    prospective = {
        "kind": "claim",
        "operation_id": prospective_operation["operation_id"],
        "claim_id": prospective_operation["claim_id"],
        "task_claim_id": prospective_operation["task_claim_id"],
        "owner": prospective_operation["owner"],
        "branch": prospective_operation["branch"],
        "context_policy_set_digest": prospective_operation["context_policy_set_digest"],
    }
    digest, conflicts = writer_conflict(
        prospective_operation["owner"], home_set["digest"], prospective, rows, legacy_claims
    )
    value = {
        "contract_version": "workbench-writer-conflict/v1",
        "owner": prospective_operation["owner"],
        "revision": digest,
        "conflicts": conflicts,
    }
    write_json(value)


def cmd_work_ref_conflict(args: argparse.Namespace) -> None:
    inventory = load_json(args.inventory_file)
    if not isinstance(inventory, dict) or set(inventory) != ACTIVE_TASK_INVENTORY_FIELDS:
        raise ValueError("active task inventory fields do not match the contract")
    if (
        inventory["contract_version"] != "workbench-active-task-inventory/v1"
        or inventory["complete"] is not True
        or inventory["blockers"] != []
    ):
        raise ValueError("active task inventory is incomplete")
    if not isinstance(inventory["source_revision"], str) or OID.fullmatch(inventory["source_revision"]) is None:
        raise ValueError("active task inventory revision is invalid")
    require_digest(inventory["descriptor_digest"], "descriptor_digest")
    require_text(inventory["workspace_origin_url"], "workspace_origin_url")
    if NAMESPACED_REF.fullmatch(args.work_ref) is None:
        raise ValueError("work_ref is invalid")
    if not isinstance(inventory["tasks"], list):
        raise ValueError("active task inventory tasks must be an array")
    validated = []
    for task in inventory["tasks"]:
        if not isinstance(task, dict) or set(task) != ACTIVE_TASK_FIELDS:
            raise ValueError("active task fields do not match the contract")
        if task["home"] is not None:
            require_text(task["home"], "task.home")
        if (
            not isinstance(task["issue"], int)
            or isinstance(task["issue"], bool)
            or task["issue"] <= 0
        ):
            raise ValueError("active task issue is invalid")
        for field in ("branch", "claim_id"):
            require_text(task[field], "task." + field)
        require_digest(
            task["workspace_authority_descriptor_digest"],
            "task.workspace_authority_descriptor_digest",
        )
        if task["work_ref"] is not None and (
            not isinstance(task["work_ref"], str)
            or NAMESPACED_REF.fullmatch(task["work_ref"]) is None
        ):
            raise ValueError("active task work_ref is invalid")
        if task["source_kind"] not in ("branch", "submitted-pr"):
            raise ValueError("active task source kind is invalid")
        for field in ("source_revision", "index_revision"):
            if not isinstance(task[field], str) or OID.fullmatch(task[field]) is None:
                raise ValueError("active task {} is invalid".format(field))
        if task["source_kind"] == "branch":
            if task["pull_request"] is not None:
                raise ValueError("branch-backed active task carries a pull request")
        elif (
            not isinstance(task["pull_request"], int)
            or isinstance(task["pull_request"], bool)
            or task["pull_request"] <= 0
        ):
            raise ValueError("submitted active task pull request is invalid")
        validated.append(task)
    if validated != sorted(validated, key=lambda item: (item["branch"], item["claim_id"])):
        raise ValueError("active tasks are not canonically sorted")
    if len(validated) != len({item["claim_id"] for item in validated}):
        raise ValueError("active task claim identity is duplicated")
    conflicts = [
        {
            "claim_id": task["claim_id"],
            "branch": task["branch"],
            "home": task["home"],
            "issue": task["issue"],
        }
        for task in validated
        if task["work_ref"] == args.work_ref and task["claim_id"] != args.current_claim_id
    ]
    write_json(
        {
            "contract_version": "workbench-work-ref-conflict/v1",
            "work_ref": args.work_ref,
            "conflicts": conflicts,
        }
    )


def cmd_matching_active(args: argparse.Namespace) -> None:
    rows, _ = read_ledger(args.file)
    matches = [
        row
        for row in current_active_claims(rows)
        if row["task_claim_id"] == args.task_claim_id
        and row["owner"] == args.owner
        and row["branch"] == args.branch
    ]
    effects = [row for row in rows if row["kind"] == "effect-owner"]
    write_json(
        {
            "matches": matches,
            "effect_events": [
                row
                for row in effects
                if any(
                    row["operation_id"] == match["operation_id"]
                    and row["claim_id"] == match["claim_id"]
                    for match in matches
                )
            ],
        }
    )


def cmd_ledger_validate(args: argparse.Namespace) -> None:
    rows, raw = read_ledger(args.file)
    write_json(
        {
            "contract_version": "workbench-writer-ledger-validation/v1",
            "digest": sha256(raw),
            "events": len(rows),
        }
    )


def git_bytes(repository: str, *arguments: str) -> bytes:
    environment = dict(os.environ)
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    return subprocess.check_output(
        ["git", "-C", repository, *arguments],
        stderr=subprocess.DEVNULL,
        env=environment,
    )


def coordination_commit(repository: str, oid: str) -> Tuple[str, List[str]]:
    if git_bytes(repository, "cat-file", "-t", oid).strip() != b"commit":
        raise ValueError("writer coordination history contains a non-commit object")
    raw = git_bytes(repository, "cat-file", "-p", oid)
    header = raw.split(b"\n\n", 1)[0].splitlines()
    trees = [line[5:].decode("ascii") for line in header if line.startswith(b"tree ")]
    parents = [line[7:].decode("ascii") for line in header if line.startswith(b"parent ")]
    if len(trees) != 1 or len(parents) > 1:
        raise ValueError("writer coordination history is not a single-parent chain")
    return trees[0], parents


def coordination_descends_from(repository: str, tip: str, anchor: str) -> bool:
    seen = set()
    current = tip
    while current not in seen:
        if current == anchor:
            return True
        seen.add(current)
        _, parents = coordination_commit(repository, current)
        if not parents:
            return False
        current = parents[0]
    raise ValueError("writer coordination history contains a cycle")


def secure_directory_flags() -> int:
    try:
        return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    except AttributeError as exc:
        raise ValueError("secure anchor directory operations are unavailable") from exc


def secure_file_flags(access: int) -> int:
    try:
        return access | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    except AttributeError as exc:
        raise ValueError("secure anchor file operations are unavailable") from exc


def validate_anchor_inode(status: os.stat_result, kind: str) -> None:
    if not stat.S_ISREG(status.st_mode):
        raise ValueError("writer {} is not a regular file".format(kind))
    if status.st_nlink != 1:
        raise ValueError("writer {} must have exactly one link".format(kind))
    if status.st_uid != os.geteuid() or status.st_mode & 0o022:
        raise ValueError("writer {} ownership or mode is unsafe".format(kind))


def open_anchor_directory(common_dir: str, create: bool) -> Optional[int]:
    common = os.open(common_dir, secure_directory_flags())
    created = False
    try:
        if create:
            try:
                os.mkdir("workbench-v2", 0o700, dir_fd=common)
                created = True
                os.fsync(common)
            except FileExistsError:
                pass
        try:
            directory = os.open(
                "workbench-v2", secure_directory_flags(), dir_fd=common
            )
        except FileNotFoundError:
            if create:
                raise
            return None
    finally:
        os.close(common)
    status = os.fstat(directory)
    if not stat.S_ISDIR(status.st_mode):
        os.close(directory)
        raise ValueError("writer anchor parent is not a directory")
    if status.st_uid != os.geteuid() or status.st_mode & 0o022:
        os.close(directory)
        raise ValueError("writer anchor parent ownership or mode is unsafe")
    if created:
        os.fchmod(directory, 0o700)
        os.fsync(directory)
    return directory


def open_anchor_lock(directory: int) -> int:
    name = "writer-coordination-anchor.lock"
    flags = secure_file_flags(os.O_RDWR)
    lock = -1
    for _ in range(8):
        try:
            lock = os.open(
                name, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory
            )
            break
        except FileExistsError:
            try:
                lock = os.open(name, flags, dir_fd=directory)
                break
            except FileNotFoundError:
                continue
        except FileNotFoundError:
            continue
    if lock < 0:
        raise OSError("writer coordination anchor lock could not be opened")
    try:
        validate_anchor_inode(os.fstat(lock), "anchor lock")
        os.fchmod(lock, 0o600)
    except Exception:
        os.close(lock)
        raise
    return lock


def acquire_anchor_lock(lock: int, exclusive: bool, timeout: float = 5.0) -> None:
    operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(lock, operation | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError("writer coordination anchor lock timed out")
            time.sleep(0.01)


def read_anchor_at(directory: int) -> Optional[str]:
    name = "writer-coordination-anchor"
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return None
    validate_anchor_inode(before, "coordination anchor")
    descriptor = os.open(
        name, secure_file_flags(os.O_RDONLY), dir_fd=directory
    )
    try:
        after = os.fstat(descriptor)
        validate_anchor_inode(after, "coordination anchor")
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError("writer coordination anchor changed while opening")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            raw = handle.read()
    finally:
        os.close(descriptor)
    if re.fullmatch(b"[0-9a-f]{40}([0-9a-f]{24})?\\n", raw) is None:
        raise ValueError("writer coordination anchor is not canonical")
    return raw[:-1].decode("ascii")


def read_coordination_anchor(common_dir: str) -> Optional[str]:
    directory = open_anchor_directory(common_dir, False)
    if directory is None:
        return None
    lock = -1
    try:
        lock = open_anchor_lock(directory)
        acquire_anchor_lock(lock, False)
        return read_anchor_at(directory)
    finally:
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def write_coordination_anchor(
    common_dir: str, oid: str, repository: Optional[str] = None
) -> None:
    if re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", oid) is None:
        raise ValueError("writer coordination anchor is not a Git object ID")
    directory = open_anchor_directory(common_dir, True)
    if directory is None:
        raise ValueError("writer anchor parent is unavailable")
    lock = -1
    temporary = ""
    descriptor = -1
    try:
        lock = open_anchor_lock(directory)
        acquire_anchor_lock(lock, True)
        current = read_anchor_at(directory)
        if current is not None:
            if current == oid:
                return
            if repository is None:
                raise ValueError("writer coordination anchor cannot move backwards")
            if coordination_descends_from(repository, current, oid):
                return
            if not coordination_descends_from(repository, oid, current):
                raise ValueError("writer coordination anchor histories diverged")
        temporary = ".writer-coordination-anchor.tmp-{}".format(
            secrets.token_hex(16)
        )
        descriptor = os.open(
            temporary,
            secure_file_flags(os.O_WRONLY) | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=directory,
        )
        os.fchmod(descriptor, 0o600)
        payload = (oid + "\n").encode("ascii")
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("short writer coordination anchor write")
            offset += written
        os.fsync(descriptor)
        opened = os.fstat(descriptor)
        validate_anchor_inode(opened, "anchor temporary file")
        named = os.stat(temporary, dir_fd=directory, follow_symlinks=False)
        validate_anchor_inode(named, "anchor temporary file")
        if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
            raise ValueError("writer anchor temporary path changed before replace")
        # The owner-controlled, non-group-writable directory plus this advisory lock is
        # the concurrency boundary for supported writer processes. A same-UID process
        # that ignores the lock can already rewrite the surrounding Git common dir.
        os.replace(
            temporary,
            "writer-coordination-anchor",
            src_dir_fd=directory,
            dst_dir_fd=directory,
        )
        installed = os.stat(
            "writer-coordination-anchor", dir_fd=directory, follow_symlinks=False
        )
        validate_anchor_inode(installed, "coordination anchor")
        if (opened.st_dev, opened.st_ino) != (installed.st_dev, installed.st_ino):
            raise ValueError("writer coordination anchor replacement was not exact")
        os.fsync(directory)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        # Preserve an exclusive temp inode on failure. Name-based cleanup would add a
        # check/unlink race and could remove a concurrently substituted directory entry.
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def cmd_coordination_anchor_read(args: argparse.Namespace) -> None:
    anchor = read_coordination_anchor(args.common_dir)
    if anchor is not None:
        print(anchor)


def cmd_coordination_anchor_write(args: argparse.Namespace) -> None:
    write_coordination_anchor(args.common_dir, args.oid, args.repository)


def coordination_ledger_bytes(repository: str, oid: str) -> bytes:
    raw = git_bytes(repository, "ls-tree", "-z", oid)
    entries = [entry for entry in raw.split(b"\0") if entry]
    if len(entries) != 1:
        raise ValueError("writer coordination tree must contain exactly one entry")
    metadata, separator, name = entries[0].partition(b"\t")
    fields = metadata.split(b" ")
    if separator != b"\t" or name != b"writer-claims.tsv" or fields[:2] != [b"100644", b"blob"]:
        raise ValueError("writer coordination tree entry is not canonical")
    return git_bytes(repository, "show", oid + ":writer-claims.tsv")


def ledger_row_identity(row: Mapping[str, str]) -> Tuple[str, ...]:
    fields = CLAIM_FIELDS if row["kind"] == "claim" else EFFECT_FIELDS
    return tuple(row[field] for field in fields)


def validate_coordination_transition(
    previous: Sequence[Mapping[str, str]], current: Sequence[Mapping[str, str]]
) -> None:
    prior = {ledger_row_identity(row): row for row in previous}
    present = {ledger_row_identity(row): row for row in current}
    if not set(prior).issubset(present) or len(present) != len(prior) + 1:
        raise ValueError("writer coordination commit must append exactly one immutable row")
    added_identity = next(iter(set(present) - set(prior)))
    added = present[added_identity]
    identity = (added["operation_id"], added["claim_id"])
    claims = [
        row
        for row in previous
        if row["kind"] == "claim"
        and (row["operation_id"], row["claim_id"]) == identity
    ]
    effects = [
        row
        for row in previous
        if row["kind"] == "effect-owner"
        and (row["operation_id"], row["claim_id"]) == identity
    ]
    if added["kind"] == "claim":
        if added["state"] == "active":
            if claims or effects or any(
                row["operation_id"] == added["operation_id"]
                or row["claim_id"] == added["claim_id"]
                for row in previous
            ):
                raise ValueError("writer active claim is not the first event for its identity")
            return
        if len(claims) != 1 or claims[0]["state"] != "active":
            raise ValueError("writer claim release has no unique active predecessor")
        if any(
            added[field] != claims[0][field] for field in CLAIM_FIELDS[1:-1]
        ):
            raise ValueError("writer claim release rewrites its active binding")
        effect = latest_effect(effects)
        if effect is not None and effect["state"] == "acquired":
            raise ValueError("writer claim released before its effect owner")
        return

    if len(claims) != 1 or claims[0]["state"] != "active":
        raise ValueError("writer effect event requires a currently active claim")
    if any(
        row["event_id"] == added["event_id"]
        for row in previous
        if row["kind"] == "effect-owner"
    ):
        raise ValueError("writer effect event ID was reused")
    prior_event_ids = [
        row["event_id"] for row in previous if row["kind"] == "effect-owner"
    ]
    if prior_event_ids and added["event_id"] <= max(prior_event_ids):
        raise ValueError("writer effect event ID did not advance monotonically")
    effect = latest_effect(effects)
    owner = (added["device_id"], added["clone_id"])
    if added["state"] == "acquired":
        if effect is not None and effect["state"] == "acquired":
            raise ValueError("writer effect owner was acquired discontinuously")
    elif (
        effect is None
        or effect["state"] != "acquired"
        or (effect["device_id"], effect["clone_id"]) != owner
    ):
        raise ValueError("writer effect owner release has no matching acquisition")


def cmd_coordination_history(args: argparse.Namespace) -> None:
    if re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", args.tip) is None:
        raise ValueError("writer coordination tip is not a Git object ID")
    reverse_chain: List[str] = []
    seen = set()
    current = args.tip
    while True:
        if current in seen:
            raise ValueError("writer coordination history contains a cycle")
        seen.add(current)
        reverse_chain.append(current)
        _, parents = coordination_commit(args.repository, current)
        if not parents:
            break
        current = parents[0]
    chain = list(reversed(reverse_chain))
    for anchor in args.anchor:
        if re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", anchor) is None:
            raise ValueError("writer coordination anchor is not a Git object ID")
        if anchor not in seen:
            raise ValueError("writer coordination history does not descend from a trusted anchor")
    previous_rows: List[Dict[str, str]] = []
    final_raw = b""
    with tempfile.TemporaryDirectory(prefix="workbench-writer-history-") as directory:
        for index, oid in enumerate(chain):
            raw = coordination_ledger_bytes(args.repository, oid)
            ledger = os.path.join(directory, "{}.tsv".format(index))
            with open(ledger, "wb") as handle:
                handle.write(raw)
            rows, final_raw = read_ledger(ledger)
            if index == 0:
                if rows:
                    raise ValueError("writer coordination root must be header-only")
            else:
                validate_coordination_transition(previous_rows, rows)
            previous_rows = rows
    with open(args.output, "wb") as handle:
        handle.write(final_raw)
    write_json(
        {
            "contract_version": "workbench-writer-history-validation/v1",
            "tip": args.tip,
            "root": chain[0],
            "commits": len(chain),
            "events": len(previous_rows),
        }
    )


STATUS_CLAIM_FIELDS = (
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


def operation_claim_binding(operation: Mapping[str, Any]) -> Dict[str, str]:
    return {
        "task_claim_id": operation["task_claim_id"],
        "owner": operation["owner"],
        "branch": operation["branch"],
        "expected_path": operation["expected_path"],
        "codebase_origin_url": operation["codebase_origin_url"],
        "context_policy_set_digest": operation["context_policy_set_digest"],
    }


def validate_status_claim(value: Any) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != set(STATUS_CLAIM_FIELDS):
        raise ValueError("legacy status claim fields do not match the contract")
    if value["source"] != "legacy-v1" or value["operation_id"] is not None:
        raise ValueError("invalid legacy status claim identity")
    for key in ("claim_id", "task_claim_id", "owner", "branch"):
        if not isinstance(value[key], str):
            raise ValueError("legacy status claim {} must be a string".format(key))
        require_text(value[key], key)
    if value["context_policy_set_digest"] is not None:
        raise ValueError("legacy status claim cannot carry a v2 context digest")
    for key in ("source_revision", "pr_head_revision"):
        item = value[key]
        if item is not None and (
            not isinstance(item, str) or re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", item) is None
        ):
            raise ValueError("invalid legacy status {}".format(key))
    if value["source_revision"] is None:
        raise ValueError("active legacy status claim requires source_revision")
    if not isinstance(value["lifecycle_digest"], str):
        raise ValueError("legacy lifecycle digest must be a string")
    require_digest(value["lifecycle_digest"], "lifecycle_digest")
    return value


def ordered_record(path: Path, fields: Sequence[str]) -> Dict[str, str]:
    value: Dict[str, str] = {}
    order: List[str] = []
    with path.open("r", encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            if not raw.endswith("\n") or "=" not in raw:
                raise ValueError("malformed local writer record line {}".format(lineno))
            key, item = raw[:-1].split("=", 1)
            if not key or key in value or "\t" in key or "\r" in item:
                raise ValueError("invalid local writer record")
            value[key] = item
            order.append(key)
    if tuple(order) != tuple(fields):
        raise ValueError("local writer record fields or order do not match")
    return value


def git_value(cwd: Path, *args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(cwd), *args],
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()


def resolve_git_path(cwd: Path, value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        path = cwd / path
    return Path(os.path.realpath(path))


def task_frontmatter(index: Path) -> Dict[str, str]:
    lines = index.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise ValueError("task index has no frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError as exc:
        raise ValueError("task index frontmatter is unterminated") from exc
    value: Dict[str, str] = {}
    for line in lines[1:end]:
        if ": " not in line:
            continue
        key, item = line.split(": ", 1)
        if key in value:
            raise ValueError("duplicate task index frontmatter field")
        value[key] = item
    return value


def local_writer_effects_match(operation_path: str, operation: Mapping[str, Any]) -> bool:
    path = Path(operation_path).resolve()
    if (
        path.parent.name != "writer-operations"
        or path.parent.parent.name != ".workbench"
        or path.parent.parent.parent.name != "task"
    ):
        return False
    task_root = path.parents[3]
    if task_root.parent.name != ".worktrees":
        return False
    workspace = task_root.parent.parent
    index = task_root / "task/index.md"
    frontmatter = task_frontmatter(index)
    if (
        frontmatter.get("claim_id") != operation["task_claim_id"]
        or frontmatter.get("branch") != operation["branch"]
    ):
        return False
    issue = frontmatter.get("issue", "")
    slug = frontmatter.get("slug", "")
    parent = frontmatter.get("parent", "")
    if not issue.isdigit() or not slug:
        return False
    codebase_branch = "task/{}{}-{}".format(parent + "/" if parent else "", issue, slug)
    expected_repo_row = "- {} | {} | work".format(operation["owner"], codebase_branch)
    index_lines = index.read_text(encoding="utf-8").splitlines()
    row_path = task_root / "task/.workbench/writer-rows/{}.record".format(operation["owner"])
    worktree = task_root / operation["expected_path"]
    if operation["stage"] == "handoff-ready":
        return (
            index_lines.count(expected_repo_row) == 0
            and not row_path.exists()
            and not worktree.exists()
        )
    if index_lines.count(expected_repo_row) != 1:
        return False
    row_fields = (
        "operation_id",
        "claim_id",
        "owner",
        "task_claim_id",
        "branch",
        "expected_path",
        "codebase_origin_url",
        "registry_revision",
        "registry_digest",
        "context_policy_set_digest",
        "action_instance_id",
        "intent_digest",
        "policy_manifest_digest",
        "authorization_ref",
    )
    row = ordered_record(
        row_path,
        row_fields,
    )
    policy = operation["policy_manifest"]
    expected_row = {
        "operation_id": operation["operation_id"],
        "claim_id": operation["claim_id"],
        "owner": operation["owner"],
        "task_claim_id": operation["task_claim_id"],
        "branch": codebase_branch,
        "expected_path": operation["expected_path"],
        "codebase_origin_url": operation["codebase_origin_url"],
        "registry_revision": operation["registry_revision"],
        "registry_digest": operation["registry_digest"],
        "context_policy_set_digest": operation["context_policy_set_digest"],
        "action_instance_id": operation["action_instance_id"] or "",
        "intent_digest": operation["intent_digest"] or "",
        "policy_manifest_digest": "" if policy is None else policy["digest"],
        "authorization_ref": operation["authorization_ref"] or "",
    }
    if row != expected_row:
        return False
    if operation["stage"] != "consumed":
        return True

    cache = workspace / ".codebases" / operation["owner"]
    if not worktree.is_dir() or not cache.is_dir():
        return False
    if git_value(worktree, "symbolic-ref", "--short", "HEAD") != codebase_branch:
        return False
    if git_value(worktree, "remote", "get-url", "origin") != operation["codebase_origin_url"]:
        return False
    if git_value(cache, "remote", "get-url", "origin") != operation["codebase_origin_url"]:
        return False
    worktree_common = resolve_git_path(worktree, git_value(worktree, "rev-parse", "--git-common-dir"))
    cache_common = resolve_git_path(cache, git_value(cache, "rev-parse", "--git-common-dir"))
    if worktree_common != cache_common:
        return False
    gitdir = resolve_git_path(worktree, git_value(worktree, "rev-parse", "--git-dir"))
    with (gitdir / "workbench-writer-owner.json").open("r", encoding="utf-8") as handle:
        marker = json.load(handle, object_pairs_hook=unique_object)
    expected_marker = {
        "contract_version": "workbench-writer-worktree-owner/v1",
        "operation_id": operation["operation_id"],
        "claim_id": operation["claim_id"],
        "task_claim_id": operation["task_claim_id"],
        "expected_path": operation["expected_path"],
        "branch": codebase_branch,
        "codebase_origin_url": operation["codebase_origin_url"],
    }
    return marker == expected_marker


def operation_local_facts(operation_path: str, operation: Mapping[str, Any]) -> Dict[str, Any]:
    path = Path(operation_path).resolve()
    if (
        path.parent.name != "writer-operations"
        or path.parent.parent.name != ".workbench"
        or path.parent.parent.parent.name != "task"
    ):
        raise ValueError("writer operation is outside a task state directory")
    task_root = path.parents[3]
    if task_root.parent.name != ".worktrees":
        raise ValueError("writer operation task workspace is not canonical")
    workspace = task_root.parent.parent
    index = task_root / "task/index.md"
    frontmatter = task_frontmatter(index)
    if (
        frontmatter.get("claim_id") != operation["task_claim_id"]
        or frontmatter.get("branch") != operation["branch"]
    ):
        raise ValueError("writer operation does not bind the current task")
    issue = frontmatter.get("issue", "")
    slug = frontmatter.get("slug", "")
    parent = frontmatter.get("parent", "")
    if not issue.isdigit() or not slug:
        raise ValueError("writer operation task identity is malformed")
    codebase_branch = "task/{}{}-{}".format(parent + "/" if parent else "", issue, slug)
    expected_row = "- {} | {} | work".format(operation["owner"], codebase_branch)
    row_count = index.read_text(encoding="utf-8").splitlines().count(expected_row)
    row_path = task_root / "task/.workbench/writer-rows/{}.record".format(operation["owner"])
    worktree = task_root / operation["expected_path"]
    cache = workspace / ".codebases" / operation["owner"]
    attached = False
    if cache.is_dir():
        raw = subprocess.check_output(
            ["git", "-C", str(cache), "worktree", "list", "--porcelain", "-z"],
            stderr=subprocess.DEVNULL,
        )
        for block in raw.split(b"\0\0"):
            fields: Dict[bytes, bytes] = {}
            for item in block.strip(b"\0").split(b"\0"):
                if not item:
                    continue
                key, _, value = item.partition(b" ")
                if key in fields:
                    raise ValueError("duplicate worktree porcelain field")
                fields[key] = value
            candidate = fields.get(b"worktree")
            branch = fields.get(b"branch")
            if (
                candidate is not None
                and os.path.realpath(os.fsdecode(candidate)) == os.path.realpath(worktree)
            ) or branch == ("refs/heads/" + codebase_branch).encode("utf-8"):
                attached = True
    return {
        "worktree_present": worktree.exists() or worktree.is_symlink(),
        "worktree_attached": attached,
        "repo_record_present": row_path.exists() or row_path.is_symlink(),
        "repo_index_rows": row_count,
    }


def operation_remote_state(
    rows: Sequence[Mapping[str, str]], operation: Mapping[str, Any]
) -> Tuple[str, Optional[Dict[str, str]]]:
    claims = [
        row
        for row in rows
        if row["kind"] == "claim"
        and row["operation_id"] == operation["operation_id"]
        and row["claim_id"] == operation["claim_id"]
    ]
    expected = operation_claim_binding(operation)
    if any(any(row[key] != item for key, item in expected.items()) for row in claims):
        raise ValueError("writer claim does not join the exact local operation")
    effects = [
        row
        for row in rows
        if row["kind"] == "effect-owner"
        and row["operation_id"] == operation["operation_id"]
        and row["claim_id"] == operation["claim_id"]
    ]
    return current_claim_state(claims), latest_effect(effects)


def cmd_operation_status(args: argparse.Namespace) -> None:
    operation = load_operation(args.operation_file)
    rows, _ = read_ledger(args.ledger_file)
    claim_state, effect = operation_remote_state(rows, operation)
    local = operation_local_facts(args.operation_file, operation)
    no_local_effect = (
        not local["worktree_present"]
        and not local["worktree_attached"]
        and not local["repo_record_present"]
        and local["repo_index_rows"] == 0
    )
    cancellable = (
        operation["stage"] in ("prepared", "authorization-pending", "cancelled")
        and claim_state == "absent"
        and effect is None
        and no_local_effect
    )
    blockers: List[Dict[str, str]] = []
    if not cancellable and operation["stage"] != "cancelled":
        blockers.append(
            {"code": "writer-cancel-has-effects", "ref": operation["operation_id"]}
        )
    write_json(
        {
            "contract_version": "workbench-writer-operation-status/v1",
            "operation": operation,
            "remote_claim_state": claim_state,
            "effect_owner": effect,
            "local_effects": local,
            "cancellable": cancellable,
            "blockers": blockers,
        }
    )


def cmd_operation_handoff(args: argparse.Namespace) -> None:
    operation = load_operation(args.operation_file)
    rows, _ = read_ledger(args.ledger_file)
    claim_state, effect = operation_remote_state(rows, operation)
    if (
        operation["stage"] != "compensation-pending"
        or operation["compensation_target"] != "reserved"
        or operation["compensation_reason"] != "handoff"
        or operation["compensation_next_step"] != "finish"
        or operation["effect_owner_state"] != "released"
        or operation["worktree_ownership"] != "none"
        or operation["repo_record_ownership"] != "none"
        or claim_state != "active"
        or effect is None
        or effect["state"] != "released"
        or effect["device_id"] != operation["device_id"]
        or effect["clone_id"] != operation["clone_id"]
    ):
        raise ValueError("writer handoff preconditions do not reconcile")
    local = operation_local_facts(args.operation_file, operation)
    if (
        local["worktree_present"]
        or local["worktree_attached"]
        or local["repo_record_present"]
        or local["repo_index_rows"] != 0
    ):
        raise ValueError("writer handoff still has local effects")
    require_text(args.to_device_id, "to_device_id")
    if UUID.fullmatch(args.to_clone_id) is None:
        raise ValueError("to_clone_id must be a lowercase UUID")
    operation["device_id"] = args.to_device_id
    operation["clone_id"] = args.to_clone_id
    operation["stage"] = "handoff-ready"
    operation["compensation_target"] = None
    operation["compensation_reason"] = None
    operation["compensation_next_step"] = None
    ordered = {field: operation[field] for field in OPERATION_FIELDS}
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(ordered, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
    load_operation(args.output)


def cmd_status_projection(args: argparse.Namespace) -> None:
    rows, _ = read_ledger(args.ledger_file)
    legacy = load_json(args.legacy_inventory_file)
    expected_top = (
        "contract_version",
        "source_revision",
        "authority",
        "home_set",
        "homes",
        "active_claims",
        "origin_replacements",
        "complete",
        "blockers",
    )
    if not isinstance(legacy, dict) or set(legacy) != set(expected_top):
        raise ValueError("legacy inventory fields do not match the public contract")
    if (
        legacy["contract_version"] != "workbench-legacy-inventory/v1"
        or legacy["complete"] is not True
        or legacy["blockers"] != []
    ):
        raise ValueError("legacy inventory is not complete")
    claims: List[Mapping[str, Any]] = []
    for item in legacy["active_claims"]:
        claims.append(validate_status_claim(item))
    for row in current_active_claims(rows):
        claims.append(
            {
                "source": "ledger-v2",
                "claim_id": row["claim_id"],
                "operation_id": row["operation_id"],
                "task_claim_id": row["task_claim_id"],
                "owner": row["owner"],
                "branch": row["branch"],
                "context_policy_set_digest": row["context_policy_set_digest"],
                "source_revision": None,
                "pr_head_revision": None,
                "lifecycle_digest": None,
            }
        )
    claims.sort(key=lambda item: (item["source"], item["claim_id"], item["branch"]))

    blockers: List[Dict[str, str]] = []
    for path in sorted(args.operation_file):
        operation = load_operation(path)
        matching_claims = [
            row
            for row in rows
            if row["kind"] == "claim"
            and row["operation_id"] == operation["operation_id"]
            and row["claim_id"] == operation["claim_id"]
        ]
        matching_effects = [
            row
            for row in rows
            if row["kind"] == "effect-owner"
            and row["operation_id"] == operation["operation_id"]
            and row["claim_id"] == operation["claim_id"]
        ]
        expected = operation_claim_binding(operation)
        binding_matches = all(
            all(row[key] == item for key, item in expected.items()) for row in matching_claims
        )
        claim_state = current_claim_state(matching_claims)
        effect = latest_effect(matching_effects)
        effect_state = "none" if effect is None else effect["state"]
        stage = operation["stage"]
        valid = binding_matches
        if stage == "consumed":
            valid = valid and claim_state == "active" and effect_state == "acquired"
        elif stage == "handoff-ready":
            valid = valid and claim_state == "active" and effect_state == "released"
        elif stage == "released":
            valid = valid and claim_state == "released" and effect_state != "acquired"
        elif stage == "cancelled":
            valid = valid and claim_state == "absent" and effect_state == "none"
        else:
            blockers.append(
                {"code": "writer-operation-incomplete", "ref": operation["operation_id"]}
            )
            continue
        if valid and stage in ("consumed", "handoff-ready"):
            try:
                valid = local_writer_effects_match(path, operation)
            except (OSError, UnicodeError, ValueError, subprocess.SubprocessError, json.JSONDecodeError):
                valid = False
        if not valid:
            blockers.append(
                {"code": "writer-claim-unreconciled", "ref": operation["operation_id"]}
            )

    by_owner: DefaultDict[str, List[Mapping[str, Any]]] = defaultdict(list)
    for claim in claims:
        by_owner[claim["owner"]].append(claim)
    conflicts = [
        {"owner": owner, "claims": by_owner[owner]}
        for owner in sorted(by_owner)
        if len(by_owner[owner]) > 1
    ]
    blockers.sort(key=lambda item: (item["code"], item["ref"]))
    write_json(
        {
            "writer_conflicts": conflicts,
            "writer_integrity_blockers": blockers,
        }
    )


def cmd_ledger_state(args: argparse.Namespace) -> None:
    rows, raw = read_ledger(args.file)
    matching_claims = [
        row
        for row in rows
        if row["kind"] == "claim"
        and row["operation_id"] == args.operation_id
        and row["claim_id"] == args.claim_id
    ]
    matching_effects = [
        row
        for row in rows
        if row["kind"] == "effect-owner"
        and row["operation_id"] == args.operation_id
        and row["claim_id"] == args.claim_id
    ]
    if args.operation_file is not None:
        operation = load_operation(args.operation_file)
        if (
            operation["operation_id"] != args.operation_id
            or operation["claim_id"] != args.claim_id
        ):
            raise ValueError("writer operation identity does not match the ledger query")
        expected = operation_claim_binding(operation)
        for claim in matching_claims:
            if any(claim[key] != item for key, item in expected.items()):
                raise ValueError("writer claim does not join the exact local operation")
    value = {
        "contract_version": "workbench-writer-ledger-state/v1",
        "operation_id": args.operation_id,
        "claim_id": args.claim_id,
        "claim_state": current_claim_state(matching_claims),
        "effect_owner": latest_effect(matching_effects),
        "ledger_digest": sha256(raw),
    }
    if args.format == "json":
        write_json(value)
    else:
        for key in ("operation_id", "claim_id", "claim_state", "ledger_digest"):
            sys.stdout.write("{}={}\n".format(key, value[key]))
        effect = value["effect_owner"]
        for key in ("event_id", "device_id", "clone_id", "state"):
            sys.stdout.write("effect_owner_{}={}\n".format(key, "" if effect is None else effect[key]))


def cmd_task_bijection(args: argparse.Namespace) -> None:
    rows, _ = read_ledger(args.ledger_file)
    operations = [load_operation(path) for path in args.operation_file]
    local: Dict[Tuple[str, str], Dict[str, Any]] = {}
    for operation in operations:
        identity = (operation["operation_id"], operation["claim_id"])
        if identity in local:
            raise ValueError("duplicate local writer operation identity")
        if operation["task_claim_id"] != args.task_claim_id:
            raise ValueError("local writer operation belongs to another task")
        local[identity] = operation

    remote: DefaultDict[Tuple[str, str], List[Mapping[str, str]]] = defaultdict(list)
    for row in rows:
        if row["kind"] == "claim" and row["task_claim_id"] == args.task_claim_id:
            remote[(row["operation_id"], row["claim_id"])].append(row)

    blockers = set()
    for identity, claims in remote.items():
        operation = local.get(identity)
        if operation is None:
            blockers.add(identity[0])
            continue
        expected = operation_claim_binding(operation)
        if any(any(row[key] != item for key, item in expected.items()) for row in claims):
            blockers.add(identity[0])

    unpublished = {"prepared", "authorization-pending", "cancelled"}
    for identity, operation in local.items():
        has_remote = identity in remote
        if operation["stage"] in unpublished:
            if has_remote:
                blockers.add(operation["operation_id"])
        elif not has_remote:
            blockers.add(operation["operation_id"])

    row_identities = set()
    for path in args.writer_row_file:
        row = ordered_record(Path(path), WRITER_CONTENT_FIELDS)
        identity = (row["operation_id"], row["claim_id"])
        if identity in row_identities:
            blockers.add(row["operation_id"])
            continue
        row_identities.add(identity)
        operation = local.get(identity)
        if (
            operation is None
            or operation["stage"] != "consumed"
            or row["task_claim_id"] != args.task_claim_id
            or row["owner"] != operation["owner"]
        ):
            blockers.add(row["operation_id"])

    consumed_owners = {
        operation["owner"]
        for operation in local.values()
        if operation["stage"] == "consumed"
    }
    for owner in args.repo_owner:
        if owner not in consumed_owners:
            blockers.add(owner)
    for item in sorted(blockers):
        sys.stdout.write("blocker={}\n".format(item))


def cmd_operation(args: argparse.Namespace) -> None:
    value = load_operation(args.file)
    if args.format == "json":
        write_json(value)
    else:
        for key in OPERATION_FIELDS:
            item = value[key]
            if isinstance(item, dict):
                item = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
            elif item is None:
                item = ""
            sys.stdout.write("{}={}\n".format(key, item))


def exact_managed_path(root: Path, raw: str, field: str) -> Tuple[str, str]:
    if not os.path.isabs(raw):
        raise ValueError("{} must be an absolute path".format(field))
    normalized = os.path.normpath(raw)
    lexical = Path(normalized)
    try:
        relative = lexical.relative_to(root)
    except ValueError as exc:
        raise ValueError("{} is outside the managed workspace".format(field)) from exc
    current = root
    if current.is_symlink():
        raise ValueError("{} contains a symlink component".format(field))
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("{} contains a symlink component".format(field))
    try:
        root_real = root.resolve(strict=True)
        real = lexical.resolve(strict=True)
    except OSError as exc:
        raise ValueError("{} is unavailable".format(field)) from exc
    expected_real = root_real.joinpath(relative)
    if real != expected_real:
        raise ValueError("{} lexical and real paths do not match".format(field))
    return normalized, str(real)


def exact_git_path(root: Path, repository: str, argument: str, field: str) -> Tuple[str, str]:
    raw = git_value(Path(repository), "rev-parse", argument)
    if not os.path.isabs(raw):
        raw = os.path.normpath(os.path.join(repository, raw))
    try:
        relative = Path(raw).resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError, ValueError) as exc:
        raise ValueError("{} is outside the managed workspace".format(field)) from exc
    return exact_managed_path(root, str(root.joinpath(relative)), field)


def exact_worktree_record(clone: str, worktree: str, branch: str) -> None:
    raw = subprocess.check_output(
        ["git", "-C", clone, "worktree", "list", "--porcelain", "-z"],
        stderr=subprocess.DEVNULL,
    )
    matches = []
    branch_matches = []
    for block in raw.split(b"\0\0"):
        fields: Dict[str, Optional[str]] = {}
        for encoded in block.strip(b"\0").split(b"\0"):
            if not encoded:
                continue
            key_raw, separator, value_raw = encoded.partition(b" ")
            key = key_raw.decode("ascii")
            if key in fields:
                raise ValueError("duplicate worktree porcelain field")
            fields[key] = value_raw.decode("utf-8") if separator else None
        if not fields:
            continue
        candidate = fields.get("worktree")
        if isinstance(candidate, str) and os.path.realpath(candidate) == os.path.realpath(worktree):
            matches.append(fields)
        if fields.get("branch") == "refs/heads/" + branch:
            branch_matches.append(fields)
    if len(matches) != 1 or len(branch_matches) != 1 or matches[0] is not branch_matches[0]:
        raise ValueError("cleanup worktree is not the exact pinned attachment")
    record = matches[0]
    if set(record) - {"worktree", "HEAD", "branch"}:
        raise ValueError("cleanup worktree has an unsupported attachment state")


def cmd_cleanup_descriptor(args: argparse.Namespace) -> None:
    operation = load_operation(args.operation_file)
    if not os.path.isabs(args.workspace_root):
        raise ValueError("workspace root must be absolute")
    root_raw = os.path.normpath(args.workspace_root)
    root = Path(root_raw)
    task_expected = os.path.join(
        root_raw, ".worktrees", operation["branch"].replace("/", "__")
    )
    worktree_expected = os.path.join(task_expected, operation["expected_path"])
    clone_expected = os.path.join(root_raw, ".codebases", operation["owner"])
    task_arg = os.path.normpath(args.task_dir)
    worktree_arg = os.path.normpath(args.worktree)
    clone_arg = os.path.normpath(args.clone)
    if task_arg != task_expected or worktree_arg != worktree_expected:
        raise ValueError("cleanup worktree path does not bind the operation")
    if clone_arg != clone_expected:
        raise ValueError("cleanup clone path does not bind the registered owner")

    task_lexical, task_real = exact_managed_path(root, task_arg, "task workspace")
    worktree_lexical, worktree_real = exact_managed_path(root, worktree_arg, "worktree")
    clone_lexical, clone_real = exact_managed_path(root, clone_arg, "clone")
    task_common, task_common_real = exact_git_path(
        root, task_arg, "--git-common-dir", "task common directory"
    )
    root_common, root_common_real = exact_git_path(
        root, root_raw, "--git-common-dir", "workspace common directory"
    )
    if (task_common, task_common_real) != (root_common, root_common_real):
        raise ValueError("cleanup task does not use the workspace common directory")
    clone_common, clone_common_real = exact_git_path(
        root, clone_arg, "--git-common-dir", "clone common directory"
    )
    clone_git_dir, clone_git_dir_real = exact_git_path(
        root, clone_arg, "--absolute-git-dir", "clone git directory"
    )
    if (clone_common, clone_common_real) != (clone_git_dir, clone_git_dir_real):
        raise ValueError("cleanup clone common directory is not its pinned admin directory")
    worktree_common, worktree_common_real = exact_git_path(
        root, worktree_arg, "--git-common-dir", "worktree common directory"
    )
    if (worktree_common, worktree_common_real) != (clone_common, clone_common_real):
        raise ValueError("cleanup worktree does not use the pinned clone common directory")
    worktree_git_dir, worktree_git_dir_real = exact_git_path(
        root, worktree_arg, "--git-dir", "worktree git directory"
    )

    if git_value(Path(task_arg), "symbolic-ref", "--short", "HEAD") != operation["branch"]:
        raise ValueError("cleanup task branch does not bind the operation")
    if git_value(Path(task_arg), "remote", "get-url", "origin") != args.workspace_origin_url:
        raise ValueError("cleanup task origin does not bind workspace authority")
    if git_value(Path(clone_arg), "remote", "get-url", "origin") != operation["codebase_origin_url"]:
        raise ValueError("cleanup clone origin does not bind the operation")
    if git_value(Path(worktree_arg), "remote", "get-url", "origin") != operation["codebase_origin_url"]:
        raise ValueError("cleanup worktree origin does not bind the operation")
    if git_value(Path(worktree_arg), "symbolic-ref", "--short", "HEAD") != args.codebase_branch:
        raise ValueError("cleanup worktree branch does not bind the task identity")
    exact_worktree_record(clone_arg, worktree_arg, args.codebase_branch)

    marker_path = os.path.join(worktree_git_dir, "workbench-writer-owner.json")
    marker_lexical, marker_real = exact_managed_path(root, marker_path, "ownership marker")
    raw_marker = Path(marker_path).read_bytes()
    if not raw_marker.endswith(b"\n") or b"\r" in raw_marker:
        raise ValueError("ownership marker is not canonical UTF-8 JSON")
    marker = json.loads(raw_marker.decode("utf-8"), object_pairs_hook=unique_object)
    expected_marker = {
        "contract_version": "workbench-writer-worktree-owner/v1",
        "operation_id": operation["operation_id"],
        "claim_id": operation["claim_id"],
        "task_claim_id": operation["task_claim_id"],
        "expected_path": operation["expected_path"],
        "branch": args.codebase_branch,
        "codebase_origin_url": operation["codebase_origin_url"],
    }
    if marker != expected_marker or list(marker) != list(expected_marker):
        raise ValueError("ownership marker does not bind the cleanup operation")

    descriptor = {
        "contract_version": "workbench-cleanup-worktree-ownership/v1",
        "lexical_path": worktree_lexical,
        "real_path": worktree_real,
        "task_workspace": task_lexical,
        "task_workspace_real": task_real,
        "task_common_dir": task_common,
        "task_common_dir_real": task_common_real,
        "workspace_common_dir": root_common,
        "workspace_common_dir_real": root_common_real,
        "clone_path": clone_lexical,
        "clone_real_path": clone_real,
        "clone_common_dir": clone_common,
        "clone_common_dir_real": clone_common_real,
        "clone_git_dir": clone_git_dir,
        "clone_git_dir_real": clone_git_dir_real,
        "worktree_common_dir": worktree_common,
        "worktree_common_dir_real": worktree_common_real,
        "worktree_git_dir": worktree_git_dir,
        "worktree_git_dir_real": worktree_git_dir_real,
        "task_branch": operation["branch"],
        "branch": args.codebase_branch,
        "workspace_origin_url": args.workspace_origin_url,
        "origin_url": operation["codebase_origin_url"],
        "operation_id": operation["operation_id"],
        "claim_id": operation["claim_id"],
        "task_claim_id": operation["task_claim_id"],
        "expected_path": operation["expected_path"],
        "marker_path": marker_lexical,
        "marker_real_path": marker_real,
        "marker_digest": sha256(raw_marker),
    }
    write_json(descriptor)


def parse_worktree_porcelain(file: str) -> List[Dict[str, Any]]:
    with open(file, "rb") as handle:
        raw = handle.read()
    records: List[Dict[str, Any]] = []
    allowed = {"worktree", "HEAD", "branch", "bare", "detached", "locked", "prunable"}
    for block in raw.split(b"\0\0"):
        if not block.strip(b"\0"):
            continue
        fields: Dict[str, Optional[str]] = {}
        for encoded in block.strip(b"\0").split(b"\0"):
            if not encoded:
                continue
            key_raw, separator, value_raw = encoded.partition(b" ")
            key = key_raw.decode("ascii")
            if key not in allowed or key in fields:
                raise ValueError("unsupported or duplicate worktree porcelain field")
            fields[key] = value_raw.decode("utf-8") if separator else None
        path = fields.get("worktree")
        if not isinstance(path, str) or not os.path.isabs(path):
            raise ValueError("worktree porcelain path must be absolute")
        if fields.get("branch") is not None and (
            "detached" in fields or "bare" in fields
        ):
            raise ValueError("worktree porcelain branch state is ambiguous")
        branch = fields.get("branch")
        if branch is not None and (
            not isinstance(branch, str) or not branch.startswith("refs/heads/")
        ):
            raise ValueError("worktree branch must be a full local ref")
        records.append({"path": os.path.realpath(path), "branch": branch})
    if not records:
        raise ValueError("worktree porcelain set is empty")
    if len(records) != len({item["path"] for item in records}):
        raise ValueError("duplicate worktree path")
    return records


def cmd_worktree_set(args: argparse.Namespace) -> None:
    records = parse_worktree_porcelain(args.porcelain_file)
    common = os.path.realpath(args.common_git_dir)
    expected_path = os.path.realpath(args.expected_path)
    for value, field in (
        (common, "common_git_dir"),
        (args.origin_url, "origin_url"),
        (expected_path, "expected_path"),
        (args.expected_branch, "expected_branch"),
    ):
        if not value or any(char in value for char in ("\t", "\r", "\n")):
            raise ValueError("{} cannot be represented canonically".format(field))
    matching = [
        item
        for item in records
        if item["path"] == expected_path or item["branch"] == args.expected_branch
    ]
    if args.recover_present:
        if len(matching) != 1 or matching[0] != {
            "path": expected_path,
            "branch": args.expected_branch,
        }:
            raise ValueError("expected recovery worktree is not an exact single attachment")
        records = [item for item in records if item is not matching[0]]
    elif matching:
        raise ValueError("expected worktree path or branch is not absent")
    rows = ["workbench-worktree-set/v1\n"]
    for item in sorted(records, key=lambda value: (value["path"], value["branch"] or "")):
        path = item["path"]
        if any(char in path for char in ("\t", "\r", "\n")):
            raise ValueError("worktree path cannot be represented canonically")
        rows.append(
            "worktree\t{}\t{}\t{}\t{}\n".format(
                path, item["branch"] or "null", common, args.origin_url
            )
        )
    raw = "".join(rows)
    if args.format == "manifest":
        sys.stdout.write(raw)
    else:
        sys.stdout.write(sha256(raw.encode("utf-8")) + "\n")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    ledger = commands.add_parser("ledger-state")
    ledger.add_argument("file")
    ledger.add_argument("--operation-id", required=True)
    ledger.add_argument("--claim-id", required=True)
    ledger.add_argument("--operation-file")
    ledger.add_argument("--format", choices=("json", "shell"), required=True)
    ledger.set_defaults(func=cmd_ledger_state)
    bijection = commands.add_parser("task-bijection")
    bijection.add_argument("--ledger-file", required=True)
    bijection.add_argument("--task-claim-id", required=True)
    bijection.add_argument("--operation-file", action="append", default=[])
    bijection.add_argument("--writer-row-file", action="append", default=[])
    bijection.add_argument("--repo-owner", action="append", default=[])
    bijection.set_defaults(func=cmd_task_bijection)
    validate = commands.add_parser("ledger-validate")
    validate.add_argument("file")
    validate.set_defaults(func=cmd_ledger_validate)
    history = commands.add_parser("coordination-history")
    history.add_argument("--repository", required=True)
    history.add_argument("--tip", required=True)
    history.add_argument("--output", required=True)
    history.add_argument("--anchor", action="append", default=[])
    history.set_defaults(func=cmd_coordination_history)
    anchor_read = commands.add_parser("coordination-anchor-read")
    anchor_read.add_argument("--common-dir", required=True)
    anchor_read.set_defaults(func=cmd_coordination_anchor_read)
    anchor_write = commands.add_parser("coordination-anchor-write")
    anchor_write.add_argument("--common-dir", required=True)
    anchor_write.add_argument("--repository", required=True)
    anchor_write.add_argument("--oid", required=True)
    anchor_write.set_defaults(func=cmd_coordination_anchor_write)
    status = commands.add_parser("status-projection")
    status.add_argument("--ledger-file", required=True)
    status.add_argument("--legacy-inventory-file", required=True)
    status.add_argument("--operation-file", action="append", default=[])
    status.set_defaults(func=cmd_status_projection)
    operation = commands.add_parser("operation")
    operation.add_argument("file")
    operation.add_argument("--format", choices=("json", "shell"), required=True)
    operation.set_defaults(func=cmd_operation)
    cleanup_descriptor = commands.add_parser("cleanup-descriptor")
    cleanup_descriptor.add_argument("--workspace-root", required=True)
    cleanup_descriptor.add_argument("--workspace-origin-url", required=True)
    cleanup_descriptor.add_argument("--task-dir", required=True)
    cleanup_descriptor.add_argument("--worktree", required=True)
    cleanup_descriptor.add_argument("--clone", required=True)
    cleanup_descriptor.add_argument("--operation-file", required=True)
    cleanup_descriptor.add_argument("--codebase-branch", required=True)
    cleanup_descriptor.set_defaults(func=cmd_cleanup_descriptor)
    operation_status = commands.add_parser("operation-status")
    operation_status.add_argument("--operation-file", required=True)
    operation_status.add_argument("--ledger-file", required=True)
    operation_status.set_defaults(func=cmd_operation_status)
    operation_handoff = commands.add_parser("operation-handoff")
    operation_handoff.add_argument("--operation-file", required=True)
    operation_handoff.add_argument("--ledger-file", required=True)
    operation_handoff.add_argument("--to-device-id", required=True)
    operation_handoff.add_argument("--to-clone-id", required=True)
    operation_handoff.add_argument("--output", required=True)
    operation_handoff.set_defaults(func=cmd_operation_handoff)
    worktree_set = commands.add_parser("worktree-set")
    worktree_set.add_argument("--porcelain-file", required=True)
    worktree_set.add_argument("--common-git-dir", required=True)
    worktree_set.add_argument("--origin-url", required=True)
    worktree_set.add_argument("--expected-path", required=True)
    worktree_set.add_argument("--expected-branch", required=True)
    worktree_set.add_argument("--recover-present", action="store_true")
    worktree_set.add_argument("--format", choices=("digest", "manifest"), required=True)
    worktree_set.set_defaults(func=cmd_worktree_set)

    create = commands.add_parser("operation-create")
    for field in (
        "operation_id",
        "claim_id",
        "task_claim_id",
        "owner",
        "branch",
        "expected_path",
        "codebase_origin_url",
        "registry_revision",
        "registry_digest",
        "context_policy_set_digest",
        "device_id",
        "clone_id",
    ):
        create.add_argument("--" + field.replace("_", "-"), required=True)
    create.add_argument("--coordination-oid")
    create.add_argument("--policy-resolution-file")
    create.add_argument("--stage", choices=tuple(sorted(OPERATION_STAGES)), default="prepared")
    create.add_argument("--output")
    create.set_defaults(func=cmd_operation_create)

    update = commands.add_parser("operation-update")
    update.add_argument("file")
    update.add_argument("--output", required=True)
    update.add_argument("--stage", choices=tuple(sorted(OPERATION_STAGES)))
    update.add_argument("--coordination-oid")
    update.add_argument("--effect-owner-state", choices=("none", "acquired", "released"))
    update.add_argument("--worktree-ownership", choices=("none", "created", "adopted"))
    update.add_argument("--repo-record-ownership", choices=("none", "created", "adopted"))
    update.add_argument("--worktree-set-digest")
    update.add_argument("--compensation-target", choices=("reserved", "released"))
    update.add_argument(
        "--compensation-reason",
        choices=("ask", "deny", "authorization-deny", "handoff", "creation-failure", "cleanup"),
    )
    update.add_argument(
        "--compensation-next-step", choices=("record", "worktree", "effect-owner", "claim", "finish")
    )
    update.add_argument("--clear-compensation", action="store_true")
    update.add_argument("--policy-resolution-file")
    update.add_argument("--clear-action-binding", action="store_true")
    update.set_defaults(func=cmd_operation_update)

    append_claim = commands.add_parser("ledger-append-claim")
    append_claim.add_argument("file")
    append_claim.add_argument("--output", required=True)
    append_claim.add_argument("--state", choices=("active", "released"), required=True)
    append_claim.add_argument("--operation-file")
    append_claim.add_argument("--operation-id")
    append_claim.add_argument("--claim-id")
    append_claim.set_defaults(func=cmd_ledger_append_claim)

    append_effect = commands.add_parser("ledger-append-effect")
    append_effect.add_argument("file")
    append_effect.add_argument("--output", required=True)
    append_effect.add_argument("--event-id", required=True)
    append_effect.add_argument("--operation-id", required=True)
    append_effect.add_argument("--claim-id", required=True)
    append_effect.add_argument("--device-id", required=True)
    append_effect.add_argument("--clone-id", required=True)
    append_effect.add_argument("--state", choices=("acquired", "released"), required=True)
    append_effect.set_defaults(func=cmd_ledger_append_effect)

    conflict = commands.add_parser("conflict")
    conflict.add_argument("--ledger-file", required=True)
    conflict.add_argument("--operation-file", required=True)
    conflict.add_argument("--legacy-inventory-file", required=True)
    conflict.set_defaults(func=cmd_conflict)
    work_ref = commands.add_parser("work-ref-conflict")
    work_ref.add_argument("--inventory-file", required=True)
    work_ref.add_argument("--work-ref", required=True)
    work_ref.add_argument("--current-claim-id", required=True)
    work_ref.set_defaults(func=cmd_work_ref_conflict)

    matching = commands.add_parser("matching-active")
    matching.add_argument("file")
    matching.add_argument("--task-claim-id", required=True)
    matching.add_argument("--owner", required=True)
    matching.add_argument("--branch", required=True)
    matching.set_defaults(func=cmd_matching_active)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.func(args)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
