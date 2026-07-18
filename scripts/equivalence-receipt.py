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
ARCHIVE = ROOT / "tests/fixtures/legacy/workbench-ffb426f1-engine.tar.gz.b64"
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
OID = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")

sys.path.insert(0, str(KIT_ROOT / "lib"))
from workbench_kit_contracts import (  # noqa: E402
    canonical_bytes,
    canonical_digest,
    strict_load,
    validate_equivalence_receipt,
)


def die(message: str) -> None:
    raise SystemExit("equivalence-receipt: {}".format(message))


def raw_digest(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


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


def public_json(*arguments: str):
    process = subprocess.run(
        (str(WORKBENCH), *arguments),
        cwd=str(ROOT),
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


def safe_extract(destination: pathlib.Path) -> None:
    encoded = b"".join(ARCHIVE.read_bytes().split())
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
            "digest": raw_digest(target.encode("utf-8")),
            "link_target": target,
        }
    if not stat.S_ISREG(info.st_mode):
        die("legacy archive contains unsupported node: {}".format(relative))
    return {
        "path": relative,
        "node_type": "file",
        "mode": "100755" if info.st_mode & 0o111 else "100644",
        "digest": raw_digest(path.read_bytes()),
        "link_target": None,
    }


def archived_nodes():
    with tempfile.TemporaryDirectory(prefix="workbench-equivalence-") as raw:
        root = pathlib.Path(raw)
        safe_extract(root)
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
    rows = []
    for evidence_id, kind, relative in EVIDENCE:
        path = ROOT / relative
        if not path.is_file():
            die("missing evidence source: {}".format(relative))
        rows.append({
            "evidence_id": evidence_id,
            "kind": kind,
            "source_ref": (
                "https://github.com/YOOGOMJA/workbench-kit/blob/{}/{}".format(
                    replacement_revision, relative
                )
            ),
            "source_revision": replacement_revision,
            "digest": raw_digest(path.read_bytes()),
        })
    rows.sort(key=lambda item: (item["kind"], item["evidence_id"]))
    return rows


def build(replacement_revision: str):
    if OID.fullmatch(replacement_revision) is None:
        die("replacement revision must be a full Git object ID")
    manifest = public_json("engine-manifest", "show", "--format", "json")
    contract = public_json("contract", "show", "--format", "json")
    version = manifest["plugin"]["version"]
    if (
        manifest["plugin"]["name"] != "workbench"
        or contract["engine"] != {"name": "workbench", "version": version}
    ):
        die("public engine manifest and contract identities disagree")
    capabilities = contract["capabilities"]
    if capabilities != sorted(capabilities) or len(capabilities) != len(set(capabilities)):
        die("public engine capabilities are not sorted and unique")
    removable, discovery = archived_nodes()
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
        die("activated receipt does not match its current public sources")
    print(
        "PASS: exact legacy manifest, public engine contract, and evidence are receipt-bound"
    )


def generate(output: pathlib.Path, replacement_revision: str) -> None:
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
