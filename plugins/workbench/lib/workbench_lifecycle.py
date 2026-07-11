#!/usr/bin/env python3
"""Strict authenticated lifecycle observation parsing."""

from __future__ import annotations

import argparse
import datetime
import json
import re
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple


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
RFC3339 = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z")
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
    if not isinstance(value, str) or RFC3339.fullmatch(value) is None:
        raise ValueError("lifecycle at must be RFC 3339 UTC")
    datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    return value


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


def load_submission_observation(
    path: str, repository_origin: str, branch: str, expected_head: str
) -> Tuple[str, Optional[Dict[str, Any]]]:
    with open(path, encoding="utf-8") as handle:
        value = json.load(handle, object_pairs_hook=unique_object)
    require_fields(value, SUBMISSION_OBSERVATION_FIELDS, "submission observation")
    if value["contract_version"] != "workbench-hosting-submission-observation/v1":
        raise ValueError("unsupported submission observation contract")
    if (
        value["repository_origin_url"] != repository_origin
        or value["head_branch"] != branch
        or value["base_ref"] != "main"
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
            and item["base_ref"] == "main"
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
    )
    sys.stdout.write("state={}\n".format(state))
    if item is not None:
        sys.stdout.write("number={}\nurl={}\nhead_revision={}\n".format(
            item["number"], item["url"], item["head_revision"]
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
    submission = commands.add_parser("submission")
    submission.add_argument("--observation-file", required=True)
    submission.add_argument("--repository-origin-url", required=True)
    submission.add_argument("--head-branch", required=True)
    submission.add_argument("--head-revision", required=True)
    submission.set_defaults(func=cmd_submission)
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
