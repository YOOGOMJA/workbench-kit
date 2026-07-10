"""Versioned caller-owned state for the toolbox capability pack."""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import tempfile
from typing import Any


PRODUCT_ID = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
LANGUAGE = re.compile(r"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")


class StateError(Exception):
    """Invalid or unavailable toolbox state."""


def validate_product_id(product_id: str) -> None:
    if len(product_id) > 64 or not PRODUCT_ID.fullmatch(product_id):
        raise StateError(
            "product ID must be lowercase kebab-case, start with a letter, and be at most 64 characters"
        )


def validate_language(language: str) -> None:
    if not LANGUAGE.fullmatch(language):
        raise StateError(f"invalid operational language tag '{language}'")


def plugin_root() -> pathlib.Path:
    raw = os.environ.get("TOOLBOX_PLUGIN_ROOT")
    if not raw:
        raise StateError("TOOLBOX_PLUGIN_ROOT is unavailable")
    return pathlib.Path(raw).resolve()


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise StateError(f"missing state document: {path}") from error
    except json.JSONDecodeError as error:
        raise StateError(f"malformed JSON in {path}: {error.msg}") from error
    if not isinstance(value, dict):
        raise StateError(f"state document must contain an object: {path}")
    return value


def read_template(name: str) -> dict[str, Any]:
    return read_json(plugin_root() / "templates" / f"{name}.json")


def write_json(path: pathlib.Path, document: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(document, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def product_root(workspace: pathlib.Path, product_id: str) -> pathlib.Path:
    validate_product_id(product_id)
    return workspace / "products" / product_id


def initialize_product(
    workspace: pathlib.Path,
    product_id: str,
    name: str,
    language: str,
    objective: str,
) -> pathlib.Path:
    validate_product_id(product_id)
    validate_language(language)
    if not name.strip():
        raise StateError("product name must not be empty")

    target = product_root(workspace, product_id)
    if target.exists():
        raise StateError(f"product '{product_id}' already exists")

    product = read_template("product")
    product.update(
        {
            "id": product_id,
            "name": name,
            "language": language,
            "objective": objective,
        }
    )
    autonomy = read_template("autonomy")
    quality = read_template("quality")

    products_root = target.parent
    products_root.mkdir(parents=True, exist_ok=True)
    temporary = pathlib.Path(tempfile.mkdtemp(prefix=f".{product_id}.", dir=products_root))
    try:
        write_json(temporary / "product.json", product)
        write_json(temporary / "autonomy.json", autonomy)
        write_json(temporary / "quality.json", quality)
        (temporary / "scenarios").mkdir()
        temporary.rename(target)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return target


def load_product(workspace: pathlib.Path, product_id: str) -> dict[str, Any]:
    root = product_root(workspace, product_id)
    if not root.is_dir():
        raise StateError(f"product '{product_id}' does not exist")

    scenarios_root = root / "scenarios"
    if not scenarios_root.is_dir():
        raise StateError(f"missing scenarios directory: {scenarios_root}")

    return {
        "product": read_json(root / "product.json"),
        "autonomy": read_json(root / "autonomy.json"),
        "quality": read_json(root / "quality.json"),
        "scenarios": [read_json(path) for path in sorted(scenarios_root.glob("*.json"))],
    }


def check_product(workspace: pathlib.Path, product_id: str) -> None:
    bundle = load_product(workspace, product_id)
    product = bundle["product"]
    if product.get("schema") != "toolbox-product/v1":
        raise StateError(f"product '{product_id}' has an unsupported schema")
    if product.get("id") != product_id:
        raise StateError(
            f"product directory '{product_id}' does not match document ID '{product.get('id')}'"
        )
    if bundle["autonomy"].get("schema") != "toolbox-autonomy/v1":
        raise StateError(f"product '{product_id}' has an unsupported autonomy schema")
    if bundle["quality"].get("schema") != "toolbox-quality/v1":
        raise StateError(f"product '{product_id}' has an unsupported quality schema")
