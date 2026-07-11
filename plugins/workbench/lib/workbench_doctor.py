#!/usr/bin/env python3
"""Strict validation and output codec for read-only workbench readiness."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any, Dict, Iterable, Tuple


OID = re.compile(r"[0-9a-f]{40}([0-9a-f]{24})?\Z")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
COORDINATION_REF = "refs/heads/workbench-coordination/writer-claims"
HOSTING_FIELDS = (
    "contract_version",
    "authority_identity",
    "origin_url",
    "default_ref",
    "default_revision",
    "default_ref_protected",
    "coordination_ref",
    "push_permission",
    "permission_source",
    "push_ready",
)


class NotReady(Exception):
    pass


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


def require_object(value: Any, fields: Tuple[str, ...], name: str) -> Dict[str, Any]:
    if not isinstance(value, dict) or tuple(value) != fields:
        raise ValueError("{} fields or order do not match the contract".format(name))
    return value


def require_text(value: Any, field: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or not value.isascii()
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise ValueError("{} must be non-empty printable ASCII".format(field))
    return value


def require_oid(value: Any, field: str) -> str:
    if not isinstance(value, str) or OID.fullmatch(value) is None:
        raise ValueError("{} must be a lowercase Git object ID".format(field))
    return value


def boolean(value: str, field: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise ValueError("{} must be true or false".format(field))


def write_json(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def cmd_hosting(args: argparse.Namespace) -> None:
    authority = load_json(args.authority_file)
    authority_fields = (
        "contract_version",
        "authority_identity",
        "origin_url",
        "default_ref",
        "workspace_home",
        "hosting_adapter",
        "hosting_ref",
    )
    require_object(authority, authority_fields, "workspace authority")
    value = require_object(load_json(args.verification_file), HOSTING_FIELDS, "hosting readiness")
    if value["contract_version"] != "workbench-hosting-readiness/v1":
        raise ValueError("unsupported hosting readiness contract")
    expected = {
        "authority_identity": authority["authority_identity"],
        "origin_url": authority["origin_url"],
        "default_ref": authority["default_ref"],
        "default_revision": args.default_revision,
        "coordination_ref": args.coordination_ref,
    }
    for key, expected_value in expected.items():
        if value[key] != expected_value:
            raise ValueError("hosting readiness {} binding mismatch".format(key))
    if not isinstance(value["default_ref_protected"], bool):
        raise ValueError("default_ref_protected must be boolean")
    if value["push_permission"] not in ("allowed", "denied", "unknown"):
        raise ValueError("invalid push_permission")
    permission_source = require_text(value["permission_source"], "permission_source")
    if authority["hosting_ref"] is not None and permission_source != authority["hosting_ref"]:
        raise ValueError("permission_source does not match hosting_ref")
    if not isinstance(value["push_ready"], bool):
        raise ValueError("push_ready must be boolean")
    if value["push_permission"] != "allowed" and value["push_ready"]:
        raise ValueError("non-allowed permission cannot be push-ready")
    rows = (
        ("default_ref_protected", str(value["default_ref_protected"]).lower()),
        ("push_permission", value["push_permission"]),
        ("permission_source", permission_source),
        ("push_ready", str(value["push_ready"]).lower()),
    )
    for key, item in rows:
        sys.stdout.write("{}={}\n".format(key, item))


def nullable_text(value: str, field: str) -> Any:
    return None if value == "" else require_text(value, field)


def nullable_oid(value: str, field: str) -> Any:
    return None if value == "" else require_oid(value, field)


def cmd_output(args: argparse.Namespace) -> None:
    authority_identity = nullable_text(args.authority_identity, "authority_identity")
    origin_url = nullable_text(args.origin_url, "origin_url")
    default_ref = nullable_text(args.default_ref, "default_ref")
    default_revision = nullable_oid(args.default_ref_revision, "default_ref_revision")
    descriptor_digest = None
    if args.descriptor_digest:
        if DIGEST.fullmatch(args.descriptor_digest) is None:
            raise ValueError("descriptor_digest must be canonical SHA-256")
        descriptor_digest = args.descriptor_digest
    coordination_revision = nullable_oid(args.coordination_revision, "coordination_revision")
    default_ref_protected = boolean(args.default_ref_protected, "default_ref_protected")
    readable = boolean(args.readable, "readable")
    legacy_readable = boolean(args.legacy_inventory_readable, "legacy_inventory_readable")
    push_ready = boolean(args.push_ready, "push_ready")
    if args.push_permission not in ("allowed", "denied", "unknown"):
        raise ValueError("invalid push_permission")
    permission_source = nullable_text(args.permission_source, "permission_source")
    if args.push_permission != "allowed" and push_ready:
        raise ValueError("non-allowed permission cannot be push-ready")
    ready = all(
        (
            authority_identity is not None,
            origin_url is not None,
            default_ref is not None,
            default_revision is not None,
            default_ref_protected,
            descriptor_digest is not None,
            readable,
            legacy_readable,
            args.push_permission == "allowed",
            permission_source is not None,
            push_ready,
        )
    )
    blocker = None
    if not ready:
        blocker = {"code": "writer-lock-unavailable", "ref": COORDINATION_REF}
    value = {
        "contract_version": "workbench-doctor/v1",
        "ready": ready,
        "writer_coordination": {
            "authority_identity": authority_identity,
            "origin_url": origin_url,
            "default_ref": default_ref,
            "default_ref_revision": default_revision,
            "default_ref_protected": default_ref_protected,
            "descriptor_digest": descriptor_digest,
            "ref": COORDINATION_REF,
            "revision": coordination_revision,
            "readable": readable,
            "legacy_inventory_readable": legacy_readable,
            "push_permission": args.push_permission,
            "permission_source": permission_source,
            "push_ready": push_ready,
            "blocker": blocker,
        },
    }
    write_json(value)
    if not ready:
        raise NotReady()


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    hosting = commands.add_parser("hosting")
    hosting.add_argument("--verification-file", required=True)
    hosting.add_argument("--authority-file", required=True)
    hosting.add_argument("--default-revision", required=True)
    hosting.add_argument("--coordination-ref", required=True)
    hosting.set_defaults(func=cmd_hosting)
    output = commands.add_parser("output")
    for field in (
        "authority_identity",
        "origin_url",
        "default_ref",
        "default_ref_revision",
        "descriptor_digest",
        "coordination_revision",
        "default_ref_protected",
        "readable",
        "legacy_inventory_readable",
        "push_permission",
        "permission_source",
        "push_ready",
    ):
        output.add_argument("--" + field.replace("_", "-"), required=True)
    output.set_defaults(func=cmd_output)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        args.func(args)
    except NotReady:
        return 1
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
