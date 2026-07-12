#!/usr/bin/env python3
"""Strict external cleanup-journal codec and prefix reducer."""

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

from workbench_intent import intent_manifest, load_request, parse_line_payload
from workbench_lifecycle import (
    V2_MARKER,
    load_comment_observation,
    open_submission_lock,
    open_submission_directory,
    parse_index,
    parse_v2,
    read_submission_recovery_at,
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
STAGES = {"prepared", "effect-owner-acquired", "effect-owner-released", "completed"}
DISPOSITIONS = {
    "cancel-no-effect",
    "compensate-release",
    "retire-consumed",
    "release-handoff",
}
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
ACTION_ID = re.compile(r"act_[A-Za-z0-9][A-Za-z0-9._-]*\Z")
RFC3339_UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
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
    if not isinstance(value, str) or RFC3339_UTC.fullmatch(value) is None:
        raise ValueError("{} must be an RFC3339 UTC timestamp".format(field))
    return value


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
    events = validate_events(value["effect_owner_events"])
    require_time(value["at"], "at")
    pending = bool(events and events[-1]["phase"] == "intended")
    verified = [event for event in events if event["phase"] == "verified"]
    expected_stage = "prepared"
    if verified:
        expected_stage = "effect-owner-" + verified[-1]["state"]
    if value["stage"] == "completed" and pending:
        raise ValueError("completed cleanup journal has an unverified owner event")
    if value["stage"] != "completed" and value["stage"] != expected_stage:
        raise ValueError("cleanup stage does not match its verified owner-event prefix")
    return value


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
        if (
            not all(authorization)
            or re.fullmatch(
                r"auth_[A-Za-z0-9][A-Za-z0-9._-]*", action["authorization_id"]
            )
            is None
            or action["authorization_ref"] != terminal["authorization_ref"]
            or RFC3339_UTC.fullmatch(action["authorization_at"]) is None
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


def immutable_binding(value: Mapping[str, Any]) -> str:
    selected = {key: value[key] for key in JOURNAL_FIELDS if key not in ("stage", "effect_owner_events", "at")}
    return json.dumps(selected, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def reduce_prefix(values: Sequence[Mapping[str, Any]]) -> Mapping[str, Any]:
    if not values:
        raise LookupError("cleanup journal not found")
    current = values[0]
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
        if len(next_events) == len(prior_events):
            if candidate == current:
                continue
            legal_stage_only = (
                current["stage"] != "completed"
                and candidate["stage"] == "completed"
                and candidate["at"] >= current["at"]
            )
            if not legal_stage_only:
                raise ValueError("duplicate cleanup prefix changed non-idempotently")
        if current["stage"] == "completed" and candidate != current:
            raise ValueError("cleanup journal changed after completion")
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
    value["stage"] = args.stage
    value["at"] = args.at
    ordered = {key: value[key] for key in JOURNAL_FIELDS}
    validate_journal(ordered)
    write_json(ordered)


def cmd_append_event(args: argparse.Namespace) -> None:
    value = dict(validate_journal(load_json(args.file)))
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
    if args.phase == "verified":
        value["stage"] = "effect-owner-" + args.state
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
        now = datetime.datetime.strptime(args.now, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc
        )
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
    build.add_argument("--at", required=True)
    build.set_defaults(func=cmd_build)

    stage = commands.add_parser("stage")
    stage.add_argument("file")
    stage.add_argument("--stage", choices=tuple(sorted(STAGES)), required=True)
    stage.add_argument("--at", required=True)
    stage.set_defaults(func=cmd_stage)

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
