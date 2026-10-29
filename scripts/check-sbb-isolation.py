#!/usr/bin/env python3
"""Verify the experimental target cannot accidentally reuse an upstream identity.

This checks project metadata; it does not sign, install, contact an iPhone or
claim that the iOS app compiles. No third-party Python packages are required.
"""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "WrapPin.xcodeproj/project.pbxproj"


def parse_openstep(source):
    """Parse the dictionary/array/string subset used by this Xcode project."""
    pattern = re.compile(
        r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+',
        re.S,
    )
    tokens = [t for t in pattern.findall(source) if not t.startswith(("/*", "//"))]
    index = 0

    def read_value():
        nonlocal index
        token = tokens[index]
        index += 1
        if token == "{":
            result = {}
            while tokens[index] != "}":
                key = tokens[index].strip('"')
                index += 1
                assert tokens[index] == "=", "Expected dictionary assignment"
                index += 1
                assert key not in result, f"Duplicate project key: {key}"
                result[key] = read_value()
                assert tokens[index] == ";", "Expected assignment terminator"
                index += 1
            index += 1
            return result
        if token == "(":
            result = []
            while tokens[index] != ")":
                result.append(read_value())
                if tokens[index] == ",":
                    index += 1
                else:
                    assert tokens[index] == ")", "Expected array separator"
            index += 1
            return result
        return token.strip('"')

    result = read_value()
    assert index == len(tokens), "Unexpected trailing project data"
    return result


def check():
    source = PROJECT.read_text(encoding="utf-8")
    project = parse_openstep(source)
    objects = project["objects"]
    assert "de" in objects[project["rootObject"]]["knownRegions"]
    for reference in re.findall(r"\b[0-9A-F]{24}\b", source):
        assert reference in objects, f"Unresolved project reference: {reference}"

    sbb_id = "D10000000000000000000006"
    standard_id = "C10000000000000000000006"
    tunnel_id = "A00000000000000000000006"
    extension_id = "B10000000000000000000006"
    targets = objects[project["rootObject"]]["targets"]
    assert set(targets) == {sbb_id, standard_id, tunnel_id, extension_id}
    sbb = objects[sbb_id]
    assert sbb["name"] == "WrapPinSBB"
    assert sbb["productName"] == "WrapPinSBB"
    assert sbb["dependencies"] == [], "SBB must not embed the tunnel extension"
    assert sbb["fileSystemSynchronizedGroups"] == ["A00000000000000000000002"]
    phases = [objects[ref] for ref in sbb["buildPhases"]]
    assert {phase["isa"] for phase in phases} == {
        "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"
    }
    framework_phase = next(p for p in phases if p["isa"] == "PBXFrameworksBuildPhase")
    assert len(framework_phase["files"]) == 1
    framework = objects[objects[framework_phase["files"][0]]["fileRef"]]
    assert framework["path"] == "Frameworks/WrapPinPairingFFI.xcframework"

    configurations = objects[sbb["buildConfigurationList"]]["buildConfigurations"]
    assert {objects[ref]["name"] for ref in configurations} == {"Debug", "Release"}
    for ref in configurations:
        config = objects[ref]
        settings = config["buildSettings"]
        assert objects[config["baseConfigurationReference"]]["path"] == "Configuration/SBB.xcconfig"
        assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == "ch.local.wrappin.sbb.experimental"
        assert settings["WRAPPIN_CALLBACK_SCHEME"] == "wrappinsbb"
        assert settings["WRAPPIN_DISPLAY_NAME"] == "WrapPin SBB"
        assert settings["PRODUCT_NAME"] == "WrapPinSBB"
        assert settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] == "WRAPPIN_SBB_EDITION $(inherited)"
        assert "CODE_SIGN_ENTITLEMENTS" not in settings
        assert not settings.get("DEVELOPMENT_TEAM"), "No personal signing team in project"

    # Guard the established Standard and Tunnel identities in both configurations.
    expected = {
        standard_id: ("$(WRAPPIN_BUNDLE_IDENTIFIER)", "wrappin", "WrapPin"),
        tunnel_id: ("$(WRAPPIN_TUNNEL_BUNDLE_IDENTIFIER)", "wrappintunnel", "WrapPin Tunnel"),
    }
    for target_id, identity in expected.items():
        config_list = objects[objects[target_id]["buildConfigurationList"]]
        for ref in config_list["buildConfigurations"]:
            settings = objects[ref]["buildSettings"]
            assert tuple(settings[k] for k in (
                "PRODUCT_BUNDLE_IDENTIFIER", "WRAPPIN_CALLBACK_SCHEME", "WRAPPIN_DISPLAY_NAME"
            )) == identity, f"Upstream identity changed: {target_id}"
            assert "WRAPPIN_SBB_EDITION" not in settings.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "")

    config = (ROOT / "Configuration/SBB.xcconfig").read_text(encoding="utf-8")
    active_config = re.sub(r"//[^\n]*", "", config)
    assert "Local.private" not in active_config
    includes = re.findall(r'#include\??\s+"([^"]+)"', active_config)
    assert includes == ["Version.xcconfig"], "SBB config must not inherit private identity/signing"
    for key in ("DEVELOPMENT_TEAM", "WRAPPIN_TELEMETRY_APP_ID", "WRAPPIN_TELEMETRY_NAMESPACE", "WRAPPIN_GEOAPIFY_API_KEY"):
        value = re.search(rf"(?m)^{key}\s*=([^\n]*)$", active_config)
        assert value and not value.group(1).strip(), f"Expected empty public default: {key}"

    scheme = ET.parse(ROOT / "WrapPin.xcodeproj/xcshareddata/xcschemes/WrapPin SBB.xcscheme")
    references = scheme.findall(".//BuildableReference")
    assert len(references) == 3
    for reference in references:
        assert reference.attrib["BlueprintIdentifier"] == sbb_id
        assert reference.attrib["BuildableName"] == "WrapPinSBB.app"
    assert not scheme.findall(".//ExecutionAction"), "Scheme must not run install or signing scripts"

    plist = plistlib.loads((ROOT / "Configuration/WrapPin-Info.plist").read_bytes())
    assert plist["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)"
    assert plist["CFBundleDisplayName"] == "$(WRAPPIN_DISPLAY_NAME)"
    assert plist["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["$(WRAPPIN_CALLBACK_SCHEME)"]
    print("PASS: SBB project identity, scheme, configuration and extension isolation; upstream identities preserved.")


if __name__ == "__main__":
    check()
