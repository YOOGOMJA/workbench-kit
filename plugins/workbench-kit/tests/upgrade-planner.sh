#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
from workbench_kit_contracts import (
    canonical_bytes,
    canonical_digest,
    parse_authority_approval,
    parse_reviewed_overlay,
    strict_load,
    validate_migration_receipt,
    validate_plan,
)
from workbench_kit_planner import PlanningError, build_migration_plan

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
        "active_v1_tasks": [],
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

print("PASS: deterministic migration planner and preservation manifest")
PY
