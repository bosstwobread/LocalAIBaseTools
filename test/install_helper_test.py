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
        expected = sorted([installer.DEFAULT_EXTENSION_ID, extra])
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


if __name__ == "__main__":
    unittest.main()
