"""Run the real signing shell script against fake Apple commands and dummy keys.

No real security/codesign/notarytool command or credential is used. This checks
ordering, entitlements, failure propagation and cleanup without Apple services.
"""
import base64
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts/sign-and-notarize.sh"
SECRETS = {
    "MACOS_CERTIFICATE": base64.b64encode(b"dummy-test-p12").decode(),
    "MACOS_CERTIFICATE_PWD": "dummy-test-certificate-password",
    "MACOS_KEYCHAIN_PWD": "dummy-test-keychain-password",
    "MACOS_CODESIGN_IDENT": "Developer ID Application: Dummy Test (ABCDEFGHIJ)",
    "APPLE_NOTARIZATION_USERNAME": "dummy@example.invalid",
    "APPLE_NOTARIZATION_PASSWORD": "dummy-test-notarization-password",
    "APPLE_NOTARIZATION_TEAMID": "ABCDEFGHIJ",
}
FAKE_TOOL = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
record = {"command": name, "args": args}
if name == "codesign":
    record["entitlements"] = plistlib.loads(pathlib.Path(args[args.index("--entitlements") + 1]).read_bytes())
if name == "security" and args[0] == "import":
    assert pathlib.Path(args[1]).read_bytes() == b"dummy-test-p12"
with open(os.environ["FAKE_LOG"], "a") as stream:
    stream.write(json.dumps(record) + "\n")
if os.environ.get("FAKE_FAIL") == name + ":" + args[0]:
    print("Simulated tool failure", file=sys.stderr)
    sys.exit(42)
if name == "security" and args[0] == "create-keychain":
    pathlib.Path(args[-1]).write_text("dummy keychain")
elif name == "ditto":
    pathlib.Path(args[-1]).write_bytes(b"dummy ZIP")
elif name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"id": "dummy-submission", "status": os.environ.get("FAKE_NOTARY_STATUS", "Accepted")}))
    sys.exit(int(os.environ.get("FAKE_NOTARY_EXIT", "0")))
elif name == "xcrun" and args[:2] == ["notarytool", "log"]:
    pathlib.Path(args[-1]).write_text(json.dumps({"status": "Invalid", "issues": ["Dummy rejection"]}))
elif name == "xcrun" and args[:2] == ["stapler", "staple"]:
    if os.environ.get("FAKE_STAPLE_FAIL"):
        sys.exit(42)
    pathlib.Path(args[-1], ".stapled").write_text("dummy ticket")
'''
FAKE_VERIFY = r'''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as stream:
    stream.write(json.dumps({"command": "verify", "args": args}) + "\n")
if "--notarized" in args:
    assert pathlib.Path(args[0], ".stapled").is_file(), "Verification ran before stapling"
if os.environ.get("FAKE_VERIFY_FAIL") == ("notarized" if "--notarized" in args else "release"):
    sys.exit(42)
'''


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="webusb-signing-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        shutil.copyfile(SCRIPT, self.scripts / SCRIPT.name)
        (self.scripts / "verify-distribution.py").write_text(FAKE_VERIFY)
        self.app = self.root / "build/products/Release/Safari WebUSB.app"
        self.extension = self.app / "Contents/PlugIns/Safari WebUSB Extension.appex"
        self.extension.mkdir(parents=True)
        native = self.root / "build/Safari WebUSB/Native"
        native.mkdir(parents=True)
        self.original_entitlements = {}
        for name, entitlements in [
            ("Extension", {"com.apple.security.app-sandbox": True, "com.apple.security.device.usb": True}),
            ("App", {"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
                     "com.apple.security.network.server": True, "com.apple.security.device.usb": True}),
        ]:
            path = native / (name + ".entitlements")
            path.write_bytes(plistlib.dumps(entitlements))
            self.original_entitlements[path] = path.read_bytes()
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        for name in ["security", "codesign", "xcrun", "ditto"]:
            path = self.fake_bin / name
            path.write_text(FAKE_TOOL)
            path.chmod(0o755)
        self.runner_temp = self.root / "runner-temp"
        self.runner_temp.mkdir()
        self.log = self.root / "commands.jsonl"

    def run_script(self, overrides=None, missing=None):
        environment = {key: value for key, value in os.environ.items() if key not in SECRETS and not key.startswith("FAKE_")}
        environment.update(SECRETS)
        environment.update({"PATH": str(self.fake_bin) + os.pathsep + os.environ["PATH"],
                            "RUNNER_TEMP": str(self.runner_temp), "FAKE_LOG": str(self.log)})
        environment.update(overrides or {})
        if missing:
            environment.pop(missing)
        result = subprocess.run(["/bin/bash", str(self.scripts / SCRIPT.name)], cwd=self.root,
                                env=environment, text=True, capture_output=True, timeout=20)
        records = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return result, records

    def assert_cleaned(self, records):
        self.assertEqual(list(self.runner_temp.iterdir()), [], "Temporary certificate/keychain files survived")
        self.assertEqual(records[-1]["command"], "security")
        self.assertEqual(records[-1]["args"][0], "delete-keychain")
        for path, original in self.original_entitlements.items():
            self.assertEqual(path.read_bytes(), original, "Signing mutated the generated entitlement file")

    def test_missing_each_secret_fails_before_keychain_or_signing(self):
        for secret in SECRETS:
            with self.subTest(secret=secret):
                result, records = self.run_script(missing=secret)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(secret, result.stderr)
                self.assertEqual(records, [])
                self.assertEqual(list(self.runner_temp.iterdir()), [])

    def test_accepted_release_signs_inside_out_with_distinct_original_entitlements(self):
        result, records = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        signatures = [record for record in records if record["command"] == "codesign"]
        self.assertEqual(len(signatures), 2)
        self.assertEqual(signatures[0]["args"][-1], str(self.extension))
        self.assertEqual(signatures[1]["args"][-1], str(self.app))
        for index, name in enumerate(("Extension", "App")):
            expected = plistlib.loads(next(data for path, data in self.original_entitlements.items() if path.name == name + ".entitlements"))
            expected["com.apple.security.application-groups"] = ["ABCDEFGHIJ.org.webtilp.safariwebusb"]
            self.assertEqual(signatures[index]["entitlements"], expected)
        for signature in signatures:
            args = signature["args"]
            self.assertIn("--timestamp", args)
            self.assertEqual(args[args.index("--options") + 1], "runtime")
            self.assertIn("--generate-entitlement-der", args)
            self.assertNotIn("--deep", args)
            self.assertNotIn("com.apple.security.get-task-allow", signature["entitlements"])
        verification = [record for record in records if record["command"] == "verify"]
        self.assertEqual(len(verification), 2)
        self.assertIn("--release", verification[0]["args"])
        self.assertNotIn("--notarized", verification[0]["args"])
        self.assertIn("--notarized", verification[1]["args"])
        submit = next(record for record in records if record["command"] == "xcrun" and record["args"][:2] == ["notarytool", "submit"])
        staple = next(record for record in records if record["command"] == "xcrun" and record["args"][:2] == ["stapler", "staple"])
        self.assertLess(records.index(signatures[1]), records.index(verification[0]))
        self.assertLess(records.index(verification[0]), records.index(submit))
        self.assertLess(records.index(submit), records.index(staple))
        self.assertLess(records.index(staple), records.index(verification[1]))
        self.assert_cleaned(records)

    def test_rejected_notarization_fetches_log_never_staples_and_cleans_keychain(self):
        result, records = self.run_script({"FAKE_NOTARY_STATUS": "Invalid"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Dummy rejection", result.stderr)
        self.assertTrue(any(record["command"] == "xcrun" and record["args"][:2] == ["notarytool", "log"] for record in records))
        self.assertFalse(any(record["command"] == "xcrun" and record["args"][0] == "stapler" for record in records))
        self.assertEqual(len([record for record in records if record["command"] == "verify"]), 1)
        self.assert_cleaned(records)

    def test_failed_notary_submission_never_staples_and_cleans_keychain(self):
        result, records = self.run_script({"FAKE_NOTARY_EXIT": "42"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not complete", result.stderr)
        self.assertFalse(any(record["command"] == "xcrun" and record["args"][0] == "stapler" for record in records))
        self.assert_cleaned(records)

    def test_keychain_import_failure_stops_before_signing_and_cleans_up(self):
        result, records = self.run_script({"FAKE_FAIL": "security:import"})
        self.assertEqual(result.returncode, 42)
        self.assertFalse(any(record["command"] == "codesign" for record in records))
        self.assert_cleaned(records)

    def test_keychain_failure_reports_stage_without_exposing_secrets(self):
        result, records = self.run_script({"FAKE_FAIL": "security:set-key-partition-list"})
        self.assertEqual(result.returncode, 42)
        self.assertIn("Signing failed during: Authorizing signing-key access", result.stderr)
        for name in ("MACOS_CERTIFICATE", "MACOS_CERTIFICATE_PWD", "MACOS_KEYCHAIN_PWD",
                     "APPLE_NOTARIZATION_PASSWORD"):
            self.assertNotIn(SECRETS[name], result.stdout + result.stderr)
        self.assertFalse(any(record["command"] == "codesign" for record in records))
        self.assert_cleaned(records)

    def test_signature_verification_failure_prevents_notarization_and_cleans_up(self):
        result, records = self.run_script({"FAKE_VERIFY_FAIL": "release"})
        self.assertEqual(result.returncode, 42)
        self.assertFalse(any(record["command"] == "xcrun" for record in records))
        self.assert_cleaned(records)

    def test_stapler_failure_never_reports_verified_success_and_cleans_up(self):
        result, records = self.run_script({"FAKE_STAPLE_FAIL": "1"})
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("succeeded", result.stdout)
        self.assertEqual(len([record for record in records if record["command"] == "verify"]), 1)
        self.assert_cleaned(records)

    def test_final_gatekeeper_verification_failure_is_not_reported_as_success(self):
        result, records = self.run_script({"FAKE_VERIFY_FAIL": "notarized"})
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("succeeded", result.stdout)
        self.assert_cleaned(records)


if __name__ == "__main__":
    unittest.main()
