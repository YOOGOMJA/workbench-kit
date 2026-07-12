#!/usr/bin/env python3
"""Shared strict timestamp validation for workbench machine contracts."""

from __future__ import annotations

import datetime
import re
from typing import Any


RFC3339_UTC = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z"
)


def parse_rfc3339_utc(value: Any, field: str) -> datetime.datetime:
    if not isinstance(value, str) or RFC3339_UTC.fullmatch(value) is None:
        raise ValueError("{} must be RFC 3339 UTC".format(field))
    try:
        parsed = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise ValueError("{} must be RFC 3339 UTC".format(field)) from exc
    return parsed.replace(tzinfo=datetime.timezone.utc)


def require_rfc3339_utc(value: Any, field: str) -> str:
    parse_rfc3339_utc(value, field)
    return value
