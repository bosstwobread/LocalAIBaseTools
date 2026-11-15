import ast
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


DEPLOY = runpy.run_path(str(Path(__file__).resolve().parents[1] / "ExtensionMarket-website/deploy.py"))


class MarketplaceDeployTests(unittest.TestCase):
    def test_private_master_reuses_one_short_socket_then_closes_and_removes_it(self):
        calls = []
        def run(arguments, **kwargs):
            calls.append((arguments, kwargs))
            if "-M" in arguments:
                path = next(value.split("=", 1)[1] for value in arguments if value.startswith("ControlPath="))
                self.assertEqual(Path(path).parent.stat().st_mode & 0o777, 0o700)
                self.assertLess(len(path.encode()), 100)
                self.assertEqual(arguments[-1], "voca-server")
                self.assertIn("-N", arguments)
                self.assertIn("-f", arguments)
                self.assertIn("ControlPersist=60", arguments)
                self.assertIn("ServerAliveInterval=15", arguments)
                self.assertIn("ServerAliveCountMax=2", arguments)
                self.assertFalse(any("StrictHostKeyChecking=" in value for value in arguments))
            return SimpleNamespace(returncode=0)
        with mock.patch.object(DEPLOY["subprocess"], "run", side_effect=run):
            with DEPLOY["deployment_ssh"]("voca-server") as control:
                DEPLOY["remote"]("voca-server", ["true"], control_path=control)
                DEPLOY["remote"]("voca-server", ["docker", "login", "--password-stdin"], data=b"private fixture", quiet=True, control_path=control)
                self.assertTrue(Path(control).parent.is_dir())
        stages = [(args, options) for args, options in calls if "-M" not in args and "-O" not in args]
        self.assertEqual(len(stages), 2)
        for arguments, _ in stages:
            self.assertIn("ControlPath=" + control, arguments)
            self.assertIn("ControlMaster=no", arguments)
            self.assertIn("ProxyCommand=false", arguments)
        self.assertEqual(stages[-1][1]["input"], b"private fixture")
        self.assertNotIn("private fixture", " ".join(stages[-1][0]))
        self.assertIn("exit", calls[-1][0])
        self.assertFalse(Path(control).parent.exists())

    def test_only_command_free_master_establishment_retries_up_to_three_times(self):
        for success in [True, False]:
            calls, entered = [], []
            def run(arguments, **kwargs):
                calls.append(arguments)
                if "-O" in arguments and "exit" in arguments:
                    raise DEPLOY["subprocess"].TimeoutExpired(arguments, 5)
                masters = sum("-M" in call for call in calls)
                return SimpleNamespace(returncode=0 if "-M" not in arguments or (success and masters == 3) else 255)
            with mock.patch.object(DEPLOY["subprocess"], "run", side_effect=run), mock.patch.object(DEPLOY["time"], "sleep"):
                if success:
                    with DEPLOY["deployment_ssh"]("voca-server"):
                        entered.append(True)
                else:
                    with self.assertRaisesRegex(RuntimeError, "three attempts"):
                        with DEPLOY["deployment_ssh"]("voca-server"):
                            entered.append(True)
            masters = [arguments for arguments in calls if "-M" in arguments]
            self.assertEqual(len(masters), 3)
            self.assertTrue(all("-N" in arguments and arguments[-1] == "voca-server" for arguments in masters))
            self.assertTrue(all("-M" in arguments or "-O" in arguments for arguments in calls))
            self.assertEqual(bool(entered), success)
            control = next(value.split("=", 1)[1] for value in masters[0] if value.startswith("ControlPath="))
            self.assertFalse(Path(control).parent.exists())

    def test_stage_failure_is_not_retried_and_master_close_preserves_original_error(self):
        calls = []
        def run(arguments, **kwargs):
            calls.append(arguments)
            if "-O" in arguments and "exit" in arguments:
                raise DEPLOY["subprocess"].TimeoutExpired(arguments, 5)
            return SimpleNamespace(returncode=0 if "-M" in arguments or "-O" in arguments else 255)
        with mock.patch.object(DEPLOY["subprocess"], "run", side_effect=run):
            with self.assertRaisesRegex(RuntimeError, "remote deployment operation failed"):
                with DEPLOY["deployment_ssh"]("voca-server") as control:
                    DEPLOY["remote"]("voca-server", ["deploy-once"], control_path=control)
        self.assertEqual(sum("deploy-once" in arguments for arguments in calls), 1)
        self.assertIn("exit", calls[-1])
        self.assertFalse(Path(control).parent.exists())

    def test_main_establishes_master_before_bootstrap_and_cleans_lock_before_master_exit(self):
        events, controls = [], []
        def ssh(arguments, **kwargs):
            events.append("master-open" if "-M" in arguments else "master-close" if "exit" in arguments else "master-check")
            return SimpleNamespace(returncode=0)
        def remote(target, command, **kwargs):
            controls.append(kwargs["control_path"])
            stage = ["bootstrap", "transaction", "lock-cleanup"][len(controls) - 1]
            events.append(stage)
            if stage == "transaction": raise RuntimeError("original stage failure")
        namespace = DEPLOY["main"].__globals__
        with mock.patch.dict(namespace, {"remote": remote, "private_settings": lambda _: {}}), \
             mock.patch.object(DEPLOY["subprocess"], "run", side_effect=ssh), \
             mock.patch.object(DEPLOY["subprocess"], "check_output", return_value="a" * 40), \
             mock.patch.object(DEPLOY["signal"], "signal"), \
             mock.patch.object(DEPLOY["sys"], "argv", ["deploy.py", "--deploy", "--rollback", "fixture-release"]), \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaisesRegex(RuntimeError, "original stage failure"):
                DEPLOY["main"]()
        self.assertEqual(events, ["master-open", "master-check", "bootstrap", "transaction", "lock-cleanup", "master-close"])
        self.assertEqual(len(set(controls)), 1)
        self.assertFalse(Path(controls[0]).parent.exists())

    def test_direct_remote_without_control_path_remains_fresh_and_does_not_retry(self):
        with mock.patch.object(DEPLOY["subprocess"], "run", return_value=SimpleNamespace(returncode=255)) as run:
            with self.assertRaises(RuntimeError): DEPLOY["remote"]("voca-server", ["single-command"])
        self.assertEqual(run.call_count, 1)
        arguments = run.call_args.args[0]
        self.assertIn("ControlPath=none", arguments)
        self.assertNotIn("ProxyCommand=false", arguments)

    domain = "local-ai-extension.nelson007.com"
    old_managed = """  # BEGIN LocalAIBaseTools ExtensionMarket
  redir /extension-market /extension-market/ 308
  handle_path /extension-market/* {
    reverse_proxy extension-market:8080
  }
  # END LocalAIBaseTools ExtensionMarket"""

    def legacy_config(self):
        return "recite.nelson007.com {\n" + self.old_managed + """
  handle_path /serenity/* {
    reverse_proxy serenity-backend:3010
  }
  respond /status "keep } quoted content" 200
  handle {
    reverse_proxy backend:3000
  }
}

web.nelson007.com {
  reverse_proxy recite-web:80
}
"""

    def test_caddy_migrates_owned_landing_keeps_native_alias_and_other_routes(self):
        before = self.legacy_config()
        result = DEPLOY["candidate_caddy"](before, self.domain)
        self.assertIn("handle_path /extension-market {", result)
        self.assertIn("handle_path /extension-market/ {", result)
        self.assertEqual(result.count("redir https://" + self.domain + "{uri} 308"), 2)
        self.assertIn("handle_path /extension-market/* {\n    reverse_proxy extension-market:8080\n  }", result)
        self.assertIn(self.domain + " {\n  encode gzip\n  reverse_proxy extension-market:8080\n}", result)
        self.assertNotIn("redir /extension-market /extension-market/", result)
        self.assertIn(before.split(self.old_managed)[1], result)

    def test_caddy_canonical_migration_is_idempotent(self):
        migrated = DEPLOY["candidate_caddy"](self.legacy_config(), self.domain)
        self.assertEqual(DEPLOY["candidate_caddy"](migrated, self.domain), migrated)

    def test_caddy_preserves_unrelated_same_host_routes_without_old_market_block(self):
        before = self.legacy_config().replace(self.old_managed + "\n", "")
        result = DEPLOY["candidate_caddy"](before, self.domain)
        self.assertIn(before.split("{", 1)[1], result)

    def test_caddy_refuses_conflicting_or_extended_canonical_domain_block(self):
        for body in ["reverse_proxy other-service:8080", "reverse_proxy extension-market:8080\n  respond /custom custom"]:
            before = self.legacy_config() + "\n" + self.domain + " {\n  " + body + "\n}\n"
            with self.assertRaisesRegex(ValueError, "unexpected existing"):
                DEPLOY["candidate_caddy"](before, self.domain)

    def test_caddy_refuses_operator_edits_or_unmanaged_legacy_market_routes(self):
        for before in [self.legacy_config().replace("extension-market:8080", "operator-service:8080"),
                       self.legacy_config().replace(" 308", " 302"),
                       self.legacy_config().replace(self.old_managed, "  redir /extension-market https://operator.example 308")]:
            with self.assertRaises(ValueError):
                DEPLOY["candidate_caddy"](before, self.domain)

    def test_caddy_refuses_duplicate_or_ambiguous_domain_sites(self):
        for before in [self.legacy_config() * 2,
                       self.legacy_config() + "\nhttps://" + self.domain + " { reverse_proxy operator:80 }\n"]:
            with self.assertRaises(ValueError):
                DEPLOY["candidate_caddy"](before, self.domain)

    def test_legacy_baseline_origin_is_independent_of_new_public_origin(self):
        function = next(node for node in ast.parse(DEPLOY["REMOTE_TRANSACTION"]).body
                        if isinstance(node, ast.FunctionDef) and node.name == "baselines")
        namespace = {"cfg": {"origin": "https://" + self.domain, "legacyOrigin": "https://recite.nelson007.com"},
                     "get": lambda url: calls.append(url)}
        calls = []
        exec(compile(ast.Module(body=[function], type_ignores=[]), "legacy-baselines", "exec"), namespace)
        namespace["baselines"]()
        self.assertEqual(calls, ["https://recite.nelson007.com/en", "https://recite.nelson007.com/serenity/health/live"])

    def test_archive_preserves_fractional_mtime_and_changed_same_size_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "extensions.json"
            records = []
            for contents, modified in [(b'{"sha":"old"}', 1_763_220_000_123_456_789),
                                       (b'{"sha":"new"}', 1_763_220_000_123_456_999)]:
                path.write_bytes(contents)
                os.utime(path, ns=(modified, modified))
                actual = path.stat().st_mtime_ns
                packed = DEPLOY["archive"]([(path, "dist/data/extensions.json")])
                with tarfile.open(fileobj=io.BytesIO(packed), mode="r:gz") as archive:
                    member = archive.getmember("dist/data/extensions.json")
                    records.append(member.pax_headers["mtime"])
                    self.assertEqual(member.pax_headers["mtime"], f"{actual // 10**9}.{actual % 10**9:09d}")
                    self.assertGreater(member.mtime, 0)
                    self.assertEqual(archive.extractfile(member).read(), contents)
            self.assertNotEqual(records[0], records[1])

    def test_manifest_hashes_bytes_even_when_file_size_and_mtime_are_identical(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            (folder / "index.html").write_text("public fixture")
            path = folder / "extensions.json"
            path.write_bytes(b'{"sha":"old"}')
            os.utime(path, ns=(0, 0))
            before = DEPLOY["public_manifest"](folder)
            path.write_bytes(b'{"sha":"new"}')
            os.utime(path, ns=(0, 0))
            after = DEPLOY["public_manifest"](folder)
            self.assertEqual(before["extensions.json"]["size"], after["extensions.json"]["size"])
            self.assertNotEqual(before["extensions.json"]["sha256"], after["extensions.json"]["sha256"])
            self.assertNotEqual(DEPLOY["manifest_digest"](before), DEPLOY["manifest_digest"](after))

    def test_mixed_image_metadata_fails_before_push_or_service_replacement(self):
        self.assert_candidate_gate(stale_metadata=True)

    def test_matching_image_checks_every_public_file_then_allows_push(self):
        self.assert_candidate_gate(stale_metadata=False)

    def assert_candidate_gate(self, stale_metadata):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            image = Path(temporary) / "candidate"
            for folder in [source, image]:
                (folder / "data").mkdir(parents=True)
                (folder / "downloads").mkdir()
                (folder / "index.html").write_text("current page")
                (folder / "downloads/MacHelper.zip").write_bytes(b"current app ZIP")
            old = json.dumps({"sha256": "d" * 64, "size": 3057566}).encode()
            new = json.dumps({"sha256": "1" * 64, "size": 3071255}).encode()
            self.assertEqual(len(old), len(new))
            (source / "data/extensions.json").write_bytes(new)
            (image / "data/extensions.json").write_bytes(old if stale_metadata else new)
            manifest = DEPLOY["public_manifest"](source)
            stages, verified = [], []

            def run(arguments, stage, **kwargs):
                stages.append(stage)
                if stage == "candidate-integrity":
                    self.assertEqual(arguments[-3:], ["sha256sum", "-c", "-"])
                    for line in kwargs["input_text"].splitlines():
                        expected, name = line.split("  ", 1)
                        relative = name.removeprefix("/usr/share/nginx/html/")
                        verified.append(relative)
                        actual = hashlib.sha256((image / relative).read_bytes()).hexdigest()
                        if actual != expected:
                            raise RuntimeError("candidate-integrity failed")
                return SimpleNamespace(returncode=0, stdout="ok\n")

            outer = next(node for node in ast.parse(DEPLOY["REMOTE_TRANSACTION"]).body if isinstance(node, ast.Try))
            candidate = next(i for i, node in enumerate(outer.body) if isinstance(node, ast.Try))
            push = next(i for i, node in enumerate(outer.body)
                        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
                        and len(node.value.args) > 1 and isinstance(node.value.args[1], ast.Constant)
                        and node.value.args[1].value == "docker-push")
            gate = ast.fix_missing_locations(ast.Module(body=outer.body[candidate:push + 1], type_ignores=[]))
            namespace = {"run": run, "name": "candidate-fixture", "common": [], "cfg": {"image": "fixture"},
                         "step": lambda _: None, "expected": manifest, "checksum_input": DEPLOY["checksum_input"]}
            if stale_metadata:
                with self.assertRaisesRegex(RuntimeError, "candidate-integrity"):
                    exec(compile(gate, "candidate-byte-gate", "exec"), namespace)
                self.assertNotIn("docker-push", stages)
                self.assertEqual(stages[-1], "candidate-cleanup")
            else:
                exec(compile(gate, "candidate-byte-gate", "exec"), namespace)
                self.assertEqual(set(verified), set(manifest))
                self.assertIn("docker-push", stages)
            self.assertNotIn("previous-stop", stages)
            self.assertNotIn("website-start", stages)

    def test_exact_remote_helper_preamble_executes_without_parent_globals(self):
        program = DEPLOY["remote_program"]()
        preamble = program.removesuffix(DEPLOY["REMOTE_TRANSACTION"])
        namespace = {}
        exec(preamble, namespace)
        for function in ["candidate_caddy", "public_manifest", "checksum_input", "manifest_digest"]:
            self.assertTrue(callable(namespace[function]))
        compile(program, "remote-deployment", "exec")

    def test_checksum_input_rejects_path_injection_and_empty_manifests(self):
        for name in ["../outside", "/outside", "data/../outside", "bad\nname", "bad\\name"]:
            with self.assertRaises(ValueError):
                DEPLOY["checksum_input"]({name: {"sha256": "a" * 64, "size": 1}})
        with self.assertRaises(ValueError):
            DEPLOY["checksum_input"]({})


if __name__ == "__main__":
    unittest.main()
