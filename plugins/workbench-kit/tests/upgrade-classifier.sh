#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/lib" <<'PY'
import base64
import copy
import hashlib
import json
import os
import pathlib
import sys
import tempfile

sys.path.insert(0, sys.argv[1])
from workbench_kit_classifier import diagnose_workspace
from workbench_kit_contracts import canonical_bytes, canonical_digest, node_digest

OID = "1" * 40
SHA = "sha256:" + "a" * 64


def write(root, path, content, mode=0o644):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(content)
    target.chmod(mode)


def tree_digest(root):
    rows = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories[:] = sorted(directories)
        for name in sorted(directories + files):
            path = pathlib.Path(current) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                rows.append(("link", relative, os.readlink(path)))
            elif path.is_file():
                rows.append(("file", relative, hashlib.sha256(path.read_bytes()).hexdigest()))
    return hashlib.sha256(canonical_bytes(rows)).hexdigest()


def kernel(schema, ready):
    return {
        "contract": {"workspace": {"schema": schema}},
        "doctor": {"ready": ready},
    }


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
    "source_revision": OID,
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

engine_bytes = b"#!/bin/sh\nexit 0\n"
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
    "source_revision": "2" * 40,
    "allowed_roots": ["legacy-engine"],
    "removable_nodes": [engine_node],
    "discovery_links": [],
}
equivalence = {
    "contract_version": "workbench-plugin-equivalence/v1",
    "receipt_id": "equivalence-fixture-1",
    "replacement_plugin": {
        "plugin_name": "workbench",
        "plugin_version": "0.2.0",
        "source_revision": "3" * 40,
        "plugin_manifest_digest": SHA,
        "source_ref": "github:YOOGOMJA/workbench-kit#plugins/workbench",
    },
    "public_contract": {
        "contract_version": "workbench-contract/v1",
        "engine_name": "workbench",
        "engine_version": "0.2.0",
        "supported_object_digest": SHA,
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
        {"evidence_id": "contract", "kind": "contract-test", "source_ref": "ci:contract", "source_revision": "4" * 40, "digest": SHA},
        {"evidence_id": "integration", "kind": "integration-test", "source_ref": "ci:integration", "source_revision": "4" * 40, "digest": SHA},
        {"evidence_id": "audit", "kind": "manifest-audit", "source_ref": "ci:audit", "source_revision": "4" * 40, "digest": SHA},
    ],
}

leaf_skill = b"# Task start\n"
leaf_nodes = [
    {
        "path": ".agents/skills",
        "node_type": "symlink",
        "mode": "120000",
        "digest": node_digest("symlink", "120000", link_target="../skills"),
        "link_target": "../skills",
    },
    {
        "path": ".claude/skills",
        "node_type": "symlink",
        "mode": "120000",
        "digest": node_digest("symlink", "120000", link_target="../skills"),
        "link_target": "../skills",
    },
    {
        "path": "skills/task-start/SKILL.md",
        "node_type": "file",
        "mode": "100644",
        "digest": node_digest("file", "100644", content=leaf_skill),
        "link_target": None,
    },
    {
        "path": "utils/task",
        "node_type": "file",
        "mode": "100755",
        "digest": node_digest("file", "100755", content=engine_bytes),
        "link_target": None,
    },
]
leaf_manifest = {
    "contract_version": "workbench-legacy-engine-manifest/v1",
    "source_ref": legacy_manifest["source_ref"],
    "source_revision": legacy_manifest["source_revision"],
    "allowed_roots": [".agents/skills", ".claude/skills", "skills", "utils"],
    "removable_nodes": leaf_nodes,
    "discovery_links": leaf_nodes[:2],
}
leaf_equivalence = copy.deepcopy(equivalence)
leaf_equivalence.update({
    "receipt_id": "equivalence-leaf-roots-1",
    "legacy_manifest_digest": canonical_digest(leaf_manifest),
    "allowed_roots": leaf_manifest["allowed_roots"],
    "removable_nodes": leaf_manifest["removable_nodes"],
    "discovery_links": leaf_manifest["discovery_links"],
})


def generated_root(root):
    agents = header + core + separator + overlay
    write(root, "AGENTS.overlay.md", overlay)
    write(root, "AGENTS.md", agents)
    write(root, "CLAUDE.md", agents)
    write(root, ".claude/settings.json", canonical_bytes(settings))
    write(root, "docs/index.md", b"# Docs\n")


descriptor = {
    "contract_version": "workbench-workspace-authority/v1",
    "authority_identity": "github:example/workbench",
    "origin_url": "https://github.com/example/workbench.git",
    "default_ref": "refs/heads/main",
    "workspace_home": "workbench",
    "hosting_adapter": "github",
    "hosting_ref": "github:repository/example/workbench",
}


def normative_root(root):
    write(root, ".workbench/schema", b"workbench/v2\n")
    write(root, ".workbench/profile.conf", b"schema=workbench-profile/v1\nlanguage=en\n")
    write(root, ".workbench/policy.conf", b"schema=workbench-policy/v1\n")
    write(root, ".workbench/authority.json", canonical_bytes(descriptor))


def migration_candidate(root):
    normative_root(root)
    generated_root(root)
    write(root, ".gitignore", b".codebases/\n.worktrees/\n")
    write(root, ".gitattributes", b"docs/log.md merge=union\ntask/log.md merge=union\n")
    paths = sorted([
        ".claude/settings.json",
        ".gitattributes",
        ".gitignore",
        ".workbench/authority.json",
        ".workbench/policy.conf",
        ".workbench/profile.conf",
        ".workbench/schema",
        "AGENTS.md",
        "CLAUDE.md",
    ])
    artifacts = []
    for path in paths:
        target = root / path
        content = target.read_bytes()
        artifacts.append({
            "path": path,
            "node_type": "file",
            "mode": "100644",
            "digest": node_digest("file", "100644", content=content),
        })
    language = {
        "contract_version": "workbench-kit-language-decision/v1",
        "tag": "en",
        "source": "explicit-cli",
        "source_ref": "argv:--language",
        "digest": None,
    }
    language["digest"] = canonical_digest(language, null_field="digest")
    receipt = {
        "contract_version": "workbench-kit-migration-receipt/v1",
        "source_revision": OID,
        "source_tree_digest": "git-tree:" + "5" * 40,
        "planner": {
            "contract_version": "workbench-kit-planner/v1",
            "plugin_version": "0.1.1",
            "planner_revision": "6" * 40,
        },
        "migration_task": {
            "task_id": "workbench#27",
            "claim_id": "claim-27",
            "task_contract": "workbench-task/v1",
            "branch": "task/27-upgrade",
            "index_digest": SHA,
        },
        "language": language,
        "authority_approval_object_digest": SHA,
        "authority_approval_source_digest": "sha256:" + "b" * 64,
        "reviewed_overlay_object_digest": None,
        "reviewed_overlay_source_digest": None,
        "legacy_inventory_object_digest": "sha256:" + "c" * 64,
        "legacy_inventory_source_digest": "sha256:" + "d" * 64,
        "active_v1_tasks_digest": "sha256:" + "e" * 64,
        "embedded_engine": {
            "before": "absent",
            "after": "absent",
            "equivalence_receipt_digest": None,
        },
        "artifacts": artifacts,
        "candidate_basis_digest": None,
    }
    receipt["candidate_basis_digest"] = canonical_digest(
        receipt, null_field="candidate_basis_digest"
    )
    write(root, ".workbench/migration.json", canonical_bytes(receipt))
    return receipt


def diagnose(root, schema="workbench/v1", ready=False):
    before = tree_digest(root)
    result = diagnose_workspace(
        root,
        kernel(schema, ready),
        generator_receipts=[generator],
        equivalence_receipt=equivalence,
    )
    assert before == tree_digest(root), "classification mutated workspace"
    assert list(result) == [
        "contract_version", "classification", "embedded_engine", "provenance",
        "language", "blockers",
    ]
    return result


with tempfile.TemporaryDirectory(prefix="workbench-classifier-") as temporary:
    base = pathlib.Path(temporary)

    root = base / "generated"
    generated_root(root)
    result = diagnose(root)
    assert result["classification"] == "generated-minimal", result
    assert result["embedded_engine"]["state"] == "absent"

    root = base / "embedded-without-receipt"
    generated_root(root)
    write(root, "utils/task", b"#!/bin/sh\nexit 0\n", 0o755)
    result = diagnose_workspace(
        root,
        kernel("workbench/v1", False),
        generator_receipts=[generator],
        equivalence_receipt=None,
        legacy_engine_markers=["utils/task"],
    )
    assert result["classification"] == "malformed", result
    assert result["embedded_engine"] == {
        "state": "present-unverified",
        "equivalence_receipt_digest": None,
    }
    assert result["blockers"] == [{
        "code": "embedded-engine-unverified",
        "ref": "embedded-engine",
    }]

    root = base / "embedded"
    generated_root(root)
    write(root, engine_node["path"], engine_bytes, 0o755)
    result = diagnose(root)
    assert result["classification"] == "embedded-legacy"
    assert result["embedded_engine"]["state"] == "present-verified"

    root = base / "embedded-discovery-links"
    generated_root(root)
    write(root, "skills/task-start/SKILL.md", leaf_skill)
    write(root, "utils/task", engine_bytes, 0o755)
    (root / ".agents").mkdir()
    os.symlink("../skills", root / ".agents/skills")
    os.symlink("../skills", root / ".claude/skills")
    settings_before = (root / ".claude/settings.json").read_bytes()
    result = diagnose_workspace(
        root,
        kernel("workbench/v1", False),
        generator_receipts=[generator],
        equivalence_receipt=leaf_equivalence,
    )
    assert result["classification"] == "embedded-legacy", result
    assert result["embedded_engine"]["state"] == "present-verified", result
    for node in leaf_nodes:
        (root / node["path"]).unlink()
    result = diagnose_workspace(
        root,
        kernel("workbench/v1", False),
        generator_receipts=[generator],
        equivalence_receipt=leaf_equivalence,
    )
    assert result["classification"] == "generated-minimal", result
    assert result["embedded_engine"]["state"] == "absent", result
    assert (root / ".claude/settings.json").read_bytes() == settings_before

    root = base / "generated-drift"
    generated_root(root)
    write(root, "AGENTS.md", b"# Workbench\n\nmodified\n")
    assert diagnose(root)["classification"] == "malformed"

    root = base / "settings-drift"
    generated_root(root)
    write(root, ".claude/settings.json", b'{"extraKnownMarketplaces":[]}\n')
    assert diagnose(root)["classification"] == "malformed"

    root = base / "overlay-mode-drift"
    generated_root(root)
    (root / "AGENTS.overlay.md").chmod(0o755)
    assert diagnose(root)["classification"] == "malformed"

    root = base / "embedded-drift"
    generated_root(root)
    write(root, engine_node["path"], b"modified\n", 0o755)
    result = diagnose(root)
    assert result["classification"] == "malformed"
    assert result["embedded_engine"]["state"] == "present-unverified"

    root = base / "unrecognized"
    write(root, "README.md", b"unknown workspace\n")
    assert diagnose(root)["classification"] == "unrecognized"

    required = [
        (".workbench/schema", b"workbench/v2\n"),
        (".workbench/profile.conf", b"schema=workbench-profile/v1\nlanguage=en\n"),
        (".workbench/policy.conf", b"schema=workbench-policy/v1\n"),
        (".workbench/authority.json", canonical_bytes(descriptor)),
    ]
    for count in range(1, 4):
        root = base / f"partial-{count}"
        for path, content in required[:count]:
            write(root, path, content)
        assert diagnose(root, "workbench/v2", True)["classification"] == "malformed"

    root = base / "current"
    normative_root(root)
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current"
    assert result["provenance"]["state"] == "absent"
    assert result["language"] == "en"
    assert diagnose(root, "workbench/v2", False)["classification"] == "indeterminate"

    root = base / "generic-current"
    generic_descriptor = {
        **descriptor,
        "hosting_adapter": None,
        "hosting_ref": None,
    }
    write(root, ".workbench/schema", b"workbench/v2\n")
    write(
        root,
        ".workbench/profile.conf",
        b"# operator preference\n\nlanguage=ko\nschema=workbench-profile/v1\n",
    )
    write(
        root,
        ".workbench/policy.conf",
        (
            b"# conservative workspace policy\n"
            b"action.task.cleanup=deny\n\n"
            b"schema=workbench-policy/v1\n"
            b"action.task.complete=allow\n"
            b"action.task.concurrent-write=ask\n"
        ),
    )
    write(
        root,
        ".workbench/authority.json",
        json.dumps(
            dict(reversed(list(generic_descriptor.items()))),
            separators=(",", ":"),
        ).encode() + b"\n",
    )
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current", result
    assert result["language"] == "ko"

    for language_tag in ("i-klingon", "x-private"):
        root = base / f"current-language-{language_tag}"
        normative_root(root)
        write(
            root,
            ".workbench/profile.conf",
            (
                "schema=workbench-profile/v1\n"
                f"language={language_tag}\n"
            ).encode("ascii"),
        )
        result = diagnose(root, "workbench/v2", True)
        assert result["classification"] == "already-current", result
        assert result["language"] == language_tag

    for index, language_tag in enumerate((
        "en-u-ca-gregory-u-nu-latn",
        "en-a",
    )):
        root = base / f"invalid-language-{index}"
        normative_root(root)
        write(
            root,
            ".workbench/profile.conf",
            (
                "schema=workbench-profile/v1\n"
                f"language={language_tag}\n"
            ).encode("ascii"),
        )
        assert diagnose(root, "workbench/v2", True)["classification"] == "malformed"

    for path in (
        ".workbench/schema",
        ".workbench/profile.conf",
        ".workbench/policy.conf",
    ):
        root = base / ("current-no-final-lf-" + pathlib.Path(path).name)
        normative_root(root)
        target = root / path
        target.write_bytes(target.read_bytes().removesuffix(b"\n"))
        result = diagnose(root, "workbench/v2", True)
        assert result["classification"] == "already-current", (path, result)

    root = base / "current-generation-provenance"
    migration = migration_candidate(root)
    (root / ".workbench/migration.json").unlink()
    generation_language = {
        "contract_version": "workbench-kit-language-decision/v1",
        "tag": "en",
        "source": "generation-input",
        "source_ref": "generator:language",
        "digest": None,
    }
    generation_language["digest"] = canonical_digest(
        generation_language, null_field="digest"
    )
    generation = {
        "contract_version": "workbench-kit-generation-receipt/v1",
        "generator_receipt_digest": generator["receipt_digest"],
        "workspace_home": "workbench",
        "language": generation_language,
        "authority_descriptor_digest": canonical_digest(descriptor),
        "embedded_engine": {
            "state": "absent",
            "equivalence_receipt_digest": None,
        },
        "artifacts": migration["artifacts"],
        "candidate_basis_digest": None,
    }
    generation["candidate_basis_digest"] = canonical_digest(
        generation, null_field="candidate_basis_digest"
    )
    write(root, ".workbench/generation.json", canonical_bytes(generation))
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current"
    assert result["provenance"]["state"] == "valid"
    generation["candidate_basis_digest"] = None
    generation["authority_descriptor_digest"] = "sha256:" + "f" * 64
    generation["candidate_basis_digest"] = canonical_digest(
        generation, null_field="candidate_basis_digest"
    )
    write(root, ".workbench/generation.json", canonical_bytes(generation))
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current"
    assert result["provenance"]["state"] == "stale"

    root = base / "current-hardlink"
    normative_root(root)
    os.link(root / ".workbench/schema", root / ".workbench/schema.alias")
    assert diagnose(root, "workbench/v2", True)["classification"] == "malformed"

    root = base / "current-with-engine"
    normative_root(root)
    write(root, engine_node["path"], engine_bytes, 0o755)
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current"
    assert result["embedded_engine"]["state"] == "present-verified"
    write(root, "user-owned.txt", b"preserve\n")
    (root / engine_node["path"]).unlink()
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current", result
    assert result["embedded_engine"]["state"] == "absent", result
    assert (root / "legacy-engine").is_dir()
    assert (root / "user-owned.txt").read_bytes() == b"preserve\n"

    root = base / "staged"
    staged_root = root
    migration_candidate(root)
    result = diagnose(root, "workbench/v2", False)
    assert result["classification"] == "migration-staged"
    assert result["provenance"]["kind"] == "migration"
    assert result["provenance"]["state"] == "valid"
    assert diagnose(root, "workbench/v2", True)["classification"] == "already-current"

    root = base / "staged-language-drift"
    receipt = migration_candidate(root)
    receipt["candidate_basis_digest"] = None
    receipt["language"]["tag"] = "ko"
    receipt["language"]["digest"] = canonical_digest(
        receipt["language"], null_field="digest"
    )
    receipt["candidate_basis_digest"] = canonical_digest(
        receipt, null_field="candidate_basis_digest"
    )
    write(root, ".workbench/migration.json", canonical_bytes(receipt))
    result = diagnose(root, "workbench/v2", False)
    assert result["classification"] == "malformed"
    assert result["provenance"]["state"] == "stale"

    root = base / "staged-engine-drift"
    migration_candidate(root)
    write(root, engine_node["path"], engine_bytes, 0o755)
    result = diagnose(root, "workbench/v2", False)
    assert result["classification"] == "malformed"
    assert result["provenance"]["state"] == "stale"

    root = staged_root
    write(root, "AGENTS.md", b"post-merge governed evolution\n")
    current = diagnose(root, "workbench/v2", True)
    assert current["classification"] == "already-current"
    assert current["provenance"]["state"] == "stale"
    staged = diagnose(root, "workbench/v2", False)
    assert staged["classification"] == "malformed"

    root = base / "invalid-provenance-current"
    normative_root(root)
    write(root, ".workbench/migration.json", b"{invalid\n")
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current"
    assert result["provenance"] == {
        "kind": "migration",
        "state": "invalid",
        "receipt_digest": None,
        "ref": ".workbench/migration.json",
    }

    root = base / "unsafe-provenance-current"
    normative_root(root)
    write(root, ".workbench/migration.json", b"{}\n", 0o755)
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current"
    assert result["provenance"]["state"] == "invalid"

    root = base / "hardlinked-provenance-current"
    normative_root(root)
    write(root, ".workbench/migration.json", b"{}\n")
    os.link(
        root / ".workbench/migration.json",
        root / ".workbench/migration.json.alias",
    )
    result = diagnose(root, "workbench/v2", True)
    assert result["classification"] == "already-current"
    assert result["provenance"]["state"] == "invalid"

print("PASS: closed workspace classifier and provenance lifecycle")
PY

if find "$ROOT" -type d -name __pycache__ -print -quit | grep -q .; then
  echo "Python bytecode cache escaped upgrade tests" >&2
  exit 1
fi
