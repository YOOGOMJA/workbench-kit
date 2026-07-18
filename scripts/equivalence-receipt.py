#!/usr/bin/env python3
"""Generate or verify the source-bound embedded-engine equivalence receipt."""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
KIT_ROOT = ROOT / "plugins/workbench-kit"
WORKBENCH = ROOT / "plugins/workbench/bin/workbench"
WORKBENCH_RELATIVE = "plugins/workbench"
ARCHIVE_RELATIVE = "tests/fixtures/legacy/workbench-ffb426f1-engine.tar.gz.b64"
RUNTIME = KIT_ROOT / "receipts/upgrade-runtime.json"
RECEIPT_RELATIVE = "receipts/workbench-ffb426f1-equivalence.json"
LEGACY_SOURCE_REF = "https://github.com/YOOGOMJA/workbench"
LEGACY_SOURCE_REVISION = "ffb426f1c316485c56950e599b7560d155fd220c"
ALLOWED_ROOTS = [".agents/skills", ".claude/skills", "skills", "utils"]
DISCOVERY_PATHS = {".agents/skills", ".claude/skills"}
EVIDENCE = [
    ("workbench-public-contract", "contract-test", "plugins/workbench/tests/contract.sh"),
    ("three-plugin-public-e2e", "integration-test", "tests/cross_plugin_e2e.py"),
    (
        "workbench-ffb426f1-engine-archive",
        "manifest-audit",
        "tests/fixtures/legacy/workbench-ffb426f1-engine.tar.gz.b64",
    ),
]
BOUND_SOURCE_PATHS = [WORKBENCH_RELATIVE] + [item[2] for item in EVIDENCE]
OID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")

sys.dont_write_bytecode = True
sys.path.insert(0, str(KIT_ROOT / "lib"))
from workbench_kit_contracts import (  # noqa: E402
    canonical_bytes,
    canonical_digest,
    node_digest,
    strict_load,
    validate_equivalence_receipt,
)


def die(message: str) -> None:
    raise SystemExit("equivalence-receipt: {}".format(message))


def raw_digest(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def git_bytes(*arguments: str) -> bytes:
    process = subprocess.run(
        ("git", "-C", str(ROOT), *arguments),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        detail = process.stderr.decode("utf-8", errors="replace").strip()
        die("Git {} failed: {}".format(" ".join(arguments), detail))
    return process.stdout


def require_commit(revision: str) -> None:
    if OID.fullmatch(revision) is None:
        die("replacement revision must be a full Git object ID")
    kind = git_bytes("cat-file", "-t", revision).decode("ascii").strip()
    if kind != "commit":
        die("replacement revision is not a commit: {}".format(revision))
    resolved = git_bytes("rev-parse", "--verify", revision).decode("ascii").strip()
    if resolved != revision:
        die("replacement revision did not resolve exactly: {}".format(revision))


def git_blob(revision: str, relative: str) -> bytes:
    path = pathlib.PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        die("invalid revision-relative path: {}".format(relative))
    specifier = "{}:{}".format(revision, relative)
    kind = git_bytes("cat-file", "-t", specifier).decode("ascii").strip()
    if kind != "blob":
        die("revision source is not a blob: {}".format(specifier))
    return git_bytes("cat-file", "blob", specifier)


def evidence_tag(version: str) -> str:
    if not isinstance(version, str) or not version:
        die("replacement plugin version is unavailable")
    return "workbench-equivalence-v{}".format(version)


def require_evidence_tag(revision: str, version: str) -> str:
    tag = evidence_tag(version)
    resolved = git_bytes(
        "rev-parse", "--verify", "refs/tags/{}^{{commit}}".format(tag)
    ).decode("ascii").strip()
    if resolved != revision:
        die(
            "evidence tag {} points to {}, expected {}".format(
                tag, resolved, revision
            )
        )
    return tag


def require_bound_worktree(revision: str) -> None:
    process = subprocess.run(
        ("git", "-C", str(ROOT), "diff", "--quiet", revision, "--", *BOUND_SOURCE_PATHS)
    )
    if process.returncode == 1:
        die("checked-out evidence sources differ from {}".format(revision))
    if process.returncode != 0:
        die("cannot compare checked-out evidence sources to {}".format(revision))
    untracked = git_bytes(
        "ls-files", "--others", "--exclude-standard", "--", *BOUND_SOURCE_PATHS
    )
    if untracked:
        die("checked-out evidence sources contain untracked paths")


def public_digest(value) -> str:
    raw = (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")
    return raw_digest(raw)


def public_json(
    *arguments: str,
    workbench: pathlib.Path = WORKBENCH,
    plugin_root: pathlib.Path = ROOT / "plugins/workbench",
):
    environment = os.environ.copy()
    environment["CLAUDE_PLUGIN_ROOT"] = str(plugin_root)
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    process = subprocess.run(
        (str(workbench), *arguments),
        cwd=str(ROOT),
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        die(
            "public workbench command failed: {}\n{}".format(
                " ".join(arguments), process.stderr
            )
        )
    try:
        return json.loads(process.stdout)
    except json.JSONDecodeError as error:
        die("public workbench command emitted invalid JSON: {}".format(error))


def safe_extract_git_archive(raw: bytes, destination: pathlib.Path) -> None:
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
        for member in archive.getmembers():
            path = pathlib.PurePosixPath(member.name)
            under_workbench = path.parts == ("plugins",) or tuple(
                path.parts[:2]
            ) == ("plugins", "workbench")
            if path.is_absolute() or ".." in path.parts or not under_workbench:
                die("unsafe replacement archive member: {}".format(member.name))
            if member.issym():
                target = pathlib.PurePosixPath(member.linkname)
                if target.is_absolute() or ".." in target.parts:
                    die("unsafe replacement archive symlink: {}".format(member.name))
            if not (member.isdir() or member.isreg() or member.issym()):
                die("unsupported replacement archive node: {}".format(member.name))
        archive.extractall(str(destination))


def revision_public_state(replacement_revision: str):
    require_commit(replacement_revision)
    archive = git_bytes(
        "archive", "--format=tar", replacement_revision, "--", WORKBENCH_RELATIVE
    )
    with tempfile.TemporaryDirectory(prefix="workbench-replacement-") as raw:
        root = pathlib.Path(raw)
        safe_extract_git_archive(archive, root)
        plugin_root = root / WORKBENCH_RELATIVE
        workbench = plugin_root / "bin/workbench"
        if not workbench.is_file():
            die("replacement revision has no public workbench dispatcher")
        manifest = public_json(
            "engine-manifest",
            "show",
            "--format",
            "json",
            workbench=workbench,
            plugin_root=plugin_root,
        )
        contract = public_json(
            "contract",
            "show",
            "--format",
            "json",
            workbench=workbench,
            plugin_root=plugin_root,
        )
    return manifest, contract


def safe_extract(destination: pathlib.Path, encoded_source: bytes) -> None:
    encoded = b"".join(encoded_source.split())
    try:
        compressed = base64.b64decode(encoded, validate=True)
    except ValueError as error:
        die("legacy archive is not canonical base64: {}".format(error))
    with tarfile.open(fileobj=io.BytesIO(compressed), mode="r:gz") as archive:
        for member in archive.getmembers():
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                die("unsafe legacy archive member: {}".format(member.name))
            if member.issym() and pathlib.PurePosixPath(member.linkname).is_absolute():
                die("unsafe legacy archive symlink: {}".format(member.name))
        archive.extractall(str(destination))


def node(path: pathlib.Path, relative: str):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        target = os.readlink(str(path))
        return {
            "path": relative,
            "node_type": "symlink",
            "mode": "120000",
            "digest": node_digest("symlink", "120000", link_target=target),
            "link_target": target,
        }
    if not stat.S_ISREG(info.st_mode):
        die("legacy archive contains unsupported node: {}".format(relative))
    mode = "100755" if info.st_mode & 0o111 else "100644"
    return {
        "path": relative,
        "node_type": "file",
        "mode": mode,
        "digest": node_digest("file", mode, content=path.read_bytes()),
        "link_target": None,
    }


def archived_nodes(replacement_revision: str):
    encoded = git_blob(replacement_revision, ARCHIVE_RELATIVE)
    with tempfile.TemporaryDirectory(prefix="workbench-equivalence-") as raw:
        root = pathlib.Path(raw)
        safe_extract(root, encoded)
        rows = []
        for allowed in ALLOWED_ROOTS:
            candidate = root / allowed
            if not os.path.lexists(str(candidate)):
                die("legacy archive is missing allowed root: {}".format(allowed))
            if candidate.is_symlink() or candidate.is_file():
                rows.append(node(candidate, allowed))
                continue
            for current, directories, files in os.walk(
                str(candidate), topdown=True, followlinks=False
            ):
                current_path = pathlib.Path(current)
                symlink_directories = []
                for name in sorted(directories):
                    path = current_path / name
                    if path.is_symlink():
                        relative = path.relative_to(root).as_posix()
                        rows.append(node(path, relative))
                        symlink_directories.append(name)
                directories[:] = sorted(
                    name for name in directories if name not in symlink_directories
                )
                for name in sorted(files):
                    path = current_path / name
                    relative = path.relative_to(root).as_posix()
                    rows.append(node(path, relative))
        rows.sort(key=lambda item: item["path"])
        paths = [item["path"] for item in rows]
        if len(paths) != len(set(paths)):
            die("legacy archive contains duplicate removable paths")
        discovery = [item for item in rows if item["path"] in DISCOVERY_PATHS]
        if {item["path"] for item in discovery} != DISCOVERY_PATHS:
            die("legacy archive discovery links are incomplete")
        if any(item["node_type"] != "symlink" for item in discovery):
            die("legacy archive discovery entry is not a symlink")
        return rows, discovery


def evidence(replacement_revision: str):
    require_commit(replacement_revision)
    rows = []
    for evidence_id, kind, relative in EVIDENCE:
        source = git_blob(replacement_revision, relative)
        rows.append({
            "evidence_id": evidence_id,
            "kind": kind,
            "source_ref": (
                "https://github.com/YOOGOMJA/workbench-kit/blob/{}/{}".format(
                    replacement_revision, relative
                )
            ),
            "source_revision": replacement_revision,
            "digest": raw_digest(source),
        })
    rows.sort(key=lambda item: (item["kind"], item["evidence_id"]))
    return rows


def build(replacement_revision: str):
    require_commit(replacement_revision)
    manifest, contract = revision_public_state(replacement_revision)
    version = manifest["plugin"]["version"]
    if (
        manifest["plugin"]["name"] != "workbench"
        or contract["engine"] != {"name": "workbench", "version": version}
    ):
        die("public engine manifest and contract identities disagree")
    require_evidence_tag(replacement_revision, version)
    advertised_capabilities = contract["capabilities"]
    if (
        not isinstance(advertised_capabilities, list)
        or not all(isinstance(item, str) and item for item in advertised_capabilities)
        or len(advertised_capabilities) != len(set(advertised_capabilities))
    ):
        die("public engine capabilities are not unique non-empty strings")
    capabilities = sorted(advertised_capabilities)
    removable, discovery = archived_nodes(replacement_revision)
    legacy_manifest = {
        "contract_version": "workbench-legacy-engine-manifest/v1",
        "source_ref": LEGACY_SOURCE_REF,
        "source_revision": LEGACY_SOURCE_REVISION,
        "allowed_roots": ALLOWED_ROOTS,
        "removable_nodes": removable,
        "discovery_links": discovery,
    }
    receipt = {
        "contract_version": "workbench-plugin-equivalence/v1",
        "receipt_id": "workbench-0.2.0-replaces-workbench-ffb426f1",
        "replacement_plugin": {
            "plugin_name": "workbench",
            "plugin_version": version,
            "source_revision": replacement_revision,
            "plugin_manifest_digest": manifest["digest"],
            "source_ref": (
                "https://github.com/YOOGOMJA/workbench-kit/tree/{}/plugins/workbench".format(
                    replacement_revision
                )
            ),
        },
        "public_contract": {
            "contract_version": contract["contract_version"],
            "engine_name": contract["engine"]["name"],
            "engine_version": contract["engine"]["version"],
            "supported_object_digest": public_digest(contract["supported"]),
            "capabilities": capabilities,
        },
        "required_capabilities": capabilities,
        "legacy_source": {
            "source_ref": LEGACY_SOURCE_REF,
            "source_revision": LEGACY_SOURCE_REVISION,
        },
        "legacy_manifest_digest": canonical_digest(legacy_manifest),
        "allowed_roots": ALLOWED_ROOTS,
        "removable_nodes": removable,
        "discovery_links": discovery,
        "verification_evidence": evidence(replacement_revision),
    }
    return validate_equivalence_receipt(receipt)


def check() -> None:
    runtime = strict_load(RUNTIME.read_bytes(), str(RUNTIME))
    if runtime.get("plugin_equivalence_file") != RECEIPT_RELATIVE:
        die("upgrade runtime does not activate {}".format(RECEIPT_RELATIVE))
    receipt_path = KIT_ROOT / RECEIPT_RELATIVE
    try:
        raw = receipt_path.read_bytes()
    except OSError as error:
        die("cannot read activated receipt: {}".format(error))
    receipt = validate_equivalence_receipt(strict_load(raw, str(receipt_path)))
    if raw != canonical_bytes(receipt):
        die("activated receipt is not canonical JSON")
    revision = receipt["replacement_plugin"]["source_revision"]
    expected = build(revision)
    if receipt != expected:
        die("activated receipt does not match its recorded Git revision")
    print(
        "PASS: exact legacy manifest, public engine contract, and evidence are receipt-bound"
    )


def generate(output: pathlib.Path, replacement_revision: str) -> None:
    require_bound_worktree(replacement_revision)
    receipt = build(replacement_revision)
    if output.resolve() != (KIT_ROOT / RECEIPT_RELATIVE).resolve():
        die("output must be {}".format(KIT_ROOT / RECEIPT_RELATIVE))
    output.write_bytes(canonical_bytes(receipt))
    print("wrote {}".format(output.relative_to(ROOT)))


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    create = commands.add_parser("generate")
    create.add_argument("--replacement-revision", required=True)
    create.add_argument(
        "--output", type=pathlib.Path, default=KIT_ROOT / RECEIPT_RELATIVE
    )
    return root


def main() -> None:
    arguments = parser().parse_args()
    if arguments.command == "check":
        check()
    else:
        generate(arguments.output, arguments.replacement_revision)


if __name__ == "__main__":
    main()
