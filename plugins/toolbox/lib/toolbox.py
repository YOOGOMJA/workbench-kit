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

from toolbox_state import (
    StateError,
    candidate_scenarios,
    check_portfolio,
    check_product,
    find_scenario,
    initialize_product,
    load_portfolio,
    load_product,
)


WORKBENCH_CONTRACT = "workbench-contract/v1"
WORKSPACE_SCHEMA = "workbench/v2"
CAPABILITY_PACK_CONTRACT = "workbench-capability-pack/v1"


class ToolboxError(Exception):
    """An expected, user-actionable toolbox failure."""


def resolve_workspace(raw: str) -> pathlib.Path:
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


def inspect_workbench_contract(workspace: pathlib.Path) -> dict[str, Any]:
    binary = resolve_workbench_binary()
    result = subprocess.run(
        [binary, "contract", "show", "--format", "json"],
        cwd=workspace,
        capture_output=True,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        diagnostic = result.stderr.strip() or f"exit {result.returncode}"
        raise ToolboxError(f"workbench compatibility probe failed: {diagnostic}")

    try:
        document = json.loads(result.stdout)
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

    return {
        "compatible": True,
        "contract_version": contract_version,
        "workspace_root": str(workspace),
        "workspace_schema": workspace_schema,
    }


def write_json(document: Any) -> None:
    json.dump(document, sys.stdout, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="toolbox",
        description="Inspect and validate versioned product state in a workbench.",
    )
    parser.add_argument(
        "--workspace",
        default=".",
        help="Caller workbench root (default: current directory)",
    )
    commands = parser.add_subparsers(dest="command", metavar="{product,scenario,portfolio,workbench}")
    product = commands.add_parser("product", help="Initialize, inspect, or validate a product")
    product_commands = product.add_subparsers(dest="product_command")
    product_init = product_commands.add_parser("init", help="Create versioned product state")
    product_init.add_argument("--id", required=True, dest="product_id")
    product_init.add_argument("--name", required=True)
    product_init.add_argument("--language", required=True)
    product_init.add_argument("--objective", required=True)
    product_inspect = product_commands.add_parser("inspect", help="Read one product bundle")
    product_inspect.add_argument("product_id")
    product_check = product_commands.add_parser("check", help="Validate one product bundle")
    product_check.add_argument("product_id")
    scenario = commands.add_parser(
        "scenario", help="Inspect, validate, or list scenario candidates"
    )
    scenario_commands = scenario.add_subparsers(dest="scenario_command")
    scenario_inspect = scenario_commands.add_parser("inspect", help="Read one scenario")
    scenario_inspect.add_argument("scenario_id")
    scenario_check = scenario_commands.add_parser("check", help="Validate one scenario")
    scenario_check.add_argument("scenario_id")
    scenario_candidates = scenario_commands.add_parser(
        "candidates", help="List dependency-ready scenarios"
    )
    scenario_candidates.add_argument("--product", dest="product_filter")

    portfolio = commands.add_parser(
        "portfolio", help="Inspect or validate the joined portfolio"
    )
    portfolio_commands = portfolio.add_subparsers(dest="portfolio_command")
    portfolio_commands.add_parser("inspect", help="Read the joined portfolio")
    portfolio_commands.add_parser("check", help="Validate the joined portfolio")
    portfolio_commands.add_parser("candidates", help="List portfolio-wide candidates")
    workbench = commands.add_parser(
        "workbench", help="Check the public workbench compatibility contract"
    )
    workbench_commands = workbench.add_subparsers(dest="workbench_command")
    workbench_commands.add_parser("check", help="Validate the caller workbench contract")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args == ["help"]:
        parser.print_help()
        return 0
    parsed = parser.parse_args(args)
    try:
        workspace = resolve_workspace(parsed.workspace)
        if parsed.command == "workbench" and parsed.workbench_command == "check":
            write_json(inspect_workbench_contract(workspace))
            return 0
        if parsed.command == "product":
            inspect_workbench_contract(workspace)
            if parsed.product_command == "init":
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
            if parsed.product_command == "inspect":
                write_json(load_product(workspace, parsed.product_id))
                return 0
            if parsed.product_command == "check":
                check_product(workspace, parsed.product_id)
                write_json({"product_id": parsed.product_id, "valid": True})
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
        parser.error("a command action is required")
    except (StateError, ToolboxError) as error:
        print(f"toolbox: {error}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
