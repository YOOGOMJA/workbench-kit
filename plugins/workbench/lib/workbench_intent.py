#!/usr/bin/env python3
"""Strict parsing and hashing for governed workbench action intents."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from typing import Any, Dict, Iterable, Mapping, Sequence, Tuple


REQUEST_FIELDS = (
    "contract_version",
    "action_id",
    "task_claim_id",
    "target_ref",
    "revision",
    "payload_contract",
    "payload",
)

AUTHORIZATION_FIELDS = (
    "contract_version",
    "authorization_id",
    "action_instance_id",
    "action_id",
    "task_claim_id",
    "target_ref",
    "revision",
    "intent_digest",
    "policy_manifest_digest",
    "decision",
    "actor",
    "authorized_at",
    "source_ref",
)

ACTION_PAYLOADS = {
    "task.complete": "workbench-task-complete-intent/v1",
    "task.abandon": "workbench-task-abandon-intent/v1",
    "task.deliverable.accept": "workbench-deliverable-accept-intent/v1",
    "task.deliverable.waive": "workbench-deliverable-transition-intent/v1",
    "task.deliverable.reject": "workbench-deliverable-transition-intent/v1",
    "task.deliverable.weaken": "workbench-deliverable-transition-intent/v1",
    "task.required-check.waive": "workbench-required-check-waive-intent/v1",
    "task.harvest.dispose": "workbench-harvest-disposition-intent/v1",
    "task.policy-context.register": "workbench-context-policy-registration/v1",
    "task.policy-context.seal": "workbench-context-policy-set/v1",
    "task.concurrent-write": "workbench-writer-request/v1",
    "task.cleanup": "workbench-task-cleanup-intent/v1",
}

PAYLOAD_FIELDS = {
    "workbench-task-complete-intent/v1": (
        "outcome",
        "completion_snapshot",
    ),
    "workbench-task-abandon-intent/v1": (
        "outcome",
        "abandonment_revision",
        "reason_code",
        "reason_ref",
    ),
    "workbench-deliverable-transition-intent/v1": (
        "deliverable_id",
        "record_revision",
        "transition",
        "from_required",
        "to_required",
        "from_state",
        "to_state",
        "reason_code",
        "reason_ref",
    ),
    "workbench-deliverable-accept-intent/v1": (
        "deliverable_id",
        "record_revision",
        "mode",
        "acceptance_id",
        "deliverable_revision",
        "owner_context_ref",
        "acceptance_authority_ref",
        "authority_contract",
        "subject_authority_digest",
        "actor",
        "accepted_at",
    ),
    "workbench-required-check-waive-intent/v1": (
        "check_id",
        "record_revision",
        "transition",
        "reason_code",
        "reason_ref",
    ),
    "workbench-harvest-disposition-intent/v1": (
        "candidate_id",
        "record_revision",
        "decision",
        "target_ref",
        "reason_code",
        "reason_ref",
    ),
    "workbench-writer-request/v1": (
        "operation_id",
        "claim_id",
        "owner",
        "branch",
        "expected_path",
        "codebase_origin_url",
        "context_policy_set_digest",
        "conflict_revision",
    ),
    "workbench-task-cleanup-intent/v1": (
        "terminal_revision",
        "removal_plan_digest",
    ),
}

DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
RFC3339_UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")


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


def strict_object(file: str, fields: Sequence[str]) -> Dict[str, Any]:
    value = load_json(file)
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError("JSON object fields do not match the contract")
    return value


def require_text(value: Any, field: str, allow_null_token: bool = False) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("{} must be a non-empty string".format(field))
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("{} must not contain control characters".format(field))
    if not allow_null_token and value == "null":
        raise ValueError("{} must not use the null token".format(field))
    return value


def require_digest(value: Any, field: str) -> str:
    if not isinstance(value, str) or DIGEST.fullmatch(value) is None:
        raise ValueError("{} must be a canonical SHA-256 digest".format(field))
    return value


def sha256(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def parse_line_payload(contract: str, payload: str) -> Dict[str, str]:
    if not payload.endswith("\n") or "\r" in payload:
        raise ValueError("intent payload must be LF-terminated")
    lines = payload[:-1].split("\n")
    fields = PAYLOAD_FIELDS[contract]
    if not lines or lines[0] != contract or len(lines) != len(fields) + 1:
        raise ValueError("intent payload rows do not match the contract")
    result: Dict[str, str] = {}
    for line, expected in zip(lines[1:], fields):
        if line.count("\t") != 1:
            raise ValueError("intent payload row must contain one TAB")
        key, item = line.split("\t", 1)
        if key != expected or not item or "\n" in item or "\r" in item:
            raise ValueError("intent payload fields or order do not match the contract")
        result[key] = item
    return result


def parse_json_payload(contract: str, payload: str) -> Mapping[str, Any]:
    if not payload.endswith("\n") or "\r" in payload:
        raise ValueError("JSON intent payload must be LF-terminated")
    value = json.loads(payload, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or value.get("contract_version") != contract:
        raise ValueError("JSON intent payload contract mismatch")
    return value


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"


def require_nullable(value: str, field: str) -> None:
    if value != "null":
        require_text(value, field)


def require_boolean(value: str, field: str) -> None:
    if value not in ("true", "false"):
        raise ValueError("{} must be true or false".format(field))


def validate_line_binding(request: Mapping[str, Any], fields: Mapping[str, str]) -> None:
    action = request["action_id"]
    contract = request["payload_contract"]
    revision = request["revision"]

    if contract == "workbench-task-complete-intent/v1":
        if fields["outcome"] != "completed" or fields["completion_snapshot"] != revision:
            raise ValueError("completion intent does not bind the subject revision")
    elif contract == "workbench-task-abandon-intent/v1":
        if fields["outcome"] != "abandoned" or fields["abandonment_revision"] != revision:
            raise ValueError("abandon intent does not bind the subject revision")
        require_text(fields["reason_code"], "reason_code")
        require_nullable(fields["reason_ref"], "reason_ref")
    elif contract == "workbench-deliverable-transition-intent/v1":
        if fields["record_revision"] != revision:
            raise ValueError("deliverable transition does not bind the record revision")
        if fields["transition"] != action.rsplit(".", 1)[-1]:
            raise ValueError("deliverable transition does not match the action")
        require_boolean(fields["from_required"], "from_required")
        require_boolean(fields["to_required"], "to_required")
        require_text(fields["reason_code"], "reason_code")
        require_nullable(fields["reason_ref"], "reason_ref")
        if request["target_ref"] != "workbench:deliverable/" + fields["deliverable_id"]:
            raise ValueError("deliverable target binding mismatch")
    elif contract == "workbench-deliverable-accept-intent/v1":
        if fields["record_revision"] != revision:
            raise ValueError("deliverable acceptance does not bind the record revision")
        if fields["mode"] not in ("kernel-probe", "owner-assertion"):
            raise ValueError("invalid deliverable acceptance mode")
        for key in ("deliverable_revision", "subject_authority_digest"):
            require_digest(fields[key], key)
        for key in (
            "owner_context_ref",
            "acceptance_authority_ref",
            "actor",
            "accepted_at",
        ):
            require_nullable(fields[key], key)
        if request["target_ref"] != "workbench:deliverable/" + fields["deliverable_id"]:
            raise ValueError("deliverable target binding mismatch")
    elif contract == "workbench-required-check-waive-intent/v1":
        if fields["record_revision"] != revision or fields["transition"] != "required-to-waived":
            raise ValueError("required-check intent does not bind the transition")
        require_text(fields["reason_code"], "reason_code")
        require_nullable(fields["reason_ref"], "reason_ref")
        if request["target_ref"] != "workbench:required-check/" + fields["check_id"]:
            raise ValueError("required-check target binding mismatch")
    elif contract == "workbench-harvest-disposition-intent/v1":
        if fields["record_revision"] != revision:
            raise ValueError("harvest intent does not bind the candidate revision")
        if fields["decision"] not in ("absorb", "codebase", "follow-up", "discard"):
            raise ValueError("invalid harvest disposition")
        require_nullable(fields["target_ref"], "target_ref")
        require_text(fields["reason_code"], "reason_code")
        require_nullable(fields["reason_ref"], "reason_ref")
        if request["target_ref"] != "workbench:harvest/" + fields["candidate_id"]:
            raise ValueError("harvest target binding mismatch")
    elif contract == "workbench-writer-request/v1":
        if fields["conflict_revision"] != revision:
            raise ValueError("writer request does not bind the conflict revision")
        require_digest(fields["context_policy_set_digest"], "context_policy_set_digest")
        if request["target_ref"] != "workbench:codebase/" + fields["owner"]:
            raise ValueError("writer target binding mismatch")
    elif contract == "workbench-task-cleanup-intent/v1":
        if fields["terminal_revision"] != revision:
            raise ValueError("cleanup intent does not bind the terminal revision")
        require_digest(fields["removal_plan_digest"], "removal_plan_digest")


def intent_manifest(request: Mapping[str, Any], payload_digest: str) -> bytes:
    rows = (
        "workbench-action-intent/v1",
        "action_id\t" + request["action_id"],
        "task_claim_id\t" + request["task_claim_id"],
        "target_ref\t" + request["target_ref"],
        "subject_revision\t" + request["revision"],
        "payload_contract\t" + request["payload_contract"],
        "payload_digest\t" + payload_digest,
    )
    return ("\n".join(rows) + "\n").encode("utf-8")


def load_request(file: str) -> Dict[str, Any]:
    value = strict_object(file, REQUEST_FIELDS)
    if value["contract_version"] != "workbench-action-request/v1":
        raise ValueError("unsupported action request contract")
    for key in ("action_id", "task_claim_id", "target_ref", "payload_contract"):
        require_text(value[key], key)
    require_digest(value["revision"], "revision")
    expected_payload = ACTION_PAYLOADS.get(value["action_id"])
    if expected_payload is None:
        raise ValueError("unsupported-action: {}".format(value["action_id"]))
    if value["payload_contract"] != expected_payload:
        raise ValueError("action payload contract mismatch")
    payload = value["payload"]
    if not isinstance(payload, str):
        raise ValueError("payload must be a string")
    if expected_payload in PAYLOAD_FIELDS:
        fields = parse_line_payload(expected_payload, payload)
        validate_line_binding(value, fields)
        digest_payload = payload
    else:
        digest_payload = canonical_json(parse_json_payload(expected_payload, payload))
    payload_digest = sha256(digest_payload.encode("utf-8"))
    value["payload_digest"] = payload_digest
    value["intent_digest"] = sha256(intent_manifest(value, payload_digest))
    return value


def load_authorization(file: str) -> Dict[str, Any]:
    value = strict_object(file, AUTHORIZATION_FIELDS)
    if value["contract_version"] != "workbench-authorization/v1":
        raise ValueError("unsupported authorization contract")
    for key in (
        "authorization_id",
        "action_instance_id",
        "action_id",
        "task_claim_id",
        "target_ref",
        "actor",
        "source_ref",
    ):
        require_text(value[key], key)
    if value["action_id"] not in ACTION_PAYLOADS:
        raise ValueError("unsupported-action: {}".format(value["action_id"]))
    for key in ("revision", "intent_digest", "policy_manifest_digest"):
        require_digest(value[key], key)
    if value["decision"] not in ("allow", "deny"):
        raise ValueError("authorization decision must be allow or deny")
    if not isinstance(value["authorized_at"], str) or RFC3339_UTC.fullmatch(value["authorized_at"]) is None:
        raise ValueError("authorized_at must be RFC 3339 UTC")
    return value


def write_json(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def write_shell(rows: Iterable[Tuple[str, Any]]) -> None:
    for key, value in rows:
        if not isinstance(value, str) or "\n" in value or "\r" in value:
            raise ValueError("{} cannot be serialized to shell rows".format(key))
        sys.stdout.write("{}={}\n".format(key, value))


def cmd_request(args: argparse.Namespace) -> None:
    value = load_request(args.file)
    projection = {
        "contract_version": "workbench-action-intent/v1",
        "action_id": value["action_id"],
        "task_claim_id": value["task_claim_id"],
        "target_ref": value["target_ref"],
        "subject_revision": value["revision"],
        "payload_contract": value["payload_contract"],
        "payload_digest": value["payload_digest"],
        "intent_digest": value["intent_digest"],
    }
    if args.intent_digest is not None and args.intent_digest != value["intent_digest"]:
        raise ValueError("intent-digest-mismatch")
    if args.format == "json":
        write_json(projection)
    else:
        write_shell(projection.items())


def cmd_authorization(args: argparse.Namespace) -> None:
    value = load_authorization(args.file)
    write_shell((key, value[key]) for key in AUTHORIZATION_FIELDS[1:])


def cmd_build_request(args: argparse.Namespace) -> None:
    with open(args.payload_file, "r", encoding="utf-8", newline="") as handle:
        payload = handle.read()
    value = {
        "contract_version": "workbench-action-request/v1",
        "action_id": args.action_id,
        "task_claim_id": args.task_claim_id,
        "target_ref": args.target_ref,
        "revision": args.revision,
        "payload_contract": args.payload_contract,
        "payload": payload,
    }
    # Validate through the same parser by reproducing its checks in-memory.
    expected = ACTION_PAYLOADS.get(value["action_id"])
    if expected is None:
        raise ValueError("unsupported-action: {}".format(value["action_id"]))
    if expected != value["payload_contract"]:
        raise ValueError("action payload contract mismatch")
    require_text(value["task_claim_id"], "task_claim_id")
    require_text(value["target_ref"], "target_ref")
    require_digest(value["revision"], "revision")
    if expected in PAYLOAD_FIELDS:
        validate_line_binding(value, parse_line_payload(expected, payload))
    else:
        parse_json_payload(expected, payload)
    write_json(value)


def cmd_build_payload(args: argparse.Namespace) -> None:
    fields = PAYLOAD_FIELDS.get(args.contract)
    if fields is None:
        raise ValueError("payload contract is JSON-backed or unsupported")
    supplied: Dict[str, str] = {}
    for item in args.field:
        if "=" not in item:
            raise ValueError("payload field must use key=value")
        key, value = item.split("=", 1)
        if key in supplied:
            raise ValueError("duplicate payload field: {}".format(key))
        supplied[key] = value
    if tuple(supplied) != fields:
        raise ValueError("payload fields or order do not match the contract")
    payload = args.contract + "\n" + "".join(
        "{}\t{}\n".format(key, supplied[key]) for key in fields
    )
    parse_line_payload(args.contract, payload)
    sys.stdout.write(payload)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    request = commands.add_parser("request")
    request.add_argument("file")
    request.add_argument("--intent-digest")
    request.add_argument("--format", choices=("json", "shell"), required=True)
    request.set_defaults(func=cmd_request)
    authorization = commands.add_parser("authorization")
    authorization.add_argument("file")
    authorization.set_defaults(func=cmd_authorization)
    build = commands.add_parser("build-request")
    build.add_argument("--action-id", required=True)
    build.add_argument("--task-claim-id", required=True)
    build.add_argument("--target-ref", required=True)
    build.add_argument("--revision", required=True)
    build.add_argument("--payload-contract", required=True)
    build.add_argument("--payload-file", required=True)
    build.set_defaults(func=cmd_build_request)
    payload = commands.add_parser("build-payload")
    payload.add_argument("--contract", required=True)
    payload.add_argument("--field", action="append", default=[])
    payload.set_defaults(func=cmd_build_payload)
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
