#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
import fcntl
import multiprocessing
import pathlib
import os
import stat
import sys
import tempfile

sys.path.insert(0, sys.argv[1])

from workbench_kit_contracts import (
    canonical_bytes,
    canonical_digest,
    node_digest,
    parse_authority_approval,
    validate_journal,
    validate_plan,
    validate_result,
)
from workbench_kit_journal import (
    JournalError,
    build_prepared_journal,
    execute_upgrade,
    install_prepared_journal,
    load_journal,
    resolve_journal_location,
)


OID = "1" * 40
SHA = "sha256:" + "a" * 64
CREATED_AT = "2026-07-11T00:00:00Z"


def rejected(callable_, code):
    try:
        callable_()
    except JournalError as error:
        assert error.code == code, (error.code, code)
        return
    raise AssertionError(code)


def fixture_plan(root):
    before = b"legacy marker\n"
    after = b"workbench/v2\n"
    (root / ".workbench").mkdir()
    (root / ".workbench/schema").write_bytes(before)
    (root / "user.txt").write_bytes(b"preserve me\n")
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
            "verified_at": CREATED_AT,
            "evidence_ref": "github:ruleset/example",
        },
        "actor": "github:user/example",
        "approved_at": CREATED_AT,
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
    active = {
        "contract_version": "workbench-kit-active-v1-tasks/v1",
        "source_inventory_object_digest": SHA,
        "tasks": [],
        "digest": None,
    }
    active["digest"] = canonical_digest(active, null_field="digest")
    artifact_source_digest = canonical_digest(after, raw=True)
    plan = {
        "contract_version": "workbench-kit-upgrade-plan/v1",
        "plan_digest": None,
        "classification_before": "generated-minimal",
        "target_classification": "migration-staged",
        "embedded_engine": {
            "before": "absent",
            "after": "absent",
            "equivalence_receipt_digest": None,
        },
        "provenance_before": {
            "kind": None,
            "state": "absent",
            "receipt_digest": None,
            "ref": None,
        },
        "provenance_after": {
            "kind": "migration",
            "state": "valid",
            "receipt_digest": "sha256:" + "9" * 64,
            "ref": ".workbench/migration.json",
        },
        "workspace": {
            "root": str(root),
            "source_revision": OID,
            "default_revision": OID,
            "source_tree_digest": "git-tree:" + "2" * 40,
            "migration_task": {
                "task_id": "workbench#27",
                "claim_id": "claim-27",
                "task_contract": "workbench-task/v1",
                "branch": "task/27-upgrade",
                "index_digest": SHA,
            },
        },
        "planner": {
            "contract_version": "workbench-kit-planner/v1",
            "plugin_version": "0.2.0",
            "planner_revision": "3" * 40,
        },
        "doctor": {
            "contract_version": "workbench-doctor/v1",
            "ready": False,
            "object_digest": SHA,
            "source_digest": SHA,
            "writer_coordination_digest": SHA,
        },
        "legacy_inventory": {
            "contract_version": "workbench-legacy-inventory/v1",
            "command": "bootstrap-show",
            "object_digest": SHA,
            "source_digest": SHA,
            "authority_revision": OID,
            "home_set_digest": SHA,
            "complete": True,
        },
        "inputs": {
            "language": language,
            "bootstrap_authority_approval": authority_input,
            "reviewed_overlay": None,
        },
        "engine_manifest": None,
        "plugin_equivalence": None,
        "removal_plan_basis_digest": None,
        "removal_approval": None,
        "active_v1_tasks": active,
        "preserved": [{
            "path": "user.txt",
            "node_type": "file",
            "mode": "100644",
            "digest": node_digest("file", "100644", content=b"preserve me\n"),
            "link_target": None,
        }],
        "parent_directories": [{
            "path": ".workbench",
            "before_type": "directory",
            "before_mode": "040755",
            "after_type": "directory",
            "after_mode": "040755",
        }],
        "artifacts": [{
            "path": ".workbench/schema",
            "node_type": "file",
            "mode": "100644",
            "content_base64": base64.b64encode(after).decode("ascii"),
            "link_target": None,
            "source_ref": "constant:workbench/v2",
            "source_digest": artifact_source_digest,
        }],
        "operations": [{
            "op": "update",
            "path": ".workbench/schema",
            "before_type": "file",
            "before_mode": "100644",
            "before_digest": node_digest("file", "100644", content=before),
            "after_type": "file",
            "after_mode": "100644",
            "after_digest": node_digest("file", "100644", content=after),
            "artifact_source_digest": artifact_source_digest,
            "equivalence_receipt_ref": None,
        }],
        "blockers": [],
        "changed": True,
        "actionable": True,
    }
    plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
    return validate_plan(plan), before, after


def passed_validation(plan):
    validation = {
        "status": "passed",
        "classification_after": plan["target_classification"],
        "basis_kind": "migration-candidate",
        "basis_digest": plan["provenance_after"]["receipt_digest"],
        "blockers": [],
        "digest": None,
    }
    validation["digest"] = canonical_digest(validation, null_field="digest")
    return validation


def fixture_create_plan(root):
    plan, _, after = fixture_plan(root)
    (root / ".workbench/schema").unlink()
    (root / ".workbench").rmdir()
    plan["plan_digest"] = None
    plan["parent_directories"] = [{
        "path": ".workbench",
        "before_type": None,
        "before_mode": None,
        "after_type": "directory",
        "after_mode": "040755",
    }]
    plan["operations"][0]["op"] = "create"
    plan["operations"][0]["before_type"] = None
    plan["operations"][0]["before_mode"] = None
    plan["operations"][0]["before_digest"] = None
    plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
    return validate_plan(plan), after


def fixture_removal_plan(root):
    plan, _, _ = fixture_plan(root)
    engine_bytes = b"#!/bin/sh\nexit 0\n"
    engine_path = root / "legacy-engine/task"
    engine_path.parent.mkdir()
    engine_path.write_bytes(engine_bytes)
    engine_path.chmod(0o755)
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
    remove_operation = {
        "op": "remove",
        "path": engine_node["path"],
        "before_type": "file",
        "before_mode": "100755",
        "before_digest": engine_node["digest"],
        "after_type": None,
        "after_mode": None,
        "after_digest": None,
        "artifact_source_digest": None,
        "equivalence_receipt_ref": equivalence["receipt_id"],
    }
    plan["plan_digest"] = None
    plan["classification_before"] = "already-current"
    plan["target_classification"] = "already-current"
    plan["embedded_engine"] = {
        "before": "present-verified",
        "after": "absent",
        "equivalence_receipt_digest": equivalence_input["object_digest"],
    }
    plan["provenance_before"] = {
        "kind": None, "state": "absent", "receipt_digest": None, "ref": None,
    }
    plan["provenance_after"] = dict(plan["provenance_before"])
    plan["workspace"]["migration_task"]["task_contract"] = "workbench-task/v2"
    plan["doctor"]["ready"] = True
    plan["legacy_inventory"]["command"] = "show"
    plan["inputs"]["bootstrap_authority_approval"] = None
    plan["inputs"]["language"]["source"] = "workspace-profile"
    plan["inputs"]["language"]["source_ref"] = ".workbench/profile.conf"
    plan["inputs"]["language"]["digest"] = canonical_digest(
        plan["inputs"]["language"], null_field="digest"
    )
    plan["engine_manifest"] = {
        "contract_version": "workbench-plugin-manifest/v1",
        "command": "engine-manifest show",
        "object_digest": "sha256:" + "8" * 64,
        "source_digest": "sha256:" + "9" * 64,
        "content_revision": "sha256:" + "b" * 64,
        "manifest_digest": SHA,
    }
    plan["plugin_equivalence"] = equivalence_input
    plan["parent_directories"] = [{
        "path": "legacy-engine",
        "before_type": "directory",
        "before_mode": "040755",
        "after_type": "directory",
        "after_mode": "040755",
    }]
    plan["artifacts"] = []
    plan["operations"] = [remove_operation]
    basis = {
        "contract_version": "workbench-kit-removal-plan-basis/v1",
        "workspace_source_revision": plan["workspace"]["source_revision"],
        "workspace_source_tree_digest": plan["workspace"]["source_tree_digest"],
        "migration_task_claim_id": plan["workspace"]["migration_task"]["claim_id"],
        "planner_revision": plan["planner"]["planner_revision"],
        "legacy_inventory_digest": plan["legacy_inventory"]["object_digest"],
        "equivalence_receipt_digest": equivalence_input["object_digest"],
        "remove_operations": [remove_operation],
    }
    plan["removal_plan_basis_digest"] = canonical_digest(basis)
    approval = {
        "contract_version": "workbench-kit-removal-approval/v1",
        "approval_id": "removal-27",
        "equivalence_receipt_id": equivalence["receipt_id"],
        "equivalence_receipt_digest": equivalence_input["object_digest"],
        "approved_plan_basis_digest": plan["removal_plan_basis_digest"],
        "actor": "github:user/example",
        "approved_at": CREATED_AT,
        "source_ref": "github:issue/example/27",
    }
    plan["removal_approval"] = {
        "receipt": approval,
        "object_digest": canonical_digest(approval),
        "source_digest": canonical_digest(canonical_bytes(approval), raw=True),
    }
    plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
    return validate_plan(plan), engine_bytes


def hold_workspace_lock(path, ready, release):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        ready.send(True)
        release.recv()
    finally:
        os.close(descriptor)


with tempfile.TemporaryDirectory(prefix="workbench-journal-") as temporary:
    root = pathlib.Path(temporary) / "workbench"
    root.mkdir()
    root = root.resolve()
    plan, before, after = fixture_plan(root)
    raw_plan = canonical_bytes(plan)
    plan_source_digest = canonical_digest(raw_plan, raw=True)
    first = build_prepared_journal(plan, plan_source_digest, CREATED_AT)
    second = build_prepared_journal(plan, plan_source_digest, CREATED_AT)
    assert canonical_bytes(first) == canonical_bytes(second)
    assert validate_journal(first, plan) == first
    assert first["journal_id"] == "upgrade-" + plan["plan_digest"][7:]
    assert first["stage"] == "prepared"
    assert first["direction"] == "forward"
    assert first["cursor"] == 0
    assert first["applied"] == []
    assert len(first["effects"]) == 1
    effect = first["effects"][0]
    assert effect["effect_id"] == "effect-0001"
    assert effect["kind"] == "update"
    assert effect["before"]["content_base64"] == base64.b64encode(before).decode()
    assert effect["after"]["content_base64"] == base64.b64encode(after).decode()
    assert effect["temp_path"] == (
        ".workbench/.workbench-kit."
        + first["journal_id"]
        + ".effect-0001.tmp"
    )
    assert first["validation"]["status"] == "pending"

    journal_root = pathlib.Path(temporary) / "journal-root"
    journal_root.mkdir(mode=0o700)
    journal_root = journal_root.resolve()
    location = resolve_journal_location(
        root,
        plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    assert location["root"] == journal_root
    assert location["directory"].parent == journal_root
    assert location["directory"].name == first["workspace_id"]
    assert location["journal"].name == plan["plan_digest"][7:] + ".json"
    installed = install_prepared_journal(first, location)
    assert installed == location["journal"]
    installed_stat = os.lstat(installed)
    assert stat.S_ISREG(installed_stat.st_mode)
    assert stat.S_IMODE(installed_stat.st_mode) == 0o600
    assert installed_stat.st_nlink == 1
    assert installed.read_bytes() == canonical_bytes(first)
    assert not location["initial_temp"].exists()
    rejected(lambda: install_prepared_journal(first, location), "journal-exists")

    rejected(
        lambda: resolve_journal_location(
            root, plan["plan_digest"], journal_dir=pathlib.Path("relative")
        ),
        "journal-root-invalid",
    )
    inside = root / ".journal"
    inside.mkdir(mode=0o700)
    rejected(
        lambda: resolve_journal_location(root, plan["plan_digest"], journal_dir=inside),
        "journal-root-unsafe",
    )
    unsafe = pathlib.Path(temporary) / "unsafe"
    unsafe.mkdir(mode=0o777)
    unsafe.chmod(0o777)
    rejected(
        lambda: resolve_journal_location(root, plan["plan_digest"], journal_dir=unsafe),
        "journal-root-unsafe",
    )
    symlink = pathlib.Path(temporary) / "journal-link"
    symlink.symlink_to(journal_root, target_is_directory=True)
    rejected(
        lambda: resolve_journal_location(root, plan["plan_digest"], journal_dir=symlink),
        "journal-root-unsafe",
    )

    xdg = pathlib.Path(temporary) / "xdg"
    xdg.mkdir(mode=0o700)
    xdg = xdg.resolve()
    default_location = resolve_journal_location(
        root,
        plan["plan_digest"],
        environment={"XDG_STATE_HOME": str(xdg)},
    )
    assert default_location["root"] == xdg / "workbench-kit/upgrades"
    assert stat.S_IMODE(os.lstat(default_location["root"]).st_mode) == 0o700
    rejected(
        lambda: resolve_journal_location(
            root,
            plan["plan_digest"],
            environment={"XDG_STATE_HOME": "relative"},
        ),
        "journal-root-invalid",
    )
    rejected(
        lambda: resolve_journal_location(
            root,
            plan["plan_digest"],
            environment={"HOME": ""},
        ),
        "journal-root-invalid",
    )

    result = execute_upgrade(
        plan,
        location,
        plan_source_digest=plan_source_digest,
        updated_at="2026-07-11T00:01:00Z",
        validate_after=passed_validation,
    )
    assert validate_result(result) == result
    assert result["changed"] is True
    assert result["applied"] == [{
        "op": "update",
        "path": ".workbench/schema",
        "before_digest": first["effects"][0]["before"]["digest"],
        "after_digest": first["effects"][0]["after"]["digest"],
    }]
    assert (root / ".workbench/schema").read_bytes() == after
    completed = load_journal(location, plan)
    assert completed["stage"] == "completed"
    assert completed["cursor"] == 1
    replay = execute_upgrade(
        plan,
        location,
        plan_source_digest=plan_source_digest,
        updated_at="2026-07-11T00:02:00Z",
        validate_after=passed_validation,
    )
    assert validate_result(replay) == replay
    assert replay["changed"] is False
    assert replay["applied"] == []
    assert replay["transaction"]["resumed"] is True

    crash_root = pathlib.Path(temporary) / "crash-workbench"
    crash_root.mkdir()
    crash_root = crash_root.resolve()
    crash_plan, crash_before, crash_after = fixture_plan(crash_root)
    crash_journal = build_prepared_journal(
        crash_plan,
        canonical_digest(canonical_bytes(crash_plan), raw=True),
        CREATED_AT,
    )
    crash_location = resolve_journal_location(
        crash_root,
        crash_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(crash_journal, crash_location)

    class Crash(BaseException):
        pass

    def crash_after_effect(point, effect, direction):
        if point == "after-effect" and direction == "forward":
            raise Crash()

    try:
        execute_upgrade(
            crash_plan,
            crash_location,
            plan_source_digest=canonical_digest(
                canonical_bytes(crash_plan), raw=True
            ),
            updated_at="2026-07-11T00:03:00Z",
            validate_after=passed_validation,
            fault_hook=crash_after_effect,
        )
    except Crash:
        pass
    else:
        raise AssertionError("fault after effect did not interrupt execution")
    assert (crash_root / ".workbench/schema").read_bytes() == crash_after
    interrupted = load_journal(crash_location, crash_plan)
    assert interrupted["stage"] == "applying"
    assert interrupted["cursor"] == 0
    resumed = execute_upgrade(
        crash_plan,
        crash_location,
        plan_source_digest=canonical_digest(canonical_bytes(crash_plan), raw=True),
        updated_at="2026-07-11T00:04:00Z",
        validate_after=passed_validation,
    )
    assert resumed["changed"] is True
    assert resumed["transaction"]["resumed"] is True
    assert (crash_root / ".workbench/schema").read_bytes() == crash_after

    mixed_root = pathlib.Path(temporary) / "mixed-workbench"
    mixed_root.mkdir()
    mixed_root = mixed_root.resolve()
    mixed_plan, _, _ = fixture_plan(mixed_root)
    mixed_journal = build_prepared_journal(
        mixed_plan,
        canonical_digest(canonical_bytes(mixed_plan), raw=True),
        CREATED_AT,
    )
    mixed_location = resolve_journal_location(
        mixed_root,
        mixed_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(mixed_journal, mixed_location)
    (mixed_root / ".workbench/schema").write_bytes(b"unexpected\n")
    journal_bytes = mixed_location["journal"].read_bytes()
    rejected(
        lambda: execute_upgrade(
            mixed_plan,
            mixed_location,
            plan_source_digest=canonical_digest(
                canonical_bytes(mixed_plan), raw=True
            ),
            updated_at="2026-07-11T00:05:00Z",
            validate_after=passed_validation,
        ),
        "transaction-state-mismatch",
    )
    assert mixed_location["journal"].read_bytes() == journal_bytes
    assert (mixed_root / ".workbench/schema").read_bytes() == b"unexpected\n"

    rollback_root = pathlib.Path(temporary) / "rollback-workbench"
    rollback_root.mkdir()
    rollback_root = rollback_root.resolve()
    rollback_plan, rollback_before, _ = fixture_plan(rollback_root)
    rollback_journal = build_prepared_journal(
        rollback_plan,
        canonical_digest(canonical_bytes(rollback_plan), raw=True),
        CREATED_AT,
    )
    rollback_location = resolve_journal_location(
        rollback_root,
        rollback_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(rollback_journal, rollback_location)
    failed_once = False

    def fail_after_effect(point, effect, direction):
        global failed_once
        if point == "after-effect" and direction == "forward" and not failed_once:
            failed_once = True
            raise RuntimeError("injected apply failure")

    rolled_back = execute_upgrade(
        rollback_plan,
        rollback_location,
        plan_source_digest=canonical_digest(
            canonical_bytes(rollback_plan), raw=True
        ),
        updated_at="2026-07-11T00:06:00Z",
        validate_after=passed_validation,
        fault_hook=fail_after_effect,
    )
    assert validate_result(rolled_back) == rolled_back
    assert rolled_back["transaction"]["stage"] == "rolled-back"
    assert rolled_back["changed"] is False
    assert rolled_back["blockers"] == [{
        "code": "apply-effect-failed",
        "ref": ".workbench/schema",
    }]
    assert (rollback_root / ".workbench/schema").read_bytes() == rollback_before
    terminal_rollback = load_journal(rollback_location, rollback_plan)
    assert terminal_rollback["stage"] == "rolled-back"

    stale_root = pathlib.Path(temporary) / "stale-preserved-workbench"
    stale_root.mkdir()
    stale_root = stale_root.resolve()
    stale_plan, _, _ = fixture_plan(stale_root)
    stale_source_digest = canonical_digest(canonical_bytes(stale_plan), raw=True)
    stale_journal = build_prepared_journal(
        stale_plan, stale_source_digest, CREATED_AT
    )
    stale_location = resolve_journal_location(
        stale_root,
        stale_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(stale_journal, stale_location)
    stale_bytes = stale_location["journal"].read_bytes()
    (stale_root / "user.txt").write_bytes(b"changed after plan\n")
    rejected(
        lambda: execute_upgrade(
            stale_plan,
            stale_location,
            plan_source_digest=stale_source_digest,
            updated_at="2026-07-11T00:07:00Z",
            validate_after=passed_validation,
        ),
        "preserved-node-stale",
    )
    assert stale_location["journal"].read_bytes() == stale_bytes
    rejected(
        lambda: execute_upgrade(
            stale_plan,
            stale_location,
            plan_source_digest="sha256:" + "f" * 64,
            updated_at="2026-07-11T00:07:00Z",
            validate_after=passed_validation,
        ),
        "plan-source-stale",
    )

    create_root = pathlib.Path(temporary) / "create-workbench"
    create_root.mkdir()
    create_root = create_root.resolve()
    create_plan, create_after = fixture_create_plan(create_root)
    create_source_digest = canonical_digest(canonical_bytes(create_plan), raw=True)
    create_journal = build_prepared_journal(
        create_plan, create_source_digest, CREATED_AT
    )
    assert [effect["kind"] for effect in create_journal["effects"]] == [
        "ensure-directory", "create",
    ]
    create_location = resolve_journal_location(
        create_root,
        create_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(create_journal, create_location)
    failed_forward = False

    def crash_during_rollback(point, effect, direction):
        global failed_forward
        if point != "after-effect":
            return
        if direction == "forward" and effect["kind"] == "create":
            failed_forward = True
            raise RuntimeError("start rollback")
        if direction == "reverse" and effect["kind"] == "create":
            raise Crash()

    try:
        execute_upgrade(
            create_plan,
            create_location,
            plan_source_digest=create_source_digest,
            updated_at="2026-07-11T00:08:00Z",
            validate_after=passed_validation,
            fault_hook=crash_during_rollback,
        )
    except Crash:
        pass
    else:
        raise AssertionError("rollback crash was not injected")
    assert failed_forward is True
    interrupted_rollback = load_journal(create_location, create_plan)
    assert interrupted_rollback["stage"] == "rolling-back"
    assert interrupted_rollback["cursor"] == 2
    assert (create_root / ".workbench").is_dir()
    assert not (create_root / ".workbench/schema").exists()
    recovered_rollback = execute_upgrade(
        create_plan,
        create_location,
        plan_source_digest=create_source_digest,
        updated_at="2026-07-11T00:09:00Z",
        validate_after=passed_validation,
    )
    assert recovered_rollback["transaction"]["stage"] == "rolled-back"
    assert not (create_root / ".workbench").exists()

    lock_root = pathlib.Path(temporary) / "locked-workbench"
    lock_root.mkdir()
    lock_root = lock_root.resolve()
    lock_plan, _, _ = fixture_plan(lock_root)
    lock_source_digest = canonical_digest(canonical_bytes(lock_plan), raw=True)
    lock_journal = build_prepared_journal(
        lock_plan, lock_source_digest, CREATED_AT
    )
    lock_location = resolve_journal_location(
        lock_root,
        lock_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(lock_journal, lock_location)
    context = multiprocessing.get_context("fork")
    ready_parent, ready_child = context.Pipe(duplex=False)
    release_child, release_parent = context.Pipe(duplex=False)
    process = context.Process(
        target=hold_workspace_lock,
        args=(str(lock_root), ready_child, release_child),
    )
    process.start()
    assert ready_parent.recv() is True
    locked_bytes = lock_location["journal"].read_bytes()
    try:
        rejected(
            lambda: execute_upgrade(
                lock_plan,
                lock_location,
                plan_source_digest=lock_source_digest,
                updated_at="2026-07-11T00:10:00Z",
                validate_after=passed_validation,
            ),
            "apply-in-progress",
        )
    finally:
        release_parent.send(True)
        process.join(5)
        assert process.exitcode == 0
    assert lock_location["journal"].read_bytes() == locked_bytes

    temp_root = pathlib.Path(temporary) / "temp-crash-workbench"
    temp_root.mkdir()
    temp_root = temp_root.resolve()
    temp_plan, _, temp_after = fixture_plan(temp_root)
    temp_source_digest = canonical_digest(canonical_bytes(temp_plan), raw=True)
    temp_journal = build_prepared_journal(
        temp_plan, temp_source_digest, CREATED_AT
    )
    temp_location = resolve_journal_location(
        temp_root,
        temp_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(temp_journal, temp_location)

    def crash_after_temp_fsync(point, effect, direction):
        if point == "after-temp-fsync" and direction == "forward":
            raise Crash()

    try:
        execute_upgrade(
            temp_plan,
            temp_location,
            plan_source_digest=temp_source_digest,
            updated_at="2026-07-11T00:11:00Z",
            validate_after=passed_validation,
            fault_hook=crash_after_temp_fsync,
        )
    except Crash:
        pass
    else:
        raise AssertionError("temp fsync crash was not injected")
    temp_effect_path = temp_root / temp_journal["effects"][0]["temp_path"]
    assert temp_effect_path.is_file()
    assert (temp_root / ".workbench/schema").read_bytes() != temp_after
    temp_resumed = execute_upgrade(
        temp_plan,
        temp_location,
        plan_source_digest=temp_source_digest,
        updated_at="2026-07-11T00:12:00Z",
        validate_after=passed_validation,
    )
    assert temp_resumed["transaction"]["resumed"] is True
    assert not temp_effect_path.exists()
    assert (temp_root / ".workbench/schema").read_bytes() == temp_after

    link_root = pathlib.Path(temporary) / "link-crash-workbench"
    link_root.mkdir()
    link_root = link_root.resolve()
    link_plan, link_after = fixture_create_plan(link_root)
    link_source_digest = canonical_digest(canonical_bytes(link_plan), raw=True)
    link_journal = build_prepared_journal(
        link_plan, link_source_digest, CREATED_AT
    )
    link_location = resolve_journal_location(
        link_root,
        link_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(link_journal, link_location)

    def crash_after_target_install(point, effect, direction):
        if (
            point == "after-target-install"
            and direction == "forward"
            and effect["kind"] == "create"
        ):
            raise Crash()

    try:
        execute_upgrade(
            link_plan,
            link_location,
            plan_source_digest=link_source_digest,
            updated_at="2026-07-11T00:13:00Z",
            validate_after=passed_validation,
            fault_hook=crash_after_target_install,
        )
    except Crash:
        pass
    else:
        raise AssertionError("target install crash was not injected")
    link_temp = link_root / link_journal["effects"][1]["temp_path"]
    link_target = link_root / ".workbench/schema"
    assert link_temp.is_file() and link_target.is_file()
    assert os.lstat(link_temp).st_ino == os.lstat(link_target).st_ino
    assert os.lstat(link_temp).st_nlink == 2
    link_resumed = execute_upgrade(
        link_plan,
        link_location,
        plan_source_digest=link_source_digest,
        updated_at="2026-07-11T00:14:00Z",
        validate_after=passed_validation,
    )
    assert link_resumed["transaction"]["resumed"] is True
    assert not link_temp.exists()
    assert link_target.read_bytes() == link_after

    unsafe_temp_root = pathlib.Path(temporary) / "unsafe-temp-workbench"
    unsafe_temp_root.mkdir()
    unsafe_temp_root = unsafe_temp_root.resolve()
    unsafe_temp_plan, _, _ = fixture_plan(unsafe_temp_root)
    unsafe_temp_source = canonical_digest(
        canonical_bytes(unsafe_temp_plan), raw=True
    )
    unsafe_temp_journal = build_prepared_journal(
        unsafe_temp_plan, unsafe_temp_source, CREATED_AT
    )
    unsafe_temp_location = resolve_journal_location(
        unsafe_temp_root,
        unsafe_temp_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(unsafe_temp_journal, unsafe_temp_location)
    unsafe_temp = unsafe_temp_root / unsafe_temp_journal["effects"][0]["temp_path"]
    unsafe_temp.symlink_to("schema")
    rejected(
        lambda: execute_upgrade(
            unsafe_temp_plan,
            unsafe_temp_location,
            plan_source_digest=unsafe_temp_source,
            updated_at="2026-07-11T00:15:00Z",
            validate_after=passed_validation,
        ),
        "transaction-state-mismatch",
    )
    assert unsafe_temp.is_symlink()

    removal_root = pathlib.Path(temporary) / "removal-workbench"
    removal_root.mkdir()
    removal_root = removal_root.resolve()
    removal_plan, engine_bytes = fixture_removal_plan(removal_root)
    removal_source = canonical_digest(canonical_bytes(removal_plan), raw=True)
    removal_journal = build_prepared_journal(
        removal_plan, removal_source, CREATED_AT
    )
    removal_location = resolve_journal_location(
        removal_root,
        removal_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(removal_journal, removal_location)
    removal_failed = False

    def fail_after_removal(point, effect, direction):
        global removal_failed
        if point == "after-effect" and direction == "forward" and not removal_failed:
            removal_failed = True
            raise RuntimeError("rollback removal")

    removal_rollback = execute_upgrade(
        removal_plan,
        removal_location,
        plan_source_digest=removal_source,
        updated_at="2026-07-11T00:16:00Z",
        validate_after=lambda current: {
            **passed_validation(current),
            "basis_kind": "removal-plan",
            "basis_digest": current["removal_plan_basis_digest"],
            "digest": None,
        },
        fault_hook=fail_after_removal,
    )
    assert removal_rollback["transaction"]["stage"] == "rolled-back"
    restored_engine = removal_root / "legacy-engine/task"
    assert restored_engine.read_bytes() == engine_bytes
    assert stat.S_IMODE(os.lstat(restored_engine).st_mode) == 0o755

    validation_root = pathlib.Path(temporary) / "validation-workbench"
    validation_root.mkdir()
    validation_root = validation_root.resolve()
    validation_plan, validation_before, _ = fixture_plan(validation_root)
    validation_source = canonical_digest(
        canonical_bytes(validation_plan), raw=True
    )
    validation_journal = build_prepared_journal(
        validation_plan, validation_source, CREATED_AT
    )
    validation_location = resolve_journal_location(
        validation_root,
        validation_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(validation_journal, validation_location)

    def failed_validation(_plan):
        validation = {
            "status": "failed",
            "classification_after": None,
            "basis_kind": None,
            "basis_digest": None,
            "blockers": [{
                "code": "candidate-static-invalid",
                "ref": ".workbench/schema",
            }],
            "digest": None,
        }
        validation["digest"] = canonical_digest(
            validation, null_field="digest"
        )
        return validation

    validation_rollback = execute_upgrade(
        validation_plan,
        validation_location,
        plan_source_digest=validation_source,
        updated_at="2026-07-11T00:17:00Z",
        validate_after=failed_validation,
    )
    assert validation_rollback["transaction"]["stage"] == "rolled-back"
    assert validation_rollback["blockers"] == [{
        "code": "candidate-static-invalid",
        "ref": ".workbench/schema",
    }]
    assert (validation_root / ".workbench/schema").read_bytes() == validation_before

print("PASS: deterministic full-preimage upgrade journal preparation")
PY
