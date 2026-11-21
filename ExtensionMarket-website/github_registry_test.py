import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from github_registry import GitHubSource, read_registry


COMMIT = "0123456789abcdef" * 2 + "01234567"
PROJECT = "https://github.com/independent-author/ExampleTools/tree/" + COMMIT


def blob(path, data, mode="100644"):
    oid = hashlib.sha1(f"blob {len(data)}\0".encode() + data, usedforsecurity=False).hexdigest()
    return f"{mode} blob {oid}\t{path}\0".encode()


class RegistryTests(unittest.TestCase):
    def test_independent_source_at_root_or_in_monorepo_fetches_only_listed_files(self):
        files = {
            "extension.json": b"{}",
            "README.md": b"Independent example",
            "prompts/Edit text.txt": b"Improve this writing.",
        }
        preview = b'{"schemaVersion":1}'
        tree = b"".join(blob(path, data) for path, data in files.items())
        tree += blob("marketplace/preview.json", preview) + blob("marketplace/demo.png", b"demo")
        tree += blob(".github/workflows/release.yml", b"workflow") + blob("docs/AI_DEPLOYMENT.md", b"private")
        for path in ["", "Extensions/My Tool"]:
            with self.subTest(path=path):
                prefix = f"https://raw.githubusercontent.com/independent-author/ExampleTools/{COMMIT}/"
                if path:
                    prefix += "Extensions/My%20Tool/"
                catalog_url = PROJECT + ("/Extensions/My%20Tool" if path else "")
                calls = []

                def list_tree(*args):
                    self.assertEqual(args, ("independent-author", "ExampleTools", COMMIT, path))
                    return tree

                def fetch(url, maximum):
                    self.assertTrue(url.startswith(prefix))
                    relative = url.removeprefix(prefix).replace("%20", " ")
                    calls.append(relative)
                    self.assertGreater(maximum, 0)
                    if relative == "marketplace/preview.json":
                        return preview
                    return files[relative]

                with tempfile.TemporaryDirectory() as directory:
                    registry = Path(directory) / "registry.json"
                    registry.write_text(json.dumps({"schemaVersion": 1, "extensions": [catalog_url]}))
                    source, = read_registry(registry, fetch=fetch, tree_reader=list_tree)
                    self.assertEqual(source.url, catalog_url)
                    self.assertEqual(source.files(), files)
                    self.assertEqual(set(calls), set(files))
                    self.assertEqual(source.read("marketplace/preview.json", 1024), preview)
                    self.assertIsNone(source.read("marketplace/missing.json", 1024, optional=True))
                    self.assertNotIn("marketplace/demo.png", calls)

    def test_unpinned_and_unsafe_folder_urls_are_rejected(self):
        invalid = [
            PROJECT.replace(COMMIT, "main"),
            PROJECT.replace("https://", "http://"),
            PROJECT.replace("github.com", "github.com.evil.example"),
            PROJECT.replace("github.com", "name@github.com"),
            PROJECT + "?ref=main",
            PROJECT + "/../Other",
            PROJECT + "/%2e%2e/Other",
            PROJECT + "/Nested%2FHidden",
            PROJECT + "/Nested//Hidden",
        ]
        for entry in invalid:
            with self.subTest(entry=entry), self.assertRaises(ValueError):
                GitHubSource(entry)

    def test_rejects_symlinks_collisions_and_modified_raw_file(self):
        cases = [
            (blob("extension.json", b"{}") + blob("link.js", b"main.js", "120000"), b"{}", "regular Git blob"),
            (blob("extension.json", b"{}") + blob("Extension.json", b"{}"), b"{}", "case-insensitive"),
            (blob("extension.json", b"{}"), b"changed", "Git blob check"),
        ]
        for tree, data, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                GitHubSource(PROJECT, tree_reader=lambda *_: tree, fetch=lambda *_: data).files()

    def test_development_overlay_is_limited_to_first_party_extensions(self):
        url = f"https://github.com/bosstwobread/LocalAIBaseTools/tree/{COMMIT}/Extensions/Example"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "Extensions" / "Example"
            (source_path / "marketplace").mkdir(parents=True)
            (source_path / "extension.json").write_bytes(b"{}")
            (source_path / "marketplace" / "preview.json").write_bytes(b"preview")
            source = GitHubSource(url, local_root=root)
            self.assertTrue(source.is_local)
            self.assertEqual(source.files(), {"extension.json": b"{}"})
            self.assertEqual(source.read("marketplace/preview.json", 1024), b"preview")
            self.assertFalse(GitHubSource(PROJECT, local_root=root).is_local)
            (source_path / "marketplace" / "preview.json").unlink()
            (source_path / "marketplace" / "preview.json").symlink_to(source_path / "extension.json")
            with self.assertRaisesRegex(ValueError, "ordinary file"):
                source.read("marketplace/preview.json", 1024)


if __name__ == "__main__":
    unittest.main()
