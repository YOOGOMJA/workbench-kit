#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
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
)
from workbench_kit_journal import (
    JournalError,
    build_prepared_journal,
    install_prepared_journal,
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

print("PASS: deterministic full-preimage upgrade journal preparation")
PY
