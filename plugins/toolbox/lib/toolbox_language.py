"""Deterministic validation for the supported ASCII BCP 47 subset."""

from __future__ import annotations

from typing import Any


GRANDFATHERED = {
    "art-lojban",
    "cel-gaulish",
    "en-gb-oed",
    "i-ami",
    "i-bnn",
    "i-default",
    "i-enochian",
    "i-hak",
    "i-klingon",
    "i-lux",
    "i-mingo",
    "i-navajo",
    "i-pwn",
    "i-tao",
    "i-tay",
    "i-tsu",
    "no-bok",
    "no-nyn",
    "sgn-be-fr",
    "sgn-be-nl",
    "sgn-ch-de",
    "zh-guoyu",
    "zh-hakka",
    "zh-min",
    "zh-min-nan",
    "zh-xiang",
}


def is_ascii_alnum(value: str) -> bool:
    return value.isascii() and value.isalnum()


def is_language_tag(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value) > 255 or not value.isascii():
        return False
    if value.lower() in GRANDFATHERED:
        return True

    parts = value.split("-")
    if any(not part for part in parts):
        return False
    if parts[0].lower() == "x":
        return len(parts) > 1 and all(
            1 <= len(part) <= 8 and is_ascii_alnum(part) for part in parts[1:]
        )

    language = parts[0]
    if not 2 <= len(language) <= 8 or not language.isascii() or not language.isalpha():
        return False
    index = 1

    if len(language) <= 3:
        extlang_count = 0
        while (
            index < len(parts)
            and extlang_count < 3
            and len(parts[index]) == 3
            and parts[index].isascii()
            and parts[index].isalpha()
        ):
            index += 1
            extlang_count += 1

    if (
        index < len(parts)
        and len(parts[index]) == 4
        and parts[index].isascii()
        and parts[index].isalpha()
    ):
        index += 1

    if index < len(parts) and (
        (len(parts[index]) == 2 and parts[index].isascii() and parts[index].isalpha())
        or (len(parts[index]) == 3 and parts[index].isascii() and parts[index].isdigit())
    ):
        index += 1

    variants = set()
    while index < len(parts):
        part = parts[index]
        is_variant = (
            5 <= len(part) <= 8 and is_ascii_alnum(part)
        ) or (
            len(part) == 4 and part[0].isascii() and part[0].isdigit() and is_ascii_alnum(part)
        )
        if not is_variant:
            break
        normalized = part.lower()
        if normalized in variants:
            return False
        variants.add(normalized)
        index += 1

    extensions = set()
    while index < len(parts) and len(parts[index]) == 1 and parts[index].lower() != "x":
        singleton = parts[index].lower()
        if not is_ascii_alnum(singleton) or singleton in extensions:
            return False
        extensions.add(singleton)
        index += 1
        start = index
        while (
            index < len(parts)
            and 2 <= len(parts[index]) <= 8
            and is_ascii_alnum(parts[index])
        ):
            index += 1
        if index == start:
            return False

    if index < len(parts) and parts[index].lower() == "x":
        index += 1
        start = index
        while (
            index < len(parts)
            and 1 <= len(parts[index]) <= 8
            and is_ascii_alnum(parts[index])
        ):
            index += 1
        if index == start:
            return False

    return index == len(parts)
