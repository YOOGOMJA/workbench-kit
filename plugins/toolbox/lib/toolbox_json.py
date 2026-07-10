"""Strict JSON loading shared by public contracts and versioned state."""

from __future__ import annotations

import json
from typing import Any


class DuplicateJsonMember(ValueError):
    """A JSON object declared the same member more than once."""

    def __init__(self, member: str) -> None:
        super().__init__(member)
        self.member = member


class InvalidJsonConstant(ValueError):
    """A JSON payload used a non-finite JavaScript numeric constant."""

    def __init__(self, constant: str) -> None:
        super().__init__(constant)
        self.constant = constant


def strict_json_loads(payload: str) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        document: dict[str, Any] = {}
        for key, value in pairs:
            if key in document:
                raise DuplicateJsonMember(key)
            document[key] = value
        return document

    def reject_constant(constant: str) -> Any:
        raise InvalidJsonConstant(constant)

    return json.loads(
        payload,
        object_pairs_hook=reject_duplicates,
        parse_constant=reject_constant,
    )
