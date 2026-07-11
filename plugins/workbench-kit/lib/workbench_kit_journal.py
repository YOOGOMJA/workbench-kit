"""Durable journal construction for governed workbench upgrades."""

from __future__ import annotations

import base64
import os
import pathlib
import stat
from typing import Any

from workbench_kit_classifier import _inspect_node
from workbench_kit_contracts import (
    canonical_bytes,
    canonical_digest,
    decode_artifact,
    node_digest,
    validate_journal,
    validate_plan,
    workspace_identifier,
)


class JournalError(RuntimeError):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


def _lstat_directory(path: pathlib.Path, code: str) -> os.stat_result:
    try:
        node = os.lstat(path)
    except OSError as error:
        raise JournalError(code, str(path)) from error
    if not stat.S_ISDIR(node.st_mode) or stat.S_ISLNK(node.st_mode):
        raise JournalError(code, str(path))
    return node


def _walk_existing_directories(path: pathlib.Path, code: str) -> pathlib.Path:
    if not path.is_absolute():
        raise JournalError("journal-root-invalid", str(path))
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        _lstat_directory(current, code)
    return current


def _require_owned_safe_directory(
    path: pathlib.Path, code: str, *, private: bool
) -> os.stat_result:
    node = _lstat_directory(path, code)
    permissions = stat.S_IMODE(node.st_mode)
    if (
        node.st_uid != os.getuid()
        or permissions & 0o022
        or (private and permissions != 0o700)
    ):
        raise JournalError(code, str(path))
    return node


def _ensure_private_child(parent: pathlib.Path, name: str) -> pathlib.Path:
    target = parent / name
    try:
        os.mkdir(target, 0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise JournalError("journal-root-unsafe", str(target)) from error
    _require_owned_safe_directory(target, "journal-root-unsafe", private=True)
    return target


def _default_journal_root(environment: dict[str, str]) -> pathlib.Path:
    xdg = environment.get("XDG_STATE_HOME")
    if xdg:
        base = pathlib.Path(xdg)
        if not base.is_absolute():
            raise JournalError("journal-root-invalid", xdg)
        base = _walk_existing_directories(base, "journal-root-unsafe")
        _require_owned_safe_directory(base, "journal-root-unsafe", private=False)
    else:
        home = environment.get("HOME")
        if not home or not pathlib.Path(home).is_absolute():
            raise JournalError("journal-root-invalid", "HOME")
        home_path = _walk_existing_directories(
            pathlib.Path(home), "journal-root-unsafe"
        )
        _require_owned_safe_directory(
            home_path, "journal-root-unsafe", private=False
        )
        local = home_path / ".local"
        state_root = local / "state"
        for directory in (local, state_root):
            try:
                os.mkdir(directory, 0o700)
            except FileExistsError:
                pass
            except OSError as error:
                raise JournalError(
                    "journal-root-unsafe", str(directory)
                ) from error
            _require_owned_safe_directory(
                directory, "journal-root-unsafe", private=False
            )
        base = state_root
    kit = _ensure_private_child(base, "workbench-kit")
    return _ensure_private_child(kit, "upgrades")


def resolve_journal_location(
    workspace: pathlib.Path,
    plan_digest: str,
    *,
    journal_dir: pathlib.Path | None = None,
    environment: dict[str, str] | None = None,
) -> dict[str, pathlib.Path]:
    root = pathlib.Path(workspace).resolve(strict=True)
    workspace_node = _lstat_directory(root, "workspace-unsafe")
    if journal_dir is None:
        journal_root = _default_journal_root(
            dict(os.environ) if environment is None else environment
        )
    else:
        requested = pathlib.Path(journal_dir)
        if not requested.is_absolute():
            raise JournalError("journal-root-invalid", str(requested))
        journal_root = _walk_existing_directories(
            requested, "journal-root-unsafe"
        )
        _require_owned_safe_directory(
            journal_root, "journal-root-unsafe", private=False
        )
    journal_root = journal_root.resolve(strict=True)
    journal_node = _lstat_directory(journal_root, "journal-root-unsafe")
    if (
        (workspace_node.st_dev, workspace_node.st_ino)
        == (journal_node.st_dev, journal_node.st_ino)
        or root == journal_root
        or root in journal_root.parents
    ):
        raise JournalError("journal-root-unsafe", str(journal_root))
    workspace_id = workspace_identifier(str(root))
    directory = _ensure_private_child(journal_root, workspace_id)
    digest_hex = plan_digest.removeprefix("sha256:")
    if len(digest_hex) != 64 or any(
        character not in "0123456789abcdef" for character in digest_hex
    ):
        raise JournalError("plan-digest-invalid", plan_digest)
    return {
        "root": journal_root,
        "directory": directory,
        "journal": directory / f"{digest_hex}.json",
        "initial_temp": directory / f"{digest_hex}.initial.tmp",
        "replace_temp": directory / f"{digest_hex}.replace.tmp",
        "lock": journal_root / "apply.lock",
        "lock_temp": journal_root / "apply.lock.replace.tmp",
    }


def _fsync_directory(path: pathlib.Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_all(descriptor: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short journal write")
        view = view[written:]


def _existing_file(path: pathlib.Path) -> os.stat_result | None:
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise JournalError("journal-unsafe", str(path)) from error


def install_prepared_journal(
    journal: dict[str, Any], location: dict[str, pathlib.Path]
) -> pathlib.Path:
    normalized = validate_journal(journal)
    directory = location["directory"]
    final = location["journal"]
    temporary = location["initial_temp"]
    _require_owned_safe_directory(directory, "journal-unsafe", private=True)
    expected_name = normalized["plan_digest"].removeprefix("sha256:") + ".json"
    if final.name != expected_name:
        raise JournalError("journal-identity-mismatch", str(final))
    existing = _existing_file(final)
    if existing is not None:
        if (
            stat.S_ISREG(existing.st_mode)
            and existing.st_uid == os.getuid()
            and stat.S_IMODE(existing.st_mode) == 0o600
            and existing.st_nlink == 1
        ):
            raise JournalError("journal-exists", str(final))
        raise JournalError("journal-unsafe", str(final))
    if _existing_file(temporary) is not None:
        raise JournalError("journal-unsafe", str(temporary))

    payload = canonical_bytes(normalized)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    linked = False
    try:
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.link(temporary, final, follow_symlinks=False)
        linked = True
        _fsync_directory(directory)
        os.unlink(temporary)
        _fsync_directory(directory)
    except FileExistsError as error:
        os.unlink(temporary)
        _fsync_directory(directory)
        raise JournalError("journal-exists", str(final)) from error
    except OSError:
        if not linked and _existing_file(temporary) is not None:
            os.unlink(temporary)
            _fsync_directory(directory)
        raise
    return final


def _absent_image() -> dict[str, Any]:
    return {
        "node_type": "absent",
        "mode": None,
        "content_base64": None,
        "link_target": None,
        "digest": None,
    }


def _node_image(node: dict[str, Any]) -> dict[str, Any]:
    if node["node_type"] == "absent":
        return _absent_image()
    if node["node_type"] == "directory":
        content_base64 = None
    elif node["node_type"] == "file":
        content_base64 = base64.b64encode(node["content"]).decode("ascii")
    elif node["node_type"] == "symlink":
        content_base64 = None
    else:
        raise JournalError("node-type-invalid", node["node_type"])
    return {
        "node_type": node["node_type"],
        "mode": node["mode"],
        "content_base64": content_base64,
        "link_target": node["link_target"],
        "digest": node["digest"],
    }


def _artifact_image(
    artifact: dict[str, Any], content: bytes | None
) -> dict[str, Any]:
    if artifact["node_type"] == "file":
        digest = node_digest(
            "file", artifact["mode"], content=content
        )
    else:
        digest = node_digest(
            "symlink", "120000", link_target=artifact["link_target"]
        )
    return {
        "node_type": artifact["node_type"],
        "mode": artifact["mode"],
        "content_base64": artifact["content_base64"],
        "link_target": artifact["link_target"],
        "digest": digest,
    }


def _matches_before(
    observed: dict[str, Any], operation: dict[str, Any]
) -> bool:
    return (
        observed["node_type"] == (operation["before_type"] or "absent")
        and observed["mode"] == operation["before_mode"]
        and observed["digest"] == operation["before_digest"]
    )


def _temp_path(path: str, journal_id: str, effect_id: str) -> str:
    pure = pathlib.PurePosixPath(path)
    name = f".workbench-kit.{journal_id}.{effect_id}.tmp"
    parent = pure.parent.as_posix()
    return name if parent == "." else f"{parent}/{name}"


def build_prepared_journal(
    plan: dict[str, Any], plan_source_digest: str, created_at: str
) -> dict[str, Any]:
    normalized_plan = validate_plan(plan)
    root = pathlib.Path(normalized_plan["workspace"]["root"]).resolve(strict=True)
    if str(root) != normalized_plan["workspace"]["root"]:
        raise JournalError("workspace-root-stale", str(root))

    for preserved in normalized_plan["preserved"]:
        observed = _inspect_node(root, preserved["path"])
        if any(
            observed[field] != preserved[field]
            for field in ("node_type", "mode", "digest", "link_target")
        ):
            raise JournalError("preserved-node-stale", preserved["path"])

    planned_effects: list[dict[str, Any]] = []
    for parent in normalized_plan["parent_directories"]:
        observed = _inspect_node(root, parent["path"])
        if parent["before_type"] is None:
            if observed["node_type"] != "absent":
                raise JournalError("operation-parent-stale", parent["path"])
            planned_effects.append({
                "kind": "ensure-directory",
                "path": parent["path"],
                "before": _absent_image(),
                "after": {
                    "node_type": "directory",
                    "mode": parent["after_mode"],
                    "content_base64": None,
                    "link_target": None,
                    "digest": node_digest("directory", parent["after_mode"]),
                },
                "artifact_source_digest": None,
                "equivalence_receipt_ref": None,
            })
        elif (
            observed["node_type"] != "directory"
            or observed["mode"] != parent["before_mode"]
        ):
            raise JournalError("operation-parent-stale", parent["path"])

    artifacts = {}
    for raw_artifact in normalized_plan["artifacts"]:
        artifact, content = decode_artifact(raw_artifact)
        artifacts[artifact["path"]] = (artifact, content)
    for operation in normalized_plan["operations"]:
        observed = _inspect_node(root, operation["path"])
        if not _matches_before(observed, operation):
            raise JournalError("operation-preimage-stale", operation["path"])
        if operation["op"] == "remove":
            after = _absent_image()
        else:
            artifact, content = artifacts[operation["path"]]
            after = _artifact_image(artifact, content)
        planned_effects.append({
            "kind": operation["op"],
            "path": operation["path"],
            "before": _node_image(observed),
            "after": after,
            "artifact_source_digest": operation["artifact_source_digest"],
            "equivalence_receipt_ref": operation["equivalence_receipt_ref"],
        })

    journal_id = "upgrade-" + normalized_plan["plan_digest"].removeprefix(
        "sha256:"
    )
    effects = []
    for index, planned in enumerate(planned_effects, 1):
        effect_id = f"effect-{index:04d}"
        effects.append({
            "effect_id": effect_id,
            "kind": planned["kind"],
            "path": planned["path"],
            "temp_path": (
                _temp_path(planned["path"], journal_id, effect_id)
                if planned["kind"] in ("create", "update")
                else None
            ),
            "before": planned["before"],
            "after": planned["after"],
            "artifact_source_digest": planned["artifact_source_digest"],
            "equivalence_receipt_ref": planned["equivalence_receipt_ref"],
        })
    validation = {
        "status": "pending",
        "classification_after": None,
        "basis_kind": None,
        "basis_digest": None,
        "blockers": [],
        "digest": None,
    }
    validation["digest"] = canonical_digest(validation, null_field="digest")
    journal = {
        "contract_version": "workbench-kit-upgrade-journal/v1",
        "journal_id": journal_id,
        "workspace_id": workspace_identifier(str(root)),
        "plan_digest": normalized_plan["plan_digest"],
        "plan_source_digest": plan_source_digest,
        "workspace": normalized_plan["workspace"],
        "stage": "prepared",
        "direction": "forward",
        "cursor": 0,
        "effects": effects,
        "applied": [],
        "validation": validation,
        "completion_result": None,
        "created_at": created_at,
        "updated_at": created_at,
    }
    return validate_journal(journal, normalized_plan)
