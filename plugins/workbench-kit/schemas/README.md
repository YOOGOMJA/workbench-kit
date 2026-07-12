# Workbench Kit JSON Schema Validation

The published schemas use Draft 2020-12 plus the `canonical-base64`, `nfc`, and
`reviewed-overlay-content` formats. Standard validators treat `format` as an
annotation unless configured, so consumers that need runtime-equivalent
validation must use the packaged validator surface.

Run with the pinned product dependencies:

```sh
PYTHONPATH=lib uv run --with-requirements schemas/requirements.txt python3 validate.py
```

```python
from pathlib import Path

from workbench_kit_schema import load_schema_suite

suite = load_schema_suite(Path("schemas"))
validator = suite.validator("upgrade-plan.schema.json")
errors = list(validator.iter_errors(document))
```

`load_schema_suite()` registers every shipped schema by its canonical `$id` and
installs all workbench-kit format checks. Importing the normal upgrade CLI does
not import `jsonschema`; only consumers of this validator surface need these
dependencies.
