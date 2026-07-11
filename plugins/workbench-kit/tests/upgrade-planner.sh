#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
import fcntl
import hashlib
import multiprocessing
import os
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
import workbench_kit_upgrade as upgrade_module
from workbench_kit_contracts import (
    canonical_bytes,
    canonical_digest,
    node_digest,
    parse_authority_approval,
    parse_reviewed_overlay,
    strict_load,
    validate_migration_receipt,
    validate_plan,
    validate_result,
)
from workbench_kit_planner import (
    PlanningError,
    build_current_plan,
    build_migration_plan,
)
from workbench_kit_cli import CliError, parse_request
from workbench_kit_upgrade import apply_upgrade, dry_run_upgrade, plan_from_snapshot

OID = "1" * 40
SHA = "sha256:" + "a" * 64


def write(root, path, content, mode=0o644):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
    target.chmod(mode)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args]).decode().strip()


def workspace_digest(root):
    rows = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories[:] = sorted(item for item in directories if item != ".git")
        for name in sorted(directories + files):
            path = pathlib.Path(current) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                rows.append(("link", relative, os.readlink(path)))
            elif path.is_file():
                rows.append(("file", relative, hashlib.sha256(path.read_bytes()).hexdigest()))
    return hashlib.sha256(canonical_bytes(rows)).hexdigest()


def git_observable_state(root):
    environment = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
    git_dir = pathlib.Path(subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "--absolute-git-dir"],
        env=environment,
    ).decode().strip())
    rows = []
    for name in ("HEAD", "index", "FETCH_HEAD", "packed-refs"):
        path = git_dir / name
        rows.append((name, path.read_bytes() if path.exists() else None))
    refs = git_dir / "refs"
    for path in sorted(item for item in refs.rglob("*") if item.is_file()):
        rows.append((path.relative_to(git_dir).as_posix(), path.read_bytes()))
    status = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain=v2", "--untracked-files=all"],
        capture_output=True,
        check=True,
        env=environment,
    )
    rows.append(("status", status.stdout))
    return tuple(rows)


def hold_workspace_lock(path, ready, release):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        ready.send(True)
        release.recv()
    finally:
        os.close(descriptor)


def try_locked_workspace_edit(path, result):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    acquired = False
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except BlockingIOError:
            pass
        if acquired:
            subprocess.run(
                ["git", "-C", path, "config", "upgrade.race", "won"],
                check=True,
            )
        result.send(acquired)
    finally:
        os.close(descriptor)


header = b"# Workbench\n\n"
core = b"# Core\n"
separator = b"\n# Persona\n\n"
overlay = b"Reviewed defaults.\n"
settings = {
    "extraKnownMarketplaces": {
        "workbench-kit": {
            "source": {"source": "github", "repo": "YOOGOMJA/workbench-kit"}
        }
    },
    "enabledPlugins": {"workbench@workbench-kit": True},
    "userSetting": {"preserved": True},
}
generator = {
    "contract_version": "workbench-kit-generator-receipt/v1",
    "receipt_id": "generator-0.1.1",
    "generator_id": "workbench-kit:generate-workbench",
    "generator_version": "0.1.1",
    "source_revision": "2" * 40,
    "compose_contract": "workbench-kit-compose/v1",
    "header_base64": base64.b64encode(header).decode(),
    "core_base64": base64.b64encode(core).decode(),
    "core_digest": canonical_digest(core, raw=True),
    "separator_base64": base64.b64encode(separator).decode(),
    "settings_owned": {
        "marketplace": {
            "source": {"source": "github", "repo": "YOOGOMJA/workbench-kit"}
        },
        "plugin_enabled": True,
    },
    "generated_nodes": [
        {"path": ".claude/settings.json", "node_type": "file", "mode": "100644"},
        {"path": "AGENTS.md", "node_type": "file", "mode": "100644"},
        {"path": "CLAUDE.md", "node_type": "file", "mode": "100644"},
    ],
    "receipt_digest": None,
}
generator["receipt_digest"] = canonical_digest(generator, null_field="receipt_digest")

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
    "default_revision": OID,
    "protection": {
        "ref": "refs/heads/main",
        "revision": OID,
        "direct_task_actor_writes": "blocked",
        "verified_at": "2026-07-11T00:00:00Z",
        "evidence_ref": "github:ruleset/example",
    },
    "actor": "github:user/example",
    "approved_at": "2026-07-11T00:00:00Z",
    "source_ref": "github:repository/example/workbench",
}
authority_input = parse_authority_approval(canonical_bytes(authority))
language = {
    "contract_version": "workbench-kit-language-decision/v1",
    "tag": "en",
    "source": "explicit-cli",
    "source_ref": "argv:--language",
    "digest": None,
}
language["digest"] = canonical_digest(language, null_field="digest")


with tempfile.TemporaryDirectory(prefix="workbench-planner-") as temporary:
    root = pathlib.Path(temporary) / "workbench"
    agents = header + core + separator + overlay
    write(root, "AGENTS.overlay.md", overlay)
    write(root, "AGENTS.md", agents)
    write(root, "CLAUDE.md", agents)
    write(root, ".claude/settings.json", canonical_bytes(settings))
    write(root, ".gitignore", b".codebases/\n")
    write(root, "docs/index.md", b"# Docs\n")
    write(root, "templates/custom.md", b"custom\n")
    write(root, "user.txt", b"preserve me\n")
    write(root, "task/index.md", b"---\nid: workbench#27\n---\n")
    subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(root), "config", "user.name", "Fixture"], check=True)
    subprocess.run(["git", "-C", str(root), "config", "user.email", "fixture@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture: generated v1"], check=True)
    subprocess.run(["git", "-C", str(root), "switch", "-qc", "task/27-upgrade"], check=True)

    migration_task = {
        "task_id": "workbench#27",
        "claim_id": "claim-27",
        "task_contract": "workbench-task/v1",
        "branch": "task/27-upgrade",
        "index_digest": canonical_digest((root / "task/index.md").read_bytes(), raw=True),
    }
    diagnosis = {
        "contract_version": "workbench-kit-diagnosis/v1",
        "classification": "generated-minimal",
        "embedded_engine": {
            "state": "absent",
            "equivalence_receipt_digest": None,
        },
        "provenance": {
            "kind": None,
            "state": "absent",
            "receipt_digest": None,
            "ref": None,
        },
        "language": None,
        "blockers": [],
    }
    inventory_object_digest = "sha256:" + "b" * 64
    public = {
        "doctor_projection": {
            "contract_version": "workbench-doctor/v1",
            "ready": False,
            "object_digest": "sha256:" + "c" * 64,
            "source_digest": "sha256:" + "d" * 64,
            "writer_coordination_digest": "sha256:" + "e" * 64,
        },
        "legacy_inventory_projection": {
            "contract_version": "workbench-legacy-inventory/v1",
            "command": "bootstrap-show",
            "object_digest": inventory_object_digest,
            "source_digest": "sha256:" + "f" * 64,
            "authority_revision": OID,
            "home_set_digest": SHA,
            "complete": True,
        },
        "legacy_inventory": {
            "authority": {
                "descriptor_digest": canonical_digest(authority["proposed_descriptor"]),
            }
        },
        "active_v1_tasks": [{
            "source": "legacy-inventory:homes[].claims",
            "home": "workbench",
            "claim_id": "claim-27",
            "task_claim_id": "claim-27",
            "task_contract": "workbench-task/v1",
            "issue": 27,
            "parent": None,
            "branch": "task/27-upgrade",
            "lifecycle_state": "task-claimed",
            "lifecycle_digest": "sha256:" + "9" * 64,
            "source_revision": "2" * 40,
            "pr_head_revision": None,
            "ancestry_complete": True,
        }],
    }
    planner = {
        "contract_version": "workbench-kit-planner/v1",
        "plugin_version": "0.1.1",
        "planner_revision": "3" * 40,
    }

    before = workspace_digest(root)
    status_before = git(root, "status", "--porcelain=v2", "--untracked-files=all")
    first = build_migration_plan(
        root,
        diagnosis=diagnosis,
        public_snapshot=public,
        authority_input=authority_input,
        language=language,
        migration_task=migration_task,
        planner=planner,
        generator_receipt=generator,
        reviewed_overlay_input=None,
    )
    second = build_migration_plan(
        root,
        diagnosis=diagnosis,
        public_snapshot=public,
        authority_input=authority_input,
        language=language,
        migration_task=migration_task,
        planner=planner,
        generator_receipt=generator,
        reviewed_overlay_input=None,
    )
    assert canonical_bytes(first) == canonical_bytes(second)
    assert first == validate_plan(first)
    assert before == workspace_digest(root)
    assert status_before == git(root, "status", "--porcelain=v2", "--untracked-files=all")
    assert first["classification_before"] == "generated-minimal"
    assert first["target_classification"] == "migration-staged"
    assert first["changed"] is True and first["actionable"] is True
    paths = {item["path"] for item in first["operations"]}
    assert {
        ".workbench/schema",
        ".workbench/profile.conf",
        ".workbench/policy.conf",
        ".workbench/authority.json",
        ".workbench/migration.json",
        ".gitignore",
        ".gitattributes",
    } <= paths
    preserved = {item["path"] for item in first["preserved"]}
    assert {
        "AGENTS.overlay.md", "AGENTS.md", "CLAUDE.md", "docs/index.md",
        "templates/custom.md", "task/index.md", "user.txt",
    } <= preserved
    migration_artifact = next(
        item for item in first["artifacts"]
        if item["path"] == ".workbench/migration.json"
    )
    migration_receipt = validate_migration_receipt(strict_load(
        base64.b64decode(migration_artifact["content_base64"]),
        ".workbench/migration.json",
    ))
    assert migration_receipt["active_v1_tasks_digest"] == first["active_v1_tasks"]["digest"]
    assert migration_receipt["artifacts"] == sorted(
        migration_receipt["artifacts"], key=lambda item: item["path"]
    )

    write(root, "untracked.txt", b"dirty\n")
    try:
        build_migration_plan(
            root,
            diagnosis=diagnosis,
            public_snapshot=public,
            authority_input=authority_input,
            language=language,
            migration_task=migration_task,
            planner=planner,
            generator_receipt=generator,
            reviewed_overlay_input=None,
        )
    except PlanningError as error:
        assert error.code == "workspace-dirty"
    else:
        raise AssertionError("dirty workspace was planned")

    (root / "untracked.txt").unlink()
    write(root, "AGENTS.md", b"# Workbench\n\ndirect edit\n")
    write(root, "CLAUDE.md", b"# Workbench\n\ndirect edit\n")
    subprocess.run(["git", "-C", str(root), "add", "AGENTS.md", "CLAUDE.md"], check=True)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture: direct edit"], check=True)
    reviewed_bytes = b"Human approved overlay.\n"
    reviewed_receipt = {
        "contract_version": "workbench-kit-reviewed-overlay/v1",
        "review_id": "review-27",
        "content_base64": base64.b64encode(reviewed_bytes).decode(),
        "content_digest": canonical_digest(reviewed_bytes, raw=True),
        "actor": "github:user/example",
        "reviewed_at": "2026-07-11T00:00:00Z",
        "source_ref": "github:issue/example/27",
    }
    reviewed_input = parse_reviewed_overlay(canonical_bytes(reviewed_receipt))
    reviewed_input = {
        field: reviewed_input[field]
        for field in ("receipt", "object_digest", "source_digest")
    }
    malformed = {
        **diagnosis,
        "classification": "malformed",
        "blockers": [{
            "code": "generator-composition-invalid",
            "ref": "AGENTS.md",
        }],
    }
    reviewed_plan = build_migration_plan(
        root,
        diagnosis=malformed,
        public_snapshot=public,
        authority_input=authority_input,
        language=language,
        migration_task=migration_task,
        planner=planner,
        generator_receipt=generator,
        reviewed_overlay_input=reviewed_input,
    )
    reviewed_paths = {item["path"] for item in reviewed_plan["operations"]}
    assert {"AGENTS.overlay.md", "AGENTS.md", "CLAUDE.md"} <= reviewed_paths
    assert validate_plan(reviewed_plan) == reviewed_plan

    engine_bytes = b"#!/bin/sh\nexit 0\n"
    write(root, "legacy-engine/task", engine_bytes, 0o755)
    subprocess.run(["git", "-C", str(root), "add", "legacy-engine/task"], check=True)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "fixture: embedded engine"], check=True)
    engine_node = {
        "path": "legacy-engine/task",
        "node_type": "file",
        "mode": "100755",
        "digest": node_digest("file", "100755", content=engine_bytes),
        "link_target": None,
    }
    legacy_manifest = {
        "contract_version": "workbench-legacy-engine-manifest/v1",
        "source_ref": "github:YOOGOMJA/workbench-kit#legacy-engine",
        "source_revision": "4" * 40,
        "allowed_roots": ["legacy-engine"],
        "removable_nodes": [engine_node],
        "discovery_links": [],
    }
    equivalence = {
        "contract_version": "workbench-plugin-equivalence/v1",
        "receipt_id": "equivalence-fixture-27",
        "replacement_plugin": {
            "plugin_name": "workbench",
            "plugin_version": "0.2.0",
            "source_revision": "5" * 40,
            "plugin_manifest_digest": SHA,
            "source_ref": "github:YOOGOMJA/workbench-kit#plugins/workbench",
        },
        "public_contract": {
            "contract_version": "workbench-contract/v1",
            "engine_name": "workbench",
            "engine_version": "0.2.0",
            "supported_object_digest": "sha256:" + "6" * 64,
            "capabilities": ["engine.manifest/v1", "workspace.schema/v1"],
        },
        "required_capabilities": ["engine.manifest/v1", "workspace.schema/v1"],
        "legacy_source": {
            "source_ref": legacy_manifest["source_ref"],
            "source_revision": legacy_manifest["source_revision"],
        },
        "legacy_manifest_digest": canonical_digest(legacy_manifest),
        "allowed_roots": legacy_manifest["allowed_roots"],
        "removable_nodes": legacy_manifest["removable_nodes"],
        "discovery_links": legacy_manifest["discovery_links"],
        "verification_evidence": [
            {"evidence_id": "contract", "kind": "contract-test", "source_ref": "ci:contract", "source_revision": "7" * 40, "digest": SHA},
            {"evidence_id": "integration", "kind": "integration-test", "source_ref": "ci:integration", "source_revision": "7" * 40, "digest": SHA},
            {"evidence_id": "audit", "kind": "manifest-audit", "source_ref": "ci:audit", "source_revision": "7" * 40, "digest": SHA},
        ],
    }
    equivalence_input = {
        "receipt": equivalence,
        "object_digest": canonical_digest(equivalence),
        "source_digest": canonical_digest(canonical_bytes(equivalence), raw=True),
    }
    manifest_projection = {
        "contract_version": "workbench-plugin-manifest/v1",
        "command": "engine-manifest show",
        "object_digest": "sha256:" + "8" * 64,
        "source_digest": "sha256:" + "9" * 64,
        "content_revision": "sha256:" + "a" * 64,
        "manifest_digest": SHA,
    }
    embedded_diagnosis = {
        **malformed,
        "embedded_engine": {
            "state": "present-verified",
            "equivalence_receipt_digest": canonical_digest(equivalence),
        },
    }
    planner_v2 = {**planner, "plugin_version": "0.2.0"}
    preserved_engine_plan = build_migration_plan(
        root,
        diagnosis=embedded_diagnosis,
        public_snapshot=public,
        authority_input=authority_input,
        language=language,
        migration_task=migration_task,
        planner=planner_v2,
        generator_receipt=generator,
        reviewed_overlay_input=reviewed_input,
        engine_manifest_projection=manifest_projection,
        plugin_equivalence_input=equivalence_input,
        remove_embedded=False,
        removal_approval_input=None,
    )
    assert preserved_engine_plan["embedded_engine"]["after"] == "present-verified"
    assert not any(
        operation["op"] == "remove"
        for operation in preserved_engine_plan["operations"]
    )
    assert preserved_engine_plan["actionable"] is True

    removal_candidate = build_migration_plan(
        root,
        diagnosis=embedded_diagnosis,
        public_snapshot=public,
        authority_input=authority_input,
        language=language,
        migration_task=migration_task,
        planner=planner_v2,
        generator_receipt=generator,
        reviewed_overlay_input=reviewed_input,
        engine_manifest_projection=manifest_projection,
        plugin_equivalence_input=equivalence_input,
        remove_embedded=True,
        removal_approval_input=None,
    )
    assert removal_candidate["actionable"] is False
    assert removal_candidate["blockers"] == [{
        "code": "removal-approval-required",
        "ref": removal_candidate["removal_plan_basis_digest"],
    }]
    approval = {
        "contract_version": "workbench-kit-removal-approval/v1",
        "approval_id": "removal-27",
        "equivalence_receipt_id": equivalence["receipt_id"],
        "equivalence_receipt_digest": canonical_digest(equivalence),
        "approved_plan_basis_digest": removal_candidate["removal_plan_basis_digest"],
        "actor": "github:user/example",
        "approved_at": "2026-07-11T00:00:00Z",
        "source_ref": "github:issue/example/27",
    }
    approval_input = {
        "receipt": approval,
        "object_digest": canonical_digest(approval),
        "source_digest": canonical_digest(canonical_bytes(approval), raw=True),
    }
    approved_removal = build_migration_plan(
        root,
        diagnosis=embedded_diagnosis,
        public_snapshot=public,
        authority_input=authority_input,
        language=language,
        migration_task=migration_task,
        planner=planner_v2,
        generator_receipt=generator,
        reviewed_overlay_input=reviewed_input,
        engine_manifest_projection=manifest_projection,
        plugin_equivalence_input=equivalence_input,
        remove_embedded=True,
        removal_approval_input=approval_input,
    )
    assert approved_removal["actionable"] is True
    assert any(
        operation["op"] == "remove" and operation["path"] == engine_node["path"]
        for operation in approved_removal["operations"]
    )
    assert validate_plan(approved_removal) == approved_removal

    current_public = {
        **public,
        "doctor_projection": {
            **public["doctor_projection"],
            "ready": True,
        },
        "legacy_inventory_projection": {
            **public["legacy_inventory_projection"],
            "command": "show",
        },
    }
    current_diagnosis = {
        **embedded_diagnosis,
        "classification": "already-current",
        "provenance": {
            "kind": None,
            "state": "absent",
            "receipt_digest": None,
            "ref": None,
        },
        "language": "en",
        "blockers": [],
    }
    current_task = {**migration_task, "task_contract": "workbench-task/v2"}
    current_noop = build_current_plan(
        root,
        diagnosis=current_diagnosis,
        public_snapshot=current_public,
        migration_task=current_task,
        planner=planner_v2,
        engine_manifest_projection=manifest_projection,
        plugin_equivalence_input=equivalence_input,
        remove_embedded=False,
        removal_approval_input=None,
    )
    assert current_noop["classification_before"] == "already-current"
    assert current_noop["target_classification"] == "already-current"
    assert current_noop["changed"] is False
    assert current_noop["actionable"] is False
    assert current_noop["operations"] == []
    assert current_noop["artifacts"] == []
    assert current_noop["inputs"]["bootstrap_authority_approval"] is None
    assert current_noop["inputs"]["reviewed_overlay"] is None
    assert validate_plan(current_noop) == current_noop
    current_noop_path = pathlib.Path(temporary).resolve() / "current-noop-plan.json"
    current_noop_path.write_bytes(canonical_bytes(current_noop))
    current_noop_path.chmod(0o600)
    current_noop_journals = pathlib.Path(temporary).resolve() / "current-noop-journals"
    current_noop_journals.mkdir(mode=0o700)
    current_noop_request = parse_request([
        "--workspace", str(root),
        "upgrade-workbench", "--apply",
        "--plan-file", str(current_noop_path),
        "--journal-dir", str(current_noop_journals),
        "--format", "json",
    ])
    try:
        apply_upgrade(current_noop_request, {
            "planner": planner_v2,
            "generator_receipts": [generator],
            "target_generator_receipt": generator,
            "plugin_equivalence_input": equivalence_input,
        })
    except CliError as error:
        assert error.code == "plan-not-actionable", error.code
    else:
        raise AssertionError("fresh no-op plan was applied")

    current_candidate = build_current_plan(
        root,
        diagnosis=current_diagnosis,
        public_snapshot=current_public,
        migration_task=current_task,
        planner=planner_v2,
        engine_manifest_projection=manifest_projection,
        plugin_equivalence_input=equivalence_input,
        remove_embedded=True,
        removal_approval_input=None,
    )
    assert current_candidate["blockers"] == [{
        "code": "removal-approval-required",
        "ref": current_candidate["removal_plan_basis_digest"],
    }]
    current_approval = {
        **approval,
        "approved_plan_basis_digest": current_candidate[
            "removal_plan_basis_digest"
        ],
    }
    current_approval_input = {
        "receipt": current_approval,
        "object_digest": canonical_digest(current_approval),
        "source_digest": canonical_digest(
            canonical_bytes(current_approval), raw=True
        ),
    }
    current_removal = build_current_plan(
        root,
        diagnosis=current_diagnosis,
        public_snapshot=current_public,
        migration_task=current_task,
        planner=planner_v2,
        engine_manifest_projection=manifest_projection,
        plugin_equivalence_input=equivalence_input,
        remove_embedded=True,
        removal_approval_input=current_approval_input,
    )
    assert current_removal["actionable"] is True
    assert [operation["path"] for operation in current_removal["operations"]] == [
        engine_node["path"]
    ]
    assert not any(
        path in {"AGENTS.md", "CLAUDE.md", ".claude/settings.json"}
        for path in (operation["path"] for operation in current_removal["operations"])
    )
    assert validate_plan(current_removal) == current_removal

    task_index = (
        b"---\n"
        b"id: workbench#27\n"
        b"issue: 27\n"
        b"home: \n"
        b"parent: \n"
        b"slug: upgrade\n"
        b"branch: task/27-upgrade\n"
        b"claim_id: claim-27\n"
        b"---\n"
    )
    write(root, "task/index.md", task_index)
    subprocess.run(["git", "-C", str(root), "add", "task/index.md"], check=True)
    subprocess.run(
        ["git", "-C", str(root), "commit", "-qm", "fixture: task metadata"],
        check=True,
    )
    external_root = pathlib.Path(temporary).resolve()
    authority_path = external_root / "authority.json"
    authority_path.write_bytes(canonical_bytes(authority))
    authority_path.chmod(0o600)
    reviewed_path = external_root / "reviewed.json"
    reviewed_path.write_bytes(canonical_bytes(reviewed_receipt))
    reviewed_path.chmod(0o600)
    orchestration_public = {
        **public,
        "contract": {"workspace": {"schema": "workbench/v1"}},
        "doctor": {"ready": False},
        "engine_manifest_projection": manifest_projection,
    }
    request = parse_request([
        "--workspace", str(root),
        "upgrade-workbench", "--dry-run",
        "--language", "en",
        "--authority-approval-file", str(authority_path),
        "--reviewed-overlay-file", str(reviewed_path),
        "--format", "json",
    ])
    bundle = {
        "planner": planner_v2,
        "generator_receipts": [generator],
        "target_generator_receipt": generator,
        "plugin_equivalence_input": equivalence_input,
    }
    orchestrated = plan_from_snapshot(
        root,
        request=request,
        bundle=bundle,
        public_snapshot=orchestration_public,
    )
    assert orchestrated["classification_before"] == "malformed"
    assert orchestrated["embedded_engine"]["after"] == "present-verified"
    assert orchestrated["actionable"] is True
    assert not any(
        operation["op"] == "remove"
        for operation in orchestrated["operations"]
    )
    assert validate_plan(orchestrated) == orchestrated
    try:
        plan_from_snapshot(
            root,
            request=request,
            bundle={
                **bundle,
                "plugin_equivalence_input": None,
                "legacy_engine_markers": ["legacy-engine/task"],
            },
            public_snapshot=orchestration_public,
        )
    except CliError as error:
        assert error.code == "classification-not-actionable", error.code
    else:
        raise AssertionError("unverified embedded engine was planned")

    cli_root = pathlib.Path(temporary).resolve() / "cli-workbench"
    cli_agents = header + core + separator + overlay
    write(cli_root, "AGENTS.overlay.md", overlay)
    write(cli_root, "AGENTS.md", cli_agents)
    write(cli_root, "CLAUDE.md", cli_agents)
    write(cli_root, ".claude/settings.json", canonical_bytes(settings))
    write(cli_root, "task/index.md", task_index)
    subprocess.run(["git", "-C", str(cli_root), "init", "-q"], check=True)
    subprocess.run(
        ["git", "-C", str(cli_root), "config", "user.name", "Fixture"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(cli_root), "config", "user.email", "fixture@example.invalid"],
        check=True,
    )
    subprocess.run(["git", "-C", str(cli_root), "add", "-A"], check=True)
    subprocess.run(
        ["git", "-C", str(cli_root), "commit", "-qm", "fixture: cli v1"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(cli_root), "switch", "-qc", "task/27-upgrade"],
        check=True,
    )
    cli_request = parse_request([
        "--workspace", str(cli_root),
        "upgrade-workbench", "--dry-run",
        "--language", "en",
        "--authority-approval-file", str(authority_path),
        "--format", "json",
    ])
    cli_bundle = {**bundle, "plugin_equivalence_input": None}
    stub = pathlib.Path(sys.argv[1]).parent / "tests/upgrade-public-stub.sh"
    old_binary = os.environ.get("WORKBENCH_KIT_WORKBENCH_BIN")
    old_approval = os.environ.get("UPGRADE_STUB_APPROVAL_FILE")
    old_descriptor = os.environ.get("UPGRADE_STUB_DESCRIPTOR_DIGEST")
    missing_binary = str(pathlib.Path(temporary).resolve() / "missing-workbench")
    os.environ["WORKBENCH_KIT_WORKBENCH_BIN"] = missing_binary
    indeterminate_before = workspace_digest(cli_root)
    indeterminate = dry_run_upgrade(cli_request, cli_bundle)
    assert indeterminate == {
        "contract_version": "workbench-kit-diagnosis/v1",
        "classification": "indeterminate",
        "embedded_engine": {
            "state": "indeterminate",
            "equivalence_receipt_digest": None,
        },
        "provenance": {
            "kind": None,
            "state": "absent",
            "receipt_digest": None,
            "ref": None,
        },
        "language": None,
        "blockers": [{
            "code": "kernel-readiness-indeterminate",
            "ref": missing_binary,
        }],
    }
    assert workspace_digest(cli_root) == indeterminate_before
    os.environ["WORKBENCH_KIT_WORKBENCH_BIN"] = str(stub)
    os.environ["UPGRADE_STUB_APPROVAL_FILE"] = str(authority_path)
    os.environ["UPGRADE_STUB_DESCRIPTOR_DIGEST"] = canonical_digest(
        authority["proposed_descriptor"]
    )
    git_dir = pathlib.Path(git(cli_root, "rev-parse", "--absolute-git-dir"))
    (git_dir / "FETCH_HEAD").write_bytes(b"fixture fetch state\n")
    stale_node = cli_root / "AGENTS.md"
    stale_stat = stale_node.stat()
    os.utime(
        stale_node,
        ns=(stale_stat.st_atime_ns, stale_stat.st_mtime_ns + 2_000_000_000),
    )
    git_state_before = git_observable_state(cli_root)
    cli_before = workspace_digest(cli_root)
    try:
        cli_first = dry_run_upgrade(cli_request, cli_bundle)
        cli_second = dry_run_upgrade(cli_request, cli_bundle)
    finally:
        for name, value in (
            ("WORKBENCH_KIT_WORKBENCH_BIN", old_binary),
            ("UPGRADE_STUB_APPROVAL_FILE", old_approval),
            ("UPGRADE_STUB_DESCRIPTOR_DIGEST", old_descriptor),
        ):
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    assert canonical_bytes(cli_first) == canonical_bytes(cli_second)
    assert cli_first["classification_before"] == "generated-minimal"
    assert cli_first["actionable"] is True
    assert workspace_digest(cli_root) == cli_before
    assert git_observable_state(cli_root) == git_state_before

    plan_path = external_root / "upgrade-plan.json"
    plan_path.write_bytes(canonical_bytes(cli_first))
    plan_path.chmod(0o600)
    journal_dir = external_root / "upgrade-journals"
    journal_dir.mkdir(mode=0o700)
    xdg_state = external_root / "xdg-state"
    xdg_state.mkdir(mode=0o700)
    apply_request = parse_request([
        "--workspace", str(cli_root),
        "upgrade-workbench", "--apply",
        "--plan-file", str(plan_path),
        "--language", "en",
        "--authority-approval-file", str(authority_path),
        "--journal-dir", str(journal_dir),
        "--format", "json",
    ])
    previous_environment = {
        name: os.environ.get(name)
        for name in (
            "WORKBENCH_KIT_WORKBENCH_BIN",
            "UPGRADE_STUB_APPROVAL_FILE",
            "UPGRADE_STUB_DESCRIPTOR_DIGEST",
            "UPGRADE_STUB_MODE",
            "XDG_STATE_HOME",
        )
    }
    os.environ["WORKBENCH_KIT_WORKBENCH_BIN"] = str(stub)
    os.environ["UPGRADE_STUB_APPROVAL_FILE"] = str(authority_path)
    os.environ["UPGRADE_STUB_DESCRIPTOR_DIGEST"] = canonical_digest(
        authority["proposed_descriptor"]
    )
    os.environ["UPGRADE_STUB_MODE"] = "staged-v2"
    os.environ["XDG_STATE_HOME"] = str(xdg_state)

    alternate_journal_dir = external_root / "alternate-upgrade-journals"
    alternate_journal_dir.mkdir(mode=0o700)
    alternate_apply_request = parse_request([
        "--workspace", str(cli_root),
        "upgrade-workbench", "--apply",
        "--plan-file", str(plan_path),
        "--language", "en",
        "--authority-approval-file", str(authority_path),
        "--journal-dir", str(alternate_journal_dir),
        "--format", "json",
    ])
    context = multiprocessing.get_context("fork")
    ready_parent, ready_child = context.Pipe(duplex=False)
    release_child, release_parent = context.Pipe(duplex=False)
    lock_process = context.Process(
        target=hold_workspace_lock,
        args=(str(cli_root), ready_child, release_child),
    )
    lock_process.start()
    assert ready_parent.recv() is True
    try:
        for blocked_request, operation in (
            (cli_request, dry_run_upgrade),
            (apply_request, apply_upgrade),
            (alternate_apply_request, apply_upgrade),
        ):
            try:
                operation(blocked_request, cli_bundle)
            except CliError as error:
                assert error.code == "apply-in-progress", error.code
            else:
                raise AssertionError("workspace flock contention was ignored")
    finally:
        release_parent.send(True)
        lock_process.join(5)
        assert lock_process.exitcode == 0
    assert not any(journal_dir.iterdir())
    assert not any(alternate_journal_dir.iterdir())

    original_inspect = upgrade_module.inspect_public_kernel
    race_result_parent, race_result_child = context.Pipe(duplex=False)

    def racing_inspect(*args, **kwargs):
        race_process = context.Process(
            target=try_locked_workspace_edit,
            args=(str(cli_root), race_result_child),
        )
        race_process.start()
        race_process.join(5)
        assert race_process.exitcode == 0
        return original_inspect(*args, **kwargs)

    upgrade_module.inspect_public_kernel = racing_inspect
    os.environ["UPGRADE_STUB_MODE"] = "mutate-state"
    try:
        try:
            dry_run_upgrade(cli_request, cli_bundle)
        except CliError as error:
            assert error.code == "public-adapter-mutated", error.code
        else:
            raise AssertionError("mutating public adapter was accepted")
    finally:
        upgrade_module.inspect_public_kernel = original_inspect
        os.environ["UPGRADE_STUB_MODE"] = "staged-v2"
    assert race_result_parent.recv() is False
    race_config = subprocess.run(
        ["git", "-C", str(cli_root), "config", "--get", "upgrade.race"],
        capture_output=True,
        check=False,
    )
    assert race_config.returncode == 1

    try:
        applied = apply_upgrade(apply_request, cli_bundle)
        replayed = apply_upgrade(apply_request, cli_bundle)
    finally:
        for name, value in previous_environment.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    assert validate_result(applied) == applied
    assert applied["transaction"]["stage"] == "completed"
    assert applied["changed"] is True
    assert (cli_root / ".workbench/schema").read_bytes() == b"workbench/v2\n"
    assert validate_result(replayed) == replayed
    assert replayed["changed"] is False
    assert replayed["applied"] == []
    assert replayed["transaction"]["resumed"] is True

    subprocess.run(["git", "-C", str(cli_root), "add", "-A"], check=True)
    subprocess.run(
        ["git", "-C", str(cli_root), "commit", "-qm", "fixture: staged migration"],
        check=True,
    )
    staged_request = parse_request([
        "--workspace", str(cli_root),
        "upgrade-workbench", "--dry-run",
        "--authority-approval-file", str(authority_path),
        "--format", "json",
    ])
    staged_receipt_before = (cli_root / ".workbench/migration.json").read_bytes()
    staged_before = workspace_digest(cli_root)
    staged_environment = {
        name: os.environ.get(name)
        for name in (
            "WORKBENCH_KIT_WORKBENCH_BIN",
            "UPGRADE_STUB_APPROVAL_FILE",
            "UPGRADE_STUB_DESCRIPTOR_DIGEST",
            "UPGRADE_STUB_MODE",
        )
    }
    os.environ["WORKBENCH_KIT_WORKBENCH_BIN"] = str(stub)
    os.environ["UPGRADE_STUB_APPROVAL_FILE"] = str(authority_path)
    os.environ["UPGRADE_STUB_DESCRIPTOR_DIGEST"] = canonical_digest(
        authority["proposed_descriptor"]
    )
    os.environ["UPGRADE_STUB_MODE"] = "staged-v2"
    try:
        staged_noop = dry_run_upgrade(staged_request, cli_bundle)
    finally:
        for name, value in staged_environment.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    assert staged_noop["classification_before"] == "migration-staged"
    assert staged_noop["target_classification"] == "migration-staged"
    assert staged_noop["changed"] is False
    assert staged_noop["actionable"] is False
    assert staged_noop["operations"] == []
    assert staged_noop["artifacts"] == []
    assert (cli_root / ".workbench/migration.json").read_bytes() == staged_receipt_before
    assert workspace_digest(cli_root) == staged_before

    current_descriptor = canonical_digest(authority["proposed_descriptor"])
    current_index = task_index.replace(
        b"id: workbench#27\n", b"id: 27\n"
    ).replace(
        b"claim_id: claim-27\n",
        (
            b"claim_id: claim-27\n"
            b"task_contract: workbench-task/v2\n"
            b"workspace_authority_descriptor_digest: "
            + current_descriptor.encode("ascii")
            + b"\n"
        ),
    )
    write(cli_root, "task/index.md", current_index)
    subprocess.run(["git", "-C", str(cli_root), "add", "task/index.md"], check=True)
    subprocess.run(
        ["git", "-C", str(cli_root), "commit", "-qm", "fixture: native v2 task"],
        check=True,
    )
    current_log = external_root / "historical-current.log"
    current_environment = {
        **os.environ,
        "WORKBENCH_KIT_WORKBENCH_BIN": str(stub),
        "UPGRADE_STUB_APPROVAL_FILE": str(authority_path),
        "UPGRADE_STUB_DESCRIPTOR_DIGEST": current_descriptor,
        "UPGRADE_STUB_MODE": "v2-ok",
        "UPGRADE_STUB_LOG": str(current_log),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    cli = pathlib.Path(sys.argv[1]).parent / "bin/workbench-kit"
    command = [
        str(cli), "--workspace", str(cli_root),
        "upgrade-workbench", "--dry-run", "--format", "json",
    ]
    historical = subprocess.run(
        command,
        capture_output=True,
        check=False,
        env=current_environment,
    )
    assert historical.returncode == 0, historical.stderr.decode()
    assert historical.stderr == b""
    historical_plan = strict_load(historical.stdout, "historical-current")
    assert historical_plan["classification_before"] == "already-current"
    assert historical_plan["changed"] is False
    assert current_log.read_text().splitlines() == [
        f"{cli_root}\tcontract show --format json",
        f"{cli_root}\tdoctor --format json",
        f"{cli_root}\tlegacy-inventory show --format json",
        f"{cli_root}\ttask status --format json",
    ]

    hardlink = cli_root / ".workbench/migration-hardlink.json"
    os.link(cli_root / ".workbench/migration.json", hardlink)
    unsafe_historical = subprocess.run(
        command,
        capture_output=True,
        check=False,
        env=current_environment,
    )
    assert unsafe_historical.returncode == 1
    assert unsafe_historical.stdout == b""
    assert b"workbench-kit: node-hardlink: .workbench/migration.json" in (
        unsafe_historical.stderr
    )
    assert b"Traceback" not in unsafe_historical.stderr
    hardlink.unlink()

print("PASS: deterministic migration planner and preservation manifest")
PY

if find "$ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
