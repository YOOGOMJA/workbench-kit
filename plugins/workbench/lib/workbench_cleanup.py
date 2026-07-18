#!/usr/bin/env python3
"""Strict external cleanup-journal codec and prefix reducer."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

from workbench_intent import intent_manifest, load_request, parse_line_payload
from workbench_lifecycle import (
    V2_MARKER,
    load_comment_observation,
    open_submission_lock,
    open_submission_directory,
    parse_comment,
    parse_index,
    parse_v2,
    read_submission_recovery_at,
    reduce_lifecycle_marker,
    submission_snapshot_index,
    validate_cleanup_revision,
    validate_recovery_snapshot,
    validate_recovery_worktree,
    validate_restored_submission_state,
)
from workbench_terminal import (
    ACTION_FIELDS,
    TERMINAL_FIELDS,
    read_exact_record,
    validate_terminal_record,
)
from workbench_time import parse_rfc3339_utc, require_rfc3339_utc
from workbench_writer import current_claim_state, latest_effect, read_ledger


JOURNAL_FIELDS = (
    "contract_version",
    "journal_id",
    "stage",
    "task_id",
    "claim_id",
    "branch",
    "revision",
    "action_instance_id",
    "intent_digest",
    "policy_manifest",
    "authorization_ref",
    "removal_plan_digest",
    "removal_plan",
    "quarantine_authority",
    "quarantine_receipt",
    "effect_owner_events",
    "at",
)
PLAN_FIELDS = (
    "writer_operations",
    "codebase_worktrees",
    "task_workspace",
    "local_branch",
)
OPERATION_FIELDS = ("operation_id", "claim_id", "disposition")
WORKTREE_FIELDS = ("operation_id", "claim_id", "owner", "expected_path")
EVENT_FIELDS = (
    "event_id",
    "operation_id",
    "claim_id",
    "device_id",
    "clone_id",
    "state",
    "phase",
    "at",
)
QUARANTINE_AUTHORITY_FIELDS = (
    "contract_version",
    "device_id",
    "clone_id",
    "workspace_locator",
    "quarantine_locator",
    "arm_commitment",
)
QUARANTINE_RECEIPT_FIELDS = (
    "contract_version",
    "receipt_digest",
    "arm_secret",
    "task_id",
    "claim_id",
    "branch",
    "device_id",
    "clone_id",
    "workspace_locator",
    "quarantine_locator",
    "workspace_device",
    "workspace_inode",
    "workspace_tree_digest",
    "admin_manifest_digest",
    "quarantined_at",
)
STAGES = {"prepared", "quarantined", "completed"}
DISPOSITIONS = {
    "cancel-no-effect",
    "compensate-release",
    "retire-consumed",
    "release-handoff",
}
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
ACTION_ID = re.compile(r"act_[A-Za-z0-9][A-Za-z0-9._-]*\Z")
UUID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\Z"
)
MARKER = re.compile(
    r"<!-- workbench-task-cleanup:v1\n([^\r\n]+)\n-->", re.MULTILINE
)
TERMINAL_CHECKPOINT_MARKER = re.compile(
    r"<!-- workbench-task-terminal-checkpoint:v1\n([^\r\n]+)\n-->",
    re.MULTILINE,
)
TERMINAL_CHECKPOINT_FIELDS = (
    "contract_version",
    "task_id",
    "claim_id",
    "issue",
    "home",
    "branch",
    "work_ref",
    "workspace_authority_descriptor_digest",
    "repository_origin_url",
    "snapshot_revision",
    "cleanup_revision",
    "pull_request",
    "pull_request_url",
    "head_revision",
    "terminal",
    "terminal_action",
    "terminal_request",
    "terminal_primary_digest",
    "at",
)
OID = re.compile(r"[0-9a-f]{40}([0-9a-f]{24})?\Z")
QUARANTINE_LOCATOR = re.compile(
    r"workbench-v2/cleanup-quarantine/[0-9a-f]{64}\Z"
)
ARM_SECRET = re.compile(r"[0-9a-f]{64}\Z")
LOCAL_QUARANTINE_PROOF_FIELDS = (
    "contract_version",
    "task_id",
    "claim_id",
    "branch",
    "device_id",
    "clone_id",
    "workspace_locator",
    "quarantine_locator",
    "journal_binding_digest",
    "arm_commitment",
    "arm_secret",
)
LOCAL_QUARANTINE_INTENT_FIELDS = (
    "contract_version",
    "task_id",
    "claim_id",
    "branch",
    "device_id",
    "clone_id",
    "workspace_locator",
    "quarantine_locator",
    "workspace_device",
    "workspace_inode",
    "admin_records",
)
LOCAL_ADMIN_INTENT_FIELDS = (
    "kind",
    "identity",
    "source_locator",
    "quarantine_locator",
    "filesystem_device",
    "filesystem_inode",
)
LOCAL_QUARANTINE_RECEIPT_FIELDS = (
    "contract_version",
    "receipt_digest",
    "arm_secret",
    "task_id",
    "claim_id",
    "branch",
    "device_id",
    "clone_id",
    "workspace_locator",
    "quarantine_locator",
    "workspace_device",
    "workspace_inode",
    "workspace_tree_digest",
    "admin_records",
    "admin_manifest_digest",
    "quarantined_at",
)
LOCAL_ADMIN_RECEIPT_FIELDS = LOCAL_ADMIN_INTENT_FIELDS + ("tree_digest",)


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


def write_json(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def sha256(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("{} must be a non-empty string".format(field))
    if "\t" in value or "\n" in value or "\r" in value:
        raise ValueError("{} must be a single-line value".format(field))
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("{} must not contain control characters".format(field))
    return value


def require_digest(value: Any, field: str) -> str:
    if not isinstance(value, str) or DIGEST.fullmatch(value) is None:
        raise ValueError("{} must be a canonical SHA-256 digest".format(field))
    return value


def require_time(value: Any, field: str) -> str:
    return require_rfc3339_utc(value, field)


def require_relative_path(value: Any, field: str) -> str:
    value = require_text(value, field)
    if value.startswith("/") or value in (".", "..") or "//" in value:
        raise ValueError("{} must be normalized and workspace-relative".format(field))
    if any(part in ("", ".", "..") for part in value.split("/")):
        raise ValueError("{} must be normalized and workspace-relative".format(field))
    return value


def require_fields(value: Any, fields: Sequence[str], name: str) -> Mapping[str, Any]:
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError("{} fields do not match the contract".format(name))
    return value


def plan_manifest(
    task_id: str, claim_id: str, branch: str, plan: Mapping[str, Any]
) -> bytes:
    require_fields(plan, PLAN_FIELDS, "removal plan")
    require_text(task_id, "task_id")
    require_text(claim_id, "claim_id")
    require_text(branch, "branch")
    operations = plan["writer_operations"]
    worktrees = plan["codebase_worktrees"]
    if not isinstance(operations, list) or not isinstance(worktrees, list):
        raise ValueError("removal plan arrays are invalid")
    operation_rows: List[Tuple[str, str, str]] = []
    for value in operations:
        require_fields(value, OPERATION_FIELDS, "writer operation plan")
        row = (
            require_text(value["operation_id"], "operation_id"),
            require_text(value["claim_id"], "claim_id"),
            require_text(value["disposition"], "disposition"),
        )
        if row[2] not in DISPOSITIONS:
            raise ValueError("invalid writer operation disposition")
        operation_rows.append(row)
    if operation_rows != sorted(operation_rows, key=lambda row: (row[0], row[1])):
        raise ValueError("writer operation plan is not canonically sorted")
    if len(operation_rows) != len(set((row[0], row[1]) for row in operation_rows)):
        raise ValueError("duplicate writer operation plan")

    worktree_rows: List[Tuple[str, str, str, str]] = []
    operation_ids = set((row[0], row[1]) for row in operation_rows)
    for value in worktrees:
        require_fields(value, WORKTREE_FIELDS, "codebase worktree plan")
        row = (
            require_text(value["operation_id"], "operation_id"),
            require_text(value["claim_id"], "claim_id"),
            require_text(value["owner"], "owner"),
            require_relative_path(value["expected_path"], "expected_path"),
        )
        if (row[0], row[1]) not in operation_ids:
            raise ValueError("worktree plan references an unknown operation")
        if row[3] != "task/codebases/" + row[2]:
            raise ValueError("worktree expected path does not bind the owner")
        worktree_rows.append(row)
    if worktree_rows != sorted(worktree_rows, key=lambda row: (row[2], row[0], row[1])):
        raise ValueError("codebase worktree plan is not canonically sorted")
    if len(worktree_rows) != len(set((row[0], row[1]) for row in worktree_rows)):
        raise ValueError("duplicate codebase worktree plan")

    task_workspace = require_relative_path(plan["task_workspace"], "task_workspace")
    local_branch = require_text(plan["local_branch"], "local_branch")
    if local_branch != branch:
        raise ValueError("cleanup local branch does not match the task branch")
    rows = [
        "workbench-task-removal-plan/v1",
        "task_id\t" + task_id,
        "claim_id\t" + claim_id,
        "task_branch\t" + branch,
    ]
    rows.extend("writer_operation\t" + "\t".join(row) for row in operation_rows)
    rows.extend("codebase_worktree\t" + "\t".join(row) for row in worktree_rows)
    rows.extend(("task_workspace\t" + task_workspace, "local_branch\t" + local_branch))
    return ("\n".join(rows) + "\n").encode("utf-8")


def validate_policy_manifest(value: Any) -> Mapping[str, Any]:
    require_fields(value, ("contract_version", "digest", "sources"), "policy manifest")
    if value["contract_version"] != "workbench-policy-manifest/v1":
        raise ValueError("unsupported policy manifest contract")
    require_digest(value["digest"], "policy_manifest.digest")
    if not isinstance(value["sources"], list):
        raise ValueError("policy manifest sources must be an array")
    return value


def validate_events(events: Any) -> List[Mapping[str, Any]]:
    if not isinstance(events, list):
        raise ValueError("effect_owner_events must be an array")
    result: List[Mapping[str, Any]] = []
    current_owner: Dict[Tuple[str, str], Optional[Tuple[str, str]]] = {}
    pending: Optional[Mapping[str, Any]] = None
    previous_at = ""
    seen_verified = set()
    for value in events:
        require_fields(value, EVENT_FIELDS, "cleanup effect-owner event")
        for field in ("event_id", "operation_id", "claim_id", "device_id"):
            require_text(value[field], field)
        if UUID.fullmatch(value["clone_id"] if isinstance(value["clone_id"], str) else "") is None:
            raise ValueError("cleanup event clone_id must be a lowercase UUID")
        if value["state"] not in ("acquired", "released"):
            raise ValueError("invalid cleanup effect-owner state")
        if value["phase"] not in ("intended", "verified"):
            raise ValueError("invalid cleanup effect-owner phase")
        at = require_time(value["at"], "effect_owner_event.at")
        if previous_at and at < previous_at:
            raise ValueError("cleanup event timestamps must be nondecreasing")
        previous_at = at
        if value["phase"] == "intended":
            if pending is not None:
                raise ValueError("cleanup cannot append an intent while another is pending")
            pending = value
        else:
            if pending is None:
                raise ValueError("verified cleanup event has no intended prefix")
            for field in EVENT_FIELDS[:-2]:
                if value[field] != pending[field]:
                    raise ValueError("verified cleanup event does not match its intent")
            identity = (value["operation_id"], value["claim_id"])
            event_identity = identity + (value["event_id"],)
            if event_identity in seen_verified:
                raise ValueError("duplicate verified cleanup event")
            seen_verified.add(event_identity)
            owner = (value["device_id"], value["clone_id"])
            current = current_owner.get(identity)
            if value["state"] == "acquired":
                if current is not None:
                    raise ValueError("cleanup acquired an already-owned operation")
                current_owner[identity] = owner
            else:
                if current != owner:
                    raise ValueError("cleanup released a different effect owner")
                current_owner[identity] = None
            pending = None
        result.append(value)
    return result


def quarantine_locator(
    task_id: str,
    claim_id: str,
    branch: str,
    device_id: str,
    clone_id: str,
    workspace_locator: str,
) -> str:
    rows = (
        "workbench-task-quarantine-authority/v1\n"
        "task_id\t{}\n"
        "claim_id\t{}\n"
        "branch\t{}\n"
        "device_id\t{}\n"
        "clone_id\t{}\n"
        "workspace_locator\t{}\n"
    ).format(task_id, claim_id, branch, device_id, clone_id, workspace_locator)
    return "workbench-v2/cleanup-quarantine/" + hashlib.sha256(
        rows.encode("utf-8")
    ).hexdigest()


def require_arm_secret(value: Any, field: str = "arm_secret") -> str:
    if not isinstance(value, str) or ARM_SECRET.fullmatch(value) is None:
        raise ValueError("{} must be a 256-bit lowercase hex secret".format(field))
    return value


def quarantine_arm_commitment(
    secret: str,
    journal_binding_digest: str,
) -> str:
    require_arm_secret(secret)
    require_digest(journal_binding_digest, "quarantine journal binding digest")
    rows = (
        "workbench-task-quarantine-arm-proof/v1\n"
        "journal_binding_digest\t{}\n"
        "arm_secret\t{}\n"
    ).format(journal_binding_digest, secret)
    return sha256(rows.encode("utf-8"))


def validate_quarantine_authority(
    value: Any,
    task_id: str,
    claim_id: str,
    branch: str,
    workspace_locator: str,
) -> Mapping[str, Any]:
    require_fields(value, QUARANTINE_AUTHORITY_FIELDS, "quarantine authority")
    if value["contract_version"] != "workbench-task-quarantine-authority/v1":
        raise ValueError("unsupported quarantine authority contract")
    device_id = require_text(value["device_id"], "quarantine authority device_id")
    clone_id = require_text(value["clone_id"], "quarantine authority clone_id")
    if UUID.fullmatch(clone_id) is None:
        raise ValueError("quarantine authority clone_id must be a lowercase UUID")
    locator = require_relative_path(
        value["workspace_locator"], "quarantine authority workspace_locator"
    )
    if locator != workspace_locator:
        raise ValueError("quarantine authority does not bind the task workspace")
    expected = quarantine_locator(
        task_id, claim_id, branch, device_id, clone_id, locator
    )
    if value["quarantine_locator"] != expected:
        raise ValueError("quarantine authority locator does not bind its identity")
    if QUARANTINE_LOCATOR.fullmatch(value["quarantine_locator"]) is None:
        raise ValueError("quarantine authority locator is not canonical")
    require_digest(value["arm_commitment"], "quarantine authority arm_commitment")
    return value


def require_decimal_identity(value: Any, field: str, allow_zero: bool) -> str:
    value = require_text(value, field)
    if not value.isdigit() or (len(value) > 1 and value.startswith("0")):
        raise ValueError("{} must be a canonical decimal identity".format(field))
    if not allow_zero and int(value) == 0:
        raise ValueError("{} must be positive".format(field))
    return value


def validate_quarantine_receipt(
    value: Any,
    journal: Mapping[str, Any],
    authority: Mapping[str, Any],
) -> Mapping[str, Any]:
    require_fields(value, QUARANTINE_RECEIPT_FIELDS, "quarantine receipt")
    if value["contract_version"] != "workbench-task-quarantine-receipt/v1":
        raise ValueError("unsupported quarantine receipt contract")
    require_digest(value["receipt_digest"], "quarantine receipt digest")
    secret = require_arm_secret(value["arm_secret"], "quarantine receipt arm_secret")
    expected = {
        "task_id": journal["task_id"],
        "claim_id": journal["claim_id"],
        "branch": journal["branch"],
        "device_id": authority["device_id"],
        "clone_id": authority["clone_id"],
        "workspace_locator": authority["workspace_locator"],
        "quarantine_locator": authority["quarantine_locator"],
    }
    if any(value[field] != item for field, item in expected.items()):
        raise ValueError("quarantine receipt does not bind the cleanup authority")
    require_decimal_identity(
        value["workspace_device"], "quarantine receipt workspace_device", True
    )
    require_decimal_identity(
        value["workspace_inode"], "quarantine receipt workspace_inode", False
    )
    require_digest(
        value["workspace_tree_digest"], "quarantine receipt workspace tree"
    )
    require_digest(
        value["admin_manifest_digest"], "quarantine receipt admin manifest"
    )
    require_time(value["quarantined_at"], "quarantine receipt quarantined_at")
    commitment = quarantine_arm_commitment(secret, quarantine_arm_binding(journal))
    if commitment != authority["arm_commitment"]:
        raise ValueError("quarantine receipt does not prove the local arm secret")
    if quarantine_receipt_digest(value) != value["receipt_digest"]:
        raise ValueError("quarantine receipt proof digest mismatch")
    return value


def validate_journal(value: Any) -> Mapping[str, Any]:
    require_fields(value, JOURNAL_FIELDS, "cleanup journal")
    if value["contract_version"] != "workbench-task-cleanup-journal/v1":
        raise ValueError("unsupported cleanup journal contract")
    for field in ("journal_id", "task_id", "claim_id", "branch", "action_instance_id"):
        require_text(value[field], field)
    if ACTION_ID.fullmatch(value["action_instance_id"]) is None:
        raise ValueError("cleanup action instance ID is invalid")
    if value["journal_id"] != "cleanup-" + value["claim_id"]:
        raise ValueError("cleanup journal ID does not bind the claim")
    if value["stage"] not in STAGES:
        raise ValueError("invalid cleanup journal stage")
    require_digest(value["revision"], "revision")
    require_digest(value["intent_digest"], "intent_digest")
    validate_policy_manifest(value["policy_manifest"])
    if value["authorization_ref"] is not None:
        require_text(value["authorization_ref"], "authorization_ref")
    require_digest(value["removal_plan_digest"], "removal_plan_digest")
    raw_plan = plan_manifest(value["task_id"], value["claim_id"], value["branch"], value["removal_plan"])
    if sha256(raw_plan) != value["removal_plan_digest"]:
        raise ValueError("cleanup removal-plan digest mismatch")
    authority = validate_quarantine_authority(
        value["quarantine_authority"],
        value["task_id"],
        value["claim_id"],
        value["branch"],
        value["removal_plan"]["task_workspace"],
    )
    receipt = value["quarantine_receipt"]
    if receipt is not None:
        validate_quarantine_receipt(receipt, value, authority)
    events = validate_events(value["effect_owner_events"])
    require_time(value["at"], "at")
    pending = bool(events and events[-1]["phase"] == "intended")
    if value["stage"] == "prepared":
        if receipt is not None or events:
            raise ValueError("prepared cleanup cannot carry quarantine effects")
    else:
        if receipt is None:
            raise ValueError("post-prepare cleanup requires a quarantine receipt")
        if receipt["quarantined_at"] > value["at"]:
            raise ValueError("cleanup journal predates its quarantine receipt")
    if value["stage"] == "completed":
        if pending:
            raise ValueError("completed cleanup journal has an unverified owner event")
        latest_verified: Dict[Tuple[str, str], Mapping[str, Any]] = {}
        for event in events:
            if event["phase"] == "verified":
                latest_verified[(event["operation_id"], event["claim_id"])] = event
        if any(event["state"] != "released" for event in latest_verified.values()):
            raise ValueError("completed cleanup retains an acquired effect owner")
    return value


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def quarantine_arm_binding(value: Mapping[str, Any]) -> str:
    selected: Dict[str, Any] = {}
    for field in JOURNAL_FIELDS:
        if field in ("stage", "quarantine_receipt", "effect_owner_events", "at"):
            continue
        if field == "quarantine_authority":
            authority = dict(value[field])
            authority.pop("arm_commitment", None)
            selected[field] = authority
        else:
            selected[field] = value[field]
    raw = (
        b"workbench-task-quarantine-journal-binding/v1\n"
        + (
            json.dumps(
                selected,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    )
    return sha256(raw)


def quarantine_receipt_digest(value: Mapping[str, Any]) -> str:
    secret = require_arm_secret(value["arm_secret"], "quarantine receipt arm_secret")
    body = {
        field: value[field]
        for field in QUARANTINE_RECEIPT_FIELDS
        if field != "receipt_digest"
    }
    raw = (
        b"workbench-task-quarantine-receipt-proof/v1\n"
        + bytes.fromhex(secret)
        + b"\n"
        + canonical_json_bytes(body)
    )
    return sha256(raw)


def secure_directory_flags() -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    if not hasattr(os, "O_NOFOLLOW"):
        raise OSError("cleanup quarantine requires O_NOFOLLOW")
    return flags | os.O_NOFOLLOW


def secure_file_flags() -> int:
    if not hasattr(os, "O_NOFOLLOW"):
        raise OSError("cleanup quarantine requires O_NOFOLLOW")
    return os.O_RDONLY | os.O_NOFOLLOW


def open_absolute_directory_nofollow(path: str) -> int:
    normalized = os.path.normpath(path)
    if not os.path.isabs(normalized):
        raise ValueError("secure directory path must be absolute")
    current = os.open(os.path.sep, secure_directory_flags())
    try:
        for component in Path(normalized).parts[1:]:
            following = os.open(
                component, secure_directory_flags(), dir_fd=current
            )
            os.close(current)
            current = following
        return current
    except Exception:
        os.close(current)
        raise


def fsync_directory(path: str) -> None:
    descriptor = open_absolute_directory_nofollow(path)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_durable_json(directory: str, name: str, value: Mapping[str, Any]) -> None:
    target = os.path.join(directory, name)
    if os.path.lexists(target):
        raise ValueError("cleanup quarantine record already exists: {}".format(name))
    raw = canonical_json_bytes(value)
    directory_fd = open_absolute_directory_nofollow(directory)
    try:
        for attempt in range(32):
            temporary = ".{}.tmp.{}.{}".format(name, os.getpid(), attempt)
            try:
                descriptor = os.open(
                    temporary,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600,
                    dir_fd=directory_fd,
                )
            except FileExistsError:
                continue
            break
        else:
            raise OSError("cannot allocate cleanup quarantine record")
        try:
            view = memoryview(raw)
            while view:
                written = os.write(descriptor, view)
                if written <= 0:
                    raise OSError("cleanup quarantine record write made no progress")
                view = view[written:]
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        try:
            os.link(
                temporary,
                name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
        except FileExistsError as exc:
            raise ValueError(
                "cleanup quarantine record path became occupied: {}".format(name)
            ) from exc
        os.fsync(directory_fd)
        os.unlink(temporary, dir_fd=directory_fd)
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def read_strict_local_json(path: str, fields: Sequence[str], name: str) -> Mapping[str, Any]:
    directory_fd = open_absolute_directory_nofollow(os.path.dirname(path))
    descriptor = -1
    try:
        filename = os.path.basename(path)
        before = os.stat(filename, dir_fd=directory_fd, follow_symlinks=False)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
        ):
            raise ValueError("{} is not a private regular record".format(name))
        descriptor = os.open(filename, secure_file_flags(), dir_fd=directory_fd)
        opened = os.fstat(descriptor)
        identity = lambda item: (
            item.st_dev,
            item.st_ino,
            item.st_mode,
            item.st_nlink,
            item.st_size,
            item.st_mtime_ns,
            item.st_ctime_ns,
        )
        if identity(opened) != identity(before):
            raise ValueError("{} changed before secure open".format(name))
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > 16 * 1024 * 1024:
                raise ValueError("{} exceeds the local record budget".format(name))
            chunks.append(chunk)
        after = os.fstat(descriptor)
        current = os.stat(filename, dir_fd=directory_fd, follow_symlinks=False)
        if identity(after) != identity(opened) or identity(current) != identity(after):
            raise ValueError("{} changed during secure read".format(name))
        raw = b"".join(chunks)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        os.close(directory_fd)
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    require_fields(value, fields, name)
    if tuple(value) != tuple(fields):
        raise ValueError("{} fields are not canonical".format(name))
    if raw != canonical_json_bytes(value):
        raise ValueError("{} bytes are not canonical".format(name))
    return value


def git_value(directory: str, *arguments: str) -> str:
    return subprocess.check_output(
        ["git", "-C", directory] + list(arguments),
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()


def normalized_real_path(directory: str, value: str) -> str:
    path = value if os.path.isabs(value) else os.path.join(directory, value)
    return os.path.realpath(os.path.normpath(path))


def relative_managed_path(root: str, path: str, field: str) -> str:
    root = os.path.realpath(root)
    path = os.path.realpath(path)
    if os.path.commonpath((root, path)) != root:
        raise ValueError("{} escapes the workspace root".format(field))
    relative = os.path.relpath(path, root)
    return require_relative_path(relative, field)


def strict_tree_digest(path: str) -> str:
    digest = hashlib.sha256()
    seen_regular = set()

    def update(kind: str, relative: str, value: os.stat_result) -> None:
        row = [
            kind,
            relative,
            stat.S_IMODE(value.st_mode),
            str(value.st_dev),
            str(value.st_ino),
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        ]
        encoded = json.dumps(
            row, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)

    def unchanged(before: os.stat_result, after: os.stat_result, field: str) -> None:
        identity = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(getattr(before, item) != getattr(after, item) for item in identity):
            raise ValueError("cleanup quarantine {} changed during authentication".format(field))

    def walk(directory: int, prefix: str) -> None:
        initial_directory = os.fstat(directory)
        names = sorted(os.listdir(directory), key=lambda item: os.fsencode(item))
        for name in names:
            relative = name if not prefix else prefix + "/" + name
            value = os.stat(name, dir_fd=directory, follow_symlinks=False)
            if stat.S_ISDIR(value.st_mode):
                update("directory", relative, value)
                child = os.open(name, secure_directory_flags(), dir_fd=directory)
                try:
                    observed = os.fstat(child)
                    if (observed.st_dev, observed.st_ino) != (value.st_dev, value.st_ino):
                        raise ValueError("cleanup quarantine directory identity changed")
                    walk(child, relative)
                    unchanged(value, os.fstat(child), relative)
                finally:
                    os.close(child)
            elif stat.S_ISREG(value.st_mode):
                identity = (value.st_dev, value.st_ino)
                if value.st_nlink != 1 or identity in seen_regular:
                    raise ValueError("cleanup quarantine rejects hard-linked files")
                seen_regular.add(identity)
                update("file", relative, value)
                child = os.open(name, secure_file_flags(), dir_fd=directory)
                try:
                    observed = os.fstat(child)
                    if (observed.st_dev, observed.st_ino) != identity:
                        raise ValueError("cleanup quarantine file identity changed")
                    while True:
                        chunk = os.read(child, 1024 * 1024)
                        if not chunk:
                            break
                        digest.update(len(chunk).to_bytes(8, "big"))
                        digest.update(chunk)
                    unchanged(value, os.fstat(child), relative)
                finally:
                    os.close(child)
            elif stat.S_ISLNK(value.st_mode):
                update("symlink", relative, value)
                target = os.fsencode(os.readlink(name, dir_fd=directory))
                digest.update(len(target).to_bytes(8, "big"))
                digest.update(target)
                unchanged(
                    value,
                    os.stat(name, dir_fd=directory, follow_symlinks=False),
                    relative,
                )
            else:
                raise ValueError("cleanup quarantine contains an unsupported file type")
        unchanged(initial_directory, os.fstat(directory), prefix or ".")

    root = open_absolute_directory_nofollow(path)
    try:
        value = os.fstat(root)
        update("directory", ".", value)
        walk(root, "")
        unchanged(value, os.fstat(root), ".")
    finally:
        os.close(root)
    return "sha256:" + digest.hexdigest()


def quarantine_base_directory(common: str, locator: str, create: bool) -> str:
    parts = locator.split("/")
    if len(parts) != 3 or parts[:2] != ["workbench-v2", "cleanup-quarantine"]:
        raise ValueError("cleanup quarantine locator is invalid")
    current = common
    for index, part in enumerate(parts[:-1]):
        candidate = os.path.join(current, part)
        if not os.path.lexists(candidate):
            if not create:
                raise FileNotFoundError(candidate)
            os.mkdir(candidate, 0o700)
            fsync_directory(current)
        value = os.lstat(candidate)
        if not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode):
            raise ValueError("cleanup quarantine parent is not a private directory")
        if index == 1:
            os.chmod(candidate, 0o700)
        current = candidate
    return os.path.join(current, parts[-1])


def validate_local_quarantine_proof(
    value: Any,
    task_id: str,
    claim_id: str,
    branch: str,
    device_id: str,
    clone_id: str,
    workspace_locator: str,
    locator: str,
    journal_binding_digest: str,
) -> Mapping[str, Any]:
    require_fields(value, LOCAL_QUARANTINE_PROOF_FIELDS, "local quarantine proof")
    if tuple(value) != LOCAL_QUARANTINE_PROOF_FIELDS:
        raise ValueError("local quarantine proof fields are not canonical")
    if value["contract_version"] != "workbench-local-task-quarantine-proof/v1":
        raise ValueError("unsupported local quarantine proof contract")
    expected = {
        "task_id": task_id,
        "claim_id": claim_id,
        "branch": branch,
        "device_id": device_id,
        "clone_id": clone_id,
        "workspace_locator": workspace_locator,
        "quarantine_locator": locator,
        "journal_binding_digest": journal_binding_digest,
    }
    if any(value[field] != item for field, item in expected.items()):
        raise ValueError("local quarantine proof changed its cleanup binding")
    secret = require_arm_secret(value["arm_secret"], "local quarantine arm_secret")
    commitment = quarantine_arm_commitment(secret, journal_binding_digest)
    if value["arm_commitment"] != commitment:
        raise ValueError("local quarantine proof commitment mismatch")
    return value


def local_proof_for_journal(bundle: str, journal: Mapping[str, Any]) -> Mapping[str, Any]:
    authority = journal["quarantine_authority"]
    return validate_local_quarantine_proof(
        read_strict_local_json(
            os.path.join(bundle, "proof.json"),
            LOCAL_QUARANTINE_PROOF_FIELDS,
            "local quarantine proof",
        ),
        journal["task_id"],
        journal["claim_id"],
        journal["branch"],
        authority["device_id"],
        authority["clone_id"],
        authority["workspace_locator"],
        authority["quarantine_locator"],
        quarantine_arm_binding(journal),
    )


def admin_intent(
    root: str,
    source: str,
    kind: str,
    identity: str,
    quarantine_path: str,
) -> Mapping[str, Any]:
    value = os.lstat(source)
    if not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode):
        raise ValueError("cleanup quarantine admin source is not an exact directory")
    return {
        "kind": kind,
        "identity": identity,
        "source_locator": relative_managed_path(root, source, "admin source locator"),
        "quarantine_locator": require_relative_path(
            quarantine_path, "admin quarantine locator"
        ),
        "filesystem_device": str(value.st_dev),
        "filesystem_inode": str(value.st_ino),
    }


def build_local_quarantine_intent(
    root: str,
    task_path: str,
    common: str,
    journal: Mapping[str, Any],
    descriptor_file: Optional[str],
) -> Mapping[str, Any]:
    authority = journal["quarantine_authority"]
    workspace = os.lstat(task_path)
    if not stat.S_ISDIR(workspace.st_mode) or stat.S_ISLNK(workspace.st_mode):
        raise ValueError("cleanup quarantine workspace is not an exact directory")
    task_git_dir = normalized_real_path(
        task_path, git_value(task_path, "rev-parse", "--git-dir")
    )
    if os.path.dirname(task_git_dir) != os.path.join(common, "worktrees"):
        raise ValueError("cleanup quarantine task admin is outside the common directory")
    if git_value(task_path, "symbolic-ref", "--short", "HEAD") != journal["branch"]:
        raise ValueError("cleanup quarantine task branch changed")
    if descriptor_file is None:
        raise ValueError("cleanup quarantine requires the final ownership descriptor")
    descriptor = load_json(descriptor_file)
    expected_descriptor = {
        "real_path": os.path.realpath(task_path),
        "workspace_common_dir_real": os.path.realpath(common),
        "task_common_dir_real": os.path.realpath(common),
        "task_git_dir_real": os.path.realpath(task_git_dir),
        "branch": journal["branch"],
    }
    if any(descriptor.get(field) != item for field, item in expected_descriptor.items()):
        raise ValueError("cleanup quarantine descriptor changed before rename")

    admins = [
        admin_intent(root, task_git_dir, "task", journal["branch"], "admins/task")
    ]
    for item in journal["removal_plan"]["codebase_worktrees"]:
        owner = item["owner"]
        worktree = os.path.join(task_path, item["expected_path"])
        clone_common = normalized_real_path(
            worktree, git_value(worktree, "rev-parse", "--git-common-dir")
        )
        expected_common = os.path.realpath(
            os.path.join(root, ".codebases", owner, ".git")
        )
        if clone_common != expected_common:
            raise ValueError("cleanup quarantine codebase common directory changed")
        worktree_git = normalized_real_path(
            worktree, git_value(worktree, "rev-parse", "--git-dir")
        )
        if os.path.dirname(worktree_git) != os.path.join(clone_common, "worktrees"):
            raise ValueError("cleanup quarantine codebase admin is outside its clone")
        opaque = hashlib.sha256(
            (item["operation_id"] + "\0" + item["claim_id"] + "\0" + owner).encode(
                "utf-8"
            )
        ).hexdigest()
        admins.append(
            admin_intent(
                root,
                worktree_git,
                "codebase",
                "{}:{}:{}".format(item["operation_id"], item["claim_id"], owner),
                "admins/codebase-" + opaque,
            )
        )
    admins.sort(key=lambda item: (item["kind"], item["identity"]))
    if len({item["source_locator"] for item in admins}) != len(admins):
        raise ValueError("cleanup quarantine admin source is duplicated")
    devices = {int(item["filesystem_device"]) for item in admins}
    devices.add(workspace.st_dev)
    devices.add(os.lstat(common).st_dev)
    if len(devices) != 1:
        raise ValueError("cleanup quarantine paths cross filesystem boundaries")
    return {
        "contract_version": "workbench-local-task-quarantine-intent/v1",
        "task_id": journal["task_id"],
        "claim_id": journal["claim_id"],
        "branch": journal["branch"],
        "device_id": authority["device_id"],
        "clone_id": authority["clone_id"],
        "workspace_locator": authority["workspace_locator"],
        "quarantine_locator": authority["quarantine_locator"],
        "workspace_device": str(workspace.st_dev),
        "workspace_inode": str(workspace.st_ino),
        "admin_records": admins,
    }


def validate_local_quarantine_intent(
    value: Any, journal: Mapping[str, Any]
) -> Mapping[str, Any]:
    require_fields(value, LOCAL_QUARANTINE_INTENT_FIELDS, "local quarantine intent")
    if tuple(value) != LOCAL_QUARANTINE_INTENT_FIELDS:
        raise ValueError("local quarantine intent fields are not canonical")
    if value["contract_version"] != "workbench-local-task-quarantine-intent/v1":
        raise ValueError("unsupported local quarantine intent contract")
    authority = journal["quarantine_authority"]
    expected = {
        "task_id": journal["task_id"],
        "claim_id": journal["claim_id"],
        "branch": journal["branch"],
        "device_id": authority["device_id"],
        "clone_id": authority["clone_id"],
        "workspace_locator": authority["workspace_locator"],
        "quarantine_locator": authority["quarantine_locator"],
    }
    if any(value[field] != item for field, item in expected.items()):
        raise ValueError("local quarantine intent does not bind the journal")
    require_decimal_identity(value["workspace_device"], "workspace_device", True)
    require_decimal_identity(value["workspace_inode"], "workspace_inode", False)
    if not isinstance(value["admin_records"], list):
        raise ValueError("local quarantine admin records must be an array")
    seen = set()
    for record in value["admin_records"]:
        require_fields(record, LOCAL_ADMIN_INTENT_FIELDS, "local quarantine admin intent")
        if tuple(record) != LOCAL_ADMIN_INTENT_FIELDS:
            raise ValueError("local quarantine admin intent fields are not canonical")
        if record["kind"] not in ("task", "codebase"):
            raise ValueError("local quarantine admin kind is invalid")
        require_text(record["identity"], "local quarantine admin identity")
        require_relative_path(record["source_locator"], "admin source locator")
        require_relative_path(record["quarantine_locator"], "admin quarantine locator")
        require_decimal_identity(record["filesystem_device"], "admin device", True)
        require_decimal_identity(record["filesystem_inode"], "admin inode", False)
        identity = (record["source_locator"], record["quarantine_locator"])
        if identity in seen:
            raise ValueError("local quarantine admin record is duplicated")
        seen.add(identity)
    if not value["admin_records"] or value["admin_records"][-1]["kind"] != "task":
        # Canonical sorting puts codebase records before the one task record.
        raise ValueError("local quarantine intent has no canonical task admin")
    return value


def move_quarantine_entry(
    source: str,
    destination: str,
    expected_device: str,
    expected_inode: str,
) -> None:
    source_exists = os.path.lexists(source)
    destination_exists = os.path.lexists(destination)
    if source_exists and destination_exists:
        raise ValueError("cleanup quarantine source and destination are both occupied")
    if destination_exists:
        value = os.lstat(destination)
        if (
            not stat.S_ISDIR(value.st_mode)
            or stat.S_ISLNK(value.st_mode)
            or str(value.st_dev) != expected_device
            or str(value.st_ino) != expected_inode
        ):
            raise ValueError("cleanup quarantine destination identity changed")
        return
    if not source_exists:
        raise ValueError("cleanup quarantine entry is missing from both locations")
    value = os.lstat(source)
    if (
        not stat.S_ISDIR(value.st_mode)
        or stat.S_ISLNK(value.st_mode)
        or str(value.st_dev) != expected_device
        or str(value.st_ino) != expected_inode
    ):
        raise ValueError("cleanup quarantine source identity changed")
    hook = os.environ.get("WORKBENCH_TEST_QUARANTINE_RENAME_HOOK")
    if hook:
        subprocess.check_call([hook, source, destination])
    rename_directory_noreplace(source, destination)
    fsync_directory(os.path.dirname(source))
    fsync_directory(os.path.dirname(destination))
    moved = os.lstat(destination)
    if (str(moved.st_dev), str(moved.st_ino)) != (expected_device, expected_inode):
        raise ValueError("cleanup quarantine rename changed entry identity")


def rename_directory_noreplace(source: str, destination: str) -> None:
    source_parent = open_absolute_directory_nofollow(os.path.dirname(source))
    destination_parent = open_absolute_directory_nofollow(
        os.path.dirname(destination)
    )
    try:
        library = ctypes.CDLL(None, use_errno=True)
        source_name = os.fsencode(os.path.basename(source))
        destination_name = os.fsencode(os.path.basename(destination))
        if sys.platform == "darwin" and hasattr(library, "renameatx_np"):
            function = library.renameatx_np
            function.argtypes = (
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint,
            )
            function.restype = ctypes.c_int
            result = function(
                source_parent,
                source_name,
                destination_parent,
                destination_name,
                0x00000004,  # RENAME_EXCL
            )
        elif sys.platform.startswith("linux") and hasattr(library, "renameat2"):
            function = library.renameat2
            function.argtypes = (
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint,
            )
            function.restype = ctypes.c_int
            result = function(
                source_parent,
                source_name,
                destination_parent,
                destination_name,
                1,  # RENAME_NOREPLACE
            )
        else:
            raise OSError(
                errno.ENOTSUP,
                "cleanup quarantine requires an atomic no-replace rename",
            )
        if result != 0:
            error = ctypes.get_errno()
            if error in (errno.EEXIST, errno.ENOTEMPTY):
                raise ValueError("cleanup quarantine destination became occupied")
            raise OSError(error, os.strerror(error), destination)
    finally:
        os.close(destination_parent)
        os.close(source_parent)


def local_receipt_digest(value: Mapping[str, Any]) -> str:
    return quarantine_receipt_digest(external_quarantine_receipt(value))


def validate_local_quarantine_receipt(
    value: Any,
    intent: Mapping[str, Any],
    journal: Mapping[str, Any],
) -> Mapping[str, Any]:
    require_fields(value, LOCAL_QUARANTINE_RECEIPT_FIELDS, "local quarantine receipt")
    if tuple(value) != LOCAL_QUARANTINE_RECEIPT_FIELDS:
        raise ValueError("local quarantine receipt fields are not canonical")
    if value["contract_version"] != "workbench-local-task-quarantine-receipt/v1":
        raise ValueError("unsupported local quarantine receipt contract")
    for field in (
        "task_id",
        "claim_id",
        "branch",
        "device_id",
        "clone_id",
        "workspace_locator",
        "quarantine_locator",
        "workspace_device",
        "workspace_inode",
    ):
        if value[field] != intent[field]:
            raise ValueError("local quarantine receipt does not bind its intent")
    require_digest(value["receipt_digest"], "local quarantine receipt digest")
    require_digest(value["workspace_tree_digest"], "local quarantine workspace tree")
    require_digest(value["admin_manifest_digest"], "local quarantine admin manifest")
    require_time(value["quarantined_at"], "local quarantine receipt time")
    if not isinstance(value["admin_records"], list):
        raise ValueError("local quarantine receipt admin records must be an array")
    if len(value["admin_records"]) != len(intent["admin_records"]):
        raise ValueError("local quarantine receipt admin count changed")
    for receipt, expected in zip(value["admin_records"], intent["admin_records"]):
        require_fields(receipt, LOCAL_ADMIN_RECEIPT_FIELDS, "local quarantine admin receipt")
        if tuple(receipt) != LOCAL_ADMIN_RECEIPT_FIELDS:
            raise ValueError("local quarantine admin receipt fields are not canonical")
        if any(receipt[field] != expected[field] for field in LOCAL_ADMIN_INTENT_FIELDS):
            raise ValueError("local quarantine admin receipt changed its intent")
        require_digest(receipt["tree_digest"], "local quarantine admin tree")
    manifest_digest = sha256(canonical_json_bytes(value["admin_records"]))
    if manifest_digest != value["admin_manifest_digest"]:
        raise ValueError("local quarantine admin manifest digest mismatch")
    if local_receipt_digest(value) != value["receipt_digest"]:
        raise ValueError("local quarantine receipt digest mismatch")
    validate_quarantine_receipt(
        external_quarantine_receipt(value), journal, journal["quarantine_authority"]
    )
    return value


def external_quarantine_receipt(value: Mapping[str, Any]) -> Mapping[str, Any]:
    return {
        "contract_version": "workbench-task-quarantine-receipt/v1",
        "receipt_digest": value["receipt_digest"],
        "arm_secret": value["arm_secret"],
        "task_id": value["task_id"],
        "claim_id": value["claim_id"],
        "branch": value["branch"],
        "device_id": value["device_id"],
        "clone_id": value["clone_id"],
        "workspace_locator": value["workspace_locator"],
        "quarantine_locator": value["quarantine_locator"],
        "workspace_device": value["workspace_device"],
        "workspace_inode": value["workspace_inode"],
        "workspace_tree_digest": value["workspace_tree_digest"],
        "admin_manifest_digest": value["admin_manifest_digest"],
        "quarantined_at": value["quarantined_at"],
    }


def authenticate_local_quarantine(
    root: str,
    bundle: str,
    intent: Mapping[str, Any],
    journal: Mapping[str, Any],
    arm_secret: str,
) -> Mapping[str, Any]:
    workspace = os.path.join(bundle, "workspace")
    source_workspace = os.path.join(root, intent["workspace_locator"])
    if os.path.lexists(source_workspace):
        raise ValueError("cleanup quarantine original workspace path is occupied")
    value = os.lstat(workspace)
    if (
        not stat.S_ISDIR(value.st_mode)
        or stat.S_ISLNK(value.st_mode)
        or str(value.st_dev) != intent["workspace_device"]
        or str(value.st_ino) != intent["workspace_inode"]
    ):
        raise ValueError("cleanup quarantine workspace identity changed")
    workspace_digest = strict_tree_digest(workspace)
    admin_receipts = []
    for record in intent["admin_records"]:
        source = os.path.join(root, record["source_locator"])
        destination = os.path.join(bundle, record["quarantine_locator"])
        if os.path.lexists(source):
            raise ValueError("cleanup quarantine original admin path is occupied")
        observed = os.lstat(destination)
        if (
            not stat.S_ISDIR(observed.st_mode)
            or stat.S_ISLNK(observed.st_mode)
            or str(observed.st_dev) != record["filesystem_device"]
            or str(observed.st_ino) != record["filesystem_inode"]
        ):
            raise ValueError("cleanup quarantine admin identity changed")
        item = {field: record[field] for field in LOCAL_ADMIN_INTENT_FIELDS}
        item["tree_digest"] = strict_tree_digest(destination)
        admin_receipts.append(item)
    admin_digest = sha256(canonical_json_bytes(admin_receipts))
    receipt_path = os.path.join(bundle, "receipt.json")
    if os.path.lexists(receipt_path):
        receipt = validate_local_quarantine_receipt(
            read_strict_local_json(
                receipt_path, LOCAL_QUARANTINE_RECEIPT_FIELDS, "local quarantine receipt"
            ),
            intent,
            journal,
        )
        if (
            receipt["arm_secret"] != arm_secret
            or receipt["workspace_tree_digest"] != workspace_digest
            or receipt["admin_records"] != admin_receipts
            or receipt["admin_manifest_digest"] != admin_digest
        ):
            raise ValueError("cleanup quarantine tree changed after receipt publication")
        return receipt
    receipt_body = {
        "contract_version": "workbench-local-task-quarantine-receipt/v1",
        "arm_secret": arm_secret,
        "task_id": intent["task_id"],
        "claim_id": intent["claim_id"],
        "branch": intent["branch"],
        "device_id": intent["device_id"],
        "clone_id": intent["clone_id"],
        "workspace_locator": intent["workspace_locator"],
        "quarantine_locator": intent["quarantine_locator"],
        "workspace_device": intent["workspace_device"],
        "workspace_inode": intent["workspace_inode"],
        "workspace_tree_digest": workspace_digest,
        "admin_records": admin_receipts,
        "admin_manifest_digest": admin_digest,
        "quarantined_at": journal.get("_quarantine_at"),
    }
    require_time(receipt_body["quarantined_at"], "local quarantine receipt time")
    receipt = {"contract_version": receipt_body.pop("contract_version")}
    receipt["receipt_digest"] = ""
    receipt.update(receipt_body)
    receipt["receipt_digest"] = local_receipt_digest(receipt)
    ordered = {field: receipt[field] for field in LOCAL_QUARANTINE_RECEIPT_FIELDS}
    validate_local_quarantine_receipt(ordered, intent, journal)
    write_durable_json(bundle, "receipt.json", ordered)
    return ordered


def ensure_local_quarantine_bundle(common: str, locator: str) -> str:
    bundle = quarantine_base_directory(common, locator, True)
    admins = os.path.join(bundle, "admins")
    if not os.path.lexists(bundle):
        os.mkdir(bundle, 0o700)
        fsync_directory(os.path.dirname(bundle))
        os.mkdir(admins, 0o700)
        fsync_directory(bundle)
    else:
        value = os.lstat(bundle)
        admin_value = os.lstat(admins)
        if (
            not stat.S_ISDIR(value.st_mode)
            or stat.S_ISLNK(value.st_mode)
            or stat.S_IMODE(value.st_mode) != 0o700
            or not stat.S_ISDIR(admin_value.st_mode)
            or stat.S_ISLNK(admin_value.st_mode)
            or stat.S_IMODE(admin_value.st_mode) != 0o700
        ):
            raise ValueError("cleanup quarantine arm bundle is not exact")
    return bundle


def cmd_quarantine_proof(args: argparse.Namespace) -> None:
    journal = validate_journal(load_json(args.journal_file))
    if journal["stage"] != "prepared":
        raise ValueError("local quarantine proof requires a prepared journal")
    authority = journal["quarantine_authority"]
    if authority["device_id"] != args.device_id or authority["clone_id"] != args.clone_id:
        raise PermissionError("local quarantine proof belongs to another device or clone")
    workspace_locator = authority["workspace_locator"]
    locator = authority["quarantine_locator"]
    journal_binding_digest = quarantine_arm_binding(journal)
    if not os.path.isabs(args.workspace_root):
        raise ValueError("local quarantine proof workspace root must be absolute")
    root = os.path.realpath(args.workspace_root)
    task_path = os.path.join(root, workspace_locator)
    if os.path.realpath(args.task_dir) != task_path:
        raise ValueError("local quarantine proof task path does not bind the workspace")
    common = normalized_real_path(root, git_value(root, "rev-parse", "--git-common-dir"))
    if os.path.dirname(common) != root:
        raise ValueError("local quarantine proof common directory does not bind the workspace")
    bundle = ensure_local_quarantine_bundle(common, locator)
    proof_path = os.path.join(bundle, "proof.json")
    if os.path.lexists(proof_path):
        proof = validate_local_quarantine_proof(
            read_strict_local_json(
                proof_path, LOCAL_QUARANTINE_PROOF_FIELDS, "local quarantine proof"
            ),
            journal["task_id"],
            journal["claim_id"],
            journal["branch"],
            authority["device_id"],
            authority["clone_id"],
            workspace_locator,
            locator,
            journal_binding_digest,
        )
    else:
        unexpected = set(os.listdir(bundle)) - {"admins"}
        if unexpected or os.listdir(os.path.join(bundle, "admins")):
            raise ValueError("cleanup quarantine proof bundle contains unbound state")
        secret = secrets.token_hex(32)
        proof = {
            "contract_version": "workbench-local-task-quarantine-proof/v1",
            "task_id": journal["task_id"],
            "claim_id": journal["claim_id"],
            "branch": journal["branch"],
            "device_id": authority["device_id"],
            "clone_id": authority["clone_id"],
            "workspace_locator": workspace_locator,
            "quarantine_locator": locator,
            "journal_binding_digest": journal_binding_digest,
            "arm_commitment": quarantine_arm_commitment(secret, journal_binding_digest),
            "arm_secret": secret,
        }
        ordered = {field: proof[field] for field in LOCAL_QUARANTINE_PROOF_FIELDS}
        validate_local_quarantine_proof(
            ordered,
            journal["task_id"],
            journal["claim_id"],
            journal["branch"],
            authority["device_id"],
            authority["clone_id"],
            workspace_locator,
            locator,
            journal_binding_digest,
        )
        write_durable_json(bundle, "proof.json", ordered)
        proof = ordered
    sys.stdout.write(proof["arm_commitment"] + "\n")


def cmd_quarantine_create(args: argparse.Namespace) -> None:
    journal = dict(validate_journal(load_json(args.journal_file)))
    if journal["stage"] != "prepared":
        raise ValueError("local quarantine creation requires a prepared journal")
    authority = journal["quarantine_authority"]
    if authority["device_id"] != args.device_id or authority["clone_id"] != args.clone_id:
        raise PermissionError("cleanup quarantine is owned by another device or clone")
    if not os.path.isabs(args.workspace_root):
        raise ValueError("cleanup quarantine workspace root must be absolute")
    root = os.path.realpath(args.workspace_root)
    task_path = os.path.join(root, authority["workspace_locator"])
    if os.path.realpath(args.task_dir) != task_path:
        raise ValueError("cleanup quarantine task path does not bind the journal")
    common = normalized_real_path(root, git_value(root, "rev-parse", "--git-common-dir"))
    if os.path.dirname(common) != root:
        raise ValueError("cleanup quarantine common directory does not bind the workspace")
    bundle = quarantine_base_directory(common, authority["quarantine_locator"], False)
    value = os.lstat(bundle)
    if not stat.S_ISDIR(value.st_mode) or stat.S_ISLNK(value.st_mode):
        raise ValueError("cleanup quarantine bundle is not an exact directory")
    intent = validate_local_quarantine_intent(
        read_strict_local_json(
            os.path.join(bundle, "intent.json"),
            LOCAL_QUARANTINE_INTENT_FIELDS,
            "local quarantine intent",
        ),
        journal,
    )
    proof = local_proof_for_journal(bundle, journal)
    if os.path.lexists(task_path):
        current = build_local_quarantine_intent(
            root, task_path, common, journal, args.descriptor_file
        )
        if current != intent:
            raise ValueError("cleanup quarantine workspace no longer matches its local arm")
    validate_local_quarantine_intent(intent, journal)
    move_quarantine_entry(
        task_path,
        os.path.join(bundle, "workspace"),
        intent["workspace_device"],
        intent["workspace_inode"],
    )
    if os.environ.get("WORKBENCH_TEST_FAIL_QUARANTINE_STAGE") == "workspace-renamed":
        raise OSError("injected cleanup quarantine interruption after workspace rename")
    for record in intent["admin_records"]:
        move_quarantine_entry(
            os.path.join(root, record["source_locator"]),
            os.path.join(bundle, record["quarantine_locator"]),
            record["filesystem_device"],
            record["filesystem_inode"],
        )
    journal["_quarantine_at"] = args.at
    receipt = authenticate_local_quarantine(
        root, bundle, intent, journal, proof["arm_secret"]
    )
    write_json(external_quarantine_receipt(receipt))


def cmd_quarantine_arm(args: argparse.Namespace) -> None:
    journal = validate_journal(load_json(args.journal_file))
    if journal["stage"] != "prepared":
        raise ValueError("local quarantine arm requires a prepared journal")
    authority = journal["quarantine_authority"]
    if authority["device_id"] != args.device_id or authority["clone_id"] != args.clone_id:
        raise PermissionError("cleanup quarantine arm belongs to another device or clone")
    if not os.path.isabs(args.workspace_root):
        raise ValueError("cleanup quarantine workspace root must be absolute")
    root = os.path.realpath(args.workspace_root)
    task_path = os.path.join(root, authority["workspace_locator"])
    if os.path.realpath(args.task_dir) != task_path:
        raise ValueError("cleanup quarantine arm task path does not bind the journal")
    common = normalized_real_path(root, git_value(root, "rev-parse", "--git-common-dir"))
    if os.path.dirname(common) != root:
        raise ValueError("cleanup quarantine arm common directory does not bind the workspace")
    bundle = ensure_local_quarantine_bundle(common, authority["quarantine_locator"])
    local_proof_for_journal(bundle, journal)
    current = build_local_quarantine_intent(
        root, task_path, common, journal, args.descriptor_file
    )
    intent_path = os.path.join(bundle, "intent.json")
    if os.path.lexists(intent_path):
        stored = validate_local_quarantine_intent(
            read_strict_local_json(
                intent_path,
                LOCAL_QUARANTINE_INTENT_FIELDS,
                "local quarantine intent",
            ),
            journal,
        )
        if stored != current:
            raise ValueError("cleanup quarantine arm changed")
    else:
        unexpected = set(os.listdir(bundle)) - {"admins", "proof.json"}
        if unexpected or os.listdir(os.path.join(bundle, "admins")):
            raise ValueError("cleanup quarantine arm contains unbound state")
        write_durable_json(bundle, "intent.json", current)


def record_bytes(value: Mapping[str, str], fields: Sequence[str]) -> bytes:
    return ("".join("{}={}\n".format(field, value[field]) for field in fields)).encode(
        "utf-8"
    )


def validate_terminal_request(value: Any) -> Mapping[str, Any]:
    fields = (
        "contract_version",
        "action_id",
        "task_claim_id",
        "target_ref",
        "revision",
        "payload_contract",
        "payload",
    )
    require_fields(value, fields, "terminal checkpoint request")
    if tuple(value) != fields:
        raise ValueError("terminal checkpoint request fields are not canonical")
    if value["contract_version"] != "workbench-action-request/v1":
        raise ValueError("terminal checkpoint request contract is invalid")
    for field in ("action_id", "task_claim_id", "target_ref", "payload_contract"):
        require_text(value[field], field)
    require_digest(value["revision"], "terminal request revision")
    if not isinstance(value["payload"], str):
        raise ValueError("terminal checkpoint request payload is invalid")
    return value


def validate_terminal_checkpoint(value: Any) -> Mapping[str, Any]:
    require_fields(value, TERMINAL_CHECKPOINT_FIELDS, "terminal checkpoint")
    if tuple(value) != TERMINAL_CHECKPOINT_FIELDS:
        raise ValueError("terminal checkpoint fields are not canonical")
    if value["contract_version"] != "workbench-task-terminal-checkpoint/v1":
        raise ValueError("unsupported terminal checkpoint contract")
    for field in (
        "task_id",
        "claim_id",
        "branch",
        "repository_origin_url",
        "pull_request_url",
    ):
        require_text(value[field], field)
    if not isinstance(value["issue"], int) or isinstance(value["issue"], bool) or value["issue"] <= 0:
        raise ValueError("terminal checkpoint issue is invalid")
    if value["home"] is not None:
        require_text(value["home"], "home")
    if value["work_ref"] is not None:
        require_text(value["work_ref"], "work_ref")
    require_digest(
        value["workspace_authority_descriptor_digest"],
        "workspace_authority_descriptor_digest",
    )
    for field in ("snapshot_revision", "cleanup_revision", "head_revision"):
        if not isinstance(value[field], str) or OID.fullmatch(value[field]) is None:
            raise ValueError("terminal checkpoint {} is invalid".format(field))
    if value["head_revision"] != value["cleanup_revision"]:
        raise ValueError("terminal checkpoint PR head does not join cleanup")
    if (
        not isinstance(value["pull_request"], int)
        or isinstance(value["pull_request"], bool)
        or value["pull_request"] <= 0
    ):
        raise ValueError("terminal checkpoint pull request is invalid")
    require_time(value["at"], "terminal checkpoint at")

    terminal = require_fields(value["terminal"], TERMINAL_FIELDS, "terminal checkpoint terminal")
    action = require_fields(value["terminal_action"], ACTION_FIELDS, "terminal checkpoint action")
    if tuple(terminal) != TERMINAL_FIELDS or tuple(action) != ACTION_FIELDS:
        raise ValueError("terminal checkpoint record fields are not canonical")
    request = validate_terminal_request(value["terminal_request"])
    outcome = terminal["outcome"]
    expected_action = {"completed": "task.complete", "abandoned": "task.abandon"}.get(outcome)
    if expected_action is None:
        raise ValueError("terminal checkpoint outcome is invalid")
    for field in TERMINAL_FIELDS:
        if not isinstance(terminal[field], str):
            raise ValueError("terminal checkpoint terminal fields must be strings")
    for field in ACTION_FIELDS:
        if not isinstance(action[field], str):
            raise ValueError("terminal checkpoint action fields must be strings")
    expected = {
        "id": terminal["action_instance_id"],
        "action_id": expected_action,
        "task_claim_id": value["claim_id"],
        "target_ref": value["work_ref"] or ("workbench:task/" + value["claim_id"]),
        "revision": terminal["revision"],
        "intent_digest": terminal["intent_digest"],
        "policy_manifest_digest": terminal["policy_manifest_digest"],
        "authorization_ref": terminal["authorization_ref"],
    }
    for field, item in expected.items():
        if action[field] != item:
            raise ValueError("terminal checkpoint action binding mismatch: {}".format(field))
    if ACTION_ID.fullmatch(terminal["action_instance_id"]) is None:
        raise ValueError("terminal checkpoint action instance ID is invalid")
    for field in ("intent_digest", "policy_manifest_digest", "revision"):
        require_digest(terminal[field], "terminal " + field)
    for field in ("authorization_ref", "reason_ref"):
        if terminal[field]:
            require_text(terminal[field], "terminal " + field)
    require_time(terminal["at"], "terminal at")
    if value["at"] != terminal["at"]:
        raise ValueError("terminal checkpoint time does not join its terminal")
    if outcome == "completed":
        if any(
            terminal[field]
            for field in ("removal_plan_digest", "reason_code", "reason_ref")
        ):
            raise ValueError("completed terminal checkpoint carries abandonment fields")
    else:
        require_digest(terminal["removal_plan_digest"], "terminal removal plan")
        require_text(terminal["reason_code"], "terminal reason code")
    for field in ("revision", "intent_digest", "policy_manifest_digest"):
        require_digest(action[field], "terminal action " + field)
    authorization = (
        action["authorization_id"],
        action["authorization_ref"],
        action["authorization_actor"],
        action["authorization_at"],
    )
    if terminal["authorization_ref"]:
        require_rfc3339_utc(
            action["authorization_at"], "terminal action authorization_at"
        )
        if (
            not all(authorization)
            or re.fullmatch(
                r"auth_[A-Za-z0-9][A-Za-z0-9._-]*", action["authorization_id"]
            )
            is None
            or action["authorization_ref"] != terminal["authorization_ref"]
        ):
            raise ValueError("terminal checkpoint authorization is not exact")
        for field in (
            "authorization_id",
            "authorization_ref",
            "authorization_actor",
        ):
            require_text(action[field], "terminal action " + field)
    elif any(authorization):
        raise ValueError("terminal checkpoint carries an unbound authorization")
    primary_digest = sha256(record_bytes(terminal, TERMINAL_FIELDS))
    require_digest(value["terminal_primary_digest"], "terminal primary digest")
    if (
        value["terminal_primary_digest"] != primary_digest
        or action["status"] != "consumed"
        or action["consumed_provenance_digest"] != primary_digest
    ):
        raise ValueError("terminal checkpoint action projection is not primary-bound")
    for field in ("action_id", "task_claim_id", "target_ref", "revision"):
        if request[field] != action[field]:
            raise ValueError("terminal checkpoint request binding mismatch: {}".format(field))
    payload = parse_line_payload(request["payload_contract"], request["payload"])
    if (
        request["payload_contract"]
        != ("workbench-task-complete-intent/v1" if outcome == "completed" else "workbench-task-abandon-intent/v1")
        or payload["outcome"] != outcome
    ):
        raise ValueError("terminal checkpoint intent outcome mismatch")
    revision_field = "completion_snapshot" if outcome == "completed" else "abandonment_revision"
    if payload[revision_field] != terminal["revision"]:
        raise ValueError("terminal checkpoint intent revision mismatch")
    payload_digest = sha256(request["payload"].encode("utf-8"))
    if sha256(intent_manifest(request, payload_digest)) != action["intent_digest"]:
        raise ValueError("terminal checkpoint intent digest mismatch")

    return value


def cmd_terminal_checkpoint_build(args: argparse.Namespace) -> None:
    terminal = read_exact_record(Path(args.terminal_file), TERMINAL_FIELDS)
    action = dict(read_exact_record(Path(args.terminal_action_file), ACTION_FIELDS))
    primary_digest = sha256(record_bytes(terminal, TERMINAL_FIELDS))
    if action["status"] != "consumed" or action["consumed_provenance_digest"] != primary_digest:
        raise ValueError("consumed terminal action does not join its primary")
    request = load_json(args.terminal_request_file)
    value = dict(
        zip(
            TERMINAL_CHECKPOINT_FIELDS,
            (
                "workbench-task-terminal-checkpoint/v1",
                args.task_id,
                args.claim_id,
                args.issue,
                None if args.home == "-" else args.home,
                args.branch,
                None if args.work_ref == "-" else args.work_ref,
                args.descriptor_digest,
                args.repository_origin_url,
                args.snapshot_revision,
                args.cleanup_revision,
                args.pull_request,
                args.pull_request_url,
                args.head_revision,
                terminal,
                action,
                request,
                primary_digest,
                args.at,
            ),
        )
    )
    validate_terminal_checkpoint(value)
    if len(
        json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ) > 60000:
        raise ValueError("terminal checkpoint exceeds the authenticated comment budget")
    write_json(value)


def cmd_terminal_checkpoint_validate_recovery(args: argparse.Namespace) -> None:
    checkpoint = validate_terminal_checkpoint(load_json(args.checkpoint_file))
    require_digest(args.removal_plan_digest, "derived cleanup removal plan")
    if (
        checkpoint["terminal"]["outcome"] == "abandoned"
        and checkpoint["terminal"]["removal_plan_digest"]
        != args.removal_plan_digest
    ):
        raise ValueError("derived cleanup plan changed the abandoned terminal")
    directory = open_submission_directory(args.repository, False)
    if directory is None:
        raise ValueError("terminal checkpoint recovery cursor is unavailable")
    lock = -1
    try:
        lock = open_submission_lock(directory, args.branch)
        recovery = read_submission_recovery_at(directory, args.branch)
        if recovery is None or recovery["stage"] != "restored":
            raise ValueError("terminal checkpoint recovery is not restored")
        expected = {
            "repository_origin_url": checkpoint["repository_origin_url"],
            "branch": checkpoint["branch"],
            "task_id": checkpoint["task_id"],
            "issue": checkpoint["issue"],
            "home": checkpoint["home"],
            "claim_id": checkpoint["claim_id"],
            "workspace_authority_descriptor_digest": checkpoint[
                "workspace_authority_descriptor_digest"
            ],
            "snapshot_revision": checkpoint["snapshot_revision"],
            "cleanup_revision": checkpoint["cleanup_revision"],
            "pull_request": checkpoint["pull_request"],
            "pull_request_url": checkpoint["pull_request_url"],
            "head_revision": checkpoint["head_revision"],
        }
        for field, item in expected.items():
            if recovery[field] != item:
                raise ValueError(
                    "terminal checkpoint recovery binding mismatch: {}".format(field)
                )
        validate_recovery_snapshot(args.repository, recovery)
        validate_cleanup_revision(
            args.repository, recovery, recovery["cleanup_revision"]
        )
        validate_recovery_worktree(args.repository, recovery)
        _, index, _ = submission_snapshot_index(
            args.repository, recovery["snapshot_revision"], recovery["branch"]
        )
        if index["work_ref"] != checkpoint["work_ref"]:
            raise ValueError("terminal checkpoint work reference changed")
        target_ref = "workbench:task/" + checkpoint["claim_id"]
        validate_restored_submission_state(
            args.repository,
            directory,
            recovery,
            {
                "target_ref": target_ref,
                "terminal_revision": checkpoint["terminal"]["revision"],
                "removal_plan_digest": args.removal_plan_digest,
            },
        )
    finally:
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def cmd_terminal_checkpoint_find_observation(args: argparse.Namespace) -> None:
    values: List[Mapping[str, Any]] = []
    comments = load_comment_observation(
        args.observation_file, args.repository_origin_url, args.issue
    )
    groups: Dict[Tuple[str, str], Dict[str, Any]] = {}
    claim_actors: Dict[Tuple[str, str], str] = {}
    for comment in comments:
        for marker in parse_comment(
            comment["body"], comment["author_identity"], args.issue
        ):
            if marker["task_contract"] != "workbench-task/v2":
                continue
            reduce_lifecycle_marker(groups, marker)
            if marker["event"] == "task-claimed":
                claim_actors[(marker["branch"], marker["claim_id"])] = marker[
                    "actor"
                ]
    for comment in comments:
        body = comment["body"]
        matches = list(TERMINAL_CHECKPOINT_MARKER.finditer(body))
        if body.count("<!-- workbench-task-terminal-checkpoint:v1") != len(matches):
            raise ValueError("malformed terminal checkpoint marker")
        for match in matches:
            if len(match.group(1).encode("utf-8")) > 60000:
                raise ValueError("terminal checkpoint exceeds the authenticated comment budget")
            value = validate_terminal_checkpoint(
                json.loads(match.group(1), object_pairs_hook=unique_object)
            )
            if value["task_id"] != args.task_id or value["branch"] != args.branch:
                continue
            if (
                value["issue"] != args.issue
                or value["repository_origin_url"] != args.repository_origin_url
            ):
                raise ValueError("terminal checkpoint observation identity mismatch")
            lifecycle_matches = list(V2_MARKER.finditer(body))
            if body.count("<!-- workbench-task-lifecycle:v2") != len(lifecycle_matches):
                raise ValueError("malformed paired terminal lifecycle marker")
            terminal = value["terminal"]
            expected_event = (
                "task-completed"
                if terminal["outcome"] == "completed"
                else "task-abandoned"
            )
            terminal_markers = []
            for lifecycle_match in lifecycle_matches:
                marker = parse_v2(
                    lifecycle_match.group(1), comment["author_identity"], args.issue
                )
                if (
                    marker["event"] == expected_event
                    and marker["branch"] == value["branch"]
                    and marker["claim_id"] == value["claim_id"]
                ):
                    terminal_markers.append(marker)
            if len(terminal_markers) != 1:
                raise ValueError("terminal checkpoint is not paired one-to-one")
            marker = terminal_markers[0]
            expected = {
                "event": expected_event,
                "claim_id": value["claim_id"],
                "issue": value["issue"],
                "home": value["home"],
                "branch": value["branch"],
                "workspace_authority_descriptor_digest": value[
                    "workspace_authority_descriptor_digest"
                ],
                "pr": value["pull_request"],
                "revision": terminal["revision"],
                "action_instance_id": terminal["action_instance_id"],
                "intent_digest": terminal["intent_digest"],
            }
            if any(marker[field] != item for field, item in expected.items()):
                raise ValueError("terminal checkpoint lifecycle binding mismatch")
            key = (value["branch"], value["claim_id"])
            group = groups.get(key)
            other_live_claims = [
                candidate
                for candidate_key, candidate in groups.items()
                if candidate_key != key
                and candidate["branch"] == value["branch"]
                and not candidate["conflicted"]
            ]
            if (
                group is None
                or group["conflicted"]
                or group["phase"] != "terminal"
                or other_live_claims
            ):
                raise ValueError("terminal checkpoint has no unique winning claim")
            trusted_actor = claim_actors.get(key)
            if trusted_actor is None or comment["author_identity"] != trusted_actor:
                raise ValueError("terminal checkpoint actor does not own the winning claim")
            # The claimant attests the consumed action; its approving actor is independent.
            values.append(value)
    if not values:
        raise LookupError("terminal checkpoint not found")
    if len(values) != 1:
        raise ValueError("terminal checkpoint is duplicated or ambiguous")
    write_json(values[0])


def cmd_terminal_checkpoint_field(args: argparse.Namespace) -> None:
    value = validate_terminal_checkpoint(load_json(args.file))
    item: Any = value
    for field in args.field.split("."):
        if not isinstance(item, dict) or field not in item:
            raise ValueError("unknown terminal checkpoint field")
        item = item[field]
    if isinstance(item, (dict, list)):
        sys.stdout.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
    elif item is None:
        sys.stdout.write("\n")
    else:
        sys.stdout.write(str(item) + "\n")


def cmd_terminal_checkpoint_project(args: argparse.Namespace) -> None:
    value = validate_terminal_checkpoint(load_json(args.file))
    if args.projection == "action-record":
        sys.stdout.buffer.write(record_bytes(value["terminal_action"], ACTION_FIELDS))
    else:
        sys.stdout.write(
            json.dumps(
                value["terminal_request"],
                ensure_ascii=False,
                separators=(",", ":"),
            )
            + "\n"
        )


def immutable_binding(value: Mapping[str, Any]) -> str:
    selected = {
        key: value[key]
        for key in JOURNAL_FIELDS
        if key not in ("stage", "quarantine_receipt", "effect_owner_events", "at")
    }
    return json.dumps(selected, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def reduce_prefix(values: Sequence[Mapping[str, Any]]) -> Mapping[str, Any]:
    if not values:
        raise LookupError("cleanup journal not found")
    current = values[0]
    if current["stage"] != "prepared":
        raise ValueError("cleanup journal prefix must begin with prepared")
    binding = immutable_binding(current)
    for candidate in values[1:]:
        if immutable_binding(candidate) != binding:
            raise ValueError("cleanup journal immutable binding changed")
        if candidate["at"] < current["at"]:
            raise ValueError("cleanup journal timestamps are not monotonic")
        prior_events = current["effect_owner_events"]
        next_events = candidate["effect_owner_events"]
        if next_events[: len(prior_events)] != prior_events:
            raise ValueError("cleanup journal event prefix forked")
        if len(next_events) < len(prior_events):
            raise ValueError("cleanup journal event prefix shrank")
        if current["stage"] == "completed" and candidate != current:
            raise ValueError("cleanup journal changed after completion")
        if candidate == current:
            continue
        if current["quarantine_receipt"] is not None \
            and candidate["quarantine_receipt"] != current["quarantine_receipt"]:
            raise ValueError("cleanup quarantine receipt changed")
        legal = False
        if current["stage"] == "prepared":
            legal = (
                candidate["stage"] == "quarantined"
                and len(next_events) == 0
                and candidate["quarantine_receipt"] is not None
            )
        elif current["stage"] == "quarantined":
            legal = candidate["stage"] in ("quarantined", "completed")
            if candidate["stage"] == "completed" and len(next_events) != len(prior_events):
                legal = False
        if not legal:
            raise ValueError("cleanup journal prefix changed non-idempotently")
        current = candidate
    return current


def policy_binding(file: str) -> Tuple[Mapping[str, Any], Optional[str], Mapping[str, Any]]:
    value = load_json(file)
    require_fields(
        value,
        ("contract_version", "action_instance", "decision", "authorization_ref"),
        "policy resolution",
    )
    if value["contract_version"] != "workbench-policy/v1" or value["decision"] != "allow":
        raise ValueError("cleanup policy resolution must be allow")
    action = value["action_instance"]
    if not isinstance(action, dict):
        raise ValueError("cleanup policy action instance is invalid")
    manifest = validate_policy_manifest(action.get("policy_manifest"))
    authorization_ref = value["authorization_ref"]
    if authorization_ref is not None:
        require_text(authorization_ref, "authorization_ref")
    return manifest, authorization_ref, action


def cmd_build(args: argparse.Namespace) -> None:
    manifest, authorization_ref, action = policy_binding(args.policy_resolution_file)
    plan = load_json(args.removal_plan_file)
    raw_plan = plan_manifest(args.task_id, args.claim_id, args.branch, plan)
    if sha256(raw_plan) != args.removal_plan_digest:
        raise ValueError("supplied cleanup plan digest does not match the exact plan")
    if action.get("id") != args.action_instance_id:
        raise ValueError("cleanup action instance mismatch")
    if action.get("action_id") != "task.cleanup" or action.get("task_claim_id") != args.claim_id:
        raise ValueError("cleanup policy action binding mismatch")
    if action.get("revision") != args.revision or action.get("intent_digest") != args.intent_digest:
        raise ValueError("cleanup policy intent binding mismatch")
    authority = {
        "contract_version": "workbench-task-quarantine-authority/v1",
        "device_id": args.device_id,
        "clone_id": args.clone_id,
        "workspace_locator": plan["task_workspace"],
        "quarantine_locator": quarantine_locator(
            args.task_id,
            args.claim_id,
            args.branch,
            args.device_id,
            args.clone_id,
            plan["task_workspace"],
        ),
        "arm_commitment": args.arm_commitment,
    }
    value = {
        "contract_version": "workbench-task-cleanup-journal/v1",
        "journal_id": "cleanup-" + args.claim_id,
        "stage": "prepared",
        "task_id": args.task_id,
        "claim_id": args.claim_id,
        "branch": args.branch,
        "revision": args.revision,
        "action_instance_id": args.action_instance_id,
        "intent_digest": args.intent_digest,
        "policy_manifest": manifest,
        "authorization_ref": authorization_ref,
        "removal_plan_digest": args.removal_plan_digest,
        "removal_plan": plan,
        "quarantine_authority": authority,
        "quarantine_receipt": None,
        "effect_owner_events": [],
        "at": args.at,
    }
    validate_journal(value)
    write_json(value)


def cmd_stage(args: argparse.Namespace) -> None:
    value = dict(validate_journal(load_json(args.file)))
    require_time(args.at, "at")
    if args.at < value["at"]:
        raise ValueError("cleanup stage timestamp regressed")
    if value["stage"] == "completed" and args.stage != "completed":
        raise ValueError("completed cleanup journal is terminal")
    if args.stage != "completed" or value["stage"] != "quarantined":
        raise ValueError("cleanup stage transition is invalid")
    value["stage"] = args.stage
    value["at"] = args.at
    ordered = {key: value[key] for key in JOURNAL_FIELDS}
    validate_journal(ordered)
    write_json(ordered)


def cmd_quarantine(args: argparse.Namespace) -> None:
    value = dict(validate_journal(load_json(args.file)))
    receipt = validate_quarantine_receipt(
        load_json(args.receipt_file), value, value["quarantine_authority"]
    )
    require_time(args.at, "at")
    if args.at < value["at"] or args.at < receipt["quarantined_at"]:
        raise ValueError("cleanup quarantine timestamp regressed")
    if value["stage"] == "quarantined":
        if value["quarantine_receipt"] != receipt:
            raise ValueError("cleanup quarantine receipt changed")
    elif value["stage"] == "prepared":
        value["stage"] = "quarantined"
        value["quarantine_receipt"] = receipt
    else:
        raise ValueError("cleanup cannot quarantine from its current stage")
    value["at"] = args.at
    ordered = {key: value[key] for key in JOURNAL_FIELDS}
    validate_journal(ordered)
    write_json(ordered)


def cmd_append_event(args: argparse.Namespace) -> None:
    value = dict(validate_journal(load_json(args.file)))
    if value["stage"] != "quarantined":
        raise ValueError("cleanup owner events require a durable quarantine receipt")
    require_time(args.at, "at")
    event = {
        "event_id": args.event_id,
        "operation_id": args.operation_id,
        "claim_id": args.writer_claim_id,
        "device_id": args.device_id,
        "clone_id": args.clone_id,
        "state": args.state,
        "phase": args.phase,
        "at": args.at,
    }
    value["effect_owner_events"] = list(value["effect_owner_events"]) + [event]
    value["at"] = args.at
    ordered = {key: value[key] for key in JOURNAL_FIELDS}
    validate_journal(ordered)
    write_json(ordered)


def cmd_find(args: argparse.Namespace) -> None:
    with open(args.comments_file, "r", encoding="utf-8") as handle:
        text = handle.read()
    values: List[Mapping[str, Any]] = []
    for match in MARKER.finditer(text):
        value = json.loads(match.group(1), object_pairs_hook=unique_object)
        value = validate_journal(value)
        if value["task_id"] == args.task_id and value["branch"] == args.branch:
            values.append(value)
    write_json(reduce_prefix(values))


def cmd_find_observation(args: argparse.Namespace) -> None:
    values: List[Mapping[str, Any]] = []
    provenance_digests: List[str] = []
    comments = load_comment_observation(
        args.observation_file, args.repository_origin_url, args.issue
    )
    for comment in comments:
        body = comment["body"]
        matches = list(MARKER.finditer(body))
        if body.count("<!-- workbench-task-cleanup:v1") != len(matches):
            raise ValueError("malformed cleanup journal marker")
        for match in matches:
            value = validate_journal(
                json.loads(match.group(1), object_pairs_hook=unique_object)
            )
            if value["task_id"] != args.task_id or value["branch"] != args.branch:
                continue
            if comment["author_identity"] != args.expected_author:
                raise PermissionError("cleanup journal author is not authenticated")
            values.append(value)
            provenance_digests.append(sha256((match.group(1) + "\n").encode("utf-8")))
    reduced = reduce_prefix(values)
    Path(args.provenance_file).write_text(
        "".join(item + "\n" for item in provenance_digests), encoding="utf-8"
    )
    write_json(reduced)


def cmd_validate_snapshot(args: argparse.Namespace) -> None:
    journal = validate_journal(load_json(args.journal_file))
    task_dir = Path(args.task_dir)
    checkpoint = None
    if args.terminal_checkpoint_file is not None:
        checkpoint = validate_terminal_checkpoint(
            load_json(args.terminal_checkpoint_file)
        )
    index_path = task_dir / "task/index.md"
    if index_path.is_file():
        index = parse_index(str(index_path), args.branch)
    elif checkpoint is not None and args.snapshot_repository is not None:
        _, index, _ = submission_snapshot_index(
            args.snapshot_repository,
            checkpoint["snapshot_revision"],
            args.branch,
        )
    else:
        raise ValueError("cleanup task index provenance is missing")
    if (
        index["id"] != journal["task_id"]
        or index["claim_id"] != journal["claim_id"]
        or index["task_contract"] != "workbench-task/v2"
    ):
        raise ValueError("cleanup journal does not join the task index")
    target_ref = "workbench:task/" + journal["claim_id"]
    if checkpoint is None:
        now = parse_rfc3339_utc(args.now, "now")
        terminal = validate_terminal_record(
            task_dir,
            task_dir / "task/.workbench/terminal",
            journal["claim_id"],
            now,
        )
    else:
        expected_checkpoint = {
            "task_id": journal["task_id"],
            "claim_id": journal["claim_id"],
            "branch": journal["branch"],
            "work_ref": index["work_ref"],
        }
        for field, item in expected_checkpoint.items():
            if checkpoint[field] != item:
                raise ValueError(
                    "cleanup journal terminal checkpoint mismatch: {}".format(field)
                )
        terminal_path = task_dir / "task/.workbench/terminal"
        if terminal_path.exists() or terminal_path.is_symlink():
            raise ValueError("remote terminal checkpoint has a local terminal projection")
        terminal = checkpoint["terminal"]
        if (
            terminal["outcome"] == "abandoned"
            and terminal["removal_plan_digest"] != journal["removal_plan_digest"]
        ):
            raise ValueError("cleanup journal changed the abandoned removal plan")
    if terminal["revision"] != journal["revision"]:
        raise ValueError("cleanup journal does not join the terminal revision")

    state = task_dir / "task/.workbench"
    action_file = state / "actions" / (journal["action_instance_id"] + ".record")
    request_file = state / "actions" / (journal["action_instance_id"] + ".request.json")
    payload = (
        "workbench-task-cleanup-intent/v1\n"
        "terminal_revision\t{}\n"
        "removal_plan_digest\t{}\n"
    ).format(journal["revision"], journal["removal_plan_digest"])
    request = {
        "contract_version": "workbench-action-request/v1",
        "action_id": "task.cleanup",
        "task_claim_id": journal["claim_id"],
        "target_ref": target_ref,
        "revision": journal["revision"],
        "payload_contract": "workbench-task-cleanup-intent/v1",
        "payload": payload,
    }
    payload_digest = sha256(payload.encode("utf-8"))
    if sha256(intent_manifest(request, payload_digest)) != journal["intent_digest"]:
        raise ValueError("cleanup journal intent does not bind its immutable request")

    if not action_file.exists() and not request_file.exists():
        if not args.allow_missing_private_action:
            raise ValueError("cleanup private action provenance is missing")
        return
    if not action_file.is_file() or not request_file.is_file():
        raise ValueError("cleanup private action provenance is incomplete")

    action = read_exact_record(action_file, ACTION_FIELDS)
    manifest = validate_policy_manifest(journal["policy_manifest"])
    expected = {
        "id": journal["action_instance_id"],
        "action_id": "task.cleanup",
        "task_claim_id": journal["claim_id"],
        "target_ref": target_ref,
        "revision": journal["revision"],
        "intent_digest": journal["intent_digest"],
        "policy_manifest_digest": manifest["digest"],
        "authorization_ref": "" if journal["authorization_ref"] is None else journal["authorization_ref"],
    }
    for field, value in expected.items():
        if action[field] != value:
            raise ValueError("cleanup action does not join journal field {}".format(field))
    if action["status"] not in ("authorized", "consumed"):
        raise ValueError("cleanup action is not authorized or consumed")

    stored_request = load_request(str(request_file))
    if (
        stored_request["action_id"] != "task.cleanup"
        or stored_request["task_claim_id"] != journal["claim_id"]
        or stored_request["target_ref"] != target_ref
        or stored_request["revision"] != journal["revision"]
        or stored_request["intent_digest"] != journal["intent_digest"]
    ):
        raise ValueError("cleanup request does not join the journal")
    payload_fields = parse_line_payload(
        stored_request["payload_contract"], stored_request["payload"]
    )
    if (
        payload_fields["terminal_revision"] != journal["revision"]
        or payload_fields["removal_plan_digest"] != journal["removal_plan_digest"]
    ):
        raise ValueError("cleanup request payload does not join the removal plan")
    if action["status"] == "consumed":
        provenance = Path(args.provenance_file).read_text(encoding="utf-8").splitlines()
        if (
            not provenance
            or len(provenance) != len(set(provenance))
            or any(DIGEST.fullmatch(item) is None for item in provenance)
            or action["consumed_provenance_digest"] not in provenance
        ):
            raise ValueError("consumed cleanup action does not join the journal bytes")


def cmd_field(args: argparse.Namespace) -> None:
    value = validate_journal(load_json(args.file))
    item = value[args.field]
    if isinstance(item, (dict, list)):
        sys.stdout.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
    elif item is None:
        sys.stdout.write("\n")
    else:
        sys.stdout.write(str(item) + "\n")


def cmd_list(args: argparse.Namespace) -> None:
    value = validate_journal(load_json(args.file))
    if args.collection == "writer_operations":
        for item in value["removal_plan"]["writer_operations"]:
            sys.stdout.write(
                "{}\t{}\t{}\n".format(
                    item["operation_id"], item["claim_id"], item["disposition"]
                )
            )
    else:
        for item in value["removal_plan"]["codebase_worktrees"]:
            sys.stdout.write(
                "{}\t{}\t{}\t{}\n".format(
                    item["operation_id"],
                    item["claim_id"],
                    item["owner"],
                    item["expected_path"],
                )
            )


def cmd_event_state(args: argparse.Namespace) -> None:
    value = validate_journal(load_json(args.file))
    events = [
        item
        for item in value["effect_owner_events"]
        if item["operation_id"] == args.operation_id and item["claim_id"] == args.writer_claim_id
    ]
    verified = [item for item in events if item["phase"] == "verified"]
    current = "none" if not verified else verified[-1]["state"]
    last = None if not events else events[-1]
    rows = (
        ("current_state", current),
        ("last_event_id", "" if last is None else last["event_id"]),
        ("last_device_id", "" if last is None else last["device_id"]),
        ("last_clone_id", "" if last is None else last["clone_id"]),
        ("last_state", "" if last is None else last["state"]),
        ("last_phase", "" if last is None else last["phase"]),
    )
    for key, item in rows:
        sys.stdout.write("{}={}\n".format(key, item))


def cmd_verify_released_writers(args: argparse.Namespace) -> None:
    journal = validate_journal(load_json(args.journal_file))
    rows, _ = read_ledger(args.ledger_file)
    worktrees = {
        (item["operation_id"], item["claim_id"]): item
        for item in journal["removal_plan"]["codebase_worktrees"]
    }
    effects_by_id = {
        item["event_id"]: item for item in rows if item["kind"] == "effect-owner"
    }
    for operation in journal["removal_plan"]["writer_operations"]:
        identity = (operation["operation_id"], operation["claim_id"])
        claims = [
            item
            for item in rows
            if item["kind"] == "claim"
            and (item["operation_id"], item["claim_id"]) == identity
        ]
        effects = [
            item
            for item in rows
            if item["kind"] == "effect-owner"
            and (item["operation_id"], item["claim_id"]) == identity
        ]
        state = current_claim_state(claims)
        if operation["disposition"] == "cancel-no-effect":
            if state != "absent" or effects:
                raise ValueError("cancelled cleanup writer has remote effects")
            continue
        if state != "released" or not claims:
            raise ValueError("cleanup writer release is not remotely durable")
        for claim in claims:
            if (
                claim["task_claim_id"] != journal["claim_id"]
                or claim["branch"] != journal["branch"]
            ):
                raise ValueError("cleanup writer claim does not join the journal")
            worktree = worktrees.get(identity)
            if worktree is not None and (
                claim["owner"] != worktree["owner"]
                or claim["expected_path"] != worktree["expected_path"]
            ):
                raise ValueError("cleanup writer worktree does not join the remote claim")
        effect = latest_effect(effects)
        if effect is not None and effect["state"] == "acquired":
            raise ValueError("cleanup writer still has a remote effect owner")
    for event in journal["effect_owner_events"]:
        if event["phase"] != "verified":
            continue
        remote = effects_by_id.get(event["event_id"])
        if remote is None or any(
            remote[field] != event[field]
            for field in (
                "operation_id",
                "claim_id",
                "device_id",
                "clone_id",
                "state",
            )
        ):
            raise ValueError("verified cleanup owner event does not join the remote ledger")


def cmd_writer_state(args: argparse.Namespace) -> None:
    journal = validate_journal(load_json(args.journal_file))
    if journal["stage"] not in ("quarantined", "completed"):
        raise ValueError("cleanup writer state requires a durable quarantine receipt")
    planned = [
        item
        for item in journal["removal_plan"]["writer_operations"]
        if item["operation_id"] == args.operation_id
        and item["claim_id"] == args.writer_claim_id
    ]
    if len(planned) != 1:
        raise ValueError("cleanup writer identity is not uniquely planned")
    operation = planned[0]
    rows, _ = read_ledger(args.ledger_file)
    claims = [
        item
        for item in rows
        if item["kind"] == "claim"
        and item["operation_id"] == args.operation_id
        and item["claim_id"] == args.writer_claim_id
    ]
    effects = [
        item
        for item in rows
        if item["kind"] == "effect-owner"
        and item["operation_id"] == args.operation_id
        and item["claim_id"] == args.writer_claim_id
    ]
    for claim in claims:
        if claim["task_claim_id"] != journal["claim_id"] or claim["branch"] != journal["branch"]:
            raise ValueError("cleanup writer claim does not join the quarantined task")
    worktrees = [
        item
        for item in journal["removal_plan"]["codebase_worktrees"]
        if item["operation_id"] == args.operation_id
        and item["claim_id"] == args.writer_claim_id
    ]
    if len(worktrees) > 1:
        raise ValueError("cleanup writer has duplicate worktree plans")
    if worktrees and any(
        claim["owner"] != worktrees[0]["owner"]
        or claim["expected_path"] != worktrees[0]["expected_path"]
        for claim in claims
    ):
        raise ValueError("cleanup writer worktree does not join its remote claim")
    claim_state = current_claim_state(claims)
    effect = latest_effect(effects)
    if operation["disposition"] == "cancel-no-effect":
        if claim_state != "absent" or effect is not None:
            raise ValueError("cancel-no-effect writer has remote effects")
    elif not claims or claim_state not in ("active", "released"):
        raise ValueError("cleanup writer has no releasable remote claim")
    values = {
        "disposition": operation["disposition"],
        "claim_state": claim_state,
        "effect_owner_event_id": "" if effect is None else effect["event_id"],
        "effect_owner_device_id": "" if effect is None else effect["device_id"],
        "effect_owner_clone_id": "" if effect is None else effect["clone_id"],
        "effect_owner_state": "" if effect is None else effect["state"],
    }
    for key, item in values.items():
        sys.stdout.write("{}={}\n".format(key, item))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    build.add_argument("--policy-resolution-file", required=True)
    build.add_argument("--task-id", required=True)
    build.add_argument("--claim-id", required=True)
    build.add_argument("--branch", required=True)
    build.add_argument("--revision", required=True)
    build.add_argument("--action-instance-id", required=True)
    build.add_argument("--intent-digest", required=True)
    build.add_argument("--removal-plan-digest", required=True)
    build.add_argument("--removal-plan-file", required=True)
    build.add_argument("--device-id", required=True)
    build.add_argument("--clone-id", required=True)
    build.add_argument("--arm-commitment", required=True)
    build.add_argument("--at", required=True)
    build.set_defaults(func=cmd_build)

    stage = commands.add_parser("stage")
    stage.add_argument("file")
    stage.add_argument("--stage", choices=tuple(sorted(STAGES)), required=True)
    stage.add_argument("--at", required=True)
    stage.set_defaults(func=cmd_stage)

    quarantine = commands.add_parser("quarantine")
    quarantine.add_argument("file")
    quarantine.add_argument("--receipt-file", required=True)
    quarantine.add_argument("--at", required=True)
    quarantine.set_defaults(func=cmd_quarantine)

    quarantine_create = commands.add_parser("quarantine-create")
    quarantine_create.add_argument("--journal-file", required=True)
    quarantine_create.add_argument("--workspace-root", required=True)
    quarantine_create.add_argument("--task-dir", required=True)
    quarantine_create.add_argument("--descriptor-file")
    quarantine_create.add_argument("--device-id", required=True)
    quarantine_create.add_argument("--clone-id", required=True)
    quarantine_create.add_argument("--at", required=True)
    quarantine_create.set_defaults(func=cmd_quarantine_create)

    quarantine_proof = commands.add_parser("quarantine-proof")
    quarantine_proof.add_argument("--journal-file", required=True)
    quarantine_proof.add_argument("--workspace-root", required=True)
    quarantine_proof.add_argument("--task-dir", required=True)
    quarantine_proof.add_argument("--device-id", required=True)
    quarantine_proof.add_argument("--clone-id", required=True)
    quarantine_proof.set_defaults(func=cmd_quarantine_proof)

    quarantine_arm = commands.add_parser("quarantine-arm")
    quarantine_arm.add_argument("--journal-file", required=True)
    quarantine_arm.add_argument("--workspace-root", required=True)
    quarantine_arm.add_argument("--task-dir", required=True)
    quarantine_arm.add_argument("--descriptor-file", required=True)
    quarantine_arm.add_argument("--device-id", required=True)
    quarantine_arm.add_argument("--clone-id", required=True)
    quarantine_arm.set_defaults(func=cmd_quarantine_arm)

    event = commands.add_parser("append-event")
    event.add_argument("file")
    event.add_argument("--event-id", required=True)
    event.add_argument("--operation-id", required=True)
    event.add_argument("--writer-claim-id", required=True)
    event.add_argument("--device-id", required=True)
    event.add_argument("--clone-id", required=True)
    event.add_argument("--state", choices=("acquired", "released"), required=True)
    event.add_argument("--phase", choices=("intended", "verified"), required=True)
    event.add_argument("--at", required=True)
    event.set_defaults(func=cmd_append_event)

    find = commands.add_parser("find")
    find.add_argument("--comments-file", required=True)
    find.add_argument("--task-id", required=True)
    find.add_argument("--branch", required=True)
    find.set_defaults(func=cmd_find)
    observed = commands.add_parser("find-observation")
    observed.add_argument("--observation-file", required=True)
    observed.add_argument("--repository-origin-url", required=True)
    observed.add_argument("--issue", type=int, required=True)
    observed.add_argument("--task-id", required=True)
    observed.add_argument("--branch", required=True)
    observed.add_argument("--expected-author", required=True)
    observed.add_argument("--provenance-file", required=True)
    observed.set_defaults(func=cmd_find_observation)
    snapshot = commands.add_parser("validate-snapshot")
    snapshot.add_argument("--journal-file", required=True)
    snapshot.add_argument("--task-dir", required=True)
    snapshot.add_argument("--branch", required=True)
    snapshot.add_argument("--now", required=True)
    snapshot.add_argument("--provenance-file", required=True)
    snapshot.add_argument("--allow-missing-private-action", action="store_true")
    snapshot.add_argument("--terminal-checkpoint-file")
    snapshot.add_argument("--snapshot-repository")
    snapshot.set_defaults(func=cmd_validate_snapshot)

    field = commands.add_parser("field")
    field.add_argument("file")
    field.add_argument("field", choices=JOURNAL_FIELDS)
    field.set_defaults(func=cmd_field)

    listing = commands.add_parser("list")
    listing.add_argument("file")
    listing.add_argument("collection", choices=("writer_operations", "codebase_worktrees"))
    listing.set_defaults(func=cmd_list)
    event_state = commands.add_parser("event-state")
    event_state.add_argument("file")
    event_state.add_argument("--operation-id", required=True)
    event_state.add_argument("--writer-claim-id", required=True)
    event_state.set_defaults(func=cmd_event_state)
    released = commands.add_parser("verify-released-writers")
    released.add_argument("--journal-file", required=True)
    released.add_argument("--ledger-file", required=True)
    released.set_defaults(func=cmd_verify_released_writers)
    writer_state = commands.add_parser("writer-state")
    writer_state.add_argument("--journal-file", required=True)
    writer_state.add_argument("--ledger-file", required=True)
    writer_state.add_argument("--operation-id", required=True)
    writer_state.add_argument("--writer-claim-id", required=True)
    writer_state.set_defaults(func=cmd_writer_state)
    checkpoint = commands.add_parser("terminal-checkpoint-build")
    checkpoint.add_argument("--task-id", required=True)
    checkpoint.add_argument("--claim-id", required=True)
    checkpoint.add_argument("--issue", type=int, required=True)
    checkpoint.add_argument("--home", required=True)
    checkpoint.add_argument("--branch", required=True)
    checkpoint.add_argument("--work-ref", required=True)
    checkpoint.add_argument("--descriptor-digest", required=True)
    checkpoint.add_argument("--repository-origin-url", required=True)
    checkpoint.add_argument("--snapshot-revision", required=True)
    checkpoint.add_argument("--cleanup-revision", required=True)
    checkpoint.add_argument("--pull-request", type=int, required=True)
    checkpoint.add_argument("--pull-request-url", required=True)
    checkpoint.add_argument("--head-revision", required=True)
    checkpoint.add_argument("--terminal-file", required=True)
    checkpoint.add_argument("--terminal-action-file", required=True)
    checkpoint.add_argument("--terminal-request-file", required=True)
    checkpoint.add_argument("--at", required=True)
    checkpoint.set_defaults(func=cmd_terminal_checkpoint_build)
    checkpoint_find = commands.add_parser("terminal-checkpoint-find-observation")
    checkpoint_find.add_argument("--observation-file", required=True)
    checkpoint_find.add_argument("--repository-origin-url", required=True)
    checkpoint_find.add_argument("--issue", type=int, required=True)
    checkpoint_find.add_argument("--task-id", required=True)
    checkpoint_find.add_argument("--branch", required=True)
    checkpoint_find.set_defaults(func=cmd_terminal_checkpoint_find_observation)
    checkpoint_validate = commands.add_parser(
        "terminal-checkpoint-validate-recovery"
    )
    checkpoint_validate.add_argument("--checkpoint-file", required=True)
    checkpoint_validate.add_argument("--repository", required=True)
    checkpoint_validate.add_argument("--branch", required=True)
    checkpoint_validate.add_argument("--removal-plan-digest", required=True)
    checkpoint_validate.set_defaults(
        func=cmd_terminal_checkpoint_validate_recovery
    )
    checkpoint_field = commands.add_parser("terminal-checkpoint-field")
    checkpoint_field.add_argument("file")
    checkpoint_field.add_argument("field")
    checkpoint_field.set_defaults(func=cmd_terminal_checkpoint_field)
    checkpoint_project = commands.add_parser("terminal-checkpoint-project")
    checkpoint_project.add_argument("file")
    checkpoint_project.add_argument(
        "projection", choices=("action-record", "request")
    )
    checkpoint_project.set_defaults(func=cmd_terminal_checkpoint_project)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.func(args)
    except LookupError as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 1
    except PermissionError as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 3
    except (OSError, UnicodeError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
