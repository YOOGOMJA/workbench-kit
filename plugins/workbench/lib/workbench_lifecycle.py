#!/usr/bin/env python3
"""Strict authenticated lifecycle observation parsing."""

from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import posixpath
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, Iterable, List, Optional, Tuple

from workbench_time import require_rfc3339_utc


OBSERVATION_FIELDS = {
    "contract_version",
    "repository_origin_url",
    "issue",
    "pagination",
    "comments",
}
PAGINATION_FIELDS = {"complete", "pages_fetched", "end_cursor", "failure"}
COMMENT_FIELDS = {"author_identity", "body"}
SUBMISSION_OBSERVATION_FIELDS = {
    "contract_version",
    "repository_origin_url",
    "head_branch",
    "base_ref",
    "pagination",
    "pull_requests",
}
PULL_REQUEST_FIELDS = {
    "number",
    "url",
    "head_branch",
    "head_revision",
    "head_repository_origin_url",
    "head_is_fork",
    "base_ref",
    "state",
}
ACTIVE_OBSERVATION_FIELDS = {
    "contract_version",
    "workspace_origin_url",
    "workspace_home",
    "default_ref",
    "default_revision",
    "home_pagination",
    "pr_pagination",
    "homes",
    "pull_requests",
}
ACTIVE_HOME_FIELDS = {
    "home",
    "origin_url",
    "membership",
    "issue_pagination",
    "issues",
}
ACTIVE_ISSUE_FIELDS = {
    "number",
    "lifecycle_pagination",
    "comments",
}
SUBMISSION_RECOVERY_FIELDS = (
    "contract_version",
    "repository_origin_url",
    "default_ref",
    "branch",
    "task_id",
    "issue",
    "home",
    "parent",
    "claim_id",
    "workspace_authority_descriptor_digest",
    "snapshot_revision",
    "snapshot_index_digest",
    "cleanup_revision",
    "pull_request",
    "pull_request_url",
    "head_revision",
    "stage",
)
SUBMISSION_RECOVERY_STAGES = (
    "prepared",
    "cleanup-committed",
    "pr-observed",
    "submitted",
    "restored",
)
DELIVERABLE_RECORD_FIELDS = (
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
ACCEPTANCE_ATTEMPT_RECORD_FIELDS = (
    "acceptance_id",
    "deliverable_id",
    "owner",
    "kind",
    "external_ref",
    "revision",
    "subject_authority_digest",
    "created_at",
    "probed_at",
)
ACCEPTANCE_RECORD_FIELDS = (
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
ACTION_RECORD_FIELDS = (
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
TERMINAL_RECORD_FIELDS = (
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
RESTORED_OPERATIONAL_DIRECTORIES = {
    ".workbench/acceptance-attempts",
    ".workbench/acceptances",
    ".workbench/actions",
}
MARKER_FIELDS = {
    "task_contract",
    "event",
    "claim_id",
    "issue",
    "home",
    "branch",
    "workspace_authority_descriptor_digest",
    "pr",
    "revision",
    "action_instance_id",
    "intent_digest",
    "actor",
    "tool",
    "at",
}
MARKER_ORDER = (
    "task_contract",
    "event",
    "claim_id",
    "issue",
    "home",
    "branch",
    "workspace_authority_descriptor_digest",
    "pr",
    "revision",
    "action_instance_id",
    "intent_digest",
    "actor",
    "tool",
    "at",
)
EVENTS = {
    "task-claimed",
    "task-claim-conflict",
    "task-active",
    "task-verified",
    "task-submitted",
    "task-completed",
    "task-abandoned",
    "task-cleaned",
}
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
OID = re.compile(r"[0-9a-f]{40}([0-9a-f]{24})?\Z")
ACTION_ID = re.compile(r"act_[A-Za-z0-9][A-Za-z0-9._-]*\Z")
HOME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+){0,3}\Z")
NAMESPACED_REF = re.compile(r"[a-z][a-z0-9-]*:[a-z][a-z0-9-]*/[A-Za-z0-9._-]+\Z")
V2_MARKER = re.compile(r"<!-- workbench-task-lifecycle:v2\n([^\r\n]+)\n-->")
V1_MARKER = re.compile(r"<!-- workbench-task-lifecycle:v1 ([^\r\n]+) -->")


def unique_object(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON member: {}".format(key))
        value[key] = item
    return value


def require_fields(value: Any, fields: set[str], name: str) -> Dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("{} members do not match the contract".format(name))
    return value


def require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\t" in value or "\r" in value or "\n" in value:
        raise ValueError("{} must be a non-empty single-line string".format(field))
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("{} contains control characters".format(field))
    return value


def require_optional_text(value: Any, field: str) -> None:
    if value is not None:
        require_text(value, field)


def parse_time(value: Any) -> str:
    return require_rfc3339_utc(value, "lifecycle at")


def canonical_marker(value: Dict[str, Any]) -> Dict[str, Any]:
    return {key: value[key] for key in MARKER_ORDER}


def validate_event_shape(value: Dict[str, Any]) -> None:
    event = value["event"]
    pr = value["pr"]
    revision = value["revision"]
    action = value["action_instance_id"]
    intent = value["intent_digest"]
    if event in ("task-claimed", "task-claim-conflict", "task-active"):
        if any(item is not None for item in (pr, revision, action, intent)):
            raise ValueError("active lifecycle marker carries result fields")
    elif event == "task-verified":
        if pr is not None or revision is None or action is not None or intent is not None:
            raise ValueError("verified lifecycle marker field mismatch")
        if DIGEST.fullmatch(revision) is None:
            raise ValueError("verified lifecycle revision must be a task digest")
    elif event == "task-submitted":
        if pr is None or revision is None or action is not None or intent is not None:
            raise ValueError("submitted lifecycle marker field mismatch")
        if OID.fullmatch(revision) is None:
            raise ValueError("submitted lifecycle revision must be an exact Git OID")
    elif event in ("task-completed", "task-abandoned"):
        if revision is None or action is None or intent is None:
            raise ValueError("terminal lifecycle marker lacks provenance")
        if DIGEST.fullmatch(revision) is None:
            raise ValueError("terminal lifecycle revision must be a task digest")
    elif event == "task-cleaned":
        if pr is not None or revision is None or action is None or intent is None:
            raise ValueError("cleaned lifecycle marker field mismatch")
        if DIGEST.fullmatch(revision) is None:
            raise ValueError("cleaned lifecycle revision must be a task digest")
    if action is not None and ACTION_ID.fullmatch(action) is None:
        raise ValueError("lifecycle action instance ID is invalid")
    if intent is not None and DIGEST.fullmatch(intent) is None:
        raise ValueError("lifecycle intent digest is invalid")


def parse_v2(raw: str, author: str, issue: int) -> Dict[str, Any]:
    value = json.loads(raw, object_pairs_hook=unique_object)
    require_fields(value, MARKER_FIELDS, "v2 lifecycle marker")
    if value["task_contract"] != "workbench-task/v2":
        raise ValueError("v2 marker has the wrong task contract")
    if value["event"] not in EVENTS:
        raise ValueError("unsupported lifecycle event")
    if not isinstance(value["issue"], int) or isinstance(value["issue"], bool) or value["issue"] != issue:
        raise ValueError("lifecycle issue mismatch")
    require_text(value["claim_id"], "claim_id")
    require_text(value["branch"], "branch")
    if value["home"] is not None:
        home = require_text(value["home"], "home")
        if HOME.fullmatch(home) is None or home.isdigit():
            raise ValueError("invalid lifecycle home")
    descriptor = require_text(
        value["workspace_authority_descriptor_digest"],
        "workspace_authority_descriptor_digest",
    )
    if DIGEST.fullmatch(descriptor) is None:
        raise ValueError("invalid workspace authority descriptor digest")
    if value["pr"] is not None and (
        not isinstance(value["pr"], int) or isinstance(value["pr"], bool) or value["pr"] <= 0
    ):
        raise ValueError("lifecycle pr must be a positive integer or null")
    for field in ("revision", "action_instance_id", "intent_digest"):
        require_optional_text(value[field], field)
    actor = require_text(value["actor"], "actor")
    if actor != author:
        raise ValueError("lifecycle actor is not authenticated by the hosting observation")
    if value["tool"] != "workbench":
        raise ValueError("v2 lifecycle marker tool mismatch")
    parse_time(value["at"])
    validate_event_shape(value)
    return canonical_marker(value)


def parse_v1(raw: str, author: str, issue: int) -> Dict[str, Any]:
    fields: Dict[str, str] = {}
    for token in raw.split(" "):
        if not token or "=" not in token:
            raise ValueError("malformed v1 lifecycle token")
        key, item = token.split("=", 1)
        if key in fields:
            raise ValueError("duplicate v1 lifecycle field")
        fields[key] = item
    expected = {"event", "claim_id", "issue", "home", "branch", "pr", "actor", "tool", "at"}
    if set(fields) != expected:
        raise ValueError("v1 lifecycle fields do not match the contract")
    try:
        marker_issue = int(fields["issue"])
    except ValueError as exc:
        raise ValueError("v1 lifecycle issue is not an integer") from exc
    if marker_issue != issue or fields["event"] not in EVENTS:
        raise ValueError("v1 lifecycle identity mismatch")
    for field in ("claim_id", "branch", "actor", "tool"):
        require_text(fields[field], field)
    if fields["actor"] != author:
        raise ValueError("v1 lifecycle actor is not authenticated")
    parse_time(fields["at"])
    home = None if fields["home"] == "-" else fields["home"]
    pr = None if fields["pr"] == "-" else int(fields["pr"])
    return canonical_marker(
        {
            "task_contract": "workbench-task/v1",
            "event": fields["event"],
            "claim_id": fields["claim_id"],
            "issue": marker_issue,
            "home": home,
            "branch": fields["branch"],
            "workspace_authority_descriptor_digest": None,
            "pr": pr,
            "revision": None,
            "action_instance_id": None,
            "intent_digest": None,
            "actor": fields["actor"],
            "tool": fields["tool"],
            "at": fields["at"],
        }
    )


def parse_comment(body: str, author: str, issue: int) -> List[Dict[str, Any]]:
    if not isinstance(body, str):
        raise ValueError("lifecycle comment body must be a string")
    v2 = list(V2_MARKER.finditer(body))
    v1 = list(V1_MARKER.finditer(body))
    if body.count("<!-- workbench-task-lifecycle:v2") != len(v2):
        raise ValueError("malformed v2 lifecycle marker")
    if body.count("<!-- workbench-task-lifecycle:v1") != len(v1):
        raise ValueError("malformed v1 lifecycle marker")
    parsed: List[Tuple[int, Dict[str, Any]]] = []
    parsed.extend((match.start(), parse_v2(match.group(1), author, issue)) for match in v2)
    parsed.extend((match.start(), parse_v1(match.group(1), author, issue)) for match in v1)
    parsed.sort(key=lambda item: item[0])
    return [item for _, item in parsed]


def load_comment_observation(
    path: str, repository_origin: str, issue: int
) -> List[Dict[str, Any]]:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    require_fields(value, OBSERVATION_FIELDS, "lifecycle observation")
    if value["contract_version"] != "workbench-hosting-lifecycle-observation/v1":
        raise ValueError("unsupported lifecycle observation contract")
    if value["repository_origin_url"] != repository_origin or value["issue"] != issue:
        raise ValueError("lifecycle observation identity mismatch")
    pagination = require_fields(value["pagination"], PAGINATION_FIELDS, "lifecycle pagination")
    if (
        pagination["complete"] is not True
        or not isinstance(pagination["pages_fetched"], int)
        or isinstance(pagination["pages_fetched"], bool)
        or pagination["pages_fetched"] < 1
        or pagination["end_cursor"] is not None
        or pagination["failure"] is not None
    ):
        raise ValueError("lifecycle pagination is incomplete")
    if not isinstance(value["comments"], list):
        raise ValueError("lifecycle comments must be an array")
    result: List[Dict[str, Any]] = []
    for comment in value["comments"]:
        require_fields(comment, COMMENT_FIELDS, "lifecycle comment")
        result.append(
            {
                "author_identity": require_text(comment["author_identity"], "author_identity"),
                "body": comment["body"],
            }
        )
    return result


def load_observation(path: str, repository_origin: str, issue: int) -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []
    for comment in load_comment_observation(path, repository_origin, issue):
        result.extend(parse_comment(comment["body"], comment["author_identity"], issue))
    return result


def cmd_markers(args: argparse.Namespace) -> None:
    markers = load_observation(args.observation_file, args.repository_origin_url, args.issue)
    for marker in markers:
        sys.stdout.write(json.dumps(marker, ensure_ascii=False, separators=(",", ":")) + "\n")


def parse_index(path: str, expected_branch: str) -> Dict[str, Any]:
    raw = open(path, "rb").read()
    if not raw.endswith(b"\n") or b"\r" in raw:
        raise ValueError("task index must be LF-terminated")
    text = raw.decode("utf-8")
    rows = text.splitlines()
    if not rows or rows[0] != "---" or rows.count("---") < 2:
        raise ValueError("task index frontmatter is missing")
    closing = rows.index("---", 1)
    frontmatter: Dict[str, str] = {}
    for row in rows[1:closing]:
        if not row:
            continue
        if ":" not in row:
            raise ValueError("malformed task index frontmatter")
        key, value = row.split(":", 1)
        if key in frontmatter or value != " " + value.lstrip(" "):
            raise ValueError("duplicate or noncanonical task index field")
        frontmatter[key] = value[1:]
    required = {"id", "issue", "home", "parent", "slug", "branch", "claim_id"}
    if not required.issubset(frontmatter):
        raise ValueError("task index identity fields are incomplete")
    if not frontmatter["issue"].isdigit() or int(frontmatter["issue"]) <= 0 or not frontmatter["id"]:
        raise ValueError("task index issue identity is invalid")
    if frontmatter["parent"] and not frontmatter["parent"].isdigit():
        raise ValueError("task index parent is invalid")
    home = frontmatter["home"]
    if home and (HOME.fullmatch(home) is None or home.isdigit()):
        raise ValueError("task index home is invalid")
    slug = frontmatter["slug"]
    if SLUG.fullmatch(slug) is None:
        raise ValueError("task index slug is invalid")
    issue = frontmatter["issue"]
    parent = frontmatter["parent"]
    canonical_id = "{}#{}".format(home, issue) if home else issue
    canonical_branch = "task/{}{}{}-{}".format(
        home + "/" if home else "",
        parent + "/" if parent else "",
        issue,
        slug,
    )
    if frontmatter["id"] != canonical_id or frontmatter["branch"] != canonical_branch:
        raise ValueError("task index identity is noncanonical")
    if frontmatter["branch"] != expected_branch:
        raise ValueError("task index branch mismatch")
    require_text(frontmatter["claim_id"], "task index claim_id")
    task_contract = frontmatter.get("task_contract", "workbench-task/v1")
    if task_contract not in ("workbench-task/v1", "workbench-task/v2"):
        raise ValueError("unsupported task contract in task index")
    descriptor = frontmatter.get("workspace_authority_descriptor_digest", "")
    if task_contract == "workbench-task/v2":
        if DIGEST.fullmatch(descriptor) is None:
            raise ValueError("v2 task index descriptor digest is invalid")
    elif descriptor:
        raise ValueError("v1 task index carries a v2 descriptor digest")
    context_ref = frontmatter.get("context_ref", "")
    work_ref = frontmatter.get("work_ref", "")
    for field, item in (("context_ref", context_ref), ("work_ref", work_ref)):
        if item and NAMESPACED_REF.fullmatch(item) is None:
            raise ValueError("task index {} is invalid".format(field))
    begin = "<!-- repos:begin -->"
    end = "<!-- repos:end -->"
    if rows.count(begin) != 1 or rows.count(end) != 1 or rows.index(begin) >= rows.index(end):
        raise ValueError("task index repo block is malformed")
    repos = []
    seen = set()
    for row in rows[rows.index(begin) + 1 : rows.index(end)]:
        if not row:
            continue
        match = re.fullmatch(r"- ([A-Za-z0-9][A-Za-z0-9._-]*) \| ([^|\r\n]+) \| (work|reference)", row)
        if match is None or match.group(1) in seen:
            raise ValueError("task index repo row is malformed or duplicate")
        seen.add(match.group(1))
        repos.append({"owner": match.group(1), "branch": match.group(2), "role": match.group(3)})
    return {
        "id": frontmatter["id"],
        "issue": int(issue),
        "home": home or None,
        "parent": int(parent) if parent else None,
        "slug": slug,
        "branch": frontmatter["branch"],
        "claim_id": frontmatter["claim_id"],
        "task_contract": task_contract,
        "workspace_authority_descriptor_digest": descriptor or None,
        "context_ref": context_ref or None,
        "work_ref": work_ref or None,
        "repos": repos,
    }


def cmd_task_index(args: argparse.Namespace) -> None:
    value = parse_index(args.file, args.branch)
    if args.format == "json":
        sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
        return
    for key in (
        "id",
        "issue",
        "home",
        "parent",
        "slug",
        "branch",
        "claim_id",
        "task_contract",
        "workspace_authority_descriptor_digest",
    ):
        item = value[key]
        sys.stdout.write("{}={}\n".format(key, "" if item is None else item))


def require_complete_pagination(value: Any, name: str) -> Dict[str, Any]:
    pagination = require_fields(value, PAGINATION_FIELDS, name)
    if (
        pagination["complete"] is not True
        or not isinstance(pagination["pages_fetched"], int)
        or isinstance(pagination["pages_fetched"], bool)
        or pagination["pages_fetched"] < 1
        or pagination["end_cursor"] is not None
        or pagination["failure"] is not None
    ):
        raise ValueError("{} is incomplete".format(name))
    return pagination


def git_bytes(repository: str, *arguments: str) -> bytes:
    environment = dict(os.environ)
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    return subprocess.check_output(
        ["git", "-C", repository, *arguments],
        stderr=subprocess.DEVNULL,
        env=environment,
    )


def fetch_exact_revision(repository: str, origin: str, revision: str) -> None:
    environment = dict(os.environ)
    environment["GIT_NO_REPLACE_OBJECTS"] = "1"
    subprocess.check_call(
        [
            "git",
            "-C",
            repository,
            "fetch",
            "--no-write-fetch-head",
            "--quiet",
            "--no-tags",
            origin,
            revision,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=environment,
    )
    if git_bytes(repository, "cat-file", "-t", revision).strip() != b"commit":
        raise ValueError("active task revision is not a commit")


def advertised_branch_revision(repository: str, origin: str, branch: str) -> str:
    full_ref = "refs/heads/" + require_text(branch, "active task branch")
    rows = git_bytes(repository, "ls-remote", "--refs", origin, full_ref).splitlines()
    matches = []
    for row in rows:
        fields = row.split(b"\t")
        if len(fields) == 2 and fields[1].decode("ascii") == full_ref:
            oid = fields[0].decode("ascii")
            if OID.fullmatch(oid) is None:
                raise ValueError("active task branch advertises an invalid revision")
            matches.append(oid)
    if len(matches) != 1:
        raise ValueError("active task branch is absent or ambiguous")
    fetch_exact_revision(repository, origin, matches[0])
    return matches[0]


def commit_parents(repository: str, revision: str) -> List[str]:
    raw = git_bytes(repository, "cat-file", "-p", revision)
    header = raw.split(b"\n\n", 1)[0].splitlines()
    parents = [line[7:].decode("ascii") for line in header if line.startswith(b"parent ")]
    for parent in parents:
        if OID.fullmatch(parent) is None:
            raise ValueError("active task history contains an invalid parent")
    return parents


def parse_index_bytes(raw: bytes, branch: str) -> Dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="workbench-active-index-") as directory:
        path = os.path.join(directory, "index.md")
        with open(path, "wb") as handle:
            handle.write(raw)
        return parse_index(path, branch)


def task_index_snapshot(
    repository: str, revision: str, branch: str, historical: bool
) -> Tuple[str, Dict[str, Any]]:
    current = revision
    seen = set()
    while current not in seen:
        seen.add(current)
        try:
            raw = git_bytes(repository, "show", current + ":task/index.md")
        except subprocess.CalledProcessError:
            raw = b""
        if raw:
            return current, parse_index_bytes(raw, branch)
        if not historical:
            break
        parents = commit_parents(repository, current)
        if not parents:
            break
        current = parents[0]
    raise ValueError("active task has no canonical task/index.md snapshot")


def validate_active_pull_requests(value: Any) -> List[Dict[str, Any]]:
    if not isinstance(value, list):
        raise ValueError("active task pull requests must be an array")
    result = []
    for item in value:
        require_fields(item, PULL_REQUEST_FIELDS, "active task pull request")
        if (
            not isinstance(item["number"], int)
            or isinstance(item["number"], bool)
            or item["number"] <= 0
        ):
            raise ValueError("active task pull request number is invalid")
        for field in (
            "url",
            "head_branch",
            "head_revision",
            "head_repository_origin_url",
            "base_ref",
            "state",
        ):
            require_text(item[field], "pull_request." + field)
        if OID.fullmatch(item["head_revision"]) is None:
            raise ValueError("active task pull request revision is invalid")
        if not isinstance(item["head_is_fork"], bool):
            raise ValueError("active task pull request fork flag is invalid")
        if item["state"] not in ("open", "merged", "closed"):
            raise ValueError("active task pull request state is invalid")
        result.append(item)
    if result != sorted(result, key=lambda item: item["number"]):
        raise ValueError("active task pull requests are not canonically sorted")
    if len(result) != len({item["number"] for item in result}):
        raise ValueError("duplicate active task pull request")
    return result


def reduce_lifecycle_marker(
    groups: Dict[str, Dict[str, Any]], marker: Dict[str, Any]
) -> None:
    if marker["event"] == "task-claim-conflict":
        return
    branch = marker["branch"]
    identity = (
        marker["claim_id"],
        marker["workspace_authority_descriptor_digest"],
        marker["issue"],
        marker["home"],
    )
    group = groups.get(branch)
    if group is None:
        if marker["event"] != "task-claimed":
            raise ValueError("active task lifecycle does not begin with task-claimed")
        groups[branch] = {
            "branch": branch,
            "claim_id": identity[0],
            "workspace_authority_descriptor_digest": identity[1],
            "issue": identity[2],
            "home": identity[3],
            "active": True,
            "terminal": False,
            "cleaned": False,
            "submission": None,
            "phase": "claimed",
        }
        return
    if identity != (
        group["claim_id"],
        group["workspace_authority_descriptor_digest"],
        group["issue"],
        group["home"],
    ):
        raise ValueError("active task lifecycle identity is ambiguous")
    event = marker["event"]
    if event == "task-claimed":
        raise ValueError("active task lifecycle claim is duplicated")
    if event == "task-cleaned":
        if not group["terminal"] or group["cleaned"]:
            raise ValueError("active task cleanup transition is invalid")
        group["cleaned"] = True
        group["active"] = False
        group["phase"] = "cleaned"
        return
    if group["terminal"]:
        raise ValueError("active task lifecycle resumed after a terminal event")
    if event == "task-active":
        group["active"] = True
        group["submission"] = None
        group["phase"] = "active"
    elif event == "task-verified":
        if group["phase"] not in (
            "active",
            "verified",
            "submitted",
            "submitted-verified",
        ):
            raise ValueError("active task verification transition is invalid")
        group["active"] = True
        group["phase"] = (
            "submitted-verified" if group["submission"] is not None else "verified"
        )
    elif event == "task-submitted":
        if group["phase"] not in ("active", "verified"):
            raise ValueError("active task submission transition is invalid")
        group["active"] = True
        group["submission"] = {
            "number": marker["pr"],
            "revision": marker["revision"],
        }
        group["phase"] = "submitted"
    elif event in ("task-completed", "task-abandoned"):
        if group["phase"] not in (
            "active",
            "verified",
            "submitted",
            "submitted-verified",
        ):
            raise ValueError("active task terminal transition is invalid")
        if group["submission"] is None and marker["pr"] is not None:
            raise ValueError("terminal task references an absent submission")
        if group["submission"] is not None and (
            marker["pr"] != group["submission"]["number"]
        ):
            raise ValueError("terminal task does not join its current submission")
        group["terminal"] = True
        group["active"] = False
        group["terminal_event"] = event
        group["terminal_revision"] = marker["revision"]
        group["terminal_action_instance_id"] = marker["action_instance_id"]
        group["terminal_intent_digest"] = marker["intent_digest"]
        group["phase"] = "terminal"


def active_lifecycle_groups(
    issues: Any, marker_home: Optional[str]
) -> List[Dict[str, Any]]:
    if not isinstance(issues, list):
        raise ValueError("active task issues must be an array")
    if any(not isinstance(item, dict) for item in issues):
        raise ValueError("active task issue must be an object")
    if issues != sorted(issues, key=lambda item: item.get("number", -1)):
        raise ValueError("active task issues are not canonically sorted")
    if len(issues) != len({item.get("number") for item in issues}):
        raise ValueError("duplicate active task issue")
    groups: Dict[str, Dict[str, Any]] = {}
    for issue in issues:
        require_fields(issue, ACTIVE_ISSUE_FIELDS, "active task issue")
        number = issue["number"]
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            raise ValueError("active task issue number is invalid")
        require_complete_pagination(
            issue["lifecycle_pagination"], "active task lifecycle pagination"
        )
        comments = issue["comments"]
        if not isinstance(comments, list):
            raise ValueError("active task lifecycle comments must be an array")
        markers: List[Dict[str, Any]] = []
        for comment in comments:
            require_fields(comment, COMMENT_FIELDS, "active task lifecycle comment")
            author = require_text(comment["author_identity"], "author_identity")
            markers.extend(parse_comment(comment["body"], author, number))
        for marker in markers:
            if marker["task_contract"] != "workbench-task/v2":
                continue
            if marker["home"] != marker_home:
                raise ValueError("active task lifecycle home does not match its issue home")
            if marker["issue"] != number:
                raise ValueError("active task lifecycle issue does not match its issue")
            reduce_lifecycle_marker(groups, marker)
    return [group for group in groups.values() if group["active"]]


def build_active_task_inventory(
    observation_file: str,
    legacy_inventory_file: str,
    repository: str,
    workspace_origin: str,
    workspace_home: str,
    default_ref: str,
    default_revision: str,
    descriptor_digest: str,
) -> Dict[str, Any]:
    if OID.fullmatch(default_revision) is None:
        raise ValueError("active task default revision is invalid")
    if re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", default_ref) is None:
        raise ValueError("active task default ref is invalid")
    default_branch = default_ref[len("refs/heads/") :]
    if DIGEST.fullmatch(descriptor_digest) is None:
        raise ValueError("active task descriptor digest is invalid")
    with open(legacy_inventory_file, encoding="utf-8") as handle:
        legacy = json.load(handle, object_pairs_hook=unique_object)
    expected_legacy = {
        "contract_version",
        "source_revision",
        "authority",
        "home_set",
        "homes",
        "active_claims",
        "origin_replacements",
        "complete",
        "blockers",
    }
    require_fields(legacy, expected_legacy, "active task legacy inventory")
    if (
        legacy["contract_version"] != "workbench-legacy-inventory/v1"
        or legacy["source_revision"] != default_revision
        or legacy["complete"] is not True
        or legacy["blockers"] != []
    ):
        raise ValueError("active task closed-home inventory is incomplete")
    authority = legacy["authority"]
    if (
        not isinstance(authority, dict)
        or authority.get("descriptor_digest") != descriptor_digest
        or authority.get("default_revision") != default_revision
        or authority.get("default_ref") != default_ref
    ):
        raise ValueError("active task authority does not join the closed-home inventory")
    legacy_homes = []
    for home in legacy["homes"]:
        if not isinstance(home, dict) or set(home) != {
            "home", "origin_url", "membership", "pagination", "claims"
        }:
            raise ValueError("active task legacy home fields are invalid")
        require_complete_pagination(home["pagination"], "active task legacy home pagination")
        legacy_homes.append((home["home"], home["origin_url"], home["membership"]))
    if legacy_homes != sorted(legacy_homes):
        raise ValueError("active task legacy homes are not canonically sorted")

    with open(observation_file, encoding="utf-8") as handle:
        observation = json.load(handle, object_pairs_hook=unique_object)
    require_fields(observation, ACTIVE_OBSERVATION_FIELDS, "active task observation")
    if (
        observation["contract_version"]
        != "workbench-hosting-active-task-observation/v1"
        or observation["workspace_origin_url"] != workspace_origin
        or observation["workspace_home"] != workspace_home
        or observation["default_ref"] != default_branch
        or observation["default_revision"] != default_revision
    ):
        raise ValueError("active task observation identity mismatch")
    require_complete_pagination(observation["home_pagination"], "active task home pagination")
    require_complete_pagination(observation["pr_pagination"], "active task PR pagination")
    pull_requests = validate_active_pull_requests(observation["pull_requests"])
    homes = observation["homes"]
    if not isinstance(homes, list):
        raise ValueError("active task homes must be an array")
    if any(not isinstance(item, dict) for item in homes):
        raise ValueError("active task home must be an object")
    if homes != sorted(homes, key=lambda item: item.get("home", "")):
        raise ValueError("active task homes are not canonically sorted")
    observed_homes = []
    active_groups: List[Tuple[Optional[str], Dict[str, Any]]] = []
    for home in homes:
        require_fields(home, ACTIVE_HOME_FIELDS, "active task home")
        name = require_text(home["home"], "active task home")
        origin = require_text(home["origin_url"], "active task home origin")
        membership = require_text(home["membership"], "active task home membership")
        observed_homes.append((name, origin, membership))
        require_complete_pagination(home["issue_pagination"], "active task issue pagination")
        marker_home = None if name == workspace_home else name
        active_groups.extend(
            (marker_home, group)
            for group in active_lifecycle_groups(home["issues"], marker_home)
        )
    if observed_homes != legacy_homes:
        raise ValueError("active task observation does not cover the exact closed home set")

    tasks = []
    seen_claims = set()
    seen_branches = set()
    for home, group in active_groups:
        if group["workspace_authority_descriptor_digest"] != descriptor_digest:
            raise ValueError("active task lifecycle descriptor is stale or mismatched")
        branch = group["branch"]
        submission = group["submission"]
        pull_request = None
        if submission is None:
            source_revision = advertised_branch_revision(
                repository, workspace_origin, branch
            )
            index_revision, index = task_index_snapshot(
                repository, source_revision, branch, False
            )
            source_kind = "branch"
        else:
            matches = [
                item
                for item in pull_requests
                if item["number"] == submission["number"]
                and item["head_branch"] == branch
                and item["head_revision"] == submission["revision"]
            ]
            if len(matches) != 1:
                raise ValueError("active submitted task PR mapping is absent or ambiguous")
            item = matches[0]
            if (
                item["head_repository_origin_url"] != workspace_origin
                or item["head_is_fork"] is not False
                or item["base_ref"] != default_branch
                or item["state"] not in ("open", "merged")
            ):
                raise ValueError("active submitted task PR is not current and canonical")
            source_revision = item["head_revision"]
            fetch_exact_revision(repository, workspace_origin, source_revision)
            index_revision, index = task_index_snapshot(
                repository, source_revision, branch, True
            )
            source_kind = "submitted-pr"
            pull_request = item["number"]
        if (
            index["task_contract"] != "workbench-task/v2"
            or index["home"] != home
            or index["issue"] != group["issue"]
            or index["branch"] != branch
            or index["claim_id"] != group["claim_id"]
            or index["workspace_authority_descriptor_digest"] != descriptor_digest
        ):
            raise ValueError("active task index does not join its lifecycle identity")
        if group["claim_id"] in seen_claims or branch in seen_branches:
            raise ValueError("active task claim or branch identity is duplicated")
        seen_claims.add(group["claim_id"])
        seen_branches.add(branch)
        tasks.append(
            {
                "home": home,
                "issue": group["issue"],
                "branch": branch,
                "claim_id": group["claim_id"],
                "workspace_authority_descriptor_digest": descriptor_digest,
                "work_ref": index["work_ref"],
                "source_kind": source_kind,
                "source_revision": source_revision,
                "index_revision": index_revision,
                "pull_request": pull_request,
            }
        )
    tasks.sort(key=lambda item: (item["branch"], item["claim_id"]))
    return {
        "contract_version": "workbench-active-task-inventory/v1",
        "source_revision": default_revision,
        "descriptor_digest": descriptor_digest,
        "workspace_origin_url": workspace_origin,
        "tasks": tasks,
        "complete": True,
        "blockers": [],
    }


def cmd_active_inventory(args: argparse.Namespace) -> None:
    value = build_active_task_inventory(
        args.observation_file,
        args.legacy_inventory_file,
        args.repository,
        args.workspace_origin_url,
        args.workspace_home,
        args.default_ref,
        args.default_revision,
        args.descriptor_digest,
    )
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")


def submission_recovery_name(branch: str) -> str:
    require_text(branch, "submission recovery branch")
    return "submission-recovery-{}.json".format(
        hashlib.sha256(branch.encode("utf-8")).hexdigest()
    )


def submission_common_dir(repository: str) -> str:
    return git_bytes(
        repository, "rev-parse", "--path-format=absolute", "--git-common-dir"
    ).decode("utf-8").strip()


def secure_directory_flags() -> int:
    try:
        return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    except AttributeError as exc:
        raise ValueError("secure submission recovery directories are unavailable") from exc


def secure_file_flags(access: int) -> int:
    try:
        return access | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    except AttributeError as exc:
        raise ValueError("secure submission recovery files are unavailable") from exc


def validate_recovery_inode(value: os.stat_result, kind: str) -> None:
    if not stat.S_ISREG(value.st_mode):
        raise ValueError("submission recovery {} is not a regular file".format(kind))
    if value.st_nlink != 1:
        raise ValueError("submission recovery {} must have exactly one link".format(kind))
    if value.st_uid != os.geteuid() or value.st_mode & 0o022:
        raise ValueError("submission recovery {} ownership or mode is unsafe".format(kind))


def open_submission_directory(repository: str, create: bool) -> Optional[int]:
    common_path = submission_common_dir(repository)
    common = os.open(common_path, secure_directory_flags())
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
    value = os.fstat(directory)
    if not stat.S_ISDIR(value.st_mode):
        os.close(directory)
        raise ValueError("submission recovery parent is not a directory")
    if value.st_uid != os.geteuid() or value.st_mode & 0o022:
        os.close(directory)
        raise ValueError("submission recovery parent ownership or mode is unsafe")
    if created:
        os.fchmod(directory, 0o700)
        os.fsync(directory)
    return directory


def open_submission_lock(directory: int, branch: str) -> int:
    name = submission_recovery_name(branch) + ".lock"
    flags = secure_file_flags(os.O_RDWR)
    descriptor = -1
    for _ in range(8):
        try:
            descriptor = os.open(
                name, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory
            )
            break
        except FileExistsError:
            try:
                descriptor = os.open(name, flags, dir_fd=directory)
                break
            except FileNotFoundError:
                continue
    if descriptor < 0:
        raise OSError("submission recovery lock could not be opened")
    try:
        validate_recovery_inode(os.fstat(descriptor), "lock")
        os.fchmod(descriptor, 0o600)
    except Exception:
        os.close(descriptor)
        raise
    deadline = time.monotonic() + 5.0
    while True:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return descriptor
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(descriptor)
                raise TimeoutError("submission recovery lock timed out")
            time.sleep(0.01)


def validate_submission_recovery(value: Any) -> Dict[str, Any]:
    require_fields(value, set(SUBMISSION_RECOVERY_FIELDS), "submission recovery")
    if list(value) != list(SUBMISSION_RECOVERY_FIELDS):
        raise ValueError("submission recovery members are not canonically ordered")
    if value["contract_version"] != "workbench-submission-recovery/v1":
        raise ValueError("unsupported submission recovery contract")
    for field in ("repository_origin_url", "branch", "task_id", "claim_id"):
        require_text(value[field], "submission recovery " + field)
    if re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", value["default_ref"]) is None:
        raise ValueError("submission recovery default ref is invalid")
    if not value["branch"].startswith("task/"):
        raise ValueError("submission recovery branch is invalid")
    if (
        not isinstance(value["issue"], int)
        or isinstance(value["issue"], bool)
        or value["issue"] <= 0
    ):
        raise ValueError("submission recovery issue is invalid")
    if value["home"] is not None:
        require_text(value["home"], "submission recovery home")
    if value["parent"] is not None and (
        not isinstance(value["parent"], int)
        or isinstance(value["parent"], bool)
        or value["parent"] <= 0
    ):
        raise ValueError("submission recovery parent is invalid")
    if DIGEST.fullmatch(value["workspace_authority_descriptor_digest"]) is None:
        raise ValueError("submission recovery descriptor digest is invalid")
    if OID.fullmatch(value["snapshot_revision"]) is None:
        raise ValueError("submission recovery snapshot revision is invalid")
    if DIGEST.fullmatch(value["snapshot_index_digest"]) is None:
        raise ValueError("submission recovery index digest is invalid")
    if value["stage"] not in SUBMISSION_RECOVERY_STAGES:
        raise ValueError("submission recovery stage is invalid")
    stage = SUBMISSION_RECOVERY_STAGES.index(value["stage"])
    if stage == 0:
        if any(
            value[field] is not None
            for field in (
                "cleanup_revision",
                "pull_request",
                "pull_request_url",
                "head_revision",
            )
        ):
            raise ValueError("prepared submission recovery carries later state")
        return value
    if OID.fullmatch(value["cleanup_revision"] or "") is None:
        raise ValueError("submission recovery cleanup revision is invalid")
    if stage == 1:
        if any(
            value[field] is not None
            for field in ("pull_request", "pull_request_url", "head_revision")
        ):
            raise ValueError("cleanup submission recovery carries PR state")
        return value
    if (
        not isinstance(value["pull_request"], int)
        or isinstance(value["pull_request"], bool)
        or value["pull_request"] <= 0
    ):
        raise ValueError("submission recovery pull request is invalid")
    require_text(value["pull_request_url"], "submission recovery pull request URL")
    if OID.fullmatch(value["head_revision"] or "") is None:
        raise ValueError("submission recovery head revision is invalid")
    if value["head_revision"] != value["cleanup_revision"]:
        raise ValueError("submission recovery PR head does not join cleanup")
    return value


def read_submission_recovery_at(
    directory: int, branch: str
) -> Optional[Dict[str, Any]]:
    name = submission_recovery_name(branch)
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return None
    validate_recovery_inode(before, "record")
    descriptor = os.open(name, secure_file_flags(os.O_RDONLY), dir_fd=directory)
    try:
        after = os.fstat(descriptor)
        validate_recovery_inode(after, "record")
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError("submission recovery record changed while opening")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            raw = handle.read(65537)
    finally:
        os.close(descriptor)
    if len(raw) > 65536:
        raise ValueError("submission recovery record is too large")
    value = json.loads(raw, object_pairs_hook=unique_object)
    validate_submission_recovery(value)
    canonical = (
        json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if raw != canonical:
        raise ValueError("submission recovery record is not canonical")
    return value


def write_submission_recovery_at(
    directory: int, branch: str, value: Dict[str, Any]
) -> None:
    validate_submission_recovery(value)
    payload = (
        json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    temporary = ".submission-recovery-tmp-{}".format(secrets.token_hex(16))
    descriptor = os.open(
        temporary,
        secure_file_flags(os.O_WRONLY) | os.O_CREAT | os.O_EXCL,
        0o600,
        dir_fd=directory,
    )
    try:
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("short submission recovery write")
            offset += written
        os.fsync(descriptor)
        opened = os.fstat(descriptor)
        validate_recovery_inode(opened, "temporary file")
        named = os.stat(temporary, dir_fd=directory, follow_symlinks=False)
        validate_recovery_inode(named, "temporary file")
        if (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino):
            raise ValueError("submission recovery temporary path changed")
        os.replace(
            temporary,
            submission_recovery_name(branch),
            src_dir_fd=directory,
            dst_dir_fd=directory,
        )
        installed = os.stat(
            submission_recovery_name(branch),
            dir_fd=directory,
            follow_symlinks=False,
        )
        validate_recovery_inode(installed, "record")
        if (opened.st_dev, opened.st_ino) != (installed.st_dev, installed.st_ino):
            raise ValueError("submission recovery replacement was not exact")
        os.fsync(directory)
    finally:
        os.close(descriptor)


def submission_snapshot_index(
    repository: str, revision: str, branch: str
) -> Tuple[bytes, Dict[str, Any], str]:
    if OID.fullmatch(revision) is None:
        raise ValueError("submission snapshot revision is invalid")
    if git_bytes(repository, "cat-file", "-t", revision).strip() != b"commit":
        raise ValueError("submission snapshot is not a commit")
    raw = git_bytes(repository, "show", revision + ":task/index.md")
    index = parse_index_bytes(raw, branch)
    digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    return raw, index, digest


def validate_recovery_snapshot(repository: str, value: Dict[str, Any]) -> bytes:
    raw, index, digest = submission_snapshot_index(
        repository, value["snapshot_revision"], value["branch"]
    )
    expected = {
        "id": value["task_id"],
        "issue": value["issue"],
        "home": value["home"],
        "parent": value["parent"],
        "branch": value["branch"],
        "claim_id": value["claim_id"],
        "task_contract": "workbench-task/v2",
        "workspace_authority_descriptor_digest": value[
            "workspace_authority_descriptor_digest"
        ],
    }
    for field, expected_value in expected.items():
        if index[field] != expected_value:
            raise ValueError("submission snapshot index identity mismatch")
    if digest != value["snapshot_index_digest"]:
        raise ValueError("submission snapshot index digest mismatch")
    return raw


def validate_cleanup_revision(
    repository: str, value: Dict[str, Any], cleanup_revision: str
) -> None:
    if OID.fullmatch(cleanup_revision) is None:
        raise ValueError("submission cleanup revision is invalid")
    if commit_parents(repository, cleanup_revision) != [value["snapshot_revision"]]:
        raise ValueError("submission cleanup is not the exact snapshot child")
    raw_paths = git_bytes(
        repository,
        "diff",
        "--name-only",
        "-z",
        "--no-renames",
        value["snapshot_revision"],
        cleanup_revision,
        "--",
    )
    paths = [path for path in raw_paths.split(b"\0") if path]
    if not paths or any(not path.startswith(b"task/") for path in paths):
        raise ValueError("submission cleanup changed non-task content")
    if git_bytes(
        repository, "ls-tree", "-r", "--name-only", cleanup_revision, "--", "task"
    ).strip():
        raise ValueError("submission cleanup retains tracked task state")


def validate_recovery_authority(repository: str, value: Dict[str, Any]) -> None:
    origin = git_bytes(repository, "remote", "get-url", "origin").decode("utf-8").strip()
    if origin != value["repository_origin_url"]:
        raise ValueError("submission recovery origin mismatch")
    remote = git_bytes(repository, "ls-remote", "--symref", origin, "HEAD").splitlines()
    refs = [
        row.split()[1].decode("ascii")
        for row in remote
        if len(row.split()) == 3 and row.split()[0] == b"ref:" and row.split()[2] == b"HEAD"
    ]
    revisions = [
        row.split()[0].decode("ascii")
        for row in remote
        if len(row.split()) == 2 and row.split()[1] == b"HEAD"
    ]
    if refs != [value["default_ref"]] or len(revisions) != 1 or OID.fullmatch(revisions[0]) is None:
        raise ValueError("submission recovery default authority mismatch")
    fetch_exact_revision(repository, origin, revisions[0])
    raw = git_bytes(
        repository, "show", revisions[0] + ":.workbench/authority.json"
    )
    descriptor = json.loads(raw, object_pairs_hook=unique_object)
    expected_fields = {
        "contract_version",
        "authority_identity",
        "origin_url",
        "default_ref",
        "workspace_home",
        "hosting_adapter",
        "hosting_ref",
    }
    require_fields(descriptor, expected_fields, "submission recovery authority")
    if (
        descriptor["contract_version"] != "workbench-workspace-authority/v1"
        or descriptor["origin_url"] != origin
        or descriptor["default_ref"] != value["default_ref"]
    ):
        raise ValueError("submission recovery authority descriptor mismatch")
    canonical = (
        json.dumps(descriptor, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")
    digest = "sha256:" + hashlib.sha256(canonical).hexdigest()
    if digest != value["workspace_authority_descriptor_digest"]:
        raise ValueError("submission recovery authority digest mismatch")


def validate_recovery_worktree(
    repository: str, value: Dict[str, Any], allow_snapshot_head: bool = False
) -> None:
    branch = git_bytes(repository, "symbolic-ref", "--quiet", "--short", "HEAD").decode(
        "utf-8"
    ).strip()
    if branch != value["branch"]:
        raise ValueError("submission recovery is bound to another worktree branch")
    head = git_bytes(repository, "rev-parse", "HEAD").decode("ascii").strip()
    allowed_heads = set()
    if value["cleanup_revision"] is not None:
        allowed_heads.add(value["cleanup_revision"])
    if allow_snapshot_head:
        allowed_heads.add(value["snapshot_revision"])
    if head not in allowed_heads:
        raise ValueError("submission recovery worktree head mismatch")
    validate_recovery_authority(repository, value)


def print_submission_recovery_shell(value: Dict[str, Any]) -> None:
    for field in SUBMISSION_RECOVERY_FIELDS:
        item = value[field]
        sys.stdout.write("{}={}\n".format(field, "" if item is None else item))


def cmd_submission_recovery_prepare(args: argparse.Namespace) -> None:
    origin = require_text(args.repository_origin_url, "submission repository origin")
    if re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", args.default_ref) is None:
        raise ValueError("submission default ref is invalid")
    raw, index, digest = submission_snapshot_index(
        args.repository, args.snapshot_revision, args.branch
    )
    del raw
    if index["task_contract"] != "workbench-task/v2":
        raise ValueError("submission recovery requires a v2 task snapshot")
    value = dict(
        zip(
            SUBMISSION_RECOVERY_FIELDS,
            (
                "workbench-submission-recovery/v1",
                origin,
                args.default_ref,
                args.branch,
                index["id"],
                index["issue"],
                index["home"],
                index["parent"],
                index["claim_id"],
                index["workspace_authority_descriptor_digest"],
                args.snapshot_revision,
                digest,
                None,
                None,
                None,
                None,
                "prepared",
            ),
        )
    )
    directory = open_submission_directory(args.repository, True)
    if directory is None:
        raise ValueError("submission recovery directory is unavailable")
    lock = -1
    try:
        lock = open_submission_lock(directory, args.branch)
        current = read_submission_recovery_at(directory, args.branch)
        if current is None:
            head = git_bytes(args.repository, "rev-parse", "HEAD").decode(
                "ascii"
            ).strip()
            if head != value["snapshot_revision"]:
                validate_cleanup_revision(args.repository, value, head)
                value["cleanup_revision"] = head
                value["stage"] = "cleanup-committed"
            validate_recovery_worktree(args.repository, value, True)
            write_submission_recovery_at(directory, args.branch, value)
            current = value
        else:
            for field in SUBMISSION_RECOVERY_FIELDS[:12]:
                if current[field] != value[field]:
                    raise ValueError("submission recovery identity is immutable")
            validate_recovery_snapshot(args.repository, current)
        validate_recovery_worktree(args.repository, current, True)
        print_submission_recovery_shell(current)
    finally:
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def cmd_submission_recovery_advance(args: argparse.Namespace) -> None:
    if args.stage == "prepared":
        raise ValueError("submission recovery cannot advance to prepared")
    directory = open_submission_directory(args.repository, False)
    if directory is None:
        raise ValueError("submission recovery record is unavailable")
    lock = -1
    try:
        lock = open_submission_lock(directory, args.branch)
        value = read_submission_recovery_at(directory, args.branch)
        if value is None:
            raise ValueError("submission recovery record is unavailable")
        validate_recovery_snapshot(args.repository, value)
        current_stage = SUBMISSION_RECOVERY_STAGES.index(value["stage"])
        requested_stage = SUBMISSION_RECOVERY_STAGES.index(args.stage)
        supplied = {
            "cleanup_revision": args.cleanup_revision,
            "pull_request": args.pull_request,
            "pull_request_url": args.pull_request_url,
            "head_revision": args.head_revision,
        }
        if requested_stage <= current_stage:
            for field, item in supplied.items():
                if item is not None and value[field] != item:
                    raise ValueError("submission recovery retry identity mismatch")
            validate_recovery_worktree(args.repository, value, True)
            print_submission_recovery_shell(value)
            return
        if requested_stage != current_stage + 1:
            raise ValueError("submission recovery stage transition is invalid")
        if args.stage == "cleanup-committed":
            if any(
                item is not None
                for field, item in supplied.items()
                if field != "cleanup_revision"
            ):
                raise ValueError("cleanup recovery transition carries PR state")
            if args.cleanup_revision is None:
                raise ValueError("cleanup recovery transition lacks a revision")
            validate_cleanup_revision(args.repository, value, args.cleanup_revision)
            value["cleanup_revision"] = args.cleanup_revision
        elif args.stage == "pr-observed":
            if (
                args.cleanup_revision is not None
                and args.cleanup_revision != value["cleanup_revision"]
            ):
                raise ValueError("submission recovery cleanup identity changed")
            if (
                args.pull_request is None
                or args.pull_request_url is None
                or args.head_revision is None
            ):
                raise ValueError("submission recovery PR transition is incomplete")
            if args.head_revision != value["cleanup_revision"]:
                raise ValueError("submission recovery PR head mismatch")
            value["pull_request"] = args.pull_request
            value["pull_request_url"] = args.pull_request_url
            value["head_revision"] = args.head_revision
        elif any(item is not None for item in supplied.values()):
            raise ValueError("submission recovery state transition carries identity fields")
        value["stage"] = args.stage
        validate_recovery_worktree(args.repository, value, True)
        write_submission_recovery_at(directory, args.branch, value)
        print_submission_recovery_shell(value)
    finally:
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def cmd_submission_recovery_validate(args: argparse.Namespace) -> None:
    directory = open_submission_directory(args.repository, False)
    if directory is None:
        raise ValueError("submission recovery record is unavailable")
    lock = -1
    try:
        lock = open_submission_lock(directory, args.branch)
        value = read_submission_recovery_at(directory, args.branch)
        if value is None or value["stage"] == "prepared":
            raise ValueError("submission recovery is not cleanup-bound")
        if (
            value["repository_origin_url"] != args.repository_origin_url
            or value["default_ref"] != args.default_ref
            or value["branch"] != args.branch
            or value["cleanup_revision"] != args.current_head
        ):
            raise ValueError("submission recovery authority identity mismatch")
        raw = validate_recovery_snapshot(args.repository, value)
        validate_cleanup_revision(
            args.repository, value, value["cleanup_revision"]
        )
        validate_recovery_worktree(args.repository, value)
        current = git_bytes(args.repository, "rev-parse", "HEAD").decode("ascii").strip()
        if current != args.current_head:
            raise ValueError("submission recovery current head changed")
        if args.index_file is not None:
            with open(args.index_file, "rb") as handle:
                if handle.read() != raw:
                    raise ValueError("restored task index does not match its snapshot")
            validate_restored_submission_state(args.repository, directory, value)
        print_submission_recovery_shell(value)
    finally:
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def rename_noreplace(
    source_directory: int,
    source: str,
    target_directory: int,
    target: str,
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    source_raw = os.fsencode(source)
    target_raw = os.fsencode(target)
    if hasattr(libc, "renameatx_np"):
        operation = libc.renameatx_np
        operation.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        operation.restype = ctypes.c_int
        result = operation(
            source_directory,
            source_raw,
            target_directory,
            target_raw,
            0x00000004,
        )
    elif hasattr(libc, "renameat2"):
        operation = libc.renameat2
        operation.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        operation.restype = ctypes.c_int
        result = operation(
            source_directory,
            source_raw,
            target_directory,
            target_raw,
            1,
        )
    else:
        raise ValueError("atomic no-replace rename is unavailable")
    if result != 0:
        error = ctypes.get_errno()
        if error in (errno.EEXIST, errno.ENOTEMPTY):
            raise FileExistsError(error, os.strerror(error), target)
        raise OSError(error, os.strerror(error), target)


def validate_owned_directory(descriptor: int, kind: str) -> None:
    value = os.fstat(descriptor)
    if not stat.S_ISDIR(value.st_mode):
        raise ValueError("submission recovery {} is not a directory".format(kind))
    if value.st_uid != os.geteuid() or value.st_mode & 0o022:
        raise ValueError(
            "submission recovery {} ownership or mode is unsafe".format(kind)
        )


def validate_exact_task_directory(descriptor: int, kind: str) -> None:
    validate_owned_directory(descriptor, kind)
    if stat.S_IMODE(os.fstat(descriptor).st_mode) != 0o700:
        raise ValueError("submission recovery {} mode is not 0700".format(kind))


def open_child_directory(parent: int, name: str, create: bool) -> int:
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        raise ValueError("submission recovery directory component is invalid")
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
            os.fsync(parent)
        except FileExistsError:
            pass
    descriptor = os.open(name, secure_directory_flags(), dir_fd=parent)
    validate_exact_task_directory(descriptor, "snapshot directory")
    return descriptor


def snapshot_task_entries(
    repository: str, revision: str
) -> Dict[str, Tuple[str, bytes]]:
    raw = git_bytes(
        repository,
        "ls-tree",
        "-rz",
        "--full-tree",
        revision,
        "--",
        "task",
    )
    result: Dict[str, Tuple[str, bytes]] = {}
    for row in raw.split(b"\0"):
        if not row:
            continue
        metadata, path_raw = row.split(b"\t", 1)
        mode_raw, kind, oid_raw = metadata.split(b" ", 2)
        mode = mode_raw.decode("ascii")
        oid = oid_raw.decode("ascii")
        path = path_raw.decode("utf-8")
        if (
            kind != b"blob"
            or mode not in ("100644", "100755", "120000")
            or not path.startswith("task/")
        ):
            raise ValueError("submission snapshot task tree is unsupported")
        relative = path[len("task/") :]
        parts = relative.split("/")
        if (
            not relative
            or any(part in ("", ".", "..") for part in parts)
            or any(
                any(ord(character) < 32 or ord(character) == 127 for character in part)
                for part in parts
            )
            or relative in result
        ):
            raise ValueError("submission snapshot task path is invalid")
        blob = git_bytes(repository, "cat-file", "blob", oid)
        if mode == "120000":
            if b"\0" in blob or b"\n" in blob or not blob:
                raise ValueError("submission snapshot symlink target is invalid")
            target = blob.decode("utf-8")
            if posixpath.isabs(target):
                raise ValueError("submission snapshot symlink target is absolute")
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(relative), target)
            )
            if resolved == ".." or resolved.startswith("../"):
                raise ValueError("submission snapshot symlink escapes task state")
        result[relative] = (mode, blob)
    if "index.md" not in result:
        raise ValueError("submission snapshot task tree lacks index.md")
    return result


def ensure_relative_parent(root: int, parts: List[str]) -> int:
    current = os.dup(root)
    try:
        for part in parts:
            following = open_child_directory(current, part, True)
            os.close(current)
            current = following
        return current
    except Exception:
        os.close(current)
        raise


def materialize_task_tree(
    root: int, temporary: str, entries: Dict[str, Tuple[str, bytes]]
) -> None:
    os.mkdir(temporary, 0o700, dir_fd=root)
    os.fsync(root)
    task = os.open(temporary, secure_directory_flags(), dir_fd=root)
    validate_exact_task_directory(task, "temporary task tree")
    try:
        for relative in sorted(entries):
            mode, blob = entries[relative]
            parts = relative.split("/")
            parent = ensure_relative_parent(task, parts[:-1])
            try:
                name = parts[-1]
                if mode == "120000":
                    os.symlink(blob.decode("utf-8"), name, dir_fd=parent)
                else:
                    descriptor = os.open(
                        name,
                        secure_file_flags(os.O_WRONLY) | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=parent,
                    )
                    try:
                        offset = 0
                        while offset < len(blob):
                            written = os.write(descriptor, blob[offset:])
                            if written <= 0:
                                raise OSError("short submission snapshot write")
                            offset += written
                        os.fchmod(descriptor, 0o755 if mode == "100755" else 0o644)
                        os.fsync(descriptor)
                        validate_recovery_inode(
                            os.fstat(descriptor), "restored task file"
                        )
                    finally:
                        os.close(descriptor)
                os.fsync(parent)
            finally:
                os.close(parent)
        os.fsync(task)
    finally:
        os.close(task)


def validate_materialized_task(
    root: int, name: str, entries: Dict[str, Tuple[str, bytes]]
) -> None:
    task = os.open(name, secure_directory_flags(), dir_fd=root)
    validate_exact_task_directory(task, "restored task tree")
    observed_files = set()
    observed_directories = set()

    def walk(directory: int, prefix: str) -> None:
        for child in os.listdir(directory):
            if child in (".", ".."):
                raise ValueError("restored task tree contains an invalid entry")
            relative = child if not prefix else prefix + "/" + child
            value = os.stat(child, dir_fd=directory, follow_symlinks=False)
            if stat.S_ISDIR(value.st_mode):
                observed_directories.add(relative)
                nested = os.open(child, secure_directory_flags(), dir_fd=directory)
                validate_exact_task_directory(nested, "restored task directory")
                try:
                    walk(nested, relative)
                finally:
                    os.close(nested)
                continue
            if relative not in entries:
                raise ValueError("restored task tree contains foreign content")
            mode, blob = entries[relative]
            if mode == "120000":
                if not stat.S_ISLNK(value.st_mode):
                    raise ValueError("restored task symlink type mismatch")
                if os.fsencode(os.readlink(child, dir_fd=directory)) != blob:
                    raise ValueError("restored task symlink target mismatch")
            else:
                validate_recovery_inode(value, "restored task file")
                expected_mode = 0o755 if mode == "100755" else 0o644
                if stat.S_IMODE(value.st_mode) != expected_mode:
                    raise ValueError("restored task file mode mismatch")
                descriptor = os.open(
                    child, secure_file_flags(os.O_RDONLY), dir_fd=directory
                )
                try:
                    with os.fdopen(descriptor, "rb", closefd=False) as handle:
                        if handle.read(len(blob) + 1) != blob:
                            raise ValueError("restored task file content mismatch")
                finally:
                    os.close(descriptor)
            observed_files.add(relative)

    try:
        walk(task, "")
    finally:
        os.close(task)
    expected_directories = {
        "/".join(relative.split("/")[:index])
        for relative in entries
        for index in range(1, len(relative.split("/")))
    }
    if observed_files != set(entries) or observed_directories != expected_directories:
        raise ValueError("restored task tree is not the exact snapshot")


def parse_submission_record(
    raw: bytes, fields: Tuple[str, ...], kind: str
) -> Dict[str, str]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError("restored {} is not UTF-8".format(kind)) from exc
    value: Dict[str, str] = {}
    order: List[str] = []
    for line in text.splitlines(keepends=True):
        if not line.endswith("\n") or line.endswith("\r\n") or "=" not in line:
            raise ValueError("restored {} is malformed".format(kind))
        key, item = line[:-1].split("=", 1)
        if not key or key in value or "\r" in item or "\n" in item:
            raise ValueError("restored {} has invalid fields".format(kind))
        value[key] = item
        order.append(key)
    if tuple(order) != fields:
        raise ValueError("restored {} fields are not exact".format(kind))
    return value


def read_restored_task_entries(
    repository: str,
) -> Tuple[Dict[str, Tuple[str, bytes]], Dict[str, int], Optional[os.stat_result]]:
    root = os.open(os.path.abspath(repository), secure_directory_flags())
    task = -1
    entries: Dict[str, Tuple[str, bytes]] = {}
    directories: Dict[str, int] = {}
    codebases: Optional[os.stat_result] = None

    def require_same_inode(
        before: os.stat_result, opened: os.stat_result, after: os.stat_result, kind: str
    ) -> None:
        identity = (before.st_dev, before.st_ino)
        if identity != (opened.st_dev, opened.st_ino) or identity != (
            after.st_dev,
            after.st_ino,
        ):
            raise ValueError("restored task {} changed while opening".format(kind))

    def walk(directory: int, prefix: str) -> None:
        nonlocal codebases
        children = sorted(os.listdir(directory))
        for child in children:
            relative = child if not prefix else prefix + "/" + child
            value = os.stat(child, dir_fd=directory, follow_symlinks=False)
            if relative == "codebases":
                nested = os.open(child, secure_directory_flags(), dir_fd=directory)
                try:
                    opened = os.fstat(nested)
                    validate_parked_directory(opened)
                    after = os.stat(child, dir_fd=directory, follow_symlinks=False)
                    require_same_inode(value, opened, after, "codebases directory")
                    codebases = opened
                finally:
                    os.close(nested)
                continue
            if stat.S_ISDIR(value.st_mode):
                nested = os.open(child, secure_directory_flags(), dir_fd=directory)
                try:
                    opened = os.fstat(nested)
                    validate_owned_directory(nested, "restored task directory")
                    after = os.stat(child, dir_fd=directory, follow_symlinks=False)
                    require_same_inode(value, opened, after, "directory")
                    mode = stat.S_IMODE(opened.st_mode)
                    if mode != 0o700:
                        raise ValueError("restored task directory mode is not 0700")
                    directories[relative] = mode
                    walk(nested, relative)
                    final = os.stat(child, dir_fd=directory, follow_symlinks=False)
                    require_same_inode(value, os.fstat(nested), final, "directory")
                finally:
                    os.close(nested)
                continue
            if stat.S_ISLNK(value.st_mode):
                target = os.fsencode(os.readlink(child, dir_fd=directory))
                after = os.stat(child, dir_fd=directory, follow_symlinks=False)
                if (value.st_dev, value.st_ino) != (after.st_dev, after.st_ino):
                    raise ValueError("restored task symlink changed while reading")
                entries[relative] = (
                    "120000",
                    target,
                )
                continue
            validate_recovery_inode(value, "restored task file")
            mode = stat.S_IMODE(value.st_mode)
            if mode not in (0o600, 0o644, 0o755):
                raise ValueError("restored task file mode is unsafe")
            descriptor = os.open(
                child, secure_file_flags(os.O_RDONLY), dir_fd=directory
            )
            try:
                opened = os.fstat(descriptor)
                validate_recovery_inode(opened, "restored task file")
                if (opened.st_dev, opened.st_ino) != (value.st_dev, value.st_ino):
                    raise ValueError("restored task file changed while opening")
                with os.fdopen(descriptor, "rb", closefd=False) as handle:
                    raw = handle.read()
                after = os.stat(child, dir_fd=directory, follow_symlinks=False)
                require_same_inode(value, opened, after, "file")
            finally:
                os.close(descriptor)
            modes = {0o600: "100600", 0o644: "100644", 0o755: "100755"}
            entries[relative] = (modes[mode], raw)
        if sorted(os.listdir(directory)) != children:
            raise ValueError("restored task directory changed while reading")

    try:
        task_before = os.stat("task", dir_fd=root, follow_symlinks=False)
        task = os.open("task", secure_directory_flags(), dir_fd=root)
        task_opened = os.fstat(task)
        validate_exact_task_directory(task, "restored task tree")
        task_after = os.stat("task", dir_fd=root, follow_symlinks=False)
        require_same_inode(task_before, task_opened, task_after, "root")
        walk(task, "")
        task_final = os.stat("task", dir_fd=root, follow_symlinks=False)
        require_same_inode(task_before, os.fstat(task), task_final, "root")
        return entries, directories, codebases
    finally:
        if task >= 0:
            os.close(task)
        os.close(root)


def validate_submitted_increment(
    snapshot: bytes, current: bytes, value: Dict[str, Any]
) -> Dict[str, str]:
    expected = parse_submission_record(
        snapshot, DELIVERABLE_RECORD_FIELDS, "snapshot deliverable"
    )
    observed = parse_submission_record(
        current, DELIVERABLE_RECORD_FIELDS, "restored deliverable"
    )
    if expected["kind"] != "workbench-increment":
        raise ValueError("restored mutable deliverable kind is invalid")
    if current == snapshot:
        return expected
    if (
        expected["state"] != "declared"
        or expected["external_ref"]
        or expected["revision"]
        or expected["acceptance_ref"]
    ):
        raise ValueError("submission snapshot increment is not bindable")
    for field in DELIVERABLE_RECORD_FIELDS:
        if field in ("external_ref", "revision", "state", "acceptance_ref"):
            continue
        if observed[field] != expected[field]:
            raise ValueError("restored increment diverges from its snapshot")
    if (
        observed["external_ref"] != value["pull_request_url"]
        or observed["revision"] != value["head_revision"]
        or observed["state"] not in ("submitted", "accepted")
    ):
        raise ValueError("restored increment does not join submission recovery")
    if observed["state"] == "submitted" and observed["acceptance_ref"]:
        raise ValueError("submitted increment carries an acceptance")
    if observed["state"] == "accepted" and re.fullmatch(
        r"workbench:acceptance/[A-Za-z0-9][A-Za-z0-9._-]*",
        observed["acceptance_ref"],
    ) is None:
        raise ValueError("accepted increment lacks an exact acceptance reference")
    return observed


def parse_restored_action_request(raw: bytes) -> Dict[str, Any]:
    from workbench_intent import load_request

    descriptor, path = tempfile.mkstemp(prefix="workbench-restored-action-")
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw)
        return load_request(path)
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def validate_restored_acceptance_files(
    current: Dict[str, Tuple[str, bytes]],
    extras: set,
    increment: Optional[Dict[str, str]],
    value: Dict[str, Any],
) -> None:
    attempt_paths = sorted(
        path for path in extras if path.startswith(".workbench/acceptance-attempts/")
    )
    receipt_paths = sorted(
        path for path in extras if path.startswith(".workbench/acceptances/")
    )
    if increment is None:
        if attempt_paths or receipt_paths:
            raise ValueError("restored task has acceptance state without an increment")
        return
    deliverable_id = increment["deliverable_id"]
    attempt_path = ".workbench/acceptance-attempts/{}.record".format(deliverable_id)
    if attempt_paths not in ([], [attempt_path]) or len(receipt_paths) > 1:
        raise ValueError("restored acceptance membership is not exact")
    attempt = None
    if attempt_paths:
        mode, raw = current[attempt_path]
        if mode != "100600":
            raise ValueError("restored acceptance attempt mode is not 0600")
        attempt = parse_submission_record(
            raw, ACCEPTANCE_ATTEMPT_RECORD_FIELDS, "acceptance attempt"
        )
        expected = {
            "deliverable_id": deliverable_id,
            "owner": increment["owner"],
            "kind": increment["kind"],
            "external_ref": value["pull_request_url"],
            "revision": value["head_revision"],
        }
        if any(attempt[field] != item for field, item in expected.items()):
            raise ValueError("restored acceptance attempt is not submission-bound")
        require_rfc3339_utc(attempt["created_at"], "acceptance attempt created_at")
        if attempt["probed_at"]:
            require_rfc3339_utc(attempt["probed_at"], "acceptance attempt probed_at")
        if (
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", attempt["acceptance_id"])
            is None
            or bool(attempt["subject_authority_digest"]) != bool(attempt["probed_at"])
            or (
                attempt["subject_authority_digest"]
                and DIGEST.fullmatch(attempt["subject_authority_digest"]) is None
            )
        ):
            raise ValueError("restored acceptance attempt contract is invalid")
    receipt = None
    if receipt_paths:
        mode, raw = current[receipt_paths[0]]
        if mode != "100600":
            raise ValueError("restored acceptance receipt mode is not 0600")
        receipt = parse_submission_record(
            raw, ACCEPTANCE_RECORD_FIELDS, "acceptance receipt"
        )
        expected_path = ".workbench/acceptances/{}.record".format(
            receipt["acceptance_id"]
        )
        require_rfc3339_utc(receipt["accepted_at"], "acceptance receipt accepted_at")
        empty = (
            "owner_context_ref",
            "acceptance_authority_ref",
            "actor",
            "action_instance_id",
            "intent_digest",
            "policy_manifest_digest",
            "authorization_ref",
        )
        expected = {
            "deliverable_id": deliverable_id,
            "owner": increment["owner"],
            "kind": increment["kind"],
            "revision": value["head_revision"],
            "authority_type": "kernel-probe",
            "authority_contract": "workbench-probe/github-pr/v1",
            "authority_ref": value["pull_request_url"],
        }
        if (
            receipt_paths[0] != expected_path
            or any(receipt[field] != item for field, item in expected.items())
            or any(receipt[field] for field in empty)
            or DIGEST.fullmatch(receipt["authority_digest"]) is None
            or DIGEST.fullmatch(receipt["subject_authority_digest"]) is None
            or attempt is None
            or receipt["acceptance_id"] != attempt["acceptance_id"]
            or receipt["subject_authority_digest"]
            != attempt["subject_authority_digest"]
            or receipt["accepted_at"] != attempt["probed_at"]
        ):
            raise ValueError("restored acceptance receipt is not exact")
    if increment["state"] == "accepted":
        if receipt is None or increment["acceptance_ref"] != (
            "workbench:acceptance/" + receipt["acceptance_id"]
        ):
            raise ValueError("restored accepted increment is not receipt-bound")
    elif receipt is not None and attempt is None:
        raise ValueError("restored pending acceptance lacks its attempt")


def validate_restored_terminal_files(
    current: Dict[str, Tuple[str, bytes]],
    extras: set,
    value: Dict[str, Any],
    target_ref: str,
    cleanup_authority: Optional[Dict[str, str]] = None,
) -> None:
    action_records = sorted(
        path
        for path in extras
        if re.fullmatch(
            r"\.workbench/actions/[A-Za-z0-9][A-Za-z0-9._-]*\.record", path
        )
    )
    action_requests = sorted(
        path
        for path in extras
        if re.fullmatch(
            r"\.workbench/actions/[A-Za-z0-9][A-Za-z0-9._-]*\.request\.json",
            path,
        )
    )
    terminal_path = ".workbench/terminal"
    terminal_present = terminal_path in extras
    if not action_records and not action_requests and not terminal_present:
        return
    if len(action_records) != 1 or len(action_requests) != 1:
        raise ValueError("restored terminal action membership is not exact")
    action_mode, action_raw = current[action_records[0]]
    request_mode, request_raw = current[action_requests[0]]
    if action_mode != "100600" or request_mode != "100600":
        raise ValueError("restored terminal action mode is not 0600")
    action = parse_submission_record(
        action_raw, ACTION_RECORD_FIELDS, "terminal action"
    )
    action_id = action["id"]
    if (
        action_records[0] != ".workbench/actions/{}.record".format(action_id)
        or action_requests[0]
        != ".workbench/actions/{}.request.json".format(action_id)
        or action["action_id"]
        not in (
            ("task.complete", "task.abandon")
            if cleanup_authority is None
            else ("task.cleanup",)
        )
        or action["task_claim_id"] != value["claim_id"]
        or action["target_ref"] != target_ref
        or DIGEST.fullmatch(action["revision"]) is None
        or DIGEST.fullmatch(action["intent_digest"]) is None
        or DIGEST.fullmatch(action["policy_manifest_digest"]) is None
        or action["status"] not in ("pending", "authorized", "consumed")
        or (
            action["status"] == "consumed"
            and DIGEST.fullmatch(action["consumed_provenance_digest"]) is None
        )
        or (
            action["status"] != "consumed" and action["consumed_provenance_digest"]
        )
    ):
        raise ValueError("restored terminal action is not exact")
    request = parse_restored_action_request(request_raw)
    for field in ("action_id", "task_claim_id", "target_ref", "revision"):
        if request[field] != action[field]:
            raise ValueError("restored terminal request binding mismatch")
    if request["intent_digest"] != action["intent_digest"]:
        raise ValueError("restored terminal request digest mismatch")
    authorization = (
        action["authorization_id"],
        action["authorization_ref"],
        action["authorization_actor"],
        action["authorization_at"],
    )
    if all(authorization):
        require_rfc3339_utc(action["authorization_at"], "action authorization_at")
    if (
        (any(authorization) and not all(authorization))
        or (
            all(authorization)
            and (
                re.fullmatch(
                    r"auth_[A-Za-z0-9][A-Za-z0-9._-]*",
                    action["authorization_id"],
                )
                is None
            )
        )
        or (
            action["status"] == "pending"
            and (any(authorization) or action["consumed_provenance_digest"])
        )
        or (
            action["status"] == "authorized"
            and action["consumed_provenance_digest"]
        )
    ):
        raise ValueError("restored terminal action state is not closed")
    if cleanup_authority is not None:
        if terminal_present:
            raise ValueError("restored remote cleanup state contains a local terminal")
        if (
            action["revision"] != cleanup_authority["terminal_revision"]
            or request["payload_contract"]
            != "workbench-task-cleanup-intent/v1"
        ):
            raise ValueError("restored cleanup action is not terminal-bound")
        from workbench_intent import parse_line_payload

        payload = parse_line_payload(request["payload_contract"], request["payload"])
        if (
            payload["terminal_revision"]
            != cleanup_authority["terminal_revision"]
            or payload["removal_plan_digest"]
            != cleanup_authority["removal_plan_digest"]
        ):
            raise ValueError("restored cleanup request is not removal-plan-bound")
        return
    if not terminal_present:
        return
    terminal_mode, terminal_raw = current[terminal_path]
    if terminal_mode != "100600":
        raise ValueError("restored terminal record mode is not 0600")
    terminal = parse_submission_record(
        terminal_raw, TERMINAL_RECORD_FIELDS, "terminal record"
    )
    require_rfc3339_utc(terminal["at"], "terminal at")
    expected_action = {
        "completed": "task.complete",
        "abandoned": "task.abandon",
    }.get(terminal["outcome"])
    if (
        expected_action != action["action_id"]
        or terminal["action_instance_id"] != action_id
        or terminal["revision"] != action["revision"]
        or terminal["intent_digest"] != action["intent_digest"]
        or terminal["policy_manifest_digest"] != action["policy_manifest_digest"]
        or terminal["authorization_ref"] != action["authorization_ref"]
    ):
        raise ValueError("restored terminal record is not action-bound")


def validate_restored_operational_files(
    current: Dict[str, Tuple[str, bytes]],
    extras: set,
    increment: Optional[Dict[str, str]],
    value: Dict[str, Any],
    target_ref: str,
    cleanup_authority: Optional[Dict[str, str]] = None,
) -> None:
    acceptance = {
        path
        for path in extras
        if path.startswith(".workbench/acceptance-attempts/")
        or path.startswith(".workbench/acceptances/")
    }
    terminal = extras - acceptance
    if any(
        not (
            path == ".workbench/terminal"
            or re.fullmatch(
                r"\.workbench/actions/[A-Za-z0-9][A-Za-z0-9._-]*\.(?:record|request\.json)",
                path,
            )
        )
        for path in terminal
    ):
        raise ValueError("restored task contains unauthenticated content")
    validate_restored_acceptance_files(current, acceptance, increment, value)
    validate_restored_terminal_files(
        current, terminal, value, target_ref, cleanup_authority
    )


def validate_restored_submission_state(
    repository: str,
    directory: int,
    value: Dict[str, Any],
    cleanup_authority: Optional[Dict[str, str]] = None,
) -> None:
    _, snapshot_index, _ = submission_snapshot_index(
        repository, value["snapshot_revision"], value["branch"]
    )
    terminal_target_ref = snapshot_index["work_ref"] or (
        "workbench:task/" + value["claim_id"]
    )
    target_ref = (
        "workbench:task/" + value["claim_id"]
        if cleanup_authority is not None
        else terminal_target_ref
    )
    if cleanup_authority is not None and cleanup_authority["target_ref"] != target_ref:
        raise ValueError("restored cleanup target does not join the snapshot index")
    snapshot = snapshot_task_entries(repository, value["snapshot_revision"])
    current, directories, codebases = read_restored_task_entries(repository)
    snapshot_directories = {
        "/".join(relative.split("/")[:index])
        for relative in snapshot
        for index in range(1, len(relative.split("/")))
    }
    if any(relative == "codebases" or relative.startswith("codebases/") for relative in snapshot):
        raise ValueError("submission snapshot unexpectedly tracks codebases")
    missing_directories = snapshot_directories - set(directories)
    foreign_directories = (
        set(directories) - snapshot_directories - RESTORED_OPERATIONAL_DIRECTORIES
    )
    if missing_directories or foreign_directories:
        raise ValueError("restored task directories diverge from the snapshot")
    if any(mode != 0o700 for mode in directories.values()):
        raise ValueError("restored task directory mode changed")

    mutable: List[Dict[str, str]] = []
    for relative, (mode, raw) in snapshot.items():
        observed = current.get(relative)
        if observed is None:
            raise ValueError("restored task is missing snapshot content")
        if mode == "100644" and re.fullmatch(
            r"\.workbench/deliverables/[A-Za-z0-9][A-Za-z0-9._-]*\.record",
            relative,
        ):
            record = parse_submission_record(
                raw, DELIVERABLE_RECORD_FIELDS, "snapshot deliverable"
            )
            if record["kind"] == "workbench-increment":
                if observed[0] != mode:
                    raise ValueError("restored increment mode changed")
                mutable.append(validate_submitted_increment(raw, observed[1], value))
                continue
        if observed != (mode, raw):
            raise ValueError("restored task content diverges from the snapshot")
    if len(mutable) > 1:
        raise ValueError("submission snapshot has multiple workbench increments")
    extras = set(current) - set(snapshot)
    validate_restored_operational_files(
        current,
        extras,
        mutable[0] if mutable else None,
        value,
        target_ref,
        cleanup_authority,
    )

    marker = read_codebases_marker(directory, value["branch"])
    if codebases is None:
        if marker is not None:
            raise ValueError("restored task codebases marker has no directory")
    elif marker != codebases_marker_value(value, codebases):
        raise ValueError("restored task codebases are not recovery-bound")


def submission_task_staging_name(value: Dict[str, Any]) -> str:
    identity = (value["branch"] + "\0" + value["snapshot_revision"]).encode("utf-8")
    return ".submission-task-stage-{}".format(hashlib.sha256(identity).hexdigest())


def cmd_submission_recovery_restore(args: argparse.Namespace) -> None:
    directory = open_submission_directory(args.repository, False)
    if directory is None:
        raise ValueError("submission recovery record is unavailable")
    lock = -1
    root = -1
    try:
        lock = open_submission_lock(directory, args.branch)
        value = read_submission_recovery_at(directory, args.branch)
        if value is None or value["stage"] not in ("submitted", "restored"):
            raise ValueError("submission recovery is not ready to restore")
        validate_recovery_snapshot(args.repository, value)
        validate_cleanup_revision(args.repository, value, value["cleanup_revision"])
        validate_recovery_worktree(args.repository, value)
        entries = snapshot_task_entries(args.repository, value["snapshot_revision"])
        root = os.open(os.path.abspath(args.repository), secure_directory_flags())
        validate_owned_directory(root, "worktree root")
        try:
            os.stat("task", dir_fd=root, follow_symlinks=False)
            exists = True
        except FileNotFoundError:
            exists = False
        if exists:
            validate_materialized_task(root, "task", entries)
            sys.stdout.write("changed=false\n")
            return
        temporary = submission_task_staging_name(value)
        try:
            os.stat(temporary, dir_fd=directory, follow_symlinks=False)
            staged = True
        except FileNotFoundError:
            staged = False
        if not staged:
            materialize_task_tree(directory, temporary, entries)
        validate_materialized_task(directory, temporary, entries)
        if os.environ.get("WORKBENCH_TEST_FAIL_SUBMISSION_STAGE") == "restore-materialized":
            raise OSError("simulated failure after submission restore materialization")
        rename_noreplace(directory, temporary, root, "task")
        os.fsync(directory); os.fsync(root)
        validate_materialized_task(root, "task", entries)
        if os.environ.get("WORKBENCH_TEST_FAIL_SUBMISSION_STAGE") == "restore-installed":
            raise OSError("simulated failure after submission restore installation")
        sys.stdout.write("changed=true\n")
    finally:
        if root >= 0:
            os.close(root)
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def codebases_parking_name(branch: str) -> str:
    return "submission-codebases-{}".format(
        hashlib.sha256(branch.encode("utf-8")).hexdigest()
    )


CODEBASES_MARKER_FIELDS = (
    "contract_version",
    "branch",
    "claim_id",
    "snapshot_revision",
    "device",
    "inode",
)


def codebases_marker_name(branch: str) -> str:
    return codebases_parking_name(branch) + ".json"


def validate_parked_directory(value: os.stat_result) -> None:
    if not stat.S_ISDIR(value.st_mode):
        raise ValueError("parked task codebases is not a directory")
    if value.st_uid != os.geteuid() or value.st_mode & 0o022:
        raise ValueError("parked task codebases ownership or mode is unsafe")


def codebases_marker_value(
    recovery: Dict[str, Any], value: os.stat_result
) -> Dict[str, Any]:
    return dict(
        zip(
            CODEBASES_MARKER_FIELDS,
            (
                "workbench-submission-codebases/v1",
                recovery["branch"],
                recovery["claim_id"],
                recovery["snapshot_revision"],
                value.st_dev,
                value.st_ino,
            ),
        )
    )


def validate_codebases_marker(value: Any) -> Dict[str, Any]:
    require_fields(value, set(CODEBASES_MARKER_FIELDS), "submission codebases marker")
    if list(value) != list(CODEBASES_MARKER_FIELDS):
        raise ValueError("submission codebases marker is not canonically ordered")
    if value["contract_version"] != "workbench-submission-codebases/v1":
        raise ValueError("unsupported submission codebases marker")
    for field in ("branch", "claim_id"):
        require_text(value[field], "submission codebases " + field)
    if OID.fullmatch(value["snapshot_revision"]) is None:
        raise ValueError("submission codebases snapshot is invalid")
    for field in ("device", "inode"):
        if (
            not isinstance(value[field], int)
            or isinstance(value[field], bool)
            or value[field] <= 0
        ):
            raise ValueError("submission codebases inode identity is invalid")
    return value


def read_codebases_marker(directory: int, branch: str) -> Optional[Dict[str, Any]]:
    name = codebases_marker_name(branch)
    try:
        before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return None
    validate_recovery_inode(before, "codebases marker")
    descriptor = os.open(name, secure_file_flags(os.O_RDONLY), dir_fd=directory)
    try:
        after = os.fstat(descriptor)
        validate_recovery_inode(after, "codebases marker")
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ValueError("submission codebases marker changed while opening")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            raw = handle.read(8193)
    finally:
        os.close(descriptor)
    if len(raw) > 8192:
        raise ValueError("submission codebases marker is too large")
    value = json.loads(raw, object_pairs_hook=unique_object)
    validate_codebases_marker(value)
    canonical = (
        json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    if raw != canonical:
        raise ValueError("submission codebases marker is not canonical")
    return value


def write_codebases_marker(
    directory: int, branch: str, value: Dict[str, Any]
) -> None:
    validate_codebases_marker(value)
    payload = (
        json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")
    temporary = ".submission-codebases-marker-{}".format(secrets.token_hex(16))
    descriptor = os.open(
        temporary,
        secure_file_flags(os.O_WRONLY) | os.O_CREAT | os.O_EXCL,
        0o600,
        dir_fd=directory,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("short submission codebases marker write")
            offset += written
        os.fsync(descriptor)
        validate_recovery_inode(os.fstat(descriptor), "codebases marker temporary")
        rename_noreplace(
            directory, temporary, directory, codebases_marker_name(branch)
        )
        os.fsync(directory)
    finally:
        os.close(descriptor)


def cmd_submission_recovery_codebases(args: argparse.Namespace) -> None:
    directory = open_submission_directory(args.repository, True)
    if directory is None:
        raise ValueError("submission recovery directory is unavailable")
    lock = -1
    root = -1
    task = -1
    try:
        lock = open_submission_lock(directory, args.branch)
        recovery = read_submission_recovery_at(directory, args.branch)
        if recovery is None or recovery["branch"] != args.branch:
            raise ValueError("submission codebases recovery identity is unavailable")
        validate_recovery_snapshot(args.repository, recovery)
        validate_recovery_worktree(args.repository, recovery, True)
        root = os.open(os.path.abspath(args.repository), secure_directory_flags())
        validate_owned_directory(root, "worktree root")
        parking = codebases_parking_name(args.branch)
        marker = read_codebases_marker(directory, args.branch)
        parked = True
        try:
            parked_status = os.stat(parking, dir_fd=directory, follow_symlinks=False)
            validate_parked_directory(parked_status)
        except FileNotFoundError:
            parked = False
        if args.direction == "park":
            try:
                task = os.open("task", secure_directory_flags(), dir_fd=root)
                validate_owned_directory(task, "task directory")
                source = os.stat("codebases", dir_fd=task, follow_symlinks=False)
                validate_parked_directory(source)
                present = True
            except FileNotFoundError:
                present = False
            if present and parked:
                raise ValueError("task codebases parking is ambiguous")
            if present:
                expected = codebases_marker_value(recovery, source)
                if marker is None:
                    write_codebases_marker(directory, args.branch, expected)
                elif marker != expected:
                    raise ValueError("task codebases parking marker mismatch")
                rename_noreplace(task, "codebases", directory, parking)
                os.fsync(task); os.fsync(directory)
                installed = os.stat(parking, dir_fd=directory, follow_symlinks=False)
                validate_parked_directory(installed)
                if (installed.st_dev, installed.st_ino) != (source.st_dev, source.st_ino):
                    raise ValueError("task codebases parking changed inode")
                sys.stdout.write("changed=true\n")
            elif parked:
                expected = codebases_marker_value(recovery, parked_status)
                if marker != expected:
                    raise ValueError("parked task codebases marker mismatch")
                sys.stdout.write("changed=false\n")
            else:
                if marker is not None:
                    raise ValueError("task codebases marker has no directory")
                sys.stdout.write("changed=false\n")
            return
        task = os.open("task", secure_directory_flags(), dir_fd=root)
        validate_owned_directory(task, "task directory")
        try:
            target_status = os.stat("codebases", dir_fd=task, follow_symlinks=False)
            validate_parked_directory(target_status)
            target_present = True
        except FileNotFoundError:
            target_present = False
        if parked and target_present:
            raise ValueError("restored task codebases path is occupied")
        if not parked:
            if target_present:
                expected = codebases_marker_value(recovery, target_status)
                if marker != expected:
                    raise ValueError("restored task codebases marker mismatch")
            elif marker is not None:
                raise ValueError("submission codebases marker has no directory")
            sys.stdout.write("changed=false\n")
            return
        expected = codebases_marker_value(recovery, parked_status)
        if marker != expected:
            raise ValueError("parked task codebases marker mismatch")
        rename_noreplace(directory, parking, task, "codebases")
        os.fsync(directory); os.fsync(task)
        installed = os.stat("codebases", dir_fd=task, follow_symlinks=False)
        validate_parked_directory(installed)
        if (installed.st_dev, installed.st_ino) != (
            parked_status.st_dev,
            parked_status.st_ino,
        ):
            raise ValueError("restored task codebases changed inode")
        sys.stdout.write("changed=true\n")
    finally:
        if task >= 0:
            os.close(task)
        if root >= 0:
            os.close(root)
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def unlink_regular_at(directory: int, name: str, kind: str) -> None:
    before = os.stat(name, dir_fd=directory, follow_symlinks=False)
    validate_recovery_inode(before, kind)
    os.unlink(name, dir_fd=directory)
    os.fsync(directory)


def cmd_submission_recovery_retire(args: argparse.Namespace) -> None:
    directory = open_submission_directory(args.repository, False)
    if directory is None:
        return
    lock = -1
    try:
        lock = open_submission_lock(directory, args.branch)
        value = read_submission_recovery_at(directory, args.branch)
        if value is None:
            lock_status = os.fstat(lock)
            lock_name = submission_recovery_name(args.branch) + ".lock"
            named = os.stat(lock_name, dir_fd=directory, follow_symlinks=False)
            validate_recovery_inode(named, "lock")
            if (lock_status.st_dev, lock_status.st_ino) != (named.st_dev, named.st_ino):
                raise ValueError("submission recovery lock changed before retirement")
            os.unlink(lock_name, dir_fd=directory)
            os.fsync(directory)
            return
        if (
            value["branch"] != args.branch
            or value["claim_id"] != args.claim_id
            or value["stage"] != "restored"
        ):
            raise ValueError("submission recovery retirement identity mismatch")
        validate_recovery_snapshot(args.repository, value)
        validate_cleanup_revision(
            args.repository, value, value["cleanup_revision"]
        )
        validate_recovery_authority(args.repository, value)
        local_ref = "refs/heads/" + args.branch
        if subprocess.call(
            ["git", "-C", args.repository, "show-ref", "--verify", "--quiet", local_ref],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ) == 0:
            raise ValueError("submission recovery branch still exists during retirement")
        worktrees = git_bytes(args.repository, "worktree", "list", "--porcelain").decode(
            "utf-8"
        )
        if "branch {}\n".format(local_ref) in worktrees:
            raise ValueError("submission recovery worktree still exists during retirement")
        staging = submission_task_staging_name(value)
        try:
            os.stat(staging, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("submission recovery staging remains during retirement")
        parking = codebases_parking_name(args.branch)
        try:
            os.stat(parking, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ValueError("submission codebases remain parked during retirement")
        marker = read_codebases_marker(directory, args.branch)
        if marker is not None:
            if (
                marker["branch"] != value["branch"]
                or marker["claim_id"] != value["claim_id"]
                or marker["snapshot_revision"] != value["snapshot_revision"]
            ):
                raise ValueError("submission codebases retirement marker mismatch")
            unlink_regular_at(
                directory, codebases_marker_name(args.branch), "codebases marker"
            )
        unlink_regular_at(
            directory, submission_recovery_name(args.branch), "record"
        )
        lock_status = os.fstat(lock)
        lock_name = submission_recovery_name(args.branch) + ".lock"
        named = os.stat(lock_name, dir_fd=directory, follow_symlinks=False)
        validate_recovery_inode(named, "lock")
        if (lock_status.st_dev, lock_status.st_ino) != (named.st_dev, named.st_ino):
            raise ValueError("submission recovery lock changed before retirement")
        os.unlink(lock_name, dir_fd=directory)
        os.fsync(directory)
    finally:
        if lock >= 0:
            os.close(lock)
        os.close(directory)


def cmd_lifecycle_reduce(args: argparse.Namespace) -> None:
    groups: Dict[str, Dict[str, Any]] = {}
    with open(args.markers_file, encoding="utf-8") as handle:
        for raw in handle:
            if not raw.endswith("\n"):
                raise ValueError("lifecycle marker stream is not LF-terminated")
            marker = json.loads(raw, object_pairs_hook=unique_object)
            require_fields(marker, MARKER_FIELDS, "lifecycle marker stream row")
            if marker["task_contract"] != "workbench-task/v2":
                continue
            reduce_lifecycle_marker(groups, marker)
    group = groups.get(args.branch)
    expected_home = None if args.home == "-" else args.home
    if group is None:
        raise ValueError("submission lifecycle identity is absent")
    if (
        group["claim_id"] != args.claim_id
        or group["issue"] != args.issue
        or group["home"] != expected_home
        or group["workspace_authority_descriptor_digest"] != args.descriptor_digest
    ):
        raise ValueError("submission lifecycle identity mismatch")
    sys.stdout.write("phase={}\n".format(group["phase"]))
    submission = group["submission"]
    sys.stdout.write(
        "pull_request={}\nhead_revision={}\n".format(
            "" if submission is None else submission["number"],
            "" if submission is None else submission["revision"],
        )
    )
    sys.stdout.write("terminal_event={}\n".format(group.get("terminal_event", "")))
    sys.stdout.write(
        "terminal_revision={}\n".format(group.get("terminal_revision", ""))
    )
    sys.stdout.write(
        "terminal_action_instance_id={}\nterminal_intent_digest={}\n".format(
            group.get("terminal_action_instance_id", ""),
            group.get("terminal_intent_digest", ""),
        )
    )


def load_submission_observation(
    path: str,
    repository_origin: str,
    branch: str,
    expected_head: str,
    expected_base_ref: str,
) -> Tuple[str, Optional[Dict[str, Any]]]:
    require_text(expected_base_ref, "submission expected base ref")
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    require_fields(value, SUBMISSION_OBSERVATION_FIELDS, "submission observation")
    if value["contract_version"] != "workbench-hosting-submission-observation/v1":
        raise ValueError("unsupported submission observation contract")
    if (
        value["repository_origin_url"] != repository_origin
        or value["head_branch"] != branch
        or value["base_ref"] != expected_base_ref
    ):
        raise ValueError("submission observation identity mismatch")
    pagination = require_fields(value["pagination"], PAGINATION_FIELDS, "submission pagination")
    if (
        pagination["complete"] is not True
        or not isinstance(pagination["pages_fetched"], int)
        or isinstance(pagination["pages_fetched"], bool)
        or pagination["pages_fetched"] < 1
        or pagination["end_cursor"] is not None
        or pagination["failure"] is not None
    ):
        raise ValueError("submission pagination is incomplete")
    if not isinstance(value["pull_requests"], list):
        raise ValueError("submission pull requests must be an array")
    if not value["pull_requests"]:
        return "absent", None
    matches = []
    for item in value["pull_requests"]:
        require_fields(item, PULL_REQUEST_FIELDS, "submission pull request")
        if not isinstance(item["number"], int) or isinstance(item["number"], bool) or item["number"] <= 0:
            raise ValueError("submission pull request number is invalid")
        for field in ("url", "head_branch", "head_revision", "head_repository_origin_url", "base_ref"):
            require_text(item[field], "pull_request." + field)
        if item["head_is_fork"] is not False or item["state"] not in ("open", "merged"):
            continue
        if (
            item["head_branch"] == branch
            and item["head_revision"] == expected_head
            and item["head_repository_origin_url"] == repository_origin
            and item["base_ref"] == expected_base_ref
        ):
            matches.append(item)
    if len(matches) != 1 or len(value["pull_requests"]) != 1:
        raise ValueError("submission pull request mapping is mismatched or ambiguous")
    return "exact", matches[0]


def cmd_submission(args: argparse.Namespace) -> None:
    state, item = load_submission_observation(
        args.observation_file,
        args.repository_origin_url,
        args.head_branch,
        args.head_revision,
        args.base_ref,
    )
    sys.stdout.write("state={}\n".format(state))
    if item is not None:
        sys.stdout.write("number={}\nurl={}\nhead_revision={}\npull_request_state={}\n".format(
            item["number"], item["url"], item["head_revision"], item["state"]
        ))


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser()
    commands = value.add_subparsers(dest="command", required=True)
    markers = commands.add_parser("markers")
    markers.add_argument("--observation-file", required=True)
    markers.add_argument("--repository-origin-url", required=True)
    markers.add_argument("--issue", type=int, required=True)
    markers.add_argument("--format", choices=("jsonl",), required=True)
    markers.set_defaults(func=cmd_markers)
    task_index = commands.add_parser("task-index")
    task_index.add_argument("--file", required=True)
    task_index.add_argument("--branch", required=True)
    task_index.add_argument("--format", choices=("json", "shell"), required=True)
    task_index.set_defaults(func=cmd_task_index)
    active = commands.add_parser("active-inventory")
    active.add_argument("--observation-file", required=True)
    active.add_argument("--legacy-inventory-file", required=True)
    active.add_argument("--repository", required=True)
    active.add_argument("--workspace-origin-url", required=True)
    active.add_argument("--workspace-home", required=True)
    active.add_argument("--default-ref", required=True)
    active.add_argument("--default-revision", required=True)
    active.add_argument("--descriptor-digest", required=True)
    active.set_defaults(func=cmd_active_inventory)
    submission = commands.add_parser("submission")
    submission.add_argument("--observation-file", required=True)
    submission.add_argument("--repository-origin-url", required=True)
    submission.add_argument("--head-branch", required=True)
    submission.add_argument("--head-revision", required=True)
    submission.add_argument("--base-ref", required=True)
    submission.set_defaults(func=cmd_submission)
    recovery_prepare = commands.add_parser("submission-recovery-prepare")
    recovery_prepare.add_argument("--repository", required=True)
    recovery_prepare.add_argument("--repository-origin-url", required=True)
    recovery_prepare.add_argument("--default-ref", required=True)
    recovery_prepare.add_argument("--branch", required=True)
    recovery_prepare.add_argument("--snapshot-revision", required=True)
    recovery_prepare.set_defaults(func=cmd_submission_recovery_prepare)
    recovery_advance = commands.add_parser("submission-recovery-advance")
    recovery_advance.add_argument("--repository", required=True)
    recovery_advance.add_argument("--branch", required=True)
    recovery_advance.add_argument(
        "--stage", choices=SUBMISSION_RECOVERY_STAGES[1:], required=True
    )
    recovery_advance.add_argument("--cleanup-revision")
    recovery_advance.add_argument("--pull-request", type=int)
    recovery_advance.add_argument("--pull-request-url")
    recovery_advance.add_argument("--head-revision")
    recovery_advance.set_defaults(func=cmd_submission_recovery_advance)
    recovery_validate = commands.add_parser("submission-recovery-validate")
    recovery_validate.add_argument("--repository", required=True)
    recovery_validate.add_argument("--repository-origin-url", required=True)
    recovery_validate.add_argument("--default-ref", required=True)
    recovery_validate.add_argument("--branch", required=True)
    recovery_validate.add_argument("--current-head", required=True)
    recovery_validate.add_argument("--index-file")
    recovery_validate.set_defaults(func=cmd_submission_recovery_validate)
    recovery_restore = commands.add_parser("submission-recovery-restore")
    recovery_restore.add_argument("--repository", required=True)
    recovery_restore.add_argument("--branch", required=True)
    recovery_restore.set_defaults(func=cmd_submission_recovery_restore)
    recovery_codebases = commands.add_parser("submission-recovery-codebases")
    recovery_codebases.add_argument("--repository", required=True)
    recovery_codebases.add_argument("--branch", required=True)
    recovery_codebases.add_argument(
        "--direction", choices=("park", "restore"), required=True
    )
    recovery_codebases.set_defaults(func=cmd_submission_recovery_codebases)
    recovery_retire = commands.add_parser("submission-recovery-retire")
    recovery_retire.add_argument("--repository", required=True)
    recovery_retire.add_argument("--branch", required=True)
    recovery_retire.add_argument("--claim-id", required=True)
    recovery_retire.set_defaults(func=cmd_submission_recovery_retire)
    lifecycle_reduce = commands.add_parser("lifecycle-reduce")
    lifecycle_reduce.add_argument("--markers-file", required=True)
    lifecycle_reduce.add_argument("--branch", required=True)
    lifecycle_reduce.add_argument("--claim-id", required=True)
    lifecycle_reduce.add_argument("--issue", type=int, required=True)
    lifecycle_reduce.add_argument("--home", required=True)
    lifecycle_reduce.add_argument("--descriptor-digest", required=True)
    lifecycle_reduce.set_defaults(func=cmd_lifecycle_reduce)
    return value


def main() -> int:
    try:
        args = parser().parse_args()
        args.func(args)
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print("error: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
