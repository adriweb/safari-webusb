#!/usr/bin/env python3
"""Wire the original native backend into Apple's generated Safari wrapper.

Only build/ is modified. Use plutil to parse OpenStep, then write a plist that
Xcode also accepts, avoiding textual edits tied to generated object IDs.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "build/Safari WebUSB"
PBX = PROJECT / "Safari WebUSB.xcodeproj/project.pbxproj"
data = plistlib.loads(subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(PBX)]))
objects = data["objects"]
native_dir = PROJECT / "Native"
native_dir.mkdir(exist_ok=True)
version = json.loads((ROOT / "extension/manifest.json").read_text())["version"]
build_number = os.environ.get("BUILD_NUMBER", "1")
if not build_number.isdigit() or int(build_number) < 1:
    raise SystemExit("BUILD_NUMBER must be a positive integer")

def copy_generated(source, destination):
    # Homebrew archives/headers are commonly read-only; keep regeneration safe.
    if destination.exists():
        destination.chmod(destination.stat().st_mode | 0o200)
    shutil.copy2(source, destination)
    destination.chmod(destination.stat().st_mode | 0o200)

for name in ("USBBackend.h", "USBBackend.m", "SafariWebExtensionHandler.m",
             "USBTransportAuth.h", "USBTransportAuth.m", "USBLoopbackServer.h", "USBLoopbackServer.m", "DeviceBridgeBackend.h", "DeviceBridgeBackend.m",
             "SerialBackend.h", "SerialBackend.m", "HIDBackend.h", "HIDBackend.m",
             "HIDReportDescriptor.h", "HIDReportDescriptor.m"):
    copy_generated(ROOT / "native" / name, native_dir / name)
for name in ("AppDelegate.m", "ViewController.m"):
    copy_generated(ROOT / "native" / name, PROJECT / "Safari WebUSB" / name)
copy_generated(ROOT / "native/Main.html", PROJECT / "Safari WebUSB/Base.lproj/Main.html")
libdir = pathlib.Path(subprocess.check_output(["pkg-config", "--variable=libdir", "libusb-1.0"], text=True).strip())
includedir = pathlib.Path(subprocess.check_output(["pkg-config", "--variable=includedir", "libusb-1.0"], text=True).strip())
copy_generated(libdir / "libusb-1.0.a", native_dir / "libusb-1.0.a")
copy_generated(includedir / "libusb-1.0/libusb.h", native_dir / "libusb.h")
copy_generated(ROOT / "LICENSES/libusb-LGPL-2.1.txt", native_dir / "LIBUSB-COPYING")
# Homebrew bottles can target a newer OS than Safari's minimum. Never stamp
# an app with a deployment target older than its linked archive supports.
load_commands = subprocess.check_output(["otool", "-l", str(native_dir / "libusb-1.0.a")], text=True)
versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+)*)", load_commands, re.MULTILINE)
version_key = lambda value: tuple(int(part) for part in value.split("."))
minimum = max(["13.0", *versions], key=version_key)
deployment = os.environ.get("SAFARI_WEBUSB_DEPLOYMENT_TARGET", minimum)
if version_key(deployment) < version_key(minimum):
    raise SystemExit(f"libusb requires macOS {minimum}; build libusb for the older target first.")

def object_id(key):
    return hashlib.sha256(("safari-webusb:" + key).encode()).hexdigest()[:24].upper()

def add_file(path, kind, phase):
    existing = next((key for key, obj in objects.items() if obj.get("isa") == "PBXFileReference" and obj.get("path") == path), None)
    ref = existing or object_id(path)
    if not existing:
        objects[ref] = {"isa": "PBXFileReference", "lastKnownFileType": kind, "path": path, "sourceTree": "SOURCE_ROOT"}
        group["children"].append(ref)
    if not any(objects[item].get("fileRef") == ref for item in phase["files"]):
        build = object_id(path + ":build")
        objects[build] = {"isa": "PBXBuildFile", "fileRef": ref}
        phase["files"].append(build)

project = objects[data["rootObject"]]
group = objects[project["mainGroup"]]
for target_id in project["targets"]:
    target = objects[target_id]
    extension = target["productType"] == "com.apple.product-type.app-extension"
    config_list = objects[target["buildConfigurationList"]]
    for config_id in config_list["buildConfigurations"]:
        settings = objects[config_id]["buildSettings"]
        settings["MACOSX_DEPLOYMENT_TARGET"] = deployment
        settings["PRODUCT_BUNDLE_IDENTIFIER"] = "org.webtilp.safariwebusb" + (".Extension" if extension else "")
        settings["MARKETING_VERSION"] = version
        settings["CURRENT_PROJECT_VERSION"] = build_number
        settings["CODE_SIGN_ENTITLEMENTS"] = "Native/Extension.entitlements" if extension else "Native/App.entitlements"
        settings["HEADER_SEARCH_PATHS"] = ["$(inherited)", "$(SRCROOT)/Native"]
        settings["OTHER_LDFLAGS"] = ["$(inherited)", '"$(SRCROOT)/Native/libusb-1.0.a"', "-framework", "SafariServices", "-framework", "IOKit", "-framework", "CoreFoundation", "-framework", "Security", "-lobjc"]
        if extension:
            settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
        else:
            settings["OTHER_LDFLAGS"] += ["-framework", "Network"]
    phases = {objects[key]["isa"]: objects[key] for key in target["buildPhases"]}
    sources = phases["PBXSourcesBuildPhase"]
    add_file("Native/USBBackend.m", "sourcecode.c.objc", sources)
    add_file("Native/USBTransportAuth.m", "sourcecode.c.objc", sources)
    if not extension:
        for name in ("DeviceBridgeBackend", "SerialBackend", "HIDBackend", "HIDReportDescriptor"):
            add_file("Native/" + name + ".m", "sourcecode.c.objc", sources)
        add_file("Native/USBLoopbackServer.m", "sourcecode.c.objc", sources)
        resources = PROJECT / "DistributionResources"
        (resources / "LICENSES").mkdir(parents=True, exist_ok=True)
        copy_generated(ROOT / "LICENSE", resources / "LICENSE")
        copy_generated(ROOT / "THIRD-PARTY-NOTICES.txt", resources / "THIRD-PARTY-NOTICES.txt")
        copy_generated(ROOT / "LICENSES/libusb-LGPL-2.1.txt", resources / "LICENSES/libusb-LGPL-2.1.txt")
        for path, kind in [("LICENSE", "text"), ("THIRD-PARTY-NOTICES.txt", "text"), ("LICENSES", "folder")]:
            add_file("DistributionResources/" + path, kind, phases["PBXResourcesBuildPhase"])
        continue
    sources = phases["PBXSourcesBuildPhase"]
    # Replace the generated echo handler, rather than compiling both classes.
    sources["files"] = [key for key in sources["files"] if objects[objects[key]["fileRef"]].get("path") != "SafariWebExtensionHandler.m"]
    add_file("Native/USBBackend.m", "sourcecode.c.objc", sources)
    add_file("Native/SafariWebExtensionHandler.m", "sourcecode.c.objc", sources)
    resources = PROJECT / "Safari WebUSB Extension/Resources"
    for source in (ROOT / "extension").iterdir():
        if not source.is_file():
            continue
        copy_generated(source, resources / source.name)
        # Existing converter entries are group-relative Resources/foo.
        existing = next((key for key in phases["PBXResourcesBuildPhase"]["files"] if objects[objects[key]["fileRef"]].get("path") == "Resources/" + source.name), None)
        if not existing:
            add_file("Safari WebUSB Extension/Resources/" + source.name, "text", phases["PBXResourcesBuildPhase"])

team_id = os.environ.get("TEAM_ID", "")
if team_id and not re.fullmatch(r"[A-Z0-9]{10}", team_id):
    raise SystemExit("TEAM_ID must be a 10-character Apple developer team identifier")
for name, entitlements in [
    ("Extension", {"com.apple.security.app-sandbox": True, "com.apple.security.device.usb": True}),
    ("App", {"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True,
             "com.apple.security.network.server": True, "com.apple.security.device.usb": True,
             "com.apple.security.device.serial": True}),
]:
    if team_id:
        entitlements["com.apple.security.application-groups"] = [team_id + ".org.webtilp.safariwebusb"]
    (native_dir / (name + ".entitlements")).write_bytes(plistlib.dumps(entitlements))
PBX.write_bytes(plistlib.dumps(data, sort_keys=False))
# Shared schemes make command-line and CI builds independent of Xcode's
# per-user automatic-scheme preferences and generated xcuserdata.
app_id = next(key for key in project["targets"] if objects[key]["productType"] == "com.apple.product-type.application")
reference = {"BuildableIdentifier": "primary", "BlueprintIdentifier": app_id,
             "BuildableName": "Safari WebUSB.app", "BlueprintName": "Safari WebUSB",
             "ReferencedContainer": "container:Safari WebUSB.xcodeproj"}
scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")
build_action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
entries = ET.SubElement(build_action, "BuildActionEntries")
entry = ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES",
                      buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
ET.SubElement(entry, "BuildableReference", reference)
debugger = {"selectedDebuggerIdentifier": "Xcode.DebuggerFoundation.Debugger.LLDB",
            "selectedLauncherIdentifier": "Xcode.IDEFoundation.Launcher.LLDB"}
ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", **debugger)
launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", **debugger)
ET.SubElement(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"), "BuildableReference", reference)
profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES")
ET.SubElement(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), "BuildableReference", reference)
ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
ET.indent(scheme)
scheme_dir = PBX.parent / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
ET.ElementTree(scheme).write(scheme_dir / "Safari WebUSB.xcscheme", encoding="UTF-8", xml_declaration=True)
print(f"Configured native USB backend and sandbox entitlements (macOS {deployment}+) in", PROJECT)
