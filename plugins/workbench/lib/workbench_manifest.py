#!/usr/bin/env python3
"""Canonical, location-independent manifest for the installed workbench plugin."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple


PLUGIN_NAME = "workbench"
SOURCE_REF = "https://github.com/YOOGOMJA/workbench-kit#plugins/workbench"
INCLUDED_PATHS = (".",)
EXCLUDED_PATHS = (
    (".DS_Store", "exact"),
    (".git/", "prefix"),
    ("lib/__pycache__/", "prefix"),
)
SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\Z"
)


def unique_object(pairs: Sequence[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON member: {}".format(key))
        value[key] = item
    return value


def sha256(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def canonical_row(*items: Any) -> str:
    return json.dumps(items, ensure_ascii=False, separators=(",", ":")) + "\n"


def require_path_text(value: str, field: str) -> None:
    if not value or any(char in value for char in ("\0", "\r", "\n")):
        raise ValueError("{} contains an unsupported path value".format(field))


def plugin_version(root: Path) -> str:
    versions = []
    for relative in (".claude-plugin/plugin.json", ".codex-plugin/plugin.json"):
        path = root / relative
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle, object_pairs_hook=unique_object)
        if not isinstance(value, dict) or value.get("name") != PLUGIN_NAME:
            raise ValueError("{} does not identify the workbench plugin".format(relative))
        version = value.get("version")
        if not isinstance(version, str) or SEMVER.fullmatch(version) is None:
            raise ValueError("{} has an invalid SemVer version".format(relative))
        versions.append(version)
    if len(set(versions)) != 1:
        raise ValueError("plugin metadata versions do not match")
    return versions[0]


def excluded(relative: str, directory: bool) -> bool:
    candidate = relative + "/" if directory else relative
    for path, match in EXCLUDED_PATHS:
        if match == "exact" and candidate == path:
            return True
        if match == "prefix" and (candidate == path or candidate.startswith(path)):
            return True
    return False


def canonical_mode(mode: int, node_type: str) -> str:
    if node_type == "symlink":
        return "120000"
    return format(stat.S_IFMT(mode) | stat.S_IMODE(mode), "06o")


def scan_node(root: Path, relative: str) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    path = root if relative == "." else root.joinpath(*relative.split("/"))
    info = path.lstat()
    if stat.S_ISREG(info.st_mode):
        node_type = "file"
        digest = sha256(path.read_bytes())
        link_target = None
        descendants: List[Dict[str, Any]] = []
    elif stat.S_ISLNK(info.st_mode):
        node_type = "symlink"
        link_target = os.readlink(path)
        require_path_text(link_target, "link_target")
        digest = sha256(link_target.encode("utf-8"))
        descendants = []
    elif stat.S_ISDIR(info.st_mode):
        node_type = "directory"
        link_target = None
        children: List[Dict[str, Any]] = []
        descendants = []
        for entry in sorted(os.scandir(path), key=lambda item: item.name):
            require_path_text(entry.name, "node name")
            child_relative = entry.name if relative == "." else relative + "/" + entry.name
            is_directory = entry.is_dir(follow_symlinks=False)
            if excluded(child_relative, is_directory):
                continue
            child, nested = scan_node(root, child_relative)
            children.append(child)
            descendants.append(child)
            descendants.extend(nested)
        rows = ["workbench-plugin-directory/v1\n"]
        for child in children:
            rows.append(
                canonical_row(
                    "child",
                    child["path"].rsplit("/", 1)[-1],
                    child["node_type"],
                    child["mode"],
                    child["digest"],
                    child["link_target"],
                )
            )
        digest = sha256("".join(rows).encode("utf-8"))
    else:
        raise ValueError("unsupported plugin node type: {}".format(relative))
    node = {
        "path": relative,
        "node_type": node_type,
        "mode": canonical_mode(info.st_mode, node_type),
        "digest": digest,
        "link_target": link_target,
    }
    return node, descendants


def manifest(root: Path) -> Dict[str, Any]:
    if not root.is_dir():
        raise ValueError("plugin root is not a directory")
    version = plugin_version(root)
    root_node, descendants = scan_node(root, ".")
    nodes = sorted([root_node, *descendants], key=lambda item: item["path"])
    excluded_paths = [
        {"path": path, "match": match} for path, match in EXCLUDED_PATHS
    ]

    source_rows = ["workbench-plugin-tree/v1\n"]
    for path in INCLUDED_PATHS:
        source_rows.append(canonical_row("included_path", path))
    for item in excluded_paths:
        source_rows.append(canonical_row("excluded_path", item["path"], item["match"]))
    for node in nodes:
        source_rows.append(
            canonical_row(
                "node",
                node["path"],
                node["node_type"],
                node["mode"],
                node["digest"],
                node["link_target"],
            )
        )
    source_revision = sha256("".join(source_rows).encode("utf-8"))

    value = {
        "contract_version": "workbench-plugin-manifest/v1",
        "plugin": {"name": PLUGIN_NAME, "version": version},
        "source": {"ref": SOURCE_REF, "revision": source_revision},
        "included_paths": list(INCLUDED_PATHS),
        "excluded_paths": excluded_paths,
        "nodes": nodes,
        "digest": None,
    }
    raw = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    value["digest"] = sha256(raw)
    return value


def cmd_show(args: argparse.Namespace) -> None:
    value = manifest(Path(args.plugin_root).resolve())
    json.dump(value, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


def cmd_version(args: argparse.Namespace) -> None:
    sys.stdout.write(plugin_version(Path(args.plugin_root).resolve()) + "\n")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)
    show = commands.add_parser("show")
    show.add_argument("--plugin-root", required=True)
    show.set_defaults(func=cmd_show)
    version = commands.add_parser("version")
    version.add_argument("--plugin-root", required=True)
    version.set_defaults(func=cmd_version)
    return root


def main() -> None:
    args = parser().parse_args()
    try:
        args.func(args)
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        sys.stderr.write("error: {}\n".format(exc))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
