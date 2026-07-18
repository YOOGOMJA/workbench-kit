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
validated_plan = suite.validate("upgrade-plan.schema.json", document)
validated_result = suite.validate(
    "upgrade-result.schema.json",
    result_document,
    context={"plan": validated_plan},
)
```

`load_schema_suite()` registers every shipped schema by its canonical `$id` and
installs all workbench-kit format checks. `SchemaSuite.validate()` is the only
runtime-equivalent entry point: it runs JSON Schema validation and the matching
top-level runtime contract validator. Upgrade journal and result documents also
require the exact `{"plan": plan}` context shown above. The
`schema_validator()` and `schema_definition_validator()` methods are structural
schema-authoring tools and must not be used to claim runtime equivalence.

Importing the normal upgrade CLI does not import `jsonschema`; only consumers
of this validator surface need these dependencies.

Validated product documents are normalized to the member order listed by their
contract before canonical serialization and object hashing. Raw JSON member
order is not semantic, so callers must validate and normalize strict contract
objects before calling `canonical_bytes()` or `canonical_digest()`.

In a plugin-equivalence receipt, an `allowed_roots` entry owns either the file
or symlink at that exact path, or the removable nodes strictly below a directory
at that path. Exact leaf roots are required for discovery links such as
`.agents/skills` and `.claude/skills`; sibling state such as
`.claude/settings.json` remains outside the removal surface. Allowed roots and
removable nodes remain path-sorted, collision-free, and ancestor-disjoint, and
every discovery link must be an identical member of `removable_nodes`.
