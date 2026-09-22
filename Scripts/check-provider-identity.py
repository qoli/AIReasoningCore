#!/usr/bin/env python3
"""Run the real Core/provider boundary offline using an isolated Core source copy.

Only SwiftPM dependency resolution may use the network. The test transport uses
sanitized checked-in frames and dummy credentials. Neither checkout is edited.
This proves local integration, not publication or remote-main acceptance.
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pi", type=pathlib.Path, required=True)
    args = parser.parse_args()
    core = pathlib.Path(__file__).resolve().parents[1]
    repo = args.pi.resolve()
    manifest = (core / "Package.swift").read_text()
    pattern = r'\.package\(\s*url:\s*"https://github.com/qoli/pi-ai-swift.git",\s*branch:\s*"main"\s*\)'
    manifest, count = re.subn(
        pattern, lambda _: f'.package(name: "pi-ai-swift", path: {json.dumps(str(repo), ensure_ascii=False)})', manifest
    )
    if count != 1:
        raise SystemExit("expected exactly one pi-ai-swift/main dependency in Core manifest")
    with tempfile.TemporaryDirectory(prefix="pi-consumer-identity-") as temporary:
        root = pathlib.Path(temporary)
        (root / "Package.swift").write_text(manifest)
        shutil.copyfile(core / "Package.resolved", root / "Package.resolved")
        shutil.copytree(core / "Sources", root / "Sources")
        tests = root / "Tests/AIReasoningCoreTests"
        tests.mkdir(parents=True)
        shutil.copyfile(
            core / "IntegrationTests/ProviderIdentity/ConsumerResponseIdentityTests.swift",
            tests / "ConsumerResponseIdentityTests.swift",
        )
        environment = dict(os.environ)
        environment["PI_IDENTITY_FIXTURE_PATH"] = str(
            repo / "Fixtures/Differential/Cases/response-rich.json"
        )
        return subprocess.run(
            ["swift", "test", "--skip-update", "--package-path", str(root),
             "--scratch-path", str(core / ".build/consumer-identity"),
             "--filter", "ConsumerResponseIdentityTests"],
            env=environment,
        ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
