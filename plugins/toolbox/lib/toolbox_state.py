"""Versioned caller-owned state for the toolbox capability pack."""

from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import stat
import tempfile
from typing import Any

from toolbox_json import DuplicateJsonMember, InvalidJsonConstant, strict_json_loads
from toolbox_language import is_language_tag


PRODUCT_ID = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")


class StateError(Exception):
    """Invalid or unavailable toolbox state."""


def validate_product_id(product_id: str) -> None:
    if len(product_id) > 64 or not PRODUCT_ID.fullmatch(product_id):
        raise StateError(
            "product ID must be lowercase kebab-case, start with a letter, and be at most 64 characters"
        )


def validate_language(language: str) -> None:
    if not is_language_tag(language):
        raise StateError(f"invalid operational language tag '{language}'")


def plugin_root() -> pathlib.Path:
    raw = os.environ.get("TOOLBOX_PLUGIN_ROOT")
    if not raw:
        raise StateError("TOOLBOX_PLUGIN_ROOT is unavailable")
    return pathlib.Path(raw).resolve()


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = strict_json_loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise StateError(f"missing state document: {path}") from error
    except UnicodeDecodeError as error:
        raise StateError(f"state document is not valid UTF-8: {path}") from error
    except DuplicateJsonMember as error:
        raise StateError(f"duplicate JSON member '{error.member}' in {path}") from error
    except InvalidJsonConstant as error:
        raise StateError(f"invalid JSON constant '{error.constant}' in {path}") from error
    except json.JSONDecodeError as error:
        raise StateError(f"malformed JSON in {path}: {error.msg}") from error
    except OSError as error:
        diagnostic = error.strerror or type(error).__name__
        raise StateError(f"unable to read state document {path}: {diagnostic}") from error
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
    try:
        path.write_text(
            json.dumps(document, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    except OSError as error:
        diagnostic = error.strerror or type(error).__name__
        raise StateError(f"unable to write state document {path}: {diagnostic}") from error


def atomic_replace_json(
    workspace: pathlib.Path, path: pathlib.Path, document: dict[str, Any]
) -> None:
    """Replace one caller-owned JSON document without exposing a partial write."""
    target = safe_state_path(workspace, path, "state document")
    parent = safe_state_path(workspace, target.parent, "state document directory")
    if not parent.is_dir():
        raise StateError(f"state document directory does not exist: {parent}")

    descriptor = -1
    temporary: pathlib.Path | None = None
    try:
        descriptor, raw_temporary = tempfile.mkstemp(
            prefix=f".{target.name}.", suffix=".tmp", dir=parent
        )
        temporary = pathlib.Path(raw_temporary)
        safe_state_path(workspace, temporary, "temporary state document")
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            descriptor = -1
            json.dump(document, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        temporary = None
        if hasattr(os, "O_DIRECTORY"):
            directory_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
    except OSError as error:
        diagnostic = error.strerror or type(error).__name__
        raise StateError(f"unable to replace state document {target}: {diagnostic}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                pass


def product_root(workspace: pathlib.Path, product_id: str) -> pathlib.Path:
    validate_product_id(product_id)
    return workspace / "products" / product_id


def safe_state_path(
    workspace: pathlib.Path,
    path: pathlib.Path,
    label: str = "state path",
) -> pathlib.Path:
    try:
        workspace_root = workspace.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise StateError(f"unable to resolve caller workspace: {workspace}") from error

    try:
        relative = path.relative_to(workspace_root)
    except ValueError as error:
        raise StateError(f"{label} escapes caller workspace: {path}") from error

    current = workspace_root
    for component in relative.parts:
        current = current / component
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            break
        except OSError as error:
            diagnostic = error.strerror or type(error).__name__
            raise StateError(f"unable to inspect {label} {current}: {diagnostic}") from error
        if stat.S_ISLNK(mode):
            raise StateError(f"{label} must not be a symbolic link: {current}")

    try:
        resolved = path.resolve(strict=False)
    except (OSError, RuntimeError) as error:
        raise StateError(f"unable to resolve {label}: {path}") from error
    if resolved != workspace_root and workspace_root not in resolved.parents:
        raise StateError(f"{label} escapes caller workspace: {path}")
    return path


def safe_products_root(workspace: pathlib.Path) -> pathlib.Path:
    root = safe_state_path(workspace, workspace / "products", "product state root")
    return root


def scenario_paths(workspace: pathlib.Path, product_id: str) -> list[pathlib.Path]:
    scenarios_root = safe_state_path(
        workspace,
        product_root(workspace, product_id) / "scenarios",
        "scenario state directory",
    )
    try:
        with os.scandir(scenarios_root) as entries:
            paths = sorted(
                (
                    scenarios_root / entry.name
                    for entry in entries
                    if entry.name.endswith(".json")
                ),
                key=lambda path: path.name,
            )
    except OSError as error:
        diagnostic = error.strerror or type(error).__name__
        raise StateError(
            f"unable to traverse scenario state directory {scenarios_root}: {diagnostic}"
        ) from error
    return [safe_state_path(workspace, path, "scenario state document") for path in paths]


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

    products_root = safe_products_root(workspace)
    target = safe_state_path(
        workspace, products_root / product_id, "product state directory"
    )
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
    validate_document("product", product)
    validate_document("autonomy", autonomy)
    validate_document("quality", quality)

    temporary = None
    try:
        products_root.mkdir(parents=True, exist_ok=True)
        safe_products_root(workspace)
        temporary = pathlib.Path(
            tempfile.mkdtemp(prefix=f".{product_id}.", dir=products_root)
        )
        safe_state_path(workspace, temporary, "temporary product state directory")
        product_path = safe_state_path(
            workspace, temporary / "product.json", "product state document"
        )
        autonomy_path = safe_state_path(
            workspace, temporary / "autonomy.json", "autonomy state document"
        )
        quality_path = safe_state_path(
            workspace, temporary / "quality.json", "quality state document"
        )
        scenarios_root = safe_state_path(
            workspace, temporary / "scenarios", "scenario state directory"
        )
        write_json(product_path, product)
        write_json(autonomy_path, autonomy)
        write_json(quality_path, quality)
        scenarios_root.mkdir()
        safe_state_path(workspace, scenarios_root, "scenario state directory")
        safe_state_path(workspace, target, "product state directory")
        temporary.rename(target)
    except StateError:
        if temporary is not None:
            shutil.rmtree(temporary, ignore_errors=True)
        raise
    except OSError as error:
        if temporary is not None:
            shutil.rmtree(temporary, ignore_errors=True)
        diagnostic = error.strerror or type(error).__name__
        raise StateError(
            f"unable to initialize product state '{product_id}': {diagnostic}"
        ) from error
    except Exception:
        if temporary is not None:
            shutil.rmtree(temporary, ignore_errors=True)
        raise
    return target


def load_product(workspace: pathlib.Path, product_id: str) -> dict[str, Any]:
    safe_products_root(workspace)
    root = safe_state_path(
        workspace, product_root(workspace, product_id), "product state directory"
    )
    if not root.is_dir():
        raise StateError(f"product '{product_id}' does not exist")

    scenarios_root = safe_state_path(
        workspace, root / "scenarios", "scenario state directory"
    )
    if not scenarios_root.is_dir():
        raise StateError(f"missing scenarios directory: {scenarios_root}")

    product_path = safe_state_path(
        workspace, root / "product.json", "product state document"
    )
    autonomy_path = safe_state_path(
        workspace, root / "autonomy.json", "autonomy state document"
    )
    quality_path = safe_state_path(
        workspace, root / "quality.json", "quality state document"
    )
    scenarios = scenario_paths(workspace, product_id)

    return {
        "product": read_json(product_path),
        "autonomy": read_json(autonomy_path),
        "quality": read_json(quality_path),
        "scenarios": [read_json(path) for path in scenarios],
    }


def check_product(workspace: pathlib.Path, product_id: str) -> None:
    bundle = load_product(workspace, product_id)
    validate_product_bundle(product_id, bundle)
    paths = scenario_paths(workspace, product_id)
    for path, scenario in zip(paths, bundle["scenarios"]):
        expected_name = f"{scenario['id']}.json"
        if path.name != expected_name:
            raise StateError(
                f"scenario file '{path.name}' must be named '{expected_name}'"
            )


def validate_product_bundle(product_id: str, bundle: dict[str, Any]) -> None:
    product = bundle["product"]
    validate_document("product", product)
    validate_language(product["language"])
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


def validate_repository_path(path: str) -> None:
    candidate = pathlib.PurePosixPath(path)
    if (
        not path
        or candidate.is_absolute()
        or ".." in candidate.parts
        or "." in candidate.parts
        or str(candidate) != path
    ):
        raise StateError("repository path must be workspace-relative and normalized")


def set_repository(
    workspace: pathlib.Path,
    product_id: str,
    repository_id: str,
    path: str,
    role: str,
) -> tuple[bool, dict[str, Any]]:
    validate_product_id(repository_id)
    validate_repository_path(path)
    bundle = load_product(workspace, product_id)
    validate_product_bundle(product_id, bundle)
    repository = {"id": repository_id, "path": path, "role": role}
    repositories = bundle["product"]["repositories"]
    for existing in repositories:
        if existing["path"] == path and existing["id"] != repository_id:
            raise StateError(
                f"repository path '{path}' already belongs to repository '{existing['id']}'"
            )
    existing = next(
        (item for item in repositories if item["id"] == repository_id), None
    )
    if existing == repository:
        return False, repository
    proposed = dict(bundle["product"])
    proposed["repositories"] = sorted(
        [item for item in repositories if item["id"] != repository_id] + [repository],
        key=lambda item: item["id"],
    )
    proposed_bundle = dict(bundle)
    proposed_bundle["product"] = proposed
    validate_product_bundle(product_id, proposed_bundle)
    atomic_replace_json(
        workspace, product_root(workspace, product_id) / "product.json", proposed
    )
    return True, repository


def set_autonomy(
    workspace: pathlib.Path, product_id: str, action_id: str, decision: str
) -> bool:
    bundle = load_product(workspace, product_id)
    validate_product_bundle(product_id, bundle)
    proposed = dict(bundle["autonomy"])
    proposed["actions"] = dict(proposed["actions"])
    if proposed["actions"].get(action_id) == decision:
        return False
    proposed["actions"][action_id] = decision
    proposed["actions"] = dict(sorted(proposed["actions"].items()))
    proposed_bundle = dict(bundle)
    proposed_bundle["autonomy"] = proposed
    validate_product_bundle(product_id, proposed_bundle)
    atomic_replace_json(
        workspace, product_root(workspace, product_id) / "autonomy.json", proposed
    )
    return True


def set_quality_check(
    workspace: pathlib.Path,
    product_id: str,
    check_id: str,
    kind: str,
    required: bool,
    command: list[str],
) -> tuple[bool, dict[str, Any]]:
    validate_product_id(check_id)
    bundle = load_product(workspace, product_id)
    validate_product_bundle(product_id, bundle)
    quality_check = {
        "id": check_id,
        "kind": kind,
        "command": command,
        "required": required,
    }
    checks = bundle["quality"]["checks"]
    existing = next((item for item in checks if item["id"] == check_id), None)
    if existing == quality_check:
        return False, quality_check
    proposed = dict(bundle["quality"])
    proposed["checks"] = sorted(
        [item for item in checks if item["id"] != check_id] + [quality_check],
        key=lambda item: item["id"],
    )
    proposed_bundle = dict(bundle)
    proposed_bundle["quality"] = proposed
    validate_product_bundle(product_id, proposed_bundle)
    atomic_replace_json(
        workspace, product_root(workspace, product_id) / "quality.json", proposed
    )
    return True, quality_check


def apply_scenario(
    workspace: pathlib.Path, product_id: str, source: pathlib.Path
) -> tuple[bool, dict[str, Any]]:
    scenario = read_json(source)
    validate_document("scenario", scenario)
    if scenario["productId"] != product_id:
        raise StateError(
            f"scenario '{scenario['id']}' belongs to product '{scenario['productId']}', not '{product_id}'"
        )

    bundle = load_product(workspace, product_id)
    validate_product_bundle(product_id, bundle)
    existing = next(
        (item for item in bundle["scenarios"] if item["id"] == scenario["id"]), None
    )
    if existing == scenario:
        return False, scenario

    proposed_bundle = dict(bundle)
    proposed_bundle["scenarios"] = sorted(
        [item for item in bundle["scenarios"] if item["id"] != scenario["id"]]
        + [scenario],
        key=lambda item: item["id"],
    )
    validate_product_bundle(product_id, proposed_bundle)

    portfolio = load_portfolio(workspace)
    portfolio["products"] = [
        proposed_bundle if item["product"]["id"] == product_id else item
        for item in portfolio["products"]
    ]
    index = scenario_index(portfolio)
    check_dependency_graph(index)

    target = product_root(workspace, product_id) / "scenarios" / f"{scenario['id']}.json"
    atomic_replace_json(workspace, target, scenario)
    return True, scenario


def load_portfolio(workspace: pathlib.Path) -> dict[str, Any]:
    products_root = safe_products_root(workspace)
    if not products_root.exists():
        return {"products": []}
    if not products_root.is_dir():
        raise StateError(f"product state root is not a directory: {products_root}")

    products = []
    product_ids: set[str] = set()
    try:
        product_paths = sorted(products_root.iterdir(), key=lambda item: item.name)
    except OSError as error:
        diagnostic = error.strerror or type(error).__name__
        raise StateError(
            f"unable to traverse product state root {products_root}: {diagnostic}"
        ) from error
    for path in product_paths:
        if path.name.startswith("."):
            continue
        safe_state_path(workspace, path, "product state directory")
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
