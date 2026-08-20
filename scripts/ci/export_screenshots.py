#!/usr/bin/env python3
"""Pull the UI-test screenshots out of an .xcresult bundle as plain PNG files.

The bundle already goes up as a CI artifact, but opening one needs Xcode. Nobody reviewing a pull
request from a phone is going to do that, so the pictures are also emitted as ordinary files.

Two extraction routes are tried, in order, because `xcresulttool`'s interface has changed across
Xcode releases and this repository pins only 16.4 today:

1. `xcresulttool export attachments`, if the installed tool advertises it.
2. The legacy object graph, walked by hand.

This is a convenience layer and it never fails the build. The gate is the assertions inside the
tests; a missing PNG means the reviewer opens the .xcresult, not that the app is broken.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterator


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, text=True, check=False)


def supports_export_attachments() -> bool:
    """Ask the installed tool instead of assuming a version."""
    probe = run(["xcrun", "xcresulttool", "export", "attachments", "--help"])
    return probe.returncode == 0


def export_via_modern(xcresult: Path, output: Path) -> int:
    result = run(
        [
            "xcrun", "xcresulttool", "export", "attachments",
            "--path", str(xcresult),
            "--output-path", str(output),
        ]
    )
    if result.returncode != 0:
        print(f"  export attachments failed: {result.stderr.strip()[:400]}", file=sys.stderr)
        return 0
    return rename_from_manifest(output)


def rename_from_manifest(output: Path) -> int:
    """Give the exported files their attachment names, if a manifest says what those were."""
    manifests = list(output.rglob("manifest.json")) + list(output.rglob("manifest.plist"))
    renamed = 0
    for manifest_path in manifests:
        try:
            if manifest_path.suffix == ".json":
                payload = json.loads(manifest_path.read_text())
            else:
                payload = plistlib.loads(manifest_path.read_bytes())
        except (json.JSONDecodeError, plistlib.InvalidFileException, OSError, ValueError):
            continue
        for entry in walk_manifest(payload):
            exported = entry.get("exportedFileName")
            suggested = entry.get("suggestedHumanReadableName") or entry.get("name")
            if not exported or not suggested:
                continue
            source = manifest_path.parent / exported
            if not source.is_file():
                continue
            target = manifest_path.parent / safe_name(suggested, Path(exported).suffix)
            if source != target and not target.exists():
                source.rename(target)
                renamed += 1
    return renamed


def walk_manifest(payload: Any) -> Iterator[dict[str, Any]]:
    if isinstance(payload, dict):
        if "exportedFileName" in payload:
            yield payload
        for value in payload.values():
            yield from walk_manifest(value)
    elif isinstance(payload, list):
        for item in payload:
            yield from walk_manifest(item)


def safe_name(name: str, suffix: str) -> str:
    keep = "".join(character if character.isalnum() or character in "-_." else "-" for character in name)
    keep = keep.strip("-") or "screenshot"
    if not keep.lower().endswith(suffix.lower()):
        keep += suffix
    return keep[:120]


# --- Legacy route -----------------------------------------------------------------------------


def legacy_get(xcresult: Path, identifier: str | None = None) -> Any:
    command = [
        "xcrun", "xcresulttool", "get", "--legacy",
        "--format", "json",
        "--path", str(xcresult),
    ]
    if identifier:
        command += ["--id", identifier]
    result = run(command)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def values(node: Any, key: str) -> list[Any]:
    child = (node or {}).get(key) or {}
    return child.get("_values", []) if isinstance(child, dict) else []


def scalar(node: Any, key: str) -> str | None:
    child = (node or {}).get(key)
    if isinstance(child, dict):
        value = child.get("_value")
        return str(value) if value is not None else None
    return None


def collect_summary_refs(node: Any, found: list[str]) -> None:
    """Test nodes nest arbitrarily deep; each leaf may carry a summaryRef."""
    if isinstance(node, dict):
        reference = node.get("summaryRef")
        if isinstance(reference, dict):
            identifier = scalar(reference, "id")
            if identifier:
                found.append(identifier)
        for value in node.values():
            collect_summary_refs(value, found)
    elif isinstance(node, list):
        for item in node:
            collect_summary_refs(item, found)


def collect_attachments(node: Any, found: list[tuple[str, str]]) -> None:
    if isinstance(node, dict):
        if "payloadRef" in node:
            identifier = scalar(node.get("payloadRef"), "id")
            name = scalar(node, "name") or scalar(node, "filename") or "screenshot"
            if identifier:
                found.append((identifier, name))
        for value in node.values():
            collect_attachments(value, found)
    elif isinstance(node, list):
        for item in node:
            collect_attachments(item, found)


def export_via_legacy(xcresult: Path, output: Path) -> int:
    root = legacy_get(xcresult)
    if root is None:
        print("  legacy xcresulttool is unavailable too", file=sys.stderr)
        return 0

    tests_refs = [
        scalar((action.get("actionResult") or {}).get("testsRef"), "id")
        for action in values(root, "actions")
    ]

    summary_refs: list[str] = []
    for tests_ref in filter(None, tests_refs):
        collect_summary_refs(legacy_get(xcresult, tests_ref), summary_refs)

    attachments: list[tuple[str, str]] = []
    for summary_ref in dict.fromkeys(summary_refs):
        collect_attachments(legacy_get(xcresult, summary_ref), attachments)

    written = 0
    for index, (identifier, name) in enumerate(attachments):
        destination = output / f"{index:02d}-{safe_name(name, '.png')}"
        result = run(
            [
                "xcrun", "xcresulttool", "export", "--legacy",
                "--type", "file",
                "--path", str(xcresult),
                "--id", identifier,
                "--output-path", str(destination),
            ]
        )
        if result.returncode == 0 and destination.is_file():
            written += 1
    return written


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xcresult", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()

    if not arguments.xcresult.exists():
        print(f"No result bundle at {arguments.xcresult}; nothing to export.")
        return 0

    if arguments.output.exists():
        shutil.rmtree(arguments.output)
    arguments.output.mkdir(parents=True, exist_ok=True)

    if supports_export_attachments():
        print("Using: xcresulttool export attachments")
        export_via_modern(arguments.xcresult, arguments.output)
    else:
        print("xcresulttool has no 'export attachments'; walking the legacy object graph")
        export_via_legacy(arguments.xcresult, arguments.output)

    images = sorted(
        path for path in arguments.output.rglob("*")
        if path.is_file() and path.suffix.lower() in {".png", ".jpg", ".jpeg", ".heic"}
    )
    if not images:
        # The artifact upload is configured to fail on an empty path, and an extraction hiccup must
        # not turn a green build red. Leave a note saying so rather than nothing at all.
        (arguments.output / "NO-SCREENSHOTS.txt").write_text(
            "xcresulttool extracted no attachments from this run.\n"
            "The .xcresult bundle in this same artifact still holds them; open it in Xcode.\n"
        )
        print("No screenshots were extracted. The .xcresult bundle is still uploaded intact.")
        return 0

    print(f"Extracted {len(images)} screenshot(s):")
    for image in images:
        print(f"  {image.relative_to(arguments.output)}  ({image.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
