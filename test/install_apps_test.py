"""App migration tests use disposable homes and never change real installations."""
import contextlib
import importlib.util
import io
import os
import plistlib
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("app_installer", Path(__file__).resolve().parents[1] / "scripts/install-apps.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallAppsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.project = self.base / "project"
        self.destination = self.home / "Applications/LocalAIBaseTools"
        self.legacy = self.destination / "Translation.app"

    def make_app(self, path, identifier, executable, data=b"fixture-executable"):
        (path / "Contents/MacOS").mkdir(parents=True)
        with (path / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": identifier, "CFBundleExecutable": executable}, stream)
        (path / "Contents/MacOS" / executable).write_bytes(data)

    def make_legacy(self, identifier="com.localaibasetools.translation", executable="Translation"):
        self.make_app(self.legacy, identifier, executable)

    def install(self):
        with patch.object(installer, "ROOT", self.project), patch.object(Path, "home", return_value=self.home), \
                patch.object(installer.subprocess, "run") as helper, contextlib.redirect_stdout(io.StringIO()):
            installer.main()
            return helper

    def test_known_legacy_moves_to_trash_and_keeps_preferences(self):
        self.make_legacy()
        preferences = self.home / "Library/Preferences/com.localaibasetools.translation.plist"
        preferences.parent.mkdir(parents=True)
        preferences.write_bytes(b"saved-language-preference")
        with patch.object(installer, "stop_legacy_translation") as stop:
            moved = installer.retire_legacy_translation(self.home)
        stop.assert_called_once_with(self.legacy / "Contents/MacOS/Translation")
        self.assertFalse(self.legacy.exists())
        self.assertEqual(moved, self.home / ".Trash/Translation.app")
        self.assertTrue((moved / "Contents/MacOS/Translation").is_file())
        self.assertEqual(preferences.read_bytes(), b"saved-language-preference")

    def test_existing_trash_item_is_preserved_with_unique_migration_name(self):
        self.make_legacy()
        existing = self.home / ".Trash/Translation.app"
        existing.mkdir(parents=True)
        (existing / "keep.txt").write_text("unrelated-trash-item")
        with patch.object(installer, "stop_legacy_translation"):
            moved = installer.retire_legacy_translation(self.home)
        self.assertEqual(moved.name, "Translation (MacHelper migration 1).app")
        self.assertEqual((existing / "keep.txt").read_text(), "unrelated-trash-item")

    def test_unrelated_translation_app_is_neither_stopped_nor_moved(self):
        self.make_legacy(identifier="com.example.someone-else")
        with patch.object(installer, "stop_legacy_translation") as stop:
            self.assertIsNone(installer.retire_legacy_translation(self.home))
        stop.assert_not_called()
        self.assertTrue(self.legacy.is_dir())
        self.assertFalse((self.home / ".Trash").exists())

    def test_matching_identifier_with_different_executable_is_preserved(self):
        self.make_legacy(executable="AnotherProgram")
        with patch.object(installer, "stop_legacy_translation") as stop:
            self.assertIsNone(installer.retire_legacy_translation(self.home))
        stop.assert_not_called()
        self.assertTrue(self.legacy.is_dir())

    def test_missing_legacy_app_is_a_noop(self):
        with patch.object(installer, "stop_legacy_translation") as stop:
            self.assertIsNone(installer.retire_legacy_translation(self.home))
        stop.assert_not_called()
        self.assertFalse((self.home / ".Trash").exists())

    def test_main_installs_only_mac_helper_even_with_old_build_artifact(self):
        self.make_app(self.project / "dist/MacHelper.app", "com.localaibasetools.mac-helper", "MacHelperApp")
        self.make_app(self.project / "dist/Translation.app", "com.localaibasetools.translation", "Translation")
        helper = self.install()
        helper.assert_called_once()
        self.assertEqual([path.name for path in self.destination.iterdir()], ["MacHelper.app"])
        self.assertEqual((self.destination / "MacHelper.app/Contents/MacOS/MacHelperApp").read_bytes(), b"fixture-executable")

    def test_failed_main_install_restores_old_helper_and_does_not_retire_translation(self):
        self.make_legacy()
        self.make_app(self.destination / "MacHelper.app", "com.localaibasetools.mac-helper", "MacHelperApp", b"old-helper")
        self.make_app(self.project / "dist/MacHelper.app", "com.localaibasetools.mac-helper", "MacHelperApp", b"new-helper")
        rename = Path.rename

        def fail_staged_move(path, target):
            if path.name == "MacHelper.app" and path.parent.name.startswith(".install-"):
                raise OSError("fixture-install-failure")
            return rename(path, target)

        with patch.object(Path, "rename", fail_staged_move), patch.object(installer, "stop_legacy_translation") as stop:
            with self.assertRaisesRegex(OSError, "fixture-install-failure"):
                self.install()
        stop.assert_not_called()
        self.assertTrue(self.legacy.is_dir())
        self.assertEqual((self.destination / "MacHelper.app/Contents/MacOS/MacHelperApp").read_bytes(), b"old-helper")

    def test_only_same_user_exact_legacy_executable_receives_sigterm(self):
        executable = self.home / "Applications/LocalAIBaseTools/Translation.app/Contents/MacOS/Translation"
        uid = os.getuid()
        output = f"41001 {uid} {executable}\n41002 {uid} {executable}-other\n41003 {uid + 1} {executable}\n"
        replies = [subprocess.CompletedProcess([], 0, output), subprocess.CompletedProcess([], 0, "")]
        with patch.object(installer.subprocess, "run", side_effect=replies), patch.object(installer.os, "kill") as kill:
            installer.stop_legacy_translation(executable)
        kill.assert_called_once_with(41001, signal.SIGTERM)


if __name__ == "__main__":
    unittest.main()
