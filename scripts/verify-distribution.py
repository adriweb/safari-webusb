#!/usr/bin/env python3
"""Verify a distributable Safari WebUSB app using Apple's inspection tools.

An ad-hoc signature is sufficient by default. --release additionally requires a
Developer ID Application signature and hardened runtime. --notarized implies
--release and verifies both the stapled ticket and Gatekeeper acceptance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXPECTED_ARCHITECTURES = {"arm64", "x86_64"}
EXPECTED_MINIMUM = (13, 0, 0)
BUNDLE_ID = "org.webtilp.safariwebusb"


class DistributionError(Exception):
    """The app does not meet a distribution invariant."""


def require(condition, message):
    if not condition:
        raise DistributionError(message)


def command(*arguments):
    try:
        result = subprocess.run(arguments, check=False, capture_output=True)
    except OSError as error:
        raise DistributionError(f"Could not run {arguments[0]}: {error}") from error
    if result.returncode:
        output = (result.stdout + result.stderr).decode("utf-8", errors="replace").strip()
        raise DistributionError(f"{arguments[0]} failed ({result.returncode}): {output}")
    return result.stdout, result.stderr


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r"\d+(?:\.\d+){0,2}", value),
            f"Invalid macOS version: {value!r}")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def inspect_load_commands(text, label):
    """Check each slice's deployment target and actual dylib load commands."""
    minimums = []
    for block in re.split(r"^Load command \d+\s*$", text, flags=re.MULTILINE)[1:]:
        kind = re.search(r"^\s*cmd\s+(\S+)\s*$", block, re.MULTILINE)
        if not kind:
            continue
        kind = kind.group(1)
        if kind == "LC_BUILD_VERSION":
            platform = re.search(r"^\s*platform\s+(\S+)\s*$", block, re.MULTILINE)
            require(platform is not None and platform.group(1) in {"1", "MACOS", "macos"},
                    f"{label}: executable is not built for macOS")
            minimum = re.search(r"^\s*minos\s+(\S+)\s*$", block, re.MULTILINE)
            require(minimum is not None, f"{label}: missing LC_BUILD_VERSION minos")
            minimums.append(version_tuple(minimum.group(1)))
        elif kind == "LC_VERSION_MIN_MACOSX":
            minimum = re.search(r"^\s*version\s+(\S+)\s*$", block, re.MULTILINE)
            require(minimum is not None, f"{label}: missing LC_VERSION_MIN_MACOSX version")
            minimums.append(version_tuple(minimum.group(1)))
        elif kind in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                      "LC_LAZY_LOAD_DYLIB", "LC_LOAD_UPWARD_DYLIB"}:
            dependency = re.search(r"^\s*name\s+(.+?)\s+\(offset \d+\)\s*$", block, re.MULTILINE)
            require(dependency is not None, f"{label}: malformed {kind}")
            dependency = dependency.group(1)
            # libusb must be static; only Apple system libraries/frameworks may
            # remain dynamic. This also rejects unresolved @rpath dependencies.
            require(dependency.startswith(("/System/Library/", "/usr/lib/")),
                    f"{label}: non-system dylib dependency: {dependency}")
        elif kind == "LC_RPATH":
            rpath = re.search(r"^\s*path\s+(.+?)\s+\(offset \d+\)\s*$", block, re.MULTILINE)
            require(rpath is not None, f"{label}: malformed LC_RPATH")
            path = rpath.group(1)
            require(path.startswith(("@loader_path", "@executable_path", "/usr/lib/", "/System/Library/")),
                    f"{label}: nonportable library search path: {path}")
    require(len(minimums) == 1, f"{label}: expected one macOS deployment target, got {len(minimums)}")
    require(minimums[0] == EXPECTED_MINIMUM,
            f"{label}: expected macOS 13.0 deployment target, got {'.'.join(map(str, minimums[0]))}")


def inspect_entitlements(entitlements, extension, release, label, team=None):
    require(entitlements.get("com.apple.security.app-sandbox") is True,
            f"{label}: missing app sandbox entitlement")
    require(entitlements.get("com.apple.security.device.usb") is True,
            f"{label}: missing USB device entitlement")
    if not extension:
        require(entitlements.get("com.apple.security.device.serial") is True,
                f"{label}: missing serial device entitlement")
        require(entitlements.get("com.apple.security.network.server") is True,
                f"{label}: missing loopback server entitlement")
    if release:
        require(entitlements.get("com.apple.security.get-task-allow", False) is False,
                f"{label}: release must not permit get-task-allow")
        if team:
            require(entitlements.get("com.apple.security.application-groups") == [team + ".org.webtilp.safariwebusb"],
                    f"{label}: missing or mismatched signed app group")


def inspect_signature(text, label, release):
    if not release:
        return None
    require(re.search(r"^Authority=Developer ID Application: .+$", text, re.MULTILINE),
            f"{label}: release needs a Developer ID Application signature")
    require(re.search(r"^CodeDirectory .*flags=0x[0-9a-fA-F]+\([^\n]*\bruntime\b", text, re.MULTILINE),
            f"{label}: hardened runtime is not enabled")
    team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})\s*$", text, re.MULTILINE)
    require(team is not None, f"{label}: missing Developer ID team identifier")
    # Developer ID signatures without a secure timestamp become invalid when
    # the signing certificate expires, so every signed bundle needs one.
    require(re.search(r"^Timestamp=.+$", text, re.MULTILINE), f"{label}: missing secure signing timestamp")
    return team.group(1)


def read_plist(path):
    try:
        with path.open("rb") as stream:
            return plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise DistributionError(f"Cannot read {path}: {error}") from error


def verify_bundle(bundle, bundle_id, version, build_version, release, extension):
    label = bundle.name
    info = read_plist(bundle / "Contents/Info.plist")
    require(info.get("CFBundleIdentifier") == bundle_id,
            f"{label}: expected bundle identifier {bundle_id}, got {info.get('CFBundleIdentifier')!r}")
    require(info.get("CFBundleShortVersionString") == version,
            f"{label}: expected version {version}, got {info.get('CFBundleShortVersionString')!r}")
    actual_build = info.get("CFBundleVersion")
    require(isinstance(actual_build, str) and re.fullmatch(r"\d+(?:\.\d+){0,2}", actual_build),
            f"{label}: CFBundleVersion must be a numeric build version")
    require(build_version is None or actual_build == build_version,
            f"{label}: expected build version {build_version}, got {actual_build}")
    minimum = info.get("LSMinimumSystemVersion", info.get("MinimumOSVersion"))
    require(version_tuple(minimum) == EXPECTED_MINIMUM, f"{label}: Info.plist minimum macOS must be 13.0")
    executable_name = info.get("CFBundleExecutable")
    require(isinstance(executable_name, str) and pathlib.Path(executable_name).name == executable_name,
            f"{label}: invalid CFBundleExecutable")
    executable = bundle / "Contents/MacOS" / executable_name
    require(executable.is_file(), f"{label}: missing executable {executable}")
    architectures, _ = command("lipo", "-archs", str(executable))
    architectures = set(architectures.decode().split())
    require(architectures == EXPECTED_ARCHITECTURES,
            f"{label}: expected universal arm64/x86_64, got {sorted(architectures)}")
    for architecture in sorted(EXPECTED_ARCHITECTURES):
        load_commands, _ = command("otool", "-arch", architecture, "-l", str(executable))
        inspect_load_commands(load_commands.decode(), f"{label} ({architecture})")
    command("codesign", "--verify", "--strict", "--verbose=2", str(bundle))
    teams = set()
    for architecture in sorted(EXPECTED_ARCHITECTURES):
        slice_label = f"{label} ({architecture})"
        _, signature = command("codesign", "--display", "--arch", architecture, "--verbose=4", str(bundle))
        slice_team = inspect_signature(signature.decode(), slice_label, release)
        teams.add(slice_team)
        entitlement_data, _ = command("codesign", "--display", "--arch", architecture, "--entitlements", "-", "--xml", str(bundle))
        try:
            entitlements = plistlib.loads(entitlement_data)
        except (plistlib.InvalidFileException, ValueError) as error:
            raise DistributionError(f"{slice_label}: missing or invalid signed entitlements") from error
        inspect_entitlements(entitlements, extension, release, slice_label, slice_team)
    require(len(teams) == 1, f"{label}: architecture slices have different signing teams")
    team = teams.pop()
    if extension:
        require(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == "com.apple.Safari.web-extension",
                f"{label}: unexpected extension point")
        manifest_path = bundle / "Contents/Resources/manifest.json"
        try:
            manifest = json.loads(manifest_path.read_text())
        except (OSError, ValueError) as error:
            raise DistributionError(f"{label}: missing or invalid extension manifest") from error
        require(manifest.get("version") == version, f"{label}: JavaScript manifest version does not match bundle")
    print(f"PASS {label}: version {version} ({actual_build}), arm64+x86_64, macOS 13.0, sandbox and signature")
    return actual_build, team


def verify_licenses(app):
    resources = app / "Contents/Resources"
    for name in ("LICENSE", "THIRD-PARTY-NOTICES.txt", "LICENSES/libusb-LGPL-2.1.txt"):
        embedded = resources / name
        require(embedded.is_file() and embedded.stat().st_size > 0, f"Missing embedded licence/notice: {name}")
        original = ROOT / name
        require(original.is_file(), f"Missing source licence/notice for verification: {original}")
        require(hashlib.sha256(embedded.read_bytes()).digest() == hashlib.sha256(original.read_bytes()).digest(),
                f"Embedded licence/notice differs from source: {name}")
    print("PASS licences: project licence, libusb LGPL 2.1 and third-party notices match source")


def verify(app, version, build_version=None, release=False, notarized=False):
    app = app.resolve()
    require(app.is_dir() and app.suffix == ".app", f"Not an app bundle: {app}")
    extensions = list((app / "Contents/PlugIns").glob("*.appex"))
    require(len(extensions) == 1, f"Expected one embedded Safari extension, found {len(extensions)}")
    release = release or notarized
    actual_build, app_team = verify_bundle(app, BUNDLE_ID, version, build_version, release, False)
    _, extension_team = verify_bundle(extensions[0], BUNDLE_ID + ".Extension", version, actual_build, release, True)
    if release:
        require(app_team == extension_team, "Containing app and extension have different signing teams")
    command("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    verify_licenses(app)
    if notarized:
        command("xcrun", "stapler", "validate", "-v", str(app))
        stdout, stderr = command("spctl", "--assess", "--type", "execute", "--verbose=4", str(app))
        require("source=Notarized Developer ID" in (stdout + stderr).decode(),
                "Gatekeeper did not identify the app as Notarized Developer ID")
        print("PASS notarization: stapled ticket and Gatekeeper Notarized Developer ID assessment")
    print(f"Verified distribution: {app}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path, help="built Safari WebUSB.app")
    parser.add_argument("--version", help="expected marketing/manifest version; defaults to extension/manifest.json")
    parser.add_argument("--build-version", help="expected CFBundleVersion; app and extension must always match")
    parser.add_argument("--release", action="store_true", help="require Developer ID, timestamp, hardened runtime and no debugger entitlement")
    parser.add_argument("--notarized", action="store_true", help="also require stapled ticket and Gatekeeper acceptance (implies --release)")
    args = parser.parse_args()
    try:
        version = args.version or json.loads((ROOT / "extension/manifest.json").read_text())["version"]
        verify(args.app, version, args.build_version, args.release, args.notarized)
    except (DistributionError, OSError, ValueError, KeyError) as error:
        print(f"Distribution verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
