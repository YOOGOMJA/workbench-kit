#!/usr/bin/env python3
"""Pure planning reducer for governed effects that may outlive a crashed command."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from typing import Any, Dict, Mapping, Optional, Sequence

from workbench_intent import load_request


DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
ACTION_FIELDS = {
    "id",
    "action_id",
    "task_claim_id",
    "target_ref",
    "revision",
    "intent_digest",
    "policy_manifest_digest",
    "authorization_ref",
    "status",
    "consumed_provenance_digest",
}
PRIMARY_FIELDS = {
    "action_instance_id",
    "intent_digest",
    "policy_manifest_digest",
    "authorization_ref",
    "primary_digest",
}


def require_digest(value: Any, field: str) -> str:
    if not isinstance(value, str) or DIGEST.fullmatch(value) is None:
        raise ValueError("{} must be a canonical SHA-256 digest".format(field))
    return value


def blocker(ref: str) -> Dict[str, Any]:
    return {
        "decision": "blocked",
        "primary_digest": None,
        "write_secondary": False,
        "consume_action": False,
        "blocker": {"code": "action-effect-unreconciled", "ref": ref},
    }


def provenance_manifest(primary: Mapping[str, Any]) -> bytes:
    authorization = primary["authorization_ref"]
    if authorization is None:
        authorization = "null"
    rows = (
        "workbench-applied-action-provenance/v1",
        "action_instance_id\t" + primary["action_instance_id"],
        "intent_digest\t" + primary["intent_digest"],
        "policy_manifest_digest\t" + primary["policy_manifest_digest"],
        "authorization_ref\t" + authorization,
    )
    return ("\n".join(rows) + "\n").encode("utf-8")


def provenance_digest(primary: Mapping[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(provenance_manifest(primary)).hexdigest()


def validate_action(action: Mapping[str, Any], request: Mapping[str, Any]) -> None:
    if set(action) != ACTION_FIELDS:
        raise ValueError("stored action fields do not match the reducer contract")
    binding = {
        "action_id": request["action_id"],
        "task_claim_id": request["task_claim_id"],
        "target_ref": request["target_ref"],
        "revision": request["revision"],
        "intent_digest": request["intent_digest"],
    }
    for key, expected in binding.items():
        if action[key] != expected:
            raise ValueError("stored action request binding mismatch: {}".format(key))
    if not isinstance(action["id"], str) or not action["id"]:
        raise ValueError("stored action ID is invalid")
    require_digest(action["intent_digest"], "intent_digest")
    require_digest(action["policy_manifest_digest"], "policy_manifest_digest")
    if action["authorization_ref"] is not None and (
        not isinstance(action["authorization_ref"], str) or not action["authorization_ref"]
    ):
        raise ValueError("authorization_ref must be null or a non-empty string")
    if action["status"] not in ("pending", "authorized", "consumed", "denied", "superseded"):
        raise ValueError("invalid stored action status")
    consumed = action["consumed_provenance_digest"]
    if consumed is not None:
        require_digest(consumed, "consumed_provenance_digest")
    if action["status"] == "consumed" and consumed is None:
        raise ValueError("consumed action is missing frozen provenance")
    if action["status"] != "consumed" and consumed is not None:
        raise ValueError("non-consumed action cannot carry consumed provenance")


def validate_primary(primary: Mapping[str, Any], action: Mapping[str, Any]) -> None:
    if set(primary) != PRIMARY_FIELDS:
        raise ValueError("applied primary fields do not match the reducer contract")
    for key in (
        "action_instance_id",
        "intent_digest",
        "policy_manifest_digest",
        "authorization_ref",
    ):
        if primary[key] != action["id" if key == "action_instance_id" else key]:
            raise ValueError("applied provenance binding mismatch: {}".format(key))
    require_digest(primary["primary_digest"], "primary_digest")
    provenance_manifest(primary)


def reduce_applied_effect(
    action: Mapping[str, Any],
    request: Mapping[str, Any],
    primaries: Sequence[Mapping[str, Any]],
    secondary_state: str,
    mandatory_authorization: bool = False,
) -> Dict[str, Any]:
    """Return the only safe next step without performing an effect or reauthorizing."""

    validate_action(action, request)
    ref = action["id"]
    if secondary_state not in ("missing", "exact", "incompatible"):
        raise ValueError("invalid applied-effect secondary state")
    if mandatory_authorization and action["authorization_ref"] is None:
        return blocker(ref)
    if secondary_state == "incompatible" or len(primaries) > 1:
        return blocker(ref)

    if not primaries:
        if action["status"] == "consumed":
            return {
                "decision": "idempotent",
                "primary_digest": action["consumed_provenance_digest"],
                "write_secondary": False,
                "consume_action": False,
                "blocker": None,
            }
        if secondary_state != "missing":
            return blocker(ref)
        return {
            "decision": "none",
            "primary_digest": None,
            "write_secondary": False,
            "consume_action": False,
            "blocker": None,
        }

    primary = primaries[0]
    try:
        validate_primary(primary, action)
    except ValueError:
        return blocker(ref)
    primary_digest = primary["primary_digest"]
    if action["status"] in ("denied", "superseded", "pending"):
        return blocker(ref)
    if action["status"] == "consumed":
        if action["consumed_provenance_digest"] != primary_digest:
            return blocker(ref)
        return {
            "decision": "idempotent",
            "primary_digest": primary_digest,
            "write_secondary": False,
            "consume_action": False,
            "blocker": None,
        }
    return {
        "decision": "reconcile",
        "primary_digest": primary_digest,
        "write_secondary": secondary_state == "missing",
        "consume_action": True,
        "blocker": None,
    }


def read_record(file: str) -> Dict[str, str]:
    value: Dict[str, str] = {}
    with open(file, "r", encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            if not raw.endswith("\n") or "=" not in raw:
                raise ValueError("malformed record line {}".format(lineno))
            key, item = raw[:-1].split("=", 1)
            if not key or key in value or "\t" in key or "\r" in item:
                raise ValueError("invalid or duplicate record field")
            value[key] = item
    return value


def digest_file(file: str) -> str:
    with open(file, "rb") as handle:
        return "sha256:" + hashlib.sha256(handle.read()).hexdigest()


def cmd_reduce_files(args: argparse.Namespace) -> None:
    stored = read_record(args.action_file)
    request = load_request(args.request_file)
    action = {
        "id": stored.get("id", ""),
        "action_id": stored.get("action_id", ""),
        "task_claim_id": stored.get("task_claim_id", ""),
        "target_ref": stored.get("target_ref", ""),
        "revision": stored.get("revision", ""),
        "intent_digest": stored.get("intent_digest", ""),
        "policy_manifest_digest": stored.get("policy_manifest_digest", ""),
        "authorization_ref": stored.get("authorization_ref") or None,
        "status": stored.get("status", ""),
        "consumed_provenance_digest": stored.get("consumed_provenance_digest") or None,
    }
    primaries = []
    field_map = {
        "generic": (
            "action_instance_id",
            "intent_digest",
            "policy_manifest_digest",
            "authorization_ref",
        ),
        "deliverable": (
            "governance_action_instance_id",
            "governance_intent_digest",
            "governance_policy_manifest_digest",
            "authorization_ref",
        ),
        "required-check": (
            "action_instance_id",
            "intent_digest",
            "policy_manifest_digest",
            "authorization_ref",
        ),
        "context-register": (
            "registration_action_instance_id",
            "registration_intent_digest",
            "registration_policy_manifest_digest",
            "registration_authorization_ref",
        ),
        "context-seal": (
            "seal_action_instance_id",
            "seal_intent_digest",
            "seal_policy_manifest_digest",
            "seal_authorization_ref",
        ),
    }[args.primary_kind]
    for file in args.primary_file:
        record = read_record(file)
        primaries.append(
            {
                "action_instance_id": record.get(field_map[0], ""),
                "intent_digest": record.get(field_map[1], ""),
                "policy_manifest_digest": record.get(field_map[2], ""),
                "authorization_ref": record.get(field_map[3]) or None,
                "primary_digest": digest_file(file),
            }
        )
    result = reduce_applied_effect(
        action,
        request,
        primaries,
        args.secondary_state,
        mandatory_authorization=args.mandatory_authorization,
    )
    json.dump(result, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    reduce_files = commands.add_parser("reduce-files")
    reduce_files.add_argument("--action-file", required=True)
    reduce_files.add_argument("--request-file", required=True)
    reduce_files.add_argument("--primary-file", action="append", default=[])
    reduce_files.add_argument(
        "--primary-kind",
        choices=("generic", "deliverable", "required-check", "context-register", "context-seal"),
        default="generic",
    )
    reduce_files.add_argument(
        "--secondary-state", choices=("missing", "exact", "incompatible"), required=True
    )
    reduce_files.add_argument("--mandatory-authorization", action="store_true")
    reduce_files.set_defaults(func=cmd_reduce_files)
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
