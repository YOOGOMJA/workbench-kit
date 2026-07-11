#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import sys

sys.path.insert(0, sys.argv[1])

from workbench_kit_cli import CliError, parse_request, validate_route_flags


WORKSPACE = "/tmp/workbench-kit-cli-workspace"
AUTHORITY = "/tmp/workbench-kit-authority.json"
OVERLAY = "/tmp/workbench-kit-overlay.json"
PLAN = "/tmp/workbench-kit-plan.json"
REMOVAL = "/tmp/workbench-kit-removal.json"
JOURNAL = "/tmp/workbench-kit-journals"


def request(*arguments):
    return parse_request([
        "--workspace",
        WORKSPACE,
        "upgrade-workbench",
        *arguments,
        "--format",
        "json",
    ])


def rejected(arguments, *, code, route=None):
    try:
        parsed = arguments if isinstance(arguments, dict) else parse_request(arguments)
        if route is not None:
            validate_route_flags(parsed, route)
    except CliError as error:
        assert error.code == code, (error.code, code)
    else:
        raise AssertionError((arguments, code))


legacy_dry = request(
    "--dry-run",
    "--language",
    "en",
    "--authority-approval-file",
    AUTHORITY,
    "--reviewed-overlay-file",
    OVERLAY,
    "--remove-embedded-engine",
    "--removal-approval-file",
    REMOVAL,
)
assert validate_route_flags(legacy_dry, "implicit-v1") == legacy_dry

staged_dry = request(
    "--dry-run",
    "--authority-approval-file",
    AUTHORITY,
    "--reviewed-overlay-file",
    OVERLAY,
)
assert validate_route_flags(staged_dry, "staged-v2") == staged_dry

current_dry = request("--dry-run", "--remove-embedded-engine")
assert validate_route_flags(current_dry, "current-v2") == current_dry

legacy_apply = request(
    "--apply",
    "--plan-file",
    PLAN,
    "--language",
    "en",
    "--authority-approval-file",
    AUTHORITY,
    "--reviewed-overlay-file",
    OVERLAY,
    "--removal-approval-file",
    REMOVAL,
    "--journal-dir",
    JOURNAL,
)
assert validate_route_flags(legacy_apply, "implicit-v1") == legacy_apply

current_apply = request(
    "--apply",
    "--plan-file",
    PLAN,
    "--removal-approval-file",
    REMOVAL,
    "--journal-dir",
    JOURNAL,
)
assert validate_route_flags(current_apply, "current-v2") == current_apply

base = ["--workspace", WORKSPACE, "upgrade-workbench"]
rejected(base + ["--format", "json"], code="mode-required")
rejected(
    base + ["--dry-run", "--apply", "--format", "json"],
    code="mode-conflict",
)
rejected(
    base + ["--dry-run", "--plan-file", PLAN, "--format", "json"],
    code="dry-run-flag-conflict",
)
rejected(
    base + ["--dry-run", "--journal-dir", JOURNAL, "--format", "json"],
    code="dry-run-flag-conflict",
)
rejected(
    base + ["--apply", "--format", "json"],
    code="plan-file-required",
)
rejected(
    base + [
        "--apply", "--plan-file", PLAN, "--remove-embedded-engine",
        "--format", "json",
    ],
    code="apply-flag-conflict",
)
rejected(
    base + ["--dry-run", "--removal-approval-file", REMOVAL, "--format", "json"],
    code="removal-request-required",
)
rejected(
    ["--workspace", "relative", "upgrade-workbench", "--dry-run", "--format", "json"],
    code="workspace-not-absolute",
)
rejected(
    base + ["--dry-run"],
    code="format-required",
)
rejected(
    base + ["--dry-run", "--format", "text"],
    code="format-invalid",
)

rejected(
    request("--dry-run", "--authority-approval-file", AUTHORITY),
    route="implicit-v1",
    code="language-required",
)
rejected(
    request("--dry-run", "--language", "en"),
    route="implicit-v1",
    code="authority-approval-required",
)
rejected(
    request("--dry-run", "--language", "en", "--authority-approval-file", AUTHORITY),
    route="staged-v2",
    code="language-not-allowed",
)
rejected(
    request("--dry-run"),
    route="staged-v2",
    code="authority-approval-required",
)
rejected(
    request("--dry-run", "--language", "en"),
    route="current-v2",
    code="language-not-allowed",
)
rejected(
    request("--dry-run", "--authority-approval-file", AUTHORITY),
    route="current-v2",
    code="authority-approval-not-allowed",
)
rejected(
    request("--dry-run", "--reviewed-overlay-file", OVERLAY),
    route="current-v2",
    code="reviewed-overlay-not-allowed",
)
rejected(
    request("--dry-run"),
    route="unknown",
    code="route-invalid",
)

print("PASS: closed upgrade CLI flag matrix")
PY
