#!/usr/bin/env python3
"""Select a usable iPhone from `xcrun simctl list devices available --json`."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


PREFERRED_NAMES = (
    "iPhone 17 Pro",
    "iPhone 17",
    "iPhone 16 Pro",
    "iPhone 16",
    "iPhone 15 Pro",
    "iPhone 15",
)


def runtime_version(runtime: str) -> tuple[int, ...]:
    match = re.search(r"iOS[- ](\d+(?:[-.]\d+)*)", runtime)
    if match is None:
        return ()
    return tuple(int(part) for part in re.split(r"[-.]", match.group(1)))


def parse_version(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(?:\.\d+)*", value):
        raise ValueError(f"invalid runtime version: {value}")
    return tuple(int(part) for part in value.split("."))


def select_device(
    payload: dict[str, Any],
    maximum_runtime: tuple[int, ...] | None = None,
) -> dict[str, Any]:
    candidates: list[tuple[tuple[int, ...], int, dict[str, Any]]] = []

    for runtime, devices in payload.get("devices", {}).items():
        version = runtime_version(runtime)
        if not version:
            continue
        if maximum_runtime is not None and version > maximum_runtime:
            continue
        for device in devices:
            name = str(device.get("name", ""))
            if not name.startswith("iPhone") or not device.get("isAvailable", True):
                continue
            preference = len(PREFERRED_NAMES)
            if name in PREFERRED_NAMES:
                preference = PREFERRED_NAMES.index(name)
            candidates.append((version, -preference, device))

    if not candidates:
        raise RuntimeError("No available iPhone Simulator runtime was found")

    # Highest iOS runtime wins, then the most preferred phone on that runtime.
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    return candidates[0][2]


def main() -> int:
    try:
        parser = argparse.ArgumentParser()
        parser.add_argument(
            "--maximum-runtime",
            type=parse_version,
            help="Highest iOS runtime compatible with the selected Xcode SDK (for example 18.5)",
        )
        arguments = parser.parse_args()
        payload = json.load(sys.stdin)
        device = select_device(payload, maximum_runtime=arguments.maximum_runtime)
        udid = device.get("udid")
        if not udid:
            raise RuntimeError("Selected simulator has no UDID")
        print(udid)
        return 0
    except (json.JSONDecodeError, RuntimeError, TypeError, ValueError) as error:
        print(f"simulator selection failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
