#!/usr/bin/env python3
"""Generate the KLMS iPhone companion Xcode project.

The repository keeps the Mac app as a SwiftPM package, but a real iPhone app
needs an Xcode application target for signing, capabilities, and device deploys.
This script generates that project deterministically from the current source
layout so the checked-in project can be refreshed when shared files change.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_ROOT = ROOT / "apps" / "KLMSync"
PROJECT_ROOT = APP_ROOT / "Xcode" / "KLMSiOS"
PROJECT_DIR = PROJECT_ROOT / "KLMSiOS.xcodeproj"
PBXPROJ = PROJECT_DIR / "project.pbxproj"
SCHEME = PROJECT_DIR / "xcshareddata" / "xcschemes" / "KLMSiOS.xcscheme"

IOS_SOURCE = APP_ROOT / "Sources" / "KLMSiOS" / "KLMSiOSApp.swift"
ASSET_CATALOG = PROJECT_ROOT / "KLMSiOS" / "Assets.xcassets"
SHARED_SOURCES = [
    "AcademicTerm.swift",
    "DashboardDataModels.swift",
    "DisplayText.swift",
    "EngineSnapshot.swift",
    "FileStatusModels.swift",
    "JSONDefaults.swift",
    "KLMSEngineCommand.swift",
    "KLMSPaths.swift",
    "RemoteCommandModels.swift",
    "StateModels.swift",
    "StatusModels.swift",
]


def oid(name: str) -> str:
    return hashlib.sha1(name.encode("utf-8")).hexdigest()[:24].upper()


def quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def main() -> int:
    PROJECT_DIR.mkdir(parents=True, exist_ok=True)

    source_paths = [IOS_SOURCE] + [
        APP_ROOT / "Sources" / "KLMSShared" / name for name in SHARED_SOURCES
    ]
    missing = [path for path in source_paths if not path.exists()]
    if not ASSET_CATALOG.exists():
        missing.append(ASSET_CATALOG)
    if missing:
        for path in missing:
            print(f"missing source: {path}")
        return 1

    project_id = oid("project")
    target_id = oid("target:KLMSiOS")
    main_group_id = oid("group:main")
    ios_group_id = oid("group:KLMSiOS")
    shared_group_id = oid("group:KLMSShared")
    product_group_id = oid("group:products")
    sources_phase_id = oid("phase:sources")
    frameworks_phase_id = oid("phase:frameworks")
    resources_phase_id = oid("phase:resources")
    product_ref_id = oid("product:KLMSIPhone.app")
    asset_catalog_ref_id = oid("file:KLMSiOS/Assets.xcassets")
    asset_catalog_build_id = oid("build:KLMSiOS/Assets.xcassets")
    project_config_list_id = oid("config-list:project")
    target_config_list_id = oid("config-list:target")
    project_debug_id = oid("config:project:debug")
    project_release_id = oid("config:project:release")
    target_debug_id = oid("config:target:debug")
    target_release_id = oid("config:target:release")

    file_refs: list[tuple[Path, str, str, str]] = []
    for path in source_paths:
        rel = Path(os.path.relpath(path, PROJECT_ROOT))
        name = path.name
        ref_id = oid(f"file:{rel}")
        build_id = oid(f"build:{rel}")
        file_refs.append((rel, name, ref_id, build_id))

    ios_children = [
        f"\t\t\t\t{ref_id} /* {name} */,"
        for rel, name, ref_id, _ in file_refs
        if "Sources/KLMSiOS" in rel.as_posix()
    ]
    ios_children.append(f"\t\t\t\t{asset_catalog_ref_id} /* Assets.xcassets */,")
    shared_children = [
        f"\t\t\t\t{ref_id} /* {name} */,"
        for rel, name, ref_id, _ in file_refs
        if "Sources/KLMSShared" in rel.as_posix()
    ]
    source_build_files = [
        f"\t\t\t\t{build_id} /* {name} in Sources */,"
        for _, name, _, build_id in file_refs
    ]

    objects: list[str] = []

    objects.append("/* Begin PBXBuildFile section */")
    for _, name, ref_id, build_id in file_refs:
        objects.append(
            f"\t\t{build_id} /* {name} in Sources */ = "
            f"{{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};"
        )
    objects.append(
        f"\t\t{asset_catalog_build_id} /* Assets.xcassets in Resources */ = "
        f"{{isa = PBXBuildFile; fileRef = {asset_catalog_ref_id} /* Assets.xcassets */; }};"
    )
    objects.append("/* End PBXBuildFile section */")

    objects.append("")
    objects.append("/* Begin PBXFileReference section */")
    objects.append(
        f"\t\t{product_ref_id} /* KLMSiOS.app */ = "
        "{isa = PBXFileReference; explicitFileType = wrapper.application; "
        "includeInIndex = 0; path = KLMSiOS.app; sourceTree = BUILT_PRODUCTS_DIR; };"
    )
    for rel, name, ref_id, _ in file_refs:
        objects.append(
            f"\t\t{ref_id} /* {name} */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
            f"name = {quote(name)}; path = {quote(rel.as_posix())}; sourceTree = \"<group>\"; }};"
        )
    objects.append(
        f"\t\t{asset_catalog_ref_id} /* Assets.xcassets */ = "
        "{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; "
        "path = KLMSiOS/Assets.xcassets; sourceTree = \"<group>\"; };"
    )
    objects.append("/* End PBXFileReference section */")

    objects.append("")
    objects.append("/* Begin PBXFrameworksBuildPhase section */")
    objects.append(
        f"\t\t{frameworks_phase_id} /* Frameworks */ = "
        "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); "
        "runOnlyForDeploymentPostprocessing = 0; };"
    )
    objects.append("/* End PBXFrameworksBuildPhase section */")

    objects.append("")
    objects.append("/* Begin PBXGroup section */")
    objects.append(
        f"\t\t{main_group_id} = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{ios_group_id} /* KLMSiOS */,\n"
        f"\t\t\t\t{shared_group_id} /* KLMSShared */,\n"
        f"\t\t\t\t{product_group_id} /* Products */,\n"
        "\t\t\t);\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};"
    )
    objects.append(
        f"\t\t{ios_group_id} /* KLMSiOS */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        + "\n".join(ios_children)
        + "\n\t\t\t);\n"
        "\t\t\tname = KLMSiOS;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};"
    )
    objects.append(
        f"\t\t{shared_group_id} /* KLMSShared */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        + "\n".join(shared_children)
        + "\n\t\t\t);\n"
        "\t\t\tname = KLMSShared;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};"
    )
    objects.append(
        f"\t\t{product_group_id} /* Products */ = {{\n"
        "\t\t\tisa = PBXGroup;\n"
        "\t\t\tchildren = (\n"
        f"\t\t\t\t{product_ref_id} /* KLMSiOS.app */,\n"
        "\t\t\t);\n"
        "\t\t\tname = Products;\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};"
    )
    objects.append("/* End PBXGroup section */")

    objects.append("")
    objects.append("/* Begin PBXNativeTarget section */")
    objects.append(
        f"\t\t{target_id} /* KLMSiOS */ = {{\n"
        "\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {target_config_list_id} /* Build configuration list for PBXNativeTarget \"KLMSiOS\" */;\n"
        "\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{sources_phase_id} /* Sources */,\n"
        f"\t\t\t\t{frameworks_phase_id} /* Frameworks */,\n"
        f"\t\t\t\t{resources_phase_id} /* Resources */,\n"
        "\t\t\t);\n"
        "\t\t\tbuildRules = ();\n"
        "\t\t\tdependencies = ();\n"
        "\t\t\tname = KLMSiOS;\n"
        "\t\t\tproductName = KLMSiOS;\n"
        f"\t\t\tproductReference = {product_ref_id} /* KLMSiOS.app */;\n"
        "\t\t\tproductType = \"com.apple.product-type.application\";\n"
        "\t\t};"
    )
    objects.append("/* End PBXNativeTarget section */")

    objects.append("")
    objects.append("/* Begin PBXProject section */")
    objects.append(
        f"\t\t{project_id} /* Project object */ = {{\n"
        "\t\t\tisa = PBXProject;\n"
        "\t\t\tattributes = {\n"
        "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
        "\t\t\t\tLastSwiftUpdateCheck = 1600;\n"
        "\t\t\t\tLastUpgradeCheck = 1600;\n"
        "\t\t\t\tTargetAttributes = {\n"
        f"\t\t\t\t\t{target_id} = {{\n"
        "\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;\n"
        "\t\t\t\t\t};\n"
        "\t\t\t\t};\n"
        "\t\t\t};\n"
        f"\t\t\tbuildConfigurationList = {project_config_list_id} /* Build configuration list for PBXProject \"KLMSiOS\" */;\n"
        "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
        "\t\t\tdevelopmentRegion = ko;\n"
        "\t\t\thasScannedForEncodings = 0;\n"
        "\t\t\tknownRegions = (\n"
        "\t\t\t\tko,\n"
        "\t\t\t\ten,\n"
        "\t\t\t\tBase,\n"
        "\t\t\t);\n"
        f"\t\t\tmainGroup = {main_group_id};\n"
        f"\t\t\tproductRefGroup = {product_group_id} /* Products */;\n"
        "\t\t\tprojectDirPath = \"\";\n"
        "\t\t\tprojectRoot = \"\";\n"
        "\t\t\ttargets = (\n"
        f"\t\t\t\t{target_id} /* KLMSiOS */,\n"
        "\t\t\t);\n"
        "\t\t};"
    )
    objects.append("/* End PBXProject section */")

    objects.append("")
    objects.append("/* Begin PBXResourcesBuildPhase section */")
    objects.append(
        f"\t\t{resources_phase_id} /* Resources */ = "
        "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ("
        f"{asset_catalog_build_id} /* Assets.xcassets in Resources */,); "
        "runOnlyForDeploymentPostprocessing = 0; };"
    )
    objects.append("/* End PBXResourcesBuildPhase section */")

    objects.append("")
    objects.append("/* Begin PBXSourcesBuildPhase section */")
    objects.append(
        f"\t\t{sources_phase_id} /* Sources */ = {{\n"
        "\t\t\tisa = PBXSourcesBuildPhase;\n"
        "\t\t\tbuildActionMask = 2147483647;\n"
        "\t\t\tfiles = (\n"
        + "\n".join(source_build_files)
        + "\n\t\t\t);\n"
        "\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        "\t\t};"
    )
    objects.append("/* End PBXSourcesBuildPhase section */")

    project_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ANALYZER_NONNULL": "YES",
        "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION": "YES_AGGRESSIVE",
        "CLANG_CXX_LANGUAGE_STANDARD": "\"gnu++20\"",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_ENABLE_OBJC_WEAK": "YES",
        "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES",
        "CLANG_WARN_COMMA": "YES",
        "CLANG_WARN_CONSTANT_CONVERSION": "YES",
        "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
        "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES_ERROR",
        "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES",
        "CLANG_WARN_ENUM_CONVERSION": "YES",
        "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES",
        "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF": "YES",
        "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
        "CLANG_WARN_OBJC_ROOT_CLASS": "YES_ERROR",
        "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
        "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
        "CLANG_WARN_STRICT_PROTOTYPES": "YES",
        "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
        "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
        "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
        "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES",
        "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE",
        "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "6.0",
    }
    target_common = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": "\"../../Config/KLMSiOS.entitlements\"",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "\"\"",
        "GENERATE_INFOPLIST_FILE": "YES",
        "INFOPLIST_KEY_CFBundleDisplayName": "\"KLMS Sync\"",
        "INFOPLIST_KEY_LSApplicationCategoryType": "\"public.app-category.productivity\"",
        "INFOPLIST_KEY_NSLocalNetworkUsageDescription": "\"KLMS Sync가 같은 Wi-Fi 또는 개인 VPN의 Mac 앱에 동기화 실행 요청을 보내기 위해 로컬 네트워크를 사용합니다.\"",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "\"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\"",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "\"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight\"",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "LD_RUNPATH_SEARCH_PATHS": "\"$(inherited) @executable_path/Frameworks\"",
        "MARKETING_VERSION": "0.1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.local.KLMSync.iOS",
        "PRODUCT_NAME": "\"$(TARGET_NAME)\"",
        "SUPPORTED_PLATFORMS": "\"iphoneos iphonesimulator\"",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES",
        "SWIFT_VERSION": "6.0",
        "TARGETED_DEVICE_FAMILY": "\"1,2\"",
    }

    def settings_block(settings: dict[str, str], indent: str = "\t\t\t\t") -> str:
        return "\n".join(f"{indent}{key} = {value};" for key, value in settings.items())

    project_debug = dict(project_settings)
    project_debug.update(
        {
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": "\"DEBUG=1 $(inherited)\"",
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "MTL_FAST_MATH": "YES",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": "\"-Onone\"",
        }
    )
    project_release = dict(project_settings)
    project_release.update(
        {
            "COPY_PHASE_STRIP": "NO",
            "DEBUG_INFORMATION_FORMAT": "\"dwarf-with-dsym\"",
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "MTL_FAST_MATH": "YES",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "VALIDATE_PRODUCT": "YES",
        }
    )
    target_debug = dict(target_common)
    target_debug.update({"SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG"})
    target_release = dict(target_common)

    objects.append("")
    objects.append("/* Begin XCBuildConfiguration section */")
    for config_id, name, settings in [
        (project_debug_id, "Debug", project_debug),
        (project_release_id, "Release", project_release),
        (target_debug_id, "Debug", target_debug),
        (target_release_id, "Release", target_release),
    ]:
        objects.append(
            f"\t\t{config_id} /* {name} */ = {{\n"
            "\t\t\tisa = XCBuildConfiguration;\n"
            "\t\t\tbuildSettings = {\n"
            + settings_block(settings)
            + "\n\t\t\t};\n"
            f"\t\t\tname = {name};\n"
            "\t\t};"
        )
    objects.append("/* End XCBuildConfiguration section */")

    objects.append("")
    objects.append("/* Begin XCConfigurationList section */")
    objects.append(
        f"\t\t{project_config_list_id} /* Build configuration list for PBXProject \"KLMSiOS\" */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{project_debug_id} /* Debug */,\n"
        f"\t\t\t\t{project_release_id} /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};"
    )
    objects.append(
        f"\t\t{target_config_list_id} /* Build configuration list for PBXNativeTarget \"KLMSiOS\" */ = {{\n"
        "\t\t\tisa = XCConfigurationList;\n"
        "\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{target_debug_id} /* Debug */,\n"
        f"\t\t\t\t{target_release_id} /* Release */,\n"
        "\t\t\t);\n"
        "\t\t\tdefaultConfigurationIsVisible = 0;\n"
        "\t\t\tdefaultConfigurationName = Release;\n"
        "\t\t};"
    )
    objects.append("/* End XCConfigurationList section */")

    content = (
        "// !$*UTF8*$!\n"
        "{\n"
        "\tarchiveVersion = 1;\n"
        "\tclasses = {\n"
        "\t};\n"
        "\tobjectVersion = 56;\n"
        "\tobjects = {\n\n"
        + "\n".join(objects)
        + "\n\t};\n"
        f"\trootObject = {project_id} /* Project object */;\n"
        "}\n"
    )
    PBXPROJ.write_text(content, encoding="utf-8")
    SCHEME.parent.mkdir(parents=True, exist_ok=True)
    SCHEME.write_text(
        f"""<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<Scheme
   LastUpgradeVersion = \"1600\"
   version = \"1.3\">
   <BuildAction
      parallelizeBuildables = \"YES\"
      buildImplicitDependencies = \"YES\"
      buildArchitectures = \"Automatic\">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = \"YES\"
            buildForRunning = \"YES\"
            buildForProfiling = \"YES\"
            buildForArchiving = \"YES\"
            buildForAnalyzing = \"YES\">
            <BuildableReference
               BuildableIdentifier = \"primary\"
               BlueprintIdentifier = \"{target_id}\"
               BuildableName = \"KLMSiOS.app\"
               BlueprintName = \"KLMSiOS\"
               ReferencedContainer = \"container:KLMSiOS.xcodeproj\">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = \"Debug\"
      selectedDebuggerIdentifier = \"Xcode.DebuggerFoundation.Debugger.LLDB\"
      selectedLauncherIdentifier = \"Xcode.DebuggerFoundation.Launcher.LLDB\"
      shouldUseLaunchSchemeArgsEnv = \"YES\">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = \"Debug\"
      selectedDebuggerIdentifier = \"Xcode.DebuggerFoundation.Debugger.LLDB\"
      selectedLauncherIdentifier = \"Xcode.DebuggerFoundation.Launcher.LLDB\"
      launchStyle = \"0\"
      useCustomWorkingDirectory = \"NO\"
      ignoresPersistentStateOnLaunch = \"NO\"
      debugDocumentVersioning = \"YES\"
      debugServiceExtension = \"internal\"
      allowLocationSimulation = \"YES\">
      <BuildableProductRunnable
         runnableDebuggingMode = \"0\">
         <BuildableReference
            BuildableIdentifier = \"primary\"
            BlueprintIdentifier = \"{target_id}\"
            BuildableName = \"KLMSiOS.app\"
            BlueprintName = \"KLMSiOS\"
            ReferencedContainer = \"container:KLMSiOS.xcodeproj\">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = \"Release\"
      shouldUseLaunchSchemeArgsEnv = \"YES\"
      savedToolIdentifier = \"\"
      useCustomWorkingDirectory = \"NO\"
      debugDocumentVersioning = \"YES\">
      <BuildableProductRunnable
         runnableDebuggingMode = \"0\">
         <BuildableReference
            BuildableIdentifier = \"primary\"
            BlueprintIdentifier = \"{target_id}\"
            BuildableName = \"KLMSiOS.app\"
            BlueprintName = \"KLMSiOS\"
            ReferencedContainer = \"container:KLMSiOS.xcodeproj\">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = \"Debug\">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = \"Release\"
      revealArchiveInOrganizer = \"YES\">
   </ArchiveAction>
</Scheme>
""",
        encoding="utf-8",
    )
    print(PBXPROJ)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
