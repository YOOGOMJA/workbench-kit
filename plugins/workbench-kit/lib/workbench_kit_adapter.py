"""Read-only adapter for the public workbench kernel contracts."""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import pathlib
import re
import resource
import shutil
import stat
import subprocess
import sys
import unicodedata
from collections.abc import Callable, Sequence
from typing import Any

from workbench_kit_json import (
    DuplicateJsonMember,
    InvalidJsonConstant,
    strict_json_loads,
)


REQUIRED_CAPABILITIES = {
    "workspace.schema/v1",
    "workspace.doctor/v1",
    "workspace.legacy-inventory/v1",
}
BOOTSTRAP_CAPABILITY = "workspace.legacy-inventory-bootstrap/v1"
ENGINE_MANIFEST_CAPABILITY = "engine.manifest/v1"
LEGACY_INVENTORY_CONTRACT = "workbench-legacy-inventory/v1"
BOOTSTRAP_APPROVAL_CONTRACT = "workbench-bootstrap-authority-approval/v1"
ENGINE_MANIFEST_CONTRACT = "workbench-plugin-manifest/v1"
GIT_OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
SEMVER = re.compile(
    r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
    r"(?:-(?:(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")
HOME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DEFAULT_REF = re.compile(r"^refs/heads/[A-Za-z0-9._/-]+$")
GITHUB_ORIGIN = re.compile(
    r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$"
)
INVENTORY_FIELDS = (
    "contract_version", "source_revision", "authority", "home_set", "homes",
    "active_claims", "origin_replacements", "complete", "blockers",
)
AUTHORITY_FIELDS = (
    "authority_identity", "default_ref", "default_revision", "descriptor_digest",
    "bootstrap_revision",
)
HOME_SET_FIELDS = ("contract_version", "digest", "source_revision")
HOME_FIELDS = ("home", "origin_url", "membership", "pagination", "claims")
PAGINATION_FIELDS = ("complete", "pages_fetched", "end_cursor", "failure")
FAILURE_FIELDS = ("code", "ref", "cursor")
CLAIM_FIELDS = (
    "claim_id", "task_claim_id", "task_contract", "issue", "home", "parent",
    "branch", "lifecycle_digest", "lifecycle_state", "classification",
    "submission", "source_revision", "pr_head_revision", "ancestry_complete", "repos",
)
SUBMISSION_FIELDS = ("pull_request", "head_revision", "current")
REPO_FIELDS = ("owner", "branch", "role")
ACTIVE_CLAIM_FIELDS = (
    "source", "claim_id", "operation_id", "task_claim_id", "owner", "branch",
    "context_policy_set_digest", "source_revision", "pr_head_revision", "lifecycle_digest",
)
REPLACEMENT_FIELDS = (
    "home", "previous_origin_url", "current_origin_url", "status",
)
BLOCKER_FIELDS = ("code", "ref")
DOCTOR_FIELDS = ("contract_version", "ready", "writer_coordination")
COORDINATION_FIELDS = (
    "authority_identity", "origin_url", "default_ref", "default_ref_revision",
    "default_ref_protected", "descriptor_digest", "ref", "revision", "readable",
    "legacy_inventory_readable", "push_permission", "permission_source", "push_ready",
    "blocker",
)
COORDINATION_REF = "refs/heads/workbench-coordination/writer-claims"
ENGINE_MANIFEST_FIELDS = (
    "contract_version", "plugin", "source", "included_paths", "excluded_paths", "nodes",
    "digest",
)
PLUGIN_FIELDS = ("name", "version")
SOURCE_FIELDS = ("ref", "revision")
EXCLUSION_FIELDS = ("path", "match")
MANIFEST_NODE_FIELDS = ("path", "node_type", "mode", "digest", "link_target")
ENGINE_SOURCE_REF = "https://github.com/YOOGOMJA/workbench-kit#plugins/workbench"
ENGINE_EXCLUSIONS = [
    {"path": ".DS_Store", "match": "exact"},
    {"path": ".git/", "match": "prefix"},
    {"path": "lib/__pycache__/", "match": "prefix"},
]
RESERVED_MANIFEST_PREFIXES = {"." + name for name in ("git", "worktrees", "codebases")}
RESERVED_MANIFEST_PAIR = ("task", "codebases")


class AdapterError(Exception):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


def canonical_public_digest(value: Any) -> str:
    """Hash extensible public observations independent of JSON member order."""
    raw = (
        json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def source_digest(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def valid_default_ref(value: str) -> bool:
    return (
        DEFAULT_REF.fullmatch(value) is not None
        and ".." not in value
        and "//" not in value
    )


def require_origin(value: str, authority_identity: str, ref: str) -> None:
    if authority_identity.startswith("github:") and GITHUB_ORIGIN.fullmatch(value) is None:
        raise AdapterError("public-contract-invalid", ref)


def require_object(value: Any, ref: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AdapterError("public-contract-invalid", ref)
    return value


def require_array(value: Any, ref: str) -> list[Any]:
    if not isinstance(value, list):
        raise AdapterError("public-contract-invalid", ref)
    return value


def inventory_error(ref: str) -> None:
    raise AdapterError("legacy-inventory-unavailable", ref)


def inventory_object(value: Any, fields: tuple[str, ...], ref: str) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != set(fields)
        or len(value) != len(fields)
    ):
        inventory_error(ref)
    return value


def exact_fields(value: Any, fields: tuple[str, ...]) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == set(fields)
        and len(value) == len(fields)
    )


def inventory_array(value: Any, ref: str) -> list[Any]:
    if not isinstance(value, list):
        inventory_error(ref)
    return value


def inventory_text(value: Any, ref: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or any(ord(char) < 32 or ord(char) == 127 for char in value)
    ):
        inventory_error(ref)
    return value


def inventory_home(value: Any, ref: str) -> str:
    result = inventory_text(value, ref)
    if HOME.fullmatch(result) is None or result.isdigit():
        inventory_error(ref)
    return result


def inventory_oid(value: Any, ref: str, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or GIT_OID.fullmatch(value) is None:
        inventory_error(ref)
    return value


def inventory_digest(value: Any, ref: str) -> str:
    if not isinstance(value, str) or SHA256.fullmatch(value) is None:
        inventory_error(ref)
    return value


def positive_integer(value: Any, ref: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        inventory_error(ref)
    return value


def pseudo_claim_id(task_claim_id: str, owner: str, branch: str) -> str:
    manifest = (
        "workbench-legacy-writer-identity/v1\n"
        f"task_claim_id\t{task_claim_id}\nowner\t{owner}\nbranch\t{branch}\n"
    )
    return "legacy-v1-" + hashlib.sha256(manifest.encode("utf-8")).hexdigest()


def resolve_workbench_binary() -> str:
    requested = os.environ.get("WORKBENCH_KIT_WORKBENCH_BIN", "workbench")
    if os.sep in requested:
        path = pathlib.Path(requested).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path.resolve())
        raise AdapterError("public-adapter-unavailable", requested)
    resolved = shutil.which(requested)
    if resolved is None:
        raise AdapterError("public-adapter-unavailable", requested)
    return resolved


def run_public_json(
    binary: str,
    argv: Sequence[str],
    workspace: pathlib.Path,
    allowed_exits: set[int],
) -> tuple[dict[str, Any], int, str]:
    ref = "workbench " + " ".join(argv)
    try:
        completed = subprocess.run(
            [binary, *argv],
            cwd=workspace,
            capture_output=True,
            check=False,
        )
    except OSError as error:
        raise AdapterError("public-adapter-unavailable", ref) from error
    if completed.stderr:
        raise AdapterError("public-adapter-stderr", ref)
    if completed.returncode not in allowed_exits:
        raise AdapterError("public-adapter-exit", ref)
    try:
        stdout = completed.stdout.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AdapterError("public-json-invalid", ref) from error
    if not stdout.endswith("\n"):
        raise AdapterError("public-json-invalid", ref)
    try:
        value = strict_json_loads(stdout)
    except (
        DuplicateJsonMember,
        InvalidJsonConstant,
        json.JSONDecodeError,
    ) as error:
        raise AdapterError("public-json-invalid", ref) from error
    return (
        require_object(value, ref),
        completed.returncode,
        source_digest(completed.stdout),
    )


def _git_read(
    workspace: pathlib.Path,
    argv: Sequence[str],
    allowed_exits: set[int] = {0},
) -> tuple[bytes, int]:
    environment = {**os.environ, "GIT_OPTIONAL_LOCKS": "0"}
    try:
        completed = subprocess.run(
            ["git", "-C", str(workspace), *argv],
            capture_output=True,
            check=False,
            env=environment,
        )
    except OSError as error:
        raise AdapterError("public-state-unavailable", "git " + " ".join(argv)) from error
    if completed.returncode not in allowed_exits:
        raise AdapterError("public-state-unavailable", "git " + " ".join(argv))
    return completed.stdout, completed.returncode


def _open_workspace_root(root: pathlib.Path) -> int:
    try:
        node = os.lstat(root)
        descriptor = os.open(
            root,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise AdapterError("public-state-unavailable", str(root)) from error
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(node.st_mode)
        or stat.S_ISLNK(node.st_mode)
        or not stat.S_ISDIR(opened.st_mode)
        or (node.st_dev, node.st_ino) != (opened.st_dev, opened.st_ino)
        or opened.st_uid != os.getuid()
    ):
        os.close(descriptor)
        raise AdapterError("public-state-unavailable", str(root))
    return descriptor


def _require_workspace_root(
    root: pathlib.Path, root_fd: int, *, restore: bool
) -> os.stat_result:
    code = "public-adapter-restore-failed" if restore else "public-state-unavailable"
    try:
        opened = os.fstat(root_fd)
        current = os.lstat(root)
    except OSError as error:
        raise AdapterError(code, str(root)) from error
    if (
        not stat.S_ISDIR(opened.st_mode)
        or not stat.S_ISDIR(current.st_mode)
        or stat.S_ISLNK(current.st_mode)
        or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)
        or opened.st_uid != os.getuid()
    ):
        raise AdapterError(code, str(root))
    return opened


def _worktree_manifest(
    root: pathlib.Path, root_fd: int
) -> dict[str, tuple[str, int, bytes | str | None]]:
    _require_workspace_root(root, root_fd, restore=False)
    manifest: dict[str, tuple[str, int, bytes | str | None]] = {}
    _manifest_visit(root_fd, pathlib.PurePosixPath(), manifest, skip_git=True)
    _require_workspace_root(root, root_fd, restore=False)
    return manifest


ABSENT_STATE = ("absent", None, None)


def _state_node(path: pathlib.Path) -> tuple[str, int | None, bytes | str | None]:
    try:
        node = os.lstat(path)
    except FileNotFoundError:
        return ABSENT_STATE
    except OSError as error:
        raise AdapterError("public-state-unavailable", str(path)) from error
    mode = stat.S_IMODE(node.st_mode)
    if stat.S_ISDIR(node.st_mode) and not stat.S_ISLNK(node.st_mode):
        return "directory", mode, None
    if stat.S_ISLNK(node.st_mode):
        try:
            target = os.readlink(path)
            verified = os.lstat(path)
        except OSError as error:
            raise AdapterError("public-state-unavailable", str(path)) from error
        if (
            not stat.S_ISLNK(verified.st_mode)
            or (node.st_dev, node.st_ino, node.st_mtime_ns)
            != (verified.st_dev, verified.st_ino, verified.st_mtime_ns)
        ):
            raise AdapterError("public-state-unavailable", str(path))
        return "symlink", mode, target
    if stat.S_ISREG(node.st_mode):
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except OSError as error:
            raise AdapterError("public-state-unavailable", str(path)) from error
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or (node.st_dev, node.st_ino) != (opened.st_dev, opened.st_ino)
                or stat.S_IMODE(opened.st_mode) != mode
                or opened.st_size != node.st_size
            ):
                raise AdapterError("public-state-unavailable", str(path))
            chunks = []
            remaining = opened.st_size
            while remaining:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk:
                    raise AdapterError("public-state-unavailable", str(path))
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise AdapterError("public-state-unavailable", str(path))
            verified = os.fstat(descriptor)
            if (
                opened.st_dev,
                opened.st_ino,
                opened.st_mode,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
            ) != (
                verified.st_dev,
                verified.st_ino,
                verified.st_mode,
                verified.st_size,
                verified.st_mtime_ns,
                verified.st_ctime_ns,
            ):
                raise AdapterError("public-state-unavailable", str(path))
            return "file", mode, b"".join(chunks)
        finally:
            os.close(descriptor)
    raise AdapterError("public-state-unavailable", str(path))


def _state_node_at(
    parent_fd: int,
    name: str,
    ref: str,
) -> tuple[str, int | None, bytes | str | None]:
    try:
        node = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return ABSENT_STATE
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    mode = stat.S_IMODE(node.st_mode)
    if stat.S_ISDIR(node.st_mode):
        return "directory", mode, None
    if stat.S_ISLNK(node.st_mode):
        try:
            target = os.readlink(name, dir_fd=parent_fd)
            verified = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except OSError as error:
            raise AdapterError("public-adapter-restore-failed", ref) from error
        if (
            not stat.S_ISLNK(verified.st_mode)
            or (node.st_dev, node.st_ino, node.st_mtime_ns)
            != (verified.st_dev, verified.st_ino, verified.st_mtime_ns)
        ):
            raise AdapterError("public-adapter-restore-failed", ref)
        return "symlink", mode, target
    if stat.S_ISREG(node.st_mode):
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(name, flags, dir_fd=parent_fd)
        except OSError as error:
            raise AdapterError("public-adapter-restore-failed", ref) from error
        try:
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISREG(opened.st_mode)
                or (node.st_dev, node.st_ino) != (opened.st_dev, opened.st_ino)
                or opened.st_mode != node.st_mode
                or opened.st_size != node.st_size
            ):
                raise AdapterError("public-adapter-restore-failed", ref)
            chunks = []
            remaining = opened.st_size
            while remaining:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk:
                    raise AdapterError("public-adapter-restore-failed", ref)
                chunks.append(chunk)
                remaining -= len(chunk)
            if os.read(descriptor, 1):
                raise AdapterError("public-adapter-restore-failed", ref)
            verified = os.fstat(descriptor)
            if (
                opened.st_dev,
                opened.st_ino,
                opened.st_mode,
                opened.st_size,
                opened.st_mtime_ns,
                opened.st_ctime_ns,
            ) != (
                verified.st_dev,
                verified.st_ino,
                verified.st_mode,
                verified.st_size,
                verified.st_mtime_ns,
                verified.st_ctime_ns,
            ):
                raise AdapterError("public-adapter-restore-failed", ref)
            return "file", mode, b"".join(chunks)
        finally:
            os.close(descriptor)
    raise AdapterError("public-adapter-restore-failed", ref)


def _manifest_node_at(
    parent_fd: int,
    name: str,
    ref: str,
) -> tuple[str, int | None, bytes | str | None]:
    try:
        image = _state_node_at(parent_fd, name, ref)
    except AdapterError as error:
        raise AdapterError("public-state-unavailable", ref) from error
    if image[0] == "absent":
        raise AdapterError("public-state-unavailable", ref)
    return image


def _manifest_visit(
    directory_fd: int,
    prefix: pathlib.PurePosixPath,
    manifest: dict[str, tuple[str, int | None, bytes | str | None]],
    *,
    skip_git: bool = False,
    stop_directory: str | None = None,
) -> None:
    try:
        names = sorted(os.listdir(directory_fd))
    except OSError as error:
        raise AdapterError("public-state-unavailable", prefix.as_posix()) from error
    for name in names:
        if not prefix.parts and skip_git and name == ".git":
            continue
        relative_path = prefix / name
        relative = relative_path.as_posix()
        image = _manifest_node_at(directory_fd, name, relative)
        manifest[relative] = image
        if image[0] != "directory" or relative == stop_directory:
            continue
        try:
            node = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            child_fd = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_fd,
            )
            opened = os.fstat(child_fd)
        except OSError as error:
            raise AdapterError("public-state-unavailable", relative) from error
        try:
            if (
                not stat.S_ISDIR(opened.st_mode)
                or (node.st_dev, node.st_ino)
                != (opened.st_dev, opened.st_ino)
                or stat.S_IMODE(opened.st_mode) != image[1]
            ):
                raise AdapterError("public-state-unavailable", relative)
            _manifest_visit(
                child_fd,
                relative_path,
                manifest,
                stop_directory=stop_directory,
            )
        finally:
            os.close(child_fd)


def _open_relative_parent(root_fd: int, relative: str, ref: str) -> tuple[int, str]:
    path = pathlib.PurePosixPath(relative)
    if path.is_absolute() or not path.parts or any(
        part in ("", ".", "..") for part in path.parts
    ):
        raise AdapterError("public-adapter-restore-failed", ref)
    descriptor = os.dup(root_fd)
    try:
        for part in path.parts[:-1]:
            child = os.open(
                part,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = child
    except OSError as error:
        os.close(descriptor)
        raise AdapterError("public-adapter-restore-failed", ref) from error
    return descriptor, path.parts[-1]


def _remove_state_node_at(
    parent_fd: int,
    name: str,
    expected: tuple[str, int | None, bytes | str | None],
    ref: str,
    quarantine: dict[str, Any],
) -> None:
    try:
        observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    if _state_node_at(parent_fd, name, ref) != expected:
        raise AdapterError("public-adapter-restore-failed", ref)
    try:
        verified = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    if (
        observed.st_dev,
        observed.st_ino,
        observed.st_mode,
        observed.st_size,
        observed.st_mtime_ns,
        observed.st_ctime_ns,
    ) != (
        verified.st_dev,
        verified.st_ino,
        verified.st_mode,
        verified.st_size,
        verified.st_mtime_ns,
        verified.st_ctime_ns,
    ):
        raise AdapterError("public-adapter-restore-failed", ref)
    handle = _open_state_handle_at(parent_fd, name, expected[0], ref)
    try:
        quarantine_fd, entry_name = _open_quarantine_entry(
            quarantine, observed.st_dev, ref
        )
    except BaseException:
        os.close(handle)
        raise
    moved = False
    try:
        try:
            opened = os.fstat(handle)
            if (opened.st_dev, opened.st_ino) != (
                observed.st_dev,
                observed.st_ino,
            ):
                raise AdapterError("public-adapter-restore-failed", ref)
            _rename_noreplace(parent_fd, name, quarantine_fd, "node", ref)
            moved = True
            _fsync_quarantine_transition(
                quarantine, quarantine_fd, parent_fd, ref
            )
            _mark_quarantine_residue(
                quarantine, quarantine_fd, entry_name, ref
            )
            quarantined = os.stat(
                "node", dir_fd=quarantine_fd, follow_symlinks=False
            )
            if (quarantined.st_dev, quarantined.st_ino) != (
                opened.st_dev,
                opened.st_ino,
            ):
                raise AdapterError("public-adapter-restore-failed", ref)
        except OSError as error:
            raise AdapterError("public-adapter-restore-failed", ref) from error
    finally:
        try:
            os.close(handle)
        finally:
            _close_quarantine_entry(
                quarantine,
                quarantine_fd,
                entry_name,
                preserve=moved,
                ref=ref,
            )


def _open_state_handle_at(
    parent_fd: int,
    name: str,
    kind: str,
    ref: str,
) -> int:
    if kind == "directory":
        flags = (
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
    elif kind == "file":
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    elif hasattr(os, "O_SYMLINK"):
        flags = os.O_RDONLY | os.O_SYMLINK
    elif sys.platform == "darwin":
        flags = os.O_RDONLY | 0x00200000
    elif hasattr(os, "O_PATH"):
        flags = os.O_PATH | getattr(os, "O_NOFOLLOW", 0)
    else:
        raise AdapterError("public-adapter-restore-failed", ref)
    try:
        return os.open(name, flags, dir_fd=parent_fd)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error


def _new_external_quarantine(
    workspace: pathlib.Path, workspace_fd: int
) -> dict[str, Any]:
    parent_path = workspace.parent
    parent_fd = None
    try:
        parent_node = os.lstat(parent_path)
        parent_fd = os.open(
            parent_path,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        parent_opened = os.fstat(parent_fd)
        workspace_node = os.stat(
            workspace.name, dir_fd=parent_fd, follow_symlinks=False
        )
        workspace_opened = os.fstat(workspace_fd)
    except OSError as error:
        if parent_fd is not None:
            os.close(parent_fd)
        raise AdapterError(
            "public-adapter-restore-failed", str(parent_path)
        ) from error
    if (
        not workspace.name
        or not stat.S_ISDIR(parent_node.st_mode)
        or stat.S_ISLNK(parent_node.st_mode)
        or not stat.S_ISDIR(parent_opened.st_mode)
        or (parent_node.st_dev, parent_node.st_ino)
        != (parent_opened.st_dev, parent_opened.st_ino)
        or parent_opened.st_uid != os.getuid()
        or parent_opened.st_mode & 0o022
        or (workspace_node.st_dev, workspace_node.st_ino)
        != (workspace_opened.st_dev, workspace_opened.st_ino)
    ):
        os.close(parent_fd)
        raise AdapterError(
            "public-adapter-restore-failed", str(parent_path)
        )
    return {
        "workspace": str(workspace),
        "workspace_fd": workspace_fd,
        "workspace_name": workspace.name,
        "workspace_binding": (workspace_opened.st_dev, workspace_opened.st_ino),
        "parent_path": str(parent_path),
        "parent_fd": parent_fd,
        "parent_binding": (parent_opened.st_dev, parent_opened.st_ino),
        "device": parent_opened.st_dev,
        "root_name": None,
        "root_fd": None,
        "root_binding": None,
        "residues": {},
    }


def _external_quarantine_ref(quarantine: dict[str, Any]) -> str:
    root_name = quarantine["root_name"]
    if root_name is None:
        return quarantine["parent_path"]
    return str(pathlib.Path(quarantine["parent_path"]) / root_name)


def _fsync_directory(descriptor: int, ref: str) -> None:
    try:
        os.fsync(descriptor)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error


def _fsync_quarantine_transition(
    quarantine: dict[str, Any],
    entry_fd: int,
    source_or_target_fd: int,
    ref: str,
) -> None:
    for descriptor in (
        source_or_target_fd,
        entry_fd,
        quarantine["root_fd"],
        quarantine["parent_fd"],
    ):
        _fsync_directory(descriptor, ref)


def _require_external_quarantine(
    quarantine: dict[str, Any], ref: str
) -> None:
    try:
        parent = os.fstat(quarantine["parent_fd"])
        parent_path = os.lstat(quarantine["parent_path"])
        workspace = os.stat(
            quarantine["workspace_name"],
            dir_fd=quarantine["parent_fd"],
            follow_symlinks=False,
        )
        workspace_opened = os.fstat(quarantine["workspace_fd"])
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    if (
        (parent.st_dev, parent.st_ino) != quarantine["parent_binding"]
        or (parent_path.st_dev, parent_path.st_ino) != quarantine["parent_binding"]
        or parent.st_uid != os.getuid()
        or parent.st_mode & 0o022
        or (workspace.st_dev, workspace.st_ino)
        != quarantine["workspace_binding"]
        or (workspace_opened.st_dev, workspace_opened.st_ino)
        != quarantine["workspace_binding"]
    ):
        raise AdapterError("public-adapter-restore-failed", ref)
    if quarantine["root_fd"] is None:
        return
    try:
        root = os.fstat(quarantine["root_fd"])
        root_path = os.stat(
            quarantine["root_name"],
            dir_fd=quarantine["parent_fd"],
            follow_symlinks=False,
        )
    except OSError as error:
        raise AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        ) from error
    if (
        not stat.S_ISDIR(root.st_mode)
        or (root.st_dev, root.st_ino) != quarantine["root_binding"]
        or (root_path.st_dev, root_path.st_ino) != quarantine["root_binding"]
        or root.st_uid != os.getuid()
        or stat.S_IMODE(root.st_mode) != 0o700
    ):
        raise AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        )


def _require_quarantine_device(
    quarantine: dict[str, Any], target_device: int, ref: str
) -> None:
    _require_external_quarantine(quarantine, ref)
    if quarantine["device"] != target_device:
        raise AdapterError("public-adapter-restore-failed", ref)


def _ensure_quarantine_root(
    quarantine: dict[str, Any], ref: str
) -> None:
    if quarantine["root_fd"] is not None:
        _require_external_quarantine(quarantine, ref)
        return
    prefix = f".workbench-kit-quarantine-{os.getpid()}-"
    for _ in range(1024):
        name = prefix + os.urandom(16).hex()
        try:
            os.mkdir(name, mode=0o700, dir_fd=quarantine["parent_fd"])
        except FileExistsError:
            continue
        except OSError as error:
            raise AdapterError("public-adapter-restore-failed", ref) from error
        descriptor = None
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=quarantine["parent_fd"],
            )
            os.fchmod(descriptor, 0o700)
            node = os.stat(
                name,
                dir_fd=quarantine["parent_fd"],
                follow_symlinks=False,
            )
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISDIR(opened.st_mode)
                or (node.st_dev, node.st_ino) != (opened.st_dev, opened.st_ino)
                or opened.st_dev != quarantine["device"]
                or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) != 0o700
            ):
                raise AdapterError("public-adapter-restore-failed", ref)
            quarantine["root_name"] = name
            quarantine["root_fd"] = descriptor
            quarantine["root_binding"] = (opened.st_dev, opened.st_ino)
            _require_external_quarantine(quarantine, ref)
            _fsync_directory(descriptor, ref)
            _fsync_directory(quarantine["parent_fd"], ref)
            return
        except BaseException:
            if descriptor is not None:
                os.close(descriptor)
            quarantine["root_name"] = name
            quarantine["root_fd"] = None
            quarantine["root_binding"] = None
            raise
    raise AdapterError("public-adapter-restore-failed", ref)


def _open_quarantine_entry(
    quarantine: dict[str, Any], target_device: int, ref: str
) -> tuple[int, str]:
    _require_quarantine_device(quarantine, target_device, ref)
    _ensure_quarantine_root(quarantine, ref)
    for _ in range(1024):
        name = "entry-" + os.urandom(16).hex()
        try:
            os.mkdir(name, mode=0o700, dir_fd=quarantine["root_fd"])
        except FileExistsError:
            continue
        except OSError as error:
            raise AdapterError("public-adapter-restore-failed", ref) from error
        descriptor = None
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=quarantine["root_fd"],
            )
            os.fchmod(descriptor, 0o700)
            node = os.stat(
                name,
                dir_fd=quarantine["root_fd"],
                follow_symlinks=False,
            )
            opened = os.fstat(descriptor)
            if (
                not stat.S_ISDIR(opened.st_mode)
                or (node.st_dev, node.st_ino) != (opened.st_dev, opened.st_ino)
                or opened.st_dev != target_device
                or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) != 0o700
            ):
                raise AdapterError("public-adapter-restore-failed", ref)
            _fsync_directory(descriptor, ref)
            _fsync_directory(quarantine["root_fd"], ref)
            _fsync_directory(quarantine["parent_fd"], ref)
            return descriptor, name
        except BaseException:
            if descriptor is not None:
                os.close(descriptor)
            raise
    raise AdapterError("public-adapter-restore-failed", ref)


def _quarantine_entry_snapshot(
    quarantine: dict[str, Any],
    entry_fd: int,
    entry_name: str,
    ref: str,
    *,
    require_node: bool,
) -> dict[str, Any]:
    _require_external_quarantine(quarantine, ref)
    try:
        opened = os.fstat(entry_fd)
        current = os.stat(
            entry_name,
            dir_fd=quarantine["root_fd"],
            follow_symlinks=False,
        )
    except OSError as error:
        raise AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        ) from error
    binding = (opened.st_dev, opened.st_ino)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or (current.st_dev, current.st_ino) != binding
        or opened.st_uid != os.getuid()
        or stat.S_IMODE(opened.st_mode) != 0o700
    ):
        raise AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        )
    manifest: dict[str, tuple[str, int | None, bytes | str | None]] = {}
    try:
        _manifest_visit(entry_fd, pathlib.PurePosixPath(), manifest)
        node = os.stat("node", dir_fd=entry_fd, follow_symlinks=False)
        node_binding = (node.st_dev, node.st_ino)
    except FileNotFoundError:
        node_binding = None
    except (AdapterError, OSError) as error:
        raise AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        ) from error
    if require_node and (
        node_binding is None
        or not manifest
        or any(
            path != "node" and not path.startswith("node/")
            for path in manifest
        )
    ):
        raise AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        )
    return {
        "entry_binding": binding,
        "node_binding": node_binding,
        "manifest": manifest,
    }


def _mark_quarantine_residue(
    quarantine: dict[str, Any],
    entry_fd: int,
    entry_name: str,
    ref: str,
) -> None:
    snapshot = _quarantine_entry_snapshot(
        quarantine,
        entry_fd,
        entry_name,
        ref,
        require_node=True,
    )
    expected = quarantine["residues"].get(entry_name)
    if expected is not None and snapshot != expected:
        raise AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        )
    quarantine["residues"][entry_name] = snapshot
    _fsync_directory(entry_fd, _external_quarantine_ref(quarantine))
    _fsync_directory(
        quarantine["root_fd"], _external_quarantine_ref(quarantine)
    )
    _fsync_directory(
        quarantine["parent_fd"], _external_quarantine_ref(quarantine)
    )


def _close_quarantine_entry(
    quarantine: dict[str, Any],
    entry_fd: int,
    entry_name: str,
    *,
    preserve: bool,
    ref: str,
) -> None:
    failure: BaseException | None = None
    try:
        if preserve:
            _mark_quarantine_residue(
                quarantine, entry_fd, entry_name, ref
            )
        else:
            snapshot = _quarantine_entry_snapshot(
                quarantine,
                entry_fd,
                entry_name,
                ref,
                require_node=False,
            )
            if snapshot["node_binding"] is not None or snapshot["manifest"]:
                raise AdapterError(
                    "public-adapter-restore-failed",
                    _external_quarantine_ref(quarantine),
                )
            quarantine["residues"][entry_name] = snapshot
            _fsync_directory(entry_fd, ref)
            _fsync_directory(quarantine["root_fd"], ref)
            _fsync_directory(quarantine["parent_fd"], ref)
    except BaseException as error:
        failure = error
    try:
        os.close(entry_fd)
    except OSError as error:
        if failure is None:
            failure = AdapterError(
                "public-adapter-restore-failed",
                _external_quarantine_ref(quarantine),
            )
            failure.__cause__ = error
    if failure is not None:
        raise failure


def _close_external_quarantine(quarantine: dict[str, Any]) -> None:
    failure = None
    root_fd = quarantine["root_fd"]
    if root_fd is not None:
        try:
            _require_external_quarantine(
                quarantine, _external_quarantine_ref(quarantine)
            )
            names = set(os.listdir(root_fd))
            if names != set(quarantine["residues"]):
                raise AdapterError(
                    "public-adapter-restore-failed",
                    _external_quarantine_ref(quarantine),
                )
            for name, expected in quarantine["residues"].items():
                entry_fd = os.open(
                    name,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=root_fd,
                )
                try:
                    observed = _quarantine_entry_snapshot(
                        quarantine,
                        entry_fd,
                        name,
                        _external_quarantine_ref(quarantine),
                        require_node=expected["node_binding"] is not None,
                    )
                    if observed != expected:
                        raise AdapterError(
                            "public-adapter-restore-failed",
                            _external_quarantine_ref(quarantine),
                        )
                finally:
                    os.close(entry_fd)
            _fsync_directory(
                root_fd, _external_quarantine_ref(quarantine)
            )
            _fsync_directory(
                quarantine["parent_fd"],
                _external_quarantine_ref(quarantine),
            )
        except BaseException as error:
            failure = error
        try:
            os.close(root_fd)
        except OSError as error:
            if failure is None:
                failure = AdapterError(
                    "public-adapter-restore-failed",
                    _external_quarantine_ref(quarantine),
                )
                failure.__cause__ = error
        quarantine["root_fd"] = None
        if failure is None:
            failure = AdapterError(
                "public-adapter-restore-failed",
                _external_quarantine_ref(quarantine),
            )
    elif quarantine["root_name"] is not None:
        failure = AdapterError(
            "public-adapter-restore-failed",
            _external_quarantine_ref(quarantine),
        )
    try:
        os.close(quarantine["parent_fd"])
    except OSError as error:
        if failure is None:
            failure = AdapterError(
                "public-adapter-restore-failed",
                _external_quarantine_ref(quarantine),
            )
            failure.__cause__ = error
    if failure is not None:
        raise failure


def _rename_noreplace(
    source_fd: int,
    source: str,
    destination_fd: int,
    destination: str,
    ref: str,
) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    source_raw = os.fsencode(source)
    destination_raw = os.fsencode(destination)
    if sys.platform == "darwin":
        rename = getattr(library, "renameatx_np", None)
        flag = 0x00000004
    elif sys.platform.startswith("linux"):
        rename = getattr(library, "renameat2", None)
        flag = 0x00000001
    else:
        rename = None
        flag = 0
    if rename is None:
        raise AdapterError("public-adapter-restore-failed", ref)
    rename.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    rename.restype = ctypes.c_int
    if rename(
        source_fd,
        source_raw,
        destination_fd,
        destination_raw,
        flag,
    ) != 0:
        error = OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
        raise AdapterError("public-adapter-restore-failed", ref) from error


def _create_state_node_at(
    parent_fd: int,
    name: str,
    image: tuple[str, int | None, bytes | str | None],
    ref: str,
    quarantine: dict[str, Any],
) -> None:
    if _state_node_at(parent_fd, name, ref) != ABSENT_STATE:
        raise AdapterError("public-adapter-restore-failed", ref)
    kind, mode, payload = image
    if kind == "directory":
        try:
            os.mkdir(name, mode=mode, dir_fd=parent_fd)
        except OSError as error:
            raise AdapterError("public-adapter-restore-failed", ref) from error
        return
    try:
        parent = os.fstat(parent_fd)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    quarantine_fd, entry_name = _open_quarantine_entry(
        quarantine, parent.st_dev, ref
    )
    staged = False
    installed = False
    try:
        if kind == "file":
            flags = (
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0)
            )
            descriptor = os.open("node", flags, mode, dir_fd=quarantine_fd)
            staged = True
            try:
                view = memoryview(payload)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise OSError("short state restore write")
                    view = view[written:]
                os.fchmod(descriptor, mode)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        elif kind == "symlink":
            os.symlink(payload, "node", dir_fd=quarantine_fd)
            staged = True
        else:
            raise AdapterError("public-adapter-restore-failed", ref)
        if _state_node_at(parent_fd, name, ref) != ABSENT_STATE:
            raise AdapterError("public-adapter-restore-failed", ref)
        _rename_noreplace(quarantine_fd, "node", parent_fd, name, ref)
        installed = True
        _fsync_quarantine_transition(
            quarantine, quarantine_fd, parent_fd, ref
        )
    except AdapterError:
        raise
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    finally:
        _close_quarantine_entry(
            quarantine,
            quarantine_fd,
            entry_name,
            preserve=staged and not installed,
            ref=ref,
        )


def _chmod_directory_at(
    parent_fd: int,
    name: str,
    expected: tuple[str, int | None, bytes | str | None],
    mode: int,
    ref: str,
) -> None:
    try:
        observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    if _state_node_at(parent_fd, name, ref) != expected:
        raise AdapterError("public-adapter-restore-failed", ref)
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(opened.st_mode)
            or (opened.st_dev, opened.st_ino, opened.st_mode)
            != (observed.st_dev, observed.st_ino, observed.st_mode)
        ):
            raise AdapterError("public-adapter-restore-failed", ref)
        os.fchmod(descriptor, mode)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", ref) from error
    finally:
        os.close(descriptor)


def _require_nofollow_directory(path: pathlib.Path) -> os.stat_result:
    if not path.is_absolute():
        raise AdapterError("public-state-unavailable", str(path))
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            node = os.lstat(current)
        except OSError as error:
            raise AdapterError("public-state-unavailable", str(path)) from error
        if not stat.S_ISDIR(node.st_mode) or stat.S_ISLNK(node.st_mode):
            raise AdapterError("public-state-unavailable", str(path))
    return node


def _require_nofollow_ancestors(path: pathlib.Path) -> None:
    if not path.is_absolute():
        raise AdapterError("public-state-unavailable", str(path))
    current = pathlib.Path(path.anchor)
    for part in path.parts[1:-1]:
        current /= part
        try:
            node = os.lstat(current)
        except OSError as error:
            raise AdapterError("public-state-unavailable", str(path)) from error
        if not stat.S_ISDIR(node.st_mode) or stat.S_ISLNK(node.st_mode):
            raise AdapterError("public-state-unavailable", str(path))


def _binding_path(base: pathlib.Path, raw: str) -> pathlib.Path:
    candidate = pathlib.Path(raw)
    if not candidate.is_absolute():
        candidate = base / candidate
    return pathlib.Path(os.path.abspath(candidate))


def _decode_pointer(image: tuple[str, int | None, bytes | str | None], ref: str) -> str:
    if image[0] != "file" or not isinstance(image[2], bytes):
        raise AdapterError("public-state-unavailable", ref)
    try:
        value = image[2].decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AdapterError("public-state-unavailable", ref) from error
    if not value.endswith("\n") or value.count("\n") != 1:
        raise AdapterError("public-state-unavailable", ref)
    return value[:-1]


def _raw_git_binding(
    workspace: pathlib.Path, *, strict: bool
) -> dict[str, Any]:
    pointer_path = workspace / ".git"
    pointer = _state_node(pointer_path)
    try:
        if pointer[0] == "directory":
            git_dir = pointer_path
        else:
            line = _decode_pointer(pointer, str(pointer_path))
            if not line.startswith("gitdir: ") or not line[8:]:
                raise AdapterError("public-state-unavailable", str(pointer_path))
            git_dir = _binding_path(workspace, line[8:])
        git_node = _require_nofollow_directory(git_dir)
        commondir_image = _state_node(git_dir / "commondir")
        if commondir_image[0] == "absent":
            common_dir = git_dir
        else:
            raw_common = _decode_pointer(
                commondir_image, str(git_dir / "commondir")
            )
            if not raw_common:
                raise AdapterError(
                    "public-state-unavailable", str(git_dir / "commondir")
                )
            common_dir = _binding_path(git_dir, raw_common)
        common_node = _require_nofollow_directory(common_dir)
        object_dir = common_dir / "objects"
        object_node = _require_nofollow_directory(object_dir)
        return {
            "status": "valid",
            "git_dir": str(git_dir),
            "git_binding": (git_node.st_dev, git_node.st_ino),
            "common_dir": str(common_dir),
            "common_binding": (common_node.st_dev, common_node.st_ino),
            "object_dir": str(object_dir),
            "object_binding": (object_node.st_dev, object_node.st_ino),
        }
    except AdapterError as error:
        if strict:
            raise
        return {"status": "invalid", "ref": error.ref}


def _discovered_git_binding(workspace: pathlib.Path) -> dict[str, Any]:
    binding = _raw_git_binding(workspace, strict=True)
    commands = (
        (("rev-parse", "--absolute-git-dir"), "git_dir"),
        (("rev-parse", "--path-format=absolute", "--git-common-dir"), "common_dir"),
        (("rev-parse", "--path-format=absolute", "--git-path", "objects"), "object_dir"),
    )
    for argv, field in commands:
        raw, _ = _git_read(workspace, argv)
        try:
            reported = raw.decode("utf-8", errors="strict").strip()
        except UnicodeDecodeError as error:
            raise AdapterError("public-state-unavailable", field) from error
        if pathlib.Path(os.path.abspath(reported)) != pathlib.Path(binding[field]):
            raise AdapterError("public-state-unavailable", field)
    return binding


def _admin_specs(binding: dict[str, Any]) -> list[dict[str, Any]]:
    roots = sorted(
        {
            pathlib.Path(binding["git_dir"]),
            pathlib.Path(binding["common_dir"]),
        },
        key=lambda path: (len(path.parts), str(path)),
    )
    minimal = [
        root
        for root in roots
        if not any(parent == root or parent in root.parents for parent in roots if parent != root)
    ]
    object_dir = pathlib.Path(binding["object_dir"])
    if not any(root == object_dir or root in object_dir.parents for root in minimal):
        minimal.append(object_dir)
    specs = []
    for root in sorted(minimal, key=str):
        node = _require_nofollow_directory(root)
        object_relative = None
        if root == object_dir:
            object_relative = "."
        elif root in object_dir.parents:
            object_relative = object_dir.relative_to(root).as_posix()
        specs.append({
            "path": str(root),
            "binding": (node.st_dev, node.st_ino),
            "object_relative": object_relative,
        })
    return specs


def _admin_manifest(
    root: pathlib.Path,
    object_relative: str | None,
    root_fd: int | None = None,
) -> dict[str, tuple[str, int | None, bytes | str | None]]:
    owned = root_fd is None
    if root_fd is None:
        try:
            node = os.lstat(root)
            root_fd = os.open(
                root,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            opened = os.fstat(root_fd)
        except OSError as error:
            raise AdapterError("public-state-unavailable", str(root)) from error
        if (
            not stat.S_ISDIR(node.st_mode)
            or (node.st_dev, node.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            os.close(root_fd)
            raise AdapterError("public-state-unavailable", str(root))
    try:
        opened = os.fstat(root_fd)
        manifest = {
            ".": ("directory", stat.S_IMODE(opened.st_mode), None)
        }
        if object_relative != ".":
            _manifest_visit(
                root_fd,
                pathlib.PurePosixPath(),
                manifest,
                stop_directory=object_relative,
            )
        return manifest
    finally:
        if owned:
            os.close(root_fd)


def _capture_caller_state(
    workspace: pathlib.Path,
    root_fd: int,
    git_specs: list[dict[str, Any]] | None = None,
    expected_git_binding: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root_node = _require_workspace_root(workspace, root_fd, restore=False)
    binding = (
        _discovered_git_binding(workspace)
        if git_specs is None
        else _raw_git_binding(workspace, strict=False)
    )
    specs = _admin_specs(binding) if git_specs is None else git_specs
    known_binding = expected_git_binding or binding
    git_nodes = {}
    if known_binding.get("status") == "valid":
        for field in ("git_dir", "common_dir", "object_dir"):
            path = pathlib.Path(known_binding[field])
            _require_nofollow_ancestors(path)
            image = _state_node(path)
            node_binding = None
            if image[0] == "directory":
                node = os.lstat(path)
                node_binding = (node.st_dev, node.st_ino)
            git_nodes[field] = {
                "path": str(path),
                "binding": node_binding,
                "image": image,
            }
    admin = []
    for spec in specs:
        root = pathlib.Path(spec["path"])
        _require_nofollow_ancestors(root)
        image = _state_node(root)
        root_binding = None
        if image[0] == "directory":
            node = os.lstat(root)
            root_binding = (node.st_dev, node.st_ino)
        admin.append({
            "path": spec["path"],
            "binding": root_binding,
            "object_relative": spec["object_relative"],
            "manifest": _admin_manifest(root, spec["object_relative"]),
        })
    result = {
        "root_mode": stat.S_IMODE(root_node.st_mode),
        "worktree": _worktree_manifest(workspace, root_fd),
        "git_pointer": _state_node(workspace / ".git"),
        "git_binding": binding,
        "git_nodes": git_nodes,
        "git_specs": specs,
        "git_admin": admin,
    }
    _require_workspace_root(workspace, root_fd, restore=False)
    return result


def _directory_access_group(
    root_fd: int,
    root_path: pathlib.Path,
    manifest: dict[str, tuple[str, int | None, bytes | str | None]],
    root_mode: int,
    ref: str,
) -> dict[str, Any]:
    descriptors: dict[str, int] = {".": os.dup(root_fd)}
    records = []
    try:
        root_node = os.fstat(descriptors["."])
        records.append({
            "relative": ".",
            "path": str(root_path),
            "fd": descriptors["."],
            "parent_fd": None,
            "name": None,
            "binding": (root_node.st_dev, root_node.st_ino),
            "mode": root_mode,
            "uid": root_node.st_uid,
            "gid": root_node.st_gid,
        })
        directories = sorted(
            (
                relative
                for relative, image in manifest.items()
                if relative != "." and image[0] == "directory"
            ),
            key=lambda value: (value.count("/"), value),
        )
        for relative in directories:
            pure = pathlib.PurePosixPath(relative)
            parent = pure.parent.as_posix()
            if parent == ".":
                parent = "."
            parent_fd = descriptors[parent]
            name = pure.name
            node = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_fd,
            )
            descriptors[relative] = descriptor
            opened = os.fstat(descriptor)
            expected_mode = manifest[relative][1]
            if (
                not stat.S_ISDIR(node.st_mode)
                or (node.st_dev, node.st_ino)
                != (opened.st_dev, opened.st_ino)
                or stat.S_IMODE(opened.st_mode) != expected_mode
            ):
                raise AdapterError("public-state-unavailable", ref)
            records.append({
                "relative": relative,
                "path": str(root_path / pathlib.PurePosixPath(relative)),
                "fd": descriptor,
                "parent_fd": parent_fd,
                "name": name,
                "binding": (opened.st_dev, opened.st_ino),
                "mode": expected_mode,
                "uid": opened.st_uid,
                "gid": opened.st_gid,
            })
        return {"root": str(root_path), "records": records}
    except BaseException as error:
        for descriptor in descriptors.values():
            os.close(descriptor)
        if isinstance(error, AdapterError):
            raise
        if isinstance(error, OSError):
            raise AdapterError("public-state-unavailable", ref) from error
        raise


def _capture_directory_access(
    workspace: pathlib.Path,
    root_fd: int,
    state: dict[str, Any],
) -> list[dict[str, Any]]:
    groups = []
    try:
        groups.append(_directory_access_group(
            root_fd,
            workspace,
            state["worktree"],
            state["root_mode"],
            str(workspace),
        ))
        for admin in state["git_admin"]:
            root = pathlib.Path(admin["path"])
            descriptor = os.open(
                root,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                opened = os.fstat(descriptor)
                if admin["binding"] != (opened.st_dev, opened.st_ino):
                    raise AdapterError("public-state-unavailable", str(root))
                groups.append(_directory_access_group(
                    descriptor,
                    root,
                    admin["manifest"],
                    admin["manifest"]["."][1],
                    str(root),
                ))
            finally:
                os.close(descriptor)
        return groups
    except BaseException as error:
        _close_directory_access(groups)
        if isinstance(error, AdapterError):
            raise
        if isinstance(error, OSError):
            raise AdapterError(
                "public-state-unavailable", str(workspace)
            ) from error
        raise


def _preflight_quarantine_devices(
    quarantine: dict[str, Any], groups: list[dict[str, Any]]
) -> None:
    _require_external_quarantine(
        quarantine, quarantine["workspace"]
    )
    for group in groups:
        for record in group["records"]:
            try:
                device = os.fstat(record["fd"]).st_dev
            except OSError as error:
                raise AdapterError(
                    "public-adapter-restore-failed", record["path"]
                ) from error
            if device != quarantine["device"]:
                raise AdapterError(
                    "public-adapter-restore-failed", record["path"]
                )


def _raise_access_descriptor_limit(
    state: dict[str, Any],
) -> tuple[int, int] | None:
    required = 1 + sum(
        image[0] == "directory" for image in state["worktree"].values()
    )
    required += sum(
        1 + sum(
            relative != "." and image[0] == "directory"
            for relative, image in admin["manifest"].items()
        )
        for admin in state["git_admin"]
    )
    previous = resource.getrlimit(resource.RLIMIT_NOFILE)
    soft, hard = previous
    if soft == resource.RLIM_INFINITY:
        return None
    target = soft + required + 32
    if hard != resource.RLIM_INFINITY:
        target = min(target, hard)
    if target < soft + required:
        raise AdapterError("public-state-unavailable", "RLIMIT_NOFILE")
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except (OSError, ValueError) as error:
        raise AdapterError(
            "public-state-unavailable", "RLIMIT_NOFILE"
        ) from error
    return previous


def _restore_access_descriptor_limit(previous: tuple[int, int] | None) -> None:
    if previous is None:
        return
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, previous)
    except (OSError, ValueError) as error:
        raise AdapterError(
            "public-state-unavailable", "RLIMIT_NOFILE"
        ) from error


def _directory_readable(node: os.stat_result) -> bool:
    if os.geteuid() == 0:
        return True
    mode = stat.S_IMODE(node.st_mode)
    if node.st_uid == os.geteuid():
        required = 0o500
    elif node.st_gid == os.getegid() or node.st_gid in os.getgroups():
        required = 0o050
    else:
        required = 0o005
    return mode & required == required


def _restore_directory_access(
    workspace: pathlib.Path,
    root_fd: int,
    groups: list[dict[str, Any]],
) -> bool:
    repaired = False
    _require_workspace_root(workspace, root_fd, restore=True)
    for group in groups:
        detached: list[str] = []
        for record in group["records"]:
            relative = record["relative"]
            if any(
                relative.startswith(prefix + "/")
                for prefix in detached
            ):
                continue
            root_record = record["parent_fd"] is None
            try:
                if root_record:
                    current = os.lstat(record["path"])
                else:
                    current = os.stat(
                        record["name"],
                        dir_fd=record["parent_fd"],
                        follow_symlinks=False,
                    )
            except FileNotFoundError as error:
                if not root_record:
                    detached.append(relative)
                    continue
                raise AdapterError(
                    "public-adapter-restore-failed", record["path"]
                ) from error
            except OSError as error:
                raise AdapterError(
                    "public-adapter-restore-failed", record["path"]
                ) from error
            if (
                not stat.S_ISDIR(current.st_mode)
                or (current.st_dev, current.st_ino) != record["binding"]
            ):
                if not root_record:
                    detached.append(relative)
                    continue
                raise AdapterError(
                    "public-adapter-restore-failed", record["path"]
                )
            try:
                opened = os.fstat(record["fd"])
            except OSError as error:
                raise AdapterError(
                    "public-adapter-restore-failed", record["path"]
                ) from error
            if (
                not stat.S_ISDIR(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != record["binding"]
            ):
                raise AdapterError(
                    "public-adapter-restore-failed", record["path"]
                )
            if not _directory_readable(current):
                try:
                    os.fchmod(record["fd"], record["mode"])
                    verified = os.fstat(record["fd"])
                except OSError as error:
                    raise AdapterError(
                        "public-adapter-restore-failed", record["path"]
                    ) from error
                if (
                    (verified.st_dev, verified.st_ino) != record["binding"]
                    or stat.S_IMODE(verified.st_mode) != record["mode"]
                ):
                    raise AdapterError(
                        "public-adapter-restore-failed", record["path"]
                    )
                repaired = True
            _require_workspace_root(workspace, root_fd, restore=True)
    return repaired


def _close_directory_access(groups: list[dict[str, Any]]) -> None:
    failure = None
    for group in reversed(groups):
        for record in reversed(group["records"]):
            try:
                os.close(record["fd"])
            except OSError as error:
                if failure is None:
                    failure = error
    if failure is not None:
        raise AdapterError(
            "public-state-unavailable", "directory-access-fd"
        ) from failure


def _require_worktree_cas(
    workspace: pathlib.Path,
    root_fd: int,
    expected_manifest: dict[str, tuple[str, int, bytes | str | None]],
    expected_root_mode: int,
) -> None:
    try:
        opened = _require_workspace_root(workspace, root_fd, restore=True)
        if stat.S_IMODE(opened.st_mode) != expected_root_mode:
            raise AdapterError("public-adapter-restore-failed", str(workspace))
        if _worktree_manifest(workspace, root_fd) != expected_manifest:
            raise AdapterError("public-adapter-restore-failed", str(workspace))
        _require_workspace_root(workspace, root_fd, restore=True)
    except AdapterError as error:
        if error.code == "public-adapter-restore-failed":
            raise
        raise AdapterError(
            "public-adapter-restore-failed", str(workspace)
        ) from error


def _worktree_parent(
    workspace: pathlib.Path,
    root_fd: int,
    relative: str,
) -> tuple[int, str]:
    _require_workspace_root(workspace, root_fd, restore=True)
    return _open_relative_parent(root_fd, relative, relative)


def _drop_manifest_subtree(
    manifest: dict[str, tuple[str, int | None, bytes | str | None]],
    relative: str,
) -> None:
    prefix = relative + "/"
    for path in list(manifest):
        if path == relative or path.startswith(prefix):
            manifest.pop(path)


def _restore_worktree(
    workspace: pathlib.Path,
    state: dict[str, Any],
    after: dict[str, Any],
    root_fd: int,
    quarantine: dict[str, Any],
) -> dict[str, tuple[str, int | None, bytes | str | None]]:
    before_manifest = state["worktree"]
    expected = dict(after["worktree"])
    expected_root_mode = after["root_mode"]
    removal_candidates = [
        relative
        for relative, image in expected.items()
        if relative not in before_manifest
        or before_manifest[relative][0] != image[0]
    ]
    removal_set = set(removal_candidates)
    removals = [
        relative
        for relative in removal_candidates
        if not any(
            pathlib.PurePosixPath(*pathlib.PurePosixPath(relative).parts[:depth]).as_posix()
            in removal_set
            for depth in range(1, len(pathlib.PurePosixPath(relative).parts))
        )
    ]
    directories = [
        relative
        for relative, image in before_manifest.items()
        if image[0] == "directory"
        and expected.get(relative, ABSENT_STATE)[0] != "directory"
    ]
    leaves = [
        relative
        for relative, image in before_manifest.items()
        if image[0] in ("file", "symlink")
        and expected.get(relative, ABSENT_STATE) != image
    ]
    mutation_targets = set(removals + directories + leaves)
    access_directories = {
        pathlib.PurePosixPath(*pathlib.PurePosixPath(relative).parts[:depth]).as_posix()
        for relative in mutation_targets
        for depth in range(1, len(pathlib.PurePosixPath(relative).parts))
    }

    if mutation_targets and expected_root_mode & 0o700 != 0o700:
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )
        try:
            os.fchmod(root_fd, expected_root_mode | 0o700)
        except OSError as error:
            raise AdapterError(
                "public-adapter-restore-failed", str(workspace)
            ) from error
        expected_root_mode |= 0o700
        _require_workspace_root(workspace, root_fd, restore=True)
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )

    for relative in sorted(
        access_directories, key=lambda value: (value.count("/"), value)
    ):
        image = expected.get(relative, ABSENT_STATE)
        if image[0] != "directory" or image[1] & 0o700 == 0o700:
            continue
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )
        parent_fd, name = _worktree_parent(workspace, root_fd, relative)
        try:
            _chmod_directory_at(
                parent_fd, name, image, image[1] | 0o700, relative
            )
        finally:
            os.close(parent_fd)
        expected[relative] = ("directory", image[1] | 0o700, None)
        _require_workspace_root(workspace, root_fd, restore=True)
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )

    for relative in sorted(
        removals, key=lambda value: (value.count("/"), value), reverse=True
    ):
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )
        parent_fd, name = _worktree_parent(workspace, root_fd, relative)
        try:
            _remove_state_node_at(
                parent_fd, name, expected[relative], relative, quarantine
            )
        finally:
            os.close(parent_fd)
        _drop_manifest_subtree(expected, relative)
        _require_workspace_root(workspace, root_fd, restore=True)
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )

    for relative in sorted(
        directories, key=lambda value: (value.count("/"), value)
    ):
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )
        parent_fd, name = _worktree_parent(workspace, root_fd, relative)
        try:
            _create_state_node_at(
                parent_fd,
                name,
                before_manifest[relative],
                relative,
                quarantine,
            )
        finally:
            os.close(parent_fd)
        expected[relative] = before_manifest[relative]
        _require_workspace_root(workspace, root_fd, restore=True)
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )

    for relative in sorted(leaves):
        current = expected.get(relative, ABSENT_STATE)
        if current[0] != "absent":
            _require_worktree_cas(
                workspace, root_fd, expected, expected_root_mode
            )
            parent_fd, name = _worktree_parent(workspace, root_fd, relative)
            try:
                _remove_state_node_at(
                    parent_fd, name, current, relative, quarantine
                )
            finally:
                os.close(parent_fd)
            _drop_manifest_subtree(expected, relative)
            _require_workspace_root(workspace, root_fd, restore=True)
            _require_worktree_cas(
                workspace, root_fd, expected, expected_root_mode
            )
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )
        parent_fd, name = _worktree_parent(workspace, root_fd, relative)
        try:
            _create_state_node_at(
                parent_fd,
                name,
                before_manifest[relative],
                relative,
                quarantine,
            )
        finally:
            os.close(parent_fd)
        expected[relative] = before_manifest[relative]
        _require_workspace_root(workspace, root_fd, restore=True)
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )

    directory_modes = [
        relative
        for relative, image in before_manifest.items()
        if image[0] == "directory" and expected.get(relative) != image
    ]
    for relative in sorted(
        directory_modes,
        key=lambda value: (value.count("/"), value),
        reverse=True,
    ):
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )
        parent_fd, name = _worktree_parent(workspace, root_fd, relative)
        try:
            _chmod_directory_at(
                parent_fd,
                name,
                expected[relative],
                before_manifest[relative][1],
                relative,
            )
        finally:
            os.close(parent_fd)
        expected[relative] = before_manifest[relative]
        _require_workspace_root(workspace, root_fd, restore=True)
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )

    if expected_root_mode != state["root_mode"]:
        _require_worktree_cas(
            workspace, root_fd, expected, expected_root_mode
        )
        try:
            os.fchmod(root_fd, state["root_mode"])
        except OSError as error:
            raise AdapterError(
                "public-adapter-restore-failed", str(workspace)
            ) from error
        expected_root_mode = state["root_mode"]
        _require_workspace_root(workspace, root_fd, restore=True)
    _require_worktree_cas(
        workspace, root_fd, before_manifest, state["root_mode"]
    )
    return before_manifest


def _path_for_manifest(root: pathlib.Path, relative: str) -> pathlib.Path:
    if relative == ".":
        return root
    return root.joinpath(*pathlib.PurePosixPath(relative).parts)


def _require_admin_cas(
    workspace: pathlib.Path,
    workspace_fd: int,
    root: pathlib.Path,
    root_fd: int,
    binding: tuple[int, int],
    object_relative: str | None,
    expected: dict[str, tuple[str, int | None, bytes | str | None]],
) -> None:
    _require_workspace_root(workspace, workspace_fd, restore=True)
    try:
        opened = os.fstat(root_fd)
        current = os.lstat(root)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", str(root)) from error
    if (
        not stat.S_ISDIR(opened.st_mode)
        or not stat.S_ISDIR(current.st_mode)
        or stat.S_ISLNK(current.st_mode)
        or (opened.st_dev, opened.st_ino) != binding
        or (current.st_dev, current.st_ino) != binding
    ):
        raise AdapterError("public-adapter-restore-failed", str(root))
    try:
        observed = _admin_manifest(root, object_relative, root_fd)
    except AdapterError as error:
        raise AdapterError(
            "public-adapter-restore-failed", str(root)
        ) from error
    if observed != expected:
        raise AdapterError("public-adapter-restore-failed", str(root))
    _require_workspace_root(workspace, workspace_fd, restore=True)
    try:
        verified = os.fstat(root_fd)
        current = os.lstat(root)
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", str(root)) from error
    if (
        (verified.st_dev, verified.st_ino) != binding
        or (current.st_dev, current.st_ino) != binding
    ):
        raise AdapterError("public-adapter-restore-failed", str(root))


def _restore_admin_manifest(
    workspace: pathlib.Path,
    workspace_fd: int,
    root: pathlib.Path,
    binding: tuple[int, int],
    object_relative: str | None,
    before: dict[str, tuple[str, int | None, bytes | str | None]],
    after: dict[str, tuple[str, int | None, bytes | str | None]],
    quarantine: dict[str, Any],
) -> dict[str, tuple[str, int | None, bytes | str | None]]:
    try:
        root_fd = os.open(
            root,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise AdapterError("public-adapter-restore-failed", str(root)) from error
    try:
        return _restore_admin_manifest_open(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            before,
            after,
            quarantine,
        )
    finally:
        os.close(root_fd)


def _restore_admin_manifest_open(
    workspace: pathlib.Path,
    workspace_fd: int,
    root: pathlib.Path,
    root_fd: int,
    binding: tuple[int, int],
    object_relative: str | None,
    before: dict[str, tuple[str, int | None, bytes | str | None]],
    after: dict[str, tuple[str, int | None, bytes | str | None]],
    quarantine: dict[str, Any],
) -> dict[str, tuple[str, int | None, bytes | str | None]]:
    expected = dict(after)
    if before.get(".", ABSENT_STATE)[0] != after.get(".", ABSENT_STATE)[0]:
        raise AdapterError("public-adapter-restore-failed", str(root))

    removal_candidates = [
        relative
        for relative, image in after.items()
        if relative != "."
        and (
            relative not in before
            or before[relative][0] != image[0]
        )
    ]
    removal_set = set(removal_candidates)
    removals = [
        relative
        for relative in removal_candidates
        if not any(
            pathlib.PurePosixPath(*pathlib.PurePosixPath(relative).parts[:depth]).as_posix()
            in removal_set
            for depth in range(1, len(pathlib.PurePosixPath(relative).parts))
        )
    ]
    directories = [
        relative
        for relative, image in before.items()
        if relative != "."
        and image[0] == "directory"
        and expected.get(relative, ABSENT_STATE)[0] != "directory"
    ]
    leaves = [
        relative
        for relative, image in before.items()
        if relative != "."
        and image[0] in ("file", "symlink")
        and expected.get(relative, ABSENT_STATE) != image
    ]
    mutation_targets = set(removals + directories + leaves)
    access_directories = {
        pathlib.PurePosixPath(*pathlib.PurePosixPath(relative).parts[:depth]).as_posix()
        for relative in mutation_targets
        for depth in range(1, len(pathlib.PurePosixPath(relative).parts))
    }
    root_image = expected["."]
    if mutation_targets and root_image[1] & 0o700 != 0o700:
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )
        try:
            os.fchmod(root_fd, root_image[1] | 0o700)
        except OSError as error:
            raise AdapterError(
                "public-adapter-restore-failed", str(root)
            ) from error
        expected["."] = ("directory", root_image[1] | 0o700, None)
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )

    for relative in sorted(
        access_directories, key=lambda value: (value.count("/"), value)
    ):
        image = expected.get(relative, ABSENT_STATE)
        if image[0] != "directory" or image[1] & 0o700 == 0o700:
            continue
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )
        parent_fd, name = _open_relative_parent(root_fd, relative, str(root / relative))
        try:
            _chmod_directory_at(
                parent_fd, name, image, image[1] | 0o700, str(root / relative)
            )
        finally:
            os.close(parent_fd)
        expected[relative] = ("directory", image[1] | 0o700, None)
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )

    for relative in sorted(
        removals, key=lambda value: (value.count("/"), value), reverse=True
    ):
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )
        path = _path_for_manifest(root, relative)
        parent_fd, name = _open_relative_parent(root_fd, relative, str(path))
        try:
            _remove_state_node_at(
                parent_fd,
                name,
                expected[relative],
                str(path),
                quarantine,
            )
        finally:
            os.close(parent_fd)
        _drop_manifest_subtree(expected, relative)
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )

    for relative in sorted(
        directories, key=lambda value: (value.count("/"), value)
    ):
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )
        path = _path_for_manifest(root, relative)
        parent_fd, name = _open_relative_parent(root_fd, relative, str(path))
        try:
            _create_state_node_at(
                parent_fd,
                name,
                before[relative],
                str(path),
                quarantine,
            )
        finally:
            os.close(parent_fd)
        expected[relative] = before[relative]
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )

    for relative in sorted(leaves):
        path = _path_for_manifest(root, relative)
        current = expected.get(relative, ABSENT_STATE)
        if current[0] != "absent":
            _require_admin_cas(
                workspace,
                workspace_fd,
                root,
                root_fd,
                binding,
                object_relative,
                expected,
            )
            parent_fd, name = _open_relative_parent(root_fd, relative, str(path))
            try:
                _remove_state_node_at(
                    parent_fd,
                    name,
                    current,
                    str(path),
                    quarantine,
                )
            finally:
                os.close(parent_fd)
            _drop_manifest_subtree(expected, relative)
            _require_admin_cas(
                workspace,
                workspace_fd,
                root,
                root_fd,
                binding,
                object_relative,
                expected,
            )
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )
        parent_fd, name = _open_relative_parent(root_fd, relative, str(path))
        try:
            _create_state_node_at(
                parent_fd,
                name,
                before[relative],
                str(path),
                quarantine,
            )
        finally:
            os.close(parent_fd)
        expected[relative] = before[relative]
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )

    directory_modes = [
        relative
        for relative, image in before.items()
        if image[0] == "directory" and expected.get(relative) != image
    ]
    for relative in sorted(
        directory_modes,
        key=lambda value: (value.count("/"), value),
        reverse=True,
    ):
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )
        path = _path_for_manifest(root, relative)
        if relative == ".":
            try:
                opened = os.fstat(root_fd)
                if (
                    opened.st_dev,
                    opened.st_ino,
                    stat.S_IMODE(opened.st_mode),
                ) != (binding[0], binding[1], expected[relative][1]):
                    raise AdapterError(
                        "public-adapter-restore-failed", str(path)
                    )
                os.fchmod(root_fd, before[relative][1])
            except OSError as error:
                raise AdapterError(
                    "public-adapter-restore-failed", str(path)
                ) from error
        else:
            parent_fd, name = _open_relative_parent(root_fd, relative, str(path))
            try:
                _chmod_directory_at(
                    parent_fd,
                    name,
                    expected[relative],
                    before[relative][1],
                    str(path),
                )
            finally:
                os.close(parent_fd)
        expected[relative] = before[relative]
        _require_admin_cas(
            workspace,
            workspace_fd,
            root,
            root_fd,
            binding,
            object_relative,
            expected,
        )

    _require_admin_cas(
        workspace,
        workspace_fd,
        root,
        root_fd,
        binding,
        object_relative,
        before,
    )
    return before


def _restore_git_pointer(
    workspace: pathlib.Path,
    root_fd: int,
    before: tuple[str, int | None, bytes | str | None],
    after: tuple[str, int | None, bytes | str | None],
    quarantine: dict[str, Any],
) -> None:
    path = workspace / ".git"
    if before == after or before[0] == "directory":
        return
    _require_workspace_root(workspace, root_fd, restore=True)
    if _state_node_at(root_fd, ".git", str(path)) != after:
        raise AdapterError("public-adapter-restore-failed", str(path))
    if after[0] != "absent":
        _remove_state_node_at(
            root_fd, ".git", after, str(path), quarantine
        )
        _require_workspace_root(workspace, root_fd, restore=True)
        if _state_node_at(root_fd, ".git", str(path)) != ABSENT_STATE:
            raise AdapterError("public-adapter-restore-failed", str(path))
    if before[0] != "absent":
        if _state_node_at(root_fd, ".git", str(path)) != ABSENT_STATE:
            raise AdapterError("public-adapter-restore-failed", str(path))
        _create_state_node_at(
            root_fd, ".git", before, str(path), quarantine
        )
        _require_workspace_root(workspace, root_fd, restore=True)
        if _state_node_at(root_fd, ".git", str(path)) != before:
            raise AdapterError("public-adapter-restore-failed", str(path))


def _restore_caller_state(
    workspace: pathlib.Path,
    root_fd: int,
    state: dict[str, Any],
    after: dict[str, Any],
    quarantine: dict[str, Any],
) -> None:
    try:
        _require_workspace_root(workspace, root_fd, restore=True)
        current = _capture_caller_state(
            workspace, root_fd, state["git_specs"], state["git_binding"]
        )
        if current != after:
            raise AdapterError(
                "public-adapter-restore-failed", str(workspace)
            )
        expected_worktree = _restore_worktree(
            workspace, state, after, root_fd, quarantine
        )
        _restore_git_pointer(
            workspace,
            root_fd,
            state["git_pointer"],
            after["git_pointer"],
            quarantine,
        )
        _require_worktree_cas(
            workspace, root_fd, expected_worktree, state["root_mode"]
        )
        if state["git_nodes"] != after["git_nodes"]:
            raise AdapterError(
                "public-adapter-restore-failed", str(workspace)
            )
        before_admin = {item["path"]: item for item in state["git_admin"]}
        after_admin = {item["path"]: item for item in after["git_admin"]}
        expected_admin = []
        for path in sorted(before_admin):
            expected_binding = before_admin[path]["binding"]
            observed_binding = after_admin[path]["binding"]
            if expected_binding is None or expected_binding != observed_binding:
                raise AdapterError(
                    "public-adapter-restore-failed", path
                )
            root = pathlib.Path(path)
            _require_nofollow_directory(root)
            expected_manifest = _restore_admin_manifest(
                workspace,
                root_fd,
                root,
                expected_binding,
                before_admin[path]["object_relative"],
                before_admin[path]["manifest"],
                after_admin[path]["manifest"],
                quarantine,
            )
            expected_item = dict(before_admin[path])
            expected_item["manifest"] = expected_manifest
            expected_admin.append(expected_item)
        expected_state = dict(state)
        expected_state["worktree"] = expected_worktree
        expected_state["git_admin"] = expected_admin
        if _capture_caller_state(
            workspace, root_fd, state["git_specs"], state["git_binding"]
        ) != expected_state:
            raise AdapterError("public-adapter-restore-failed", str(workspace))
        if _raw_git_binding(workspace, strict=True) != state["git_binding"]:
            raise AdapterError("public-adapter-restore-failed", str(workspace))
        if quarantine["residues"]:
            _require_external_quarantine(
                quarantine, _external_quarantine_ref(quarantine)
            )
            raise AdapterError(
                "public-adapter-restore-failed",
                _external_quarantine_ref(quarantine),
            )
    except AdapterError as error:
        if quarantine["residues"]:
            raise AdapterError(
                "public-adapter-restore-failed",
                _external_quarantine_ref(quarantine),
            ) from error
        raise
    except (OSError, UnicodeError) as error:
        raise AdapterError("public-adapter-restore-failed", str(workspace)) from error


def _task_claim(document: dict[str, Any], branch: str) -> dict[str, Any]:
    ref = "workbench task status"
    if document.get("contract_version") != "workbench-task-status/v2":
        raise AdapterError("public-task-status-invalid", ref)
    tasks = require_array(document.get("tasks"), f"{ref}.tasks")
    blockers = require_array(
        document.get("writer_integrity_blockers"),
        f"{ref}.writer_integrity_blockers",
    )
    require_array(document.get("writer_conflicts"), f"{ref}.writer_conflicts")
    if blockers:
        raise AdapterError("public-task-status-invalid", f"{ref}.writer_integrity_blockers")
    required = (
        "task_id",
        "issue",
        "home",
        "parent",
        "claim_id",
        "task_contract",
        "branch",
        "workspace_authority_descriptor_digest",
        "context_ref",
        "work_ref",
        "work_owners",
    )
    task_rows = [
        (offset, require_object(value, f"{ref}.tasks[{offset}]"))
        for offset, value in enumerate(tasks)
    ]
    matches = [item for item in task_rows if item[1].get("branch") == branch]
    if len(matches) != 1:
        raise AdapterError("public-task-status-invalid", branch)
    offset, task = matches[0]
    if any(field not in task for field in required):
        raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}]")
    for field in ("task_id", "claim_id", "branch"):
        if (
            not isinstance(task[field], str)
            or not task[field]
            or any(ord(char) < 32 or ord(char) == 127 for char in task[field])
        ):
            raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].{field}")
    issue = task["issue"]
    home = task["home"]
    parent = task["parent"]
    if not isinstance(issue, int) or isinstance(issue, bool) or issue <= 0:
        raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].issue")
    if home is not None and (
        not isinstance(home, str) or HOME.fullmatch(home) is None or home.isdigit()
    ):
        raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].home")
    if parent is not None and (
        not isinstance(parent, int) or isinstance(parent, bool) or parent <= 0
    ):
        raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].parent")
    expected_task_id = str(issue) if home is None else f"{home}#{issue}"
    if task["task_id"] != expected_task_id:
        raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].task_id")
    if task["task_contract"] != "workbench-task/v2":
        raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].task_contract")
    if (
        not isinstance(task["workspace_authority_descriptor_digest"], str)
        or SHA256.fullmatch(task["workspace_authority_descriptor_digest"]) is None
    ):
        raise AdapterError(
            "public-task-status-invalid",
            f"{ref}.tasks[{offset}].workspace_authority_descriptor_digest",
        )
    for field in ("context_ref", "work_ref"):
        if task[field] is not None and (
            not isinstance(task[field], str)
            or not task[field]
            or any(ord(char) < 32 or ord(char) == 127 for char in task[field])
        ):
            raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].{field}")
    owners = require_array(task["work_owners"], f"{ref}.tasks[{offset}].work_owners")
    if (
        any(not isinstance(owner, str) or not owner for owner in owners)
        or owners != sorted(set(owners))
    ):
        raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].work_owners")
    return {field: task[field] for field in required}


def validate_contract(
    document: dict[str, Any],
    workspace: pathlib.Path,
    require_bootstrap: bool = False,
    require_engine_manifest: bool = False,
) -> str:
    ref = "workbench contract show"
    if document.get("contract_version") != "workbench-contract/v1":
        raise AdapterError("public-contract-invalid", ref)
    engine = require_object(document.get("engine"), f"{ref}.engine")
    if engine.get("name") != "workbench" or not isinstance(engine.get("version"), str):
        raise AdapterError("public-engine-mismatch", ref)
    if SEMVER.fullmatch(engine["version"]) is None:
        raise AdapterError("public-engine-mismatch", ref)
    workspace_contract = require_object(document.get("workspace"), f"{ref}.workspace")
    root = workspace_contract.get("root")
    if not isinstance(root, str) or pathlib.Path(root).resolve() != workspace:
        raise AdapterError("caller-root-mismatch", str(root))
    schema = workspace_contract.get("schema")
    if schema not in ("workbench/v1", "workbench/v2"):
        raise AdapterError("public-contract-invalid", f"{ref}.workspace.schema")
    supported = require_object(document.get("supported"), f"{ref}.supported")
    inventory_contracts = require_array(
        supported.get("legacy_inventory_contracts"),
        f"{ref}.supported.legacy_inventory_contracts",
    )
    if LEGACY_INVENTORY_CONTRACT not in inventory_contracts:
        raise AdapterError("public-contract-missing", LEGACY_INVENTORY_CONTRACT)
    capabilities = require_array(document.get("capabilities"), f"{ref}.capabilities")
    if not all(isinstance(item, str) for item in capabilities):
        raise AdapterError("public-contract-invalid", f"{ref}.capabilities")
    missing = sorted(REQUIRED_CAPABILITIES - set(capabilities))
    if missing:
        raise AdapterError("public-capability-missing", missing[0])
    if schema == "workbench/v1" or require_bootstrap:
        if "bootstrap_authority_approval_contracts" not in supported:
            raise AdapterError("public-contract-missing", BOOTSTRAP_APPROVAL_CONTRACT)
        approval_contracts = require_array(
            supported.get("bootstrap_authority_approval_contracts"),
            f"{ref}.supported.bootstrap_authority_approval_contracts",
        )
        if BOOTSTRAP_APPROVAL_CONTRACT not in approval_contracts:
            raise AdapterError("public-contract-missing", BOOTSTRAP_APPROVAL_CONTRACT)
        if BOOTSTRAP_CAPABILITY not in capabilities:
            raise AdapterError("public-capability-missing", BOOTSTRAP_CAPABILITY)
    if require_engine_manifest:
        if "engine_manifest_contracts" not in supported:
            raise AdapterError("public-contract-missing", ENGINE_MANIFEST_CONTRACT)
        manifest_contracts = require_array(
            supported["engine_manifest_contracts"],
            f"{ref}.supported.engine_manifest_contracts",
        )
        if ENGINE_MANIFEST_CONTRACT not in manifest_contracts:
            raise AdapterError("public-contract-missing", ENGINE_MANIFEST_CONTRACT)
        if ENGINE_MANIFEST_CAPABILITY not in capabilities:
            raise AdapterError("public-capability-missing", ENGINE_MANIFEST_CAPABILITY)
    return schema


def validate_doctor(document: dict[str, Any], status: int) -> None:
    ref = "workbench doctor"
    if not exact_fields(document, DOCTOR_FIELDS) or document.get(
        "contract_version"
    ) != "workbench-doctor/v1":
        raise AdapterError("public-contract-invalid", ref)
    ready = document.get("ready")
    if not isinstance(ready, bool) or (ready and status != 0) or (not ready and status != 1):
        raise AdapterError("public-contract-invalid", ref)
    coordination = require_object(
        document.get("writer_coordination"), f"{ref}.writer_coordination"
    )
    if not exact_fields(coordination, COORDINATION_FIELDS):
        raise AdapterError("public-contract-invalid", f"{ref}.writer_coordination")

    def optional_text(field: str) -> str | None:
        value = coordination[field]
        if value is not None and (
            not isinstance(value, str)
            or not value
            or any(ord(char) < 32 or ord(char) == 127 for char in value)
        ):
            raise AdapterError("public-contract-invalid", f"{ref}.{field}")
        return value

    for field in ("authority_identity", "origin_url", "default_ref", "permission_source"):
        optional_text(field)
    if coordination["default_ref"] is not None and not valid_default_ref(
        coordination["default_ref"]
    ):
        raise AdapterError("public-contract-invalid", f"{ref}.default_ref")
    if (
        coordination["authority_identity"] is not None
        and coordination["origin_url"] is not None
    ):
        require_origin(
            coordination["origin_url"],
            coordination["authority_identity"],
            f"{ref}.origin_url",
        )
    for field in ("default_ref_revision", "revision"):
        value = optional_text(field)
        if value is not None and GIT_OID.fullmatch(value) is None:
            raise AdapterError("public-contract-invalid", f"{ref}.{field}")
    descriptor_digest = optional_text("descriptor_digest")
    if descriptor_digest is not None and SHA256.fullmatch(descriptor_digest) is None:
        raise AdapterError("public-contract-invalid", f"{ref}.descriptor_digest")
    for field in (
        "default_ref_protected", "readable", "legacy_inventory_readable", "push_ready"
    ):
        if not isinstance(coordination[field], bool):
            raise AdapterError("public-contract-invalid", f"{ref}.{field}")
    if coordination["ref"] != COORDINATION_REF:
        raise AdapterError("public-contract-invalid", f"{ref}.ref")
    if coordination["push_permission"] not in ("allowed", "denied", "unknown"):
        raise AdapterError("public-contract-invalid", f"{ref}.push_permission")

    blocker = coordination["blocker"]
    if blocker is not None:
        if not exact_fields(blocker, BLOCKER_FIELDS):
            raise AdapterError("public-contract-invalid", f"{ref}.blocker")
        if blocker.get("code") != "writer-lock-unavailable" or blocker.get("ref") != COORDINATION_REF:
            raise AdapterError("public-contract-invalid", f"{ref}.blocker")
    computed_ready = all(
        (
            coordination["authority_identity"] is not None,
            coordination["origin_url"] is not None,
            coordination["default_ref"] is not None,
            coordination["default_ref_revision"] is not None,
            coordination["default_ref_protected"],
            coordination["descriptor_digest"] is not None,
            coordination["readable"],
            coordination["legacy_inventory_readable"],
            coordination["push_permission"] == "allowed",
            coordination["permission_source"] is not None,
            coordination["push_ready"],
        )
    )
    if ready != computed_ready or (ready and blocker is not None) or (not ready and blocker is None):
        raise AdapterError("public-contract-invalid", ref)


def validate_inventory(
    document: dict[str, Any], status: int, command: str
) -> list[dict[str, Any]]:
    ref = f"workbench legacy-inventory {command}"
    inventory_object(document, INVENTORY_FIELDS, ref)
    if document["contract_version"] != LEGACY_INVENTORY_CONTRACT:
        inventory_error(ref)
    source_revision = inventory_oid(document["source_revision"], f"{ref}.source_revision")

    authority = inventory_object(document["authority"], AUTHORITY_FIELDS, f"{ref}.authority")
    authority_identity = inventory_text(
        authority["authority_identity"], f"{ref}.authority_identity"
    )
    default_ref = inventory_text(authority["default_ref"], f"{ref}.default_ref")
    if not valid_default_ref(default_ref):
        inventory_error(f"{ref}.default_ref")
    if inventory_oid(authority["default_revision"], f"{ref}.default_revision") != source_revision:
        inventory_error(f"{ref}.default_revision")
    inventory_digest(authority["descriptor_digest"], f"{ref}.descriptor_digest")
    inventory_oid(authority["bootstrap_revision"], f"{ref}.bootstrap_revision")

    home_set = inventory_object(document["home_set"], HOME_SET_FIELDS, f"{ref}.home_set")
    if home_set["contract_version"] != "workbench-legacy-home-set/v1":
        inventory_error(f"{ref}.home_set.contract_version")
    inventory_digest(home_set["digest"], f"{ref}.home_set.digest")
    if inventory_oid(home_set["source_revision"], f"{ref}.home_set.source_revision") != source_revision:
        inventory_error(f"{ref}.home_set.source_revision")

    tasks: list[dict[str, Any]] = []
    projected_writers: list[dict[str, Any]] = []
    homes = inventory_array(document["homes"], f"{ref}.homes")
    home_names: list[str] = []
    identities: set[tuple[str, str]] = set()
    pagination_complete = True
    for home_value in homes:
        home = inventory_object(home_value, HOME_FIELDS, f"{ref}.homes[]")
        home_name = inventory_home(home["home"], f"{ref}.home")
        home_names.append(home_name)
        origin_url = inventory_text(home["origin_url"], f"{ref}.origin_url")
        require_origin(origin_url, authority_identity, f"{ref}.origin_url")
        if home["membership"] not in ("current", "removed", "origin-replaced"):
            inventory_error(f"{ref}.membership")

        pagination = inventory_object(
            home["pagination"], PAGINATION_FIELDS, f"{ref}.pagination"
        )
        if not isinstance(pagination["complete"], bool):
            inventory_error(f"{ref}.pagination.complete")
        pages = pagination["pages_fetched"]
        if not isinstance(pages, int) or isinstance(pages, bool) or pages < 0:
            inventory_error(f"{ref}.pagination.pages_fetched")
        if pagination["end_cursor"] is not None:
            inventory_text(pagination["end_cursor"], f"{ref}.pagination.end_cursor")
        failure = pagination["failure"]
        if failure is not None:
            failure = inventory_object(failure, FAILURE_FIELDS, f"{ref}.pagination.failure")
            inventory_text(failure["code"], f"{ref}.pagination.failure.code")
            inventory_text(failure["ref"], f"{ref}.pagination.failure.ref")
            if failure["cursor"] is not None:
                inventory_text(failure["cursor"], f"{ref}.pagination.failure.cursor")
        expected_complete = failure is None and pagination["end_cursor"] is None
        if pagination["complete"] != expected_complete:
            inventory_error(f"{ref}.pagination.complete")
        pagination_complete = pagination_complete and pagination["complete"]

        claims = inventory_array(home["claims"], f"{ref}.claims")
        claim_ids: list[str] = []
        for claim_value in claims:
            claim = inventory_object(claim_value, CLAIM_FIELDS, f"{ref}.claim")
            claim_id = inventory_text(claim["claim_id"], f"{ref}.claim_id")
            task_claim_id = inventory_text(
                claim["task_claim_id"], f"{ref}.task_claim_id"
            )
            if claim_id != task_claim_id:
                inventory_error(f"{ref}.claim_id")
            claim_ids.append(claim_id)
            identity = (home_name, claim_id)
            if identity in identities or claim["home"] != home_name:
                inventory_error(f"{ref}.claim.home")
            identities.add(identity)
            if claim["task_contract"] != "workbench-task/v1":
                inventory_error(f"{ref}.task_contract")
            positive_integer(claim["issue"], f"{ref}.issue")
            if claim["parent"] is not None:
                positive_integer(claim["parent"], f"{ref}.parent")
            inventory_text(claim["branch"], f"{ref}.branch")
            inventory_digest(claim["lifecycle_digest"], f"{ref}.lifecycle_digest")
            lifecycle_states = {
                "task-claimed", "task-active", "task-submitted", "task-verified",
                "task-completed", "task-abandoned", "task-cleaned",
            }
            if claim["lifecycle_state"] not in lifecycle_states:
                inventory_error(f"{ref}.lifecycle_state")
            expected_classification = (
                "cleaned-v1" if claim["lifecycle_state"] == "task-cleaned" else "active-v1"
            )
            if claim["classification"] != expected_classification:
                inventory_error(f"{ref}.classification")

            submission = claim["submission"]
            if submission is not None:
                submission = inventory_object(
                    submission, SUBMISSION_FIELDS, f"{ref}.submission"
                )
                positive_integer(submission["pull_request"], f"{ref}.pull_request")
                inventory_oid(submission["head_revision"], f"{ref}.submission.head_revision")
                if submission["current"] is not True:
                    inventory_error(f"{ref}.submission.current")
            source = inventory_oid(
                claim["source_revision"], f"{ref}.claim.source_revision", nullable=True
            )
            pr_head = inventory_oid(
                claim["pr_head_revision"], f"{ref}.pr_head_revision", nullable=True
            )
            if submission is None and pr_head is not None:
                inventory_error(f"{ref}.pr_head_revision")
            if submission is not None and submission["head_revision"] != pr_head:
                inventory_error(f"{ref}.submission.head_revision")
            if not isinstance(claim["ancestry_complete"], bool):
                inventory_error(f"{ref}.ancestry_complete")
            if claim["classification"] == "active-v1" and (
                source is None or claim["ancestry_complete"] is not True
            ):
                inventory_error(f"{ref}.ancestry_complete")

            repos = inventory_array(claim["repos"], f"{ref}.repos")
            repo_identities: list[tuple[str, str, str]] = []
            for repo_value in repos:
                repo = inventory_object(repo_value, REPO_FIELDS, f"{ref}.repo")
                owner = inventory_home(repo["owner"], f"{ref}.repo.owner")
                branch = inventory_text(repo["branch"], f"{ref}.repo.branch")
                if repo["role"] not in ("work", "reference"):
                    inventory_error(f"{ref}.repo.role")
                repo_identities.append((owner, branch, repo["role"]))
                if claim["classification"] == "active-v1" and repo["role"] == "work":
                    projected_writers.append(
                        {
                            "source": "legacy-v1",
                            "claim_id": pseudo_claim_id(task_claim_id, owner, branch),
                            "operation_id": None,
                            "task_claim_id": task_claim_id,
                            "owner": owner,
                            "branch": branch,
                            "context_policy_set_digest": None,
                            "source_revision": source,
                            "pr_head_revision": pr_head,
                            "lifecycle_digest": claim["lifecycle_digest"],
                        }
                    )
            if repo_identities != sorted(repo_identities) or len(repo_identities) != len(
                set(repo_identities)
            ):
                inventory_error(f"{ref}.repos")

            if claim["classification"] == "active-v1":
                tasks.append(
                    {
                        "source": "legacy-inventory:homes[].claims",
                        "home": home_name,
                        "claim_id": claim_id,
                        "task_claim_id": task_claim_id,
                        "task_contract": claim["task_contract"],
                        "issue": claim["issue"],
                        "parent": claim["parent"],
                        "branch": claim["branch"],
                        "lifecycle_state": claim["lifecycle_state"],
                        "lifecycle_digest": claim["lifecycle_digest"],
                        "source_revision": source,
                        "pr_head_revision": pr_head,
                        "ancestry_complete": claim["ancestry_complete"],
                    }
                )
        if claim_ids != sorted(claim_ids) or len(claim_ids) != len(set(claim_ids)):
            inventory_error(f"{ref}.claims")
    if home_names != sorted(home_names) or len(home_names) != len(set(home_names)):
        inventory_error(f"{ref}.homes")

    active_claims = inventory_array(document["active_claims"], f"{ref}.active_claims")
    for active_value in active_claims:
        active = inventory_object(active_value, ACTIVE_CLAIM_FIELDS, f"{ref}.active_claim")
        if active["source"] != "legacy-v1":
            inventory_error(f"{ref}.active_claim.source")
        inventory_text(active["claim_id"], f"{ref}.active_claim.claim_id")
        if active["operation_id"] is not None or active["context_policy_set_digest"] is not None:
            inventory_error(f"{ref}.active_claim")
        inventory_text(active["task_claim_id"], f"{ref}.active_claim.task_claim_id")
        inventory_home(active["owner"], f"{ref}.active_claim.owner")
        inventory_text(active["branch"], f"{ref}.active_claim.branch")
        inventory_oid(active["source_revision"], f"{ref}.active_claim.source_revision")
        inventory_oid(
            active["pr_head_revision"], f"{ref}.active_claim.pr_head_revision", nullable=True
        )
        inventory_digest(active["lifecycle_digest"], f"{ref}.active_claim.lifecycle_digest")
    active_order = [
        (item["source"], item["claim_id"], item["branch"]) for item in active_claims
    ]
    if active_order != sorted(active_order) or len(active_order) != len(
        {item["claim_id"] for item in active_claims}
    ):
        inventory_error(f"{ref}.active_claims")
    projected_writers.sort(key=lambda item: (item["source"], item["claim_id"], item["branch"]))
    if active_claims != projected_writers:
        inventory_error(f"{ref}.active_claims")

    replacements = inventory_array(
        document["origin_replacements"], f"{ref}.origin_replacements"
    )
    replacement_homes: list[str] = []
    replacement_available = True
    for replacement_value in replacements:
        replacement = inventory_object(
            replacement_value, REPLACEMENT_FIELDS, f"{ref}.origin_replacement"
        )
        replacement_homes.append(
            inventory_home(replacement["home"], f"{ref}.origin_replacement.home")
        )
        previous_origin = inventory_text(
            replacement["previous_origin_url"], f"{ref}.previous_origin_url"
        )
        require_origin(previous_origin, authority_identity, f"{ref}.previous_origin_url")
        if replacement["current_origin_url"] is not None:
            current_origin = inventory_text(
                replacement["current_origin_url"], f"{ref}.current_origin_url"
            )
            require_origin(current_origin, authority_identity, f"{ref}.current_origin_url")
        if replacement["status"] not in (
            "unchanged", "removed-clean", "removed-in-use", "replaced-clean",
            "replaced-in-use", "unavailable",
        ):
            inventory_error(f"{ref}.origin_replacement.status")
        replacement_available = replacement_available and replacement["status"] != "unavailable"
    if replacement_homes != sorted(replacement_homes) or len(replacement_homes) != len(
        set(replacement_homes)
    ):
        inventory_error(f"{ref}.origin_replacements")

    blockers = inventory_array(document["blockers"], f"{ref}.blockers")
    for blocker_value in blockers:
        blocker = inventory_object(blocker_value, BLOCKER_FIELDS, f"{ref}.blocker")
        inventory_text(blocker["code"], f"{ref}.blocker.code")
        inventory_text(blocker["ref"], f"{ref}.blocker.ref")
    blocker_order = [(item["code"], item["ref"]) for item in blockers]
    if blocker_order != sorted(blocker_order):
        inventory_error(f"{ref}.blockers")

    expected_complete = (
        not blockers and pagination_complete and replacement_available
    )
    if not isinstance(document["complete"], bool) or document["complete"] != expected_complete:
        inventory_error(f"{ref}.complete")
    if status != 0 or not document["complete"]:
        inventory_error(ref)
    return tasks


def validate_engine_manifest(document: dict[str, Any], engine_version: str) -> None:
    ref = "workbench engine-manifest show"
    if not exact_fields(document, ENGINE_MANIFEST_FIELDS):
        raise AdapterError("public-contract-invalid", ref)
    if document["contract_version"] != ENGINE_MANIFEST_CONTRACT:
        raise AdapterError("public-contract-invalid", f"{ref}.contract_version")
    plugin = require_object(document["plugin"], f"{ref}.plugin")
    if not exact_fields(plugin, PLUGIN_FIELDS) or plugin.get("name") != "workbench":
        raise AdapterError("public-contract-invalid", f"{ref}.plugin")
    if plugin.get("version") != engine_version or SEMVER.fullmatch(engine_version) is None:
        raise AdapterError("public-engine-mismatch", ref)
    source = require_object(document["source"], f"{ref}.source")
    if not exact_fields(source, SOURCE_FIELDS) or source.get("ref") != ENGINE_SOURCE_REF:
        raise AdapterError("public-contract-invalid", f"{ref}.source")
    if not isinstance(source.get("revision"), str) or SHA256.fullmatch(source["revision"]) is None:
        raise AdapterError("public-contract-invalid", f"{ref}.source.revision")
    if document["included_paths"] != ["."]:
        raise AdapterError("public-contract-invalid", f"{ref}.included_paths")
    exclusions = require_array(document["excluded_paths"], f"{ref}.excluded_paths")
    if exclusions != ENGINE_EXCLUSIONS or any(
        not exact_fields(item, EXCLUSION_FIELDS) for item in exclusions
    ):
        raise AdapterError("public-contract-invalid", f"{ref}.excluded_paths")

    nodes = require_array(document["nodes"], f"{ref}.nodes")
    node_paths: list[str] = []
    for node_value in nodes:
        node = require_object(node_value, f"{ref}.node")
        if not exact_fields(node, MANIFEST_NODE_FIELDS):
            raise AdapterError("public-contract-invalid", f"{ref}.node")
        path = node.get("path")
        if (
            not isinstance(path, str)
            or not path
            or "\x00" in path
            or "\\" in path
            or unicodedata.normalize("NFC", path) != path
        ):
            raise AdapterError("public-contract-invalid", f"{ref}.node.path")
        if path != ".":
            pure = pathlib.PurePosixPath(path)
            if pure.is_absolute() or pure.as_posix() != path or ".." in pure.parts:
                raise AdapterError("public-contract-invalid", f"{ref}.node.path")
            folded = tuple(part.casefold() for part in pure.parts)
            if (
                folded[0] in RESERVED_MANIFEST_PREFIXES
                or folded[:2] == RESERVED_MANIFEST_PAIR
            ):
                raise AdapterError("public-contract-invalid", f"{ref}.node.path")
        node_paths.append(path)
        node_type = node.get("node_type")
        mode = node.get("mode")
        link_target = node.get("link_target")
        if node_type == "file":
            valid_node = mode in ("100644", "100755") and link_target is None
        elif node_type == "directory":
            valid_node = (
                isinstance(mode, str)
                and re.fullmatch(r"04[0-7]{4}", mode) is not None
                and link_target is None
            )
        elif node_type == "symlink":
            valid_node = mode == "120000" and isinstance(link_target, str) and bool(link_target)
        else:
            valid_node = False
        if not valid_node:
            raise AdapterError("public-contract-invalid", f"{ref}.node")
        if not isinstance(node.get("digest"), str) or SHA256.fullmatch(node["digest"]) is None:
            raise AdapterError("public-contract-invalid", f"{ref}.node.digest")
    folded_paths = [path.casefold() for path in node_paths]
    if (
        node_paths != sorted(node_paths)
        or len(node_paths) != len(set(node_paths))
        or len(folded_paths) != len(set(folded_paths))
        or not nodes
    ):
        raise AdapterError("public-contract-invalid", f"{ref}.nodes")
    if not isinstance(document["digest"], str) or SHA256.fullmatch(document["digest"]) is None:
        raise AdapterError("public-contract-invalid", f"{ref}.digest")
    if nodes[0]["path"] != "." or nodes[0]["node_type"] != "directory":
        raise AdapterError("public-contract-invalid", f"{ref}.nodes")

    def canonical_line(value: Any) -> bytes:
        return (
            json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
        ).encode("utf-8")

    nodes_by_path = {node["path"]: node for node in nodes}
    children: dict[str, list[dict[str, Any]]] = {
        node["path"]: [] for node in nodes if node["node_type"] == "directory"
    }
    for node in nodes[1:]:
        parent = node["path"].rsplit("/", 1)[0] if "/" in node["path"] else "."
        if parent not in children:
            raise AdapterError("public-contract-invalid", f"{ref}.node.parent")
        children[parent].append(node)
    for directory_path, direct_children in children.items():
        rows = bytearray(b"workbench-plugin-directory/v1\n")
        for child in sorted(
            direct_children, key=lambda item: item["path"].rsplit("/", 1)[-1]
        ):
            rows.extend(
                canonical_line(
                    [
                        "child",
                        child["path"].rsplit("/", 1)[-1],
                        child["node_type"],
                        child["mode"],
                        child["digest"],
                        child["link_target"],
                    ]
                )
            )
        expected_directory_digest = source_digest(bytes(rows))
        if nodes_by_path[directory_path]["digest"] != expected_directory_digest:
            raise AdapterError(
                "public-contract-invalid", f"{ref}.node.directory_digest"
            )

    tree_bytes = bytearray(b"workbench-plugin-tree/v1\n")
    for path in document["included_paths"]:
        tree_bytes.extend(canonical_line(["included_path", path]))
    for exclusion in exclusions:
        tree_bytes.extend(
            canonical_line(["excluded_path", exclusion["path"], exclusion["match"]])
        )
    for node in nodes:
        tree_bytes.extend(
            canonical_line(
                [
                    "node",
                    node["path"],
                    node["node_type"],
                    node["mode"],
                    node["digest"],
                    node["link_target"],
                ]
            )
        )
    expected_revision = "sha256:" + hashlib.sha256(tree_bytes).hexdigest()
    if source["revision"] != expected_revision:
        raise AdapterError("public-contract-invalid", f"{ref}.source.revision")
    digest_input = {
        "contract_version": document["contract_version"],
        "plugin": {field: plugin[field] for field in PLUGIN_FIELDS},
        "source": {field: source[field] for field in SOURCE_FIELDS},
        "included_paths": document["included_paths"],
        "excluded_paths": [
            {field: item[field] for field in EXCLUSION_FIELDS} for item in exclusions
        ],
        "nodes": [
            {field: node[field] for field in MANIFEST_NODE_FIELDS} for node in nodes
        ],
        "digest": None,
    }
    digest_line = (
        json.dumps(
            digest_input,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")
    expected_digest = "sha256:" + hashlib.sha256(digest_line).hexdigest()
    if document["digest"] != expected_digest:
        raise AdapterError("public-contract-invalid", f"{ref}.digest")


def _inspect_public_kernel(
    workspace: pathlib.Path,
    authority_approval_file: pathlib.Path | None = None,
    inventory_mode: str | None = None,
    include_engine_manifest: bool = False,
    inventory_mode_resolver: Callable[[], str | None] | None = None,
) -> dict[str, Any]:
    workspace = workspace.resolve()
    if inventory_mode not in (
        None,
        "show",
        "bootstrap-show",
        "bootstrap-if-not-ready",
    ):
        raise AdapterError("public-inventory-mode-invalid", str(inventory_mode))
    binary = resolve_workbench_binary()
    contract, _, _ = run_public_json(
        binary, ("contract", "show", "--format", "json"), workspace, {0}
    )
    schema = validate_contract(
        contract,
        workspace,
        require_bootstrap=inventory_mode == "bootstrap-show",
        require_engine_manifest=include_engine_manifest,
    )
    doctor, doctor_status, doctor_source_digest = run_public_json(
        binary, ("doctor", "--format", "json"), workspace, {0, 1}
    )
    validate_doctor(doctor, doctor_status)
    resolved_inventory_mode = inventory_mode
    if schema == "workbench/v2" and doctor["ready"]:
        resolved_inventory_mode = "show"
    elif schema == "workbench/v2" and inventory_mode_resolver is not None:
        resolved_inventory_mode = inventory_mode_resolver()
        if resolved_inventory_mode not in (
            None,
            "show",
            "bootstrap-show",
            "bootstrap-if-not-ready",
        ):
            raise AdapterError(
                "public-inventory-mode-invalid", str(resolved_inventory_mode)
            )
    use_bootstrap = (
        schema == "workbench/v1"
        or resolved_inventory_mode == "bootstrap-show"
        or (
            resolved_inventory_mode == "bootstrap-if-not-ready"
            and not doctor["ready"]
        )
    )
    if schema == "workbench/v1" and resolved_inventory_mode == "show":
        raise AdapterError("public-inventory-mode-invalid", "show")
    if use_bootstrap:
        if schema == "workbench/v2":
            validate_contract(
                contract,
                workspace,
                require_bootstrap=True,
                require_engine_manifest=include_engine_manifest,
            )
        if authority_approval_file is None:
            raise AdapterError(
                "bootstrap-authority-approval-required",
                "--authority-approval-file",
            )
        approval = authority_approval_file.expanduser().resolve()
        inventory_argv = (
            "legacy-inventory",
            "bootstrap-show",
            "--authority-approval-file",
            str(approval),
            "--format",
            "json",
        )
        inventory_command = "bootstrap-show"
    else:
        inventory_argv = ("legacy-inventory", "show", "--format", "json")
        inventory_command = "show"
    inventory, inventory_status, inventory_source_digest = run_public_json(
        binary, inventory_argv, workspace, {0, 1}
    )
    active = validate_inventory(inventory, inventory_status, inventory_command)
    snapshot = {
        "contract": contract,
        "doctor": doctor,
        "doctor_projection": {
            "contract_version": doctor["contract_version"],
            "ready": doctor["ready"],
            "object_digest": canonical_public_digest(doctor),
            "source_digest": doctor_source_digest,
            "writer_coordination_digest": canonical_public_digest(
                doctor["writer_coordination"]
            ),
        },
        "legacy_inventory": inventory,
        "legacy_inventory_projection": {
            "contract_version": inventory["contract_version"],
            "command": inventory_command,
            "object_digest": canonical_public_digest(inventory),
            "source_digest": inventory_source_digest,
            "authority_revision": inventory["authority"]["default_revision"],
            "home_set_digest": inventory["home_set"]["digest"],
            "complete": inventory["complete"],
        },
        "legacy_inventory_command": inventory_command,
        "active_v1_tasks": active,
    }
    if include_engine_manifest:
        manifest, _, manifest_source_digest = run_public_json(
            binary,
            ("engine-manifest", "show", "--format", "json"),
            workspace,
            {0},
        )
        validate_engine_manifest(manifest, contract["engine"]["version"])
        snapshot["engine_manifest"] = manifest
        snapshot["engine_manifest_projection"] = {
            "contract_version": manifest["contract_version"],
            "command": "engine-manifest show",
            "object_digest": canonical_public_digest(manifest),
            "source_digest": manifest_source_digest,
            "content_revision": manifest["source"]["revision"],
            "manifest_digest": manifest["digest"],
        }
    if schema == "workbench/v2" and doctor["ready"]:
        task_status, _, task_status_source_digest = run_public_json(
            binary, ("task", "status", "--format", "json"), workspace, {0}
        )
        branch_raw, _ = _git_read(
            workspace, ("symbolic-ref", "--quiet", "--short", "HEAD")
        )
        try:
            branch = branch_raw.decode("utf-8", errors="strict").strip()
        except UnicodeDecodeError as error:
            raise AdapterError("public-task-status-invalid", "HEAD") from error
        snapshot["task_status"] = task_status
        snapshot["task_status_projection"] = {
            "contract_version": task_status.get("contract_version"),
            "object_digest": canonical_public_digest(task_status),
            "source_digest": task_status_source_digest,
        }
        snapshot["migration_task_claim"] = _task_claim(task_status, branch)
    return snapshot


def inspect_public_kernel(
    workspace: pathlib.Path,
    authority_approval_file: pathlib.Path | None = None,
    inventory_mode: str | None = None,
    include_engine_manifest: bool = False,
    inventory_mode_resolver: Callable[[], str | None] | None = None,
) -> dict[str, Any]:
    workspace = workspace.resolve()
    root_fd = _open_workspace_root(workspace)
    access_groups: list[dict[str, Any]] = []
    descriptor_limit: tuple[int, int] | None = None
    quarantine: dict[str, Any] | None = None
    try:
        before = _capture_caller_state(workspace, root_fd)
        descriptor_limit = _raise_access_descriptor_limit(before)
        access_groups = _capture_directory_access(workspace, root_fd, before)
        quarantine = _new_external_quarantine(workspace, root_fd)
        _preflight_quarantine_devices(quarantine, access_groups)
        result: dict[str, Any] | None = None
        failure: BaseException | None = None
        try:
            result = _inspect_public_kernel(
                workspace,
                authority_approval_file,
                inventory_mode,
                include_engine_manifest,
                inventory_mode_resolver,
            )
        except BaseException as error:
            failure = error
        access_repaired = False
        try:
            access_repaired = _restore_directory_access(
                workspace, root_fd, access_groups
            )
            after = _capture_caller_state(
                workspace,
                root_fd,
                before["git_specs"],
                before["git_binding"],
            )
        except BaseException:
            after = None
        if after != before or access_repaired:
            if after is None:
                raise AdapterError(
                    "public-adapter-restore-failed", str(workspace)
                ) from failure
            if after != before:
                _restore_caller_state(
                    workspace, root_fd, before, after, quarantine
                )
            raise AdapterError(
                "public-adapter-mutated", str(workspace)
            ) from failure
        if failure is not None:
            raise failure
        assert result is not None
        return result
    finally:
        try:
            if quarantine is not None:
                _close_external_quarantine(quarantine)
        finally:
            try:
                _close_directory_access(access_groups)
            finally:
                try:
                    os.close(root_fd)
                finally:
                    _restore_access_descriptor_limit(descriptor_limit)
