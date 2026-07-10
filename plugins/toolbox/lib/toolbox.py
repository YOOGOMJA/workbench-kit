#!/usr/bin/env python3
"""Deterministic plumbing for the optional toolbox capability pack."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
from collections.abc import Sequence
from typing import Any

from toolbox_json import DuplicateJsonMember, InvalidJsonConstant, strict_json_loads
from toolbox_language import is_language_tag
from toolbox_state import (
    StateError,
    apply_scenario,
    candidate_scenarios,
    check_portfolio,
    check_product,
    context_registration,
    find_scenario,
    initialize_product,
    load_portfolio,
    load_product,
    portfolio_run_plan,
    product_run_plan,
    product_status,
    set_autonomy,
    set_quality_check,
    set_repository,
    sync_policy,
)


WORKBENCH_CONTRACT = "workbench-contract/v1"
WORKSPACE_SCHEMA = "workbench/v2"
CAPABILITY_PACK_CONTRACT = "workbench-capability-pack/v1"
PROFILE_CONTRACT = "workbench-profile/v1"
REQUIRED_CAPABILITIES = ("workspace.schema/v1", "profile.language/v1")


class ToolboxError(Exception):
    """An expected, user-actionable toolbox failure."""


def run_text_probe(
    command: Sequence[str], cwd: pathlib.Path, label: str
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            capture_output=True,
            check=False,
            encoding="utf-8",
            errors="strict",
        )
    except UnicodeDecodeError as error:
        raise ToolboxError(f"{label} returned non-UTF-8 output") from error
    except OSError as error:
        diagnostic = error.strerror or type(error).__name__
        raise ToolboxError(f"{label} could not execute: {diagnostic}") from error


def resolve_workspace(raw: str | None) -> pathlib.Path:
    if raw is None:
        result = run_text_probe(
            ["git", "rev-parse", "--show-toplevel"],
            pathlib.Path.cwd(),
            "Git workspace probe",
        )
        if result.returncode != 0:
            raise ToolboxError(
                "default workspace requires the current directory to be inside a Git worktree"
            )
        workspace = pathlib.Path(result.stdout.strip()).resolve()
    else:
        workspace = pathlib.Path(raw).expanduser().resolve()
    if not workspace.is_dir():
        raise ToolboxError(f"caller workspace is not a directory: {workspace}")

    plugin_root_raw = os.environ.get("TOOLBOX_PLUGIN_ROOT")
    if plugin_root_raw:
        plugin_root = pathlib.Path(plugin_root_raw).resolve()
        if workspace == plugin_root or plugin_root in workspace.parents:
            raise ToolboxError("caller workspace must be outside the toolbox plugin bundle")
    return workspace


def resolve_workbench_binary() -> str:
    requested = os.environ.get("TOOLBOX_WORKBENCH_BIN", "workbench")
    if os.sep in requested:
        candidate = pathlib.Path(requested).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
        raise ToolboxError(f"workbench CLI is unavailable: {requested}")

    candidate = shutil.which(requested)
    if not candidate:
        raise ToolboxError(f"workbench CLI is unavailable: {requested}")
    return candidate


def require_mapping(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ToolboxError(f"workbench contract field '{field}' must be an object")
    return value


def require_string_list(value: Any, field: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ToolboxError(f"workbench contract field '{field}' must be an array of strings")
    return value


def inspect_workbench_contract(
    workspace: pathlib.Path,
    required_capabilities: Sequence[str] = (),
    required_supported: dict[str, str] | None = None,
) -> dict[str, Any]:
    binary = resolve_workbench_binary()
    result = run_text_probe(
        [binary, "contract", "show", "--format", "json"],
        workspace,
        "workbench compatibility probe",
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or f"exit {result.returncode}"
        raise ToolboxError(f"workbench compatibility probe failed: {diagnostic}")

    try:
        document = strict_json_loads(result.stdout)
    except DuplicateJsonMember as error:
        raise ToolboxError(
            f"workbench compatibility probe returned duplicate JSON member '{error.member}'"
        ) from error
    except InvalidJsonConstant as error:
        raise ToolboxError(
            f"workbench compatibility probe returned invalid JSON constant '{error.constant}'"
        ) from error
    except json.JSONDecodeError as error:
        raise ToolboxError(f"workbench compatibility probe returned malformed JSON: {error.msg}") from error
    document = require_mapping(document, "root")

    contract_version = document.get("contract_version")
    if contract_version != WORKBENCH_CONTRACT:
        rendered = contract_version if isinstance(contract_version, str) else "missing"
        raise ToolboxError(f"unsupported workbench contract '{rendered}'")

    workspace_contract = require_mapping(document.get("workspace"), "workspace")
    reported_root = workspace_contract.get("root")
    if not isinstance(reported_root, str):
        raise ToolboxError("workbench contract field 'workspace.root' must be a string")
    if pathlib.Path(reported_root).resolve() != workspace:
        raise ToolboxError(
            f"workbench contract reported a different caller workspace: {reported_root}"
        )

    workspace_schema = workspace_contract.get("schema")
    if workspace_schema != WORKSPACE_SCHEMA:
        rendered = workspace_schema if isinstance(workspace_schema, str) else "missing"
        raise ToolboxError(f"unsupported caller workspace schema '{rendered}'")

    supported = require_mapping(document.get("supported"), "supported")
    workspace_schemas = require_mapping(
        supported.get("workspace_schemas"), "supported.workspace_schemas"
    )
    writable_schemas = require_string_list(
        workspace_schemas.get("write"), "supported.workspace_schemas.write"
    )
    if workspace_schema not in writable_schemas:
        raise ToolboxError(
            f"workbench does not allow toolbox state mutation for '{workspace_schema}'"
        )

    capability_pack_contracts = require_string_list(
        supported.get("capability_pack_contracts"),
        "supported.capability_pack_contracts",
    )
    if CAPABILITY_PACK_CONTRACT not in capability_pack_contracts:
        raise ToolboxError(
            f"workbench does not support '{CAPABILITY_PACK_CONTRACT}'"
        )

    capabilities = require_string_list(document.get("capabilities"), "capabilities")
    available_capabilities = set(capabilities)
    for capability in REQUIRED_CAPABILITIES:
        if capability not in available_capabilities:
            raise ToolboxError(f"workbench is missing required capability '{capability}'")
    for capability in required_capabilities:
        if capability not in available_capabilities:
            raise ToolboxError(f"workbench is missing required capability '{capability}'")

    for field, contract in (required_supported or {}).items():
        contracts = require_string_list(supported.get(field), f"supported.{field}")
        if contract not in contracts:
            raise ToolboxError(f"workbench does not support '{contract}'")

    profile_contracts = require_string_list(
        supported.get("profile_contracts"), "supported.profile_contracts"
    )
    if PROFILE_CONTRACT not in profile_contracts:
        raise ToolboxError(f"workbench does not support '{PROFILE_CONTRACT}'")

    profile = require_mapping(document.get("profile"), "profile")
    profile_contract = profile.get("contract_version")
    if profile_contract != PROFILE_CONTRACT:
        rendered = profile_contract if isinstance(profile_contract, str) else "missing"
        raise ToolboxError(f"unsupported workbench profile contract '{rendered}'")
    profile_language = profile.get("language")
    if not is_language_tag(profile_language):
        raise ToolboxError("workbench profile language must be a valid language tag")
    profile_source = profile.get("source")
    if profile_source != "workspace":
        rendered = profile_source if isinstance(profile_source, str) else "missing"
        raise ToolboxError(f"unsupported workbench profile source '{rendered}'")

    return {
        "compatible": True,
        "contract_version": contract_version,
        "profile": {
            "contract_version": profile_contract,
            "language": profile_language,
            "source": profile_source,
        },
        "workspace_root": str(workspace),
        "workspace_schema": workspace_schema,
    }


def write_json(document: Any) -> None:
    json.dump(document, sys.stdout, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")


def parse_boolean(value: str) -> bool:
    if value == "true":
        return True
    if value == "false":
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="toolbox",
        description="Inspect and validate versioned product state in a workbench.",
    )
    parser.add_argument(
        "--workspace",
        default=None,
        help="Caller workbench root (default: current Git worktree root)",
    )
    commands = parser.add_subparsers(
        dest="command",
        metavar="{product,scenario,portfolio,workbench}",
        required=True,
    )
    product = commands.add_parser("product", help="Initialize, inspect, or validate a product")
    product_commands = product.add_subparsers(dest="product_command", required=True)
    product_init = product_commands.add_parser("init", help="Create versioned product state")
    product_init.add_argument("--id", required=True, dest="product_id")
    product_init.add_argument("--name", required=True)
    product_init.add_argument("--language", required=True)
    product_init.add_argument("--objective", required=True)
    product_inspect = product_commands.add_parser("inspect", help="Read one product bundle")
    product_inspect.add_argument("product_id")
    product_check = product_commands.add_parser("check", help="Validate one product bundle")
    product_check.add_argument("product_id")
    product_repository = product_commands.add_parser(
        "repository", help="Mutate a product repository record"
    )
    repository_commands = product_repository.add_subparsers(
        dest="repository_command", required=True
    )
    repository_set = repository_commands.add_parser("set", help="Set a repository record")
    repository_set.add_argument("product_id")
    repository_set.add_argument("--id", required=True, dest="repository_id")
    repository_set.add_argument("--path", required=True)
    repository_set.add_argument("--role", choices=("owner", "work", "reference"), required=True)
    product_autonomy = product_commands.add_parser(
        "autonomy", help="Mutate a product autonomy policy"
    )
    autonomy_commands = product_autonomy.add_subparsers(
        dest="autonomy_command", required=True
    )
    autonomy_set = autonomy_commands.add_parser("set", help="Set an action decision")
    autonomy_set.add_argument("product_id")
    autonomy_set.add_argument("--action", required=True, dest="action_id")
    autonomy_set.add_argument("--decision", choices=("allow", "ask", "deny"), required=True)
    product_quality = product_commands.add_parser(
        "quality", help="Mutate product quality policy"
    )
    quality_commands = product_quality.add_subparsers(dest="quality_command", required=True)
    quality_check = quality_commands.add_parser("check", help="Mutate a quality check")
    quality_check_commands = quality_check.add_subparsers(
        dest="quality_check_command", required=True
    )
    quality_check_set = quality_check_commands.add_parser("set", help="Set a quality check")
    quality_check_set.add_argument("product_id")
    quality_check_set.add_argument("--id", required=True, dest="check_id")
    quality_check_set.add_argument(
        "--kind",
        choices=(
            "test", "lint", "typecheck", "build", "integration", "e2e",
            "accessibility", "visual", "performance", "security",
        ),
        required=True,
    )
    quality_check_set.add_argument("--required", required=True, type=parse_boolean)
    quality_check_set.add_argument(
        "--command-part", required=True, action="append", dest="command_parts"
    )
    product_policy = product_commands.add_parser(
        "policy", help="Materialize a canonical product policy source"
    )
    policy_commands = product_policy.add_subparsers(dest="policy_command", required=True)
    policy_sync = policy_commands.add_parser("sync", help="Synchronize product policy")
    policy_sync.add_argument("product_id")
    product_registration = product_commands.add_parser(
        "context-registration", help="Emit a strict workbench context registration"
    )
    product_registration.add_argument("product_id")
    product_registration.add_argument("--task-claim-id", required=True)
    product_registration.add_argument("--actor", required=True)
    product_registration.add_argument("--authority-ref", required=True)
    product_registration.add_argument("--registered-at", required=True)
    product_status_parser = product_commands.add_parser(
        "status", help="Derive product workflow status"
    )
    product_status_parser.add_argument("product_id")
    product_run_plan_parser = product_commands.add_parser(
        "run-plan", help="Derive one primary scenario run plan"
    )
    product_run_plan_parser.add_argument("product_id")
    product_run_plan_parser.add_argument("--scenario", dest="scenario_id")
    scenario = commands.add_parser(
        "scenario", help="Inspect, validate, or list scenario candidates"
    )
    scenario_commands = scenario.add_subparsers(dest="scenario_command", required=True)
    scenario_inspect = scenario_commands.add_parser("inspect", help="Read one scenario")
    scenario_inspect.add_argument("scenario_id")
    scenario_check = scenario_commands.add_parser("check", help="Validate one scenario")
    scenario_check.add_argument("scenario_id")
    scenario_candidates = scenario_commands.add_parser(
        "candidates", help="List dependency-ready scenarios"
    )
    scenario_candidates.add_argument("--product", dest="product_filter")
    scenario_apply = scenario_commands.add_parser("apply", help="Atomically apply a scenario")
    scenario_apply.add_argument("--product", required=True, dest="product_id")
    scenario_apply.add_argument("--file", required=True, type=pathlib.Path)

    portfolio = commands.add_parser(
        "portfolio", help="Inspect or validate the joined portfolio"
    )
    portfolio_commands = portfolio.add_subparsers(dest="portfolio_command", required=True)
    portfolio_commands.add_parser("inspect", help="Read the joined portfolio")
    portfolio_commands.add_parser("check", help="Validate the joined portfolio")
    portfolio_commands.add_parser("candidates", help="List portfolio-wide candidates")
    portfolio_commands.add_parser("run-plan", help="Select one portfolio run plan")
    workbench = commands.add_parser(
        "workbench", help="Check the public workbench compatibility contract"
    )
    workbench_commands = workbench.add_subparsers(dest="workbench_command", required=True)
    workbench_commands.add_parser("check", help="Validate the caller workbench contract")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["help"]:
        parser.print_help()
        return 0
    parsed = parser.parse_args(args)
    try:
        workspace = resolve_workspace(parsed.workspace)
        if parsed.command == "workbench" and parsed.workbench_command == "check":
            write_json(inspect_workbench_contract(workspace))
            return 0
        if parsed.command == "product":
            required_capabilities: tuple[str, ...] = ()
            required_supported: dict[str, str] = {}
            if parsed.product_command == "policy":
                required_supported["policy_contracts"] = "workbench-policy/v1"
            if parsed.product_command == "context-registration":
                required_capabilities = ("policy.context-set/v1",)
                required_supported[
                    "context_policy_contracts"
                ] = "workbench-context-policy-registration/v1"
            workbench_contract = inspect_workbench_contract(
                workspace, required_capabilities, required_supported
            )
            if parsed.product_command == "init":
                profile_language = workbench_contract["profile"]["language"]
                if parsed.language != profile_language:
                    raise ToolboxError(
                        f"product language '{parsed.language}' does not match "
                        f"workbench profile language '{profile_language}'"
                    )
                root = initialize_product(
                    workspace,
                    parsed.product_id,
                    parsed.name,
                    parsed.language,
                    parsed.objective,
                )
                write_json(
                    {
                        "created": True,
                        "product_id": parsed.product_id,
                        "product_ref": f"toolbox:product/{parsed.product_id}",
                        "state_root": str(root),
                    }
                )
                return 0
            if parsed.product_command == "status":
                write_json(product_status(workspace, parsed.product_id))
                return 0
            if parsed.product_command == "run-plan":
                write_json(
                    product_run_plan(workspace, parsed.product_id, parsed.scenario_id)
                )
                return 0
            if parsed.product_command == "inspect":
                write_json(load_product(workspace, parsed.product_id))
                return 0
            if parsed.product_command == "check":
                check_product(workspace, parsed.product_id)
                write_json({"product_id": parsed.product_id, "valid": True})
                return 0
            if parsed.product_command == "repository":
                changed, repository = set_repository(
                    workspace,
                    parsed.product_id,
                    parsed.repository_id,
                    parsed.path,
                    parsed.role,
                )
                write_json(
                    {
                        "changed": changed,
                        "product_id": parsed.product_id,
                        "repository": repository,
                    }
                )
                return 0
            if parsed.product_command == "autonomy":
                changed = set_autonomy(
                    workspace, parsed.product_id, parsed.action_id, parsed.decision
                )
                write_json(
                    {
                        "action_id": parsed.action_id,
                        "changed": changed,
                        "decision": parsed.decision,
                        "product_id": parsed.product_id,
                    }
                )
                return 0
            if parsed.product_command == "quality":
                changed, quality_check = set_quality_check(
                    workspace,
                    parsed.product_id,
                    parsed.check_id,
                    parsed.kind,
                    parsed.required,
                    parsed.command_parts,
                )
                write_json(
                    {
                        "changed": changed,
                        "product_id": parsed.product_id,
                        "quality_check": quality_check,
                    }
                )
                return 0
            if parsed.product_command == "policy":
                changed, policy_ref = sync_policy(workspace, parsed.product_id)
                write_json(
                    {
                        "changed": changed,
                        "policy_ref": policy_ref,
                        "product_id": parsed.product_id,
                    }
                )
                return 0
            if parsed.product_command == "context-registration":
                write_json(
                    context_registration(
                        workspace,
                        parsed.product_id,
                        parsed.task_claim_id,
                        parsed.actor,
                        parsed.authority_ref,
                        parsed.registered_at,
                    )
                )
                return 0
        if parsed.command == "scenario":
            inspect_workbench_contract(workspace)
            if parsed.scenario_command == "inspect":
                product_id, scenario_document = find_scenario(workspace, parsed.scenario_id)
                write_json(
                    {
                        "product_id": product_id,
                        "scenario": scenario_document,
                        "scenario_ref": f"toolbox:scenario/{parsed.scenario_id}",
                    }
                )
                return 0
            if parsed.scenario_command == "check":
                find_scenario(workspace, parsed.scenario_id)
                write_json({"scenario_id": parsed.scenario_id, "valid": True})
                return 0
            if parsed.scenario_command == "candidates":
                write_json(
                    {"candidates": candidate_scenarios(workspace, parsed.product_filter)}
                )
                return 0
            if parsed.scenario_command == "apply":
                changed, scenario_document = apply_scenario(
                    workspace, parsed.product_id, parsed.file
                )
                write_json(
                    {
                        "changed": changed,
                        "product_id": parsed.product_id,
                        "scenario": scenario_document,
                        "scenario_ref": f"toolbox:scenario/{scenario_document['id']}",
                    }
                )
                return 0
        if parsed.command == "portfolio":
            inspect_workbench_contract(workspace)
            if parsed.portfolio_command == "inspect":
                write_json(load_portfolio(workspace))
                return 0
            if parsed.portfolio_command == "check":
                portfolio_document, index = check_portfolio(workspace)
                write_json(
                    {
                        "products": len(portfolio_document["products"]),
                        "scenarios": len(index),
                        "valid": True,
                    }
                )
                return 0
            if parsed.portfolio_command == "candidates":
                write_json({"candidates": candidate_scenarios(workspace)})
                return 0
            if parsed.portfolio_command == "run-plan":
                write_json(portfolio_run_plan(workspace))
                return 0
        parser.error("a command action is required")
    except (StateError, ToolboxError) as error:
        print(f"toolbox: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError) as error:
        diagnostic = getattr(error, "strerror", None) or type(error).__name__
        print(f"toolbox: filesystem operation failed: {diagnostic}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
