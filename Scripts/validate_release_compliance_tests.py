#!/usr/bin/env python3
"""Unit tests for Scripts/validate_release_compliance.py (3F.11).

Covers the ADR-014 decision-3 contract: target discovery for every executable
app/extension target (explicitly Echo and EchoShareExtension), per-target
scan findings that never leak across targets, and fail-closed behavior when a
target is skipped or a seeded violation lands under the wrong target.

Run: python3 -m unittest Scripts.validate_release_compliance_tests
"""

import json
import plistlib
import tempfile
import unittest
from pathlib import Path

import Scripts.validate_release_compliance as vrc


def make_pbxproj(targets):
    """Build a minimal pbxproj text exposing PBXNativeTarget sections."""
    out = []
    out.append("// !$*UTF8*$!\n{ archiveVersion = 1; classes = {};")
    out.append("objectVersion = 56;")
    out.append("objects = {\n")
    for name, product_type in targets:
        out.append(f"/* Begin PBXNativeTarget section */")
        out.append(f"AAAA000000000000000000{hash(name) % 0xFFFFFF:06X} /* {name} */ = {{")
        out.append("isa = PBXNativeTarget;")
        out.append(f"productName = {name};")
        out.append(f'productType = "{product_type}";')
        out.append("};")
        out.append("/* End PBXNativeTarget section */")
    out.append("}; rootObject = 0000000000000000000000000000000000000000; }")
    return "\n".join(out)


def make_info_plist(path, usage=None):
    d = {"CFBundleDisplayName": "X"}
    for k, v in (usage or {}).items():
        d[k] = v
    path.write_bytes(plistlib.dumps(d))


class DiscoveryTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _write_project(self, targets):
        (self.root / "Echo.xcodeproj").mkdir(parents=True, exist_ok=True)
        (self.root / "Echo.xcodeproj" / "project.pbxproj").write_text(
            make_pbxproj(targets), encoding="utf-8"
        )

    def test_discovery_finds_both_executable_targets(self):
        self._write_project(
            [
                ("Echo", "com.apple.product-type.application"),
                ("EchoShareExtension", "com.apple.product-type.app-extension"),
                ("EchoTests", "com.apple.product-type.bundle.unit-test"),
                ("EchoUITests", "com.apple.product-type.bundle.ui-testing"),
            ]
        )
        targets = vrc.discover_executable_targets(self.root)
        self.assertIn("Echo", targets)
        self.assertIn("EchoShareExtension", targets)
        # Test bundles must not be treated as executable app targets.
        self.assertNotIn("EchoTests", targets)
        self.assertNotIn("EchoUITests", targets)

    def test_discovery_fails_closed_when_app_target_absent(self):
        self._write_project(
            [
                ("EchoShareExtension", "com.apple.product-type.app-extension"),
            ]
        )
        errors = vrc.validate_target_set(
            vrc.discover_executable_targets(self.root)
        )
        self.assertTrue(any("Echo" in e for e in errors))
        self.assertGreaterEqual(len(errors), 1)


class PerTargetScanTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.target = "Echo"
        # Mimic Echo's real layout: source tree + Config.
        self.source_dir = self.root / "Echo"
        self.source_dir.mkdir(parents=True, exist_ok=True)
        self.config_dir = self.root / "Echo" / "Config"
        self.config_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        self._tmp.cleanup()

    def test_network_violation_reported_under_owning_target_only(self):
        (self.source_dir / "Core").mkdir(parents=True, exist_ok=True)
        (self.source_dir / "Core" / "Bad.swift").write_text(
            'import Foundation\nlet task = URLSession.shared.dataTask(with: URL(string:"https://x")!)\n',
            encoding="utf-8",
        )
        findings = vrc.scan_target(self.root, self.target, self.source_dir, self.config_dir)
        net = [f for f in findings if f["category"] == "networking"]
        self.assertTrue(any("Bad.swift" in f["location"] for f in net))

    def test_secret_scan_detects_hardcoded_token(self):
        (self.source_dir / "Bad.swift").write_text(
            'let apiKey = "sk-live-0123456789abcdef"\n', encoding="utf-8"
        )
        findings = vrc.scan_target(self.root, self.target, self.source_dir, self.config_dir)
        secrets = [f for f in findings if f["category"] == "secret"]
        self.assertTrue(any("apiKey" in f["detail"] for f in secrets))

    def test_missing_privacy_manifest_is_reported(self):
        make_info_plist(self.config_dir / "Echo-Info.plist", {"NSPhotoLibraryUsageDescription": "x"})
        findings = vrc.scan_target(self.root, self.target, self.source_dir, self.config_dir)
        manifests = [f for f in findings if f["category"] == "privacy-manifest"]
        self.assertTrue(any("missing" in f["detail"].lower() for f in manifests))

    def test_purpose_string_scan_reports_entitlement_mismatch(self):
        (self.config_dir / "Echo.entitlements").write_bytes(
            plistlib.dumps(
                {"com.apple.developer.healthkit": True, "com.apple.security.application-groups": ["group.com.echo.Echo"]}
            )
        )
        make_info_plist(self.config_dir / "Echo-Info.plist")
        findings = vrc.scan_target(self.root, self.target, self.source_dir, self.config_dir)
        purposes = [f for f in findings if f["category"] == "purpose-string"]
        self.assertTrue(any("NSHealthShareUsageDescription" in f["detail"] for f in purposes))

    def test_clean_target_has_no_blocking_findings(self):
        make_info_plist(
            self.config_dir / "Echo-Info.plist",
            {"NSHealthShareUsageDescription": "x"},
        )
        (self.config_dir / "PrivacyInfo.xcprivacy").write_bytes(
            plistlib.dumps(
                {
                    "NSPrivacyCollectedDataTypes": [],
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                        }
                    ],
                }
            )
        )
        findings = vrc.scan_target(self.root, self.target, self.source_dir, self.config_dir)
        blocking = [f for f in findings if f.get("blocking", False)]
        self.assertEqual(blocking, [])

    def test_no_required_reason_warning_when_api_declared(self):
        # Regression for DEF-63-001.
        (self.source_dir / "Store.swift").write_text(
            "import Foundation\nlet d = UserDefaults.standard\n",
            encoding="utf-8",
        )
        (self.config_dir / "PrivacyInfo.xcprivacy").write_bytes(
            plistlib.dumps(
                {
                    "NSPrivacyCollectedDataTypes": [],
                    "NSPrivacyAccessedAPITypes": [
                        {
                            "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                            "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
                        }
                    ],
                }
            )
        )
        findings = vrc.scan_target(self.root, self.target, self.source_dir, self.config_dir)
        reason = [f for f in findings if f["category"] == "required-reason"]
        self.assertEqual(reason, [])

    def test_used_reason_apis_ignores_comments_and_strings(self):
        # Regression for DEF-63-002.
        (self.source_dir / "Comment.swift").write_text(
            '// TODO: consider UserDefaults for caching\nlet key = "UserDefaults.notUsed"\n',
            encoding="utf-8",
        )
        self.assertEqual(vrc.used_reason_apis(self.source_dir), set())

    def test_seeded_violation_never_leaks_to_sibling_target(self):
        (self.root / "EchoShareExtension").mkdir(parents=True, exist_ok=True)
        make_info_plist(self.config_dir / "Echo-Info.plist")
        (self.root / "Echo" / "Core").mkdir(parents=True, exist_ok=True)
        (self.root / "Echo" / "Core" / "Bad.swift").write_text(
            'let task = URLSession.shared.dataTask(with: URL(string:"https://x")!)\n',
            encoding="utf-8",
        )
        echo_findings = vrc.scan_target(self.root, "Echo", self.root / "Echo", self.config_dir)
        ext_findings = vrc.scan_target(
            self.root, "EchoShareExtension", self.root / "EchoShareExtension", self.root / "EchoShareExtension"
        )
        echo_net = {f["location"] for f in echo_findings if f["category"] == "networking"}
        ext_net = {f["location"] for f in ext_findings if f["category"] == "networking"}
        self.assertTrue(echo_net)
        self.assertEqual(ext_net, set())


class ReportTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_report_json_is_serializable_and_per_target(self):
        report = {
            "targets": {
                "Echo": {"status": "clean", "findings": []},
                "EchoShareExtension": {"status": "clean", "findings": []},
            },
            "errors": [],
            "ok": True,
        }
        json.dumps(report)
        self.assertTrue(report["ok"])
        self.assertEqual(set(report["targets"].keys()), {"Echo", "EchoShareExtension"})


if __name__ == "__main__":
    unittest.main()
