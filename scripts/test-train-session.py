#!/usr/bin/env python3
"""Compile the actual TrainModel and rail sources against a small device stub.

Usage: python3 scripts/test-train-session.py [--swiftc /path/to/swiftc]
Requires Swift 5.9+ (Observation), macOS or Linux. No phone, signing, API token,
or Internet requests are involved. OJP responses are served by URLProtocol.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--swiftc", default=os.environ.get("SWIFTC", "swiftc"))
args = parser.parse_args()
compiler = shutil.which(args.swiftc)
if not compiler:
    parser.error("Swift compiler unavailable; pass --swiftc or set SWIFTC. No test was run.")
root = Path(__file__).resolve().parents[1]
sources = sorted((root / "WrapPin/Features/Train/Core").glob("*.swift"))
sources += [root / "WrapPin/Features/Train/TrainModel.swift",
            root / "Tests/TrainSessionHarness.swift"]
with tempfile.TemporaryDirectory(prefix="wrappin-rail-session-") as directory:
    output = Path(directory) / ("train-session.exe" if os.name == "nt" else "train-session")
    subprocess.run([compiler, "-swift-version", "5", "-D", "WRAPPIN_SBB_EDITION", "-parse-as-library",
                    *map(str, sources), "-o", str(output)], cwd=root, check=True)
    subprocess.run([str(output)], cwd=root, check=True)
