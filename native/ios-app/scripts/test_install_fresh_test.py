import json
import shutil
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

import install_fresh_test as fresh


REPO = Path(__file__).resolve().parents[3]
BUNDLE_ID = "com.example.myai"
LEGACY = BUNDLE_ID + ".firstuse"


class FreshInstallTests(unittest.TestCase):
    def test_original_side_by_side_package_can_resume_with_its_own_group(self):
        first = {"number": 1, "bundle_id": LEGACY, "group": "group." + LEGACY,
                 "name": "ailove 测试版", "scheme": "ailove-firstuse"}
        fresh.validate_identity(first, BUNDLE_ID)
        with self.assertRaises(ValueError):
            fresh.validate_identity({**first, "group": "group." + BUNDLE_ID}, BUNDLE_ID)

    def test_own_bundle_id_and_team_are_required_before_device_selection(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(fresh, "select_phone") as select:
            repo = Path(tmp) / "repo"
            store = Path(tmp) / "state"
            with self.assertRaisesRegex(ValueError, "MYAI_BUNDLE_ID"):
                fresh.run_install(repo, store)
            with self.assertRaisesRegex(ValueError, "DEVELOPMENT_TEAM"):
                fresh.run_install(repo, store, bundle_id_arg=BUNDLE_ID)
            select.assert_not_called()

    def test_reads_local_signing_values_and_rejects_an_unrelated_test_namespace(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            config = repo / "native/ios-app" / fresh.LOCAL_SIGNING_CONFIG
            config.parent.mkdir(parents=True)
            config.write_text(f"// local settings\nDEVELOPMENT_TEAM = TESTTEAM01\n"
                              f"MYAI_BUNDLE_ID = {BUNDLE_ID} // user-owned bundle ID\n")
            self.assertEqual(fresh.read_local_signing_config(repo),
                             {"DEVELOPMENT_TEAM": "TESTTEAM01", "MYAI_BUNDLE_ID": BUNDLE_ID})
        foreign = fresh.new_identity("com.other.myai", 7)
        with self.assertRaises(ValueError):
            fresh.validate_identity(foreign, BUNDLE_ID)
        self.assertEqual(fresh.next_number([{"bundleIdentifier": foreign["bundle_id"]}], 0, BUNDLE_ID), 1)

    def test_previous_signing_config_is_supported_then_current_config_takes_priority(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            directory = repo / "native/ios-app"
            directory.mkdir(parents=True)
            legacy = directory / fresh.LEGACY_SIGNING_CONFIG
            legacy.write_text("DEVELOPMENT_TEAM = TESTTEAM01\nAILOVE_BUNDLE_ID = com.example.previous\n")
            self.assertEqual(fresh.read_local_signing_config(repo),
                             {"DEVELOPMENT_TEAM": "TESTTEAM01", "MYAI_BUNDLE_ID": "com.example.previous"})
            current = directory / fresh.LOCAL_SIGNING_CONFIG
            current.write_text(f"MYAI_BUNDLE_ID = {BUNDLE_ID}\n")
            self.assertEqual(fresh.read_local_signing_config(repo),
                             {"DEVELOPMENT_TEAM": "TESTTEAM01", "MYAI_BUNDLE_ID": BUNDLE_ID})

    def test_delivery_acknowledged_by_phone_is_not_repeated(self):
        identity = fresh.new_identity(BUNDLE_ID, 3)
        phone = {"udid": "fixture-phone", "name": "Fixture"}
        entry = {"bundleIdentifier": identity["bundle_id"], "name": identity["name"],
                 "version": "1.0", "bundleVersion": "1"}
        with ExitStack() as patches:
            patches.enter_context(mock.patch.object(fresh, "select_phone", return_value=phone))
            patches.enter_context(mock.patch.object(fresh, "installed_apps", return_value=[entry]))
            send = patches.enter_context(mock.patch.object(fresh, "device_result"))
            fresh.install_and_verify(phone, identity, Path("fixture.app"), "1.0", "1", Path("unused"), BUNDLE_ID)
            send.assert_not_called()

    def test_previously_numbered_chinese_copy_resumes_under_its_original_name(self):
        current = fresh.new_identity(BUNDLE_ID, 12)
        original = {**current, "name": "ailove 测试12",
                    "scheme": current["scheme"].replace("myai-test-", "ailove-test-")}
        fresh.validate_identity({**original, "name": "ailove Test 12"}, BUNDLE_ID)
        for invalid in ({"name": "ailove 测试02"}, {"group": "group." + BUNDLE_ID}):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                fresh.validate_identity({**original, **invalid}, BUNDLE_ID)
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as patches:
            store = Path(tmp)
            (store / "Signed.app").mkdir()
            pending = {"identity": original, "team": "TESTTEAM01", "device": "fixture-phone",
                       "signed": True, "version": "1.0", "build": "1"}
            fresh.write_state(store / "state.json", {"last_number": 11, "pending": pending})
            phone = {"udid": pending["device"], "name": "Fixture"}
            patches.enter_context(mock.patch.object(fresh, "select_phone", return_value=phone))
            verify = patches.enter_context(mock.patch.object(fresh, "verify_package"))
            build = patches.enter_context(mock.patch.object(fresh, "build_app"))
            deliver = patches.enter_context(mock.patch.object(fresh, "install_and_verify"))
            fresh.run_install(REPO, store)
            self.assertEqual(verify.call_args.args[1], original)
            self.assertEqual(deliver.call_args.args[1], original)
            build.assert_not_called()

    def test_interrupted_delivery_reuses_signed_copy_and_only_then_advances(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as patches:
            repo = Path(tmp) / "repo"
            store = Path(tmp) / "state"
            products = Path(tmp) / "local-cache"
            fixture = Path(tmp) / "fixture.app"
            fixture.mkdir()
            phone = {"udid": "fixture-phone", "name": "Fixture"}
            select = patches.enter_context(mock.patch.object(fresh, "select_phone", return_value=phone))
            installed = patches.enter_context(mock.patch.object(fresh, "installed_apps",
                return_value=[{"bundleIdentifier": LEGACY}]))
            build = patches.enter_context(mock.patch.object(fresh, "build_app", return_value=(fixture, "1.0", "1")))
            patches.enter_context(mock.patch.object(fresh, "verify_package"))
            deliver = patches.enter_context(mock.patch.object(fresh, "install_and_verify",
                side_effect=[RuntimeError("fixture Wi-Fi interruption"), None]))

            def copy_fixture(arguments, check):
                self.assertEqual(arguments, ["ditto", "--norsrc", "--noextattr", "--noacl", str(fixture), str(products / "Signed.app")])
                shutil.copytree(fixture, products / "Signed.app")

            patches.enter_context(mock.patch.object(fresh.subprocess, "run", side_effect=copy_fixture))
            with self.assertRaisesRegex(RuntimeError, "Wi-Fi interruption"):
                fresh.run_install(repo, store, team_arg="TESTTEAM01", products=products, bundle_id_arg=BUNDLE_ID)
            pending = json.loads((store / "state.json").read_text())["pending"]
            self.assertTrue(pending["signed"])
            self.assertEqual(pending["identity"]["number"], 2)

            fresh.run_install(repo, store, products=products)
            self.assertEqual(select.call_args.args[0], phone["udid"])
            self.assertEqual([call.args[1] for call in deliver.call_args_list], [pending["identity"]] * 2)
            build.assert_called_once()
            installed.assert_called_once()
            state = json.loads((store / "state.json").read_text())
            self.assertEqual(state["last_number"], 2)
            self.assertIsNone(state["pending"])

    def test_only_paired_iphones_on_wifi_are_candidates(self):
        def device(udid, transport, kind="iPhone", pairing="paired"):
            return {
                "identifier": "core-" + udid,
                "hardwareProperties": {"udid": udid, "deviceType": kind, "platform": "iOS"},
                "deviceProperties": {"name": kind},
                "connectionProperties": {"transportType": transport, "pairingState": pairing, "tunnelState": "disconnected"},
            }

        devices = [
            device("wired", "wired"),
            device("tablet", "localNetwork", "iPad"),
            device("unknown", "localNetwork", pairing="unpaired"),
            device("mine", "localNetwork"),
        ]
        self.assertEqual([d["udid"] for d in fresh.wireless_phones(devices)], ["mine"])

    def test_next_identity_uses_both_installed_apps_and_local_history(self):
        first = fresh.new_identity(BUNDLE_ID, 1)
        fourth = fresh.new_identity(BUNDLE_ID, 4)
        apps = [
            {"bundleIdentifier": BUNDLE_ID},
            {"bundleIdentifier": fourth["bundle_id"]},
            {"bundleIdentifier": fourth["bundle_id"] + ".widgets"},
        ]
        self.assertEqual(fresh.next_number(apps, 2, BUNDLE_ID), 5)
        self.assertEqual(fresh.next_number(apps, 7, BUNDLE_ID), 8)
        self.assertEqual(fresh.next_number([{"bundleIdentifier": LEGACY}], 0, BUNDLE_ID), 2)
        for key in ("bundle_id", "group", "scheme", "name"):
            self.assertNotEqual(first[key], fourth[key], key)
        self.assertNotEqual(fresh.new_identity(BUNDLE_ID, 4)["bundle_id"], fourth["bundle_id"])

    def test_staged_project_uses_numbered_name_and_separate_storage_and_urls(self):
        identity = fresh.new_identity(BUNDLE_ID, 2)
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            staged = fresh.stage_sources(REPO, work, identity, BUNDLE_ID)
            project = (staged / "project-base.yml").read_text()
            self.assertEqual(identity["name"], "myai Test 02")
            self.assertIn('static let name = "myai Test 02"', (staged / "Shared/AppLocalization.swift").read_text())
            config = (staged / "myai.xcconfig").read_text()
            self.assertIn("MYAI_BUNDLE_ID = " + identity["bundle_id"], config)
            self.assertIn("POKI_BUNDLE_ID: $(MYAI_BUNDLE_ID)", project)
            self.assertIn("POKI_APP_GROUP: group.$(POKI_BUNDLE_ID)", project)
            groups = [line.split(":", 1)[1].strip() for line in project.splitlines()
                      if "com.apple.security.application-groups:" in line]
            self.assertEqual(groups, ['["$(POKI_APP_GROUP)"]'] * 2)
            self.assertFalse((staged / fresh.LOCAL_SIGNING_CONFIG).exists())
            self.assertFalse((staged / fresh.LEGACY_SIGNING_CONFIG).exists())
            self.assertEqual((staged / "Package.resolved").read_bytes(),
                             (REPO / "native/ios-app/Package.resolved").read_bytes())
            self.assertIn("[" + identity["scheme"] + "]", project)
            names = json.loads((staged / "Poki/InfoPlist.xcstrings").read_text())
            translations = names["strings"]["CFBundleDisplayName"]["localizations"]
            for language in ("en", "zh-Hans", "zh-Hant"):
                self.assertEqual(translations[language]["stringUnit"]["value"], identity["name"])
            app = (staged / "Poki/App/PokiApp.swift").read_text()
            self.assertIn(f'url.scheme == "{identity["scheme"]}" || url.scheme == "ailove"', app)
            activity = (staged / "Shared/ActivityFace.swift").read_text()
            self.assertIn(identity["scheme"] + "://setup", activity)
            self.assertNotIn("myai://", activity)


if __name__ == "__main__":
    unittest.main()
