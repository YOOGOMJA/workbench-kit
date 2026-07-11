"""Durable journal construction for governed workbench upgrades."""

from __future__ import annotations

import base64
import copy
import fcntl
import os
import pathlib
import stat
from contextlib import contextmanager
from collections.abc import Callable, Iterator
from typing import Any

from workbench_kit_classifier import _inspect_node
from workbench_kit_contracts import (
    canonical_bytes,
    canonical_digest,
    decode_artifact,
    node_digest,
    strict_load,
    validate_journal,
    validate_plan,
    validate_result,
    validate_validation,
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


def _read_regular_file(path: pathlib.Path) -> bytes:
    node = _existing_file(path)
    if node is None:
        raise JournalError("journal-missing", str(path))
    if (
        not stat.S_ISREG(node.st_mode)
        or node.st_uid != os.getuid()
        or stat.S_IMODE(node.st_mode) != 0o600
        or node.st_nlink != 1
    ):
        raise JournalError("journal-unsafe", str(path))
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (node.st_dev, node.st_ino):
            raise JournalError("journal-unsafe", str(path))
        chunks = []
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def load_journal(
    location: dict[str, pathlib.Path], plan: dict[str, Any] | None = None
) -> dict[str, Any]:
    raw = _read_regular_file(location["journal"])
    try:
        journal = validate_journal(
            strict_load(raw, str(location["journal"])), plan
        )
    except Exception as error:
        if isinstance(error, JournalError):
            raise
        raise JournalError("journal-corrupt", str(location["journal"])) from error
    if raw != canonical_bytes(journal):
        raise JournalError("journal-corrupt", str(location["journal"]))
    if location["journal"].name != (
        journal["plan_digest"].removeprefix("sha256:") + ".json"
    ):
        raise JournalError("journal-identity-mismatch", str(location["journal"]))
    return journal


def _replace_journal(
    journal: dict[str, Any],
    location: dict[str, pathlib.Path],
    plan: dict[str, Any],
) -> dict[str, Any]:
    normalized = validate_journal(journal, plan)
    current = load_journal(location, plan)
    if current["journal_id"] != normalized["journal_id"]:
        raise JournalError("journal-identity-mismatch", current["journal_id"])
    temporary = location["replace_temp"]
    if _existing_file(temporary) is not None:
        raise JournalError("journal-unsafe", str(temporary))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        _write_all(descriptor, canonical_bytes(normalized))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary, location["journal"])
        _fsync_directory(location["directory"])
    except OSError:
        if _existing_file(temporary) is not None:
            os.unlink(temporary)
            _fsync_directory(location["directory"])
        raise
    return normalized


@contextmanager
def _workspace_lock(root: pathlib.Path) -> Iterator[None]:
    node = _lstat_directory(root, "workspace-unsafe")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(root, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            (opened.st_dev, opened.st_ino) != (node.st_dev, node.st_ino)
            or opened.st_uid != os.getuid()
        ):
            raise JournalError("workspace-unsafe", str(root))
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError) as error:
            raise JournalError("apply-in-progress", str(root)) from error
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def _image_matches(root: pathlib.Path, path: str, image: dict[str, Any]) -> bool:
    return _node_image(_inspect_node(root, path)) == image


def _observed_prefix(root: pathlib.Path, effects: list[dict[str, Any]]) -> int:
    prefix = 0
    before_seen = False
    for effect in effects:
        is_before = _image_matches(root, effect["path"], effect["before"])
        is_after = _image_matches(root, effect["path"], effect["after"])
        if is_after and not is_before:
            if before_seen:
                raise JournalError("transaction-state-mismatch", effect["path"])
            prefix += 1
        elif is_before and not is_after:
            before_seen = True
        else:
            raise JournalError("transaction-state-mismatch", effect["path"])
    return prefix


def _verify_preserved(root: pathlib.Path, plan: dict[str, Any]) -> None:
    for preserved in plan["preserved"]:
        observed = _inspect_node(root, preserved["path"])
        if any(
            observed[field] != preserved[field]
            for field in ("node_type", "mode", "digest", "link_target")
        ):
            raise JournalError("preserved-node-stale", preserved["path"])


def _mode_permissions(mode: str) -> int:
    if mode == "100644":
        return 0o644
    if mode == "100755":
        return 0o755
    raise JournalError("node-mode-invalid", mode)


def _effect_paths(
    root: pathlib.Path,
    effect: dict[str, Any],
    journal_id: str,
    target_image: dict[str, Any],
) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    target = root.joinpath(*pathlib.PurePosixPath(effect["path"]).parts)
    parent = target.parent
    temp_path = effect["temp_path"]
    if temp_path is None and target_image["node_type"] in ("file", "symlink"):
        temp_path = _temp_path(effect["path"], journal_id, effect["effect_id"])
    temporary = (
        root.joinpath(*pathlib.PurePosixPath(temp_path).parts)
        if temp_path is not None
        else target
    )
    _lstat_directory(parent, "node-parent-unsafe")
    return target, parent, temporary


def _install_image_temp(
    temporary: pathlib.Path,
    image: dict[str, Any],
    effect: dict[str, Any],
    direction: str,
    fault_hook: Callable[[str, dict[str, Any], str], None],
) -> None:
    if _existing_file(temporary) is not None:
        raise JournalError("transaction-state-mismatch", str(temporary))
    if image["node_type"] == "file":
        content = base64.b64decode(image["content_base64"], validate=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600)
        try:
            fault_hook("after-temp-create", effect, direction)
            _write_all(descriptor, content)
            fault_hook("after-temp-write", effect, direction)
            os.fchmod(descriptor, _mode_permissions(image["mode"]))
            os.fsync(descriptor)
            fault_hook("after-temp-fsync", effect, direction)
        finally:
            os.close(descriptor)
    elif image["node_type"] == "symlink":
        os.symlink(image["link_target"], temporary)
        fault_hook("after-temp-create", effect, direction)
        fault_hook("after-temp-fsync", effect, direction)
    else:
        raise JournalError("node-type-invalid", image["node_type"])


def _transition_effect(
    root: pathlib.Path,
    effect: dict[str, Any],
    source: dict[str, Any],
    target_image: dict[str, Any],
    journal_id: str,
    direction: str,
    fault_hook: Callable[[str, dict[str, Any], str], None],
) -> None:
    if not _image_matches(root, effect["path"], source):
        raise JournalError("transaction-state-mismatch", effect["path"])
    target, parent, temporary = _effect_paths(
        root, effect, journal_id, target_image
    )
    if target_image["node_type"] == "absent":
        if source["node_type"] == "directory":
            os.rmdir(target)
        else:
            os.unlink(target)
        fault_hook("after-target-install", effect, direction)
        _fsync_directory(parent)
        fault_hook("after-parent-fsync", effect, direction)
        return
    if target_image["node_type"] == "directory":
        os.mkdir(target, 0o755)
        fault_hook("after-target-install", effect, direction)
        _fsync_directory(target)
        _fsync_directory(parent)
        fault_hook("after-parent-fsync", effect, direction)
        return

    _install_image_temp(
        temporary, target_image, effect, direction, fault_hook
    )
    try:
        if source["node_type"] == "absent":
            os.link(temporary, target, follow_symlinks=False)
            fault_hook("after-target-install", effect, direction)
            os.unlink(temporary)
            fault_hook("after-temp-unlink", effect, direction)
        else:
            os.replace(temporary, target)
            fault_hook("after-target-install", effect, direction)
        _fsync_directory(parent)
        fault_hook("after-parent-fsync", effect, direction)
    except OSError:
        if _existing_file(temporary) is not None:
            os.unlink(temporary)
            _fsync_directory(parent)
        raise
    if not _image_matches(root, effect["path"], target_image):
        raise JournalError("transaction-state-mismatch", effect["path"])


def _reconcile_temp_residue(
    root: pathlib.Path, effect: dict[str, Any]
) -> None:
    if effect["temp_path"] is None:
        return
    target = root.joinpath(*pathlib.PurePosixPath(effect["path"]).parts)
    temporary = root.joinpath(
        *pathlib.PurePosixPath(effect["temp_path"]).parts
    )
    residue = _existing_file(temporary)
    if residue is None:
        return
    parent = target.parent
    _lstat_directory(parent, "node-parent-unsafe")
    expected_type = effect["after"]["node_type"]
    safe_type = (
        expected_type == "file" and stat.S_ISREG(residue.st_mode)
    ) or (
        expected_type == "symlink" and stat.S_ISLNK(residue.st_mode)
    )
    if effect["kind"] == "create" and safe_type:
        try:
            target_node = os.lstat(target)
        except FileNotFoundError:
            target_node = None
        if target_node is not None and (
            residue.st_uid == os.getuid()
            and residue.st_nlink == 2
            and target_node.st_nlink == 2
            and (residue.st_dev, residue.st_ino)
            == (target_node.st_dev, target_node.st_ino)
        ):
            if expected_type == "file":
                permissions = stat.S_IMODE(target_node.st_mode)
                expected_permissions = _mode_permissions(effect["after"]["mode"])
                target_matches = (
                    permissions == expected_permissions
                    and node_digest(
                        "file",
                        effect["after"]["mode"],
                        content=target.read_bytes(),
                    )
                    == effect["after"]["digest"]
                )
            else:
                target_matches = (
                    os.readlink(target) == effect["after"]["link_target"]
                )
            if target_matches:
                os.unlink(temporary)
                _fsync_directory(parent)
                return
    target_before = _image_matches(root, effect["path"], effect["before"])
    target_after = _image_matches(root, effect["path"], effect["after"])
    if target_before and (
        safe_type and residue.st_uid == os.getuid() and residue.st_nlink == 1
    ):
        os.unlink(temporary)
        _fsync_directory(parent)
        return
    raise JournalError("transaction-state-mismatch", effect["temp_path"])


def _reconcile_temp_residues(
    root: pathlib.Path, effects: list[dict[str, Any]]
) -> None:
    for effect in effects:
        _reconcile_temp_residue(root, effect)


def _set_cursor(
    journal: dict[str, Any], cursor: int, updated_at: str
) -> None:
    journal["cursor"] = cursor
    journal["applied"] = [
        effect["effect_id"] for effect in journal["effects"][:cursor]
    ]
    journal["updated_at"] = updated_at


def _result(
    plan: dict[str, Any],
    journal: dict[str, Any],
    *,
    stage: str,
    resumed: bool,
    applied: list[dict[str, Any]],
) -> dict[str, Any]:
    result = {
        "contract_version": "workbench-kit-upgrade-result/v1",
        "result_digest": None,
        "plan_digest": plan["plan_digest"],
        "classification_before": plan["classification_before"],
        "target_classification": plan["target_classification"],
        "embedded_engine": plan["embedded_engine"],
        "provenance_final": plan["provenance_after"],
        "workspace": plan["workspace"],
        "transaction": {
            "journal_id": journal["journal_id"],
            "workspace_id": journal["workspace_id"],
            "stage": stage,
            "direction": "none",
            "cursor": journal["cursor"],
            "resumed": resumed,
        },
        "changed": bool(applied),
        "applied": applied,
        "preserved": plan["preserved"],
        "active_v1_tasks": plan["active_v1_tasks"],
        "validation": journal["validation"],
        "blockers": journal["validation"]["blockers"],
    }
    result["result_digest"] = canonical_digest(result, null_field="result_digest")
    return validate_result(result)


def _terminal_replay(
    plan: dict[str, Any], journal: dict[str, Any]
) -> dict[str, Any]:
    result = copy.deepcopy(journal["completion_result"])
    result["result_digest"] = None
    result["transaction"]["resumed"] = True
    result["changed"] = False
    result["applied"] = []
    result["result_digest"] = canonical_digest(result, null_field="result_digest")
    return validate_result(result)


def _complete_rollback(
    plan: dict[str, Any],
    journal: dict[str, Any],
    location: dict[str, pathlib.Path],
    root: pathlib.Path,
    updated_at: str,
    resumed: bool,
    fault_hook: Callable[[str, dict[str, Any], str], None],
) -> dict[str, Any]:
    while journal["cursor"]:
        effect = journal["effects"][journal["cursor"] - 1]
        if _image_matches(root, effect["path"], effect["before"]):
            _set_cursor(journal, journal["cursor"] - 1, updated_at)
            journal = _replace_journal(journal, location, plan)
            continue
        if not _image_matches(root, effect["path"], effect["after"]):
            raise JournalError("transaction-state-mismatch", effect["path"])
        fault_hook("before-effect", effect, "reverse")
        _transition_effect(
            root,
            effect,
            effect["after"],
            effect["before"],
            journal["journal_id"],
            "reverse",
            fault_hook,
        )
        fault_hook("after-effect", effect, "reverse")
        _set_cursor(journal, journal["cursor"] - 1, updated_at)
        journal = _replace_journal(journal, location, plan)
        fault_hook("after-cursor", effect, "reverse")
    journal["stage"] = "rolled-back"
    journal["direction"] = "none"
    journal["updated_at"] = updated_at
    result = _result(
        plan, journal, stage="rolled-back", resumed=resumed, applied=[]
    )
    journal["completion_result"] = result
    journal = _replace_journal(journal, location, plan)
    return journal["completion_result"]


def execute_upgrade(
    plan: dict[str, Any],
    location: dict[str, pathlib.Path],
    *,
    plan_source_digest: str,
    updated_at: str,
    validate_after: Callable[[dict[str, Any]], dict[str, Any]],
    fault_hook: Callable[[str, dict[str, Any], str], None] | None = None,
) -> dict[str, Any]:
    normalized_plan = validate_plan(plan)
    root = pathlib.Path(normalized_plan["workspace"]["root"]).resolve(strict=True)
    hook = fault_hook or (lambda _point, _effect, _direction: None)
    with _workspace_lock(root):
        journal = load_journal(location, normalized_plan)
        if journal["plan_source_digest"] != plan_source_digest:
            raise JournalError("plan-source-stale", "--plan-file")
        _verify_preserved(root, normalized_plan)
        _reconcile_temp_residues(root, journal["effects"])
        entry_stage = journal["stage"]
        resumed = entry_stage != "prepared"
        prefix = _observed_prefix(root, journal["effects"])
        if entry_stage == "completed":
            if prefix != len(journal["effects"]):
                raise JournalError("transaction-state-mismatch", str(root))
            return _terminal_replay(normalized_plan, journal)
        if entry_stage == "rolled-back":
            if prefix != 0:
                raise JournalError("transaction-state-mismatch", str(root))
            return _terminal_replay(normalized_plan, journal)
        if entry_stage == "rolling-back":
            if prefix not in (journal["cursor"], journal["cursor"] - 1):
                raise JournalError("transaction-state-mismatch", str(root))
            return _complete_rollback(
                normalized_plan,
                journal,
                location,
                root,
                updated_at,
                True,
                hook,
            )
        if prefix not in (journal["cursor"], journal["cursor"] + 1):
            raise JournalError("transaction-state-mismatch", str(root))
        if entry_stage == "prepared":
            if prefix != 0:
                raise JournalError("transaction-state-mismatch", str(root))
            journal["stage"] = "applying"
            journal["updated_at"] = updated_at
            journal = _replace_journal(journal, location, normalized_plan)
        elif prefix == journal["cursor"] + 1:
            _set_cursor(journal, prefix, updated_at)
            journal = _replace_journal(journal, location, normalized_plan)

        active_effect = None
        validating_candidate = False
        try:
            while journal["cursor"] < len(journal["effects"]):
                active_effect = journal["effects"][journal["cursor"]]
                if _image_matches(
                    root, active_effect["path"], active_effect["after"]
                ):
                    _set_cursor(journal, journal["cursor"] + 1, updated_at)
                    journal = _replace_journal(
                        journal, location, normalized_plan
                    )
                    continue
                if not _image_matches(
                    root, active_effect["path"], active_effect["before"]
                ):
                    raise JournalError(
                        "transaction-state-mismatch", active_effect["path"]
                    )
                hook("before-effect", active_effect, "forward")
                _transition_effect(
                    root,
                    active_effect,
                    active_effect["before"],
                    active_effect["after"],
                    journal["journal_id"],
                    "forward",
                    hook,
                )
                hook("after-effect", active_effect, "forward")
                _set_cursor(journal, journal["cursor"] + 1, updated_at)
                journal = _replace_journal(journal, location, normalized_plan)
                hook("after-cursor", active_effect, "forward")
            journal["stage"] = "validating"
            journal["updated_at"] = updated_at
            journal = _replace_journal(journal, location, normalized_plan)
            hook("before-validation", journal["effects"][-1], "forward")
            validating_candidate = True
            journal["validation"] = validate_validation(
                validate_after(normalized_plan)
            )
            if journal["validation"]["status"] != "passed":
                journal["stage"] = "rolling-back"
                journal["direction"] = "reverse"
                journal["updated_at"] = updated_at
                journal = _replace_journal(
                    journal, location, normalized_plan
                )
                return _complete_rollback(
                    normalized_plan,
                    journal,
                    location,
                    root,
                    updated_at,
                    resumed,
                    hook,
                )
            hook("after-validation", journal["effects"][-1], "forward")
        except JournalError:
            raise
        except Exception:
            prefix = _observed_prefix(root, journal["effects"])
            blocker_ref = (
                str(root)
                if validating_candidate
                else active_effect["path"] if active_effect else str(root)
            )
            blocker_code = (
                "candidate-validation-failed"
                if validating_candidate
                else "apply-effect-failed"
            )
            validation = {
                "status": "failed",
                "classification_after": None,
                "basis_kind": None,
                "basis_digest": None,
                "blockers": [{
                    "code": blocker_code,
                    "ref": blocker_ref,
                }],
                "digest": None,
            }
            validation["digest"] = canonical_digest(
                validation, null_field="digest"
            )
            journal["stage"] = "rolling-back"
            journal["direction"] = "reverse"
            journal["validation"] = validation
            _set_cursor(journal, prefix, updated_at)
            journal = _replace_journal(journal, location, normalized_plan)
            return _complete_rollback(
                normalized_plan,
                journal,
                location,
                root,
                updated_at,
                resumed,
                hook,
            )

        journal["stage"] = "completed"
        journal["direction"] = "none"
        journal["updated_at"] = updated_at
        applied = [
            {
                "op": effect["kind"],
                "path": effect["path"],
                "before_digest": effect["before"]["digest"],
                "after_digest": effect["after"]["digest"],
            }
            for effect in journal["effects"]
            if effect["kind"] != "ensure-directory"
        ]
        result = _result(
            normalized_plan,
            journal,
            stage="completed",
            resumed=resumed,
            applied=applied,
        )
        journal["completion_result"] = result
        journal = _replace_journal(journal, location, normalized_plan)
        return journal["completion_result"]


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
