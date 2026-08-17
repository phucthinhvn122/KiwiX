#!/usr/bin/env python3
"""Select a usable iPhone from `xcrun simctl list devices available --json`."""

from __future__ import annotations

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


def select_device(payload: dict[str, Any]) -> dict[str, Any]:
    candidates: list[tuple[tuple[int, ...], int, dict[str, Any]]] = []

    for runtime, devices in payload.get("devices", {}).items():
        version = runtime_version(runtime)
        if not version:
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
        payload = json.load(sys.stdin)
        device = select_device(payload)
        udid = device.get("udid")
        if not udid:
            raise RuntimeError("Selected simulator has no UDID")
        print(udid)
        return 0
    except (json.JSONDecodeError, RuntimeError, TypeError) as error:
        print(f"simulator selection failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
