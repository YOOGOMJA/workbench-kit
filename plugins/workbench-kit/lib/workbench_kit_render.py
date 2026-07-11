"""Deterministic rendering and narrow structured merges for workbench v2."""

from __future__ import annotations

import base64
import fnmatch
from typing import Any

from workbench_kit_contracts import (
    BCP47,
    canonical_bytes,
    fail,
    strict_load,
    validate_descriptor,
    validate_generator_receipt,
)


MARKETPLACE = {
    "source": {"source": "github", "repo": "YOOGOMJA/workbench-kit"}
}
GITIGNORE_REQUIRED = (
    ".codebases/",
    ".worktrees/",
    "task/codebases/",
    ".claude/scheduled_tasks.lock",
)
GITATTRIBUTES_REQUIRED = (
    "docs/log.md merge=union",
    "task/log.md merge=union",
)


def merge_settings(raw: bytes | None) -> bytes:
    settings: Any = {} if raw is None else strict_load(raw, ".claude/settings.json")
    if not isinstance(settings, dict):
        fail(".claude/settings.json", "structured-merge-conflict")

    if "extraKnownMarketplaces" not in settings:
        marketplaces = {}
        settings["extraKnownMarketplaces"] = marketplaces
    else:
        marketplaces = settings["extraKnownMarketplaces"]
    if not isinstance(marketplaces, dict):
        fail("extraKnownMarketplaces", "structured-merge-conflict")
    if "workbench-kit" not in marketplaces:
        marketplaces["workbench-kit"] = MARKETPLACE
    elif marketplaces["workbench-kit"] != MARKETPLACE:
        fail("extraKnownMarketplaces.workbench-kit", "structured-merge-conflict")

    if "enabledPlugins" not in settings:
        plugins = {}
        settings["enabledPlugins"] = plugins
    else:
        plugins = settings["enabledPlugins"]
    if not isinstance(plugins, dict):
        fail("enabledPlugins", "structured-merge-conflict")
    if "workbench@workbench-kit" not in plugins:
        plugins["workbench@workbench-kit"] = True
    elif plugins["workbench@workbench-kit"] is not True:
        fail("enabledPlugins.workbench@workbench-kit", "structured-merge-conflict")
    return canonical_bytes(settings)


def _text_lines(raw: bytes | None, ref: str) -> tuple[list[str], str]:
    if raw is None or raw == b"":
        return [], "\n"
    if b"\x00" in raw:
        fail(ref, "structured-merge-conflict")
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        fail(ref, "structured-merge-conflict")
    has_crlf = "\r\n" in text
    without_crlf = text.replace("\r\n", "")
    if "\r" in without_crlf or (has_crlf and "\n" in without_crlf):
        fail(ref, "structured-merge-conflict")
    newline = "\r\n" if has_crlf else "\n"
    if newline == "\r\n":
        lines = text.split("\r\n")
    else:
        lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines, newline


def _gitignore_negation_conflicts(line: str) -> bool:
    if not line.startswith("!"):
        return False
    pattern = line[1:]
    if not pattern or pattern in ("*", "**", "**/*", "*/**"):
        return True
    normalized = pattern.lstrip("/").rstrip("/")
    for required in GITIGNORE_REQUIRED:
        candidate = required.rstrip("/")
        if fnmatch.fnmatchcase(candidate, normalized):
            return True
        if fnmatch.fnmatchcase(candidate + "/probe", normalized):
            return True
    return False


def merge_gitignore(raw: bytes | None) -> bytes:
    lines, newline = _text_lines(raw, ".gitignore")
    output = []
    seen = set()
    for line in lines:
        if _gitignore_negation_conflicts(line):
            fail(line, "structured-merge-conflict")
        if line in GITIGNORE_REQUIRED:
            if line in seen:
                continue
            seen.add(line)
        output.append(line)
    for required in GITIGNORE_REQUIRED:
        if required not in seen:
            output.append(required)
    return (newline.join(output) + newline).encode("utf-8")


def merge_gitattributes(raw: bytes | None) -> bytes:
    lines, newline = _text_lines(raw, ".gitattributes")
    output = []
    seen = set()
    required_by_path = {
        row.split(" ", 1)[0]: row for row in GITATTRIBUTES_REQUIRED
    }
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            output.append(line)
            continue
        fields = stripped.split()
        required = required_by_path.get(fields[0])
        if required is None:
            output.append(line)
            continue
        if stripped != required:
            fail(fields[0], "structured-merge-conflict")
        if required in seen:
            continue
        seen.add(required)
        output.append(required)
    for required in GITATTRIBUTES_REQUIRED:
        if required not in seen:
            output.append(required)
    return (newline.join(output) + newline).encode("utf-8")


def render_schema() -> bytes:
    return b"workbench/v2\n"


def render_profile(language: str) -> bytes:
    if (
        not isinstance(language, str)
        or not language.isascii()
        or BCP47.fullmatch(language) is None
    ):
        fail("language", "language-invalid")
    return f"schema=workbench-profile/v1\nlanguage={language}\n".encode("ascii")


def render_policy() -> bytes:
    return b"schema=workbench-policy/v1\n"


def render_authority(descriptor: dict[str, Any]) -> bytes:
    return canonical_bytes(validate_descriptor(descriptor, require_hosting=True))


def compose_agents(generator_receipt: dict[str, Any], overlay: bytes) -> bytes:
    receipt = validate_generator_receipt(generator_receipt)
    if not isinstance(overlay, bytes) or not overlay or not overlay.endswith(b"\n"):
        fail("overlay", "composition-invalid")
    try:
        overlay.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        fail("overlay", "composition-invalid")
    header = base64.b64decode(receipt["header_base64"], validate=True)
    core = base64.b64decode(receipt["core_base64"], validate=True)
    separator = base64.b64decode(receipt["separator_base64"], validate=True)
    return header + core + separator + overlay
