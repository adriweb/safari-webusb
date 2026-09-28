"""Regression tests for the release gate; no Apple tooling needed for fixtures."""
import contextlib
import importlib.util
import io
import json
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts/verify-distribution.py"
SPEC = importlib.util.spec_from_file_location("verify_distribution", SCRIPT)
verification = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verification)

LOAD_COMMANDS = """Fixture (architecture arm64):
Load command 0
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 13.0
      sdk 15.0
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 56
         name /usr/lib/libSystem.B.dylib (offset 24)
Load command 2
          cmd LC_LOAD_WEAK_DYLIB
      cmdsize 120
         name /System/Library/Frameworks/SafariServices.framework/Versions/A/SafariServices (offset 24)
Load command 3
          cmd LC_RPATH
      cmdsize 48
         path @executable_path/../Frameworks (offset 12)
"""
SIGNATURE = """Executable=/fixture/app
CodeDirectory v=20500 size=2000 flags=0x10000(runtime) hashes=50+7 location=embedded
Authority=Developer ID Application: Example Developer (ABCDEFGHIJ)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Sep 28, 2026 at 12:00:00
TeamIdentifier=ABCDEFGHIJ
"""


class DistributionTests(unittest.TestCase):
    def test_macos_deployment_commands_old_and_new(self):
        verification.inspect_load_commands(LOAD_COMMANDS, "fixture")
        legacy = LOAD_COMMANDS.replace("LC_BUILD_VERSION", "LC_VERSION_MIN_MACOSX").replace(" platform 1\n", "").replace("minos", "version")
        verification.inspect_load_commands(legacy, "fixture")
        for modified in [LOAD_COMMANDS.replace("minos 13.0", "minos 14.0"),
                         LOAD_COMMANDS.replace("platform 1", "platform 2"),
                         LOAD_COMMANDS.replace("LC_BUILD_VERSION", "LC_UNKNOWN")]:
            with self.subTest(modified=modified), self.assertRaises(verification.DistributionError):
                verification.inspect_load_commands(modified, "fixture")

    def test_nonportable_dylibs_and_rpaths_are_rejected(self):
        for dependency in ["/opt/homebrew/opt/libusb/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib",
                           "@rpath/libusb-1.0.dylib", "/Users/developer/libusb.dylib"]:
            with self.subTest(dependency=dependency), self.assertRaisesRegex(verification.DistributionError, "non-system dylib"):
                verification.inspect_load_commands(LOAD_COMMANDS.replace("/usr/lib/libSystem.B.dylib", dependency), "fixture")
        with self.assertRaisesRegex(verification.DistributionError, "nonportable library search path"):
            verification.inspect_load_commands(LOAD_COMMANDS.replace("@executable_path/../Frameworks", "/opt/homebrew/lib"), "fixture")

    def test_release_rejects_adhoc_missing_runtime_timestamp_and_debugger_entitlement(self):
        verification.inspect_signature("Signature=adhoc\n", "fixture", False)
        for signature in ["Signature=adhoc\n", SIGNATURE.replace("runtime", "none"),
                          SIGNATURE.replace("Timestamp=", "Other="), SIGNATURE.replace("TeamIdentifier=", "Other=")]:
            with self.subTest(signature=signature), self.assertRaises(verification.DistributionError):
                verification.inspect_signature(signature, "fixture", True)
        entitlements = {"com.apple.security.app-sandbox": True, "com.apple.security.device.usb": True,
                        "com.apple.security.get-task-allow": True}
        verification.inspect_entitlements(entitlements, True, False, "fixture")
        with self.assertRaisesRegex(verification.DistributionError, "get-task-allow"):
            verification.inspect_entitlements(entitlements, True, True, "fixture")

    def test_required_entitlements_are_enforced(self):
        for entitlements in [{}, {"com.apple.security.app-sandbox": True}]:
            with self.subTest(entitlements=entitlements), self.assertRaises(verification.DistributionError):
                verification.inspect_entitlements(entitlements, True, False, "fixture")

    def test_app_requires_serial_entitlement(self):
        entitlements = {"com.apple.security.app-sandbox": True, "com.apple.security.device.usb": True,
                        "com.apple.security.network.server": True}
        with self.assertRaisesRegex(verification.DistributionError, "missing serial"):
            verification.inspect_entitlements(entitlements, False, False, "fixture")
        entitlements["com.apple.security.device.serial"] = True
        verification.inspect_entitlements(entitlements, False, False, "fixture")

    def make_fixture(self, directory):
        root = pathlib.Path(directory)
        app = root / "Safari WebUSB.app"
        extension = app / "Contents/PlugIns/Safari WebUSB Extension.appex"
        for bundle, suffix in [(app, ""), (extension, ".Extension")]:
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/Resources").mkdir()
            info = {"CFBundleIdentifier": verification.BUNDLE_ID + suffix, "CFBundleVersion": "7",
                    "CFBundleShortVersionString": "0.1.0", "LSMinimumSystemVersion": "13.0",
                    "CFBundleExecutable": "WebUSB"}
            if suffix:
                info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.Safari.web-extension"}
                (bundle / "Contents/Resources/manifest.json").write_text(json.dumps({"version": "0.1.0"}))
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            (bundle / "Contents/MacOS/WebUSB").write_bytes(b"executable fixture")
        for name in ["LICENSE", "THIRD-PARTY-NOTICES.txt", "LICENSES/libusb-LGPL-2.1.txt"]:
            (root / name).parent.mkdir(parents=True, exist_ok=True)
            (root / name).write_text("Fixture content " + name)
            destination = app / "Contents/Resources" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((root / name).read_bytes())
        return root, app, extension

    @staticmethod
    def fake_command(*args):
        if args[0] == "lipo":
            return b"x86_64 arm64\n", b""
        if args[0] == "otool":
            return LOAD_COMMANDS.encode(), b""
        if args[0] == "codesign" and "--entitlements" in args:
            return plistlib.dumps({"com.apple.security.app-sandbox": True, "com.apple.security.device.usb": True,
                                  "com.apple.security.network.server": True, "com.apple.security.device.serial": True,
                                  "com.apple.security.application-groups": ["ABCDEFGHIJ.org.webtilp.safariwebusb"]}), b""
        if args[0] == "codesign" and "--display" in args:
            return b"", SIGNATURE.encode()
        if args[0] == "spctl":
            return b"", b"accepted\nsource=Notarized Developer ID\n"
        return b"", b""

    def test_complete_bundle_and_notarization_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            root, app, _ = self.make_fixture(directory)
            with patch.object(verification, "ROOT", root), patch.object(verification, "command", self.fake_command), contextlib.redirect_stdout(io.StringIO()):
                verification.verify(app, "0.1.0", "7", notarized=True)
                with self.assertRaisesRegex(verification.DistributionError, "expected version"):
                    verification.verify(app, "0.2.0")
                (app / "Contents/Resources/LICENSE").write_text("Wrong licence")
                with self.assertRaisesRegex(verification.DistributionError, "differs from source"):
                    verification.verify(app, "0.1.0")

    def test_each_architecture_needs_usb_entitlement(self):
        def command(*args):
            if args[0] == "codesign" and "--entitlements" in args and "x86_64" in args and args[-1].endswith(".appex"):
                return plistlib.dumps({"com.apple.security.app-sandbox": True}), b""
            return self.fake_command(*args)
        with tempfile.TemporaryDirectory() as directory:
            root, app, _ = self.make_fixture(directory)
            with patch.object(verification, "ROOT", root), patch.object(verification, "command", command), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(verification.DistributionError, "x86_64.*missing USB"):
                    verification.verify(app, "0.1.0")

    def test_thin_binary_fails_universal_gate(self):
        def command(*args):
            return (b"arm64\n", b"") if args[0] == "lipo" else self.fake_command(*args)
        with tempfile.TemporaryDirectory() as directory:
            root, app, _ = self.make_fixture(directory)
            with patch.object(verification, "ROOT", root), patch.object(verification, "command", command), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(verification.DistributionError, "expected universal"):
                    verification.verify(app, "0.1.0")

    def test_release_group_must_match_signing_team(self):
        for groups in ([], ["OTHERTEAM1.org.webtilp.safariwebusb"]):
            def command(*args):
                output, error = self.fake_command(*args)
                if args[0] == "codesign" and "--entitlements" in args:
                    entitlements = plistlib.loads(output)
                    entitlements["com.apple.security.application-groups"] = groups
                    output = plistlib.dumps(entitlements)
                return output, error
            with self.subTest(groups=groups), tempfile.TemporaryDirectory() as directory:
                root, app, _ = self.make_fixture(directory)
                with patch.object(verification, "ROOT", root), patch.object(verification, "command", command), contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(verification.DistributionError, "app group"):
                        verification.verify(app, "0.1.0", release=True)

    def test_notarization_must_be_gatekeepers_acceptance_reason(self):
        def command(*args):
            return (b"", b"accepted\nsource=User Rule\n") if args[0] == "spctl" else self.fake_command(*args)
        with tempfile.TemporaryDirectory() as directory:
            root, app, _ = self.make_fixture(directory)
            with patch.object(verification, "ROOT", root), patch.object(verification, "command", command), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(verification.DistributionError, "Gatekeeper"):
                    verification.verify(app, "0.1.0", notarized=True)


if __name__ == "__main__":
    unittest.main()
