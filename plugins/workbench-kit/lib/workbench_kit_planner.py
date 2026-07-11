"""Deterministic, read-only construction of governed workbench migration plans."""

from __future__ import annotations

import base64
import os
import pathlib
import subprocess
from typing import Any

from workbench_kit_classifier import StaticInspectionError, _inspect_node
from workbench_kit_contracts import (
    MIGRATION_TASK_FIELDS,
    PLANNER_FIELDS,
    ContractError,
    canonical_bytes,
    canonical_digest,
    decode_canonical_base64,
    exact_object,
    node_digest,
    validate_active_tasks,
    validate_authority_approval,
    validate_engine_manifest,
    validate_equivalence_receipt,
    validate_generator_receipt,
    validate_language,
    validate_plan,
    validate_receipt_input,
    validate_removal_approval,
    validate_reviewed_overlay,
)
from workbench_kit_render import (
    compose_agents,
    merge_gitattributes,
    merge_gitignore,
    merge_settings,
    render_authority,
    render_policy,
    render_profile,
    render_schema,
)


class PlanningError(RuntimeError):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


def _git(root: pathlib.Path, *argv: str, check: bool = True) -> str:
    completed = subprocess.run(
        ["git", "-C", str(root), *argv],
        capture_output=True,
        check=False,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if check and (completed.returncode != 0 or completed.stderr):
        raise PlanningError("workspace-git-invalid", "git " + " ".join(argv))
    try:
        return completed.stdout.decode("utf-8", errors="strict").strip()
    except UnicodeDecodeError as error:
        raise PlanningError("workspace-git-invalid", "git " + " ".join(argv)) from error


def _source_identity(
    root: pathlib.Path, migration_task: dict[str, Any]
) -> tuple[str, str]:
    status = _git(root, "status", "--porcelain=v2", "--untracked-files=all")
    if status:
        raise PlanningError("workspace-dirty", "git-status")
    if _git(root, "rev-parse", "--verify", "-q", "MERGE_HEAD", check=False):
        raise PlanningError("workspace-dirty", "merge-in-progress")
    git_dir = pathlib.Path(_git(root, "rev-parse", "--absolute-git-dir"))
    if any((git_dir / name).exists() for name in ("rebase-apply", "rebase-merge")):
        raise PlanningError("workspace-dirty", "rebase-in-progress")
    source_revision = _git(root, "rev-parse", "HEAD")
    source_tree = _git(root, "rev-parse", "HEAD^{tree}")
    index_diff = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "diff-index",
            "--cached",
            "--quiet",
            "HEAD",
            "--",
        ],
        capture_output=True,
        check=False,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"},
    )
    if index_diff.stderr or index_diff.returncode not in (0, 1):
        raise PlanningError(
            "workspace-git-invalid", "git diff-index --cached --quiet HEAD --"
        )
    if index_diff.returncode == 1:
        raise PlanningError("workspace-dirty", "git-index")
    branch = _git(root, "symbolic-ref", "--short", "HEAD")
    if branch != migration_task["branch"]:
        raise PlanningError("migration-task-stale", "branch")
    index = _inspect_node(root, "task/index.md")
    if (
        index["node_type"] != "file"
        or index["mode"] != "100644"
        or canonical_digest(index["content"], raw=True)
        != migration_task["index_digest"]
    ):
        raise PlanningError("migration-task-stale", "task/index.md")
    return source_revision, "git-tree:" + source_tree


def _file_bytes(root: pathlib.Path, path: str) -> bytes | None:
    node = _inspect_node(root, path)
    if node["node_type"] == "absent":
        return None
    if node["node_type"] != "file" or node["mode"] != "100644":
        raise PlanningError("structured-merge-conflict", path)
    return node["content"]


def _artifact(path: str, content: bytes, source_ref: str) -> dict[str, Any]:
    return {
        "path": path,
        "node_type": "file",
        "mode": "100644",
        "content_base64": base64.b64encode(content).decode("ascii"),
        "link_target": None,
        "source_ref": source_ref,
        "source_digest": canonical_digest(content, raw=True),
    }


def _manifest_node(path: str, content: bytes) -> dict[str, str]:
    return {
        "path": path,
        "node_type": "file",
        "mode": "100644",
        "digest": node_digest("file", "100644", content=content),
    }


def _operation_for(
    root: pathlib.Path, artifact: dict[str, Any], content: bytes
) -> dict[str, Any] | None:
    before = _inspect_node(root, artifact["path"])
    after_digest = node_digest("file", "100644", content=content)
    if (
        before["node_type"] == "file"
        and before["mode"] == "100644"
        and before["digest"] == after_digest
    ):
        return None
    if before["node_type"] == "absent":
        operation = "create"
        before_type = before_mode = before_digest = None
    elif before["node_type"] == "file" or (
        artifact["path"] == "CLAUDE.md"
        and before["node_type"] == "symlink"
        and before["link_target"] == "AGENTS.md"
    ):
        if before["node_type"] == "file" and before["mode"] != "100644":
            raise PlanningError("owned-target-mode-conflict", artifact["path"])
        operation = "update"
        before_type = before["node_type"]
        before_mode = before["mode"]
        before_digest = before["digest"]
    else:
        raise PlanningError("owned-target-type-conflict", artifact["path"])
    return {
        "op": operation,
        "path": artifact["path"],
        "before_type": before_type,
        "before_mode": before_mode,
        "before_digest": before_digest,
        "after_type": "file",
        "after_mode": "100644",
        "after_digest": after_digest,
        "artifact_source_digest": artifact["source_digest"],
        "equivalence_receipt_ref": None,
    }


def _remove_operation(
    root: pathlib.Path, expected: dict[str, Any], receipt_id: str
) -> dict[str, Any]:
    before = _inspect_node(root, expected["path"])
    if any(
        before[field] != expected[field]
        for field in ("node_type", "mode", "digest", "link_target")
    ):
        raise PlanningError("plugin-equivalence-stale", expected["path"])
    return {
        "op": "remove",
        "path": expected["path"],
        "before_type": expected["node_type"],
        "before_mode": expected["mode"],
        "before_digest": expected["digest"],
        "after_type": None,
        "after_mode": None,
        "after_digest": None,
        "artifact_source_digest": None,
        "equivalence_receipt_ref": receipt_id,
    }


def _parent_directories(
    root: pathlib.Path, operation_paths: list[str]
) -> list[dict[str, Any]]:
    parent_paths = sorted(
        {
            "/".join(pathlib.PurePosixPath(path).parts[:index])
            for path in operation_paths
            for index in range(1, len(pathlib.PurePosixPath(path).parts))
        },
        key=lambda path: (path.count("/"), path),
    )
    parents = []
    for path in parent_paths:
        node = _inspect_node(root, path)
        if node["node_type"] == "absent":
            parents.append({
                "path": path,
                "before_type": None,
                "before_mode": None,
                "after_type": "directory",
                "after_mode": "040755",
            })
        elif node["node_type"] == "directory":
            parents.append({
                "path": path,
                "before_type": "directory",
                "before_mode": node["mode"],
                "after_type": "directory",
                "after_mode": node["mode"],
            })
        else:
            raise PlanningError("operation-parent-conflict", path)
    return parents


def _preserved_nodes(
    root: pathlib.Path, operation_paths: set[str]
) -> list[dict[str, Any]]:
    preserved = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = pathlib.Path(current)
        relative_current = current_path.relative_to(root).as_posix()
        kept_directories = []
        for name in sorted(directories):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            folded = relative.casefold()
            if relative_current == "." and folded in (
                ".git", ".worktrees", ".codebases"
            ):
                continue
            if folded == "task/codebases" or folded.startswith("task/codebases/"):
                continue
            if path.is_symlink():
                if relative not in operation_paths:
                    node = _inspect_node(root, relative)
                    preserved.append({
                        "path": relative,
                        "node_type": "symlink",
                        "mode": node["mode"],
                        "digest": node["digest"],
                        "link_target": node["link_target"],
                    })
            else:
                kept_directories.append(name)
        directories[:] = kept_directories
        for name in sorted(files):
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            if relative.casefold() == ".claude/scheduled_tasks.lock":
                continue
            if relative in operation_paths:
                continue
            node = _inspect_node(root, relative)
            if node["node_type"] not in ("file", "symlink"):
                raise PlanningError("preserved-node-invalid", relative)
            preserved.append({
                "path": relative,
                "node_type": node["node_type"],
                "mode": node["mode"],
                "digest": node["digest"],
                "link_target": node["link_target"],
            })
    return sorted(preserved, key=lambda item: item["path"])


def build_migration_plan(
    workspace: pathlib.Path,
    *,
    diagnosis: dict[str, Any],
    public_snapshot: dict[str, Any],
    authority_input: dict[str, Any],
    language: dict[str, Any],
    migration_task: dict[str, Any],
    planner: dict[str, Any],
    generator_receipt: dict[str, Any],
    reviewed_overlay_input: dict[str, Any] | None,
    engine_manifest_projection: dict[str, Any] | None = None,
    plugin_equivalence_input: dict[str, Any] | None = None,
    remove_embedded: bool = False,
    removal_approval_input: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root = workspace.resolve(strict=True)
    try:
        authority_input = validate_receipt_input(
            authority_input,
            "authority_input",
            validate_authority_approval,
        )
        language = validate_language(language)
        migration_task = exact_object(
            migration_task, MIGRATION_TASK_FIELDS, "migration_task"
        )
        planner = exact_object(planner, PLANNER_FIELDS, "planner")
        generator_receipt = validate_generator_receipt(generator_receipt)
        if reviewed_overlay_input is not None:
            reviewed_overlay_input = validate_receipt_input(
                reviewed_overlay_input,
                "reviewed_overlay_input",
                validate_reviewed_overlay,
            )
        if plugin_equivalence_input is not None:
            plugin_equivalence_input = validate_receipt_input(
                plugin_equivalence_input,
                "plugin_equivalence_input",
                validate_equivalence_receipt,
            )
        if engine_manifest_projection is not None:
            engine_manifest_projection = validate_engine_manifest(
                engine_manifest_projection
            )
        if removal_approval_input is not None:
            removal_approval_input = validate_receipt_input(
                removal_approval_input,
                "removal_approval_input",
                validate_removal_approval,
            )
        if not isinstance(remove_embedded, bool):
            raise PlanningError("remove-embedded-invalid", "remove_embedded")
        review_recovery = (
            reviewed_overlay_input is not None
            and diagnosis["classification"] == "malformed"
            and bool(diagnosis["blockers"])
            and all(
                blocker == {
                    "code": "generator-composition-invalid",
                    "ref": "AGENTS.md",
                }
                for blocker in diagnosis["blockers"]
            )
        )
        ordinary_migration = (
            diagnosis["classification"] in (
                "generated-minimal", "embedded-legacy", "migration-staged"
            )
            and not diagnosis["blockers"]
        )
        if not ordinary_migration and not review_recovery:
            raise PlanningError("classification-not-actionable", diagnosis["classification"])
        embedded_state = diagnosis["embedded_engine"]["state"]
        if embedded_state == "absent":
            if any(
                item is not None
                for item in (
                    engine_manifest_projection,
                    plugin_equivalence_input,
                    removal_approval_input,
                )
            ) or remove_embedded:
                raise PlanningError("embedded-engine-absent", "embedded-engine")
            embedded_after = "absent"
        elif embedded_state == "present-verified":
            if engine_manifest_projection is None or plugin_equivalence_input is None:
                raise PlanningError("plugin-equivalence-unavailable", "embedded-engine")
            if (
                diagnosis["embedded_engine"]["equivalence_receipt_digest"]
                != plugin_equivalence_input["object_digest"]
            ):
                raise PlanningError("plugin-equivalence-stale", "embedded-engine")
            embedded_after = "absent" if remove_embedded else "present-verified"
            if not remove_embedded and removal_approval_input is not None:
                raise PlanningError("removal-operation-required", "removal_approval")
        else:
            raise PlanningError("plugin-equivalence-unavailable", "embedded-engine")

        source_revision, source_tree_digest = _source_identity(root, migration_task)
        legacy = public_snapshot["legacy_inventory_projection"]
        doctor = public_snapshot["doctor_projection"]
        if legacy["command"] != "bootstrap-show" or doctor["ready"] is not False:
            raise PlanningError("public-snapshot-stale", "doctor/inventory")
        if authority_input["receipt"]["default_revision"] != legacy["authority_revision"]:
            raise PlanningError("authority-approval-stale", "default_revision")
        observed_descriptor_digest = public_snapshot["legacy_inventory"]["authority"][
            "descriptor_digest"
        ]
        if canonical_digest(
            authority_input["receipt"]["proposed_descriptor"]
        ) != observed_descriptor_digest:
            raise PlanningError("authority-approval-stale", "descriptor_digest")

        active_tasks = {
            "contract_version": "workbench-kit-active-v1-tasks/v1",
            "source_inventory_object_digest": legacy["object_digest"],
            "tasks": public_snapshot["active_v1_tasks"],
            "digest": None,
        }
        active_tasks["digest"] = canonical_digest(active_tasks, null_field="digest")
        active_tasks = validate_active_tasks(active_tasks)

        embedded = {
            "before": embedded_state,
            "after": embedded_after,
            "equivalence_receipt_digest": diagnosis["embedded_engine"][
                "equivalence_receipt_digest"
            ],
        }
        if (
            diagnosis["classification"] == "migration-staged"
            and not remove_embedded
        ):
            plan = {
                "contract_version": "workbench-kit-upgrade-plan/v1",
                "plan_digest": None,
                "classification_before": "migration-staged",
                "target_classification": "migration-staged",
                "embedded_engine": embedded,
                "provenance_before": diagnosis["provenance"],
                "provenance_after": diagnosis["provenance"],
                "workspace": {
                    "root": str(root),
                    "source_revision": source_revision,
                    "default_revision": legacy["authority_revision"],
                    "source_tree_digest": source_tree_digest,
                    "migration_task": migration_task,
                },
                "planner": planner,
                "doctor": doctor,
                "legacy_inventory": legacy,
                "inputs": {
                    "language": language,
                    "bootstrap_authority_approval": authority_input,
                    "reviewed_overlay": reviewed_overlay_input,
                },
                "engine_manifest": engine_manifest_projection,
                "plugin_equivalence": plugin_equivalence_input,
                "removal_plan_basis_digest": None,
                "removal_approval": None,
                "active_v1_tasks": active_tasks,
                "preserved": _preserved_nodes(root, set()),
                "parent_directories": [],
                "artifacts": [],
                "operations": [],
                "blockers": [],
                "changed": False,
                "actionable": False,
            }
            plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
            return validate_plan(plan)

        if reviewed_overlay_input is None:
            overlay_node = _inspect_node(root, "AGENTS.overlay.md")
            if overlay_node["node_type"] != "file" or overlay_node["mode"] != "100644":
                raise PlanningError("composition-invalid", "AGENTS.overlay.md")
            overlay = overlay_node["content"]
        else:
            overlay = decode_canonical_base64(
                reviewed_overlay_input["receipt"]["content_base64"],
                "reviewed_overlay_input.content_base64",
            )
        agents = compose_agents(generator_receipt, overlay)
        targets: dict[str, tuple[bytes, str]] = {
            ".workbench/schema": (render_schema(), "constant:workbench/v2"),
            ".workbench/profile.conf": (
                render_profile(language["tag"]), "render:workbench-profile/v1"
            ),
            ".workbench/policy.conf": (
                render_policy(), "constant:workbench-policy/v1-conservative-ask"
            ),
            ".workbench/authority.json": (
                render_authority(authority_input["receipt"]["proposed_descriptor"]),
                "input:bootstrap-authority-approval#proposed_descriptor",
            ),
            "AGENTS.md": (agents, "compose:workbench-kit-compose/v1"),
            "CLAUDE.md": (agents, "compose:workbench-kit-compose/v1"),
            ".claude/settings.json": (
                merge_settings(_file_bytes(root, ".claude/settings.json")),
                "merge:claude-settings/v1",
            ),
            ".gitignore": (
                merge_gitignore(_file_bytes(root, ".gitignore")),
                "merge:gitignore/v1",
            ),
            ".gitattributes": (
                merge_gitattributes(_file_bytes(root, ".gitattributes")),
                "merge:gitattributes/v1",
            ),
        }
        if reviewed_overlay_input is not None:
            targets["AGENTS.overlay.md"] = (
                overlay, "input:reviewed-overlay#content"
            )

        receipt_artifacts = [
            _manifest_node(path, content)
            for path, (content, _) in sorted(targets.items())
        ]
        migration_receipt = {
            "contract_version": "workbench-kit-migration-receipt/v1",
            "source_revision": source_revision,
            "source_tree_digest": source_tree_digest,
            "planner": planner,
            "migration_task": migration_task,
            "language": language,
            "authority_approval_object_digest": authority_input["object_digest"],
            "authority_approval_source_digest": authority_input["source_digest"],
            "reviewed_overlay_object_digest": (
                reviewed_overlay_input["object_digest"]
                if reviewed_overlay_input else None
            ),
            "reviewed_overlay_source_digest": (
                reviewed_overlay_input["source_digest"]
                if reviewed_overlay_input else None
            ),
            "legacy_inventory_object_digest": legacy["object_digest"],
            "legacy_inventory_source_digest": legacy["source_digest"],
            "active_v1_tasks_digest": active_tasks["digest"],
            "embedded_engine": embedded,
            "artifacts": receipt_artifacts,
            "candidate_basis_digest": None,
        }
        migration_receipt["candidate_basis_digest"] = canonical_digest(
            migration_receipt, null_field="candidate_basis_digest"
        )
        migration_bytes = canonical_bytes(migration_receipt)
        targets[".workbench/migration.json"] = (
            migration_bytes, "render:workbench-kit-migration-receipt/v1"
        )

        artifacts = []
        operations = []
        for path, (content, source_ref) in sorted(targets.items()):
            artifact = _artifact(path, content, source_ref)
            operation = _operation_for(root, artifact, content)
            if operation is not None:
                artifacts.append(artifact)
                operations.append(operation)
        if remove_embedded:
            equivalence = plugin_equivalence_input["receipt"]
            operations.extend(
                _remove_operation(root, node, equivalence["receipt_id"])
                for node in equivalence["removable_nodes"]
            )
        artifacts.sort(key=lambda item: item["path"])
        operations.sort(key=lambda item: (item["path"], item["op"]))
        operation_paths = {item["path"] for item in operations}
        parents = _parent_directories(root, sorted(operation_paths))
        preserved = _preserved_nodes(root, operation_paths)
        remove_operations = [
            operation for operation in operations if operation["op"] == "remove"
        ]
        removal_plan_basis_digest = None
        blockers = []
        if remove_operations:
            removal_basis = {
                "contract_version": "workbench-kit-removal-plan-basis/v1",
                "workspace_source_revision": source_revision,
                "workspace_source_tree_digest": source_tree_digest,
                "migration_task_claim_id": migration_task["claim_id"],
                "planner_revision": planner["planner_revision"],
                "legacy_inventory_digest": legacy["object_digest"],
                "equivalence_receipt_digest": plugin_equivalence_input[
                    "object_digest"
                ],
                "remove_operations": remove_operations,
            }
            removal_plan_basis_digest = canonical_digest(removal_basis)
            if removal_approval_input is None:
                blockers.append({
                    "code": "removal-approval-required",
                    "ref": removal_plan_basis_digest,
                })
        provenance_after = {
            "kind": "migration",
            "state": "valid",
            "receipt_digest": migration_receipt["candidate_basis_digest"],
            "ref": ".workbench/migration.json",
        }
        plan = {
            "contract_version": "workbench-kit-upgrade-plan/v1",
            "plan_digest": None,
            "classification_before": diagnosis["classification"],
            "target_classification": "migration-staged",
            "embedded_engine": embedded,
            "provenance_before": diagnosis["provenance"],
            "provenance_after": provenance_after,
            "workspace": {
                "root": str(root),
                "source_revision": source_revision,
                "default_revision": legacy["authority_revision"],
                "source_tree_digest": source_tree_digest,
                "migration_task": migration_task,
            },
            "planner": planner,
            "doctor": doctor,
            "legacy_inventory": legacy,
            "inputs": {
                "language": language,
                "bootstrap_authority_approval": authority_input,
                "reviewed_overlay": reviewed_overlay_input,
            },
            "engine_manifest": engine_manifest_projection,
            "plugin_equivalence": plugin_equivalence_input,
            "removal_plan_basis_digest": removal_plan_basis_digest,
            "removal_approval": removal_approval_input,
            "active_v1_tasks": active_tasks,
            "preserved": preserved,
            "parent_directories": parents,
            "artifacts": artifacts,
            "operations": operations,
            "blockers": blockers,
            "changed": bool(operations),
            "actionable": bool(operations) and not blockers,
        }
        plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
        return validate_plan(plan)
    except StaticInspectionError as error:
        raise PlanningError(error.code, error.ref) from error
    except ContractError as error:
        raise PlanningError(error.code, error.ref) from error


def build_current_plan(
    workspace: pathlib.Path,
    *,
    diagnosis: dict[str, Any],
    public_snapshot: dict[str, Any],
    migration_task: dict[str, Any],
    planner: dict[str, Any],
    engine_manifest_projection: dict[str, Any] | None = None,
    plugin_equivalence_input: dict[str, Any] | None = None,
    remove_embedded: bool = False,
    removal_approval_input: dict[str, Any] | None = None,
) -> dict[str, Any]:
    root = workspace.resolve(strict=True)
    try:
        migration_task = exact_object(
            migration_task, MIGRATION_TASK_FIELDS, "migration_task"
        )
        if migration_task["task_contract"] != "workbench-task/v2":
            raise PlanningError("migration-task-contract-invalid", "task/index.md")
        planner = exact_object(planner, PLANNER_FIELDS, "planner")
        if engine_manifest_projection is not None:
            engine_manifest_projection = validate_engine_manifest(
                engine_manifest_projection
            )
        if plugin_equivalence_input is not None:
            plugin_equivalence_input = validate_receipt_input(
                plugin_equivalence_input,
                "plugin_equivalence_input",
                validate_equivalence_receipt,
            )
        if removal_approval_input is not None:
            removal_approval_input = validate_receipt_input(
                removal_approval_input,
                "removal_approval_input",
                validate_removal_approval,
            )
        if not isinstance(remove_embedded, bool):
            raise PlanningError("remove-embedded-invalid", "remove_embedded")
        if (
            diagnosis["classification"] != "already-current"
            or diagnosis["blockers"]
        ):
            raise PlanningError(
                "classification-not-actionable", diagnosis["classification"]
            )

        doctor = public_snapshot["doctor_projection"]
        legacy = public_snapshot["legacy_inventory_projection"]
        if doctor["ready"] is not True or legacy["command"] != "show":
            raise PlanningError("public-snapshot-stale", "doctor/inventory")
        source_revision, source_tree_digest = _source_identity(
            root, migration_task
        )
        language = {
            "contract_version": "workbench-kit-language-decision/v1",
            "tag": diagnosis["language"],
            "source": "workspace-profile",
            "source_ref": ".workbench/profile.conf",
            "digest": None,
        }
        language["digest"] = canonical_digest(language, null_field="digest")
        language = validate_language(language)

        embedded_state = diagnosis["embedded_engine"]["state"]
        if embedded_state == "absent":
            if any(
                item is not None
                for item in (
                    engine_manifest_projection,
                    plugin_equivalence_input,
                    removal_approval_input,
                )
            ) or remove_embedded:
                raise PlanningError("embedded-engine-absent", "embedded-engine")
            embedded_after = "absent"
        elif embedded_state == "present-verified":
            if engine_manifest_projection is None or plugin_equivalence_input is None:
                raise PlanningError(
                    "plugin-equivalence-unavailable", "embedded-engine"
                )
            if (
                diagnosis["embedded_engine"]["equivalence_receipt_digest"]
                != plugin_equivalence_input["object_digest"]
            ):
                raise PlanningError("plugin-equivalence-stale", "embedded-engine")
            embedded_after = "absent" if remove_embedded else "present-verified"
            if not remove_embedded and removal_approval_input is not None:
                raise PlanningError(
                    "removal-operation-required", "removal_approval"
                )
        else:
            raise PlanningError(
                "plugin-equivalence-unavailable", "embedded-engine"
            )
        embedded = {
            "before": embedded_state,
            "after": embedded_after,
            "equivalence_receipt_digest": diagnosis["embedded_engine"][
                "equivalence_receipt_digest"
            ],
        }

        active_tasks = {
            "contract_version": "workbench-kit-active-v1-tasks/v1",
            "source_inventory_object_digest": legacy["object_digest"],
            "tasks": public_snapshot["active_v1_tasks"],
            "digest": None,
        }
        active_tasks["digest"] = canonical_digest(
            active_tasks, null_field="digest"
        )
        active_tasks = validate_active_tasks(active_tasks)

        operations = []
        if remove_embedded:
            equivalence = plugin_equivalence_input["receipt"]
            operations = [
                _remove_operation(root, node, equivalence["receipt_id"])
                for node in equivalence["removable_nodes"]
            ]
        operations.sort(key=lambda item: (item["path"], item["op"]))
        operation_paths = {operation["path"] for operation in operations}
        parents = _parent_directories(root, sorted(operation_paths))
        preserved = _preserved_nodes(root, operation_paths)

        removal_plan_basis_digest = None
        blockers = []
        if operations:
            removal_basis = {
                "contract_version": "workbench-kit-removal-plan-basis/v1",
                "workspace_source_revision": source_revision,
                "workspace_source_tree_digest": source_tree_digest,
                "migration_task_claim_id": migration_task["claim_id"],
                "planner_revision": planner["planner_revision"],
                "legacy_inventory_digest": legacy["object_digest"],
                "equivalence_receipt_digest": plugin_equivalence_input[
                    "object_digest"
                ],
                "remove_operations": operations,
            }
            removal_plan_basis_digest = canonical_digest(removal_basis)
            if removal_approval_input is None:
                blockers = [{
                    "code": "removal-approval-required",
                    "ref": removal_plan_basis_digest,
                }]

        plan = {
            "contract_version": "workbench-kit-upgrade-plan/v1",
            "plan_digest": None,
            "classification_before": "already-current",
            "target_classification": "already-current",
            "embedded_engine": embedded,
            "provenance_before": diagnosis["provenance"],
            "provenance_after": diagnosis["provenance"],
            "workspace": {
                "root": str(root),
                "source_revision": source_revision,
                "default_revision": legacy["authority_revision"],
                "source_tree_digest": source_tree_digest,
                "migration_task": migration_task,
            },
            "planner": planner,
            "doctor": doctor,
            "legacy_inventory": legacy,
            "inputs": {
                "language": language,
                "bootstrap_authority_approval": None,
                "reviewed_overlay": None,
            },
            "engine_manifest": engine_manifest_projection,
            "plugin_equivalence": plugin_equivalence_input,
            "removal_plan_basis_digest": removal_plan_basis_digest,
            "removal_approval": removal_approval_input,
            "active_v1_tasks": active_tasks,
            "preserved": preserved,
            "parent_directories": parents,
            "artifacts": [],
            "operations": operations,
            "blockers": blockers,
            "changed": bool(operations),
            "actionable": bool(operations) and not blockers,
        }
        plan["plan_digest"] = canonical_digest(plan, null_field="plan_digest")
        return validate_plan(plan)
    except StaticInspectionError as error:
        raise PlanningError(error.code, error.ref) from error
    except ContractError as error:
        raise PlanningError(error.code, error.ref) from error
