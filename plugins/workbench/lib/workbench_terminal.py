#!/usr/bin/env python3
"""Canonical terminal-state manifests for workbench-task/v2."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

sys.dont_write_bytecode = True

from workbench_writer import (
    CLAIM_FIELDS,
    EFFECT_FIELDS,
    load_operation,
    read_ledger,
)
from workbench_intent import load_request
from workbench_time import parse_rfc3339_utc


DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
RECORD_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
ACTION_FIELDS = (
    "id",
    "action_id",
    "task_claim_id",
    "target_ref",
    "revision",
    "intent_digest",
    "policy_manifest_digest",
    "status",
    "consumed_provenance_digest",
    "authorization_id",
    "authorization_ref",
    "authorization_actor",
    "authorization_at",
)
WRITER_ROW_FIELDS = (
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
DELIVERABLE_FIELDS = (
    "deliverable_id",
    "owner",
    "kind",
    "owner_context_ref",
    "acceptance_authority_ref",
    "required",
    "external_ref",
    "revision",
    "state",
    "acceptance_ref",
    "governance_action",
    "reason_code",
    "reason_ref",
    "governance_action_instance_id",
    "governance_intent_digest",
    "governance_policy_manifest_digest",
    "authorization_ref",
)
ACCEPTANCE_FIELDS = (
    "acceptance_id",
    "deliverable_id",
    "owner",
    "kind",
    "owner_context_ref",
    "acceptance_authority_ref",
    "revision",
    "authority_type",
    "authority_contract",
    "authority_ref",
    "authority_digest",
    "subject_authority_digest",
    "actor",
    "action_instance_id",
    "intent_digest",
    "policy_manifest_digest",
    "authorization_ref",
    "accepted_at",
)
REQUIRED_CHECK_FIELDS = (
    "check_id",
    "owner",
    "deliverable_id",
    "subject_ref",
    "state",
    "governance_action",
    "reason_code",
    "reason_ref",
    "action_instance_id",
    "intent_digest",
    "policy_manifest_digest",
    "authorization_ref",
)
EVIDENCE_FIELDS = (
    "evidence_id",
    "owner",
    "subject_ref",
    "subject_revision",
    "check_id",
    "command",
    "result",
    "recorded_at",
    "source",
    "url",
)
HARVEST_FIELDS = (
    "candidate_id",
    "kind",
    "source_ref",
    "state",
    "decision",
    "target_ref",
    "reason_code",
    "reason_ref",
    "action_instance_id",
    "intent_digest",
    "policy_manifest_digest",
    "authorization_ref",
)
TERMINAL_FIELDS = (
    "outcome",
    "action_instance_id",
    "intent_digest",
    "policy_manifest_digest",
    "authorization_ref",
    "revision",
    "removal_plan_digest",
    "at",
    "reason_code",
    "reason_ref",
)


def sha256(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def require_text(value: str, field: str) -> str:
    if not value or "\t" in value or "\n" in value or "\r" in value:
        raise ValueError("{} must be a non-empty single-line value".format(field))
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("{} must not contain control characters".format(field))
    return value


def require_digest(value: str, field: str) -> str:
    if DIGEST.fullmatch(value) is None:
        raise ValueError("{} must be a canonical SHA-256 digest".format(field))
    return value


def nullable(value: Optional[str]) -> str:
    return "null" if value is None or value == "" else require_text(value, "nullable value")


def manifest_bytes(rows: Sequence[Sequence[str]]) -> bytes:
    return ("\n".join("\t".join(row) for row in rows) + "\n").encode("utf-8")


def operation_files(paths: Sequence[str]) -> List[Dict[str, Any]]:
    operations = [load_operation(path) for path in paths]
    operations.sort(key=lambda item: (item["operation_id"], item["claim_id"]))
    identities = [(item["operation_id"], item["claim_id"]) for item in operations]
    if len(identities) != len(set(identities)):
        raise ValueError("duplicate writer operation identity")
    return operations


def removal_disposition(operation: Mapping[str, Any]) -> str:
    stage = operation["stage"]
    if stage in ("prepared", "authorization-pending", "cancelled"):
        return "cancel-no-effect"
    if stage == "consumed":
        return "retire-consumed"
    if stage == "handoff-ready":
        return "release-handoff"
    return "compensate-release"


def normalize_relative_path(value: str, field: str) -> str:
    require_text(value, field)
    if value.startswith("/") or value in (".", ".."):
        raise ValueError("{} must be workspace-relative".format(field))
    normalized = os.path.normpath(value)
    if normalized != value or any(part == ".." for part in value.split("/")):
        raise ValueError("{} is not a normalized workspace-relative path".format(field))
    return value


def removal_plan(
    task_id: str,
    claim_id: str,
    branch: str,
    task_workspace: str,
    local_branch: str,
    operations: Sequence[Mapping[str, Any]],
) -> Tuple[bytes, Dict[str, Any]]:
    for field, value in (
        ("task_id", task_id),
        ("claim_id", claim_id),
        ("branch", branch),
        ("local_branch", local_branch),
    ):
        require_text(value, field)
    normalize_relative_path(task_workspace, "task_workspace")
    writer_rows: List[Tuple[str, str, str]] = []
    worktree_rows: List[Tuple[str, str, str, str]] = []
    for operation in operations:
        writer_rows.append(
            (
                operation["operation_id"],
                operation["claim_id"],
                removal_disposition(operation),
            )
        )
        if operation["worktree_ownership"] != "none":
            expected = normalize_relative_path(operation["expected_path"], "expected_path")
            worktree_rows.append(
                (
                    operation["operation_id"],
                    operation["claim_id"],
                    operation["owner"],
                    expected,
                )
            )
    writer_rows.sort(key=lambda item: (item[0], item[1]))
    worktree_rows.sort(key=lambda item: (item[2], item[0], item[1]))
    rows: List[Sequence[str]] = [
        ("workbench-task-removal-plan/v1",),
        ("task_id", task_id),
        ("claim_id", claim_id),
        ("task_branch", branch),
    ]
    rows.extend(("writer_operation",) + row for row in writer_rows)
    rows.extend(("codebase_worktree",) + row for row in worktree_rows)
    rows.extend(
        (
            ("task_workspace", task_workspace),
            ("local_branch", local_branch),
        )
    )
    value = {
        "writer_operations": [
            {"operation_id": row[0], "claim_id": row[1], "disposition": row[2]}
            for row in writer_rows
        ],
        "codebase_worktrees": [
            {
                "operation_id": row[0],
                "claim_id": row[1],
                "owner": row[2],
                "expected_path": row[3],
            }
            for row in worktree_rows
        ],
        "task_workspace": task_workspace,
        "local_branch": local_branch,
    }
    return manifest_bytes(rows), value


def serialize_ledger_row(row: Mapping[str, str]) -> str:
    fields = CLAIM_FIELDS if row["kind"] == "claim" else EFFECT_FIELDS
    return "\t".join(row[field] for field in fields)


def writer_snapshot(
    operations: Sequence[Mapping[str, Any]], ledger_rows: Sequence[Mapping[str, str]]
) -> bytes:
    rows: List[Sequence[str]] = [("workbench-writer-abandonment-snapshot/v1",)]
    for operation in operations:
        if operation["stage"] == "cancelled":
            continue
        matching_claims = [
            row
            for row in ledger_rows
            if row["kind"] == "claim"
            and row["operation_id"] == operation["operation_id"]
            and row["claim_id"] == operation["claim_id"]
        ]
        matching_effects = [
            row
            for row in ledger_rows
            if row["kind"] == "effect-owner"
            and row["operation_id"] == operation["operation_id"]
            and row["claim_id"] == operation["claim_id"]
        ]
        claim_state = "absent" if not matching_claims else matching_claims[-1]["state"]
        policy_digest = (
            None if operation["policy_manifest"] is None else operation["policy_manifest"]["digest"]
        )
        expected_binding = {
            "task_claim_id": operation["task_claim_id"],
            "owner": operation["owner"],
            "branch": operation["branch"],
            "expected_path": operation["expected_path"],
            "codebase_origin_url": operation["codebase_origin_url"],
            "context_policy_set_digest": operation["context_policy_set_digest"],
        }
        for claim in matching_claims:
            if any(claim[key] != value for key, value in expected_binding.items()):
                raise ValueError("writer claim does not join the local operation")
        if claim_state == "absent" and operation["stage"] not in (
            "prepared",
            "authorization-pending",
        ):
            raise ValueError("published writer operation has no remote claim")
        claim_digest: Optional[str] = None
        if matching_claims:
            raw = "workbench-writer-claim-snapshot/v1\n" + "".join(
                serialize_ledger_row(row) + "\n" for row in matching_claims
            )
            claim_digest = sha256(raw.encode("utf-8"))
        event_id: Optional[str] = None
        history_digest: Optional[str] = None
        current_device: Optional[str] = None
        current_clone: Optional[str] = None
        effect_state = "none"
        if matching_effects:
            latest = matching_effects[-1]
            event_id = latest["event_id"]
            raw = "workbench-effect-owner-snapshot/v1\n" + "".join(
                serialize_ledger_row(row) + "\n" for row in matching_effects
            )
            history_digest = sha256(raw.encode("utf-8"))
            effect_state = latest["state"]
            if latest["state"] == "acquired":
                current_device = latest["device_id"]
                current_clone = latest["clone_id"]
        operation_effect = operation["effect_owner_state"]
        expected_effect = "none" if not matching_effects else effect_state
        if operation_effect != expected_effect:
            raise ValueError("effect-owner state does not join the local operation")
        rows.append(
            (
                "operation",
                operation["operation_id"],
                operation["claim_id"],
                operation["stage"],
                nullable(operation["action_instance_id"]),
                nullable(policy_digest),
                nullable(operation["intent_digest"]),
                nullable(operation["authorization_ref"]),
                claim_state,
                nullable(claim_digest),
                nullable(event_id),
                nullable(history_digest),
                nullable(current_device),
                nullable(current_clone),
                operation["worktree_ownership"],
                operation["repo_record_ownership"],
                nullable(operation["worktree_set_digest"]),
                nullable(operation["compensation_target"]),
                nullable(operation["compensation_reason"]),
                nullable(operation["compensation_next_step"]),
            )
        )
    return manifest_bytes(rows)


def read_record(file: str) -> Dict[str, str]:
    value: Dict[str, str] = {}
    with open(file, "r", encoding="utf-8") as handle:
        for raw in handle:
            if not raw.endswith("\n") or raw.count("=") < 1:
                raise ValueError("invalid key-value record")
            key, item = raw[:-1].split("=", 1)
            if key in value:
                raise ValueError("duplicate key-value record field")
            value[key] = item
    return value


def read_exact_record(file: Path, fields: Sequence[str]) -> Dict[str, str]:
    if file.is_symlink() or not file.is_file():
        raise ValueError("tracked record must be a regular file: {}".format(file))
    value: Dict[str, str] = {}
    order: List[str] = []
    with file.open("r", encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            if not raw.endswith("\n") or "=" not in raw:
                raise ValueError("malformed tracked record {}:{}".format(file, lineno))
            key, item = raw[:-1].split("=", 1)
            if not key or key in value or "\t" in key or "\r" in item or "\n" in item:
                raise ValueError("invalid tracked record field: {}".format(file))
            value[key] = item
            order.append(key)
    if tuple(order) != tuple(fields):
        raise ValueError("tracked record fields or order do not match: {}".format(file))
    return value


def require_id(value: str, field: str) -> str:
    if RECORD_ID.fullmatch(value) is None:
        raise ValueError("invalid {}".format(field))
    return value


def require_optional_text(value: str, field: str) -> str:
    if value:
        require_text(value, field)
    return value


def parse_time(value: str, field: str) -> datetime.datetime:
    return parse_rfc3339_utc(value, field)


def require_not_future(value: str, now: datetime.datetime, field: str) -> None:
    if parse_time(value, field) > now:
        raise ValueError("{} must not be in the future".format(field))


def require_empty(record: Mapping[str, str], fields: Sequence[str], name: str) -> None:
    if any(record[field] for field in fields):
        raise ValueError("{} carries unexpected provenance".format(name))


def validate_primary_action(
    state: Path,
    primary: Path,
    action_id: str,
    intent_digest: str,
    manifest_digest: str,
    authorization_ref: str,
    expected_action: str,
    task_claim_id: str,
    expected_target: Optional[str] = None,
    expected_revision: Optional[str] = None,
    allow_authorized: bool = False,
) -> None:
    require_id(action_id, "action_instance_id")
    require_digest(intent_digest, "intent_digest")
    require_digest(manifest_digest, "policy_manifest_digest")
    action_file = state / "actions" / (action_id + ".record")
    request_file = state / "actions" / (action_id + ".request.json")
    action = read_exact_record(action_file, ACTION_FIELDS)
    request = load_request(str(request_file))
    if action["id"] != action_id or action_file.stem != action_id:
        raise ValueError("applied action identity mismatch")
    expected = {
        "action_id": expected_action,
        "task_claim_id": task_claim_id,
        "intent_digest": intent_digest,
        "policy_manifest_digest": manifest_digest,
        "authorization_ref": authorization_ref,
    }
    if expected_target is not None:
        expected["target_ref"] = expected_target
    if expected_revision is not None:
        expected["revision"] = expected_revision
    for field, item in expected.items():
        if action[field] != item:
            raise ValueError("applied action binding mismatch: {}".format(field))
    for field in ("action_id", "task_claim_id", "target_ref", "revision", "intent_digest"):
        if request[field] != action[field]:
            raise ValueError("stored request binding mismatch: {}".format(field))
    primary_digest = sha256(primary.read_bytes())
    if action["status"] == "consumed":
        if action["consumed_provenance_digest"] != primary_digest:
            raise ValueError("consumed action primary digest mismatch")
    elif allow_authorized and action["status"] == "authorized":
        if action["consumed_provenance_digest"]:
            raise ValueError("authorized action carries consumed provenance")
    else:
        raise ValueError("applied action is not consumed")


def validate_task_records(task_dir: Path, task_claim_id: str, now: datetime.datetime) -> None:
    state = task_dir / "task/.workbench"
    deliverables: Dict[str, Tuple[Path, Dict[str, str]]] = {}
    acceptances: Dict[str, Tuple[Path, Dict[str, str]]] = {}
    checks: Dict[str, Tuple[Path, Dict[str, str]]] = {}

    for file in sorted((state / "deliverables").glob("*.record")):
        record = read_exact_record(file, DELIVERABLE_FIELDS)
        item_id = require_id(record["deliverable_id"], "deliverable_id")
        if file.stem != item_id or item_id in deliverables:
            raise ValueError("deliverable identity mismatch")
        require_text(record["owner"], "deliverable owner")
        require_text(record["kind"], "deliverable kind")
        if record["required"] not in ("true", "false"):
            raise ValueError("deliverable required must be lowercase boolean")
        if record["state"] not in ("declared", "submitted", "accepted", "waived", "rejected"):
            raise ValueError("invalid deliverable state")
        if record["state"] in ("submitted", "accepted") and not record["revision"]:
            raise ValueError("submitted or accepted deliverable requires revision")
        for field in (
            "owner_context_ref",
            "acceptance_authority_ref",
            "external_ref",
            "revision",
            "acceptance_ref",
            "reason_code",
            "reason_ref",
            "authorization_ref",
        ):
            require_optional_text(record[field], field)
        governance = record["governance_action"]
        provenance_fields = (
            "governance_action",
            "reason_code",
            "reason_ref",
            "governance_action_instance_id",
            "governance_intent_digest",
            "governance_policy_manifest_digest",
            "authorization_ref",
        )
        if governance:
            if governance not in (
                "task.deliverable.waive",
                "task.deliverable.reject",
                "task.deliverable.weaken",
            ):
                raise ValueError("invalid deliverable governance action")
            if not record["reason_code"]:
                raise ValueError("governed deliverable requires reason_code")
            if governance == "task.deliverable.waive" and record["state"] != "waived":
                raise ValueError("deliverable waiver state mismatch")
            if governance == "task.deliverable.reject" and record["state"] != "rejected":
                raise ValueError("deliverable rejection state mismatch")
            if governance == "task.deliverable.weaken" and record["required"] != "false":
                raise ValueError("deliverable weaken required-state mismatch")
            validate_primary_action(
                state,
                file,
                record["governance_action_instance_id"],
                record["governance_intent_digest"],
                record["governance_policy_manifest_digest"],
                record["authorization_ref"],
                governance,
                task_claim_id,
                "workbench:deliverable/" + item_id,
            )
        else:
            require_empty(record, provenance_fields, "ungoverned deliverable")
        if record["state"] in ("waived", "rejected") and not governance:
            raise ValueError("terminal deliverable state lacks governed provenance")
        deliverables[item_id] = (file, record)

    for file in sorted((state / "acceptances").glob("*.record")):
        record = read_exact_record(file, ACCEPTANCE_FIELDS)
        acceptance_id = require_id(record["acceptance_id"], "acceptance_id")
        deliverable_id = require_id(record["deliverable_id"], "acceptance deliverable_id")
        if file.stem != acceptance_id or acceptance_id in acceptances:
            raise ValueError("acceptance identity mismatch")
        if deliverable_id not in deliverables:
            raise ValueError("acceptance references an unknown deliverable")
        _, deliverable = deliverables[deliverable_id]
        for field in ("owner", "kind", "owner_context_ref", "acceptance_authority_ref"):
            if record[field] != deliverable[field]:
                raise ValueError("acceptance deliverable binding mismatch: {}".format(field))
        require_text(record["revision"], "acceptance revision")
        require_digest(record["authority_digest"], "authority_digest")
        require_digest(record["subject_authority_digest"], "subject_authority_digest")
        parse_time(record["accepted_at"], "accepted_at")
        if record["authority_type"] == "kernel-probe":
            if record["authority_contract"] != "workbench-probe/github-pr/v1":
                raise ValueError("kernel acceptance authority contract mismatch")
            require_empty(
                record,
                ("actor", "action_instance_id", "intent_digest", "policy_manifest_digest", "authorization_ref"),
                "kernel acceptance",
            )
        elif record["authority_type"] == "owner-authorization":
            if record["authority_contract"] != "workbench-owner-acceptance/v1" or not record["actor"]:
                raise ValueError("owner acceptance authority mismatch")
            validate_primary_action(
                state,
                file,
                record["action_instance_id"],
                record["intent_digest"],
                record["policy_manifest_digest"],
                record["authorization_ref"],
                "task.deliverable.accept",
                task_claim_id,
                "workbench:deliverable/" + deliverable_id,
            )
        else:
            raise ValueError("invalid acceptance authority type")
        acceptances[acceptance_id] = (file, record)

    for deliverable_id, (_, record) in deliverables.items():
        if record["state"] == "accepted":
            prefix = "workbench:acceptance/"
            if not record["acceptance_ref"].startswith(prefix):
                raise ValueError("accepted deliverable lacks an acceptance pointer")
            acceptance_id = record["acceptance_ref"][len(prefix) :]
            if acceptance_id not in acceptances:
                raise ValueError("accepted deliverable receipt is missing")
            _, acceptance = acceptances[acceptance_id]
            for field in ("deliverable_id", "owner", "kind", "revision"):
                expected = deliverable_id if field == "deliverable_id" else record[field]
                if acceptance[field] != expected:
                    raise ValueError("current acceptance binding mismatch: {}".format(field))
        elif record["acceptance_ref"]:
            raise ValueError("non-accepted deliverable carries an acceptance pointer")

    for file in sorted((state / "required-checks").glob("*.record")):
        record = read_exact_record(file, REQUIRED_CHECK_FIELDS)
        check_id = require_id(record["check_id"], "check_id")
        if file.stem != check_id or check_id in checks:
            raise ValueError("required-check identity mismatch")
        require_text(record["owner"], "required-check owner")
        if record["deliverable_id"]:
            deliverable_id = require_id(record["deliverable_id"], "required-check deliverable_id")
            if deliverable_id not in deliverables:
                raise ValueError("required-check references an unknown deliverable")
            if record["owner"] != deliverables[deliverable_id][1]["owner"]:
                raise ValueError("required-check owner mismatch")
            expected_subject = "workbench:deliverable/" + deliverable_id
        else:
            expected_subject = "workbench:task/" + task_claim_id
        if record["subject_ref"] != expected_subject:
            raise ValueError("required-check subject mismatch")
        if record["state"] == "required":
            require_empty(
                record,
                (
                    "governance_action",
                    "reason_code",
                    "reason_ref",
                    "action_instance_id",
                    "intent_digest",
                    "policy_manifest_digest",
                    "authorization_ref",
                ),
                "required check",
            )
        elif record["state"] == "waived":
            if record["governance_action"] != "task.required-check.waive" or not record["reason_code"]:
                raise ValueError("waived required-check lacks governed provenance")
            validate_primary_action(
                state,
                file,
                record["action_instance_id"],
                record["intent_digest"],
                record["policy_manifest_digest"],
                record["authorization_ref"],
                "task.required-check.waive",
                task_claim_id,
                "workbench:required-check/" + check_id,
            )
        else:
            raise ValueError("invalid required-check state")
        checks[check_id] = (file, record)

    for file in sorted((state / "evidence").glob("*.record")):
        record = read_exact_record(file, EVIDENCE_FIELDS)
        evidence_id = require_id(record["evidence_id"], "evidence_id")
        if file.stem != evidence_id:
            raise ValueError("evidence identity mismatch")
        check_id = require_id(record["check_id"], "evidence check_id")
        if check_id not in checks:
            raise ValueError("evidence references an unknown required check")
        check = checks[check_id][1]
        if record["owner"] != check["owner"] or record["subject_ref"] != check["subject_ref"]:
            raise ValueError("evidence required-check binding mismatch")
        require_text(record["subject_revision"], "evidence subject_revision")
        if record["result"] not in ("passed", "failed") or record["source"] not in ("local", "ci"):
            raise ValueError("invalid evidence result or source")
        require_not_future(record["recorded_at"], now, "recorded_at")
        require_optional_text(record["command"], "evidence command")
        require_optional_text(record["url"], "evidence url")

    sealed = state / "harvest/sealed"
    if sealed.exists() and (sealed.is_symlink() or sealed.read_bytes() != b"true\n"):
        raise ValueError("invalid harvest seal")
    for file in sorted((state / "harvest/candidates").glob("*.record")):
        record = read_exact_record(file, HARVEST_FIELDS)
        candidate_id = require_id(record["candidate_id"], "candidate_id")
        if file.stem != candidate_id:
            raise ValueError("harvest candidate identity mismatch")
        if record["kind"] not in ("decision", "lesson", "runbook", "framework-change"):
            raise ValueError("invalid harvest candidate kind")
        require_text(record["source_ref"], "harvest source_ref")
        if record["state"] == "pending":
            require_empty(
                record,
                (
                    "decision",
                    "target_ref",
                    "reason_code",
                    "reason_ref",
                    "action_instance_id",
                    "intent_digest",
                    "policy_manifest_digest",
                    "authorization_ref",
                ),
                "pending harvest candidate",
            )
        elif record["state"] == "disposed":
            if record["decision"] not in ("absorb", "codebase", "follow-up", "discard"):
                raise ValueError("invalid harvest disposition")
            if not record["reason_code"]:
                raise ValueError("harvest disposition requires reason_code")
            if (record["decision"] == "discard") != (record["target_ref"] == ""):
                raise ValueError("harvest target_ref does not match disposition")
            validate_primary_action(
                state,
                file,
                record["action_instance_id"],
                record["intent_digest"],
                record["policy_manifest_digest"],
                record["authorization_ref"],
                "task.harvest.dispose",
                task_claim_id,
                "workbench:harvest/" + candidate_id,
            )
        else:
            raise ValueError("invalid harvest candidate state")

    for file in sorted((state / "writer-rows").glob("*.record")):
        record = read_exact_record(file, WRITER_ROW_FIELDS)
        if file.stem != record["owner"] or record["task_claim_id"] != task_claim_id:
            raise ValueError("writer row task identity mismatch")
        if record["expected_path"] != "task/codebases/" + record["owner"]:
            raise ValueError("writer row expected path mismatch")
        require_digest(record["registry_digest"], "writer registry_digest")
        require_digest(record["context_policy_set_digest"], "writer context digest")
        action_tuple = (
            record["action_instance_id"],
            record["intent_digest"],
            record["policy_manifest_digest"],
        )
        if any(action_tuple):
            if not all(action_tuple):
                raise ValueError("writer row action tuple is partial")
            validate_primary_action(
                state,
                file,
                record["action_instance_id"],
                record["intent_digest"],
                record["policy_manifest_digest"],
                record["authorization_ref"],
                "task.concurrent-write",
                task_claim_id,
                "workbench:codebase/" + record["owner"],
            )
        elif record["authorization_ref"]:
            raise ValueError("writer row authorization has no action binding")


def validate_terminal_record(
    task_dir: Path, terminal_file: Path, task_claim_id: str, now: datetime.datetime
) -> Dict[str, str]:
    state = task_dir / "task/.workbench"
    record = read_exact_record(terminal_file, TERMINAL_FIELDS)
    if record["outcome"] not in ("completed", "abandoned"):
        raise ValueError("invalid terminal outcome")
    require_digest(record["revision"], "terminal revision")
    require_not_future(record["at"], now, "terminal at")
    if record["outcome"] == "completed":
        require_empty(record, ("removal_plan_digest", "reason_code", "reason_ref"), "completed terminal")
        action = "task.complete"
    else:
        require_digest(record["removal_plan_digest"], "terminal removal_plan_digest")
        require_text(record["reason_code"], "terminal reason_code")
        require_optional_text(record["reason_ref"], "terminal reason_ref")
        action = "task.abandon"
    validate_primary_action(
        state,
        terminal_file,
        record["action_instance_id"],
        record["intent_digest"],
        record["policy_manifest_digest"],
        record["authorization_ref"],
        action,
        task_claim_id,
        expected_revision=record["revision"],
        allow_authorized=True,
    )
    return record


def abandonment_revision(
    content_revision: str,
    snapshot_digest: str,
    plan_digest: str,
    reason_code: str,
    reason_ref: Optional[str],
    deliverable_files: Sequence[str],
) -> bytes:
    require_digest(content_revision, "content_revision")
    require_digest(snapshot_digest, "writer_snapshot")
    require_digest(plan_digest, "removal_plan")
    require_text(reason_code, "reason_code")
    rows: List[Sequence[str]] = [
        ("workbench-task-abandonment-revision/v1",),
        ("content_revision", content_revision),
        ("writer_snapshot", snapshot_digest),
        ("removal_plan", plan_digest),
        ("reason_code", reason_code),
        ("reason_ref", nullable(reason_ref)),
    ]
    deliverables: List[Tuple[str, str, str, str]] = []
    for file in deliverable_files:
        record = read_record(file)
        deliverable_id = record.get("deliverable_id", "")
        if RECORD_ID.fullmatch(deliverable_id) is None:
            raise ValueError("invalid deliverable ID")
        required = record.get("required", "")
        if required not in ("true", "false"):
            raise ValueError("invalid deliverable required value")
        state = require_text(record.get("state", ""), "deliverable state")
        revision = nullable(record.get("revision"))
        deliverables.append((deliverable_id, required, state, revision))
    deliverables.sort(key=lambda item: item[0])
    if len(deliverables) != len({item[0] for item in deliverables}):
        raise ValueError("duplicate deliverable ID")
    rows.extend(("deliverable",) + item for item in deliverables)
    return manifest_bytes(rows)


def emit_manifest(raw: bytes, value: Optional[Mapping[str, Any]], output_format: str) -> None:
    if output_format == "manifest":
        sys.stdout.buffer.write(raw)
        return
    digest = sha256(raw)
    if output_format == "shell":
        sys.stdout.write("digest={}\n".format(digest))
        if value is not None:
            sys.stdout.write(
                "json={}\n".format(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
            )
        return
    result: Dict[str, Any] = {"digest": digest}
    if value is not None:
        result["value"] = value
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def cmd_removal_plan(args: argparse.Namespace) -> None:
    operations = operation_files(args.operation_file)
    raw, value = removal_plan(
        args.task_id,
        args.claim_id,
        args.branch,
        args.task_workspace,
        args.local_branch,
        operations,
    )
    emit_manifest(raw, value, args.format)


def cmd_writer_snapshot(args: argparse.Namespace) -> None:
    operations = operation_files(args.operation_file)
    ledger_rows, _ = read_ledger(args.ledger_file)
    emit_manifest(writer_snapshot(operations, ledger_rows), None, args.format)


def cmd_abandonment_revision(args: argparse.Namespace) -> None:
    raw = abandonment_revision(
        args.content_revision,
        args.writer_snapshot_digest,
        args.removal_plan_digest,
        args.reason_code,
        args.reason_ref,
        args.deliverable_record,
    )
    emit_manifest(raw, None, args.format)


def cmd_records_validate(args: argparse.Namespace) -> None:
    now = parse_time(args.now, "now")
    validate_task_records(Path(args.task_dir).resolve(), args.claim_id, now)


def cmd_terminal_validate(args: argparse.Namespace) -> None:
    now = parse_time(args.now, "now")
    value = validate_terminal_record(
        Path(args.task_dir).resolve(),
        Path(args.terminal_file).resolve(),
        args.claim_id,
        now,
    )
    if args.format == "json":
        json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
        sys.stdout.write("\n")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    plan = commands.add_parser("removal-plan")
    plan.add_argument("--task-id", required=True)
    plan.add_argument("--claim-id", required=True)
    plan.add_argument("--branch", required=True)
    plan.add_argument("--task-workspace", required=True)
    plan.add_argument("--local-branch", required=True)
    plan.add_argument("--operation-file", action="append", default=[])
    plan.add_argument("--format", choices=("manifest", "shell", "json"), required=True)
    plan.set_defaults(func=cmd_removal_plan)

    snapshot = commands.add_parser("writer-snapshot")
    snapshot.add_argument("--ledger-file", required=True)
    snapshot.add_argument("--operation-file", action="append", default=[])
    snapshot.add_argument("--format", choices=("manifest", "shell", "json"), required=True)
    snapshot.set_defaults(func=cmd_writer_snapshot)

    revision = commands.add_parser("abandonment-revision")
    revision.add_argument("--content-revision", required=True)
    revision.add_argument("--writer-snapshot-digest", required=True)
    revision.add_argument("--removal-plan-digest", required=True)
    revision.add_argument("--reason-code", required=True)
    revision.add_argument("--reason-ref")
    revision.add_argument("--deliverable-record", action="append", default=[])
    revision.add_argument("--format", choices=("manifest", "shell", "json"), required=True)
    revision.set_defaults(func=cmd_abandonment_revision)

    records = commands.add_parser("records-validate")
    records.add_argument("--task-dir", required=True)
    records.add_argument("--claim-id", required=True)
    records.add_argument("--now", required=True)
    records.set_defaults(func=cmd_records_validate)

    terminal = commands.add_parser("terminal-validate")
    terminal.add_argument("--task-dir", required=True)
    terminal.add_argument("--terminal-file", required=True)
    terminal.add_argument("--claim-id", required=True)
    terminal.add_argument("--now", required=True)
    terminal.add_argument("--format", choices=("quiet", "json"), required=True)
    terminal.set_defaults(func=cmd_terminal_validate)
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
