"""Strict JSON primitives shared by workbench-kit migration contracts."""

from __future__ import annotations

import json
from typing import Any


class DuplicateJsonMember(ValueError):
    def __init__(self, member: str) -> None:
        super().__init__(member)
        self.member = member


class InvalidJsonConstant(ValueError):
    def __init__(self, constant: str) -> None:
        super().__init__(constant)
        self.constant = constant


def strict_json_loads(payload: str) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise DuplicateJsonMember(key)
            result[key] = value
        return result

    def reject_constant(value: str) -> Any:
        raise InvalidJsonConstant(value)

    return json.loads(
        payload,
        object_pairs_hook=reject_duplicates,
        parse_constant=reject_constant,
    )
