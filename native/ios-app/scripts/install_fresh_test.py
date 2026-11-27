"""Make a side-by-side, Wi-Fi-only installation of the current personal iOS app."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import uuid

SIMULATOR_BUNDLE_IDS = {"org.myai.development", "org.ailove.development"}
LOCAL_SIGNING_CONFIG = "myai.local.xcconfig"
LEGACY_SIGNING_CONFIG = "ailove.local.xcconfig"
XCODE_SCHEME = "myai"
TARGET = "aarch64-apple-ios"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def numbered_identity_pattern(bundle_id):
    return re.escape(bundle_id) + r"\.qa\.t(\d+)-([0-9a-f]{32})"


def production_bundle_id(bundle_id):
    numbered = re.fullmatch(r"(.+)\.qa\.t\d+-[0-9a-f]{32}", bundle_id)
    if numbered:
        return numbered[1]
    if bundle_id.endswith(".firstuse"):
        return bundle_id[:-len(".firstuse")]
    return None


def validate_production_bundle_id(bundle_id):
    require(bundle_id and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+", bundle_id)
            and bundle_id not in SIMULATOR_BUNDLE_IDS and production_bundle_id(bundle_id) is None,
            "Set MYAI_BUNDLE_ID to your own reverse-DNS app identifier in myai.local.xcconfig, or use --bundle-id.")


def read_local_signing_config(repo):
    config = {}
    for filename in (LEGACY_SIGNING_CONFIG, LOCAL_SIGNING_CONFIG):
        path = repo / "native/ios-app" / filename
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            match = re.fullmatch(r"\s*(DEVELOPMENT_TEAM|MYAI_BUNDLE_ID|AILOVE_BUNDLE_ID)\s*=\s*(\S+)",
                                 line.partition("//")[0].strip())
            if match:
                key = "MYAI_BUNDLE_ID" if match[1] == "AILOVE_BUNDLE_ID" else match[1]
                config[key] = match[2]
    return config


def make_identity(bundle_id, number, suffix):
    bundle = f"{bundle_id}.qa.t{number:02d}-{suffix}"
    return {"number": number, "bundle_id": bundle, "group": "group." + bundle,
            "name": f"myai Test {number:02d}", "scheme": "myai-test-" + suffix}


def new_identity(bundle_id, number):
    return make_identity(bundle_id, number, uuid.uuid4().hex)


def validate_identity(identity, bundle_id):
    validate_production_bundle_id(bundle_id)
    number = identity["number"]
    legacy = bundle_id + ".firstuse"
    if type(number) is int and identity == {
        "number": 1, "bundle_id": legacy, "group": "group." + legacy,
        "name": "ailove 测试版", "scheme": "ailove-firstuse",
    }:
        return
    match = re.fullmatch(numbered_identity_pattern(bundle_id), identity["bundle_id"])
    require(type(number) is int and number >= 1 and match,
            "The reserved test app does not belong to the configured bundle identifier.")
    current = make_identity(bundle_id, number, match[2])
    previous = {**current, "name": f"ailove Test {number:02d}", "scheme": "ailove-test-" + match[2]}
    previous_chinese = {**previous, "name": f"ailove 测试{number:02d}"}
    require(identity in (current, previous, previous_chinese),
            "The saved test app identity is incomplete. Check state.json.")


def next_number(apps, last_number, bundle_id):
    for app in apps:
        bundle = app.get("bundleIdentifier", "")
        if bundle == bundle_id + ".firstuse":
            last_number = max(1, last_number)
        match = re.fullmatch(numbered_identity_pattern(bundle_id), bundle)
        if match:
            last_number = max(last_number, int(match[1]))
    return last_number + 1


def wireless_phones(devices):
    phones = []
    for device in devices:
        props = device.get("properties", {})
        conn = props.get("connection", device.get("connectionProperties", {}))
        hardware = props.get("hardware", device.get("hardwareProperties", {}))
        state = props.get("state", device.get("deviceProperties", {}))
        # A discoverable paired Wi-Fi phone may report disconnected until a service opens.
        if (conn.get("transportType") == "localNetwork" and conn.get("pairingState") == "paired"
                and conn.get("state", conn.get("tunnelState")) in ("connected", "connecting", "disconnected")
                and hardware.get("deviceType") == "iPhone" and hardware.get("reality", "physical") == "physical"
                and hardware.get("udid")):
            phones.append({"udid": hardware["udid"], "name": state.get("name") or hardware["deviceType"],
                           "identifier": device.get("identifier", "")})
    return phones


def device_result(arguments, log_dir, filename, timeout=35):
    log_dir.mkdir(parents=True, exist_ok=True)
    path = log_dir / (filename + ".json")
    subprocess.run(["xcrun", "devicectl", *arguments, "--timeout", str(timeout),
                    "--quiet", "--json-output", str(path)], check=True)
    return json.loads(path.read_text())["result"]


def select_phone(requested, log_dir):
    phones = wireless_phones(device_result(["list", "devices"], log_dir, "route")["devices"])
    if requested:
        phones = [p for p in phones if requested.casefold() in
                  {p["udid"].casefold(), p["identifier"].casefold(), p["name"].casefold()}]
    require(phones, "No paired iPhone was found on Wi-Fi. Unplug the cable, unlock the iPhone, and connect it and your Mac to the same Wi-Fi.")
    if len(phones) == 1:
        return phones[0]
    for number, phone in enumerate(phones, 1):
        print(f"  {number}. {phone['name']}  {phone['udid']}")
    require(sys.stdin.isatty(), "Multiple Wi-Fi iPhones were found. Use --device to select one.")
    answer = input("Choose an iPhone by number: ").strip()
    require(answer.isdecimal() and 1 <= int(answer) <= len(phones), "Invalid device number.")
    return phones[int(answer) - 1]


def installed_apps(device, log_dir, predicate):
    return device_result(["device", "info", "apps", "--device", device["udid"],
                          "--filter", predicate], log_dir, "apps")["apps"]


def setting(path, name):
    match = re.search(r"^\s*" + re.escape(name) + r':\s*"?([\w.-]+)"?\s*$', path.read_text(), re.M)
    require(match, f"Could not find {name} in {path}.")
    return match[1]


def replace(path, old, new):
    original = path.read_text()
    require(old in original, f"Could not find the expected setting in {path.name}.")
    path.write_text(original.replace(old, new))


def brand_catalog(path, name, scheme):
    catalog = json.loads(path.read_text())

    def brand(text):
        # Keep identifiers and the replacement URL scheme intact. Chinese can adjoin the name.
        return re.sub(r"(?<![a-zA-Z0-9_.])myai(?![a-zA-Z0-9_:/-]|\.[a-zA-Z])", name,
                      text.replace("myai://", scheme + "://"))

    def translate(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "stringUnit":
                    value["value"] = brand(value["value"])
                else:
                    translate(value)
    entries = {}
    for key, entry in catalog["strings"].items():
        translate(entry)
        if brand(key) != key and "en" not in entry.get("localizations", {}):
            entry.setdefault("localizations", {})["en"] = {
                "stringUnit": {"state": "translated", "value": brand(key)}}
        entries[key.replace("myai://", scheme + "://")] = entry
    catalog["strings"] = entries
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2))


def stage_sources(repo, work, identity, bundle_id, team):
    """Prepare only a private source copy. Project generation and signing happen later."""
    validate_identity(identity, bundle_id)
    source_native = (repo / "native").resolve()
    destination = (work / "native").resolve()
    require(not destination.is_relative_to(source_native) and not source_native.is_relative_to(destination),
            "The test work directory must be separate from the checkout.")
    work.mkdir(parents=True, exist_ok=True)
    marker = work / ".myai-fresh-work"
    require(not (work / "native").exists() or marker.is_file(), "The work directory contains sources that this installer did not create.")
    marker.touch()
    original = repo / "native/ios-app"
    native = work / "native"
    if native.exists():
        shutil.rmtree(native)
    src = native / "ios-app"
    shutil.copytree(original, src, ignore=shutil.ignore_patterns("*.xcodeproj", "xcuserdata", ".DS_Store",
                                                                LOCAL_SIGNING_CONFIG, LEGACY_SIGNING_CONFIG))
    for component in ("ios", "ios-gym", "codex-voice"):
        (native / component).symlink_to(repo / "native" / component, target_is_directory=True)
    (native / "launcher").mkdir()
    (native / "launcher/include").symlink_to(repo / "native/launcher/include", target_is_directory=True)
    (work / "build").mkdir(exist_ok=True)
    voice = work / "build/codex-voice"
    if not voice.is_symlink():
        voice.symlink_to(repo / "build/codex-voice", target_is_directory=True)

    bundle, name, scheme = (identity[key] for key in ("bundle_id", "name", "scheme"))
    base = src / "project-base.yml"
    # Give XcodeGen the concrete signing identity in this private project so it records the team
    # in the generated target attributes and Xcode can provision the exact App Group.
    replace(src / "myai.yml", "    CODE_SIGN_STYLE: Automatic",
            f"    DEVELOPMENT_TEAM: {team}\n    CODE_SIGN_STYLE: Automatic")
    replace(base, "bundleIdPrefix: org.myai.development", f"bundleIdPrefix: {bundle}")
    replace(base, "configFiles:\n  Debug: myai.xcconfig\n  Release: myai.xcconfig\n", "")
    replace(base, "POKI_BUNDLE_ID: $(MYAI_BUNDLE_ID)", f"POKI_BUNDLE_ID: {bundle}")
    group = identity["group"]
    replace(base, "POKI_APP_GROUP: group.$(POKI_BUNDLE_ID)", f"POKI_APP_GROUP: {group}")
    replace(base, 'com.apple.security.application-groups: ["$(POKI_APP_GROUP)"]',
            f'com.apple.security.application-groups: ["{group}"]')
    replace(base, "POKI_DISPLAY_NAME: myai", "POKI_DISPLAY_NAME: " + name)
    replace(base, "CFBundleURLSchemes: [myai]", f"CFBundleURLSchemes: [{scheme}]")
    replace(src / "project.yml", "CFBundleDisplayName: myai VPN", f"CFBundleDisplayName: {name} VPN")
    require("pairer.start(hostName: AppBrand.name" in (src / "Poki/App/AppModel.swift").read_text(),
            "The pairing host name no longer matches the configured app name.")
    replace(src / "Shared/AppLocalization.swift", 'static let name = "myai"', f'static let name = "{name}"')
    replace(src / "Poki/App/PokiApp.swift", 'url.scheme == "myai"', f'url.scheme == "{scheme}"')
    replace(src / "Poki/Setup/PairingScanner.swift", '["myai", "ailove", "poki"]', f'["{scheme}", "myai", "ailove", "poki"]')
    replace(src / "Poki/LaunchScreen.storyboard", 'text="myai"', f'text="{name}"')
    # Keep Swift and the Rust voice backend on their shared protocol service names.
    # Each new app has its own signed Keychain access group; verify_package enforces it.
    for component in ("Poki", "PokiWidgets", "Shared", "PokiTunnel"):
        for path in (src / component).rglob("*.swift"):
            original_text = path.read_text()
            if "myai://" in original_text:
                path.write_text(original_text.replace("myai://", scheme + "://"))
        for path in (src / component).rglob("*.xcstrings"):
            brand_catalog(path, name, scheme)
    return src


def build_app(repo, store, identity, team, bundle_id):
    work = store / "work"
    src = stage_sources(repo, work, identity, bundle_id, team)
    group = identity["group"]
    require(group == "group." + identity["bundle_id"], "The test App Group does not match the reserved bundle identifier.")
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join([env.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin",
                                   str(Path.home() / ".cargo/bin")])
    if env.get("CARGO_HOME"):
        env["PATH"] = env["CARGO_HOME"] + "/bin:" + env["PATH"]
    target_cache = store / "launcher-cache"
    (src.parent / "launcher/target").symlink_to(target_cache, target_is_directory=True)
    packages = store / "packages"
    log = store / "build.log"
    print(f"Building and signing {identity['name']}. Build log: {log}", flush=True)
    with log.open("w") as output:
        def run(args, **kwargs):
            subprocess.run(args, env=env, stdout=output, stderr=subprocess.STDOUT, check=True, cwd=repo, **kwargs)
        run([str(repo / "native/launcher/fetch-idevice.sh")])
        run(["rustup", "target", "add", TARGET])
        run(["cargo", "build", "--release", "--locked", "--target", TARGET, "--target-dir", str(target_cache),
             "--manifest-path", str(repo / "native/launcher/Cargo.toml"), "--jobs", "3"])
        run([str(src / "scripts/make-assets.sh")])
        run([str(src / "scripts/generate-myai-project.sh")])
        project = src / "myai.xcodeproj"
        run(["xcodebuild", "-project", str(project), "-scheme", XCODE_SCHEME, "-configuration", "Release",
             "-destination", "generic/platform=iOS", "-derivedDataPath", str(store / "DerivedData"),
             "-clonedSourcePackagesDirPath", str(packages), "-onlyUsePackageVersionsFromResolvedFile",
             "-jobs", "3", "-allowProvisioningUpdates", f"DEVELOPMENT_TEAM={team}", "CODE_SIGN_STYLE=Automatic",
             "CODE_SIGN_IDENTITY=Apple Development", "build"])
    app = store / "DerivedData/Build/Products/Release-iphoneos/Poki.app"
    return app, setting(src / "project-base.yml", "MARKETING_VERSION"), setting(src / "project-base.yml", "CURRENT_PROJECT_VERSION")


def verify_package(app, identity, team, udid, version, build):
    bundle_id, name = identity["bundle_id"], identity["name"]
    extensions = list((app / "PlugIns").glob("*.appex"))
    require(len(extensions) == 2, "Expected the widget and built-in VPN extensions.")
    expected = {bundle_id, bundle_id + ".widgets", bundle_id + ".tunnel"}
    seen = set()
    for bundle in [app, *extensions]:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        identifier = info["CFBundleIdentifier"]
        require(identifier in expected - seen and (bundle == app) == (identifier == bundle_id), "The signed app contains an unexpected bundle identifier.")
        seen.add(identifier)
        tunnel = identifier == bundle_id + ".tunnel"
        widgets = identifier == bundle_id + ".widgets"
        require(info["CFBundleDisplayName"] == (name + " VPN" if tunnel else name), "The signed app display name is incorrect.")
        require((info["CFBundleShortVersionString"], info["CFBundleVersion"]) == (version, build), "The main app or extension version does not match the build.")
        signature = plistlib.loads(subprocess.check_output(
            ["codesign", "-d", "--entitlements", "-", "--xml", str(bundle)], stderr=subprocess.PIPE))
        profile = plistlib.loads(subprocess.check_output(
            ["security", "cms", "-D", "-i", str(bundle / "embedded.mobileprovision")], stderr=subprocess.PIPE))
        allowed = profile["Entitlements"]
        app_id = team + "." + identifier
        require(team in profile["TeamIdentifier"] and signature.get("com.apple.developer.team-identifier") == team
                and signature.get("application-identifier") == allowed.get("application-identifier") == app_id,
                "The signing team or application identifier does not match.")
        require(udid.casefold() in {item.casefold() for item in profile.get("ProvisionedDevices", [])},
                "The provisioning profile does not include this iPhone. Register the device with your Apple developer account and retry.")
        require(profile["ExpirationDate"] > datetime.datetime.utcnow(), "The provisioning profile has expired.")
        require(set(signature.get("keychain-access-groups", [])) <= {app_id}, "The signature includes another app’s Keychain group.")
        for entitlement, needed in [
            ("com.apple.security.application-groups", set() if tunnel else {identity["group"]}),
            ("com.apple.developer.networking.networkextension", set() if widgets else {"packet-tunnel-provider"}),
        ]:
            require(set(signature.get(entitlement, [])) == needed and needed <= set(allowed.get(entitlement, [])),
                    f"The signed entitlement for {identifier} does not match this test build: {entitlement}")
        if not tunnel:
            require(info.get("PokiAppGroup") == identity["group"], "The shared container does not match the signature.")
        if bundle != app:
            point = "com.apple.networkextension.packet-tunnel" if tunnel else "com.apple.widgetkit-extension"
            require(info.get("NSExtension", {}).get("NSExtensionPointIdentifier") == point, "The extension type does not match.")
        else:
            schemes = {scheme for row in info["CFBundleURLTypes"] for scheme in row["CFBundleURLSchemes"]}
            require(schemes == {identity["scheme"]}, "The signed app uses another app’s URL scheme.")
    require(seen == expected, "The signed app is missing a required extension.")
    for language in ("en", "zh-Hans", "zh-Hant"):
        directory = app / (language + ".lproj")
        info = plistlib.loads((directory / "InfoPlist.strings").read_bytes())
        messages = plistlib.loads((directory / "Localizable.strings").read_bytes())
        instruction = "In Settings, open Privacy & Security › Developer Mode and choose Pair with myai."
        require(info.get("CFBundleDisplayName") == name and name in messages.get(instruction, ""),
                f"The Home Screen name or pairing host name is incorrect for {language}.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


def install_and_verify(device, identity, app, version, build, log_dir, bundle_id):
    validate_identity(identity, bundle_id)
    bundle = identity["bundle_id"]
    predicate = f"bundleIdentifier == '{bundle}'"

    def already_installed():
        apps = installed_apps(device, log_dir, predicate)
        matches = [entry for entry in apps if entry.get("bundleIdentifier") == bundle]
        if not matches:
            return False
        require(len(matches) == 1 and (matches[0].get("name"), matches[0].get("version"),
                matches[0].get("bundleVersion")) == (identity["name"], version, build),
                "An installed app with this identifier has a different name or version. Installation stopped.")
        return True

    select_phone(device["udid"], log_dir)
    if not already_installed():
        # Repeat discovery immediately before delivery; the route may have changed during signing.
        select_phone(device["udid"], log_dir)
        print(f"Installing {identity['name']} over Wi-Fi…", flush=True)
        device_result(["device", "install", "app", "--device", device["udid"], str(app)],
                      log_dir, "install", timeout=150)
        select_phone(device["udid"], log_dir)
        require(already_installed(), "The test app was not found after installation. Rerun to check again.")
    print(f"Verified {identity['name']} {version} ({build}) on {device.get('name', device['udid'])}.")


def write_state(path, state):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
    temp.replace(path)


def product_directory(repo):
    # iCloud Drive can add Finder metadata to signed bundles even after a clean copy.
    checkout = hashlib.sha256(os.fsencode(repo.resolve())).hexdigest()[:16]
    return Path.home() / "Library/Caches/myai-first-use" / checkout


def run_install(repo, store, device_arg=None, team_arg=None, products=None, bundle_id_arg=None):
    store.mkdir(parents=True, exist_ok=True)
    products = products or store
    products.mkdir(parents=True, exist_ok=True)
    with (store / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("Another test installation is in progress.") from None
        path = store / "state.json"
        state = json.loads(path.read_text()) if path.exists() else {"last_number": 0, "pending": None}
        pending = state["pending"]
        settings = read_local_signing_config(repo)
        pending_bundle = production_bundle_id(pending["identity"]["bundle_id"]) if pending else None
        bundle_id = bundle_id_arg or pending_bundle or settings.get("MYAI_BUNDLE_ID")
        validate_production_bundle_id(bundle_id)
        team = team_arg or (pending and pending["team"]) or settings.get("DEVELOPMENT_TEAM")
        require(team and re.fullmatch(r"[A-Z0-9]{10}", team),
                "Set DEVELOPMENT_TEAM to your 10-character Apple Team ID in myai.local.xcconfig, or use --team.")
        if pending:
            validate_identity(pending["identity"], bundle_id)
        logs = store / "device"
        device = select_phone(device_arg or (pending and pending["device"]), logs)
        if pending:
            require(pending["device"].casefold() == device["udid"].casefold() and pending["team"] == team,
                    "Resume the previous installation with the same iPhone and Apple development team.")
        else:
            apps = installed_apps(device, logs, f"bundleIdentifier BEGINSWITH '{bundle_id}.'")
            identity = new_identity(bundle_id, next_number(apps, state["last_number"], bundle_id))
            pending = {"identity": identity, "team": team, "device": device["udid"]}
            state["pending"] = pending
            write_state(path, state)
        identity = pending["identity"]
        print(f"Test app: {identity['name']}. Target: {device['name']}.", flush=True)
        signed = products / "Signed.app"
        if pending.get("signed") and signed.is_dir():
            try:
                verify_package(signed, identity, team, device["udid"], pending["version"], pending["build"])
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
                print("The saved signed app did not pass verification. Rebuilding with the same identity.", flush=True)
                pending["signed"] = False
                write_state(path, state)
        if not pending.get("signed") or not signed.is_dir():
            app, version, build = build_app(repo, products, identity, team, bundle_id)
            verify_package(app, identity, team, device["udid"], version, build)
            # Keep one resumable package, separately from reusable Xcode compilation products.
            if signed.exists():
                shutil.rmtree(signed)
            subprocess.run(["ditto", "--norsrc", "--noextattr", "--noacl", str(app), str(signed)], check=True)
            verify_package(signed, identity, team, device["udid"], version, build)
            pending.update(signed=True, version=version, build=build)
            write_state(path, state)
        install_and_verify(device, identity, signed, pending["version"], pending["build"], logs, bundle_id)
        state.update(last_number=identity["number"], pending=None)
        write_state(path, state)


def main():
    parser = argparse.ArgumentParser(description="Install an isolated myai test build over Wi-Fi. Rerun to resume an interrupted installation.")
    parser.add_argument("--device", default=os.environ.get("MYAI_TEST_DEVICE") or os.environ.get("AILOVE_TEST_DEVICE"),
                        help="Paired Wi-Fi iPhone name or UDID")
    parser.add_argument("--team", default=os.environ.get("MYAI_TEST_TEAM") or os.environ.get("AILOVE_TEST_TEAM"),
                        help="Apple Development team (defaults to myai.local.xcconfig)")
    parser.add_argument("--bundle-id", default=os.environ.get("MYAI_TEST_BUNDLE_ID") or os.environ.get("AILOVE_TEST_BUNDLE_ID"),
                        help="Your myai app's bundle ID (defaults to myai.local.xcconfig)")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    store = repo / "build/fresh-tests"
    try:
        run_install(repo, store, args.device, args.team, products=product_directory(repo), bundle_id_arg=args.bundle_id)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError, EOFError, KeyboardInterrupt) as error:
        print(f"Installation did not finish: {error}\nRerun the same command to resume. Logs: {store}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
