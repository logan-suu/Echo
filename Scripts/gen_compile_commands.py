#!/usr/bin/env python3
"""Generate compile_commands.json from Xcode build settings for SourceKit-LSP.

Usage: python3 Scripts/gen_compile_commands.py
"""

import json, subprocess, os

project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(project_root)

# Get build settings
result = subprocess.run(
    ["xcodebuild", "-project", "Echo.xcodeproj", "-scheme", "Echo",
     "-destination", "platform=iOS Simulator,name=iPhone 17 Pro",
     "-showBuildSettings"],
    capture_output=True, text=True, timeout=60
)

settings = {}
for line in result.stdout.splitlines():
    line = line.strip()
    if " = " in line:
        k, v = line.split(" = ", 1)
        settings[k.strip()] = v.strip()

sdk = settings.get("SDKROOT", "")
fwk_search = settings.get("FRAMEWORK_SEARCH_PATHS", "")
header_search = settings.get("HEADER_SEARCH_PATHS", "")
build_dir = settings.get("BUILD_DIR", "")
module_cache = settings.get("MODULE_CACHE_DIR", "")

# Find all Swift source files
def find_swift(dirname):
    files = []
    for root, dirs, fs in os.walk(dirname):
        dirs[:] = [d for d in dirs if d not in ("Resources", ".build")]
        for f in fs:
            if f.endswith(".swift"):
                files.append(os.path.join(root, f))
    return files

source_files = find_swift("Echo")
test_files = find_swift("EchoTests")

base_args = [
    "swiftc",
    "-sdk", sdk,
    "-target", "arm64-apple-ios18.0-simulator",
    "-swift-version", "6",
    "-F", fwk_search,
    "-I", header_search,
    f"-I", f"{build_dir}",
    "-module-cache-path", module_cache,
    "-D", "DEBUG",
]

# Whole-module compilation: each entry includes ALL source files of its module
# so SourceKit-LSP can resolve cross-file types (DBValue, DatabaseManager, etc.)
main_args = base_args + source_files
test_args = base_args + test_files + source_files  # tests depend on the main module

entries = []
for sf in source_files:
    entries.append({"directory": project_root, "file": sf, "arguments": main_args})

for tf in test_files:
    entries.append({"directory": project_root, "file": tf, "arguments": test_args})

with open("compile_commands.json", "w") as f:
    json.dump(entries, f, indent=2)

print(f"Generated compile_commands.json: {len(source_files)} main + {len(test_files)} test = {len(entries)} total entries")
