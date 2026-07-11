#!/usr/bin/env python3
"""Canonical terminal-state manifests for workbench-task/v2."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from workbench_writer import (
    CLAIM_FIELDS,
    EFFECT_FIELDS,
    load_operation,
    read_ledger,
)


DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
RECORD_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


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
    if stage == "cancelled":
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
