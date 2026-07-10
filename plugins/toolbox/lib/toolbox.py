#!/usr/bin/env python3
"""Deterministic plumbing for the optional toolbox capability pack."""

from __future__ import annotations

import argparse
from collections.abc import Sequence


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="toolbox",
        description="Inspect and validate versioned product state in a workbench.",
    )
    commands = parser.add_subparsers(dest="command", metavar="{product,scenario,portfolio,workbench}")
    commands.add_parser("product", help="Initialize, inspect, or validate a product")
    commands.add_parser("scenario", help="Inspect, validate, or list scenario candidates")
    commands.add_parser("portfolio", help="Inspect or validate the joined portfolio")
    commands.add_parser("workbench", help="Check the public workbench compatibility contract")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = list(argv) if argv is not None else None
    if not args or args == ["help"]:
        parser.print_help()
        return 0
    parser.parse_args(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
