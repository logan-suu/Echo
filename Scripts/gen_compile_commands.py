#!/usr/bin/env python3
"""Generate buildServer.json for SourceKit-LSP via xcode-build-server.

Requires: brew install xcode-build-server
Usage:   python3 Scripts/gen_compile_commands.py

This script delegates to xcode-build-server, which configures SourceKit-LSP
to use the Xcode DerivedData index for cross-file type resolution.
"""

import subprocess, os

project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(project_root)

result = subprocess.run(
    ["xcode-build-server", "config", "-project", "Echo.xcodeproj", "-scheme", "Echo"],
    capture_output=True, text=True
)

if result.returncode != 0:
    print(f"Error: {result.stderr}")
    exit(1)

print(result.stdout.strip())
print("Generated buildServer.json — SourceKit-LSP will use DerivedData index for type resolution.")
