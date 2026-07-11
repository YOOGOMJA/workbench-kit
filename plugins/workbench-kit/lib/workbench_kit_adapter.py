"""Read-only adapter for the public workbench kernel contracts."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
from collections.abc import Sequence
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
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
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


class AdapterError(Exception):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


def canonical_digest(value: Any) -> str:
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


def _worktree_manifest(root: pathlib.Path) -> dict[str, tuple[str, int, bytes | str | None]]:
    manifest: dict[str, tuple[str, int, bytes | str | None]] = {}

    def visit(directory: pathlib.Path, prefix: pathlib.PurePosixPath) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda item: item.name)
        except OSError as error:
            raise AdapterError("public-state-unavailable", str(directory)) from error
        for entry in entries:
            if not prefix.parts and entry.name == ".git":
                continue
            relative_path = prefix / entry.name
            relative = relative_path.as_posix()
            path = pathlib.Path(entry.path)
            try:
                node = os.lstat(path)
            except OSError as error:
                raise AdapterError("public-state-unavailable", relative) from error
            mode = stat.S_IMODE(node.st_mode)
            if stat.S_ISLNK(node.st_mode):
                try:
                    target = os.readlink(path)
                except OSError as error:
                    raise AdapterError("public-state-unavailable", relative) from error
                manifest[relative] = ("symlink", mode, target)
            elif stat.S_ISREG(node.st_mode):
                try:
                    content = path.read_bytes()
                    verified = os.lstat(path)
                except OSError as error:
                    raise AdapterError("public-state-unavailable", relative) from error
                if (
                    (node.st_dev, node.st_ino, node.st_size, node.st_mtime_ns)
                    != (verified.st_dev, verified.st_ino, verified.st_size, verified.st_mtime_ns)
                    or len(content) != node.st_size
                ):
                    raise AdapterError("public-state-unavailable", relative)
                manifest[relative] = ("file", mode, content)
            elif stat.S_ISDIR(node.st_mode):
                manifest[relative] = ("directory", mode, None)
                visit(path, relative_path)
            else:
                raise AdapterError("public-state-unavailable", relative)

    visit(root, pathlib.PurePosixPath())
    return manifest


def _git_file(path: pathlib.Path) -> tuple[bool, int | None, bytes | None]:
    try:
        node = os.lstat(path)
    except FileNotFoundError:
        return False, None, None
    except OSError as error:
        raise AdapterError("public-state-unavailable", str(path)) from error
    if not stat.S_ISREG(node.st_mode) or stat.S_ISLNK(node.st_mode):
        raise AdapterError("public-state-unavailable", str(path))
    try:
        content = path.read_bytes()
    except OSError as error:
        raise AdapterError("public-state-unavailable", str(path)) from error
    return True, stat.S_IMODE(node.st_mode), content


def _parse_refs(raw: bytes) -> dict[str, tuple[str, str | None]]:
    refs: dict[str, tuple[str, str | None]] = {}
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise AdapterError("public-state-unavailable", "git refs") from error
    for line in text.splitlines():
        parts = line.split("\0")
        if len(parts) != 3 or not parts[0] or not parts[1] or parts[0] in refs:
            raise AdapterError("public-state-unavailable", "git refs")
        refs[parts[0]] = (parts[1], parts[2] or None)
    return refs


def _capture_caller_state(workspace: pathlib.Path) -> dict[str, Any]:
    git_dir_raw, _ = _git_read(workspace, ("rev-parse", "--absolute-git-dir"))
    try:
        git_dir = pathlib.Path(git_dir_raw.decode("utf-8", errors="strict").strip()).resolve()
    except UnicodeDecodeError as error:
        raise AdapterError("public-state-unavailable", "git directory") from error
    symbolic, symbolic_status = _git_read(
        workspace, ("symbolic-ref", "--quiet", "HEAD"), {0, 1}
    )
    head, head_status = _git_read(
        workspace, ("rev-parse", "--verify", "HEAD"), {0, 128}
    )
    refs_raw, _ = _git_read(
        workspace,
        ("for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"),
    )
    porcelain, _ = _git_read(
        workspace, ("status", "--porcelain=v2", "--untracked-files=all")
    )
    return {
        "root_mode": stat.S_IMODE(os.lstat(workspace).st_mode),
        "worktree": _worktree_manifest(workspace),
        "git_dir": str(git_dir),
        "head_symbolic": symbolic if symbolic_status == 0 else None,
        "head_oid": head if head_status == 0 else None,
        "refs": _parse_refs(refs_raw),
        "porcelain": porcelain,
        "index": _git_file(git_dir / "index"),
        "fetch_head": _git_file(git_dir / "FETCH_HEAD"),
    }


def _remove_node(path: pathlib.Path) -> None:
    node = os.lstat(path)
    if stat.S_ISDIR(node.st_mode) and not stat.S_ISLNK(node.st_mode):
        os.chmod(path, 0o700)
        for child in list(path.iterdir()):
            _remove_node(child)
        path.rmdir()
    else:
        path.unlink()


def _restore_worktree(workspace: pathlib.Path, state: dict[str, Any]) -> None:
    os.chmod(workspace, 0o700)
    manifest = state["worktree"]
    current = _worktree_manifest(workspace)
    for relative in sorted(
        (
            path
            for path, value in current.items()
            if path not in manifest or manifest[path][0] != value[0]
        ),
        key=lambda path: (path.count("/"), path),
        reverse=True,
    ):
        target = workspace.joinpath(*pathlib.PurePosixPath(relative).parts)
        try:
            _remove_node(target)
        except FileNotFoundError:
            pass
    directories = sorted(
        (path for path, value in manifest.items() if value[0] == "directory"),
        key=lambda path: (path.count("/"), path),
    )
    for relative in directories:
        target = workspace.joinpath(*pathlib.PurePosixPath(relative).parts)
        if not target.exists():
            target.mkdir()
    for relative, (kind, mode, payload) in sorted(manifest.items()):
        if kind == "directory":
            continue
        target = workspace.joinpath(*pathlib.PurePosixPath(relative).parts)
        if current.get(relative) == (kind, mode, payload):
            continue
        try:
            _remove_node(target)
        except FileNotFoundError:
            pass
        if kind == "file":
            target.write_bytes(payload)
            os.chmod(target, mode)
        else:
            os.symlink(payload, target)
    for relative in reversed(directories):
        _, mode, _ = manifest[relative]
        os.chmod(workspace.joinpath(*pathlib.PurePosixPath(relative).parts), mode)
    os.chmod(workspace, state["root_mode"])


def _git_write(workspace: pathlib.Path, argv: Sequence[str]) -> None:
    _git_read(workspace, argv)


def _restore_git_state(workspace: pathlib.Path, state: dict[str, Any]) -> None:
    refs = state["refs"]
    for ref, (oid, symref) in sorted(refs.items()):
        if symref is None:
            _git_write(workspace, ("update-ref", ref, oid))
        else:
            _git_write(workspace, ("symbolic-ref", ref, symref))
    symbolic = state["head_symbolic"]
    if symbolic is not None:
        target = symbolic.decode("utf-8", errors="strict").strip()
        _git_write(workspace, ("symbolic-ref", "HEAD", target))
    elif state["head_oid"] is not None:
        oid_value = state["head_oid"].decode("ascii").strip()
        _git_write(workspace, ("update-ref", "--no-deref", "HEAD", oid_value))
    current_raw, _ = _git_read(
        workspace,
        ("for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"),
    )
    for ref in sorted(set(_parse_refs(current_raw)) - set(refs)):
        _git_write(workspace, ("update-ref", "-d", ref))
    git_dir = pathlib.Path(state["git_dir"])
    for name, snapshot in (
        ("index", state["index"]),
        ("FETCH_HEAD", state["fetch_head"]),
    ):
        path = git_dir / name
        exists, mode, content = snapshot
        if exists:
            path.write_bytes(content)
            os.chmod(path, mode)
        else:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def _restore_caller_state(workspace: pathlib.Path, state: dict[str, Any]) -> None:
    try:
        _restore_worktree(workspace, state)
        _restore_git_state(workspace, state)
        if _capture_caller_state(workspace) != state:
            raise AdapterError("public-adapter-restore-failed", str(workspace))
    except AdapterError:
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
        "claim_id",
        "task_contract",
        "branch",
        "workspace_authority_descriptor_digest",
        "context_ref",
        "work_ref",
        "work_owners",
    )
    normalized = []
    for offset, value in enumerate(tasks):
        task = require_object(value, f"{ref}.tasks[{offset}]")
        if any(field not in task for field in required):
            raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}]")
        for field in ("claim_id", "branch"):
            if (
                not isinstance(task[field], str)
                or not task[field]
                or any(ord(char) < 32 or ord(char) == 127 for char in task[field])
            ):
                raise AdapterError("public-task-status-invalid", f"{ref}.tasks[{offset}].{field}")
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
        normalized.append({field: task[field] for field in required})
    matches = [task for task in normalized if task["branch"] == branch]
    if len(matches) != 1:
        raise AdapterError("public-task-status-invalid", branch)
    return matches[0]


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
        if not isinstance(path, str) or not path or "\x00" in path:
            raise AdapterError("public-contract-invalid", f"{ref}.node.path")
        if path != ".":
            pure = pathlib.PurePosixPath(path)
            if pure.is_absolute() or pure.as_posix() != path or ".." in pure.parts:
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
    if node_paths != sorted(node_paths) or len(node_paths) != len(set(node_paths)) or not nodes:
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
    expected_digest = "sha256:" + hashlib.sha256(canonical_line(digest_input)).hexdigest()
    if document["digest"] != expected_digest:
        raise AdapterError("public-contract-invalid", f"{ref}.digest")


def _inspect_public_kernel(
    workspace: pathlib.Path,
    authority_approval_file: pathlib.Path | None = None,
    inventory_mode: str | None = None,
    include_engine_manifest: bool = False,
) -> dict[str, Any]:
    workspace = workspace.resolve()
    if inventory_mode not in (None, "show", "bootstrap-show"):
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
    use_bootstrap = schema == "workbench/v1" or inventory_mode == "bootstrap-show"
    if schema == "workbench/v1" and inventory_mode == "show":
        raise AdapterError("public-inventory-mode-invalid", "show")
    if use_bootstrap:
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
            "object_digest": canonical_digest(doctor),
            "source_digest": doctor_source_digest,
            "writer_coordination_digest": canonical_digest(
                doctor["writer_coordination"]
            ),
        },
        "legacy_inventory": inventory,
        "legacy_inventory_projection": {
            "contract_version": inventory["contract_version"],
            "command": inventory_command,
            "object_digest": canonical_digest(inventory),
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
            "object_digest": canonical_digest(manifest),
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
            "object_digest": canonical_digest(task_status),
            "source_digest": task_status_source_digest,
        }
        snapshot["migration_task_claim"] = _task_claim(task_status, branch)
    return snapshot


def inspect_public_kernel(
    workspace: pathlib.Path,
    authority_approval_file: pathlib.Path | None = None,
    inventory_mode: str | None = None,
    include_engine_manifest: bool = False,
) -> dict[str, Any]:
    workspace = workspace.resolve()
    before = _capture_caller_state(workspace)
    result: dict[str, Any] | None = None
    failure: BaseException | None = None
    try:
        result = _inspect_public_kernel(
            workspace,
            authority_approval_file,
            inventory_mode,
            include_engine_manifest,
        )
    except BaseException as error:
        failure = error
    try:
        after = _capture_caller_state(workspace)
    except BaseException:
        after = None
    if after != before:
        _restore_caller_state(workspace, before)
        raise AdapterError("public-adapter-mutated", str(workspace)) from failure
    if failure is not None:
        raise failure
    assert result is not None
    return result
