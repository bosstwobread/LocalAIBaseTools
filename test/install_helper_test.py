"""Installer integration tests use a temporary home, never the real registrations."""
import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).resolve().parents[1] / "scripts/install-helper.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.support = self.home / "Library/Application Support"
        self.destination = self.support / "LocalAIBaseTools/MacHelper"
        self.binary = self.home / "build/mac-helper-host"
        self.binary.parent.mkdir()
        self.binary.write_bytes(b"new-host-fixture")

    def install(self, *extra):
        with patch.object(Path, "home", return_value=self.home), patch("sys.argv", ["install-helper.py", "--binary", str(self.binary), *extra]), contextlib.redirect_stdout(io.StringIO()):
            installer.main()

    def test_both_browser_aliases_launch_new_host_and_preserve_extra_ids(self):
        extra = "a" * 32
        self.install("--extension-id", extra)
        self.install()
        expected = sorted([*installer.DEFAULT_EXTENSION_IDS, extra])
        config = self.destination / "allowed-extension-ids.json"
        self.assertEqual(json.loads(config.read_text()), expected)
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.destination / "mac-helper-host").stat().st_mode & 0o777, 0o700)
        for browser in ["Google/Chrome", "Microsoft Edge"]:
            for name in [installer.HOST_NAME, installer.LEGACY_HOST_NAME]:
                manifest = json.loads((self.support / browser / "NativeMessagingHosts" / f"{name}.json").read_text())
                self.assertEqual(manifest["name"], name)
                self.assertEqual(manifest["path"], str(self.destination / "mac-helper-host"))
                self.assertEqual(manifest["allowed_origins"], [f"chrome-extension://{value}/" for value in expected])

    def test_first_migration_preserves_legacy_authorized_tools(self):
        legacy = self.support / "MessageHelper/allowed-extension-ids.json"
        legacy.parent.mkdir(parents=True)
        legacy.write_text(json.dumps(["b" * 32]))
        self.install()
        ids = json.loads((self.destination / "allowed-extension-ids.json").read_text())
        self.assertIn("b" * 32, ids)

    def test_bad_existing_allowlist_leaves_installed_host_unchanged(self):
        self.destination.mkdir(parents=True)
        host = self.destination / "mac-helper-host"
        host.write_bytes(b"existing-host")
        config = self.destination / "allowed-extension-ids.json"
        config.write_text("{broken")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.install()
        self.assertEqual(host.read_bytes(), b"existing-host")
        self.assertEqual(config.read_text(), "{broken")
        self.assertFalse((self.support / "Google/Chrome/NativeMessagingHosts").exists())

    def test_invalid_additional_id_changes_nothing(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.install("--extension-id", "https://example.com")
        self.assertFalse(self.destination.exists())

    def test_public_discovery_sidecars_are_installed_privately_and_atomically(self):
        values = {"discovery-config.json": {"schemaVersion": 1, "websiteURL": "https://local-ai-extension.nelson007.com/"},
                  "discovery-index.json": {"schemaVersion": 1, "extensions": []},
                  "discovery-manifest.json": {"schemaVersion": 1, "revision": "old"}}
        for name, value in values.items():
            (self.binary.parent / name).write_text(json.dumps(value))
        self.install()
        settings = self.destination / "settings.json"
        settings.write_bytes(b"user AI settings unchanged")
        cache = self.destination / "discovery-cache.json"
        cache.write_bytes(b"user discovery cache unchanged")
        old_index = (self.destination / "discovery-index.json").open("rb")
        self.addCleanup(old_index.close)
        previous = old_index.read()
        old_index.seek(0)
        values["discovery-index.json"] = {"schemaVersion": 1, "extensions": [{"id": "new"}]}
        (self.binary.parent / "discovery-index.json").write_text(json.dumps(values["discovery-index.json"]))
        self.install()
        self.assertEqual(old_index.read(), previous)
        for name, value in values.items():
            installed = self.destination / name
            self.assertEqual(json.loads(installed.read_bytes()), value)
            self.assertEqual(installed.stat().st_mode & 0o777, 0o600)
        self.assertEqual(settings.read_bytes(), b"user AI settings unchanged")
        self.assertEqual(cache.read_bytes(), b"user discovery cache unchanged")

    def test_embedded_app_seed_layout_is_supported(self):
        self.binary = self.home / "Applications/MacHelper.app/Contents/MacOS/mac-helper-host"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"embedded helper")
        resources = self.binary.parent.parent / "Resources/Discovery"
        resources.mkdir(parents=True)
        for name in installer.DISCOVERY_SIDECARS:
            folder = self.binary.parent if name == "discovery-config.json" else resources
            (folder / name).write_text('{"schemaVersion":1}')
        self.install()
        for name in installer.DISCOVERY_SIDECARS:
            self.assertEqual(json.loads((self.destination / name).read_text()), {"schemaVersion": 1})

    def test_discovery_prompts_are_copied_without_rewriting(self):
        prompts = self.binary.parent / "DiscoveryPrompts"
        prompts.mkdir()
        for name in ["rank.txt", "expand.txt"]:
            (prompts / name).write_text("  Owned prompt \n中文  ", encoding="utf-8")
        self.install()
        for name in ["rank.txt", "expand.txt"]:
            copied = self.destination / "DiscoveryPrompts" / name
            self.assertEqual(copied.read_bytes(), (prompts / name).read_bytes())
            self.assertEqual(copied.stat().st_mode & 0o777, 0o600)

    def test_invalid_discovery_seed_fails_before_changing_existing_installation(self):
        self.install()
        installed = self.destination / "mac-helper-host"
        self.binary.write_bytes(b"changed host fixture")
        for invalid in [b"not json", b"[]", b"{" + b" " * (64 * 1024)]:
            (self.binary.parent / "discovery-config.json").write_bytes(invalid)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.install()
            self.assertEqual(installed.read_bytes(), b"new-host-fixture")

    def test_discovery_source_and_destination_links_are_rejected(self):
        self.install()
        outside = self.home / "outside.json"
        outside.write_bytes(b'{"private":"unchanged"}')
        for link in [self.binary.parent / "discovery-config.json", self.destination / "discovery-config.json"]:
            link.symlink_to(outside)
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.install()
            self.assertTrue(link.is_symlink())
            self.assertEqual(outside.read_bytes(), b'{"private":"unchanged"}')
            link.unlink()


if __name__ == "__main__":
    unittest.main()
