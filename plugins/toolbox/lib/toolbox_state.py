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


def schema_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    return False


def child_path(path: str, key: str) -> str:
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
        return f"{path}.{key}"
    return f"{path}[{json.dumps(key)}]"


def validate_schema(value: Any, schema: dict[str, Any], path: str = "$") -> None:
    if "const" in schema and value != schema["const"]:
        raise StateError(f"{path} must equal {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        choices = ", ".join(str(item) for item in schema["enum"])
        raise StateError(f"{path} must be one of: {choices}")

    expected_type = schema.get("type")
    if expected_type and not schema_type_matches(value, expected_type):
        raise StateError(f"{path} must be a {expected_type}")

    if isinstance(value, dict):
        required = schema.get("required", [])
        for field in required:
            if field not in value:
                raise StateError(f"{path} is missing required field '{field}'")

        properties = schema.get("properties", {})
        property_names = schema.get("propertyNames")
        additional = schema.get("additionalProperties", True)
        for key, item in value.items():
            item_path = child_path(path, key)
            if property_names:
                validate_schema(key, property_names, f"{item_path} key")
            if key in properties:
                validate_schema(item, properties[key], item_path)
            elif additional is False:
                raise StateError(f"{path} contains unknown field '{key}'")
            elif isinstance(additional, dict):
                validate_schema(item, additional, item_path)

    if isinstance(value, list):
        minimum_items = schema.get("minItems")
        if isinstance(minimum_items, int) and len(value) < minimum_items:
            raise StateError(f"{path} must contain at least {minimum_items} item(s)")
        if schema.get("uniqueItems"):
            rendered = [json.dumps(item, sort_keys=True) for item in value]
            if len(rendered) != len(set(rendered)):
                raise StateError(f"{path} must contain unique items")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(value):
                validate_schema(item, item_schema, f"{path}[{index}]")

    if isinstance(value, str):
        minimum_length = schema.get("minLength")
        maximum_length = schema.get("maxLength")
        if isinstance(minimum_length, int) and len(value) < minimum_length:
            raise StateError(f"{path} must be at least {minimum_length} character(s)")
        if isinstance(maximum_length, int) and len(value) > maximum_length:
            raise StateError(f"{path} must be at most {maximum_length} character(s)")
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and re.fullmatch(pattern, value) is None:
            raise StateError(f"{path} must match pattern {pattern}")

    if isinstance(value, int) and not isinstance(value, bool):
        minimum = schema.get("minimum")
        if isinstance(minimum, int) and value < minimum:
            raise StateError(f"{path} must be at least {minimum}")


def validate_document(kind: str, document: dict[str, Any]) -> None:
    schema = read_json(plugin_root() / "schemas" / f"{kind}.schema.json")
    validate_schema(document, schema)


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
    validate_document("product", product)
    validate_document("autonomy", bundle["autonomy"])
    validate_document("quality", bundle["quality"])
    for scenario in bundle["scenarios"]:
        validate_document("scenario", scenario)

    if product.get("id") != product_id:
        raise StateError(
            f"product directory '{product_id}' does not match document ID '{product.get('id')}'"
        )

    repository_ids = [item["id"] for item in product["repositories"]]
    if len(repository_ids) != len(set(repository_ids)):
        raise StateError(f"product '{product_id}' contains duplicate repository IDs")

    check_ids = [item["id"] for item in bundle["quality"]["checks"]]
    if len(check_ids) != len(set(check_ids)):
        raise StateError(f"product '{product_id}' contains duplicate quality check IDs")

    local_scenario_ids: set[str] = set()
    for scenario in bundle["scenarios"]:
        if scenario["productId"] != product_id:
            raise StateError(
                f"scenario '{scenario['id']}' belongs to product '{scenario['productId']}', not '{product_id}'"
            )
        if scenario["id"] in local_scenario_ids:
            raise StateError(f"duplicate scenario ID '{scenario['id']}'")
        local_scenario_ids.add(scenario["id"])


def load_portfolio(workspace: pathlib.Path) -> dict[str, Any]:
    products_root = workspace / "products"
    if not products_root.exists():
        return {"products": []}
    if not products_root.is_dir():
        raise StateError(f"product state root is not a directory: {products_root}")

    products = []
    product_ids: set[str] = set()
    for path in sorted(products_root.iterdir(), key=lambda item: item.name):
        if path.name.startswith("."):
            continue
        if not path.is_dir():
            raise StateError(f"unexpected file in product state root: {path}")
        bundle = load_product(workspace, path.name)
        validate_document("product", bundle["product"])
        document_id = bundle["product"]["id"]
        if document_id in product_ids:
            raise StateError(f"duplicate product ID '{document_id}'")
        product_ids.add(document_id)
        if document_id != path.name:
            raise StateError(
                f"product directory '{path.name}' does not match document ID '{document_id}'"
            )
        products.append(bundle)
    return {"products": products}


def scenario_index(portfolio: dict[str, Any]) -> dict[str, tuple[str, dict[str, Any]]]:
    index: dict[str, tuple[str, dict[str, Any]]] = {}
    for bundle in portfolio["products"]:
        product_id = bundle["product"]["id"]
        for scenario in bundle["scenarios"]:
            scenario_id = scenario["id"]
            if scenario_id in index:
                raise StateError(f"duplicate scenario ID '{scenario_id}'")
            index[scenario_id] = (product_id, scenario)
    return index


def check_dependency_graph(index: dict[str, tuple[str, dict[str, Any]]]) -> None:
    for scenario_id, (_, scenario) in index.items():
        for dependency in scenario["dependsOn"]:
            if dependency not in index:
                raise StateError(
                    f"scenario '{scenario_id}' depends on unknown scenario '{dependency}'"
                )

    visiting: list[str] = []
    visited: set[str] = set()

    def visit(scenario_id: str) -> None:
        if scenario_id in visited:
            return
        if scenario_id in visiting:
            start = visiting.index(scenario_id)
            cycle = visiting[start:] + [scenario_id]
            raise StateError(f"scenario dependency cycle: {' -> '.join(cycle)}")
        visiting.append(scenario_id)
        for dependency in index[scenario_id][1]["dependsOn"]:
            visit(dependency)
        visiting.pop()
        visited.add(scenario_id)

    for scenario_id in sorted(index):
        visit(scenario_id)


def check_portfolio(workspace: pathlib.Path) -> tuple[dict[str, Any], dict[str, tuple[str, dict[str, Any]]]]:
    portfolio = load_portfolio(workspace)
    for bundle in portfolio["products"]:
        product_id = bundle["product"].get("id")
        if not isinstance(product_id, str):
            validate_document("product", bundle["product"])
        check_product(workspace, bundle["product"]["id"])
    index = scenario_index(portfolio)
    check_dependency_graph(index)
    return portfolio, index


def find_scenario(
    workspace: pathlib.Path, scenario_id: str
) -> tuple[str, dict[str, Any]]:
    _, index = check_portfolio(workspace)
    try:
        return index[scenario_id]
    except KeyError as error:
        raise StateError(f"scenario '{scenario_id}' does not exist") from error


def candidate_scenarios(
    workspace: pathlib.Path, product_filter: str | None = None
) -> list[dict[str, Any]]:
    _, index = check_portfolio(workspace)
    if product_filter is not None:
        validate_product_id(product_filter)

    candidates = []
    for scenario_id, (product_id, scenario) in index.items():
        if scenario["status"] != "ready":
            continue
        if product_filter is not None and product_id != product_filter:
            continue
        if not all(index[dependency][1]["status"] == "completed" for dependency in scenario["dependsOn"]):
            continue
        candidates.append(
            {
                "priority": scenario["priority"],
                "product_id": product_id,
                "product_ref": f"toolbox:product/{product_id}",
                "scenario_id": scenario_id,
                "scenario_ref": f"toolbox:scenario/{scenario_id}",
                "title": scenario["title"],
            }
        )
    return sorted(
        candidates,
        key=lambda item: (item["priority"], item["product_id"], item["scenario_id"]),
    )
