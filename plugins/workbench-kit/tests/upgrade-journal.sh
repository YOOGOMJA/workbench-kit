#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
import copy
import fcntl
import multiprocessing
import pathlib
import os
import pwd
import stat
import sys
import tempfile

sys.path.insert(0, sys.argv[1])

import workbench_kit_journal as journal_module
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
    build_prepared_journal as _build_prepared_journal,
    execute_upgrade,
    install_prepared_journal as _install_prepared_journal,
    load_journal,
    resolve_journal_location,
)


OID = "1" * 40
SHA = "sha256:" + "a" * 64
CREATED_AT = "2026-07-11T00:00:00Z"
PLANS_BY_DIGEST = {}


def build_prepared_journal(plan, plan_source_digest, created_at):
    journal = _build_prepared_journal(
        plan, plan_source_digest, created_at
    )
    PLANS_BY_DIGEST[journal["plan_digest"]] = plan
    return journal


def install_prepared_journal(journal, location):
    return _install_prepared_journal(
        journal, location, PLANS_BY_DIGEST[journal["plan_digest"]]
    )


def rejected(callable_, code):
    try:
        callable_()
    except JournalError as error:
        assert error.code == code, (error.code, code)
        return
    raise AssertionError(code)


def fixture_plan(root):
    if not (root / ".git").exists():
        (root / ".git").mkdir()
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


def passed_removal_validation(plan):
    validation = {
        "status": "passed",
        "classification_after": plan["target_classification"],
        "basis_kind": "removal-plan",
        "basis_digest": plan["removal_plan_basis_digest"],
        "blockers": [],
        "digest": None,
    }
    validation["digest"] = canonical_digest(
        validation, null_field="digest"
    )
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


def fixture_noop_plan(root):
    plan, before, _ = fixture_plan(root)
    plan["plan_digest"] = None
    plan["preserved"] = sorted(
        plan["preserved"] + [{
            "path": ".workbench/schema",
            "node_type": "file",
            "mode": "100644",
            "digest": node_digest("file", "100644", content=before),
            "link_target": None,
        }],
        key=lambda item: item["path"],
    )
    plan["parent_directories"] = []
    plan["artifacts"] = []
    plan["operations"] = []
    plan["changed"] = False
    plan["actionable"] = False
    plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
    return validate_plan(plan)


def hold_workspace_lock(path, ready, release):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        ready.send(True)
        release.recv()
    finally:
        os.close(descriptor)


with tempfile.TemporaryDirectory(prefix="workbench-journal-") as temporary:
    system_account_home = pathlib.Path(
        pwd.getpwuid(os.getuid()).pw_dir
    ).resolve()
    assert journal_module._account_home() == system_account_home
    account_home = pathlib.Path(temporary) / "account-home"
    account_home.mkdir(mode=0o700)
    account_home = account_home.resolve()
    journal_module._account_home = lambda: account_home

    root = pathlib.Path(temporary) / "workbench"
    root.mkdir()
    root = root.resolve()
    plan, before, after = fixture_plan(root)
    raw_plan = canonical_bytes(plan)
    plan_source_digest = canonical_digest(raw_plan, raw=True)
    first = build_prepared_journal(plan, plan_source_digest, CREATED_AT)
    second = build_prepared_journal(plan, plan_source_digest, CREATED_AT)
    assert journal_module._maximum_lifecycle_journal_size(
        first, plan
    ) > len(canonical_bytes(first))
    assert journal_module.MAX_JOURNAL_BYTES == 64 * 1024 * 1024
    journal_module._require_journal_size(
        journal_module.MAX_JOURNAL_BYTES - 1, "below-limit"
    )
    journal_module._require_journal_size(
        journal_module.MAX_JOURNAL_BYTES, "at-limit"
    )
    rejected(
        lambda: journal_module._require_journal_size(
            journal_module.MAX_JOURNAL_BYTES + 1, "above-limit"
        ),
        "journal-too-large",
    )
    assert journal_module._timestamp_prefix_valid(b"2026-07")
    assert journal_module._timestamp_prefix_valid(
        b"2026-07-11T00:20:55.123Z"
    )
    assert journal_module._timestamp_prefix_valid(
        b"2024-02-29T00:20:55Z"
    )
    assert not journal_module._timestamp_prefix_valid(b"2026-19")
    assert not journal_module._timestamp_prefix_valid(
        b"2026-07-11T29"
    )
    assert not journal_module._timestamp_prefix_valid(
        b"2026-02-31T00:20:55Z"
    )
    assert not journal_module._timestamp_prefix_valid(
        b"2026-02-29T00:20:55Z"
    )
    invalid_calendar_successor = copy.deepcopy(first)
    invalid_calendar_successor["updated_at"] = "2026-02-31T00:20:55Z"
    assert not journal_module._replacement_prefix_matches(
        canonical_bytes(invalid_calendar_successor), first, plan
    )
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
    assert location["owner"] == (
        account_home
        / ".local/state/workbench-kit/upgrade-coordination"
        / first["workspace_id"]
        / "owner.json"
    )
    original_journal_limit = journal_module.MAX_JOURNAL_BYTES
    try:
        for admitted_limit in (
            len(canonical_bytes(first)) - 1,
            len(canonical_bytes(first)),
        ):
            journal_module.MAX_JOURNAL_BYTES = admitted_limit
            rejected(
                lambda: build_prepared_journal(
                    plan, plan_source_digest, CREATED_AT
                ),
                "journal-too-large",
            )
            rejected(
                lambda: install_prepared_journal(first, location),
                "journal-too-large",
            )
            assert not location["owner"].exists()
            assert not location["journal"].exists()
    finally:
        journal_module.MAX_JOURNAL_BYTES = original_journal_limit
    assert not location["owner"].exists()
    assert not location["journal"].exists()

    exact_root = pathlib.Path(temporary) / "exact-limit-workbench"
    exact_root.mkdir()
    exact_root = exact_root.resolve()
    exact_plan, _, exact_after = fixture_plan(exact_root)
    exact_source = canonical_digest(canonical_bytes(exact_plan), raw=True)
    exact_journal = build_prepared_journal(
        exact_plan, exact_source, CREATED_AT
    )
    exact_location = resolve_journal_location(
        exact_root,
        exact_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    exact_limit = journal_module._maximum_lifecycle_journal_size(
        exact_journal, exact_plan
    )
    journal_module.MAX_JOURNAL_BYTES = exact_limit
    try:
        install_prepared_journal(exact_journal, exact_location)
        exact_result = execute_upgrade(
            exact_plan,
            exact_location,
            plan_source_digest=exact_source,
            updated_at="2026-07-11T00:00:30Z",
            validate_after=passed_validation,
        )
        exact_replay = execute_upgrade(
            exact_plan,
            exact_location,
            plan_source_digest=exact_source,
            updated_at="2026-07-11T00:00:45Z",
            validate_after=passed_validation,
        )
    finally:
        journal_module.MAX_JOURNAL_BYTES = original_journal_limit
    assert exact_result["transaction"]["stage"] == "completed"
    assert exact_result["changed"] is True
    assert exact_replay["transaction"]["stage"] == "completed"
    assert exact_replay["changed"] is False
    assert (exact_root / ".workbench/schema").read_bytes() == exact_after
    assert len(exact_location["journal"].read_bytes()) <= exact_limit

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
    xdg_workspace = pathlib.Path(temporary) / "xdg-workbench"
    xdg_workspace.mkdir()
    xdg_workspace = xdg_workspace.resolve()
    xdg_plan, _, _ = fixture_plan(xdg_workspace)
    default_location = resolve_journal_location(
        xdg_workspace,
        xdg_plan["plan_digest"],
        environment={"XDG_STATE_HOME": str(xdg)},
    )
    assert default_location["root"] == xdg / "workbench-kit/upgrades"
    assert stat.S_IMODE(os.lstat(default_location["root"]).st_mode) == 0o700
    rejected(
        lambda: resolve_journal_location(
            xdg_workspace,
            xdg_plan["plan_digest"],
            environment={"XDG_STATE_HOME": "relative"},
        ),
        "journal-root-invalid",
    )
    rejected(
        lambda: resolve_journal_location(
            xdg_workspace,
            xdg_plan["plan_digest"],
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
    completed_foreign_temp = root / first["effects"][0]["temp_path"]
    completed_foreign_temp.write_bytes(before)
    completed_foreign_temp.chmod(0o644)
    rejected(
        lambda: execute_upgrade(
            plan,
            location,
            plan_source_digest=plan_source_digest,
            updated_at="2026-07-11T00:01:30Z",
            validate_after=passed_validation,
        ),
        "transaction-state-mismatch",
    )
    assert completed_foreign_temp.read_bytes() == before
    completed_foreign_temp.unlink()
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
    rollback_foreign_temp = (
        rollback_root / rollback_journal["effects"][0]["temp_path"]
    )
    rollback_after = base64.b64decode(
        rollback_journal["effects"][0]["after"]["content_base64"],
        validate=True,
    )
    rollback_foreign_temp.write_bytes(rollback_after)
    rollback_foreign_temp.chmod(0o644)
    rejected(
        lambda: execute_upgrade(
            rollback_plan,
            rollback_location,
            plan_source_digest=canonical_digest(
                canonical_bytes(rollback_plan), raw=True
            ),
            updated_at="2026-07-11T00:06:30Z",
            validate_after=passed_validation,
        ),
        "transaction-state-mismatch",
    )
    assert rollback_foreign_temp.read_bytes() == rollback_after
    rollback_foreign_temp.unlink()
    rollback_replay = execute_upgrade(
        rollback_plan,
        rollback_location,
        plan_source_digest=canonical_digest(
            canonical_bytes(rollback_plan), raw=True
        ),
        updated_at="2026-07-11T00:06:45Z",
        validate_after=passed_validation,
    )
    assert rollback_replay["transaction"]["stage"] == "rolled-back"
    assert rollback_replay["transaction"]["resumed"] is True

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

    preclaimed_root = pathlib.Path(temporary) / "preclaimed-temp-workbench"
    preclaimed_root.mkdir()
    preclaimed_root = preclaimed_root.resolve()
    preclaimed_plan, _, _ = fixture_plan(preclaimed_root)
    preclaimed_journal_id = (
        "upgrade-" + preclaimed_plan["plan_digest"].removeprefix("sha256:")
    )
    preclaimed_temp = (
        preclaimed_root
        / ".workbench"
        / (
            ".workbench-kit."
            + preclaimed_journal_id
            + ".effect-0001.tmp"
        )
    )
    preclaimed_temp.write_bytes(b"")
    preclaimed_temp.chmod(0o600)
    rejected(
        lambda: build_prepared_journal(
            preclaimed_plan,
            canonical_digest(canonical_bytes(preclaimed_plan), raw=True),
            CREATED_AT,
        ),
        "operation-temp-stale",
    )
    assert preclaimed_temp.read_bytes() == b""

    prepared_temp_root = pathlib.Path(temporary) / "prepared-temp-workbench"
    prepared_temp_root.mkdir()
    prepared_temp_root = prepared_temp_root.resolve()
    prepared_temp_plan, prepared_temp_before, _ = fixture_plan(
        prepared_temp_root
    )
    prepared_temp_source = canonical_digest(
        canonical_bytes(prepared_temp_plan), raw=True
    )
    prepared_temp_journal = build_prepared_journal(
        prepared_temp_plan, prepared_temp_source, CREATED_AT
    )
    prepared_temp_location = resolve_journal_location(
        prepared_temp_root,
        prepared_temp_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(
        prepared_temp_journal, prepared_temp_location
    )
    prepared_temp = (
        prepared_temp_root
        / prepared_temp_journal["effects"][0]["temp_path"]
    )
    prepared_temp.write_bytes(b"")
    prepared_temp.chmod(0o600)
    rejected(
        lambda: execute_upgrade(
            prepared_temp_plan,
            prepared_temp_location,
            plan_source_digest=prepared_temp_source,
            updated_at="2026-07-11T00:12:15Z",
            validate_after=passed_validation,
        ),
        "operation-temp-stale",
    )
    assert prepared_temp.read_bytes() == b""
    assert load_journal(
        prepared_temp_location, prepared_temp_plan
    )["stage"] == "prepared"
    assert (
        prepared_temp_root / ".workbench/schema"
    ).read_bytes() == prepared_temp_before

    temp_failure_root = pathlib.Path(temporary) / "temp-failure-workbench"
    temp_failure_root.mkdir()
    temp_failure_root = temp_failure_root.resolve()
    temp_failure_plan, temp_failure_before, _ = fixture_plan(
        temp_failure_root
    )
    temp_failure_source = canonical_digest(
        canonical_bytes(temp_failure_plan), raw=True
    )
    temp_failure_journal = build_prepared_journal(
        temp_failure_plan, temp_failure_source, CREATED_AT
    )
    temp_failure_location = resolve_journal_location(
        temp_failure_root,
        temp_failure_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(temp_failure_journal, temp_failure_location)
    failed_temp_create = False

    def fail_after_temp_create(point, _effect, direction):
        global failed_temp_create
        if (
            point == "after-temp-create"
            and direction == "forward"
            and not failed_temp_create
        ):
            failed_temp_create = True
            raise OSError("injected temp construction failure")

    temp_failure_result = execute_upgrade(
        temp_failure_plan,
        temp_failure_location,
        plan_source_digest=temp_failure_source,
        updated_at="2026-07-11T00:12:30Z",
        validate_after=passed_validation,
        fault_hook=fail_after_temp_create,
    )
    assert temp_failure_result["transaction"]["stage"] == "rolled-back"
    temp_failure_temp = (
        temp_failure_root
        / temp_failure_journal["effects"][0]["temp_path"]
    )
    assert not temp_failure_temp.exists()
    assert (
        temp_failure_root / ".workbench/schema"
    ).read_bytes() == temp_failure_before
    temp_failure_replay = execute_upgrade(
        temp_failure_plan,
        temp_failure_location,
        plan_source_digest=temp_failure_source,
        updated_at="2026-07-11T00:12:45Z",
        validate_after=passed_validation,
    )
    assert temp_failure_replay["transaction"]["stage"] == "rolled-back"
    assert temp_failure_replay["transaction"]["resumed"] is True

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
        "operation-temp-stale",
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
        validate_after=passed_removal_validation,
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

    validation_budget_root = (
        pathlib.Path(temporary) / "validation-budget-workbench"
    )
    validation_budget_root.mkdir()
    validation_budget_root = validation_budget_root.resolve()
    validation_budget_plan, validation_budget_before, _ = fixture_plan(
        validation_budget_root
    )
    validation_budget_source = canonical_digest(
        canonical_bytes(validation_budget_plan), raw=True
    )
    validation_budget_journal = build_prepared_journal(
        validation_budget_plan, validation_budget_source, CREATED_AT
    )
    validation_budget_location = resolve_journal_location(
        validation_budget_root,
        validation_budget_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    validation_budget_limit = (
        journal_module._maximum_lifecycle_journal_size(
            validation_budget_journal, validation_budget_plan
        )
    )

    def oversized_failed_validation(_plan):
        validation = {
            "status": "failed",
            "classification_after": None,
            "basis_kind": None,
            "basis_digest": None,
            "blockers": [{
                "code": "candidate-static-invalid",
                "ref": "x" * validation_budget_limit,
            }],
            "digest": None,
        }
        validation["digest"] = canonical_digest(
            validation, null_field="digest"
        )
        return validation

    original_journal_limit = journal_module.MAX_JOURNAL_BYTES
    journal_module.MAX_JOURNAL_BYTES = validation_budget_limit
    try:
        install_prepared_journal(
            validation_budget_journal, validation_budget_location
        )
        validation_budget_result = execute_upgrade(
            validation_budget_plan,
            validation_budget_location,
            plan_source_digest=validation_budget_source,
            updated_at="2026-07-11T00:17:15Z",
            validate_after=oversized_failed_validation,
        )
    finally:
        journal_module.MAX_JOURNAL_BYTES = original_journal_limit
    assert validation_budget_result["transaction"]["stage"] == "rolled-back"
    assert validation_budget_result["blockers"] == [{
        "code": "candidate-validation-too-large",
        "ref": str(validation_budget_root),
    }]
    assert (
        validation_budget_root / ".workbench/schema"
    ).read_bytes() == validation_budget_before

    validation_edit_root = (
        pathlib.Path(temporary) / "validation-edit-workbench"
    )
    validation_edit_root.mkdir()
    validation_edit_root = validation_edit_root.resolve()
    (
        validation_edit_plan,
        _,
        validation_edit_after,
    ) = fixture_plan(validation_edit_root)
    validation_edit_source = canonical_digest(
        canonical_bytes(validation_edit_plan), raw=True
    )
    validation_edit_journal = build_prepared_journal(
        validation_edit_plan, validation_edit_source, CREATED_AT
    )
    validation_edit_location = resolve_journal_location(
        validation_edit_root,
        validation_edit_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(
        validation_edit_journal, validation_edit_location
    )

    def edit_after_validation(point, _effect, direction):
        if point == "after-validation" and direction == "forward":
            (validation_edit_root / ".workbench/schema").write_bytes(
                b"edit after validation\n"
            )

    rejected(
        lambda: execute_upgrade(
            validation_edit_plan,
            validation_edit_location,
            plan_source_digest=validation_edit_source,
            updated_at="2026-07-11T00:17:30Z",
            validate_after=passed_validation,
            fault_hook=edit_after_validation,
        ),
        "transaction-state-mismatch",
    )
    assert load_journal(
        validation_edit_location, validation_edit_plan
    )["stage"] == "validating"
    assert validation_edit_location["owner"].is_file()
    assert (
        validation_edit_root / ".workbench/schema"
    ).read_bytes() == b"edit after validation\n"
    (validation_edit_root / ".workbench/schema").write_bytes(
        validation_edit_after
    )
    validation_edit_replay = execute_upgrade(
        validation_edit_plan,
        validation_edit_location,
        plan_source_digest=validation_edit_source,
        updated_at="2026-07-11T00:17:45Z",
        validate_after=passed_validation,
    )
    assert validation_edit_replay["transaction"]["stage"] == "completed"

    reverse_root = pathlib.Path(temporary) / "reverse-temp-workbench"
    reverse_root.mkdir()
    reverse_root = reverse_root.resolve()
    reverse_plan, reverse_before, _ = fixture_plan(reverse_root)
    reverse_source = canonical_digest(canonical_bytes(reverse_plan), raw=True)
    reverse_journal = build_prepared_journal(
        reverse_plan, reverse_source, CREATED_AT
    )
    reverse_location = resolve_journal_location(
        reverse_root,
        reverse_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(reverse_journal, reverse_location)
    reverse_forward_failed = False

    def crash_reverse_temp(point, effect, direction):
        global reverse_forward_failed
        if point == "after-effect" and direction == "forward":
            reverse_forward_failed = True
            raise RuntimeError("start reverse")
        if point == "after-temp-fsync" and direction == "reverse":
            raise Crash()

    try:
        execute_upgrade(
            reverse_plan,
            reverse_location,
            plan_source_digest=reverse_source,
            updated_at="2026-07-11T00:18:00Z",
            validate_after=passed_validation,
            fault_hook=crash_reverse_temp,
        )
    except Crash:
        pass
    else:
        raise AssertionError("reverse temp crash was not injected")
    assert reverse_forward_failed is True
    reverse_interrupted = load_journal(reverse_location, reverse_plan)
    assert reverse_interrupted["stage"] == "rolling-back"
    reverse_temp = reverse_root / reverse_journal["effects"][0]["temp_path"]
    assert reverse_temp.is_file()
    reverse_recovered = execute_upgrade(
        reverse_plan,
        reverse_location,
        plan_source_digest=reverse_source,
        updated_at="2026-07-11T00:19:00Z",
        validate_after=passed_validation,
    )
    assert reverse_recovered["transaction"]["stage"] == "rolled-back"
    assert not reverse_temp.exists()
    assert (reverse_root / ".workbench/schema").read_bytes() == reverse_before

    replace_root = pathlib.Path(temporary) / "replace-temp-workbench"
    replace_root.mkdir()
    replace_root = replace_root.resolve()
    replace_plan, _, replace_after = fixture_plan(replace_root)
    replace_source = canonical_digest(canonical_bytes(replace_plan), raw=True)
    replace_journal = build_prepared_journal(
        replace_plan, replace_source, CREATED_AT
    )
    replace_location = resolve_journal_location(
        replace_root,
        replace_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(replace_journal, replace_location)
    replace_location["replace_temp"].write_bytes(
        replace_location["journal"].read_bytes()
    )
    replace_location["replace_temp"].chmod(0o600)
    replace_recovered = execute_upgrade(
        replace_plan,
        replace_location,
        plan_source_digest=replace_source,
        updated_at="2026-07-11T00:20:00Z",
        validate_after=passed_validation,
    )
    assert replace_recovered["transaction"]["stage"] == "completed"
    assert not replace_location["replace_temp"].exists()
    assert (replace_root / ".workbench/schema").read_bytes() == replace_after

    foreign_replace_root = pathlib.Path(temporary) / "foreign-replace-workbench"
    foreign_replace_root.mkdir()
    foreign_replace_root = foreign_replace_root.resolve()
    foreign_replace_plan, foreign_replace_before, _ = fixture_plan(
        foreign_replace_root
    )
    foreign_replace_source = canonical_digest(
        canonical_bytes(foreign_replace_plan), raw=True
    )
    foreign_replace_journal = build_prepared_journal(
        foreign_replace_plan, foreign_replace_source, CREATED_AT
    )
    foreign_replace_location = resolve_journal_location(
        foreign_replace_root,
        foreign_replace_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(
        foreign_replace_journal, foreign_replace_location
    )
    foreign_replace_location["replace_temp"].write_bytes(
        b"foreign replace journal"
    )
    foreign_replace_location["replace_temp"].chmod(0o600)
    rejected(
        lambda: execute_upgrade(
            foreign_replace_plan,
            foreign_replace_location,
            plan_source_digest=foreign_replace_source,
            updated_at="2026-07-11T00:20:30Z",
            validate_after=passed_validation,
        ),
        "journal-unsafe",
    )
    assert foreign_replace_location["replace_temp"].read_bytes() == (
        b"foreign replace journal"
    )
    assert (
        foreign_replace_root / ".workbench/schema"
    ).read_bytes() == foreign_replace_before

    exchange_root = pathlib.Path(temporary) / "exchange-crash-workbench"
    exchange_root.mkdir()
    exchange_root = exchange_root.resolve()
    exchange_plan, _, exchange_after = fixture_plan(exchange_root)
    exchange_source = canonical_digest(
        canonical_bytes(exchange_plan), raw=True
    )
    exchange_journal = build_prepared_journal(
        exchange_plan, exchange_source, CREATED_AT
    )
    exchange_location = resolve_journal_location(
        exchange_root,
        exchange_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(exchange_journal, exchange_location)
    original_exchange = journal_module._rename_exchange
    exchange_interrupted = False

    def crash_after_journal_exchange(directory_fd, first_name, second_name):
        global exchange_interrupted
        original_exchange(directory_fd, first_name, second_name)
        if not exchange_interrupted:
            exchange_interrupted = True
            raise Crash()

    journal_module._rename_exchange = crash_after_journal_exchange
    try:
        try:
            execute_upgrade(
                exchange_plan,
                exchange_location,
                plan_source_digest=exchange_source,
                updated_at="2026-07-11T00:20:45Z",
                validate_after=passed_validation,
            )
        except Crash:
            pass
        else:
            raise AssertionError("journal exchange crash was not injected")
    finally:
        journal_module._rename_exchange = original_exchange
    assert exchange_interrupted is True
    assert exchange_location["replace_temp"].is_file()
    exchange_replay = execute_upgrade(
        exchange_plan,
        exchange_location,
        plan_source_digest=exchange_source,
        updated_at="2026-07-11T00:20:50Z",
        validate_after=passed_validation,
    )
    assert exchange_replay["transaction"]["stage"] == "completed"
    assert not exchange_location["replace_temp"].exists()
    assert (exchange_root / ".workbench/schema").read_bytes() == exchange_after

    partial_time = "2026-07-11T00:20:55Z"
    partial_retry_time = "2026-07-11T00:20:56Z"
    partial_specs = (
        "empty",
        "short",
        "mid-utf8",
        "mid-timestamp",
        "last-byte",
        "full",
    )
    for partial_spec in partial_specs:
        partial_root = (
            pathlib.Path(temporary)
            / f"replace-partial-{partial_spec}-교체-workbench"
        )
        partial_root.mkdir()
        partial_root = partial_root.resolve()
        partial_plan, _, partial_after = fixture_plan(partial_root)
        partial_source = canonical_digest(
            canonical_bytes(partial_plan), raw=True
        )
        partial_journal = build_prepared_journal(
            partial_plan, partial_source, CREATED_AT
        )
        partial_location = resolve_journal_location(
            partial_root,
            partial_plan["plan_digest"],
            journal_dir=journal_root,
            environment={},
        )
        install_prepared_journal(partial_journal, partial_location)
        partial_successor = copy.deepcopy(partial_journal)
        partial_successor["stage"] = "applying"
        partial_successor["updated_at"] = partial_time
        partial_successor = validate_journal(
            partial_successor, partial_plan
        )
        successor_bytes = canonical_bytes(partial_successor)
        if partial_spec == "empty":
            prefix_length = 0
        elif partial_spec == "short":
            prefix_length = 31
        elif partial_spec == "mid-utf8":
            utf8_start = successor_bytes.index("교체".encode("utf-8"))
            prefix_length = utf8_start + 1
        elif partial_spec == "mid-timestamp":
            timestamp_start = successor_bytes.index(partial_time.encode("ascii"))
            prefix_length = timestamp_start + 7
        elif partial_spec == "last-byte":
            prefix_length = len(successor_bytes) - 1
        else:
            prefix_length = len(successor_bytes)
        replace_prefix = successor_bytes[:prefix_length]
        partial_location["replace_temp"].write_bytes(replace_prefix)
        partial_location["replace_temp"].chmod(0o600)
        partial_result = execute_upgrade(
            partial_plan,
            partial_location,
            plan_source_digest=partial_source,
            updated_at=partial_retry_time,
            validate_after=passed_validation,
        )
        assert partial_result["transaction"]["stage"] == "completed"
        assert not partial_location["replace_temp"].exists()
        assert (
            partial_root / ".workbench/schema"
        ).read_bytes() == partial_after

    umask_root = pathlib.Path(temporary) / "umask-workbench"
    umask_root.mkdir()
    umask_root = umask_root.resolve()
    umask_plan, _ = fixture_create_plan(umask_root)
    umask_source = canonical_digest(canonical_bytes(umask_plan), raw=True)
    umask_journal = build_prepared_journal(
        umask_plan, umask_source, CREATED_AT
    )
    umask_location = resolve_journal_location(
        umask_root,
        umask_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(umask_journal, umask_location)
    previous_umask = os.umask(0o077)
    try:
        umask_result = execute_upgrade(
            umask_plan,
            umask_location,
            plan_source_digest=umask_source,
            updated_at="2026-07-11T00:21:00Z",
            validate_after=passed_validation,
        )
    finally:
        os.umask(previous_umask)
    assert umask_result["transaction"]["stage"] == "completed"
    assert stat.S_IMODE(os.lstat(umask_root / ".workbench").st_mode) == 0o755

    umask_crash_root = pathlib.Path(temporary) / "umask-crash-workbench"
    umask_crash_root.mkdir()
    umask_crash_root = umask_crash_root.resolve()
    umask_crash_plan, umask_crash_after = fixture_create_plan(
        umask_crash_root
    )
    umask_crash_source = canonical_digest(
        canonical_bytes(umask_crash_plan), raw=True
    )
    umask_crash_journal = build_prepared_journal(
        umask_crash_plan, umask_crash_source, CREATED_AT
    )
    umask_crash_location = resolve_journal_location(
        umask_crash_root,
        umask_crash_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(
        umask_crash_journal, umask_crash_location
    )

    def crash_after_directory_create(point, effect, direction):
        if (
            point == "after-directory-create"
            and direction == "forward"
            and effect["kind"] == "ensure-directory"
        ):
            raise Crash()

    previous_umask = os.umask(0o077)
    try:
        try:
            execute_upgrade(
                umask_crash_plan,
                umask_crash_location,
                plan_source_digest=umask_crash_source,
                updated_at="2026-07-11T00:21:15Z",
                validate_after=passed_validation,
                fault_hook=crash_after_directory_create,
            )
        except Crash:
            pass
        else:
            raise AssertionError("directory create crash was not injected")
    finally:
        os.umask(previous_umask)
    assert stat.S_IMODE(
        os.lstat(umask_crash_root / ".workbench").st_mode
    ) == 0o700
    umask_crash_replay = execute_upgrade(
        umask_crash_plan,
        umask_crash_location,
        plan_source_digest=umask_crash_source,
        updated_at="2026-07-11T00:21:30Z",
        validate_after=passed_validation,
    )
    assert umask_crash_replay["transaction"]["stage"] == "completed"
    assert stat.S_IMODE(
        os.lstat(umask_crash_root / ".workbench").st_mode
    ) == 0o755
    assert (
        umask_crash_root / ".workbench/schema"
    ).read_bytes() == umask_crash_after

    umask_027_root = pathlib.Path(temporary) / "umask-027-crash-workbench"
    umask_027_root.mkdir()
    umask_027_root = umask_027_root.resolve()
    umask_027_plan, umask_027_after = fixture_create_plan(umask_027_root)
    umask_027_source = canonical_digest(
        canonical_bytes(umask_027_plan), raw=True
    )
    umask_027_journal = build_prepared_journal(
        umask_027_plan, umask_027_source, CREATED_AT
    )
    umask_027_location = resolve_journal_location(
        umask_027_root,
        umask_027_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(umask_027_journal, umask_027_location)
    previous_umask = os.umask(0o027)
    try:
        try:
            execute_upgrade(
                umask_027_plan,
                umask_027_location,
                plan_source_digest=umask_027_source,
                updated_at="2026-07-11T00:21:45Z",
                validate_after=passed_validation,
                fault_hook=crash_after_directory_create,
            )
        except Crash:
            pass
        else:
            raise AssertionError("umask 027 crash was not injected")
    finally:
        os.umask(previous_umask)
    assert stat.S_IMODE(
        os.lstat(umask_027_root / ".workbench").st_mode
    ) == 0o700
    umask_027_replay = execute_upgrade(
        umask_027_plan,
        umask_027_location,
        plan_source_digest=umask_027_source,
        updated_at="2026-07-11T00:22:00Z",
        validate_after=passed_validation,
    )
    assert umask_027_replay["transaction"]["stage"] == "completed"
    assert stat.S_IMODE(
        os.lstat(umask_027_root / ".workbench").st_mode
    ) == 0o755
    assert (
        umask_027_root / ".workbench/schema"
    ).read_bytes() == umask_027_after

    noop_root = pathlib.Path(temporary) / "noop-workbench"
    noop_root.mkdir()
    noop_root = noop_root.resolve()
    noop_plan = fixture_noop_plan(noop_root)
    noop_source = canonical_digest(canonical_bytes(noop_plan), raw=True)
    noop_journal = build_prepared_journal(noop_plan, noop_source, CREATED_AT)
    assert noop_journal["effects"] == []
    noop_location = resolve_journal_location(
        noop_root,
        noop_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(noop_journal, noop_location)
    noop_result = execute_upgrade(
        noop_plan,
        noop_location,
        plan_source_digest=noop_source,
        updated_at="2026-07-11T00:22:00Z",
        validate_after=passed_validation,
    )
    assert validate_result(noop_result) == noop_result
    assert noop_result["transaction"]["stage"] == "completed"
    assert noop_result["transaction"]["cursor"] == 0
    assert noop_result["changed"] is False
    assert noop_result["applied"] == []

    cas_root = pathlib.Path(temporary) / "cas-workbench"
    cas_root.mkdir()
    cas_root = cas_root.resolve()
    cas_plan, _, _ = fixture_plan(cas_root)
    cas_source = canonical_digest(canonical_bytes(cas_plan), raw=True)
    cas_journal = build_prepared_journal(cas_plan, cas_source, CREATED_AT)
    cas_location = resolve_journal_location(
        cas_root,
        cas_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(cas_journal, cas_location)

    def concurrent_target_edit(point, _effect, direction):
        if point == "after-temp-fsync" and direction == "forward":
            (cas_root / ".workbench/schema").write_bytes(b"concurrent edit\n")

    rejected(
        lambda: execute_upgrade(
            cas_plan,
            cas_location,
            plan_source_digest=cas_source,
            updated_at="2026-07-11T00:23:00Z",
            validate_after=passed_validation,
            fault_hook=concurrent_target_edit,
        ),
        "transaction-state-mismatch",
    )
    assert (cas_root / ".workbench/schema").read_bytes() == b"concurrent edit\n"

    parent_root = pathlib.Path(temporary) / "parent-swap-workbench"
    parent_root.mkdir()
    parent_root = parent_root.resolve()
    parent_plan, _, parent_after = fixture_plan(parent_root)
    parent_source = canonical_digest(canonical_bytes(parent_plan), raw=True)
    parent_journal = build_prepared_journal(
        parent_plan, parent_source, CREATED_AT
    )
    parent_location = resolve_journal_location(
        parent_root,
        parent_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(parent_journal, parent_location)
    external_parent = pathlib.Path(temporary).resolve() / "external-parent"
    external_parent.mkdir()
    external_schema = external_parent / "schema"
    external_schema.write_bytes(b"external sentinel\n")
    swapped = False

    def swap_parent(point, effect, direction):
        global swapped
        if point != "after-temp-fsync" or direction != "forward" or swapped:
            return
        swapped = True
        original_parent = parent_root / ".workbench"
        os.rename(original_parent, parent_root / ".workbench-real")
        original_parent.symlink_to(external_parent, target_is_directory=True)
        external_temp = external_parent / pathlib.PurePosixPath(
            effect["temp_path"]
        ).name
        external_temp.write_bytes(parent_after)
        external_temp.chmod(0o644)

    try:
        execute_upgrade(
            parent_plan,
            parent_location,
            plan_source_digest=parent_source,
            updated_at="2026-07-11T00:24:00Z",
            validate_after=passed_validation,
            fault_hook=swap_parent,
        )
    except Exception:
        pass
    assert swapped is True
    assert external_schema.read_bytes() == b"external sentinel\n"

    hardlink_root = pathlib.Path(temporary) / "journal-hardlink-workbench"
    hardlink_root.mkdir()
    hardlink_root = hardlink_root.resolve()
    hardlink_plan, _, _ = fixture_plan(hardlink_root)
    hardlink_source = canonical_digest(canonical_bytes(hardlink_plan), raw=True)
    hardlink_journal = build_prepared_journal(
        hardlink_plan, hardlink_source, CREATED_AT
    )
    hardlink_location = resolve_journal_location(
        hardlink_root,
        hardlink_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(hardlink_journal, hardlink_location)
    journal_alias = hardlink_location["directory"] / "journal-alias"
    os.link(hardlink_location["journal"], journal_alias)
    rejected(
        lambda: load_journal(hardlink_location, hardlink_plan),
        "journal-unsafe",
    )
    journal_alias.unlink()

    journal_race_alias = hardlink_location["directory"] / "journal-race-alias"
    original_read = journal_module.os.read
    journal_read_mutated = False

    def mutate_journal_after_read(descriptor, count):
        global journal_read_mutated
        chunk = original_read(descriptor, count)
        if chunk and not journal_read_mutated:
            journal_read_mutated = True
            os.link(hardlink_location["journal"], journal_race_alias)
            hardlink_location["journal"].chmod(0o644)
        return chunk

    journal_module.os.read = mutate_journal_after_read
    try:
        rejected(
            lambda: load_journal(hardlink_location, hardlink_plan),
            "journal-unsafe",
        )
    finally:
        journal_module.os.read = original_read
        hardlink_location["journal"].chmod(0o600)
        journal_race_alias.unlink()
    assert journal_read_mutated is True

    initial_root = pathlib.Path(temporary) / "initial-temp-workbench"
    initial_root.mkdir()
    initial_root = initial_root.resolve()
    initial_plan, _, _ = fixture_plan(initial_root)
    initial_source = canonical_digest(canonical_bytes(initial_plan), raw=True)
    initial_journal = build_prepared_journal(
        initial_plan, initial_source, CREATED_AT
    )
    initial_location = resolve_journal_location(
        initial_root,
        initial_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    initial_location["initial_temp"].write_bytes(
        canonical_bytes(initial_journal)[:23]
    )
    initial_location["initial_temp"].chmod(0o600)
    install_prepared_journal(initial_journal, initial_location)
    assert initial_location["journal"].is_file()
    assert not initial_location["initial_temp"].exists()

    foreign_initial_root = pathlib.Path(temporary) / "foreign-initial-workbench"
    foreign_initial_root.mkdir()
    foreign_initial_root = foreign_initial_root.resolve()
    foreign_initial_plan, _, _ = fixture_plan(foreign_initial_root)
    foreign_initial_source = canonical_digest(
        canonical_bytes(foreign_initial_plan), raw=True
    )
    foreign_initial_journal = build_prepared_journal(
        foreign_initial_plan, foreign_initial_source, CREATED_AT
    )
    foreign_initial_location = resolve_journal_location(
        foreign_initial_root,
        foreign_initial_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    foreign_initial_location["initial_temp"].write_bytes(b"foreign journal\n")
    foreign_initial_location["initial_temp"].chmod(0o600)
    rejected(
        lambda: install_prepared_journal(
            foreign_initial_journal, foreign_initial_location
        ),
        "journal-unsafe",
    )
    assert foreign_initial_location["initial_temp"].read_bytes() == b"foreign journal\n"

    foreign_root = pathlib.Path(temporary) / "foreign-temp-workbench"
    foreign_root.mkdir()
    foreign_root = foreign_root.resolve()
    foreign_plan, _, _ = fixture_plan(foreign_root)
    foreign_source = canonical_digest(canonical_bytes(foreign_plan), raw=True)
    foreign_journal = build_prepared_journal(
        foreign_plan, foreign_source, CREATED_AT
    )
    foreign_location = resolve_journal_location(
        foreign_root,
        foreign_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(foreign_journal, foreign_location)
    foreign_temp = foreign_root / foreign_journal["effects"][0]["temp_path"]
    foreign_temp.write_bytes(b"foreign complete-looking temp\n")
    foreign_temp.chmod(0o600)
    rejected(
        lambda: execute_upgrade(
            foreign_plan,
            foreign_location,
            plan_source_digest=foreign_source,
            updated_at="2026-07-11T00:25:00Z",
            validate_after=passed_validation,
        ),
        "operation-temp-stale",
    )
    assert foreign_temp.read_bytes() == b"foreign complete-looking temp\n"

    terminal_owner_root = pathlib.Path(temporary) / "terminal-owner-workbench"
    terminal_owner_root.mkdir()
    terminal_owner_root = terminal_owner_root.resolve()
    terminal_owner_plan, _, terminal_owner_after = fixture_plan(
        terminal_owner_root
    )
    terminal_owner_source = canonical_digest(
        canonical_bytes(terminal_owner_plan), raw=True
    )
    terminal_owner_journal = build_prepared_journal(
        terminal_owner_plan, terminal_owner_source, CREATED_AT
    )
    terminal_owner_store_a = pathlib.Path(temporary) / "terminal-owner-store-a"
    terminal_owner_store_a.mkdir(mode=0o700)
    terminal_owner_location_a = resolve_journal_location(
        terminal_owner_root,
        terminal_owner_plan["plan_digest"],
        journal_dir=terminal_owner_store_a.resolve(),
        environment={"HOME": str(pathlib.Path(temporary) / "ignored-home-a")},
    )
    install_prepared_journal(
        terminal_owner_journal, terminal_owner_location_a
    )
    terminal_owner_bytes = terminal_owner_location_a["owner"].read_bytes()
    terminal_owner_result = execute_upgrade(
        terminal_owner_plan,
        terminal_owner_location_a,
        plan_source_digest=terminal_owner_source,
        updated_at="2026-07-11T00:25:15Z",
        validate_after=passed_validation,
    )
    assert terminal_owner_result["transaction"]["stage"] == "completed"
    assert not terminal_owner_location_a["owner"].exists()
    terminal_owner_location_a["owner"].write_bytes(terminal_owner_bytes)
    terminal_owner_location_a["owner"].chmod(0o600)
    terminal_owner_store_b = pathlib.Path(temporary) / "terminal-owner-store-b"
    terminal_owner_store_b.mkdir(mode=0o700)
    terminal_owner_xdg_b = pathlib.Path(temporary) / "terminal-owner-xdg-b"
    terminal_owner_xdg_b.mkdir(mode=0o700)
    terminal_owner_location_b = resolve_journal_location(
        terminal_owner_root,
        terminal_owner_plan["plan_digest"],
        journal_dir=terminal_owner_store_b.resolve(),
        environment={"XDG_STATE_HOME": str(terminal_owner_xdg_b.resolve())},
    )
    assert (
        terminal_owner_location_b["journal"]
        == terminal_owner_location_a["journal"]
    )
    terminal_owner_replay = execute_upgrade(
        terminal_owner_plan,
        terminal_owner_location_b,
        plan_source_digest=terminal_owner_source,
        updated_at="2026-07-11T00:25:30Z",
        validate_after=passed_validation,
    )
    assert terminal_owner_replay["changed"] is False
    assert terminal_owner_replay["transaction"]["resumed"] is True
    assert not terminal_owner_location_a["owner"].exists()
    assert (
        terminal_owner_root / ".workbench/schema"
    ).read_bytes() == terminal_owner_after

    owner_takeover_root = pathlib.Path(temporary) / "owner-takeover-workbench"
    owner_takeover_root.mkdir()
    owner_takeover_root = owner_takeover_root.resolve()
    owner_takeover_plan_a = fixture_noop_plan(owner_takeover_root)
    owner_takeover_plan_b = copy.deepcopy(owner_takeover_plan_a)
    owner_takeover_plan_b["plan_digest"] = None
    owner_takeover_plan_b["planner"]["planner_revision"] = "8" * 40
    owner_takeover_plan_b["plan_digest"] = canonical_digest(
        owner_takeover_plan_b, null_field="plan_digest"
    )
    owner_takeover_plan_b = validate_plan(owner_takeover_plan_b)
    owner_takeover_source_a = canonical_digest(
        canonical_bytes(owner_takeover_plan_a), raw=True
    )
    owner_takeover_source_b = canonical_digest(
        canonical_bytes(owner_takeover_plan_b), raw=True
    )
    owner_takeover_journal_a = build_prepared_journal(
        owner_takeover_plan_a, owner_takeover_source_a, CREATED_AT
    )
    owner_takeover_journal_b = build_prepared_journal(
        owner_takeover_plan_b, owner_takeover_source_b, CREATED_AT
    )
    owner_takeover_store_a = pathlib.Path(temporary) / "owner-takeover-store-a"
    owner_takeover_store_b = pathlib.Path(temporary) / "owner-takeover-store-b"
    owner_takeover_store_a.mkdir(mode=0o700)
    owner_takeover_store_b.mkdir(mode=0o700)
    owner_takeover_location_a = resolve_journal_location(
        owner_takeover_root,
        owner_takeover_plan_a["plan_digest"],
        journal_dir=owner_takeover_store_a.resolve(),
        environment={},
    )
    owner_takeover_location_b = resolve_journal_location(
        owner_takeover_root,
        owner_takeover_plan_b["plan_digest"],
        journal_dir=owner_takeover_store_b.resolve(),
        environment={"XDG_STATE_HOME": str(terminal_owner_xdg_b.resolve())},
    )
    install_prepared_journal(
        owner_takeover_journal_a, owner_takeover_location_a
    )
    owner_takeover_bytes = owner_takeover_location_a["owner"].read_bytes()
    execute_upgrade(
        owner_takeover_plan_a,
        owner_takeover_location_a,
        plan_source_digest=owner_takeover_source_a,
        updated_at="2026-07-11T00:25:45Z",
        validate_after=passed_validation,
    )
    owner_takeover_location_a["owner"].write_bytes(owner_takeover_bytes)
    owner_takeover_location_a["owner"].chmod(0o600)
    install_prepared_journal(
        owner_takeover_journal_b, owner_takeover_location_b
    )
    takeover_record = journal_module.strict_load(
        owner_takeover_location_b["owner"].read_bytes(), "owner"
    )
    assert takeover_record["plan_digest"] == owner_takeover_plan_b["plan_digest"]
    owner_takeover_result = execute_upgrade(
        owner_takeover_plan_b,
        owner_takeover_location_b,
        plan_source_digest=owner_takeover_source_b,
        updated_at="2026-07-11T00:25:50Z",
        validate_after=passed_validation,
    )
    assert owner_takeover_result["transaction"]["stage"] == "completed"

    owner_root = pathlib.Path(temporary) / "owner-workbench"
    owner_root.mkdir()
    owner_root = owner_root.resolve()
    owner_plan_a, _, _ = fixture_plan(owner_root)
    owner_plan_b = copy.deepcopy(owner_plan_a)
    owner_plan_b["plan_digest"] = None
    owner_plan_b["planner"]["planner_revision"] = "4" * 40
    owner_plan_b["plan_digest"] = canonical_digest(
        owner_plan_b, null_field="plan_digest"
    )
    owner_plan_b = validate_plan(owner_plan_b)
    owner_source_a = canonical_digest(canonical_bytes(owner_plan_a), raw=True)
    owner_source_b = canonical_digest(canonical_bytes(owner_plan_b), raw=True)
    owner_journal_a = build_prepared_journal(
        owner_plan_a, owner_source_a, CREATED_AT
    )
    owner_journal_b = build_prepared_journal(
        owner_plan_b, owner_source_b, CREATED_AT
    )
    owner_store_a = pathlib.Path(temporary).resolve() / "owner-store-a"
    owner_store_b = pathlib.Path(temporary).resolve() / "owner-store-b"
    owner_store_a.mkdir(mode=0o700)
    owner_store_b.mkdir(mode=0o700)
    owner_location_a = resolve_journal_location(
        owner_root,
        owner_plan_a["plan_digest"],
        journal_dir=owner_store_a,
        environment={},
    )
    owner_xdg = pathlib.Path(temporary).resolve() / "owner-xdg"
    owner_xdg.mkdir(mode=0o700)
    owner_location_b = resolve_journal_location(
        owner_root,
        owner_plan_b["plan_digest"],
        journal_dir=owner_store_b,
        environment={"XDG_STATE_HOME": str(owner_xdg)},
    )
    assert owner_location_a["owner"] == owner_location_b["owner"]
    install_prepared_journal(owner_journal_a, owner_location_a)

    def crash_before_owner_effect(point, _effect, direction):
        if point == "before-effect" and direction == "forward":
            raise Crash()

    try:
        execute_upgrade(
            owner_plan_a,
            owner_location_a,
            plan_source_digest=owner_source_a,
            updated_at="2026-07-11T00:26:00Z",
            validate_after=passed_validation,
            fault_hook=crash_before_owner_effect,
        )
    except Crash:
        pass
    else:
        raise AssertionError("owner plan A did not stop nonterminal")
    rejected(
        lambda: install_prepared_journal(owner_journal_b, owner_location_b),
        "transaction-in-progress",
    )

    replaced_owner_root = (
        pathlib.Path(temporary) / "replaced-owner-workbench"
    )
    replaced_owner_root.mkdir()
    replaced_owner_root = replaced_owner_root.resolve()
    replaced_owner_plan_a, _, _ = fixture_plan(replaced_owner_root)
    replaced_owner_source_a = canonical_digest(
        canonical_bytes(replaced_owner_plan_a), raw=True
    )
    replaced_owner_journal_a = build_prepared_journal(
        replaced_owner_plan_a, replaced_owner_source_a, CREATED_AT
    )
    replaced_owner_store_a = pathlib.Path(temporary) / "replaced-owner-store-a"
    replaced_owner_store_a.mkdir(mode=0o700)
    replaced_owner_location_a = resolve_journal_location(
        replaced_owner_root,
        replaced_owner_plan_a["plan_digest"],
        journal_dir=replaced_owner_store_a.resolve(),
        environment={},
    )
    install_prepared_journal(
        replaced_owner_journal_a, replaced_owner_location_a
    )
    try:
        execute_upgrade(
            replaced_owner_plan_a,
            replaced_owner_location_a,
            plan_source_digest=replaced_owner_source_a,
            updated_at="2026-07-11T00:26:15Z",
            validate_after=passed_validation,
            fault_hook=crash_before_owner_effect,
        )
    except Crash:
        pass
    else:
        raise AssertionError("replaced owner plan A did not stop nonterminal")
    replaced_owner_detached = replaced_owner_root.with_name(
        replaced_owner_root.name + "-detached"
    )
    os.rename(replaced_owner_root, replaced_owner_detached)
    replaced_owner_root.mkdir()
    replaced_owner_plan_b, _, _ = fixture_plan(replaced_owner_root)
    replaced_owner_plan_b["plan_digest"] = None
    replaced_owner_plan_b["planner"]["planner_revision"] = "6" * 40
    replaced_owner_plan_b["plan_digest"] = canonical_digest(
        replaced_owner_plan_b, null_field="plan_digest"
    )
    replaced_owner_plan_b = validate_plan(replaced_owner_plan_b)
    replaced_owner_source_b = canonical_digest(
        canonical_bytes(replaced_owner_plan_b), raw=True
    )
    replaced_owner_journal_b = build_prepared_journal(
        replaced_owner_plan_b, replaced_owner_source_b, CREATED_AT
    )
    replaced_owner_store_b = pathlib.Path(temporary) / "replaced-owner-store-b"
    replaced_owner_store_b.mkdir(mode=0o700)
    replaced_owner_location_b = resolve_journal_location(
        replaced_owner_root,
        replaced_owner_plan_b["plan_digest"],
        journal_dir=replaced_owner_store_b.resolve(),
        environment={"HOME": str(pathlib.Path(temporary) / "ignored-home-b")},
    )
    assert (
        replaced_owner_location_b["owner"]
        == replaced_owner_location_a["owner"]
    )
    rejected(
        lambda: install_prepared_journal(
            replaced_owner_journal_b, replaced_owner_location_b
        ),
        "transaction-in-progress",
    )
    assert not replaced_owner_location_b["journal"].exists()

    owner_prefix_root = pathlib.Path(temporary) / "owner-prefix-workbench"
    owner_prefix_root.mkdir()
    owner_prefix_root = owner_prefix_root.resolve()
    owner_prefix_plan, _, owner_prefix_after = fixture_plan(owner_prefix_root)
    owner_prefix_source = canonical_digest(
        canonical_bytes(owner_prefix_plan), raw=True
    )
    owner_prefix_journal = build_prepared_journal(
        owner_prefix_plan, owner_prefix_source, CREATED_AT
    )
    owner_prefix_location = resolve_journal_location(
        owner_prefix_root,
        owner_prefix_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(owner_prefix_journal, owner_prefix_location)
    os.link(
        owner_prefix_location["owner"],
        owner_prefix_location["owner_temp"],
    )
    owner_prefix_result = execute_upgrade(
        owner_prefix_plan,
        owner_prefix_location,
        plan_source_digest=owner_prefix_source,
        updated_at="2026-07-11T00:27:00Z",
        validate_after=passed_validation,
    )
    assert owner_prefix_result["transaction"]["stage"] == "completed"
    assert not owner_prefix_location["owner_temp"].exists()
    assert (owner_prefix_root / ".workbench/schema").read_bytes() == owner_prefix_after

    owner_binding_root = pathlib.Path(temporary) / "owner-binding-workbench"
    owner_binding_root.mkdir()
    owner_binding_root = owner_binding_root.resolve()
    owner_binding_plan, _, _ = fixture_plan(owner_binding_root)
    owner_binding_source = canonical_digest(
        canonical_bytes(owner_binding_plan), raw=True
    )
    owner_binding_journal = build_prepared_journal(
        owner_binding_plan, owner_binding_source, CREATED_AT
    )
    owner_binding_location = resolve_journal_location(
        owner_binding_root,
        owner_binding_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(owner_binding_journal, owner_binding_location)
    owner_record = journal_module.strict_load(
        owner_binding_location["owner"].read_bytes(), "owner"
    )
    owner_record["owner_id"] = "upgrade-" + "f" * 64
    owner_binding_location["owner"].write_bytes(canonical_bytes(owner_record))
    rejected(
        lambda: execute_upgrade(
            owner_binding_plan,
            owner_binding_location,
            plan_source_digest=owner_binding_source,
            updated_at="2026-07-11T00:27:30Z",
            validate_after=passed_validation,
        ),
        "owner-mismatch",
    )

    for crash_point in ("after-target-install", "after-temp-unlink"):
        prefix_root = pathlib.Path(temporary) / f"{crash_point}-workbench"
        prefix_root.mkdir()
        prefix_root = prefix_root.resolve()
        prefix_plan, _, prefix_after = fixture_plan(prefix_root)
        prefix_source = canonical_digest(canonical_bytes(prefix_plan), raw=True)
        prefix_journal = build_prepared_journal(
            prefix_plan, prefix_source, CREATED_AT
        )
        prefix_location = resolve_journal_location(
            prefix_root,
            prefix_plan["plan_digest"],
            journal_dir=journal_root,
            environment={},
        )
        install_prepared_journal(prefix_journal, prefix_location)

        def crash_update_prefix(point, _effect, direction, expected=crash_point):
            if point == expected and direction == "forward":
                raise Crash()

        try:
            execute_upgrade(
                prefix_plan,
                prefix_location,
                plan_source_digest=prefix_source,
                updated_at="2026-07-11T00:28:00Z",
                validate_after=passed_validation,
                fault_hook=crash_update_prefix,
            )
        except Crash:
            pass
        else:
            raise AssertionError(f"{crash_point} did not interrupt update")
        prefix_result = execute_upgrade(
            prefix_plan,
            prefix_location,
            plan_source_digest=prefix_source,
            updated_at="2026-07-11T00:29:00Z",
            validate_after=passed_validation,
        )
        assert prefix_result["transaction"]["stage"] == "completed"
        assert (prefix_root / ".workbench/schema").read_bytes() == prefix_after
        assert not list(
            (prefix_root / ".workbench").glob(".workbench-kit.*.backup")
        )

    root_swap_root = pathlib.Path(temporary) / "root-swap-workbench"
    root_swap_root.mkdir()
    root_swap_root = root_swap_root.resolve()
    root_swap_plan, root_swap_before, _ = fixture_plan(root_swap_root)
    root_swap_source = canonical_digest(
        canonical_bytes(root_swap_plan), raw=True
    )
    root_swap_journal = build_prepared_journal(
        root_swap_plan, root_swap_source, CREATED_AT
    )
    root_swap_location = resolve_journal_location(
        root_swap_root,
        root_swap_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(root_swap_journal, root_swap_location)
    detached_root = root_swap_root.with_name(root_swap_root.name + "-detached")

    def replace_workspace_root(point, _effect, direction):
        if point != "after-temp-fsync" or direction != "forward":
            return
        os.rename(root_swap_root, detached_root)
        root_swap_root.mkdir()
        (root_swap_root / ".git").mkdir()
        (root_swap_root / ".workbench").mkdir()
        (root_swap_root / ".workbench/schema").write_bytes(b"replacement\n")

    rejected(
        lambda: execute_upgrade(
            root_swap_plan,
            root_swap_location,
            plan_source_digest=root_swap_source,
            updated_at="2026-07-11T00:30:00Z",
            validate_after=passed_validation,
            fault_hook=replace_workspace_root,
        ),
        "workspace-binding-stale",
    )
    assert (detached_root / ".workbench/schema").read_bytes() == root_swap_before
    assert (root_swap_root / ".workbench/schema").read_bytes() == b"replacement\n"

    installed_swap_root = pathlib.Path(temporary) / "installed-swap-workbench"
    installed_swap_root.mkdir()
    installed_swap_root = installed_swap_root.resolve()
    installed_swap_plan, installed_swap_before, installed_swap_after = fixture_plan(
        installed_swap_root
    )
    installed_swap_source = canonical_digest(
        canonical_bytes(installed_swap_plan), raw=True
    )
    installed_swap_journal = build_prepared_journal(
        installed_swap_plan, installed_swap_source, CREATED_AT
    )
    installed_swap_location = resolve_journal_location(
        installed_swap_root,
        installed_swap_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(
        installed_swap_journal, installed_swap_location
    )
    installed_detached = installed_swap_root.with_name(
        installed_swap_root.name + "-detached"
    )

    def replace_root_after_install(point, _effect, direction):
        if point != "after-target-install" or direction != "forward":
            return
        os.rename(installed_swap_root, installed_detached)
        installed_swap_root.mkdir()
        (installed_swap_root / ".git").mkdir()
        (installed_swap_root / ".workbench").mkdir()
        (installed_swap_root / ".workbench/schema").write_bytes(
            b"replacement after install\n"
        )

    rejected(
        lambda: execute_upgrade(
            installed_swap_plan,
            installed_swap_location,
            plan_source_digest=installed_swap_source,
            updated_at="2026-07-11T00:30:15Z",
            validate_after=passed_validation,
            fault_hook=replace_root_after_install,
        ),
        "workspace-binding-stale",
    )
    installed_temp = (
        installed_detached / installed_swap_journal["effects"][0]["temp_path"]
    )
    assert installed_temp.read_bytes() == installed_swap_before
    assert (
        installed_detached / ".workbench/schema"
    ).read_bytes() == installed_swap_after
    assert (
        installed_swap_root / ".workbench/schema"
    ).read_bytes() == b"replacement after install\n"

    missing_parent_root = pathlib.Path(temporary) / "missing-parent-workbench"
    missing_parent_root.mkdir()
    missing_parent_root = missing_parent_root.resolve()
    missing_parent_plan, _ = fixture_create_plan(missing_parent_root)
    missing_parent_source = canonical_digest(
        canonical_bytes(missing_parent_plan), raw=True
    )
    missing_parent_journal = build_prepared_journal(
        missing_parent_plan, missing_parent_source, CREATED_AT
    )
    missing_parent_location = resolve_journal_location(
        missing_parent_root,
        missing_parent_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(
        missing_parent_journal, missing_parent_location
    )

    def remove_created_parent(point, effect, direction):
        if (
            point == "before-effect"
            and direction == "forward"
            and effect["kind"] == "create"
        ):
            (missing_parent_root / ".workbench").rmdir()

    rejected(
        lambda: execute_upgrade(
            missing_parent_plan,
            missing_parent_location,
            plan_source_digest=missing_parent_source,
            updated_at="2026-07-11T00:30:30Z",
            validate_after=passed_validation,
            fault_hook=remove_created_parent,
        ),
        "transaction-state-mismatch",
    )

    removal_cas_root = pathlib.Path(temporary) / "removal-cas-workbench"
    removal_cas_root.mkdir()
    removal_cas_root = removal_cas_root.resolve()
    removal_cas_plan, _ = fixture_removal_plan(removal_cas_root)
    removal_cas_source = canonical_digest(
        canonical_bytes(removal_cas_plan), raw=True
    )
    removal_cas_journal = build_prepared_journal(
        removal_cas_plan, removal_cas_source, CREATED_AT
    )
    removal_cas_location = resolve_journal_location(
        removal_cas_root,
        removal_cas_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(removal_cas_journal, removal_cas_location)

    def edit_remove_target(point, effect, direction):
        if point == "after-source-check" and direction == "forward":
            (removal_cas_root / effect["path"]).write_bytes(b"concurrent edit\n")

    rejected(
        lambda: execute_upgrade(
            removal_cas_plan,
            removal_cas_location,
            plan_source_digest=removal_cas_source,
            updated_at="2026-07-11T00:31:00Z",
            validate_after=passed_removal_validation,
            fault_hook=edit_remove_target,
        ),
        "transaction-state-mismatch",
    )
    assert (removal_cas_root / "legacy-engine/task").read_bytes() == b"concurrent edit\n"

    removal_parent_root = pathlib.Path(temporary) / "removal-parent-workbench"
    removal_parent_root.mkdir()
    removal_parent_root = removal_parent_root.resolve()
    removal_parent_plan, removal_parent_bytes = fixture_removal_plan(
        removal_parent_root
    )
    removal_parent_source = canonical_digest(
        canonical_bytes(removal_parent_plan), raw=True
    )
    removal_parent_journal = build_prepared_journal(
        removal_parent_plan, removal_parent_source, CREATED_AT
    )
    removal_parent_location = resolve_journal_location(
        removal_parent_root,
        removal_parent_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(removal_parent_journal, removal_parent_location)
    removal_detached = removal_parent_root / "legacy-engine-detached"
    removal_external = pathlib.Path(temporary).resolve() / "removal-external"
    removal_external.mkdir()
    (removal_external / "task").write_bytes(b"external sentinel\n")

    def swap_remove_parent(point, _effect, direction):
        if point != "after-source-check" or direction != "forward":
            return
        os.rename(removal_parent_root / "legacy-engine", removal_detached)
        (removal_parent_root / "legacy-engine").symlink_to(
            removal_external, target_is_directory=True
        )

    rejected(
        lambda: execute_upgrade(
            removal_parent_plan,
            removal_parent_location,
            plan_source_digest=removal_parent_source,
            updated_at="2026-07-11T00:32:00Z",
            validate_after=passed_removal_validation,
            fault_hook=swap_remove_parent,
        ),
        "node-parent-unsafe",
    )
    assert (removal_detached / "task").read_bytes() == removal_parent_bytes
    assert (removal_external / "task").read_bytes() == b"external sentinel\n"

    for crash_point in ("after-target-install", "after-temp-unlink"):
        removal_prefix_root = (
            pathlib.Path(temporary) / f"remove-{crash_point}-workbench"
        )
        removal_prefix_root.mkdir()
        removal_prefix_root = removal_prefix_root.resolve()
        removal_prefix_plan, _ = fixture_removal_plan(removal_prefix_root)
        removal_prefix_source = canonical_digest(
            canonical_bytes(removal_prefix_plan), raw=True
        )
        removal_prefix_journal = build_prepared_journal(
            removal_prefix_plan, removal_prefix_source, CREATED_AT
        )
        removal_prefix_location = resolve_journal_location(
            removal_prefix_root,
            removal_prefix_plan["plan_digest"],
            journal_dir=journal_root,
            environment={},
        )
        install_prepared_journal(
            removal_prefix_journal, removal_prefix_location
        )

        def crash_remove_prefix(
            point, effect, direction, expected=crash_point
        ):
            if (
                point == expected
                and direction == "forward"
                and effect["kind"] == "remove"
            ):
                raise Crash()

        try:
            execute_upgrade(
                removal_prefix_plan,
                removal_prefix_location,
                plan_source_digest=removal_prefix_source,
                updated_at="2026-07-11T00:33:00Z",
                validate_after=passed_removal_validation,
                fault_hook=crash_remove_prefix,
            )
        except Crash:
            pass
        else:
            raise AssertionError(
                f"remove {crash_point} did not interrupt execution"
            )
        removal_prefix_temp = (
            removal_prefix_root
            / removal_prefix_journal["effects"][0]["temp_path"]
        )
        if crash_point == "after-target-install":
            assert removal_prefix_temp.is_file()
        else:
            assert not removal_prefix_temp.exists()
        removal_prefix_result = execute_upgrade(
            removal_prefix_plan,
            removal_prefix_location,
            plan_source_digest=removal_prefix_source,
            updated_at="2026-07-11T00:34:00Z",
            validate_after=passed_removal_validation,
        )
        assert removal_prefix_result["transaction"]["stage"] == "completed"
        assert not removal_prefix_temp.exists()
        assert not (removal_prefix_root / "legacy-engine/task").exists()

    removal_reverse_root = pathlib.Path(temporary) / "remove-reverse-workbench"
    removal_reverse_root.mkdir()
    removal_reverse_root = removal_reverse_root.resolve()
    removal_reverse_plan, removal_reverse_bytes = fixture_removal_plan(
        removal_reverse_root
    )
    removal_reverse_source = canonical_digest(
        canonical_bytes(removal_reverse_plan), raw=True
    )
    removal_reverse_journal = build_prepared_journal(
        removal_reverse_plan, removal_reverse_source, CREATED_AT
    )
    removal_reverse_location = resolve_journal_location(
        removal_reverse_root,
        removal_reverse_plan["plan_digest"],
        journal_dir=journal_root,
        environment={},
    )
    install_prepared_journal(
        removal_reverse_journal, removal_reverse_location
    )
    removal_reverse_failed = False

    def crash_remove_reverse(point, effect, direction):
        global removal_reverse_failed
        if (
            point == "after-effect"
            and direction == "forward"
            and effect["kind"] == "remove"
            and not removal_reverse_failed
        ):
            removal_reverse_failed = True
            raise RuntimeError("start remove rollback")
        if (
            point == "after-target-install"
            and direction == "reverse"
            and effect["kind"] == "remove"
        ):
            raise Crash()

    try:
        execute_upgrade(
            removal_reverse_plan,
            removal_reverse_location,
            plan_source_digest=removal_reverse_source,
            updated_at="2026-07-11T00:35:00Z",
            validate_after=passed_removal_validation,
            fault_hook=crash_remove_reverse,
        )
    except Crash:
        pass
    else:
        raise AssertionError("remove reverse did not interrupt execution")
    removal_reverse_result = execute_upgrade(
        removal_reverse_plan,
        removal_reverse_location,
        plan_source_digest=removal_reverse_source,
        updated_at="2026-07-11T00:36:00Z",
        validate_after=passed_removal_validation,
    )
    assert removal_reverse_result["transaction"]["stage"] == "rolled-back"
    assert (
        removal_reverse_root / "legacy-engine/task"
    ).read_bytes() == removal_reverse_bytes

    linked_root = pathlib.Path(temporary) / "linked-workbench"
    linked_root.mkdir()
    linked_root = linked_root.resolve()
    fixture_plan(linked_root)
    (linked_root / ".git").rmdir()
    common_git = pathlib.Path(temporary).resolve() / "linked-common.git"
    worktree_git = common_git / "worktrees/linked-workbench"
    worktree_git.mkdir(parents=True)
    (worktree_git / "commondir").write_text("../..\n", encoding="utf-8")
    (worktree_git / "gitdir").write_text(
        str(linked_root / ".git") + "\n", encoding="utf-8"
    )
    (linked_root / ".git").write_text(
        "gitdir: " + str(worktree_git) + "\n", encoding="utf-8"
    )
    linked_location = resolve_journal_location(
        linked_root,
        "sha256:" + "e" * 64,
        journal_dir=journal_root,
        environment={},
    )
    assert linked_location["owner"].is_relative_to(
        account_home / ".local/state/workbench-kit/upgrade-coordination"
    )
    (worktree_git / "gitdir").write_text(
        str(pathlib.Path(temporary) / "other/.git") + "\n",
        encoding="utf-8",
    )
    rejected(
        lambda: resolve_journal_location(
            linked_root,
            "sha256:" + "e" * 64,
            journal_dir=journal_root,
            environment={},
        ),
        "git-directory-unsafe",
    )

print("PASS: deterministic full-preimage upgrade journal preparation")
PY
