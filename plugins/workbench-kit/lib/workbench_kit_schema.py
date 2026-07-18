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

from workbench_kit_contracts import (
    ContractError,
    validate_authority_approval,
    validate_equivalence_receipt,
    validate_generation_receipt,
    validate_generator_receipt,
    validate_journal,
    validate_migration_receipt,
    validate_plan,
    validate_removal_approval,
    validate_result,
    validate_reviewed_overlay,
)


RUNTIME_VALIDATORS = {
    "bootstrap-authority-approval.schema.json": validate_authority_approval,
    "generation-receipt.schema.json": validate_generation_receipt,
    "generator-receipt.schema.json": validate_generator_receipt,
    "migration-receipt.schema.json": validate_migration_receipt,
    "plugin-equivalence.schema.json": validate_equivalence_receipt,
    "removal-approval.schema.json": validate_removal_approval,
    "reviewed-overlay.schema.json": validate_reviewed_overlay,
    "upgrade-plan.schema.json": validate_plan,
    "upgrade-result.schema.json": validate_result,
    "upgrade-journal.schema.json": validate_journal,
}


class SchemaValidationError(ValueError):
    def __init__(self, filename: str, stage: str, ref: str) -> None:
        super().__init__(f"{stage}: {filename}: {ref}")
        self.filename = filename
        self.stage = stage
        self.ref = ref


def _bind_result_to_plan(
    filename: str,
    result: dict[str, Any],
    plan: dict[str, Any],
    *,
    allow_terminal_replay: bool,
) -> None:
    for field, plan_field in (
        ("plan_digest", "plan_digest"),
        ("classification_before", "classification_before"),
        ("target_classification", "target_classification"),
        ("embedded_engine", "embedded_engine"),
        ("provenance_final", "provenance_after"),
        ("workspace", "workspace"),
        ("preserved", "preserved"),
        ("active_v1_tasks", "active_v1_tasks"),
    ):
        if result[field] != plan[plan_field]:
            raise SchemaValidationError(filename, "context", field)

    expected_applied = [
        {
            "op": operation["op"],
            "path": operation["path"],
            "before_digest": operation["before_digest"],
            "after_digest": operation["after_digest"],
        }
        for operation in plan["operations"]
    ]
    expected_cursor = len(plan["operations"]) + sum(
        parent["before_type"] is None
        for parent in plan["parent_directories"]
    )
    transaction = result["transaction"]
    if transaction["stage"] == "completed":
        if transaction["cursor"] != expected_cursor:
            raise SchemaValidationError(
                filename, "context", "transaction.cursor"
            )
        if result["applied"] == expected_applied:
            if result["changed"] is not bool(expected_applied):
                raise SchemaValidationError(filename, "context", "changed")
        elif not (
            allow_terminal_replay
            and transaction["resumed"] is True
            and result["applied"] == []
            and result["changed"] is False
        ):
            raise SchemaValidationError(filename, "context", "applied")
    elif (
        transaction["cursor"] != 0
        or result["applied"] != []
        or result["changed"] is not False
    ):
        raise SchemaValidationError(filename, "context", "rolled-back")


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
        if set(self.documents) != set(RUNTIME_VALIDATORS):
            raise SchemaValidationError(
                "*", "schema-discovery", "top-level schema set"
            )

    def schema_validator(self, filename: str) -> Draft202012Validator:
        return Draft202012Validator(
            self.documents[filename],
            registry=self.registry,
            format_checker=self.format_checker,
        )

    def schema_definition_validator(
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

    def validate(
        self,
        filename: str,
        value: Any,
        *,
        context: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if filename not in self.documents:
            raise SchemaValidationError(filename, "schema-selection", filename)
        errors = sorted(
            self.schema_validator(filename).iter_errors(value),
            key=lambda error: tuple(str(item) for item in error.absolute_path),
        )
        if errors:
            error = errors[0]
            raise SchemaValidationError(
                filename, "json-schema", error.json_path
            ) from error

        if filename in (
            "upgrade-result.schema.json",
            "upgrade-journal.schema.json",
        ):
            if not isinstance(context, dict) or set(context) != {"plan"}:
                raise SchemaValidationError(filename, "context", "plan")
            try:
                plan = validate_plan(context["plan"])
            except ContractError as error:
                raise SchemaValidationError(
                    filename, "context", error.ref
                ) from error
        elif context is not None:
            raise SchemaValidationError(filename, "context", "unexpected")
        else:
            plan = None

        try:
            if filename == "upgrade-journal.schema.json":
                assert plan is not None
                normalized = validate_journal(value, plan)
                if normalized["completion_result"] is not None:
                    _bind_result_to_plan(
                        filename,
                        normalized["completion_result"],
                        plan,
                        allow_terminal_replay=False,
                    )
                return normalized
            normalized = RUNTIME_VALIDATORS[filename](value)
        except ContractError as error:
            raise SchemaValidationError(
                filename, "runtime-contract", error.ref
            ) from error

        if filename == "upgrade-result.schema.json":
            assert plan is not None
            _bind_result_to_plan(
                filename,
                normalized,
                plan,
                allow_terminal_replay=True,
            )
        return normalized


def load_schema_suite(schema_dir: pathlib.Path) -> SchemaSuite:
    return SchemaSuite(schema_dir)
