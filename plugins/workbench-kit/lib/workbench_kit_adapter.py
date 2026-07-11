"""Read-only adapter for the public workbench kernel contracts."""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
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
LEGACY_INVENTORY_CONTRACT = "workbench-legacy-inventory/v1"
BOOTSTRAP_APPROVAL_CONTRACT = "workbench-bootstrap-authority-approval/v1"
GIT_OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")


class AdapterError(Exception):
    def __init__(self, code: str, ref: str) -> None:
        super().__init__(f"{code}: {ref}")
        self.code = code
        self.ref = ref


def require_object(value: Any, ref: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AdapterError("public-contract-invalid", ref)
    return value


def require_array(value: Any, ref: str) -> list[Any]:
    if not isinstance(value, list):
        raise AdapterError("public-contract-invalid", ref)
    return value


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
) -> tuple[dict[str, Any], int]:
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
    return require_object(value, ref), completed.returncode


def validate_contract(document: dict[str, Any], workspace: pathlib.Path) -> str:
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
    if schema == "workbench/v1":
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
    return schema


def validate_doctor(document: dict[str, Any], status: int) -> None:
    ref = "workbench doctor"
    if document.get("contract_version") != "workbench-doctor/v1":
        raise AdapterError("public-contract-invalid", ref)
    ready = document.get("ready")
    if not isinstance(ready, bool) or (ready and status != 0) or (not ready and status != 1):
        raise AdapterError("public-contract-invalid", ref)
    coordination = require_object(
        document.get("writer_coordination"), f"{ref}.writer_coordination"
    )
    if coordination.get("push_permission") not in ("allowed", "denied", "unknown"):
        raise AdapterError("public-contract-invalid", f"{ref}.push_permission")
    if not isinstance(coordination.get("legacy_inventory_readable"), bool):
        raise AdapterError("public-contract-invalid", f"{ref}.legacy_inventory_readable")


def validate_inventory(
    document: dict[str, Any], status: int
) -> list[dict[str, Any]]:
    ref = "workbench legacy-inventory show"
    if document.get("contract_version") != "workbench-legacy-inventory/v1":
        raise AdapterError("legacy-inventory-unavailable", ref)
    source_revision = document.get("source_revision")
    authority = require_object(document.get("authority"), f"{ref}.authority")
    home_set = require_object(document.get("home_set"), f"{ref}.home_set")
    if (
        not isinstance(source_revision, str)
        or GIT_OID.fullmatch(source_revision) is None
        or authority.get("default_revision") != source_revision
        or home_set.get("source_revision") != source_revision
    ):
        raise AdapterError("legacy-inventory-unavailable", ref)
    if home_set.get("contract_version") != "workbench-legacy-home-set/v1":
        raise AdapterError("legacy-inventory-unavailable", ref)
    if not isinstance(home_set.get("digest"), str) or SHA256.fullmatch(home_set["digest"]) is None:
        raise AdapterError("legacy-inventory-unavailable", ref)
    blockers = require_array(document.get("blockers"), f"{ref}.blockers")
    if status != 0 or document.get("complete") is not True or blockers:
        raise AdapterError("legacy-inventory-unavailable", ref)

    homes = require_array(document.get("homes"), f"{ref}.homes")
    active: list[dict[str, Any]] = []
    identities: set[tuple[str, str]] = set()
    home_names: list[str] = []
    for home_value in homes:
        home = require_object(home_value, f"{ref}.homes[]")
        home_name = home.get("home")
        if not isinstance(home_name, str) or not home_name:
            raise AdapterError("legacy-inventory-unavailable", ref)
        home_names.append(home_name)
        pagination = require_object(home.get("pagination"), f"{ref}.pagination")
        if pagination.get("complete") is not True or pagination.get("failure") is not None:
            raise AdapterError("legacy-inventory-unavailable", ref)
        claims = require_array(home.get("claims"), f"{ref}.claims")
        claim_ids: list[str] = []
        for claim_value in claims:
            claim = require_object(claim_value, f"{ref}.claim")
            claim_id = claim.get("claim_id")
            if not isinstance(claim_id, str) or not claim_id:
                raise AdapterError("legacy-inventory-unavailable", ref)
            claim_ids.append(claim_id)
            identity = (home_name, claim_id)
            if identity in identities or claim.get("home") != home_name:
                raise AdapterError("legacy-inventory-unavailable", ref)
            identities.add(identity)
            if claim.get("task_contract") != "workbench-task/v1":
                raise AdapterError("legacy-inventory-unavailable", ref)
            if claim.get("classification") not in ("active-v1", "cleaned-v1"):
                raise AdapterError("legacy-inventory-unavailable", ref)
            if claim.get("ancestry_complete") is not True:
                raise AdapterError("legacy-inventory-unavailable", ref)
            if claim["classification"] == "active-v1":
                active.append(
                    {
                        "branch": claim.get("branch"),
                        "claim_id": claim_id,
                        "home": home_name,
                        "issue": claim.get("issue"),
                        "lifecycle_digest": claim.get("lifecycle_digest"),
                        "source_revision": claim.get("source_revision"),
                        "task_claim_id": claim.get("task_claim_id"),
                    }
                )
        if claim_ids != sorted(claim_ids):
            raise AdapterError("legacy-inventory-unavailable", ref)
    if home_names != sorted(home_names):
        raise AdapterError("legacy-inventory-unavailable", ref)
    return active


def inspect_public_kernel(
    workspace: pathlib.Path,
    authority_approval_file: pathlib.Path | None = None,
) -> dict[str, Any]:
    workspace = workspace.resolve()
    binary = resolve_workbench_binary()
    contract, _ = run_public_json(
        binary, ("contract", "show", "--format", "json"), workspace, {0}
    )
    schema = validate_contract(contract, workspace)
    doctor, doctor_status = run_public_json(
        binary, ("doctor", "--format", "json"), workspace, {0, 1}
    )
    validate_doctor(doctor, doctor_status)
    if schema == "workbench/v1":
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
    inventory, inventory_status = run_public_json(
        binary, inventory_argv, workspace, {0, 1}
    )
    active = validate_inventory(inventory, inventory_status)
    return {
        "contract": contract,
        "doctor": doctor,
        "legacy_inventory": inventory,
        "legacy_inventory_command": inventory_command,
        "active_v1_tasks": active,
    }
