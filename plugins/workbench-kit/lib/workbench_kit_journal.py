"""Durable journal construction for governed workbench upgrades."""

from __future__ import annotations

import base64
import copy
import ctypes
import errno
import fcntl
import os
import pathlib
import pwd
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


MAX_JOURNAL_BYTES = 64 * 1024 * 1024


def _require_journal_size(size: int, ref: str) -> None:
    if size > MAX_JOURNAL_BYTES:
        raise JournalError("journal-too-large", ref)


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


def _ensure_private_child(
    parent: pathlib.Path,
    name: str,
    *,
    code: str = "journal-root-unsafe",
) -> pathlib.Path:
    target = parent / name
    try:
        os.mkdir(target, 0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise JournalError(code, str(target)) from error
    _require_owned_safe_directory(target, code, private=True)
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


def _account_home() -> pathlib.Path:
    try:
        raw_home = pwd.getpwuid(os.getuid()).pw_dir
    except (KeyError, OSError) as error:
        raise JournalError("coordination-root-unsafe", "account-home") from error
    requested = pathlib.Path(raw_home)
    if not requested.is_absolute():
        raise JournalError("coordination-root-unsafe", raw_home)
    home = _walk_existing_directories(
        requested, "coordination-root-unsafe"
    )
    _require_owned_safe_directory(
        home, "coordination-root-unsafe", private=False
    )
    return home


def _fixed_coordination_root() -> pathlib.Path:
    home = _account_home()
    local = home / ".local"
    state = local / "state"
    for directory in (local, state):
        try:
            os.mkdir(directory, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            raise JournalError(
                "coordination-root-unsafe", str(directory)
            ) from error
        _require_owned_safe_directory(
            directory, "coordination-root-unsafe", private=False
        )
    kit = _ensure_private_child(
        state, "workbench-kit", code="coordination-root-unsafe"
    )
    return _ensure_private_child(
        kit, "upgrade-coordination", code="coordination-root-unsafe"
    )


def _read_safe_pointer_file(path: pathlib.Path) -> bytes:
    node = _existing_file(path)
    if (
        node is None
        or not stat.S_ISREG(node.st_mode)
        or node.st_uid != os.getuid()
        or node.st_nlink != 1
        or stat.S_IMODE(node.st_mode) & 0o022
    ):
        raise JournalError("git-directory-unsafe", str(path))
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or (opened.st_dev, opened.st_ino)
            != (node.st_dev, node.st_ino)
            or opened.st_uid != node.st_uid
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) & 0o022
        ):
            raise JournalError("git-directory-unsafe", str(path))
        raw = os.read(descriptor, 4097)
    finally:
        os.close(descriptor)
    if len(raw) > 4096 or not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise JournalError("git-directory-unsafe", str(path))
    return raw[:-1]


def _decode_pointer(raw: bytes, path: pathlib.Path) -> str:
    if not raw or b"\x00" in raw:
        raise JournalError("git-directory-unsafe", str(path))
    try:
        return os.fsdecode(raw)
    except UnicodeError as error:
        raise JournalError("git-directory-unsafe", str(path)) from error


def _resolve_directory_pointer(
    base: pathlib.Path, value: str
) -> pathlib.Path:
    requested = pathlib.Path(value)
    if not requested.is_absolute():
        requested = base / requested
    canonical = pathlib.Path(os.path.abspath(requested))
    _walk_existing_directories(canonical, "git-directory-unsafe")
    _require_owned_safe_directory(
        canonical, "git-directory-unsafe", private=False
    )
    return canonical


def _read_git_directory_file(root: pathlib.Path, marker: pathlib.Path) -> pathlib.Path:
    raw = _read_safe_pointer_file(marker)
    prefix = b"gitdir: "
    if not raw.startswith(prefix):
        raise JournalError("git-directory-unsafe", str(marker))
    canonical = _resolve_directory_pointer(
        root,
        _decode_pointer(raw[len(prefix) :], marker),
    )
    commondir_file = canonical / "commondir"
    reverse_file = canonical / "gitdir"
    has_commondir = _existing_file(commondir_file) is not None
    has_reverse = _existing_file(reverse_file) is not None
    if has_commondir != has_reverse:
        raise JournalError("git-directory-unsafe", str(canonical))
    if has_commondir:
        common = _resolve_directory_pointer(
            canonical,
            _decode_pointer(
                _read_safe_pointer_file(commondir_file), commondir_file
            ),
        )
        reverse_value = _decode_pointer(
            _read_safe_pointer_file(reverse_file), reverse_file
        )
        reverse = pathlib.Path(reverse_value)
        if not reverse.is_absolute():
            reverse = canonical / reverse
        reverse = pathlib.Path(os.path.abspath(reverse))
        if reverse != marker or canonical.parent.name != "worktrees":
            raise JournalError("git-directory-unsafe", str(canonical))
        expected_common = canonical.parent.parent
        expected_node = _lstat_directory(
            expected_common, "git-directory-unsafe"
        )
        common_node = _lstat_directory(common, "git-directory-unsafe")
        if (expected_node.st_dev, expected_node.st_ino) != (
            common_node.st_dev,
            common_node.st_ino,
        ):
            raise JournalError("git-directory-unsafe", str(commondir_file))
    return canonical


def _workspace_git_directory(root: pathlib.Path) -> pathlib.Path:
    marker = root / ".git"
    node = _existing_file(marker)
    if node is None:
        raise JournalError("git-directory-missing", str(marker))
    if stat.S_ISDIR(node.st_mode) and not stat.S_ISLNK(node.st_mode):
        _walk_existing_directories(marker, "git-directory-unsafe")
        _require_owned_safe_directory(
            marker, "git-directory-unsafe", private=False
        )
        return marker
    return _read_git_directory_file(root, marker)


def _journal_location(
    root: pathlib.Path,
    workspace_device: int,
    workspace_inode: int,
    workspace_id: str,
    plan_digest: str,
    journal_root: pathlib.Path,
    coordination: pathlib.Path,
) -> dict[str, Any]:
    directory = _ensure_private_child(journal_root, workspace_id)
    workspace_coordination = _ensure_private_child(
        coordination, workspace_id, code="coordination-root-unsafe"
    )
    digest_hex = plan_digest.removeprefix("sha256:")
    return {
        "root": journal_root,
        "directory": directory,
        "journal": directory / f"{digest_hex}.json",
        "initial_temp": directory / f"{digest_hex}.initial.tmp",
        "replace_temp": directory / f"{digest_hex}.replace.tmp",
        "owner_directory": workspace_coordination,
        "owner": workspace_coordination / "owner.json",
        "owner_temp": workspace_coordination / "owner.initial.tmp",
        "coordination": workspace_coordination,
        "lock": workspace_coordination / "apply.lock",
        "workspace_root": root,
        "workspace_device": workspace_device,
        "workspace_inode": workspace_inode,
    }


def resolve_journal_location(
    workspace: pathlib.Path,
    plan_digest: str,
    *,
    journal_dir: pathlib.Path | None = None,
    environment: dict[str, str] | None = None,
) -> dict[str, pathlib.Path]:
    root = pathlib.Path(workspace).resolve(strict=True)
    workspace_node = _lstat_directory(root, "workspace-unsafe")
    _workspace_git_directory(root)
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
    digest_hex = plan_digest.removeprefix("sha256:")
    if len(digest_hex) != 64 or any(
        character not in "0123456789abcdef" for character in digest_hex
    ):
        raise JournalError("plan-digest-invalid", plan_digest)
    workspace_id = workspace_identifier(str(root))
    coordination = _fixed_coordination_root()
    location = _journal_location(
        root,
        workspace_node.st_dev,
        workspace_node.st_ino,
        workspace_id,
        plan_digest,
        journal_root,
        coordination,
    )
    with _workspace_lock(root, location):
        owner = _read_owner(location)
        if owner is None or owner["plan_digest"] != plan_digest:
            return location
        if not _owner_workspace_matches(owner, location):
            raise JournalError(
                "transaction-in-progress", owner["journal_path"]
            )
        owner_location = _location_from_owner(location, owner)
        owner_journal = load_journal(
            owner_location, defer_replace_partial=True
        )
        _require_owner_journal_binding(owner, owner_journal, owner_location)
        return owner_location


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


def _install_prepared_journal_unlocked(
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
    payload = canonical_bytes(normalized)
    _require_journal_size(len(payload), str(final))
    existing = _existing_file(final)
    temp_existing = _existing_file(temporary)
    if existing is not None and temp_existing is not None:
        if (
            stat.S_ISREG(existing.st_mode)
            and stat.S_ISREG(temp_existing.st_mode)
            and existing.st_uid == os.getuid()
            and temp_existing.st_uid == os.getuid()
            and stat.S_IMODE(existing.st_mode) == 0o600
            and stat.S_IMODE(temp_existing.st_mode) == 0o600
            and existing.st_nlink == 2
            and temp_existing.st_nlink == 2
            and (existing.st_dev, existing.st_ino)
            == (temp_existing.st_dev, temp_existing.st_ino)
            and _read_regular_file(
                temporary, allowed_links=(2,)
            ) == payload
        ):
            _fsync_directory(directory)
            os.unlink(temporary)
            _fsync_directory(directory)
            return final
        raise JournalError("journal-unsafe", str(temporary))
    if existing is not None:
        if (
            stat.S_ISREG(existing.st_mode)
            and existing.st_uid == os.getuid()
            and stat.S_IMODE(existing.st_mode) == 0o600
            and existing.st_nlink == 1
        ):
            raise JournalError("journal-exists", str(final))
        raise JournalError("journal-unsafe", str(final))
    if temp_existing is not None:
        if (
            not stat.S_ISREG(temp_existing.st_mode)
            or temp_existing.st_uid != os.getuid()
            or stat.S_IMODE(temp_existing.st_mode) != 0o600
            or temp_existing.st_nlink != 1
        ):
            raise JournalError("journal-unsafe", str(temporary))
        raw_temp = _read_regular_file(temporary)
        if raw_temp == payload:
            try:
                os.link(temporary, final, follow_symlinks=False)
                _fsync_directory(directory)
                os.unlink(temporary)
                _fsync_directory(directory)
                return final
            except FileExistsError as error:
                raise JournalError("journal-exists", str(final)) from error
        if not payload.startswith(raw_temp):
            raise JournalError("journal-unsafe", str(temporary))
        os.unlink(temporary)
        _fsync_directory(directory)

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


def _read_regular_file(
    path: pathlib.Path,
    *,
    allowed_links: tuple[int, ...] = (1,),
    max_bytes: int | None = None,
) -> bytes:
    limit = MAX_JOURNAL_BYTES if max_bytes is None else max_bytes
    node = _existing_file(path)
    if node is None:
        raise JournalError("journal-missing", str(path))
    if (
        not stat.S_ISREG(node.st_mode)
        or node.st_uid != os.getuid()
        or stat.S_IMODE(node.st_mode) != 0o600
        or node.st_nlink not in allowed_links
    ):
        raise JournalError("journal-unsafe", str(path))
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.getuid()
            or stat.S_IMODE(opened.st_mode) != 0o600
            or opened.st_nlink not in allowed_links
            or (opened.st_dev, opened.st_ino) != (node.st_dev, node.st_ino)
            or opened.st_size != node.st_size
            or opened.st_size > limit
        ):
            if opened.st_size > limit:
                raise JournalError("journal-too-large", str(path))
            raise JournalError("journal-unsafe", str(path))
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                raise JournalError("journal-too-large", str(path))
            chunks.append(chunk)
        verified = os.fstat(descriptor)
        snapshot_fields = (
            "st_dev",
            "st_ino",
            "st_uid",
            "st_mode",
            "st_nlink",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        if any(
            getattr(verified, field) != getattr(opened, field)
            for field in snapshot_fields
        ):
            raise JournalError("journal-unsafe", str(path))
        payload = b"".join(chunks)
        if len(payload) != opened.st_size:
            raise JournalError("journal-unsafe", str(path))
        return payload
    finally:
        os.close(descriptor)


def _decode_owner(raw: bytes, path: pathlib.Path) -> dict[str, Any]:
    try:
        record = strict_load(raw, str(path))
    except Exception as error:
        raise JournalError("owner-corrupt", str(path)) from error
    fields = (
        "contract_version",
        "owner_id",
        "workspace_id",
        "workspace_device",
        "workspace_inode",
        "plan_digest",
        "plan_source_digest",
        "journal_path",
        "created_at",
    )

    def hexadecimal(value: Any, prefix: str) -> bool:
        if not isinstance(value, str) or not value.startswith(prefix):
            return False
        suffix = value[len(prefix) :]
        return len(suffix) == 64 and all(
            character in "0123456789abcdef" for character in suffix
        )

    if (
        not isinstance(record, dict)
        or set(record) != set(fields)
        or record.get("contract_version")
        != "workbench-kit-upgrade-owner/v2"
        or not isinstance(record.get("workspace_device"), int)
        or isinstance(record.get("workspace_device"), bool)
        or record.get("workspace_device", -1) < 0
        or not isinstance(record.get("workspace_inode"), int)
        or isinstance(record.get("workspace_inode"), bool)
        or record.get("workspace_inode", -1) < 0
        or not hexadecimal(record.get("owner_id"), "upgrade-")
        or not hexadecimal(record.get("workspace_id"), "ws-")
        or not hexadecimal(record.get("plan_digest"), "sha256:")
        or not hexadecimal(
            record.get("plan_source_digest"), "sha256:"
        )
        or not isinstance(record.get("journal_path"), str)
        or not record.get("journal_path")
        or not isinstance(record.get("created_at"), str)
        or not record.get("created_at")
        or raw != canonical_bytes({field: record[field] for field in fields})
    ):
        raise JournalError("owner-corrupt", str(path))
    return {field: record[field] for field in fields}


def _read_owner(location: dict[str, pathlib.Path]) -> dict[str, Any] | None:
    path = location["owner"]
    if _existing_file(path) is None:
        return None
    return _decode_owner(_read_regular_file(path), path)


def _owner_record(
    journal: dict[str, Any], location: dict[str, pathlib.Path]
) -> dict[str, Any]:
    return {
        "contract_version": "workbench-kit-upgrade-owner/v2",
        "owner_id": journal["journal_id"],
        "workspace_id": journal["workspace_id"],
        "workspace_device": location["workspace_device"],
        "workspace_inode": location["workspace_inode"],
        "plan_digest": journal["plan_digest"],
        "plan_source_digest": journal["plan_source_digest"],
        "journal_path": str(location["journal"].resolve(strict=False)),
        "created_at": journal["created_at"],
    }


def _owner_workspace_matches(
    owner: dict[str, Any], location: dict[str, Any]
) -> bool:
    return (
        owner["workspace_id"]
        == workspace_identifier(str(location["workspace_root"]))
        and owner["workspace_device"] == location["workspace_device"]
        and owner["workspace_inode"] == location["workspace_inode"]
    )


def _location_from_owner(
    location: dict[str, Any], owner: dict[str, Any]
) -> dict[str, Any]:
    requested = pathlib.Path(owner["journal_path"])
    canonical = pathlib.Path(os.path.abspath(requested))
    if not requested.is_absolute() or requested != canonical:
        raise JournalError("owner-unsafe", owner["journal_path"])
    expected_name = owner["plan_digest"].removeprefix("sha256:") + ".json"
    if requested.name != expected_name:
        raise JournalError("owner-unsafe", owner["journal_path"])
    directory = _walk_existing_directories(
        requested.parent, "owner-unsafe"
    )
    _require_owned_safe_directory(directory, "owner-unsafe", private=True)
    if directory.name != owner["workspace_id"]:
        raise JournalError("owner-unsafe", owner["journal_path"])
    journal_root = _walk_existing_directories(
        directory.parent, "owner-unsafe"
    )
    _require_owned_safe_directory(
        journal_root, "owner-unsafe", private=False
    )
    root = location["workspace_root"]
    if root == journal_root or root in journal_root.parents:
        raise JournalError("owner-unsafe", owner["journal_path"])
    resolved = _journal_location(
        root,
        owner["workspace_device"],
        owner["workspace_inode"],
        owner["workspace_id"],
        owner["plan_digest"],
        journal_root,
        location["coordination"].parent,
    )
    resolved["workspace_device"] = owner["workspace_device"]
    resolved["workspace_inode"] = owner["workspace_inode"]
    if resolved["journal"] != requested:
        raise JournalError("owner-unsafe", owner["journal_path"])
    return resolved


def _require_owner_journal_binding(
    owner: dict[str, Any],
    journal: dict[str, Any],
    location: dict[str, Any],
) -> None:
    if (
        owner["owner_id"] != journal["journal_id"]
        or owner["workspace_id"] != journal["workspace_id"]
        or owner["plan_digest"] != journal["plan_digest"]
        or owner["plan_source_digest"] != journal["plan_source_digest"]
        or owner["created_at"] != journal["created_at"]
        or owner["journal_path"]
        != str(location["journal"].resolve(strict=False))
    ):
        raise JournalError("owner-mismatch", str(location["owner"]))


def _reconcile_owner_temp(
    journal: dict[str, Any], location: dict[str, pathlib.Path]
) -> None:
    temporary = location["owner_temp"]
    owner = location["owner"]
    temp_node = _existing_file(temporary)
    if temp_node is None:
        return
    owner_node = _existing_file(owner)
    expected = canonical_bytes(_owner_record(journal, location))
    if owner_node is not None:
        if (
            stat.S_ISREG(temp_node.st_mode)
            and stat.S_ISREG(owner_node.st_mode)
            and temp_node.st_uid == os.getuid()
            and owner_node.st_uid == os.getuid()
            and stat.S_IMODE(temp_node.st_mode) == 0o600
            and stat.S_IMODE(owner_node.st_mode) == 0o600
            and temp_node.st_nlink == 2
            and owner_node.st_nlink == 2
            and (temp_node.st_dev, temp_node.st_ino)
            == (owner_node.st_dev, owner_node.st_ino)
            and _read_regular_file(temporary, allowed_links=(2,)) == expected
        ):
            os.unlink(temporary)
            _fsync_directory(location["owner_directory"])
            return
        raise JournalError("owner-unsafe", str(temporary))
    if (
        not stat.S_ISREG(temp_node.st_mode)
        or temp_node.st_uid != os.getuid()
        or stat.S_IMODE(temp_node.st_mode) != 0o600
        or temp_node.st_nlink != 1
    ):
        raise JournalError("owner-unsafe", str(temporary))
    raw = _read_regular_file(temporary)
    if not expected.startswith(raw):
        raise JournalError("owner-unsafe", str(temporary))
    os.unlink(temporary)
    _fsync_directory(location["owner_directory"])


def _claim_owner(
    journal: dict[str, Any], location: dict[str, pathlib.Path]
) -> bool:
    _reconcile_owner_temp(journal, location)
    existing = _read_owner(location)
    expected_record = _owner_record(journal, location)
    if existing is not None:
        if existing == expected_record:
            return False
        if not _owner_workspace_matches(existing, location):
            raise JournalError(
                "transaction-in-progress", existing["journal_path"]
            )
        existing_location = _location_from_owner(location, existing)
        existing_journal = load_journal(existing_location)
        _require_owner_journal_binding(
            existing, existing_journal, existing_location
        )
        if existing_journal["stage"] not in ("completed", "rolled-back"):
            raise JournalError(
                "transaction-in-progress", existing["journal_path"]
            )
        os.unlink(location["owner"])
        _fsync_directory(location["owner_directory"])
    record = expected_record
    payload = canonical_bytes(record)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(location["owner_temp"], flags, 0o600)
    try:
        _write_all(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    directory_fd = os.open(location["owner_directory"], directory_flags)
    try:
        _rename_noreplace(
            directory_fd,
            location["owner_temp"].name,
            location["owner"].name,
        )
        _fsync_directory(location["owner_directory"])
    except FileExistsError:
        _reconcile_owner_temp(journal, location)
        existing = _read_owner(location)
        raise JournalError(
            "transaction-in-progress",
            existing["journal_path"] if existing else str(location["owner"]),
        )
    finally:
        os.close(directory_fd)
    return True


def _release_owner(
    journal: dict[str, Any], location: dict[str, pathlib.Path]
) -> None:
    existing = _read_owner(location)
    if existing is None:
        return
    if existing != _owner_record(journal, location):
        raise JournalError("owner-mismatch", str(location["owner"]))
    os.unlink(location["owner"])
    _fsync_directory(location["owner_directory"])


def install_prepared_journal(
    journal: dict[str, Any],
    location: dict[str, pathlib.Path],
    plan: dict[str, Any],
) -> pathlib.Path:
    normalized_plan = validate_plan(plan)
    normalized = validate_journal(journal, normalized_plan)
    _require_lifecycle_journal_size(normalized, normalized_plan)
    root = pathlib.Path(normalized["workspace"]["root"]).resolve(strict=True)
    with _workspace_lock(root, location) as root_fd:
        _require_effect_temps_absent(
            root_fd,
            root,
            normalized["effects"],
            code="operation-temp-stale",
        )
        created_owner = _claim_owner(normalized, location)
        try:
            installed = _install_prepared_journal_unlocked(
                normalized, location
            )
            _require_workspace_binding(root_fd, root)
            return installed
        except BaseException:
            if created_owner and _existing_file(location["journal"]) is None:
                _release_owner(normalized, location)
            raise


def _decode_journal_payload(
    raw: bytes,
    path: pathlib.Path,
    plan: dict[str, Any] | None,
    *,
    code: str,
) -> dict[str, Any]:
    try:
        journal = validate_journal(strict_load(raw, str(path)), plan)
    except Exception as error:
        raise JournalError(code, str(path)) from error
    if raw != canonical_bytes(journal):
        raise JournalError(code, str(path))
    return journal


def _same_replacement_identity(
    first: dict[str, Any], second: dict[str, Any]
) -> bool:
    immutable = (
        "contract_version",
        "journal_id",
        "workspace_id",
        "plan_digest",
        "plan_source_digest",
        "workspace",
        "effects",
        "created_at",
    )
    return all(first[field] == second[field] for field in immutable)


def _same_except_updated_at(
    first: dict[str, Any], second: dict[str, Any]
) -> bool:
    first_copy = copy.deepcopy(first)
    second_copy = copy.deepcopy(second)
    first_copy["updated_at"] = None
    second_copy["updated_at"] = None
    return first_copy == second_copy


def _direct_journal_successor(
    previous: dict[str, Any], following: dict[str, Any]
) -> bool:
    if not _same_replacement_identity(previous, following):
        return False
    if _same_except_updated_at(previous, following):
        return True
    previous_stage = previous["stage"]
    following_stage = following["stage"]
    previous_cursor = previous["cursor"]
    following_cursor = following["cursor"]
    effect_count = len(previous["effects"])
    if previous_stage == "prepared":
        return (
            following_stage == "applying"
            and previous_cursor == following_cursor == 0
            and previous["validation"] == following["validation"]
            and following["completion_result"] is None
        )
    if previous_stage == "applying":
        if following_stage == "applying":
            return (
                following_cursor == previous_cursor + 1
                and previous["validation"] == following["validation"]
                and following["completion_result"] is None
            )
        if following_stage == "validating":
            return (
                previous_cursor == following_cursor == effect_count
                and previous["validation"] == following["validation"]
            )
        if following_stage == "rolling-back":
            return (
                following_cursor in (
                    previous_cursor,
                    min(previous_cursor + 1, effect_count),
                )
                and following["validation"]["status"] == "failed"
            )
        return False
    if previous_stage == "validating":
        if following_stage == "rolling-back":
            return (
                following_cursor == previous_cursor
                and following["validation"]["status"] == "failed"
            )
        if following_stage == "completed":
            return (
                previous_cursor == following_cursor == effect_count
                and following["validation"]["status"] == "passed"
                and following["completion_result"] is not None
            )
        return False
    if previous_stage == "rolling-back":
        if following_stage == "rolling-back":
            return following_cursor == previous_cursor - 1
        if following_stage == "rolled-back":
            return (
                previous_cursor == following_cursor == 0
                and following["completion_result"] is not None
            )
    return False


def _timestamp_prefix_valid(raw: bytes) -> bool:
    template = b"0000-00-00T00:00:00"
    fixed = raw[: len(template)]
    if not all(
        (48 <= observed <= 57) if expected == 48 else observed == expected
        for observed, expected in zip(fixed, template)
    ):
        return False

    def feasible_component(
        start: int, stop: int, minimum: int, maximum: int
    ) -> bool:
        observed = fixed[start : min(len(fixed), stop)]
        if not observed:
            return True
        width = stop - start
        return any(
            f"{value:0{width}d}".encode("ascii").startswith(observed)
            for value in range(minimum, maximum + 1)
        )

    def feasible_day() -> bool:
        observed = fixed[8 : min(len(fixed), 10)]
        if not observed:
            return True
        if len(fixed) < 7:
            maximum = 31
        else:
            year = int(fixed[:4])
            month = int(fixed[5:7])
            leap_year = year % 4 == 0 and (
                year % 100 != 0 or year % 400 == 0
            )
            if month == 2:
                maximum = 29 if leap_year else 28
            elif month in (4, 6, 9, 11):
                maximum = 30
            else:
                maximum = 31
        return any(
            f"{value:02d}".encode("ascii").startswith(observed)
            for value in range(1, maximum + 1)
        )

    if not all((
        feasible_component(5, 7, 1, 12),
        feasible_day(),
        feasible_component(11, 13, 0, 23),
        feasible_component(14, 16, 0, 59),
        feasible_component(17, 19, 0, 59),
    )):
        return False
    if len(raw) <= len(template):
        return True
    suffix = raw[len(template) :]
    if suffix == b"Z":
        return True
    if not suffix.startswith(b"."):
        return False
    fractional = suffix[1:]
    if not fractional:
        return True
    if fractional.endswith(b"Z"):
        fractional = fractional[:-1]
        if not fractional:
            return False
    return all(48 <= character <= 57 for character in fractional)


def _replacement_prefix_matches(
    temporary_raw: bytes,
    expected: dict[str, Any],
    plan: dict[str, Any] | None,
) -> bool:
    expected_payload = canonical_bytes(expected)
    if expected_payload.startswith(temporary_raw):
        return True
    marker = b'"updated_at":"'
    marker_start = expected_payload.find(marker)
    if marker_start < 0:
        return False
    value_start = marker_start + len(marker)
    if len(temporary_raw) <= value_start:
        return expected_payload.startswith(temporary_raw)
    if temporary_raw[:value_start] != expected_payload[:value_start]:
        return False
    value_end = temporary_raw.find(b'"', value_start)
    if value_end < 0:
        return _timestamp_prefix_valid(temporary_raw[value_start:])
    observed_raw = temporary_raw[value_start:value_end]
    if not observed_raw.endswith(b"Z") or not _timestamp_prefix_valid(
        observed_raw
    ):
        return False
    try:
        observed_timestamp = observed_raw.decode("ascii", errors="strict")
        observed_expected = copy.deepcopy(expected)
        observed_expected["updated_at"] = observed_timestamp
        observed_expected = validate_journal(observed_expected, plan)
    except (UnicodeError, ValueError):
        return False
    return canonical_bytes(observed_expected).startswith(temporary_raw)


def _reconcile_replace_temp(
    location: dict[str, pathlib.Path],
    plan: dict[str, Any] | None = None,
    *,
    expected: dict[str, Any] | None = None,
    defer_partial: bool = False,
) -> None:
    temporary = location["replace_temp"]
    if _existing_file(temporary) is None:
        return
    directory = location["directory"]
    _require_owned_safe_directory(directory, "journal-unsafe", private=True)
    try:
        current_raw = _read_regular_file(location["journal"])
        temporary_raw = _read_regular_file(temporary)
        current = _decode_journal_payload(
            current_raw, location["journal"], plan, code="journal-unsafe"
        )
    except JournalError as error:
        raise JournalError("journal-unsafe", str(temporary)) from error
    try:
        candidate = _decode_journal_payload(
            temporary_raw, temporary, plan, code="journal-unsafe"
        )
    except JournalError as error:
        if expected is None:
            if defer_partial:
                return
            raise JournalError("journal-unsafe", str(temporary)) from error
        normalized_expected = validate_journal(expected, plan)
        if (
            not _direct_journal_successor(current, normalized_expected)
            or not _replacement_prefix_matches(
                temporary_raw, normalized_expected, plan
            )
        ):
            raise JournalError("journal-unsafe", str(temporary)) from error
        os.unlink(temporary)
        _fsync_directory(directory)
        return
    if not (
        _direct_journal_successor(current, candidate)
        or _direct_journal_successor(candidate, current)
    ):
        raise JournalError("journal-unsafe", str(temporary))
    os.unlink(temporary)
    _fsync_directory(directory)


def load_journal(
    location: dict[str, pathlib.Path],
    plan: dict[str, Any] | None = None,
    *,
    expected_replacement: dict[str, Any] | None = None,
    defer_replace_partial: bool = False,
) -> dict[str, Any]:
    _reconcile_replace_temp(
        location,
        plan,
        expected=expected_replacement,
        defer_partial=defer_replace_partial,
    )
    raw = _read_regular_file(location["journal"])
    journal = _decode_journal_payload(
        raw, location["journal"], plan, code="journal-corrupt"
    )
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
    payload = canonical_bytes(normalized)
    _require_journal_size(len(payload), str(location["journal"]))
    current = load_journal(
        location, plan, expected_replacement=normalized
    )
    if current["journal_id"] != normalized["journal_id"]:
        raise JournalError("journal-identity-mismatch", current["journal_id"])
    directory = location["directory"]
    directory_node = _require_owned_safe_directory(
        directory, "journal-unsafe", private=True
    )
    directory_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    directory_fd = os.open(directory, directory_flags)
    opened_directory = os.fstat(directory_fd)
    if (opened_directory.st_dev, opened_directory.st_ino) != (
        directory_node.st_dev,
        directory_node.st_ino,
    ):
        os.close(directory_fd)
        raise JournalError("journal-unsafe", str(directory))
    temporary_name = location["replace_temp"].name
    temporary = directory / temporary_name
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(
            temporary_name, flags, 0o600, dir_fd=directory_fd
        )
    except BaseException:
        os.close(directory_fd)
        raise
    try:
        try:
            _write_all(descriptor, payload)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except BaseException:
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        raise
    try:
        _rename_exchange(
            directory_fd, location["journal"].name, temporary_name
        )
        observed_previous = _read_regular_file(temporary)
        observed_next = _read_regular_file(location["journal"])
        if (
            observed_previous != canonical_bytes(current)
            or observed_next != payload
        ):
            _rename_exchange(
                directory_fd, location["journal"].name, temporary_name
            )
            os.fsync(directory_fd)
            if _read_regular_file(temporary) == payload:
                os.unlink(temporary_name, dir_fd=directory_fd)
                os.fsync(directory_fd)
            raise JournalError("journal-state-stale", str(location["journal"]))
        os.fsync(directory_fd)
        os.unlink(temporary_name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except Exception:
        if _existing_file(temporary) is not None:
            try:
                _reconcile_replace_temp(location, plan)
            except JournalError:
                pass
        raise
    finally:
        os.close(directory_fd)
    return normalized


def _open_coordination_lock(location: dict[str, pathlib.Path]) -> int:
    coordination = location["coordination"]
    _require_owned_safe_directory(
        coordination, "coordination-root-unsafe", private=True
    )
    path = location["lock"]
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    node = os.lstat(path)
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(node.st_mode)
        or node.st_uid != os.getuid()
        or stat.S_IMODE(node.st_mode) != 0o600
        or node.st_nlink != 1
        or (opened.st_dev, opened.st_ino) != (node.st_dev, node.st_ino)
        or opened.st_uid != node.st_uid
        or opened.st_nlink != 1
    ):
        os.close(descriptor)
        raise JournalError("coordination-lock-unsafe", str(path))
    return descriptor


def _workspace_binding_valid(
    root_fd: int, root: pathlib.Path
) -> bool:
    opened = os.fstat(root_fd)
    try:
        current = os.lstat(root)
    except OSError:
        return False
    return (
        stat.S_ISDIR(current.st_mode)
        and not stat.S_ISLNK(current.st_mode)
        and (opened.st_dev, opened.st_ino) == (current.st_dev, current.st_ino)
    )


def _require_workspace_binding(root_fd: int, root: pathlib.Path) -> None:
    if not _workspace_binding_valid(root_fd, root):
        raise JournalError("workspace-binding-stale", str(root))


@contextmanager
def _workspace_lock(
    root: pathlib.Path, location: dict[str, pathlib.Path]
) -> Iterator[int]:
    node = _lstat_directory(root, "workspace-unsafe")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    root_descriptor = os.open(root, flags)
    try:
        coordination_descriptor = _open_coordination_lock(location)
        try:
            opened = os.fstat(root_descriptor)
            if (
                (opened.st_dev, opened.st_ino) != (node.st_dev, node.st_ino)
                or opened.st_uid != os.getuid()
            ):
                raise JournalError("workspace-unsafe", str(root))
            if (
                opened.st_dev != location["workspace_device"]
                or opened.st_ino != location["workspace_inode"]
            ):
                raise JournalError("workspace-binding-stale", str(root))
            try:
                fcntl.flock(
                    coordination_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB
                )
                fcntl.flock(root_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except (BlockingIOError, OSError) as error:
                raise JournalError("apply-in-progress", str(root)) from error
            _require_workspace_binding(root_descriptor, root)
            yield root_descriptor
        finally:
            try:
                fcntl.flock(root_descriptor, fcntl.LOCK_UN)
                fcntl.flock(coordination_descriptor, fcntl.LOCK_UN)
            finally:
                os.close(coordination_descriptor)
    finally:
        os.close(root_descriptor)


def _image_for_path(
    root_fd: int, root: pathlib.Path, path: str
) -> dict[str, Any]:
    try:
        directory_fd, parent_path = _open_parent_fd(root_fd, root, path)
    except FileNotFoundError:
        _require_workspace_binding(root_fd, root)
        return _absent_image()
    try:
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", path)
        image = _image_at(directory_fd, pathlib.PurePosixPath(path).name)
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", path)
        return image
    finally:
        os.close(directory_fd)


def _image_matches(
    root_fd: int,
    root: pathlib.Path,
    path: str,
    image: dict[str, Any],
) -> bool:
    return _image_for_path(root_fd, root, path) == image


def _observed_prefix(
    root_fd: int, root: pathlib.Path, effects: list[dict[str, Any]]
) -> int:
    prefix = 0
    before_seen = False
    for effect in effects:
        is_before = _image_matches(
            root_fd, root, effect["path"], effect["before"]
        )
        is_after = _image_matches(
            root_fd, root, effect["path"], effect["after"]
        )
        if is_after and not is_before:
            if before_seen:
                raise JournalError("transaction-state-mismatch", effect["path"])
            prefix += 1
        elif is_before and not is_after:
            before_seen = True
        else:
            raise JournalError("transaction-state-mismatch", effect["path"])
    return prefix


def _verify_preserved(
    root_fd: int, root: pathlib.Path, plan: dict[str, Any]
) -> None:
    for preserved in plan["preserved"]:
        observed = _image_for_path(root_fd, root, preserved["path"])
        if any(
            observed[field] != preserved[field]
            for field in ("node_type", "mode", "digest", "link_target")
        ):
            raise JournalError("preserved-node-stale", preserved["path"])


def _verify_parent_directories(
    root_fd: int,
    root: pathlib.Path,
    plan: dict[str, Any],
    *,
    completed: bool,
) -> None:
    for parent in plan["parent_directories"]:
        observed = _image_for_path(root_fd, root, parent["path"])
        expected_type = (
            parent["after_type"] if completed else parent["before_type"]
        )
        expected_mode = (
            parent["after_mode"] if completed else parent["before_mode"]
        )
        if expected_type is None:
            matches = observed["node_type"] == "absent"
        else:
            matches = (
                observed["node_type"] == expected_type
                and observed["mode"] == expected_mode
            )
        if not matches:
            raise JournalError(
                "transaction-state-mismatch", parent["path"]
            )


def _verify_terminal_snapshot(
    root_fd: int,
    root: pathlib.Path,
    plan: dict[str, Any],
    journal: dict[str, Any],
    *,
    completed: bool,
) -> None:
    _require_workspace_binding(root_fd, root)
    _verify_preserved(root_fd, root, plan)
    _verify_parent_directories(
        root_fd, root, plan, completed=completed
    )
    expected_prefix = len(journal["effects"]) if completed else 0
    if _observed_prefix(root_fd, root, journal["effects"]) != expected_prefix:
        raise JournalError("transaction-state-mismatch", str(root))
    _require_effect_temps_absent(
        root_fd,
        root,
        journal["effects"],
        code="transaction-state-mismatch",
    )
    _require_workspace_binding(root_fd, root)


def _mode_permissions(mode: str) -> int:
    if mode == "100644":
        return 0o644
    if mode == "100755":
        return 0o755
    raise JournalError("node-mode-invalid", mode)


def _open_parent_fd(
    root_fd: int, root: pathlib.Path, relative: str
) -> tuple[int, pathlib.Path]:
    parts = pathlib.PurePosixPath(relative).parts
    parent_parts = parts[:-1]
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    descriptor = os.dup(root_fd)
    parent_path = root
    try:
        for part in parent_parts:
            next_descriptor = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
            parent_path /= part
        return descriptor, parent_path
    except BaseException:
        os.close(descriptor)
        raise


def _image_at(
    directory_fd: int,
    name: str,
    *,
    allowed_links: tuple[int, ...] = (1,),
) -> dict[str, Any]:
    try:
        node = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return _absent_image()
    if stat.S_ISREG(node.st_mode):
        if node.st_nlink not in allowed_links:
            raise JournalError("node-hardlink", name)
        permissions = stat.S_IMODE(node.st_mode)
        mode = "100644" if permissions == 0o644 else "100755" if permissions == 0o755 else None
        if mode is None:
            raise JournalError("node-mode-invalid", name)
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
        try:
            opened = os.fstat(descriptor)
            if (
                opened.st_nlink not in allowed_links
                or opened.st_uid != node.st_uid
                or (opened.st_dev, opened.st_ino) != (node.st_dev, node.st_ino)
                or stat.S_IMODE(opened.st_mode)
                != stat.S_IMODE(node.st_mode)
            ):
                raise JournalError("node-unsafe", name)
            chunks = []
            while True:
                chunk = os.read(descriptor, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            content = b"".join(chunks)
        finally:
            os.close(descriptor)
        return {
            "node_type": "file",
            "mode": mode,
            "content_base64": base64.b64encode(content).decode("ascii"),
            "link_target": None,
            "digest": node_digest("file", mode, content=content),
        }
    if stat.S_ISLNK(node.st_mode):
        if node.st_nlink not in allowed_links:
            raise JournalError("node-hardlink", name)
        target = os.readlink(name, dir_fd=directory_fd)
        verified = os.stat(
            name, dir_fd=directory_fd, follow_symlinks=False
        )
        if (
            not stat.S_ISLNK(verified.st_mode)
            or verified.st_nlink not in allowed_links
            or verified.st_uid != node.st_uid
            or (verified.st_dev, verified.st_ino)
            != (node.st_dev, node.st_ino)
        ):
            raise JournalError("node-unsafe", name)
        return {
            "node_type": "symlink",
            "mode": "120000",
            "content_base64": None,
            "link_target": target,
            "digest": node_digest("symlink", "120000", link_target=target),
        }
    if stat.S_ISDIR(node.st_mode):
        child_fd = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=directory_fd,
        )
        try:
            opened = os.fstat(child_fd)
            if (
                (opened.st_dev, opened.st_ino)
                != (node.st_dev, node.st_ino)
                or stat.S_IMODE(opened.st_mode)
                != stat.S_IMODE(node.st_mode)
            ):
                raise JournalError("node-unsafe", name)
        finally:
            os.close(child_fd)
        mode = f"04{stat.S_IMODE(node.st_mode):04o}"
        return {
            "node_type": "directory",
            "mode": mode,
            "content_base64": None,
            "link_target": None,
            "digest": node_digest("directory", mode),
        }
    raise JournalError("node-type-invalid", name)


def _image_matches_at(
    directory_fd: int, name: str, image: dict[str, Any]
) -> bool:
    return _image_at(directory_fd, name) == image


def _install_image_temp_at(
    directory_fd: int,
    temporary_name: str,
    image: dict[str, Any],
    effect: dict[str, Any],
    direction: str,
    fault_hook: Callable[[str, dict[str, Any], str], None],
) -> None:
    if _image_at(directory_fd, temporary_name)["node_type"] != "absent":
        raise JournalError("transaction-state-mismatch", temporary_name)
    if image["node_type"] == "file":
        content = base64.b64decode(image["content_base64"], validate=True)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(
            temporary_name, flags, 0o600, dir_fd=directory_fd
        )
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
        os.symlink(image["link_target"], temporary_name, dir_fd=directory_fd)
        fault_hook("after-temp-create", effect, direction)
        fault_hook("after-temp-fsync", effect, direction)
    else:
        raise JournalError("node-type-invalid", image["node_type"])


def _rename_noreplace(
    directory_fd: int, source_name: str, target_name: str
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    source = os.fsencode(source_name)
    target = os.fsencode(target_name)
    if hasattr(libc, "renameatx_np"):
        result = libc.renameatx_np(
            directory_fd,
            ctypes.c_char_p(source),
            directory_fd,
            ctypes.c_char_p(target),
            0x00000004,
        )
    elif hasattr(libc, "renameat2"):
        result = libc.renameat2(
            directory_fd,
            ctypes.c_char_p(source),
            directory_fd,
            ctypes.c_char_p(target),
            0x00000001,
        )
    else:
        raise JournalError("platform-atomic-rename-unavailable", source_name)
    if result != 0:
        error_number = ctypes.get_errno()
        if error_number == errno.EEXIST:
            raise FileExistsError(error_number, os.strerror(error_number), target_name)
        raise OSError(error_number, os.strerror(error_number), source_name)


def _rename_exchange(
    directory_fd: int, first_name: str, second_name: str
) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    first = os.fsencode(first_name)
    second = os.fsencode(second_name)
    if hasattr(libc, "renameatx_np"):
        result = libc.renameatx_np(
            directory_fd,
            ctypes.c_char_p(first),
            directory_fd,
            ctypes.c_char_p(second),
            0x00000002,
        )
    elif hasattr(libc, "renameat2"):
        result = libc.renameat2(
            directory_fd,
            ctypes.c_char_p(first),
            directory_fd,
            ctypes.c_char_p(second),
            0x00000002,
        )
    else:
        raise JournalError("platform-atomic-rename-unavailable", first_name)
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), first_name)


def _parent_binding_valid(
    directory_fd: int, parent_path: pathlib.Path
) -> bool:
    opened = os.fstat(directory_fd)
    try:
        current = os.lstat(parent_path)
    except OSError:
        return False
    return (
        stat.S_ISDIR(current.st_mode)
        and not stat.S_ISLNK(current.st_mode)
        and (opened.st_dev, opened.st_ino) == (current.st_dev, current.st_ino)
    )


def _transition_effect(
    root_fd: int,
    root: pathlib.Path,
    effect: dict[str, Any],
    source: dict[str, Any],
    target_image: dict[str, Any],
    journal_id: str,
    direction: str,
    fault_hook: Callable[[str, dict[str, Any], str], None],
) -> None:
    try:
        directory_fd, parent_path = _open_parent_fd(
            root_fd, root, effect["path"]
        )
    except FileNotFoundError:
        _require_workspace_binding(root_fd, root)
        raise JournalError(
            "transaction-state-mismatch", effect["path"]
        ) from None
    target_name = pathlib.PurePosixPath(effect["path"]).name
    temp_path = effect["temp_path"]
    if temp_path is None and target_image["node_type"] in ("file", "symlink"):
        temp_path = _temp_path(effect["path"], journal_id, effect["effect_id"])
    temporary_name = pathlib.PurePosixPath(temp_path).name if temp_path else target_name
    try:
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
        if not _image_matches_at(directory_fd, target_name, source):
            raise JournalError("transaction-state-mismatch", effect["path"])
        fault_hook("after-source-check", effect, direction)
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
        if target_image["node_type"] == "absent":
            if source["node_type"] == "directory":
                os.rmdir(target_name, dir_fd=directory_fd)
            else:
                if _image_at(
                    directory_fd, temporary_name
                )["node_type"] != "absent":
                    raise JournalError(
                        "transaction-state-mismatch", temp_path
                    )
                if not _image_matches_at(
                    directory_fd, target_name, source
                ):
                    raise JournalError(
                        "transaction-state-mismatch", effect["path"]
                    )
                _rename_noreplace(
                    directory_fd, target_name, temporary_name
                )
                if not _image_matches_at(
                    directory_fd, temporary_name, source
                ):
                    try:
                        _rename_noreplace(
                            directory_fd, temporary_name, target_name
                        )
                        os.fsync(directory_fd)
                    except FileExistsError:
                        pass
                    raise JournalError(
                        "transaction-state-mismatch", effect["path"]
                    )
            fault_hook("after-target-install", effect, direction)
            _require_workspace_binding(root_fd, root)
            if not _parent_binding_valid(directory_fd, parent_path):
                raise JournalError("node-parent-unsafe", effect["path"])
            if source["node_type"] != "directory":
                if not _image_matches_at(
                    directory_fd, temporary_name, source
                ):
                    raise JournalError(
                        "transaction-state-mismatch", temp_path
                    )
                os.unlink(temporary_name, dir_fd=directory_fd)
                fault_hook("after-temp-unlink", effect, direction)
            os.fsync(directory_fd)
            fault_hook("after-parent-fsync", effect, direction)
            _require_workspace_binding(root_fd, root)
            if not _parent_binding_valid(directory_fd, parent_path):
                raise JournalError("node-parent-unsafe", effect["path"])
            if not _image_matches_at(
                directory_fd, target_name, target_image
            ):
                raise JournalError(
                    "transaction-state-mismatch", effect["path"]
                )
            return
        if target_image["node_type"] == "directory":
            previous_umask = os.umask(0)
            try:
                os.mkdir(target_name, 0o700, dir_fd=directory_fd)
            finally:
                os.umask(previous_umask)
            fault_hook("after-directory-create", effect, direction)
            _require_workspace_binding(root_fd, root)
            if not _parent_binding_valid(directory_fd, parent_path):
                raise JournalError("node-parent-unsafe", effect["path"])
            child_fd = os.open(
                target_name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_fd,
            )
            try:
                os.fchmod(child_fd, 0o755)
                os.fsync(child_fd)
            finally:
                os.close(child_fd)
            os.fsync(directory_fd)
            fault_hook("after-parent-fsync", effect, direction)
            _require_workspace_binding(root_fd, root)
            if not _parent_binding_valid(directory_fd, parent_path):
                raise JournalError("node-parent-unsafe", effect["path"])
            if not _image_matches_at(directory_fd, target_name, target_image):
                raise JournalError("transaction-state-mismatch", effect["path"])
            fault_hook("after-target-install", effect, direction)
            return

        _install_image_temp_at(
            directory_fd,
            temporary_name,
            target_image,
            effect,
            direction,
            fault_hook,
        )
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
        if not _image_matches_at(directory_fd, target_name, source):
            raise JournalError("transaction-state-mismatch", effect["path"])
        if source["node_type"] == "absent":
            os.link(
                temporary_name,
                target_name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
        else:
            _rename_exchange(directory_fd, target_name, temporary_name)
        fault_hook("after-target-install", effect, direction)
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
        if source["node_type"] == "absent":
            target_node = os.stat(
                target_name, dir_fd=directory_fd, follow_symlinks=False
            )
            temp_node = os.stat(
                temporary_name, dir_fd=directory_fd, follow_symlinks=False
            )
            transition_valid = (
                target_node.st_nlink == 2
                and temp_node.st_nlink == 2
                and (target_node.st_dev, target_node.st_ino)
                == (temp_node.st_dev, temp_node.st_ino)
                and _image_at(
                    directory_fd, target_name, allowed_links=(2,)
                )
                == target_image
            )
        else:
            transition_valid = (
                _image_matches_at(directory_fd, target_name, target_image)
                and _image_matches_at(directory_fd, temporary_name, source)
            )
        if not transition_valid:
            if source["node_type"] != "absent":
                _rename_exchange(directory_fd, target_name, temporary_name)
                os.fsync(directory_fd)
                if _image_matches_at(
                    directory_fd, temporary_name, target_image
                ):
                    os.unlink(temporary_name, dir_fd=directory_fd)
                    os.fsync(directory_fd)
            raise JournalError("transaction-state-mismatch", effect["path"])
        os.unlink(temporary_name, dir_fd=directory_fd)
        fault_hook("after-temp-unlink", effect, direction)
        os.fsync(directory_fd)
        fault_hook("after-parent-fsync", effect, direction)
        _require_workspace_binding(root_fd, root)
        if not _image_matches_at(directory_fd, target_name, target_image):
            raise JournalError("transaction-state-mismatch", effect["path"])
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
    finally:
        os.close(directory_fd)


def _stat_at(directory_fd: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _require_effect_temps_absent(
    root_fd: int,
    root: pathlib.Path,
    effects: list[dict[str, Any]],
    *,
    code: str,
) -> None:
    for effect in effects:
        temp_path = effect["temp_path"]
        if temp_path is None:
            continue
        try:
            directory_fd, parent_path = _open_parent_fd(
                root_fd, root, temp_path
            )
        except FileNotFoundError:
            _require_workspace_binding(root_fd, root)
            continue
        except OSError as error:
            raise JournalError(code, temp_path) from error
        try:
            _require_workspace_binding(root_fd, root)
            if not _parent_binding_valid(directory_fd, parent_path):
                raise JournalError(code, temp_path)
            if _stat_at(
                directory_fd, pathlib.PurePosixPath(temp_path).name
            ) is not None:
                raise JournalError(code, temp_path)
        finally:
            os.close(directory_fd)


def _reconcile_partial_directory(
    root_fd: int,
    root: pathlib.Path,
    journal: dict[str, Any],
) -> None:
    if journal["stage"] != "applying":
        return
    cursor = journal["cursor"]
    if cursor >= len(journal["effects"]):
        return
    effect = journal["effects"][cursor]
    if (
        effect["kind"] != "ensure-directory"
        or effect["before"]["node_type"] != "absent"
        or effect["after"]["node_type"] != "directory"
        or effect["after"]["mode"] != "040755"
    ):
        return
    try:
        directory_fd, parent_path = _open_parent_fd(
            root_fd, root, effect["path"]
        )
    except FileNotFoundError:
        _require_workspace_binding(root_fd, root)
        return
    name = pathlib.PurePosixPath(effect["path"]).name
    try:
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
        node = _stat_at(directory_fd, name)
        if node is None or _image_matches_at(
            directory_fd, name, effect["after"]
        ):
            return
        if (
            not stat.S_ISDIR(node.st_mode)
            or stat.S_ISLNK(node.st_mode)
            or node.st_uid != os.getuid()
            or node.st_nlink != 2
            or stat.S_IMODE(node.st_mode) != 0o700
        ):
            return
        child_flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        child_fd = os.open(name, child_flags, dir_fd=directory_fd)
        try:
            opened = os.fstat(child_fd)
            if (
                (opened.st_dev, opened.st_ino)
                != (node.st_dev, node.st_ino)
                or opened.st_uid != node.st_uid
                or opened.st_nlink != 2
                or stat.S_IMODE(opened.st_mode) != 0o700
                or os.listdir(child_fd)
            ):
                return
            os.fchmod(child_fd, 0o755)
            os.fsync(child_fd)
        finally:
            os.close(child_fd)
        os.fsync(directory_fd)
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
        if not _image_matches_at(directory_fd, name, effect["after"]):
            raise JournalError(
                "transaction-state-mismatch", effect["path"]
            )
    finally:
        os.close(directory_fd)


def _read_regular_at(
    directory_fd: int,
    name: str,
    expected: os.stat_result,
    *,
    allowed_links: tuple[int, ...] = (1,),
) -> bytes:
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != expected.st_uid
            or opened.st_nlink not in allowed_links
            or (opened.st_dev, opened.st_ino)
            != (expected.st_dev, expected.st_ino)
            or stat.S_IMODE(opened.st_mode)
            != stat.S_IMODE(expected.st_mode)
        ):
            raise JournalError("node-unsafe", name)
        chunks = []
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _residue_matches_image_at(
    directory_fd: int,
    name: str,
    node: os.stat_result,
    image: dict[str, Any],
    *,
    allowed_links: tuple[int, ...] = (1,),
) -> bool:
    if node.st_uid != os.getuid() or node.st_nlink not in allowed_links:
        return False
    if image["node_type"] == "file" and stat.S_ISREG(node.st_mode):
        if stat.S_IMODE(node.st_mode) != _mode_permissions(image["mode"]):
            return False
        content = _read_regular_at(
            directory_fd, name, node, allowed_links=allowed_links
        )
        return node_digest(
            "file", image["mode"], content=content
        ) == image["digest"]
    if image["node_type"] == "symlink" and stat.S_ISLNK(node.st_mode):
        return os.readlink(name, dir_fd=directory_fd) == image["link_target"]
    return False


def _residue_matches_target_prefix_at(
    directory_fd: int,
    name: str,
    node: os.stat_result,
    target_image: dict[str, Any],
) -> bool:
    if _residue_matches_image_at(
        directory_fd, name, node, target_image
    ):
        return True
    if (
        target_image["node_type"] != "file"
        or not stat.S_ISREG(node.st_mode)
        or node.st_uid != os.getuid()
        or node.st_nlink != 1
        or stat.S_IMODE(node.st_mode) != 0o600
    ):
        return False
    observed = _read_regular_at(directory_fd, name, node)
    expected = base64.b64decode(
        target_image["content_base64"], validate=True
    )
    return expected.startswith(observed)


def _unlink_reconciled_temp(
    root_fd: int,
    root: pathlib.Path,
    directory_fd: int,
    parent_path: pathlib.Path,
    temporary_name: str,
    effect_path: str,
) -> None:
    _require_workspace_binding(root_fd, root)
    if not _parent_binding_valid(directory_fd, parent_path):
        raise JournalError("node-parent-unsafe", effect_path)
    os.unlink(temporary_name, dir_fd=directory_fd)
    os.fsync(directory_fd)
    _require_workspace_binding(root_fd, root)
    if not _parent_binding_valid(directory_fd, parent_path):
        raise JournalError("node-parent-unsafe", effect_path)


def _reconcile_temp_residue(
    root_fd: int,
    root: pathlib.Path,
    effect: dict[str, Any],
    journal_id: str,
    direction: str,
) -> None:
    source_image = (
        effect["after"] if direction == "reverse" else effect["before"]
    )
    target_image = (
        effect["before"] if direction == "reverse" else effect["after"]
    )
    temp_path = effect["temp_path"]
    if temp_path is None and target_image["node_type"] in ("file", "symlink"):
        temp_path = _temp_path(effect["path"], journal_id, effect["effect_id"])
    if temp_path is None:
        return
    target_pure = pathlib.PurePosixPath(effect["path"])
    temp_pure = pathlib.PurePosixPath(temp_path)
    if target_pure.parent != temp_pure.parent:
        raise JournalError("transaction-state-mismatch", temp_path)
    try:
        directory_fd, parent_path = _open_parent_fd(
            root_fd, root, effect["path"]
        )
    except FileNotFoundError:
        _require_workspace_binding(root_fd, root)
        return
    target_name = target_pure.name
    temporary_name = temp_pure.name
    try:
        _require_workspace_binding(root_fd, root)
        if not _parent_binding_valid(directory_fd, parent_path):
            raise JournalError("node-parent-unsafe", effect["path"])
        residue = _stat_at(directory_fd, temporary_name)
        if residue is None:
            return
        target_node = _stat_at(directory_fd, target_name)
        if target_node is not None and target_node.st_nlink != 1:
            if (
                source_image["node_type"] == "absent"
                and target_node.st_nlink == 2
                and residue.st_nlink == 2
                and (target_node.st_dev, target_node.st_ino)
                == (residue.st_dev, residue.st_ino)
                and _residue_matches_image_at(
                    directory_fd,
                    target_name,
                    target_node,
                    target_image,
                    allowed_links=(2,),
                )
            ):
                _unlink_reconciled_temp(
                    root_fd,
                    root,
                    directory_fd,
                    parent_path,
                    temporary_name,
                    effect["path"],
                )
                return
            raise JournalError("transaction-state-mismatch", temp_path)
        if _image_matches_at(directory_fd, target_name, source_image) and (
            _residue_matches_target_prefix_at(
                directory_fd, temporary_name, residue, target_image
            )
        ):
            _unlink_reconciled_temp(
                root_fd,
                root,
                directory_fd,
                parent_path,
                temporary_name,
                effect["path"],
            )
            return
        if _image_matches_at(directory_fd, target_name, target_image) and (
            _residue_matches_image_at(
                directory_fd, temporary_name, residue, source_image
            )
        ):
            _unlink_reconciled_temp(
                root_fd,
                root,
                directory_fd,
                parent_path,
                temporary_name,
                effect["path"],
            )
            return
        raise JournalError("transaction-state-mismatch", temp_path)
    finally:
        os.close(directory_fd)


def _reconcile_temp_residues(
    root_fd: int,
    root: pathlib.Path,
    effects: list[dict[str, Any]],
    journal_id: str,
    direction: str,
) -> None:
    for effect in effects:
        _reconcile_temp_residue(
            root_fd, root, effect, journal_id, direction
        )


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


def _result_operations(journal: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "op": effect["kind"],
            "path": effect["path"],
            "before_digest": effect["before"]["digest"],
            "after_digest": effect["after"]["digest"],
        }
        for effect in journal["effects"]
        if effect["kind"] != "ensure-directory"
    ]


def _budget_validation(
    *,
    status: str,
    classification: str | None,
    basis_kind: str | None,
    basis_digest: str | None,
    blockers: list[dict[str, str]],
) -> dict[str, Any]:
    validation = {
        "status": status,
        "classification_after": classification,
        "basis_kind": basis_kind,
        "basis_digest": basis_digest,
        "blockers": blockers,
        "digest": None,
    }
    validation["digest"] = canonical_digest(
        validation, null_field="digest"
    )
    return validate_validation(validation)


def _terminal_budget_candidate(
    journal: dict[str, Any],
    plan: dict[str, Any],
    *,
    completed: bool,
    failed_validation: dict[str, Any] | None = None,
) -> dict[str, Any]:
    candidate = copy.deepcopy(journal)
    if completed:
        _set_cursor(
            candidate, len(candidate["effects"]), candidate["updated_at"]
        )
        basis_digest = plan["removal_plan_basis_digest"]
        basis_kind = "removal-plan"
        if basis_digest is None:
            basis_kind = "migration-candidate"
            basis_digest = plan["provenance_after"]["receipt_digest"]
        if basis_digest is None:
            basis_digest = "sha256:" + "0" * 64
        candidate["validation"] = _budget_validation(
            status="passed",
            classification=plan["target_classification"],
            basis_kind=basis_kind,
            basis_digest=basis_digest,
            blockers=[],
        )
        candidate["stage"] = "completed"
        candidate["direction"] = "none"
        applied = _result_operations(candidate)
        result_stage = "completed"
    else:
        _set_cursor(candidate, 0, candidate["updated_at"])
        if failed_validation is None:
            possible_refs = [
                plan["workspace"]["root"],
                *(effect["path"] for effect in candidate["effects"]),
            ]
            budget_ref = max(
                possible_refs,
                key=lambda value: len(canonical_bytes({"ref": value})),
            )
            failed_validation = _budget_validation(
                status="failed",
                classification=None,
                basis_kind=None,
                basis_digest=None,
                blockers=[{
                    "code": "candidate-validation-too-large",
                    "ref": budget_ref,
                }],
            )
        candidate["validation"] = copy.deepcopy(failed_validation)
        candidate["stage"] = "rolled-back"
        candidate["direction"] = "none"
        applied = []
        result_stage = "rolled-back"
    candidate["completion_result"] = _result(
        plan,
        candidate,
        stage=result_stage,
        resumed=False,
        applied=applied,
    )
    return validate_journal(candidate, plan)


def _maximum_lifecycle_journal_size(
    journal: dict[str, Any], plan: dict[str, Any]
) -> int:
    candidates = (
        journal,
        _terminal_budget_candidate(journal, plan, completed=True),
        _terminal_budget_candidate(journal, plan, completed=False),
    )
    return max(len(canonical_bytes(candidate)) for candidate in candidates)


def _require_lifecycle_journal_size(
    journal: dict[str, Any], plan: dict[str, Any]
) -> None:
    _require_journal_size(
        _maximum_lifecycle_journal_size(journal, plan),
        "journal-lifecycle",
    )


def _complete_rollback(
    plan: dict[str, Any],
    journal: dict[str, Any],
    location: dict[str, pathlib.Path],
    root_fd: int,
    root: pathlib.Path,
    updated_at: str,
    resumed: bool,
    fault_hook: Callable[[str, dict[str, Any], str], None],
) -> dict[str, Any]:
    while journal["cursor"]:
        effect = journal["effects"][journal["cursor"] - 1]
        if _image_matches(
            root_fd, root, effect["path"], effect["before"]
        ):
            _set_cursor(journal, journal["cursor"] - 1, updated_at)
            journal = _replace_journal(journal, location, plan)
            continue
        if not _image_matches(
            root_fd, root, effect["path"], effect["after"]
        ):
            raise JournalError("transaction-state-mismatch", effect["path"])
        fault_hook("before-effect", effect, "reverse")
        _transition_effect(
            root_fd,
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
    _verify_terminal_snapshot(
        root_fd, root, plan, journal, completed=False
    )
    journal = _replace_journal(journal, location, plan)
    _require_workspace_binding(root_fd, root)
    _release_owner(journal, location)
    _require_workspace_binding(root_fd, root)
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
    with _workspace_lock(root, location) as root_fd:
        journal = load_journal(
            location,
            normalized_plan,
            defer_replace_partial=True,
        )
        _claim_owner(journal, location)
        if journal["plan_source_digest"] != plan_source_digest:
            raise JournalError("plan-source-stale", "--plan-file")
        _verify_preserved(root_fd, root, normalized_plan)
        entry_stage = journal["stage"]
        recovery_direction = (
            "reverse"
            if entry_stage in ("rolling-back", "rolled-back")
            else "forward"
        )
        if entry_stage == "prepared":
            _require_effect_temps_absent(
                root_fd,
                root,
                journal["effects"],
                code="operation-temp-stale",
            )
        elif entry_stage in ("completed", "rolled-back"):
            _reconcile_replace_temp(location, normalized_plan)
            _require_effect_temps_absent(
                root_fd,
                root,
                journal["effects"],
                code="transaction-state-mismatch",
            )
        else:
            _reconcile_partial_directory(root_fd, root, journal)
            _reconcile_temp_residues(
                root_fd,
                root,
                journal["effects"],
                journal["journal_id"],
                recovery_direction,
            )
        resumed = entry_stage != "prepared"
        prefix = _observed_prefix(root_fd, root, journal["effects"])
        if entry_stage == "completed":
            _verify_terminal_snapshot(
                root_fd,
                root,
                normalized_plan,
                journal,
                completed=True,
            )
            result = _terminal_replay(normalized_plan, journal)
            _release_owner(journal, location)
            _require_workspace_binding(root_fd, root)
            return result
        if entry_stage == "rolled-back":
            _verify_terminal_snapshot(
                root_fd,
                root,
                normalized_plan,
                journal,
                completed=False,
            )
            result = _terminal_replay(normalized_plan, journal)
            _release_owner(journal, location)
            _require_workspace_binding(root_fd, root)
            return result
        if entry_stage == "rolling-back":
            if prefix not in (journal["cursor"], journal["cursor"] - 1):
                raise JournalError("transaction-state-mismatch", str(root))
            return _complete_rollback(
                normalized_plan,
                journal,
                location,
                root_fd,
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
                    root_fd,
                    root,
                    active_effect["path"],
                    active_effect["after"],
                ):
                    _set_cursor(journal, journal["cursor"] + 1, updated_at)
                    journal = _replace_journal(
                        journal, location, normalized_plan
                    )
                    continue
                if not _image_matches(
                    root_fd,
                    root,
                    active_effect["path"],
                    active_effect["before"],
                ):
                    raise JournalError(
                        "transaction-state-mismatch", active_effect["path"]
                    )
                hook("before-effect", active_effect, "forward")
                _transition_effect(
                    root_fd,
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
            if journal["effects"]:
                hook("before-validation", journal["effects"][-1], "forward")
            _require_workspace_binding(root_fd, root)
            validating_candidate = True
            journal["validation"] = validate_validation(
                validate_after(normalized_plan)
            )
            _require_workspace_binding(root_fd, root)
            if journal["validation"]["status"] != "passed":
                failed_terminal = _terminal_budget_candidate(
                    journal,
                    normalized_plan,
                    completed=False,
                    failed_validation=journal["validation"],
                )
                if len(canonical_bytes(failed_terminal)) > MAX_JOURNAL_BYTES:
                    journal["validation"] = _budget_validation(
                        status="failed",
                        classification=None,
                        basis_kind=None,
                        basis_digest=None,
                        blockers=[{
                            "code": "candidate-validation-too-large",
                            "ref": str(root),
                        }],
                    )
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
                    root_fd,
                    root,
                    updated_at,
                    resumed,
                    hook,
                )
            if journal["effects"]:
                hook("after-validation", journal["effects"][-1], "forward")
                _require_workspace_binding(root_fd, root)
        except JournalError:
            raise
        except Exception:
            if active_effect is not None and not validating_candidate:
                _reconcile_temp_residue(
                    root_fd,
                    root,
                    active_effect,
                    journal["journal_id"],
                    "forward",
                )
            prefix = _observed_prefix(root_fd, root, journal["effects"])
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
                root_fd,
                root,
                updated_at,
                resumed,
                hook,
            )

        journal["stage"] = "completed"
        journal["direction"] = "none"
        journal["updated_at"] = updated_at
        applied = _result_operations(journal)
        result = _result(
            normalized_plan,
            journal,
            stage="completed",
            resumed=resumed,
            applied=applied,
        )
        journal["completion_result"] = result
        _verify_terminal_snapshot(
            root_fd,
            root,
            normalized_plan,
            journal,
            completed=True,
        )
        journal = _replace_journal(journal, location, normalized_plan)
        _require_workspace_binding(root_fd, root)
        _release_owner(journal, location)
        _require_workspace_binding(root_fd, root)
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
                if planned["kind"] in ("create", "update", "remove")
                else None
            ),
            "before": planned["before"],
            "after": planned["after"],
            "artifact_source_digest": planned["artifact_source_digest"],
            "equivalence_receipt_ref": planned["equivalence_receipt_ref"],
        })
    root_node = _lstat_directory(root, "workspace-unsafe")
    root_flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    root_fd = os.open(root, root_flags)
    try:
        opened_root = os.fstat(root_fd)
        if (
            (opened_root.st_dev, opened_root.st_ino)
            != (root_node.st_dev, root_node.st_ino)
            or opened_root.st_uid != os.getuid()
        ):
            raise JournalError("workspace-unsafe", str(root))
        _require_effect_temps_absent(
            root_fd,
            root,
            effects,
            code="operation-temp-stale",
        )
    finally:
        os.close(root_fd)
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
    normalized_journal = validate_journal(journal, normalized_plan)
    _require_lifecycle_journal_size(
        normalized_journal, normalized_plan
    )
    return normalized_journal
