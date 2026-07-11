"""Closed command-line contract for governed workbench upgrades."""

from __future__ import annotations

import argparse
import pathlib
from collections.abc import Sequence
from typing import Any


class CliError(RuntimeError):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


class _Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise CliError("argument-invalid", message)


def _parser() -> argparse.ArgumentParser:
    parser = _Parser(prog="workbench-kit")
    parser.add_argument("--workspace")
    commands = parser.add_subparsers(dest="command")
    upgrade = commands.add_parser("upgrade-workbench")
    upgrade.add_argument("--dry-run", action="store_true")
    upgrade.add_argument("--apply", action="store_true")
    upgrade.add_argument("--plan-file")
    upgrade.add_argument("--language")
    upgrade.add_argument("--authority-approval-file")
    upgrade.add_argument("--reviewed-overlay-file")
    upgrade.add_argument("--remove-embedded-engine", action="store_true")
    upgrade.add_argument("--removal-approval-file")
    upgrade.add_argument("--journal-dir")
    upgrade.add_argument("--format")
    return parser


def parse_request(argv: Sequence[str]) -> dict[str, Any]:
    parsed = _parser().parse_args(argv)
    if parsed.command != "upgrade-workbench":
        raise CliError("command-required", "upgrade-workbench")
    if parsed.workspace is None:
        raise CliError("workspace-required", "--workspace")
    if not pathlib.Path(parsed.workspace).is_absolute():
        raise CliError("workspace-not-absolute", parsed.workspace)
    if parsed.dry_run and parsed.apply:
        raise CliError("mode-conflict", "--dry-run/--apply")
    if not parsed.dry_run and not parsed.apply:
        raise CliError("mode-required", "--dry-run/--apply")
    if parsed.format is None:
        raise CliError("format-required", "--format json")
    if parsed.format != "json":
        raise CliError("format-invalid", parsed.format)
    if parsed.dry_run:
        if parsed.plan_file is not None or parsed.journal_dir is not None:
            raise CliError("dry-run-flag-conflict", "--plan-file/--journal-dir")
        if (
            parsed.removal_approval_file is not None
            and not parsed.remove_embedded_engine
        ):
            raise CliError(
                "removal-request-required", "--remove-embedded-engine"
            )
        mode = "dry-run"
    else:
        if parsed.plan_file is None:
            raise CliError("plan-file-required", "--plan-file")
        if parsed.remove_embedded_engine:
            raise CliError("apply-flag-conflict", "--remove-embedded-engine")
        mode = "apply"
    return {
        "workspace": parsed.workspace,
        "command": parsed.command,
        "mode": mode,
        "plan_file": parsed.plan_file,
        "language": parsed.language,
        "authority_approval_file": parsed.authority_approval_file,
        "reviewed_overlay_file": parsed.reviewed_overlay_file,
        "remove_embedded_engine": parsed.remove_embedded_engine,
        "removal_approval_file": parsed.removal_approval_file,
        "journal_dir": parsed.journal_dir,
        "format": parsed.format,
    }


def validate_route_flags(
    request: dict[str, Any], route: str
) -> dict[str, Any]:
    if route not in ("implicit-v1", "staged-v2", "current-v2"):
        raise CliError("route-invalid", route)
    if route == "implicit-v1":
        if request["language"] is None:
            raise CliError("language-required", "--language")
        if request["authority_approval_file"] is None:
            raise CliError(
                "authority-approval-required", "--authority-approval-file"
            )
    elif route == "staged-v2":
        if request["language"] is not None:
            raise CliError("language-not-allowed", "--language")
        if request["authority_approval_file"] is None:
            raise CliError(
                "authority-approval-required", "--authority-approval-file"
            )
    else:
        if request["language"] is not None:
            raise CliError("language-not-allowed", "--language")
        if request["authority_approval_file"] is not None:
            raise CliError(
                "authority-approval-not-allowed", "--authority-approval-file"
            )
        if request["reviewed_overlay_file"] is not None:
            raise CliError(
                "reviewed-overlay-not-allowed", "--reviewed-overlay-file"
            )
    return request
