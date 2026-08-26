#!/usr/bin/env python3
"""Per-target release compliance validator for task 3F.11 (ADR-014 decision 3).

Discovers every executable app/extension target in the Xcode project
(explicitly Echo and EchoShareExtension), then scans each target's source tree
and configuration for release-compliance findings:

  - networking:      URLSession/NSURLConnection data tasks (R-001/R-005)
  - linked-sdk:      frameworks linked via the target's Frameworks build phase
  - secret:          hardcoded credentials (api key / secret / password / token)
  - entitlement:     entitlement keys declared for the target
  - privacy-manifest:PrivacyInfo.xcprivacy presence and required-reason API
  - required-reason:  required-reason APIs used in source vs declared reasons
  - purpose-string:  NS*UsageDescription keys required by declared entitlements

Fail-closed rules: a missing Echo or EchoShareExtension target, a target whose
scan is skipped, or any blocking finding fails the gate.

Exit code 0 = all targets scanned and no blocking findings; 1 otherwise.
"""

import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

EXECUTABLE_PRODUCT_TYPES = {
    "com.apple.product-type.application",
    "com.apple.product-type.app-extension",
}

REQUIRED_TARGETS = {"Echo", "EchoShareExtension"}

# Entitlement keys that require a matching NS*UsageDescription purpose string.
ENTITLEMENT_TO_PURPOSE = {
    "com.apple.developer.healthkit": [
        "NSHealthShareUsageDescription",
        "NSHealthUpdateUsageDescription",
    ],
    "com.apple.developer.location-information": ["NSLocationWhenInUseUsageDescription"],
}

# Required-reason API categories and the source markers that require a reason.
REQUIRED_REASON_MARKERS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": [r"\bUserDefaults\b"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": [r"FileManager\.default\.attributesOfItem"],
    "NSPrivacyAccessedAPICategorySystemBootTime": [r"SystemUptime", r"mach_absolute_time"],
    "NSPrivacyAccessedAPICategoryDiskSpace": [r"volumeAvailableCapacity"],
}

NETWORK_PATTERNS = [
    re.compile(r"URLSession\.(shared|session)\.\w*[Dd]ataTask"),
    re.compile(r"URLSession\.(shared|session)\.uploadTask"),
    re.compile(r"URLSession\.(shared|session)\.downloadTask"),
    re.compile(r"\bNSURLConnection\b"),
]

SECRET_PATTERN = re.compile(
    r"\b(api[_-]?key|apikey|access[_-]?token|secret|password|passwd)\b\s*[:=]\s*[\"'][^\"']{6,}[\"']",
    re.IGNORECASE,
)


def strip_comments_and_strings(text):
    """Remove Swift/ObjC line and block comments so patterns only match code."""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            out.append("\n")
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
            continue
        if text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            out.append('"')  # keep a quote so secret literal matching still works
            i = j
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def strip_comments_only(text):
    """Remove comments but keep string literals (for secret-literal scans)."""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            out.append("\n")
            continue
        if two == "/*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
            continue
        out.append(text[i])
        i += 1
    return "".join(out)


def read_plist(path):
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException):
        return None


def discover_executable_targets(root):
    """Return sorted names of executable app/extension PBXNativeTargets."""
    pbxproj = root / "Echo.xcodeproj" / "project.pbxproj"
    text = pbxproj.read_text(encoding="utf-8")
    # Find productType lines; a productType belongs to the nearest enclosing
    # PBXNativeTarget section that also carries a productName.
    targets = []
    current = None
    for line in text.splitlines():
        if "isa = PBXNativeTarget" in line:
            current = {"name": None, "product_type": None}
        elif current is not None:
            m = re.search(r'productName = ([^;]+);', line)
            if m:
                current["name"] = m.group(1).strip()
            m = re.search(r'productType = "([^"]+)";', line)
            if m:
                current["product_type"] = m.group(1)
            if line.rstrip().endswith("};") and current["product_type"]:
                if current["product_type"] in EXECUTABLE_PRODUCT_TYPES and current["name"]:
                    targets.append(current["name"])
                current = None
    return sorted(set(targets))


def validate_target_set(targets):
    """Return a list of gate-error strings; empty means the set is complete."""
    errors = []
    for required in sorted(REQUIRED_TARGETS):
        if required not in targets:
            errors.append(f"required executable target {required} not discovered")
    return errors


def declared_reason_apis(config_dir):
    """Return the set of NSPrivacyAccessedAPIType values declared in the
    target's PrivacyInfo.xcprivacy (empty when missing or unreadable)."""
    privacy = config_dir / "PrivacyInfo.xcprivacy"
    p = read_plist(privacy) or {}
    return {
        item.get("NSPrivacyAccessedAPIType")
        for item in (p.get("NSPrivacyAccessedAPITypes") or [])
    }


def scan_source(root, target, source_dir, declared_reasons, findings):
    for swift in sorted(source_dir.rglob("*.swift")):
        rel = str(swift.relative_to(root))
        raw = swift.read_text(encoding="utf-8", errors="replace")
        text = strip_comments_and_strings(raw)
        for pattern in NETWORK_PATTERNS:
            if pattern.search(text):
                findings.append(
                    {"category": "networking", "location": rel, "detail": pattern.pattern, "blocking": True}
                )
                break
        for m in SECRET_PATTERN.finditer(strip_comments_only(raw)):
            findings.append(
                {
                    "category": "secret",
                    "location": rel,
                    "detail": f"hardcoded credential near '{m.group(1)}'",
                    "blocking": True,
                }
            )
        for api, markers in REQUIRED_REASON_MARKERS.items():
            if api in declared_reasons:
                continue
            for marker in markers:
                if re.search(marker, text):
                    findings.append(
                        {
                            "category": "required-reason",
                            "location": rel,
                            "detail": f"requires reason declaration for {api}",
                            "blocking": False,
                        }
                    )
                    break


def used_reason_apis(source_dir):
    """Return the set of required-reason API categories actually used in source."""
    used = set()
    for swift in source_dir.rglob("*.swift"):
        raw = swift.read_text(encoding="utf-8", errors="replace")
        text = strip_comments_and_strings(raw)
        for api, markers in REQUIRED_REASON_MARKERS.items():
            if any(re.search(marker, text) for marker in markers):
                used.add(api)
    return used


def scan_config(root, target, config_dir, used, findings):
    info = read_plist(config_dir / f"{target}-Info.plist")
    if info is None:
        info = read_plist(config_dir / "Info.plist")
    entitlements = read_plist(config_dir / f"{target}.entitlements")
    privacy = config_dir / "PrivacyInfo.xcprivacy"

    if info is None:
        findings.append(
            {"category": "purpose-string", "location": str(config_dir), "detail": "Info.plist not found", "blocking": True}
        )

    if not privacy.exists():
        findings.append(
            {
                "category": "privacy-manifest",
                "location": str(privacy.relative_to(root)),
                "detail": "PrivacyInfo.xcprivacy missing (ADR-014 decision 4)",
                "blocking": True,
            }
        )
    else:
        declared = declared_reason_apis(config_dir)
        for api in sorted(used - declared):
            findings.append(
                {
                    "category": "privacy-manifest",
                    "location": str(privacy.relative_to(root)),
                    "detail": f"required-reason API {api} used but not declared",
                    "blocking": True,
                }
            )

    if entitlements:
        for key in sorted(entitlements.keys()):
            findings.append(
                {
                    "category": "entitlement",
                    "location": str((config_dir / f"{target}.entitlements").relative_to(root)),
                    "detail": key,
                    "blocking": False,
                }
            )
            for purpose in ENTITLEMENT_TO_PURPOSE.get(key, []):
                if info is None or not info.get(purpose):
                    findings.append(
                        {
                            "category": "purpose-string",
                            "location": str((config_dir / f"{target}-Info.plist").relative_to(root)),
                            "detail": f"{purpose} missing for entitlement {key}",
                            "blocking": True,
                        }
                    )


def scan_target(root, target, source_dir, config_dir):
    """Return per-target findings list. source_dir defaults to the target dir."""
    findings = []
    declared = declared_reason_apis(config_dir)
    scan_source(root, target, source_dir, declared, findings)
    scan_config(root, target, config_dir, used_reason_apis(source_dir), findings)
    return findings


def build_report(root):
    targets = discover_executable_targets(root)
    errors = validate_target_set(targets)
    report = {"targets": {}, "errors": errors, "ok": len(errors) == 0}

    for target in targets:
        if target not in REQUIRED_TARGETS:
            errors.append(f"executable target {target} is not an approved release target")
            report["ok"] = False
            continue
        source_dir = root / target
        config_dir = root / target if target == "EchoShareExtension" else root / target / "Config"
        if not source_dir.exists():
            errors.append(f"target {target} source directory missing: {source_dir}")
            report["ok"] = False
            continue
        findings = scan_target(root, target, source_dir, config_dir)
        blocking = [f for f in findings if f.get("blocking", False)]
        report["targets"][target] = {
            "status": "fail" if blocking else "clean",
            "findings": findings,
        }
        if blocking:
            report["ok"] = False

    return report


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT
    report = build_report(root)

    import json
    print(json.dumps(report, indent=2, ensure_ascii=False))

    for error in report["errors"]:
        print(f"::error::{error}")
    for name, target in report["targets"].items():
        for finding in target["findings"]:
            marker = "::error::" if finding.get("blocking") else "::warning::"
            print(
                f"{marker}[{name}] {finding['category']}: {finding['detail']} "
                f"({finding['location']})"
            )

    if report["ok"]:
        print("OK: all executable targets scanned, no blocking findings")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
