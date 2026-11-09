#!/usr/bin/env python3
"""Generates SpaceBridge.xcodeproj from the source tree.

Run from the repository root after adding or removing source files:

    python3 scripts/generate_xcodeproj.py

Object IDs are derived from file paths, so regenerating produces a stable diff.
(Alternatively, `xcodegen generate` with project.yml produces an equivalent project.)
"""
import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "SpaceBridge"
TESTS = "SpaceBridgeTests"
MOBILE = "SpaceBridgeMobile"   # iPhone + iPad
WATCH = "SpaceBridgeWatch"     # Apple Watch (embedded in the iPhone app)
SHARED = "Shared"
MOBILE_BUNDLE_ID = "com.geniusbridge.SpaceBridgeMobile"
IOS_DEPLOYMENT = "17.0"
WATCH_DEPLOYMENT = "10.0"
# Files from the Mac app that are also compiled into the iPhone and Watch apps.
CROSS_PLATFORM_FILES = ["SpaceBridge/Utilities/ByteFormatter.swift"]
BUNDLE_ID = "com.geniusbridge.SpaceBridge"
DEPLOYMENT = "14.0"
MARKETING_VERSION = "1.0.0"
BUILD = "1"


def oid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(value):
    """Quote a pbxproj string when needed."""
    safe = all(c.isalnum() or c in "._/$" for c in value) and value != ""
    return value if safe else '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".entitlements": "text.plist.entitlements",
    ".xcassets": "folder.assetcatalog",
    ".md": "net.daringfireball.markdown",
}

objects = {}  # id -> text
build_files = []


def add(object_id, body):
    objects[object_id] = body


def scan_group(rel_dir, target):
    """Returns (group_id, source_build_ids, resource_build_ids)."""
    group_id = oid("group", rel_dir)
    children = []
    sources, resources = [], []
    full = os.path.join(ROOT, rel_dir)
    entries = sorted(os.listdir(full), key=lambda n: (not os.path.isdir(os.path.join(full, n)) or n.endswith(".xcassets"), n.lower()))
    for name in entries:
        if name.startswith("."):
            continue
        rel = os.path.join(rel_dir, name)
        path = os.path.join(ROOT, rel)
        ext = os.path.splitext(name)[1]
        if os.path.isdir(path) and ext != ".xcassets":
            child_group, s, r = scan_group(rel, target)
            children.append((child_group, name))
            sources += s
            resources += r
            continue
        if ext not in FILE_TYPES:
            continue
        ref = oid("ref", rel)
        add(ref, f'{{isa = PBXFileReference; lastKnownFileType = {FILE_TYPES[ext]}; path = {q(name)}; sourceTree = "<group>"; }}')
        children.append((ref, name))
        if ext == ".swift":
            bid = oid("build", target, rel)
            add(bid, f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }}")
            sources.append((bid, name))
        elif ext == ".xcassets":
            bid = oid("build", target, rel)
            add(bid, f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }}")
            resources.append((bid, name))
    child_text = "".join(f"\n\t\t\t\t{cid} /* {cname} */," for cid, cname in children)
    add(group_id, f'{{isa = PBXGroup; children = ({child_text}\n\t\t\t); path = {q(os.path.basename(rel_dir))}; sourceTree = "<group>"; }}')
    return group_id, sources, resources


app_group, app_sources, app_resources = scan_group(APP, APP)
test_group, test_sources, _ = scan_group(TESTS, TESTS)
mobile_group, mobile_sources, mobile_resources = scan_group(MOBILE, MOBILE)
watch_group, watch_sources, watch_resources = scan_group(WATCH, WATCH)
shared_group, mobile_shared, _ = scan_group(SHARED, MOBILE)
_, watch_shared, _ = scan_group(SHARED, WATCH)


def extra_sources(target):
    result = []
    for rel in CROSS_PLATFORM_FILES:
        bid = oid("build", target, rel)
        add(bid, f"{{isa = PBXBuildFile; fileRef = {oid('ref', rel)} /* {os.path.basename(rel)} */; }}")
        result.append((bid, os.path.basename(rel)))
    return result


mobile_sources += mobile_shared + extra_sources(MOBILE)
watch_sources += watch_shared + extra_sources(WATCH)

# Products
app_product = oid("product", APP)
test_product = oid("product", TESTS)
add(app_product, f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }}")
add(test_product, f"{{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = {TESTS}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }}")
mobile_product = oid("product", MOBILE)
watch_product = oid("product", WATCH)
add(mobile_product, f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {MOBILE}.app; sourceTree = BUILT_PRODUCTS_DIR; }}")
add(watch_product, f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {WATCH}.app; sourceTree = BUILT_PRODUCTS_DIR; }}")
products_group = oid("group", "Products")
add(products_group, f'{{isa = PBXGroup; children = (\n\t\t\t\t{app_product} /* {APP}.app */,\n\t\t\t\t{test_product} /* {TESTS}.xctest */,\n\t\t\t\t{mobile_product} /* {MOBILE}.app */,\n\t\t\t\t{watch_product} /* {WATCH}.app */,\n\t\t\t); name = Products; sourceTree = "<group>"; }}')

extra_refs = []
for name in ["README.md", "MONETIZATION.md"]:
    if os.path.exists(os.path.join(ROOT, name)):
        ref = oid("ref", name)
        add(ref, f'{{isa = PBXFileReference; lastKnownFileType = {FILE_TYPES[".md"]}; path = {q(name)}; sourceTree = "<group>"; }}')
        extra_refs.append((ref, name))

main_group = oid("group", "main")
main_children = [(app_group, APP), (mobile_group, MOBILE), (watch_group, WATCH), (shared_group, SHARED), (test_group, TESTS)] + extra_refs + [(products_group, "Products")]
add(main_group, "{isa = PBXGroup; children = (" + "".join(f"\n\t\t\t\t{i} /* {n} */," for i, n in main_children) + '\n\t\t\t); sourceTree = "<group>"; }')


def phase(kind, name, target, items):
    pid = oid("phase", kind, target)
    files = "".join(f"\n\t\t\t\t{bid} /* {n} in {name} */," for bid, n in items)
    add(pid, f"{{isa = {kind}; buildActionMask = 2147483647; files = ({files}\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; }}")
    return pid


app_phases = [
    phase("PBXSourcesBuildPhase", "Sources", APP, app_sources),
    phase("PBXFrameworksBuildPhase", "Frameworks", APP, []),
    phase("PBXResourcesBuildPhase", "Resources", APP, app_resources),
]
watch_phases = [
    phase("PBXSourcesBuildPhase", "Sources", WATCH, watch_sources),
    phase("PBXFrameworksBuildPhase", "Frameworks", WATCH, []),
    phase("PBXResourcesBuildPhase", "Resources", WATCH, watch_resources),
]
embed_watch_file = oid("build", MOBILE, "embed-watch")
add(embed_watch_file, f"{{isa = PBXBuildFile; fileRef = {watch_product} /* {WATCH}.app */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }}")
embed_watch_phase = oid("phase", "embed-watch", MOBILE)
add(embed_watch_phase, f'{{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = "$(CONTENTS_FOLDER_PATH)/Watch"; dstSubfolderSpec = 16; files = (\n\t\t\t\t{embed_watch_file} /* {WATCH}.app in Embed Watch Content */,\n\t\t\t); name = "Embed Watch Content"; runOnlyForDeploymentPostprocessing = 0; }}')
mobile_phases = [
    phase("PBXSourcesBuildPhase", "Sources", MOBILE, mobile_sources),
    phase("PBXFrameworksBuildPhase", "Frameworks", MOBILE, []),
    phase("PBXResourcesBuildPhase", "Resources", MOBILE, mobile_resources),
    embed_watch_phase,
]
test_phases = [
    phase("PBXSourcesBuildPhase", "Sources", TESTS, test_sources),
    phase("PBXFrameworksBuildPhase", "Frameworks", TESTS, []),
    phase("PBXResourcesBuildPhase", "Resources", TESTS, []),
]


def settings(values):
    lines = []
    for key in sorted(values):
        value = values[key]
        if isinstance(value, list):
            inner = "".join(f"\n\t\t\t\t\t{q(v)}," for v in value)
            lines.append(f"\n\t\t\t\t{key} = ({inner}\n\t\t\t\t);")
        else:
            lines.append(f"\n\t\t\t\t{key} = {q(str(value))};")
    return "{" + "".join(lines) + "\n\t\t\t}"


common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "CLANG_WARN_INFINITE_RECURSION": "YES",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "COPY_PHASE_STRIP": "NO",
    "DEAD_CODE_STRIPPING": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "GCC_WARN_UNUSED_VARIABLE": "YES",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT,
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "5.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
}
project_debug = dict(common, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
project_release = dict(common, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "MTL_ENABLE_DEBUG_INFO": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
})
app_settings = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_ENTITLEMENTS": f"{APP}/Resources/{APP}.entitlements",
    # "-" = ad-hoc "Sign to Run Locally". Set DEVELOPMENT_TEAM and use a Developer ID
    # certificate for distribution (see README / scripts/release.sh).
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Automatic",
    "COMBINE_HIDPI_IMAGES": "YES",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEVELOPMENT_TEAM": "",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "NO",
    "INFOPLIST_FILE": f"{APP}/Resources/Info.plist",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
}
test_settings = {
    "BUNDLE_LOADER": "$(TEST_HOST)",
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "GENERATE_INFOPLIST_FILE": "YES",
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + "Tests",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "TEST_HOST": f"$(BUILT_PRODUCTS_DIR)/{APP}.app/Contents/MacOS/{APP}",
}


mobile_settings = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEVELOPMENT_TEAM": "",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "SpaceBridge",
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.utilities",
    "INFOPLIST_KEY_NSHumanReadableCopyright": "© 2026 Genius Bridge Technologies",
    "INFOPLIST_KEY_NSPhotoLibraryUsageDescription": "SpaceBridge analyzes photo and video sizes on this device to find large videos, screenshots and duplicates. Nothing leaves your device.",
    "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
    "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad": "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone": "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
    "IPHONEOS_DEPLOYMENT_TARGET": IOS_DEPLOYMENT,
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": MOBILE_BUNDLE_ID,
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": "1,2",
}
watch_settings = {
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "CODE_SIGN_STYLE": "Automatic",
    "CURRENT_PROJECT_VERSION": BUILD,
    "DEVELOPMENT_TEAM": "",
    "ENABLE_PREVIEWS": "YES",
    "GENERATE_INFOPLIST_FILE": "YES",
    "INFOPLIST_KEY_CFBundleDisplayName": "SpaceBridge",
    "INFOPLIST_KEY_WKCompanionAppBundleIdentifier": MOBILE_BUNDLE_ID,
    "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp": "NO",
    "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    "MARKETING_VERSION": MARKETING_VERSION,
    "PRODUCT_BUNDLE_IDENTIFIER": MOBILE_BUNDLE_ID + ".watchkitapp",
    "PRODUCT_NAME": "$(TARGET_NAME)",
    "SDKROOT": "watchos",
    "SKIP_INSTALL": "YES",
    "SUPPORTED_PLATFORMS": "watchos watchsimulator",
    "SWIFT_EMIT_LOC_STRINGS": "YES",
    "TARGETED_DEVICE_FAMILY": "4",
    "WATCHOS_DEPLOYMENT_TARGET": WATCH_DEPLOYMENT,
}


def config_list(owner, debug, release, default="Release"):
    debug_id, release_id, list_id = oid("cfg", owner, "Debug"), oid("cfg", owner, "Release"), oid("cfglist", owner)
    add(debug_id, f"{{isa = XCBuildConfiguration; buildSettings = {settings(debug)}; name = Debug; }}")
    add(release_id, f"{{isa = XCBuildConfiguration; buildSettings = {settings(release)}; name = Release; }}")
    add(list_id, f"{{isa = XCConfigurationList; buildConfigurations = (\n\t\t\t\t{debug_id} /* Debug */,\n\t\t\t\t{release_id} /* Release */,\n\t\t\t); defaultConfigurationIsVisible = 0; defaultConfigurationName = {default}; }}")
    return list_id


project_id = oid("project")
app_target = oid("target", APP)
test_target = oid("target", TESTS)
mobile_target = oid("target", MOBILE)
watch_target = oid("target", WATCH)

app_cfg = config_list(APP, app_settings, app_settings)
test_cfg = config_list(TESTS, test_settings, test_settings)
mobile_cfg = config_list(MOBILE, mobile_settings, mobile_settings)
watch_cfg = config_list(WATCH, watch_settings, watch_settings)
project_cfg = config_list("project", project_debug, project_release)

proxy = oid("proxy", TESTS)
dependency = oid("dependency", TESTS)
add(proxy, f"{{isa = PBXContainerItemProxy; containerPortal = {project_id} /* Project object */; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = {APP}; }}")
add(dependency, f"{{isa = PBXTargetDependency; target = {app_target} /* {APP} */; targetProxy = {proxy} /* PBXContainerItemProxy */; }}")
watch_proxy = oid("proxy", WATCH)
watch_dependency = oid("dependency", WATCH)
add(watch_proxy, f"{{isa = PBXContainerItemProxy; containerPortal = {project_id} /* Project object */; proxyType = 1; remoteGlobalIDString = {watch_target}; remoteInfo = {WATCH}; }}")
add(watch_dependency, f"{{isa = PBXTargetDependency; target = {watch_target} /* {WATCH} */; targetProxy = {watch_proxy} /* PBXContainerItemProxy */; }}")


def target(tid, name, cfg, phases, product, product_type, deps):
    phase_text = "".join(f"\n\t\t\t\t{p}," for p in phases)
    dep_text = "".join(f"\n\t\t\t\t{d}," for d in deps)
    add(tid, f"{{isa = PBXNativeTarget; buildConfigurationList = {cfg}; buildPhases = ({phase_text}\n\t\t\t); buildRules = (\n\t\t\t); dependencies = ({dep_text}\n\t\t\t); name = {name}; productName = {name}; productReference = {product}; productType = {q(product_type)}; }}")


target(app_target, APP, app_cfg, app_phases, app_product, "com.apple.product-type.application", [])
target(test_target, TESTS, test_cfg, test_phases, test_product, "com.apple.product-type.bundle.unit-test", [dependency])
target(mobile_target, MOBILE, mobile_cfg, mobile_phases, mobile_product, "com.apple.product-type.application", [watch_dependency])
target(watch_target, WATCH, watch_cfg, watch_phases, watch_product, "com.apple.product-type.application", [])

add(project_id, f"""{{isa = PBXProject; attributes = {{BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; ORGANIZATIONNAME = "Genius Bridge Technologies"; TargetAttributes = {{{app_target} = {{CreatedOnToolsVersion = 16.0; }}; {test_target} = {{CreatedOnToolsVersion = 16.0; TestTargetID = {app_target}; }}; {mobile_target} = {{CreatedOnToolsVersion = 16.0; }}; {watch_target} = {{CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {project_cfg}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = {main_group}; productRefGroup = {products_group} /* Products */; projectDirPath = ""; projectRoot = ""; targets = (\n\t\t\t\t{app_target} /* {APP} */,\n\t\t\t\t{test_target} /* {TESTS} */,\n\t\t\t\t{mobile_target} /* {MOBILE} */,\n\t\t\t\t{watch_target} /* {WATCH} */,\n\t\t\t); }}""")

out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {"]
for object_id in sorted(objects):
    out.append(f"\t\t{object_id} = {objects[object_id]};")
out += ["\t};", f"\trootObject = {project_id} /* Project object */;", "}", ""]

project_dir = os.path.join(ROOT, f"{APP}.xcodeproj")
os.makedirs(os.path.join(project_dir, "xcshareddata", "xcschemes"), exist_ok=True)
with open(os.path.join(project_dir, "project.pbxproj"), "w") as handle:
    handle.write("\n".join(out))

workspace_dir = os.path.join(project_dir, "project.xcworkspace")
os.makedirs(workspace_dir, exist_ok=True)
with open(os.path.join(workspace_dir, "contents.xcworkspacedata"), "w") as handle:
    handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')

scheme = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{APP}.app" BlueprintName = "{APP}" ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO" parallelizable = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{test_target}" BuildableName = "{TESTS}.xctest" BlueprintName = "{TESTS}" ReferencedContainer = "container:{APP}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{APP}.app" BlueprintName = "{APP}" ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{APP}.app" BlueprintName = "{APP}" ReferencedContainer = "container:{APP}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
with open(os.path.join(project_dir, "xcshareddata", "xcschemes", f"{APP}.xcscheme"), "w") as handle:
    handle.write(scheme)

print(f"Wrote {project_dir} ({len(app_sources)} app sources, {len(test_sources)} test sources, {len(objects)} objects)")


def simple_scheme(target_id, name):
    ref = f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_id}" BuildableName = "{name}.app" BlueprintName = "{name}" ReferencedContainer = "container:{APP}.xcodeproj">\n            </BuildableReference>'
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
            {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


for target_id, name in [(mobile_target, MOBILE), (watch_target, WATCH)]:
    with open(os.path.join(project_dir, "xcshareddata", "xcschemes", f"{name}.xcscheme"), "w") as handle:
        handle.write(simple_scheme(target_id, name))
