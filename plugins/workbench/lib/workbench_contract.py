#!/usr/bin/env python3
"""Strict parsing and JSON serialization for public workbench contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List


GRANDFATHERED = {
    "art-lojban",
    "cel-gaulish",
    "en-gb-oed",
    "i-ami",
    "i-bnn",
    "i-default",
    "i-enochian",
    "i-hak",
    "i-klingon",
    "i-lux",
    "i-mingo",
    "i-navajo",
    "i-pwn",
    "i-tao",
    "i-tay",
    "i-tsu",
    "no-bok",
    "no-nyn",
    "sgn-be-fr",
    "sgn-be-nl",
    "sgn-ch-de",
    "zh-guoyu",
    "zh-hakka",
    "zh-min",
    "zh-min-nan",
    "zh-xiang",
}


def is_ascii_alnum(value: str) -> bool:
    return value.isascii() and value.isalnum()


def is_language_tag(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value) > 255 or not value.isascii():
        return False
    if value.lower() in GRANDFATHERED:
        return True

    parts = value.split("-")
    if any(not part for part in parts):
        return False
    if parts[0].lower() == "x":
        return len(parts) > 1 and all(
            1 <= len(part) <= 8 and is_ascii_alnum(part) for part in parts[1:]
        )

    language = parts[0]
    if not 2 <= len(language) <= 8 or not language.isascii() or not language.isalpha():
        return False
    index = 1

    if len(language) <= 3:
        extlang_count = 0
        while (
            index < len(parts)
            and extlang_count < 3
            and len(parts[index]) == 3
            and parts[index].isascii()
            and parts[index].isalpha()
        ):
            index += 1
            extlang_count += 1

    if (
        index < len(parts)
        and len(parts[index]) == 4
        and parts[index].isascii()
        and parts[index].isalpha()
    ):
        index += 1

    if index < len(parts) and (
        (len(parts[index]) == 2 and parts[index].isascii() and parts[index].isalpha())
        or (len(parts[index]) == 3 and parts[index].isascii() and parts[index].isdigit())
    ):
        index += 1

    variants = set()
    while index < len(parts):
        part = parts[index]
        is_variant = (5 <= len(part) <= 8 and is_ascii_alnum(part)) or (
            len(part) == 4
            and part[0].isascii()
            and part[0].isdigit()
            and is_ascii_alnum(part)
        )
        if not is_variant:
            break
        normalized = part.lower()
        if normalized in variants:
            return False
        variants.add(normalized)
        index += 1

    extensions = set()
    while index < len(parts) and len(parts[index]) == 1 and parts[index].lower() != "x":
        singleton = parts[index].lower()
        if not is_ascii_alnum(singleton) or singleton in extensions:
            return False
        extensions.add(singleton)
        index += 1
        start = index
        while (
            index < len(parts)
            and 2 <= len(parts[index]) <= 8
            and is_ascii_alnum(parts[index])
        ):
            index += 1
        if index == start:
            return False

    if index < len(parts) and parts[index].lower() == "x":
        index += 1
        start = index
        while (
            index < len(parts)
            and 1 <= len(parts[index]) <= 8
            and is_ascii_alnum(parts[index])
        ):
            index += 1
        if index == start:
            return False

    return index == len(parts)


def write_json(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def unique_object(pairs: Any) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON member: {}".format(key))
        result[key] = value
    return result


def strict_json_object(file: str, expected_fields: Any) -> Dict[str, Any]:
    with open(file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or set(value) != set(expected_fields):
        raise ValueError("JSON object fields do not match the contract")
    return value


def require_contract_string(value: Dict[str, Any], key: str) -> str:
    field = value[key]
    if not isinstance(field, str) or not field or any(ord(char) < 32 for char in field):
        raise ValueError("{} must be a non-empty string without controls".format(key))
    return field


def digest_json(value: Any) -> str:
    raw = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def require_printable_ascii(value: Any, field: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or not value.isascii()
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        raise ValueError("{} must be non-empty printable ASCII".format(field))
    return value


def cmd_authority_descriptor(args: argparse.Namespace) -> None:
    fields = (
        "contract_version",
        "authority_identity",
        "origin_url",
        "default_ref",
        "workspace_home",
        "hosting_adapter",
        "hosting_ref",
    )
    with open(args.file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or tuple(value) != fields:
        raise ValueError("workspace authority fields or order do not match the contract")
    if value["contract_version"] != "workbench-workspace-authority/v1":
        raise ValueError("unsupported workspace authority contract")
    for key in ("authority_identity", "origin_url", "default_ref", "workspace_home"):
        require_printable_ascii(value[key], key)
    if re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", value["default_ref"]) is None:
        raise ValueError("default_ref must be a full branch ref")
    if (
        re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value["workspace_home"]) is None
        or value["workspace_home"].isdigit()
    ):
        raise ValueError("workspace_home does not match the canonical home grammar")
    adapter = value["hosting_adapter"]
    hosting_ref = value["hosting_ref"]
    if (adapter is None) != (hosting_ref is None):
        raise ValueError("hosting_adapter and hosting_ref must be null or present together")
    if adapter is not None:
        require_printable_ascii(adapter, "hosting_adapter")
        require_printable_ascii(hosting_ref, "hosting_ref")
    if adapter == "github" and re.fullmatch(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", value["origin_url"]
    ) is None:
        raise ValueError("GitHub origin_url must be canonical HTTPS with .git suffix")
    sys.stdout.write("descriptor_digest={}\n".format(digest_json(value)))
    for key in fields[1:]:
        field = value[key]
        sys.stdout.write("{}={}\n".format(key, "" if field is None else field))


def is_namespaced_ref(value: str) -> bool:
    return re.fullmatch(r"[a-z][a-z0-9-]*:[a-z][a-z0-9-]*/[A-Za-z0-9._-]+", value) is not None


def cmd_schema(args: argparse.Namespace) -> None:
    raw = Path(args.file).read_bytes()
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    if b"\n" in raw or raw not in (b"workbench/v1", b"workbench/v2"):
        raise ValueError("schema marker must contain exactly one supported schema ID line")
    sys.stdout.write(raw.decode("ascii") + "\n")


def cmd_validate_language(args: argparse.Namespace) -> None:
    if not is_language_tag(args.language):
        raise ValueError("profile language must be a well-formed ASCII BCP 47 tag")


def cmd_authorization(args: argparse.Namespace) -> None:
    fields = (
        "contract_version",
        "authorization_id",
        "action_instance_id",
        "action_id",
        "task_claim_id",
        "target_ref",
        "revision",
        "policy_manifest_digest",
        "decision",
        "actor",
        "authorized_at",
        "source_ref",
    )
    value = strict_json_object(args.file, fields)
    for key in fields:
        require_contract_string(value, key)
    if value["contract_version"] != "workbench-authorization/v1":
        raise ValueError("unsupported authorization contract")
    if value["decision"] not in ("allow", "deny"):
        raise ValueError("authorization decision must be allow or deny")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value["authorized_at"]):
        raise ValueError("authorized_at must be RFC 3339 UTC")
    for key in fields:
        sys.stdout.write("{}={}\n".format(key, value[key]))


RECEIPT_FIELDS = (
    "contract_version",
    "authority_identity",
    "authority_ref",
    "authority_revision",
    "policy_ref",
    "policy_digest",
    "actor",
    "issued_at",
    "source_ref",
)
PARTICIPANT_FIELDS = (
    "context_ref",
    "policy_ref",
    "policy_digest",
    "authority_ref",
    "authority_receipt",
)
TASK_POLICY_FIELDS = ("policy_ref", "policy_digest", "authority_ref", "authority_receipt")
REGISTRATION_FIELDS = (
    "contract_version",
    "registration_id",
    "task_claim_id",
    "task_context_ref",
    "participants",
    "task_policy",
    "actor",
    "registered_at",
)
RFC3339_UTC = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


def sha256_bytes(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def validate_policy_ref(workspace: Path, policy_ref: Any, field: str) -> Path:
    if (
        not isinstance(policy_ref, str)
        or not policy_ref
        or not policy_ref.isascii()
        or any(ord(char) < 32 or ord(char) == 127 for char in policy_ref)
        or "\\" in policy_ref
        or Path(policy_ref).is_absolute()
        or ".." in Path(policy_ref).parts
    ):
        raise ValueError("{} must be a safe workspace-relative path".format(field))
    resolved = (workspace / policy_ref).resolve()
    if os.path.commonpath((str(workspace), str(resolved))) != str(workspace):
        raise ValueError("{} resolves outside the workspace".format(field))
    if not resolved.is_file():
        raise ValueError("{} is unreadable".format(field))
    return resolved


def validate_authority_receipt(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict) or tuple(value) != RECEIPT_FIELDS:
        raise ValueError("authority receipt fields or order do not match the contract")
    if value["contract_version"] != "workbench-policy-authority-receipt/v1":
        raise ValueError("unsupported policy authority receipt contract")
    for key in ("authority_identity", "authority_ref", "policy_ref", "actor", "source_ref"):
        require_printable_ascii(value[key], "authority_receipt." + key)
        if "\t" in value[key]:
            raise ValueError("authority receipt fields must not contain TAB")
    revision = value["authority_revision"]
    if not isinstance(revision, str) or re.fullmatch(
        r"(?:[0-9a-f]{40}|[0-9a-f]{64}|sha256:[0-9a-f]{64})", revision
    ) is None:
        raise ValueError("invalid authority receipt revision")
    require_sha256(value["policy_digest"], "authority_receipt.policy_digest")
    if not isinstance(value["issued_at"], str) or RFC3339_UTC.fullmatch(value["issued_at"]) is None:
        raise ValueError("authority receipt issued_at must be RFC 3339 UTC")
    return value


def validate_policy_binding(
    value: Any, fields: Any, workspace: Path, expected_context: Any = None
) -> Dict[str, Any]:
    if not isinstance(value, dict) or tuple(value) != fields:
        raise ValueError("policy binding fields or order do not match the contract")
    if expected_context is not None:
        context_ref = value["context_ref"]
        if not isinstance(context_ref, str) or not is_namespaced_ref(context_ref):
            raise ValueError("participant context_ref must be a namespaced reference")
    receipt = validate_authority_receipt(value["authority_receipt"])
    for key in ("policy_ref", "policy_digest", "authority_ref"):
        if value[key] != receipt[key]:
            raise ValueError("policy binding does not match receipt: {}".format(key))
    require_sha256(value["policy_digest"], "policy_digest")
    path = validate_policy_ref(workspace, value["policy_ref"], "policy_ref")
    if sha256_bytes(path.read_bytes()) != value["policy_digest"]:
        raise ValueError("policy-source-tampered")
    return value


def load_registration(file: str, workspace_root: str) -> Dict[str, Any]:
    with open(file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or tuple(value) != REGISTRATION_FIELDS:
        raise ValueError("context registration fields or order do not match the contract")
    if value["contract_version"] != "workbench-context-policy-registration/v1":
        raise ValueError("unsupported context policy registration contract")
    for key in ("registration_id", "task_claim_id", "actor"):
        require_printable_ascii(value[key], key)
    if not isinstance(value["registered_at"], str) or RFC3339_UTC.fullmatch(value["registered_at"]) is None:
        raise ValueError("registered_at must be RFC 3339 UTC")
    context_ref = value["task_context_ref"]
    if context_ref is None:
        if (
            value["registration_id"] != "auto-null"
            or value["participants"] != []
            or value["task_policy"] is not None
            or value["actor"] != "workbench"
        ):
            raise ValueError("invalid auto-null context registration")
    else:
        if not isinstance(context_ref, str) or not is_namespaced_ref(context_ref):
            raise ValueError("owner registration requires a namespaced task_context_ref")
        if not isinstance(value["participants"], list) or not value["participants"]:
            raise ValueError("non-null context registration requires participants")

    workspace = Path(workspace_root).resolve()
    participants: List[Dict[str, Any]] = []
    seen = set()
    for participant in value["participants"]:
        validated = validate_policy_binding(participant, PARTICIPANT_FIELDS, workspace, True)
        participant_context = validated["context_ref"]
        if participant_context in seen:
            raise ValueError("duplicate participant context_ref: {}".format(participant_context))
        seen.add(participant_context)
        participants.append(validated)
    participants.sort(key=lambda item: item["context_ref"])
    task_policy = value["task_policy"]
    if task_policy is not None:
        task_policy = validate_policy_binding(task_policy, TASK_POLICY_FIELDS, workspace)
        if task_policy["policy_ref"] != "task/.workbench/policy.conf":
            raise ValueError("task policy ref must be task/.workbench/policy.conf")
    return {
        "contract_version": value["contract_version"],
        "registration_id": value["registration_id"],
        "task_claim_id": value["task_claim_id"],
        "task_context_ref": context_ref,
        "participants": participants,
        "task_policy": task_policy,
        "actor": value["actor"],
        "registered_at": value["registered_at"],
    }


def registration_rows(value: Dict[str, Any]) -> Any:
    for participant in value["participants"]:
        receipt = participant["authority_receipt"]
        yield (
            "context",
            participant["context_ref"],
            participant["policy_ref"],
            participant["policy_digest"],
            receipt["authority_identity"],
            participant["authority_ref"],
            receipt["authority_revision"],
            digest_json(receipt),
        )
    task_policy = value["task_policy"]
    if task_policy is not None:
        receipt = task_policy["authority_receipt"]
        yield (
            "task",
            "",
            task_policy["policy_ref"],
            task_policy["policy_digest"],
            receipt["authority_identity"],
            task_policy["authority_ref"],
            receipt["authority_revision"],
            digest_json(receipt),
        )


def context_set_digest(value: Dict[str, Any], registration_ref: str) -> str:
    lines = [
        "workbench-context-policy-set/v1",
        "task_claim_id\t" + value["task_claim_id"],
        "task_context_ref\t" + (value["task_context_ref"] or "null"),
        "registration_ref\t" + registration_ref,
        "registration_digest\t" + digest_json(value),
    ]
    for row in registration_rows(value):
        if row[0] == "context":
            lines.append("participant\t" + "\t".join(row[1:]))
        else:
            lines.append("task_policy\t" + "\t".join(row[2:]))
    return sha256_bytes(("\n".join(lines) + "\n").encode("utf-8"))


def cmd_registration(args: argparse.Namespace) -> None:
    value = load_registration(args.file, args.workspace_root)
    if value["task_context_ref"] is None:
        raise ValueError("null context does not accept owner registration")
    sys.stdout.write("registration_digest={}\n".format(digest_json(value)))
    for key in ("registration_id", "task_claim_id", "task_context_ref", "actor", "registered_at"):
        sys.stdout.write("{}={}\n".format(key, value[key]))
    sys.stdout.write(
        "registration_json={}\n".format(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    )


def cmd_registration_sources(args: argparse.Namespace) -> None:
    value = load_registration(args.file, args.workspace_root)
    for row in registration_rows(value):
        sys.stdout.write("\t".join(row) + "\n")


def cmd_registration_owner(args: argparse.Namespace) -> None:
    value = load_registration(args.file, args.workspace_root)
    matches = [
        participant
        for participant in value["participants"]
        if participant["context_ref"] == args.owner_context_ref
        and participant["authority_ref"] == args.acceptance_authority_ref
    ]
    if len(matches) != 1:
        raise ValueError("acceptance-authority-mismatch")
    participant = matches[0]
    receipt = participant["authority_receipt"]
    sys.stdout.write("owner_context_ref={}\n".format(participant["context_ref"]))
    sys.stdout.write("acceptance_authority_ref={}\n".format(participant["authority_ref"]))
    sys.stdout.write("authority_identity={}\n".format(receipt["authority_identity"]))
    sys.stdout.write("authority_actor={}\n".format(receipt["actor"]))


OWNER_ACCEPTANCE_FIELDS = (
    "contract_version",
    "acceptance_id",
    "deliverable_id",
    "owner",
    "kind",
    "owner_context_ref",
    "acceptance_authority_ref",
    "revision",
    "actor",
    "accepted_at",
)


def cmd_owner_acceptance(args: argparse.Namespace) -> None:
    with open(args.file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    if not isinstance(value, dict) or tuple(value) != OWNER_ACCEPTANCE_FIELDS:
        raise ValueError("owner acceptance fields or order do not match the contract")
    if value["contract_version"] != "workbench-owner-acceptance/v1":
        raise ValueError("unsupported owner acceptance contract")
    for key in ("acceptance_id", "deliverable_id", "owner", "kind", "revision", "actor"):
        require_printable_ascii(value[key], key)
    for key in ("owner_context_ref", "acceptance_authority_ref"):
        if not isinstance(value[key], str) or not is_namespaced_ref(value[key]):
            raise ValueError("{} must be a namespaced reference".format(key))
    if RFC3339_UTC.fullmatch(value["accepted_at"]) is None:
        raise ValueError("accepted_at must be RFC 3339 UTC")
    sys.stdout.write("authority_digest={}\n".format(digest_json(value)))
    for key in OWNER_ACCEPTANCE_FIELDS[1:]:
        sys.stdout.write("{}={}\n".format(key, value[key]))


def auto_null_registration(claim_id: str, at: str) -> Dict[str, Any]:
    require_printable_ascii(claim_id, "task_claim_id")
    if RFC3339_UTC.fullmatch(at) is None:
        raise ValueError("auto-null timestamp must be RFC 3339 UTC")
    return {
        "contract_version": "workbench-context-policy-registration/v1",
        "registration_id": "auto-null",
        "task_claim_id": claim_id,
        "task_context_ref": None,
        "participants": [],
        "task_policy": None,
        "actor": "workbench",
        "registered_at": at,
    }


def cmd_context_set(args: argparse.Namespace) -> None:
    if args.auto_null:
        value = auto_null_registration(args.task_claim_id, args.at)
        registration_ref = "workbench:context-registration/auto-null/" + args.task_claim_id
    else:
        value = load_registration(args.registration_file, args.workspace_root)
        registration_ref = "workbench:context-registration/" + value["registration_id"]
    projection = {
        "contract_version": "workbench-context-policy-set/v1",
        "task_contract": "workbench-task/v2",
        "task_claim_id": value["task_claim_id"],
        "task_context_ref": value["task_context_ref"],
        "sealed": args.sealed == "true",
        "changed": args.changed == "true",
        "digest": context_set_digest(value, registration_ref),
        "registration_ref": registration_ref,
        "registration_digest": digest_json(value),
        "registration_action_instance_id": args.registration_action_instance_id,
        "registration_intent_digest": args.registration_intent_digest,
        "registration_policy_manifest_digest": args.registration_policy_manifest_digest,
        "registration_authorization_ref": args.registration_authorization_ref,
        "seal_action_instance_id": args.seal_action_instance_id,
        "seal_intent_digest": args.seal_intent_digest,
        "seal_policy_manifest_digest": args.seal_policy_manifest_digest,
        "seal_authorization_ref": args.seal_authorization_ref,
        "participants": value["participants"],
        "task_policy": value["task_policy"],
    }
    if args.format == "json":
        write_json(projection)
    else:
        for key in ("digest", "registration_ref", "registration_digest"):
            sys.stdout.write("{}={}\n".format(key, projection[key]))
        sys.stdout.write(
            "registration_json={}\n".format(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
        )


def cmd_profile(args: argparse.Namespace) -> None:
    language = None if args.source == "unavailable" else args.language
    if args.source == "workspace" and not is_language_tag(language):
        raise ValueError("profile language must be a well-formed ASCII BCP 47 tag")
    write_json(
        {
            "contract_version": "workbench-profile/v1",
            "language": language,
            "source": args.source,
        }
    )


def cmd_github_probe(args: argparse.Namespace) -> None:
    subject = {
        "contract_version": "workbench-probe/github-pr-subject/v1",
        "repository": args.repository,
        "pull_request": args.pull_request,
        "external_ref": args.external_ref,
        "state": args.state,
        "head_revision": args.head_revision,
        "merge_revision": args.merge_revision,
    }
    value = {
        **subject,
        "contract_version": "workbench-probe/github-pr/v1",
        "observed_at": args.observed_at,
    }
    if args.format == "json":
        write_json(value)
    elif args.format == "digest":
        sys.stdout.write(digest_json(value) + "\n")
    elif args.format == "subject-json":
        write_json(subject)
    else:
        sys.stdout.write(digest_json(subject) + "\n")


CLEANUP_JOURNAL_FIELDS = {
    "contract_version",
    "journal_id",
    "stage",
    "task_id",
    "claim_id",
    "branch",
    "revision",
    "action_instance_id",
    "policy_manifest",
    "authorization_ref",
    "removal_plan",
    "at",
}


def require_sha256(value: Any, field: str) -> str:
    if not isinstance(value, str) or re.fullmatch(r"sha256:[0-9a-f]{64}", value) is None:
        raise ValueError("{} must be a lowercase SHA-256 digest".format(field))
    return value


def validate_policy_manifest(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"contract_version", "digest", "sources"}:
        raise ValueError("policy_manifest fields do not match the contract")
    if value["contract_version"] != "workbench-policy-manifest/v1":
        raise ValueError("unsupported policy manifest contract")
    require_sha256(value["digest"], "policy_manifest.digest")
    if not isinstance(value["sources"], list) or any(
        not isinstance(source, dict) for source in value["sources"]
    ):
        raise ValueError("policy_manifest.sources must be an array of objects")
    return value


def validate_cleanup_journal(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict) or set(value) != CLEANUP_JOURNAL_FIELDS:
        raise ValueError("cleanup journal fields do not match the contract")
    if value["contract_version"] != "workbench-task-cleanup-journal/v1":
        raise ValueError("unsupported cleanup journal contract")
    for key in ("journal_id", "task_id", "claim_id", "branch", "action_instance_id", "at"):
        require_contract_string(value, key)
    require_sha256(value["revision"], "revision")
    if value["journal_id"] != "cleanup-" + value["claim_id"]:
        raise ValueError("cleanup journal ID does not bind to its claim")
    if value["stage"] not in ("prepared", "completed"):
        raise ValueError("invalid cleanup journal stage")
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value["at"]) is None:
        raise ValueError("cleanup journal at must be RFC 3339 UTC")
    validate_policy_manifest(value["policy_manifest"])
    authorization_ref = value["authorization_ref"]
    if authorization_ref is not None and (
        not isinstance(authorization_ref, str)
        or not authorization_ref
        or any(ord(char) < 32 for char in authorization_ref)
    ):
        raise ValueError("authorization_ref must be null or a non-empty string without controls")
    plan = value["removal_plan"]
    if not isinstance(plan, dict) or set(plan) != {
        "writer_claims", "codebase_worktrees", "task_workspace", "local_branch"
    }:
        raise ValueError("cleanup removal plan fields do not match the contract")
    for key in ("writer_claims", "codebase_worktrees"):
        rows = plan[key]
        if not isinstance(rows, list) or any(
            not isinstance(row, str) or not row or any(ord(char) < 32 for char in row)
            for row in rows
        ):
            raise ValueError("cleanup removal plan {} must be an array of strings".format(key))
        if rows != sorted(set(rows)):
            raise ValueError("cleanup removal plan {} must be sorted and unique".format(key))
    if plan["task_workspace"] is not True or plan["local_branch"] is not True:
        raise ValueError("cleanup removal plan must include task workspace and local branch")
    return value


def read_cleanup_journal(file: str) -> Dict[str, Any]:
    with open(file, "r", encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    return validate_cleanup_journal(value)


def cmd_cleanup_journal_build(args: argparse.Namespace) -> None:
    resolution = strict_json_object(
        args.policy_resolution_file,
        ("contract_version", "action_instance", "decision", "authorization_ref"),
    )
    if resolution["contract_version"] != "workbench-policy/v1" or resolution["decision"] != "allow":
        raise ValueError("cleanup requires an allowed workbench-policy/v1 resolution")
    action = resolution["action_instance"]
    if not isinstance(action, dict) or set(action) != {
        "id", "action_id", "task_claim_id", "target_ref", "revision", "intent_digest",
        "policy_manifest", "status"
    }:
        raise ValueError("cleanup action instance fields do not match the contract")
    expected = {
        "id": args.action_instance_id,
        "action_id": "task.cleanup",
        "task_claim_id": args.claim_id,
        "target_ref": "workbench:task/" + args.claim_id,
        "revision": args.revision,
        "status": "authorized",
    }
    for key, expected_value in expected.items():
        if action[key] != expected_value:
            raise ValueError("cleanup action instance binding mismatch: {}".format(key))
    manifest = validate_policy_manifest(action["policy_manifest"])
    value = {
        "contract_version": "workbench-task-cleanup-journal/v1",
        "journal_id": "cleanup-" + args.claim_id,
        "stage": "prepared",
        "task_id": args.task_id,
        "claim_id": args.claim_id,
        "branch": args.branch,
        "revision": args.revision,
        "action_instance_id": args.action_instance_id,
        "policy_manifest": manifest,
        "authorization_ref": resolution["authorization_ref"],
        "removal_plan": {
            "writer_claims": sorted(set(args.writer_claim)),
            "codebase_worktrees": sorted(set(args.codebase_worktree)),
            "task_workspace": True,
            "local_branch": True,
        },
        "at": args.at,
    }
    validate_cleanup_journal(value)
    write_json(value)


def cmd_cleanup_journal_find(args: argparse.Namespace) -> int:
    text = Path(args.comments_file).read_text(encoding="utf-8")
    pattern = re.compile(r"<!-- workbench-task-cleanup:v1\r?\n([^\r\n]+)\r?\n-->")
    matches = pattern.findall(text)
    if text.count("<!-- workbench-task-cleanup:v1") != len(matches):
        raise ValueError("cleanup journal marker must contain exactly one JSON line")
    selected: List[Dict[str, Any]] = []
    for raw in matches:
        value = json.loads(raw, object_pairs_hook=unique_object)
        validate_cleanup_journal(value)
        if value["task_id"] == args.task_id and value["branch"] == args.branch:
            selected.append(value)
    if not selected:
        return 1
    immutable = {
        key: selected[0][key]
        for key in CLEANUP_JOURNAL_FIELDS
        if key not in ("stage", "at")
    }
    for value in selected[1:]:
        if any(value[key] != expected for key, expected in immutable.items()):
            raise ValueError("cleanup journal stages have conflicting bindings")
    stages = [value["stage"] for value in selected]
    if stages not in (["prepared"], ["prepared", "completed"]):
        raise ValueError("invalid cleanup journal stage sequence")
    write_json(selected[-1])
    return 0


def cmd_cleanup_journal_stage(args: argparse.Namespace) -> None:
    value = read_cleanup_journal(args.file)
    if value["stage"] != "prepared" or args.stage != "completed":
        raise ValueError("cleanup journal stage transition must be prepared to completed")
    value["stage"] = args.stage
    value["at"] = args.at
    validate_cleanup_journal(value)
    write_json(value)


def cmd_cleanup_journal_field(args: argparse.Namespace) -> None:
    value = read_cleanup_journal(args.file)
    field = value[args.field]
    if field is not None:
        sys.stdout.write(str(field) + "\n")


def cmd_cleanup_journal_list(args: argparse.Namespace) -> None:
    value = read_cleanup_journal(args.file)
    for item in value["removal_plan"][args.field]:
        sys.stdout.write(item + "\n")


WRITER_LEDGER_HEADER = "workbench-writer-claims/v1"


def validate_writer_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or any(
        ord(char) < 32 or char == "\t" for char in value
    ):
        raise ValueError("{} must be a non-empty string without controls".format(field))
    return value


def writer_row_key(row: Dict[str, str]) -> Any:
    return (row["owner"], row["claim_id"], 0 if row["state"] == "active" else 1)


def validate_writer_row(row: Dict[str, str]) -> None:
    for key in ("claim_id", "owner", "task_claim_id", "branch"):
        validate_writer_text(row[key], key)
    if re.fullmatch(r"wc_[A-Za-z0-9._-]+", row["claim_id"]) is None:
        raise ValueError("invalid writer claim ID")
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", row["owner"]) is None:
        raise ValueError("invalid writer owner")
    require_sha256(row["context_policy_set_digest"], "context_policy_set_digest")
    if row["state"] not in ("active", "released"):
        raise ValueError("invalid writer claim state")


def read_writer_ledger(file: str) -> List[Dict[str, str]]:
    raw = Path(file).read_bytes()
    if not raw.endswith(b"\n") or b"\r" in raw:
        raise ValueError("writer ledger must be LF-terminated")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise ValueError("writer ledger must be UTF-8") from exc
    if not lines or lines[0] != WRITER_LEDGER_HEADER:
        raise ValueError("unsupported writer ledger contract")
    rows: List[Dict[str, str]] = []
    for line in lines[1:]:
        parts = line.split("\t")
        if len(parts) != 7 or parts[0] != "claim":
            raise ValueError("malformed writer ledger row")
        row = {
            "claim_id": parts[1],
            "owner": parts[2],
            "task_claim_id": parts[3],
            "branch": parts[4],
            "context_policy_set_digest": parts[5],
            "state": parts[6],
        }
        validate_writer_row(row)
        rows.append(row)
    if rows != sorted(rows, key=writer_row_key):
        raise ValueError("writer ledger rows are not canonical")
    if len({tuple(row.values()) for row in rows}) != len(rows):
        raise ValueError("duplicate writer ledger row")
    by_claim: Dict[str, List[Dict[str, str]]] = {}
    for row in rows:
        by_claim.setdefault(row["claim_id"], []).append(row)
    for claim_rows in by_claim.values():
        if len(claim_rows) not in (1, 2) or claim_rows[0]["state"] != "active":
            raise ValueError("writer claim must begin with one active row")
        if len(claim_rows) == 2:
            if claim_rows[1]["state"] != "released":
                raise ValueError("writer claim second row must be released")
            for key in ("owner", "task_claim_id", "branch", "context_policy_set_digest"):
                if claim_rows[0][key] != claim_rows[1][key]:
                    raise ValueError("writer claim release binding mismatch")
    return rows


def write_writer_ledger(file: str, rows: List[Dict[str, str]]) -> None:
    rows = sorted(rows, key=writer_row_key)
    lines = [WRITER_LEDGER_HEADER]
    for row in rows:
        lines.append(
            "claim\t{claim_id}\t{owner}\t{task_claim_id}\t{branch}\t{context_policy_set_digest}\t{state}".format(
                **row
            )
        )
    Path(file).write_text("\n".join(lines) + "\n", encoding="utf-8")
    read_writer_ledger(file)


def writer_claim_state(rows: List[Dict[str, str]], claim_id: str) -> str:
    matches = [row for row in rows if row["claim_id"] == claim_id]
    if not matches:
        return "absent"
    return "released" if len(matches) == 2 else "active"


def writer_conflict_revision(owner: str, rows: List[Dict[str, str]]) -> str:
    writers = sorted(
        (row for row in rows if row["owner"] == owner and row["state"] == "active"),
        key=lambda row: (row["claim_id"], row["branch"]),
    )
    lines = ["workbench-writer-conflict/v1", "owner\t" + owner]
    for row in writers:
        lines.append(
            "writer\t{claim_id}\t{task_claim_id}\t{branch}\t{context_policy_set_digest}".format(
                **row
            )
        )
    raw = ("\n".join(lines) + "\n").encode("utf-8")
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def cmd_writer_ledger_state(args: argparse.Namespace) -> None:
    rows = read_writer_ledger(args.file)
    prospective = {
        "claim_id": args.claim_id,
        "owner": args.owner,
        "task_claim_id": args.task_claim_id,
        "branch": args.branch,
        "context_policy_set_digest": args.context_policy_set_digest,
        "state": "active",
    }
    validate_writer_row(prospective)
    matching = [row for row in rows if row["claim_id"] == args.claim_id]
    for row in matching:
        for key in ("owner", "task_claim_id", "branch", "context_policy_set_digest"):
            if row[key] != prospective[key]:
                raise ValueError("writer claim binding mismatch: {}".format(key))
    state = writer_claim_state(rows, args.claim_id)
    union = list(rows)
    if state == "absent":
        union.append(prospective)
    current = [
        row for row in union
        if row["owner"] == args.owner and row["state"] == "active"
        and not any(
            release["claim_id"] == row["claim_id"] and release["state"] == "released"
            for release in union
        )
    ]
    sys.stdout.write("claim_state={}\n".format(state))
    sys.stdout.write("conflict_revision={}\n".format(writer_conflict_revision(args.owner, current)))
    for row in sorted(current, key=lambda item: (item["claim_id"], item["branch"])):
        if row["claim_id"] == args.claim_id:
            continue
        sys.stdout.write(
            "conflict={claim_id}\t{task_claim_id}\t{branch}\t{context_policy_set_digest}\n".format(
                **row
            )
        )


def cmd_writer_ledger_append(args: argparse.Namespace) -> None:
    rows = read_writer_ledger(args.file)
    state = writer_claim_state(rows, args.claim_id)
    if args.state == "active":
        row = {
            "claim_id": args.claim_id,
            "owner": args.owner,
            "task_claim_id": args.task_claim_id,
            "branch": args.branch,
            "context_policy_set_digest": args.context_policy_set_digest,
            "state": "active",
        }
        validate_writer_row(row)
        if state == "released":
            raise ValueError("released writer claim cannot reactivate")
        if state == "active":
            existing = next(item for item in rows if item["claim_id"] == args.claim_id)
            if existing != row:
                raise ValueError("writer claim binding mismatch")
        else:
            rows.append(row)
    else:
        if state == "absent":
            raise ValueError("cannot release unknown writer claim")
        if state == "active":
            active = next(item for item in rows if item["claim_id"] == args.claim_id)
            released = dict(active)
            released["state"] = "released"
            rows.append(released)
    write_writer_ledger(args.output, rows)


def cmd_writer_ledger_claim(args: argparse.Namespace) -> int:
    rows = read_writer_ledger(args.file)
    matching = [row for row in rows if row["claim_id"] == args.claim_id]
    if not matching:
        return 1
    row = matching[0]
    for key in ("claim_id", "owner", "task_claim_id", "branch", "context_policy_set_digest"):
        sys.stdout.write("{}={}\n".format(key, row[key]))
    sys.stdout.write("state={}\n".format(writer_claim_state(rows, args.claim_id)))
    return 0


def cmd_contract(args: argparse.Namespace) -> None:
    profile = json.loads(args.profile_json)
    value: Dict[str, Any] = {
        "contract_version": "workbench-contract/v1",
        "engine": {"name": "workbench", "version": args.engine_version},
        "workspace": {
            "root": args.root,
            "schema": args.schema,
            "source": args.source,
        },
        "profile": profile,
        "supported": {
            "workspace_schemas": {
                "read": ["workbench/v1", "workbench/v2"],
                "write": ["workbench/v2"],
            },
            "task_contracts": {
                "read": ["workbench-task/v1", "workbench-task/v2"],
                "write": ["workbench-task/v2"],
            },
            "task_start_contracts": ["workbench-task-start/v2"],
            "lifecycle_markers": {
                "read": ["workbench-task-lifecycle:v1", "workbench-task-lifecycle:v2"],
                "write": ["workbench-task-lifecycle:v2"],
            },
            "profile_contracts": ["workbench-profile/v1"],
            "workspace_authority_contracts": ["workbench-workspace-authority/v1"],
            "policy_contracts": ["workbench-policy/v1"],
            "policy_manifest_contracts": ["workbench-policy-manifest/v1"],
            "engine_manifest_contracts": ["workbench-plugin-manifest/v1"],
            "policy_authority_receipt_contracts": [
                "workbench-policy-authority-receipt/v1"
            ],
            "context_policy_contracts": [
                "workbench-context-policy-registration/v1",
                "workbench-context-policy-set/v1",
            ],
            "authorization_contracts": ["workbench-authorization/v1"],
            "action_intent_contracts": [
                "workbench-action-request/v1",
                "workbench-action-intent/v1",
                "workbench-task-complete-intent/v1",
                "workbench-task-abandon-intent/v1",
                "workbench-deliverable-transition-intent/v1",
                "workbench-deliverable-accept-intent/v1",
                "workbench-required-check-waive-intent/v1",
                "workbench-harvest-disposition-intent/v1",
                "workbench-context-policy-registration/v1",
                "workbench-context-policy-set/v1",
                "workbench-writer-request/v1",
                "workbench-task-cleanup-intent/v1",
            ],
            "task_revision_contracts": [
                "workbench-task-content/v1",
                "workbench-task-revision/v1",
                "workbench-task-abandonment-revision/v1",
            ],
            "acceptance_contracts": [
                "workbench-acceptance/v1",
                "workbench-acceptances/v1",
                "workbench-deliverable-acceptance/v1",
                "workbench-owner-acceptance/v1",
            ],
            "external_probe_contracts": [
                "workbench-probe/github-pr-subject/v1",
                "workbench-probe/github-pr/v1",
            ],
            "cleanup_journal_contracts": [
                "workbench-task-removal-plan/v1",
                "workbench-task-cleanup-journal/v1",
            ],
            "doctor_contracts": ["workbench-doctor/v1"],
            "evidence_contracts": ["workbench-evidence/v1"],
            "legacy_inventory_contracts": ["workbench-legacy-inventory/v1"],
            "bootstrap_authority_approval_contracts": [
                "workbench-bootstrap-authority-approval/v1"
            ],
            "writer_claim_contracts": [
                "workbench-legacy-home-set/v1",
                "workbench-legacy-lifecycle-set/v1",
                "workbench-legacy-writer-identity/v1",
                "workbench-effect-owner-snapshot/v1",
                "workbench-writer-conflict/v1",
                "workbench-writer-claim/v1",
                "workbench-writer-claim-snapshot/v1",
                "workbench-writer-claims/v1",
                "workbench-writer-operation/v1",
                "workbench-writer-worktree-owner/v1",
                "workbench-worktree-set/v1",
                "workbench-writer-abandonment-snapshot/v1",
            ],
            "capability_pack_contracts": ["workbench-capability-pack/v1"],
            "action_ids": [
                "task.abandon",
                "task.cleanup",
                "task.complete",
                "task.concurrent-write",
                "task.deliverable.accept",
                "task.deliverable.reject",
                "task.deliverable.waive",
                "task.deliverable.weaken",
                "task.harvest.dispose",
                "task.policy-context.register",
                "task.policy-context.seal",
                "task.required-check.waive",
            ],
        },
        "capabilities": [
            "engine.manifest/v1",
            "knowledge.applicability/v1",
            "policy.authority/v1",
            "policy.authorization/v1",
            "policy.context-set/v1",
            "policy.intent/v1",
            "policy.resolve/v1",
            "profile.language/v1",
            "task.acceptance/v1",
            "task.abandonment/v1",
            "task.cleanup/v1",
            "task.completion/v1",
            "task.contract/v2",
            "task.deliverables/v1",
            "task.evidence/v1",
            "task.harvest/v1",
            "task.lifecycle/v2",
            "task.legacy-writer-projection/v1",
            "task.refs/v1",
            "task.required-checks/v1",
            "task.start/v2",
            "task.writer-claims/v1",
            "task.writer-conflicts/v1",
            "task.writer-handoff/v1",
            "task.writer-recovery/v1",
            "task.writer-reconciliation/v1",
            "workspace.authority/v1",
            "workspace.doctor/v1",
            "workspace.legacy-inventory-bootstrap/v1",
            "workspace.legacy-inventory/v1",
            "workspace.schema/v1",
        ],
    }
    write_json(value)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    schema = commands.add_parser("schema")
    schema.add_argument("file")
    schema.set_defaults(func=cmd_schema)

    language = commands.add_parser("validate-language")
    language.add_argument("language")
    language.set_defaults(func=cmd_validate_language)

    authorization = commands.add_parser("authorization")
    authorization.add_argument("file")
    authorization.set_defaults(func=cmd_authorization)

    authority = commands.add_parser("authority-descriptor")
    authority.add_argument("file")
    authority.set_defaults(func=cmd_authority_descriptor)

    registration = commands.add_parser("registration")
    registration.add_argument("file")
    registration.add_argument("--workspace-root", required=True)
    registration.set_defaults(func=cmd_registration)

    registration_sources = commands.add_parser("registration-sources")
    registration_sources.add_argument("file")
    registration_sources.add_argument("--workspace-root", required=True)
    registration_sources.set_defaults(func=cmd_registration_sources)

    registration_owner = commands.add_parser("registration-owner")
    registration_owner.add_argument("file")
    registration_owner.add_argument("--workspace-root", required=True)
    registration_owner.add_argument("--owner-context-ref", required=True)
    registration_owner.add_argument("--acceptance-authority-ref", required=True)
    registration_owner.set_defaults(func=cmd_registration_owner)

    owner_acceptance = commands.add_parser("owner-acceptance")
    owner_acceptance.add_argument("file")
    owner_acceptance.set_defaults(func=cmd_owner_acceptance)

    context_set = commands.add_parser("context-set")
    context_set.add_argument("--registration-file")
    context_set.add_argument("--workspace-root")
    context_set.add_argument("--auto-null", action="store_true")
    context_set.add_argument("--task-claim-id")
    context_set.add_argument("--at")
    context_set.add_argument("--sealed", choices=("true", "false"), required=True)
    context_set.add_argument("--changed", choices=("true", "false"), required=True)
    context_set.add_argument("--registration-action-instance-id")
    context_set.add_argument("--registration-intent-digest")
    context_set.add_argument("--registration-policy-manifest-digest")
    context_set.add_argument("--registration-authorization-ref")
    context_set.add_argument("--seal-action-instance-id")
    context_set.add_argument("--seal-intent-digest")
    context_set.add_argument("--seal-policy-manifest-digest")
    context_set.add_argument("--seal-authorization-ref")
    context_set.add_argument("--format", choices=("json", "shell"), required=True)
    context_set.set_defaults(func=cmd_context_set)

    profile = commands.add_parser("profile")
    profile.add_argument("--source", choices=("workspace", "unavailable"), required=True)
    profile.add_argument("--language")
    profile.set_defaults(func=cmd_profile)

    probe = commands.add_parser("github-probe")
    probe.add_argument("--repository", required=True)
    probe.add_argument("--pull-request", type=int, required=True)
    probe.add_argument("--external-ref", required=True)
    probe.add_argument("--state", choices=("merged",), required=True)
    probe.add_argument("--head-revision", required=True)
    probe.add_argument("--merge-revision", required=True)
    probe.add_argument("--observed-at", required=True)
    probe.add_argument(
        "--format",
        choices=("json", "digest", "subject-json", "subject-digest"),
        required=True,
    )
    probe.set_defaults(func=cmd_github_probe)

    cleanup_build = commands.add_parser("cleanup-journal-build")
    cleanup_build.add_argument("--policy-resolution-file", required=True)
    cleanup_build.add_argument("--task-id", required=True)
    cleanup_build.add_argument("--claim-id", required=True)
    cleanup_build.add_argument("--branch", required=True)
    cleanup_build.add_argument("--revision", required=True)
    cleanup_build.add_argument("--action-instance-id", required=True)
    cleanup_build.add_argument("--writer-claim", action="append", default=[])
    cleanup_build.add_argument("--codebase-worktree", action="append", default=[])
    cleanup_build.add_argument("--at", required=True)
    cleanup_build.set_defaults(func=cmd_cleanup_journal_build)

    cleanup_find = commands.add_parser("cleanup-journal-find")
    cleanup_find.add_argument("--comments-file", required=True)
    cleanup_find.add_argument("--task-id", required=True)
    cleanup_find.add_argument("--branch", required=True)
    cleanup_find.set_defaults(func=cmd_cleanup_journal_find)

    cleanup_stage = commands.add_parser("cleanup-journal-stage")
    cleanup_stage.add_argument("file")
    cleanup_stage.add_argument("--stage", choices=("completed",), required=True)
    cleanup_stage.add_argument("--at", required=True)
    cleanup_stage.set_defaults(func=cmd_cleanup_journal_stage)

    cleanup_field = commands.add_parser("cleanup-journal-field")
    cleanup_field.add_argument("file")
    cleanup_field.add_argument(
        "field",
        choices=("journal_id", "stage", "task_id", "claim_id", "branch", "revision", "action_instance_id", "authorization_ref"),
    )
    cleanup_field.set_defaults(func=cmd_cleanup_journal_field)

    cleanup_list = commands.add_parser("cleanup-journal-list")
    cleanup_list.add_argument("file")
    cleanup_list.add_argument("field", choices=("writer_claims", "codebase_worktrees"))
    cleanup_list.set_defaults(func=cmd_cleanup_journal_list)

    writer_state = commands.add_parser("writer-ledger-state")
    writer_state.add_argument("file")
    writer_state.add_argument("--claim-id", required=True)
    writer_state.add_argument("--owner", required=True)
    writer_state.add_argument("--task-claim-id", required=True)
    writer_state.add_argument("--branch", required=True)
    writer_state.add_argument("--context-policy-set-digest", required=True)
    writer_state.set_defaults(func=cmd_writer_ledger_state)

    writer_append = commands.add_parser("writer-ledger-append")
    writer_append.add_argument("file")
    writer_append.add_argument("--output", required=True)
    writer_append.add_argument("--state", choices=("active", "released"), required=True)
    writer_append.add_argument("--claim-id", required=True)
    writer_append.add_argument("--owner")
    writer_append.add_argument("--task-claim-id")
    writer_append.add_argument("--branch")
    writer_append.add_argument("--context-policy-set-digest")
    writer_append.set_defaults(func=cmd_writer_ledger_append)

    writer_claim = commands.add_parser("writer-ledger-claim")
    writer_claim.add_argument("file")
    writer_claim.add_argument("--claim-id", required=True)
    writer_claim.set_defaults(func=cmd_writer_ledger_claim)

    contract = commands.add_parser("contract")
    contract.add_argument("--root", required=True)
    contract.add_argument("--schema", choices=("workbench/v1", "workbench/v2"), required=True)
    contract.add_argument("--source", choices=("marker", "implicit"), required=True)
    contract.add_argument("--profile-json", required=True)
    contract.add_argument("--engine-version", required=True)
    contract.set_defaults(func=cmd_contract)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        result = args.func(args)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 2
    return 0 if result is None else result


if __name__ == "__main__":
    sys.exit(main())
