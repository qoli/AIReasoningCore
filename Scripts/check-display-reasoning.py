#!/usr/bin/env python3
"""Verify Core with the candidate AnyLanguageModel transcript-reasoning patch.

Creates a disposable source copy; never changes a checkout or its resolution.
Only dependency resolution uses the network. Tests do not call live providers.
"""

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--any-language-model", type=pathlib.Path, required=True)
    parser.add_argument("--ios", action="store_true", help="also build for iOS Simulator")
    args = parser.parse_args()
    core = pathlib.Path(__file__).resolve().parents[1]
    upstream = args.any_language_model.resolve()
    manifest, count = re.subn(
        r'\.package\(\s*url:\s*"https://github.com/qoli/AnyLanguageModel.git",\s*branch:\s*"main"\s*\)',
        lambda _: f'.package(name: "AnyLanguageModel", path: {json.dumps(str(upstream))})',
        (core / "Package.swift").read_text(),
    )
    if count != 1:
        raise SystemExit("expected one remote AnyLanguageModel/main dependency")
    # Retain logs and the exact resolved provider revision for review.
    root = pathlib.Path(tempfile.mkdtemp(prefix="core-transcript-reasoning-"))
    print(f"Integration evidence: {root}", flush=True)
    (root / "Package.swift").write_text(manifest)
    for directory in ("Sources", "Tests"):
        shutil.copytree(core / directory, root / directory)
    commands = [["swift", "test"]]
    if args.ios:
        commands.append([
            "xcodebuild", "-scheme", "AIReasoningCore",
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", str(root / "DerivedData"), "build",
        ])
    for index, command in enumerate(commands):
        with (root / f"verification-{index}.log").open("w") as log:
            result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT)
        print(f"{command[0]} exit: {result.returncode}", flush=True)
        if result.returncode:
            return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
