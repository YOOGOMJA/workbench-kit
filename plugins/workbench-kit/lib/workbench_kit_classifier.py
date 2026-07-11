"""Closed local fingerprints for workbench upgrade diagnosis."""

from __future__ import annotations

import base64
import json
import os
import pathlib
import stat
from typing import Any, Iterable

from workbench_kit_contracts import (
    BCP47,
    ContractError,
    canonical_bytes,
    canonical_digest,
    node_digest,
    strict_load,
    validate_descriptor,
    validate_equivalence_receipt,
    validate_generation_receipt,
    validate_generator_receipt,
    validate_link_target,
    validate_migration_receipt,
)


DIAGNOSIS_FIELDS = (
    "contract_version",
    "classification",
    "embedded_engine",
    "provenance",
    "language",
    "blockers",
)
NORMATIVE_PATHS = (
    ".workbench/schema",
    ".workbench/profile.conf",
    ".workbench/policy.conf",
    ".workbench/authority.json",
)


class InspectionError(RuntimeError):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


class StaticInspectionError(InspectionError):
    """A deterministic local node violation, not a transient read failure."""


def _blocker(code: str, ref: str) -> dict[str, str]:
    return {"code": code, "ref": ref}


def _result(
    classification: str,
    embedded: dict[str, Any],
    provenance: dict[str, Any],
    language: str | None,
    blockers: Iterable[dict[str, str]] = (),
) -> dict[str, Any]:
    normalized_blockers = sorted(blockers, key=lambda item: (item["code"], item["ref"]))
    return {
        "contract_version": "workbench-kit-diagnosis/v1",
        "classification": classification,
        "embedded_engine": embedded,
        "provenance": provenance,
        "language": language,
        "blockers": normalized_blockers,
    }


def _safe_target(root: pathlib.Path, relative: str) -> pathlib.Path:
    target = root.joinpath(*pathlib.PurePosixPath(relative).parts)
    current = root
    try:
        root_stat = os.lstat(root)
    except OSError as error:
        raise InspectionError("workspace-unreadable", str(root)) from error
    if not stat.S_ISDIR(root_stat.st_mode) or stat.S_ISLNK(root_stat.st_mode):
        raise StaticInspectionError("workspace-unsafe", str(root))
    for part in pathlib.PurePosixPath(relative).parts[:-1]:
        current = current / part
        try:
            current_stat = os.lstat(current)
        except FileNotFoundError:
            break
        except OSError as error:
            raise InspectionError("node-unreadable", relative) from error
        if not stat.S_ISDIR(current_stat.st_mode) or stat.S_ISLNK(current_stat.st_mode):
            raise StaticInspectionError("node-parent-unsafe", relative)
    return target


def _inspect_node(root: pathlib.Path, relative: str) -> dict[str, Any]:
    target = _safe_target(root, relative)
    try:
        node_stat = os.lstat(target)
    except FileNotFoundError:
        return {
            "node_type": "absent",
            "mode": None,
            "digest": None,
            "link_target": None,
            "content": None,
        }
    except OSError as error:
        raise InspectionError("node-unreadable", relative) from error
    if stat.S_ISREG(node_stat.st_mode):
        if node_stat.st_nlink != 1:
            raise StaticInspectionError("node-hardlink", relative)
        permissions = stat.S_IMODE(node_stat.st_mode)
        if permissions == 0o644:
            mode = "100644"
        elif permissions == 0o755:
            mode = "100755"
        else:
            raise StaticInspectionError("node-mode-invalid", relative)
        try:
            content = target.read_bytes()
        except OSError as error:
            raise InspectionError("node-unreadable", relative) from error
        return {
            "node_type": "file",
            "mode": mode,
            "digest": node_digest("file", mode, content=content),
            "link_target": None,
            "content": content,
        }
    if stat.S_ISLNK(node_stat.st_mode):
        try:
            link_target = os.readlink(target)
        except OSError as error:
            raise InspectionError("node-unreadable", relative) from error
        try:
            validate_link_target(relative, link_target, relative)
        except ContractError as error:
            raise StaticInspectionError("symlink-target-invalid", relative) from error
        return {
            "node_type": "symlink",
            "mode": "120000",
            "digest": node_digest("symlink", "120000", link_target=link_target),
            "link_target": link_target,
            "content": None,
        }
    if stat.S_ISDIR(node_stat.st_mode):
        return {
            "node_type": "directory",
            "mode": f"04{stat.S_IMODE(node_stat.st_mode):04o}",
            "digest": node_digest(
                "directory", f"04{stat.S_IMODE(node_stat.st_mode):04o}"
            ),
            "link_target": None,
            "content": None,
        }
    raise StaticInspectionError("node-type-invalid", relative)


def _node_matches(node: dict[str, Any], expected: dict[str, Any]) -> bool:
    return all(node[field] == expected[field] for field in (
        "node_type", "mode", "digest", "link_target"
    ))


def _owned_settings_match(root: pathlib.Path) -> tuple[bool, bool]:
    node = _inspect_node(root, ".claude/settings.json")
    if node["node_type"] == "absent":
        return False, False
    if node["node_type"] != "file" or node["mode"] != "100644":
        return False, True
    try:
        settings = strict_load(node["content"], ".claude/settings.json")
    except ContractError:
        return False, True
    if not isinstance(settings, dict):
        return False, True
    marketplaces = settings.get("extraKnownMarketplaces", {})
    plugins = settings.get("enabledPlugins", {})
    if not isinstance(marketplaces, dict) or not isinstance(plugins, dict):
        return False, True
    marketplace = marketplaces.get("workbench-kit")
    enabled = plugins.get("workbench@workbench-kit")
    recognized = marketplace is not None or enabled is not None
    expected_marketplace = {
        "source": {"source": "github", "repo": "YOOGOMJA/workbench-kit"}
    }
    return marketplace == expected_marketplace and enabled is True, recognized


def _generator_fingerprint(
    root: pathlib.Path, receipts: Iterable[dict[str, Any]]
) -> tuple[bool, bool]:
    agents = _inspect_node(root, "AGENTS.md")
    overlay = _inspect_node(root, "AGENTS.overlay.md")
    claude = _inspect_node(root, "CLAUDE.md")
    settings_match, settings_recognized = _owned_settings_match(root)
    recognized = settings_recognized
    for raw_receipt in receipts:
        receipt = validate_generator_receipt(raw_receipt)
        header = base64.b64decode(receipt["header_base64"], validate=True)
        core = base64.b64decode(receipt["core_base64"], validate=True)
        separator = base64.b64decode(receipt["separator_base64"], validate=True)
        if agents["node_type"] == "file" and agents["content"].startswith(header):
            recognized = True
        overlay_bytes = b"" if overlay["node_type"] == "absent" else overlay["content"]
        if overlay["node_type"] not in ("absent", "file") or (
            overlay["node_type"] == "file" and overlay["mode"] != "100644"
        ):
            continue
        expected_agents = header + core + separator + overlay_bytes
        if (
            agents["node_type"] != "file"
            or agents["mode"] != "100644"
            or agents["content"] != expected_agents
            or not settings_match
        ):
            continue
        generated = {item["path"]: item for item in receipt["generated_nodes"]}
        claude_spec = generated["CLAUDE.md"]
        if claude_spec["node_type"] == "file":
            claude_matches = (
                claude["node_type"] == "file"
                and claude["mode"] == "100644"
                and claude["content"] == expected_agents
            )
        else:
            claude_matches = (
                claude["node_type"] == "symlink"
                and claude["link_target"] == "AGENTS.md"
            )
        if claude_matches:
            return True, True
    return False, recognized


def _enumerate_owned_root(root: pathlib.Path, relative: str) -> tuple[bool, set[str]]:
    node = _inspect_node(root, relative)
    if node["node_type"] == "absent":
        return False, set()
    if node["node_type"] != "directory":
        return True, {relative}
    found: set[str] = set()
    target = root.joinpath(*pathlib.PurePosixPath(relative).parts)
    for current, directories, files in os.walk(target, topdown=True, followlinks=False):
        current_path = pathlib.Path(current)
        next_directories = []
        for name in sorted(directories):
            path = current_path / name
            relative_path = path.relative_to(root).as_posix()
            if path.is_symlink():
                found.add(relative_path)
            else:
                next_directories.append(name)
        directories[:] = next_directories
        for name in sorted(files):
            found.add((current_path / name).relative_to(root).as_posix())
    return True, found


def _embedded_fingerprint(
    root: pathlib.Path, raw_receipt: dict[str, Any] | None
) -> dict[str, Any]:
    if raw_receipt is None:
        return {"state": "absent", "equivalence_receipt_digest": None}
    receipt = validate_equivalence_receipt(raw_receipt)
    receipt_digest = canonical_digest(receipt)
    present = False
    actual_paths: set[str] = set()
    for owned_root in receipt["allowed_roots"]:
        root_present, found = _enumerate_owned_root(root, owned_root)
        present = present or root_present
        actual_paths.update(found)
    for link in receipt["discovery_links"]:
        if _inspect_node(root, link["path"])["node_type"] != "absent":
            present = True
    expected_paths = {item["path"] for item in receipt["removable_nodes"]}
    if not present and not actual_paths:
        return {"state": "absent", "equivalence_receipt_digest": None}
    if actual_paths != expected_paths:
        return {"state": "present-unverified", "equivalence_receipt_digest": None}
    for expected in receipt["removable_nodes"]:
        if not _node_matches(_inspect_node(root, expected["path"]), expected):
            return {"state": "present-unverified", "equivalence_receipt_digest": None}
    return {
        "state": "present-verified",
        "equivalence_receipt_digest": receipt_digest,
    }


def _receipt_provenance(
    root: pathlib.Path,
    embedded: dict[str, Any],
    generator_receipts: Iterable[dict[str, Any]],
) -> dict[str, Any]:
    candidates = (
        ("migration", ".workbench/migration.json", validate_migration_receipt),
        ("generation", ".workbench/generation.json", validate_generation_receipt),
    )
    present = []
    for kind, path, validator in candidates:
        try:
            node = _inspect_node(root, path)
        except StaticInspectionError:
            present.append((kind, path, validator, None))
            continue
        if node["node_type"] != "absent":
            present.append((kind, path, validator, node))
    if not present:
        return {"kind": None, "state": "absent", "receipt_digest": None, "ref": None}
    kind, path, validator, node = present[0]
    if (
        len(present) != 1
        or node is None
        or node["node_type"] != "file"
        or node["mode"] != "100644"
    ):
        return {"kind": kind, "state": "invalid", "receipt_digest": None, "ref": path}
    try:
        receipt = validator(strict_load(node["content"], path))
    except ContractError:
        return {"kind": kind, "state": "invalid", "receipt_digest": None, "ref": path}
    if node["content"] != canonical_bytes(receipt):
        return {"kind": kind, "state": "invalid", "receipt_digest": None, "ref": path}
    receipt_digest = receipt["candidate_basis_digest"]
    if kind == "generation":
        known_generators = {
            validate_generator_receipt(item)["receipt_digest"]
            for item in generator_receipts
        }
        authority = _inspect_node(root, ".workbench/authority.json")
        try:
            descriptor = validate_descriptor(
                strict_load(authority["content"], ".workbench/authority.json")
            )
        except (ContractError, TypeError):
            descriptor = None
        if (
            receipt["generator_receipt_digest"] not in known_generators
            or descriptor is None
            or receipt["authority_descriptor_digest"] != canonical_digest(descriptor)
        ):
            return {
                "kind": kind,
                "state": "stale",
                "receipt_digest": receipt_digest,
                "ref": path,
            }
    if kind == "migration":
        expected_embedded = {
            "state": receipt["embedded_engine"]["after"],
            "equivalence_receipt_digest": receipt["embedded_engine"][
                "equivalence_receipt_digest"
            ],
        }
    else:
        expected_embedded = receipt["embedded_engine"]
    if embedded != expected_embedded:
        return {
            "kind": kind,
            "state": "stale",
            "receipt_digest": receipt_digest,
            "ref": path,
        }
    profile = _inspect_node(root, ".workbench/profile.conf")
    expected_profile = (
        "schema=workbench-profile/v1\nlanguage="
        + receipt["language"]["tag"]
        + "\n"
    ).encode("ascii")
    if profile["node_type"] != "file" or profile["content"] != expected_profile:
        return {
            "kind": kind,
            "state": "stale",
            "receipt_digest": receipt_digest,
            "ref": path,
        }
    for expected in receipt["artifacts"]:
        try:
            actual = _inspect_node(root, expected["path"])
        except StaticInspectionError:
            actual = {"node_type": None, "mode": None, "digest": None}
        if any(actual[field] != expected[field] for field in (
            "node_type", "mode", "digest"
        )):
            return {
                "kind": kind,
                "state": "stale",
                "receipt_digest": receipt_digest,
                "ref": path,
            }
    return {
        "kind": kind,
        "state": "valid",
        "receipt_digest": receipt_digest,
        "ref": path,
    }


def _normative_v2(root: pathlib.Path) -> tuple[bool, str | None]:
    schema = _inspect_node(root, ".workbench/schema")
    profile = _inspect_node(root, ".workbench/profile.conf")
    policy = _inspect_node(root, ".workbench/policy.conf")
    authority = _inspect_node(root, ".workbench/authority.json")
    if any(node["node_type"] != "file" or node["mode"] != "100644" for node in (
        schema, profile, policy, authority
    )):
        return False, None
    if schema["content"] != b"workbench/v2\n":
        return False, None
    try:
        profile_text = profile["content"].decode("ascii")
    except UnicodeDecodeError:
        return False, None
    lines = profile_text.splitlines(keepends=True)
    if (
        len(lines) != 2
        or lines[0] != "schema=workbench-profile/v1\n"
        or not lines[1].startswith("language=")
        or not lines[1].endswith("\n")
    ):
        return False, None
    language = lines[1][len("language=") : -1]
    if BCP47.fullmatch(language) is None:
        return False, None
    if policy["content"] != b"schema=workbench-policy/v1\n":
        return False, None
    try:
        descriptor = validate_descriptor(strict_load(authority["content"], ".workbench/authority.json"))
    except ContractError:
        return False, None
    if authority["content"] != canonical_bytes(descriptor):
        return False, None
    return True, language


def diagnose_workspace(
    workspace: pathlib.Path,
    public_snapshot: dict[str, Any],
    *,
    generator_receipts: Iterable[dict[str, Any]] = (),
    equivalence_receipt: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root = workspace.resolve(strict=True)
    try:
        schema = public_snapshot["contract"]["workspace"]["schema"]
        doctor_ready = public_snapshot["doctor"]["ready"]
        if schema not in ("workbench/v1", "workbench/v2") or not isinstance(
            doctor_ready, bool
        ):
            raise InspectionError("public-snapshot-invalid", "contract/doctor")
        embedded = _embedded_fingerprint(root, equivalence_receipt)
        generator_receipts = tuple(generator_receipts)
        provenance = _receipt_provenance(root, embedded, generator_receipts)
        normative_nodes = [_inspect_node(root, path) for path in NORMATIVE_PATHS]
        normative_count = sum(node["node_type"] != "absent" for node in normative_nodes)
        has_v2_receipt = provenance["state"] != "absent"

        if 0 < normative_count < len(NORMATIVE_PATHS) or (
            normative_count == 0 and has_v2_receipt
        ):
            return _result(
                "malformed",
                embedded,
                provenance,
                None,
                [_blocker("partial-v2", ".workbench")],
            )
        if normative_count == len(NORMATIVE_PATHS):
            valid, language = _normative_v2(root)
            if not valid or schema != "workbench/v2":
                return _result(
                    "malformed",
                    embedded,
                    provenance,
                    language,
                    [_blocker("v2-contract-invalid", ".workbench")],
                )
            if embedded["state"] == "present-unverified":
                return _result(
                    "malformed",
                    embedded,
                    provenance,
                    language,
                    [_blocker("embedded-engine-unverified", "embedded-engine")],
                )
            if doctor_ready:
                return _result("already-current", embedded, provenance, language)
            if provenance["kind"] == "migration" and provenance["state"] == "valid":
                return _result("migration-staged", embedded, provenance, language)
            if provenance["kind"] == "migration" and provenance["state"] in (
                "stale", "invalid"
            ):
                return _result(
                    "malformed",
                    embedded,
                    provenance,
                    language,
                    [_blocker("migration-receipt-invalid", provenance["ref"])],
                )
            return _result(
                "indeterminate",
                embedded,
                provenance,
                language,
                [_blocker("doctor-not-ready", "protected-default")],
            )

        if schema != "workbench/v1":
            return _result(
                "malformed",
                embedded,
                provenance,
                None,
                [_blocker("schema-state-mismatch", ".workbench/schema")],
            )
        generated, recognized = _generator_fingerprint(root, generator_receipts)
        if embedded["state"] == "present-unverified":
            return _result(
                "malformed",
                embedded,
                provenance,
                None,
                [_blocker("embedded-engine-unverified", "embedded-engine")],
            )
        if embedded["state"] == "present-verified":
            if generated:
                return _result("embedded-legacy", embedded, provenance, None)
            return _result(
                "malformed",
                embedded,
                provenance,
                None,
                [_blocker("generator-composition-invalid", "AGENTS.md")],
            )
        if generated:
            return _result("generated-minimal", embedded, provenance, None)
        if recognized:
            return _result(
                "malformed",
                embedded,
                provenance,
                None,
                [_blocker("generator-composition-invalid", "AGENTS.md")],
            )
        return _result("unrecognized", embedded, provenance, None)
    except StaticInspectionError as error:
        return _result(
            "malformed",
            {"state": "indeterminate", "equivalence_receipt_digest": None},
            {"kind": None, "state": "absent", "receipt_digest": None, "ref": None},
            None,
            [_blocker(error.code, error.ref)],
        )
    except (ContractError, InspectionError, OSError, UnicodeError, json.JSONDecodeError) as error:
        ref = getattr(error, "ref", str(root))
        return _result(
            "indeterminate",
            {"state": "indeterminate", "equivalence_receipt_digest": None},
            {"kind": None, "state": "absent", "receipt_digest": None, "ref": None},
            None,
            [_blocker("inspection-incomplete", ref)],
        )
