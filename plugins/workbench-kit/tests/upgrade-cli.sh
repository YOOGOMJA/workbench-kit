#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import sys
import base64
import os
import pathlib
import subprocess
import tempfile

sys.path.insert(0, sys.argv[1])

import workbench_kit_upgrade as upgrade_module
from workbench_kit_cli import CliError, parse_request, validate_route_flags
from workbench_kit_contracts import canonical_bytes, canonical_digest, strict_load
from workbench_kit_upgrade import (
    language_decision,
    load_receipt_projection,
    load_runtime_bundle,
    read_migration_task,
    route_for_diagnosis,
)


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


with tempfile.TemporaryDirectory(prefix="workbench-cli-contract-") as temporary:
    base = pathlib.Path(temporary).resolve()
    workspace = base / "workspace"
    (workspace / "task").mkdir(parents=True)
    index = (
        "---\n"
        "id: workbench#27\n"
        "issue: 27\n"
        "home: \n"
        "parent: \n"
        "slug: migrate-workbench\n"
        "branch: task/27-upgrade\n"
        "claim_id: claim-27\n"
        "---\n\n# Task\n"
    ).encode()
    (workspace / "task/index.md").write_bytes(index)
    subprocess.run(["git", "-C", str(workspace), "init", "-q"], check=True)
    subprocess.run(
        ["git", "-C", str(workspace), "config", "user.name", "Fixture"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(workspace), "config", "user.email", "fixture@example.invalid"],
        check=True,
    )
    subprocess.run(["git", "-C", str(workspace), "add", "task/index.md"], check=True)
    subprocess.run(
        ["git", "-C", str(workspace), "commit", "-qm", "fixture: task index"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(workspace), "switch", "-qc", "task/27-upgrade"],
        check=True,
    )
    legacy_claim = {
        "source": "legacy-inventory:homes[].claims",
        "home": "workbench",
        "claim_id": "claim-27",
        "task_claim_id": "claim-27",
        "task_contract": "workbench-task/v1",
        "issue": 27,
        "parent": None,
        "branch": "task/27-upgrade",
        "lifecycle_state": "task-claimed",
        "lifecycle_digest": "sha256:" + "a" * 64,
        "source_revision": "1" * 40,
        "pr_head_revision": None,
        "ancestry_complete": True,
    }
    public_v1 = {"active_v1_tasks": [legacy_claim]}
    task = read_migration_task(
        workspace, "implicit-v1", public_v1, workspace_home="workbench"
    )
    assert task == {
        "task_id": "workbench#27",
        "claim_id": "claim-27",
        "task_contract": "workbench-task/v1",
        "branch": "task/27-upgrade",
        "index_digest": canonical_digest(index, raw=True),
    }
    (workspace / "task/index.md").write_bytes(
        index.replace(b"claim_id: claim-27", b"claim_id: forged-claim")
    )
    try:
        read_migration_task(
            workspace, "implicit-v1", public_v1, workspace_home="workbench"
        )
    except CliError as error:
        assert error.code == "migration-task-identity-invalid", error.code
    else:
        raise AssertionError("forged local v1 task identity was accepted")
    (workspace / "task/index.md").write_bytes(index)
    rejected_task = False
    try:
        read_migration_task(workspace, "current-v2", public_v1)
    except CliError as error:
        rejected_task = error.code == "migration-task-contract-invalid"
    assert rejected_task

    codebase_claim = {**legacy_claim, "home": "my-app"}
    numeric_codebase = index.replace(
        b"id: workbench#27\n", b"id: 27\n"
    )
    (workspace / "task/index.md").write_bytes(numeric_codebase)
    try:
        read_migration_task(
            workspace,
            "implicit-v1",
            {"active_v1_tasks": [codebase_claim]},
            workspace_home="workbench",
        )
    except CliError as error:
        assert error.code == "migration-task-identity-invalid", error.code
    else:
        raise AssertionError("numeric/blank-home codebase identity was accepted")
    exact_codebase = numeric_codebase.replace(
        b"id: 27\n", b"id: my-app#27\n"
    ).replace(
        b"home: \n", b"home: my-app\n"
    )
    (workspace / "task/index.md").write_bytes(exact_codebase)
    assert read_migration_task(
        workspace,
        "implicit-v1",
        {"active_v1_tasks": [codebase_claim]},
        workspace_home="workbench",
    )["task_id"] == "my-app#27"

    descriptor_digest = "sha256:" + "b" * 64
    v2_index = index.replace(
        b"id: workbench#27\n",
        b"id: 27\n",
    ).replace(
        b"claim_id: claim-27\n",
        (
            b"claim_id: claim-27\n"
            b"task_contract: workbench-task/v2\n"
            b"workspace_authority_descriptor_digest: "
            + descriptor_digest.encode()
            + b"\n"
        ),
    )
    (workspace / "task/index.md").write_bytes(v2_index)
    public_v2 = {
        "migration_task_claim": {
            "task_id": "27",
            "issue": 27,
            "home": None,
            "parent": None,
            "claim_id": "claim-27",
            "task_contract": "workbench-task/v2",
            "branch": "task/27-upgrade",
            "workspace_authority_descriptor_digest": descriptor_digest,
            "context_ref": None,
            "work_ref": None,
            "work_owners": [],
        },
        "doctor": {
            "writer_coordination": {
                "descriptor_digest": descriptor_digest,
            }
        },
    }
    assert read_migration_task(workspace, "current-v2", public_v2)["task_contract"] == (
        "workbench-task/v2"
    )
    forged = v2_index.replace(b"claim_id: claim-27", b"claim_id: forged-claim")
    (workspace / "task/index.md").write_bytes(forged)
    try:
        read_migration_task(workspace, "current-v2", public_v2)
    except CliError as error:
        assert error.code == "migration-task-identity-invalid", error.code
    else:
        raise AssertionError("forged local v2 task identity was accepted")
    forged = v2_index.replace(b"id: 27", b"id: 999")
    (workspace / "task/index.md").write_bytes(forged)
    try:
        read_migration_task(workspace, "current-v2", public_v2)
    except CliError as error:
        assert error.code == "migration-task-identity-invalid", error.code
    else:
        raise AssertionError("forged local v2 task id was accepted")
    forged = v2_index.replace(
        descriptor_digest.encode(), ("sha256:" + "c" * 64).encode()
    )
    (workspace / "task/index.md").write_bytes(forged)
    try:
        read_migration_task(workspace, "current-v2", public_v2)
    except CliError as error:
        assert error.code == "migration-task-identity-invalid", error.code
    else:
        raise AssertionError("forged local v2 descriptor was accepted")
    (workspace / "task/index.md").write_bytes(v2_index)

    authority = {
        "contract_version": "workbench-bootstrap-authority-approval/v1",
        "approval_id": "approval-27",
        "proposed_descriptor": {
            "contract_version": "workbench-workspace-authority/v1",
            "authority_identity": "github:example/workbench",
            "origin_url": "https://github.com/example/workbench.git",
            "default_ref": "refs/heads/main",
            "workspace_home": "workbench",
            "hosting_adapter": "github",
            "hosting_ref": "github:repository/example/workbench",
        },
        "default_revision": "1" * 40,
        "protection": {
            "ref": "refs/heads/main",
            "revision": "1" * 40,
            "direct_task_actor_writes": "blocked",
            "verified_at": "2026-07-11T00:00:00Z",
            "evidence_ref": "github:ruleset/example",
        },
        "actor": "github:user/example",
        "approved_at": "2026-07-11T00:00:00Z",
        "source_ref": "github:repository/example/workbench",
    }
    external = base / "authority.json"
    external.write_bytes(canonical_bytes(authority))
    external.chmod(0o600)
    projection = load_receipt_projection(
        external, workspace, "bootstrap-authority"
    )
    assert projection["receipt"] == authority
    assert projection["source_digest"] == canonical_digest(
        canonical_bytes(authority), raw=True
    )
    inside = workspace / "authority.json"
    inside.write_bytes(canonical_bytes(authority))
    inside.chmod(0o600)
    for unsafe_path in (inside, base / "authority-link.json"):
        if unsafe_path.name.endswith("link.json"):
            unsafe_path.symlink_to(external)
        try:
            load_receipt_projection(
                unsafe_path, workspace, "bootstrap-authority"
            )
        except CliError as error:
            assert error.code == "input-file-unsafe"
        else:
            raise AssertionError("unsafe receipt input was accepted")
    hardlink = base / "authority-hardlink.json"
    os.link(external, hardlink)
    try:
        load_receipt_projection(
            hardlink, workspace, "bootstrap-authority"
        )
    except CliError as error:
        assert error.code == "input-file-unsafe"
    else:
        raise AssertionError("hardlinked receipt input was accepted")

    raced = base / "authority-raced.json"
    raced.write_bytes(canonical_bytes(authority))
    raced.chmod(0o600)
    race_alias = base / "authority-raced-alias.json"
    original_read = upgrade_module.os.read
    raced_after_read = False

    def mutate_input_after_read(descriptor, count):
        global raced_after_read
        chunk = original_read(descriptor, count)
        if chunk and not raced_after_read:
            raced_after_read = True
            os.link(raced, race_alias)
            raced.chmod(0o644)
        return chunk

    upgrade_module.os.read = mutate_input_after_read
    try:
        try:
            load_receipt_projection(
                raced, workspace, "bootstrap-authority"
            )
        except CliError as error:
            assert error.code == "input-file-unsafe"
        else:
            raise AssertionError("post-read input mutation was accepted")
    finally:
        upgrade_module.os.read = original_read
        raced.chmod(0o600)
        race_alias.unlink()
    assert raced_after_read is True

assert route_for_diagnosis(
    {"classification": "generated-minimal", "blockers": []}, "workbench/v1"
) == "implicit-v1"
assert route_for_diagnosis(
    {"classification": "migration-staged", "blockers": []}, "workbench/v2"
) == "staged-v2"
assert route_for_diagnosis(
    {"classification": "already-current", "blockers": []}, "workbench/v2"
) == "current-v2"
try:
    route_for_diagnosis(
        {"classification": "unrecognized", "blockers": []}, "workbench/v1"
    )
except CliError as error:
    assert error.code == "classification-not-actionable"
else:
    raise AssertionError("unrecognized workspace received a route")

explicit = language_decision("en-US", "implicit-v1")
assert explicit["source"] == "explicit-cli"
profile = language_decision("ko", "staged-v2")
assert profile["source"] == "workspace-profile"

runtime_bundle = load_runtime_bundle(pathlib.Path(sys.argv[1]).parent)
assert runtime_bundle["planner"]["contract_version"] == (
    "workbench-kit-planner/v1"
)
assert runtime_bundle["planner"]["plugin_version"] == "0.1.1"
assert len(runtime_bundle["planner"]["planner_revision"]) == 40
assert runtime_bundle["target_generator_receipt"]["generator_version"] == "0.1.1"
assert runtime_bundle["generator_receipts"] == [
    runtime_bundle["target_generator_receipt"]
]
assert runtime_bundle["plugin_equivalence_input"] is None
assert runtime_bundle["legacy_engine_markers"] == [
    "skills/task-done/SKILL.md",
    "skills/task-start/SKILL.md",
    "skills/task-submit/SKILL.md",
    "utils/docs",
    "utils/task",
    "utils/workbench",
]

try:
    load_runtime_bundle(pathlib.Path("/workbench-kit/missing-plugin-root"))
except CliError as error:
    assert error.code == "runtime-bundle-invalid"
else:
    raise AssertionError("missing runtime bundle root was accepted")

with tempfile.TemporaryDirectory(prefix="workbench-runtime-invalid-") as temporary:
    invalid_root = pathlib.Path(temporary)
    source_root = pathlib.Path(sys.argv[1]).parent
    (invalid_root / ".claude-plugin").mkdir()
    (invalid_root / "receipts").mkdir()
    (invalid_root / "scaffold").mkdir()
    (invalid_root / ".claude-plugin/plugin.json").write_bytes(
        (source_root / ".claude-plugin/plugin.json").read_bytes()
    )
    (invalid_root / "scaffold/AGENTS.core.md").write_bytes(
        (source_root / "scaffold/AGENTS.core.md").read_bytes()
    )
    runtime_path = source_root / "receipts/upgrade-runtime.json"
    invalid_runtime = strict_load(runtime_path.read_bytes(), str(runtime_path))
    invalid_runtime["planner_revision"] = "not-an-object-id"
    (invalid_root / "receipts/upgrade-runtime.json").write_bytes(
        canonical_bytes(invalid_runtime)
    )
    try:
        load_runtime_bundle(invalid_root)
    except CliError as error:
        assert error.code == "runtime-bundle-invalid"
    else:
        raise AssertionError("invalid planner revision was accepted")

with tempfile.TemporaryDirectory(prefix="workbench-runtime-compose-") as temporary:
    temporary_root = pathlib.Path(temporary)
    persona = temporary_root / "persona"
    output = temporary_root / "output"
    persona.mkdir()
    overlay_bytes = b"# Language\n\nEnglish.\n"
    (persona / "overlay.md").write_bytes(overlay_bytes)
    plugin_root = pathlib.Path(sys.argv[1]).parent
    subprocess.run(
        [
            "bash",
            str(plugin_root / "skills/generate-workbench/scripts/compose.sh"),
            "--persona",
            str(persona),
            "--core",
            str(plugin_root / "scaffold/AGENTS.core.md"),
            "--scaffold",
            str(plugin_root / "scaffold"),
            "--out",
            str(output),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    receipt = runtime_bundle["target_generator_receipt"]
    expected_agents = (
        base64.b64decode(receipt["header_base64"], validate=True)
        + base64.b64decode(receipt["core_base64"], validate=True)
        + base64.b64decode(receipt["separator_base64"], validate=True)
        + overlay_bytes
    )
    assert (output / "AGENTS.md").read_bytes() == expected_agents
    assert (output / "CLAUDE.md").read_bytes() == expected_agents

print("PASS: safe task, receipt, route, and language orchestration inputs")
PY

BIN="$ROOT/bin/workbench-kit"
[ -x "$BIN" ] || { echo "FAIL: workbench-kit entrypoint missing" >&2; exit 1; }
"$BIN" --help > /dev/null
set +e
"$BIN" --workspace /tmp/workbench upgrade-workbench --format json \
  > /tmp/workbench-kit-cli.stdout 2> /tmp/workbench-kit-cli.stderr
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: invalid CLI status $status" >&2; exit 1; }
[ ! -s /tmp/workbench-kit-cli.stdout ] \
  || { echo "FAIL: invalid CLI wrote stdout" >&2; exit 1; }
grep -q 'mode-required: --dry-run/--apply' /tmp/workbench-kit-cli.stderr \
  || { echo "FAIL: invalid CLI diagnostic mismatch" >&2; exit 1; }
rm -f /tmp/workbench-kit-cli.stdout /tmp/workbench-kit-cli.stderr

runtime_tmp="$(mktemp -d "${TMPDIR:-/tmp}/workbench-kit-cli-runtime.XXXXXX")"
runtime_tmp="$(cd "$runtime_tmp" && pwd -P)"
missing_plan="$runtime_tmp/workbench-kit-missing-plan-$$.json"
set +e
"$BIN" --workspace "$runtime_tmp" upgrade-workbench --apply \
  --plan-file "$missing_plan" --format json \
  > /tmp/workbench-kit-cli.stdout 2> /tmp/workbench-kit-cli.stderr
status=$?
set -e
[ "$status" -eq 1 ] || { echo "FAIL: runtime CLI status $status" >&2; exit 1; }
[ ! -s /tmp/workbench-kit-cli.stdout ] \
  || { echo "FAIL: runtime CLI wrote stdout" >&2; exit 1; }
grep -q 'input-file-invalid:' /tmp/workbench-kit-cli.stderr \
  || { echo "FAIL: runtime CLI diagnostic mismatch" >&2; exit 1; }
! grep -q 'Traceback' /tmp/workbench-kit-cli.stderr \
  || { echo "FAIL: runtime CLI leaked traceback" >&2; exit 1; }
rm -f /tmp/workbench-kit-cli.stdout /tmp/workbench-kit-cli.stderr

set +e
"$BIN" --workspace "$runtime_tmp/workbench-kit-missing-workspace-$$" \
  upgrade-workbench --dry-run --format json \
  > /tmp/workbench-kit-cli.stdout 2> /tmp/workbench-kit-cli.stderr
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: missing workspace status $status" >&2; exit 1; }
grep -q 'workspace-invalid:' /tmp/workbench-kit-cli.stderr \
  || { echo "FAIL: missing workspace diagnostic mismatch" >&2; exit 1; }
! grep -q 'Traceback' /tmp/workbench-kit-cli.stderr \
  || { echo "FAIL: missing workspace leaked traceback" >&2; exit 1; }
rm -f /tmp/workbench-kit-cli.stdout /tmp/workbench-kit-cli.stderr
rm -rf "$runtime_tmp"

echo "PASS: packaged workbench-kit CLI entrypoint"

if find "$ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
