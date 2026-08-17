#!/usr/bin/env python3
"""Generate a safely escaped ExportOptions.plist for a manual-signing export."""

from __future__ import annotations

import argparse
import pathlib
import plistlib


SUPPORTED_METHODS = ("development", "ad-hoc")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--method", choices=SUPPORTED_METHODS, required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--profile-name", required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    options = {
        "destination": "export",
        "method": arguments.method,
        "provisioningProfiles": {
            arguments.bundle_id: arguments.profile_name,
        },
        "signingStyle": "manual",
        "stripSwiftSymbols": True,
        "teamID": arguments.team_id,
    }

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("wb") as output_file:
        plistlib.dump(options, output_file, fmt=plistlib.FMT_XML, sort_keys=True)


if __name__ == "__main__":
    main()
