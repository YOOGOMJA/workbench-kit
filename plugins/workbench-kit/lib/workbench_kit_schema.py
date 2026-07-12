"""Published Draft 2020-12 validator surface for workbench-kit contracts."""

from __future__ import annotations

import base64
import binascii
import json
import pathlib
import unicodedata
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource


def canonical_base64_format(value: Any) -> bool:
    if not isinstance(value, str):
        return True
    try:
        decoded = base64.b64decode(value, validate=True)
    except (TypeError, ValueError, binascii.Error):
        return False
    return base64.b64encode(decoded).decode("ascii") == value


def nfc_format(value: Any) -> bool:
    return not isinstance(value, str) or unicodedata.normalize("NFC", value) == value


def reviewed_overlay_content_format(value: Any) -> bool:
    if not isinstance(value, str) or not canonical_base64_format(value):
        return not isinstance(value, str)
    content = base64.b64decode(value, validate=True)
    try:
        content.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return False
    return bool(content) and content.endswith(b"\n")


def workbench_kit_format_checker() -> FormatChecker:
    checker = FormatChecker()
    checker.checks(
        "canonical-base64", raises=(TypeError, ValueError, binascii.Error)
    )(canonical_base64_format)
    checker.checks("nfc")(nfc_format)
    checker.checks("reviewed-overlay-content")(reviewed_overlay_content_format)
    return checker


class SchemaSuite:
    def __init__(self, schema_dir: pathlib.Path) -> None:
        self.schema_dir = schema_dir.resolve(strict=True)
        self.documents = {
            path.name: json.loads(path.read_bytes())
            for path in sorted(self.schema_dir.glob("*.schema.json"))
        }
        self.registry = Registry().with_resources(
            (document["$id"], Resource.from_contents(document))
            for document in self.documents.values()
        )
        self.format_checker = workbench_kit_format_checker()

    def validator(self, filename: str) -> Draft202012Validator:
        return Draft202012Validator(
            self.documents[filename],
            registry=self.registry,
            format_checker=self.format_checker,
        )

    def definition_validator(
        self, filename: str, definition: str
    ) -> Draft202012Validator:
        wrapper = {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$ref": (
                self.documents[filename]["$id"]
                + "#/$defs/"
                + definition
            ),
        }
        return Draft202012Validator(
            wrapper,
            registry=self.registry,
            format_checker=self.format_checker,
        )


def load_schema_suite(schema_dir: pathlib.Path) -> SchemaSuite:
    return SchemaSuite(schema_dir)
