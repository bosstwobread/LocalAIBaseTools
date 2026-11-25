import json
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHROMIUM_ID = "abcdefghijklmnopabcdefghijklmnop"
FIREFOX_ID = "example-addon@example.org"
SAFARI_ID = "org.example.tool.safari"
TOOL_ID = "org.example.tool"


def frame(message):
    body = json.dumps(message, ensure_ascii=False).encode()
    return struct.pack("<I", len(body)) + body


def read_frame(descriptor):
    deadline = time.monotonic() + 4

    def exact(size):
        result = bytearray()
        while len(result) < size:
            remaining = max(0, deadline - time.monotonic())
            if not select.select([descriptor], [], [], remaining)[0]:
                raise TimeoutError("the bridge did not send a complete frame")
            fragment = os.read(descriptor, size - len(result))
            if not fragment:
                raise EOFError("the bridge disconnected before a reply")
            result.extend(fragment)
        return result

    size = struct.unpack("<I", exact(4))[0]
    if not 0 < size <= 131_072:
        raise ValueError("the bridge sent an invalid frame length")
    return json.loads(exact(size))


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("swiftc"), "macOS Swift is required")
class CompanionBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_directory = tempfile.TemporaryDirectory(prefix="mac-helper-companion-test-")
        cls.addClassCleanup(cls.build_directory.cleanup)
        cls.build = Path(cls.build_directory.name)
        sources = ROOT / "MacHelper/CompanionBridge"
        cls.hosts = {}
        chrome = cls.build / "mac-helper-companion-chrome"
        subprocess.run(["swiftc", "-D", "MACHELPER_COMPANION_TESTING", str(sources / "main.swift"),
                        str(sources / "CompanionBrokerClient.swift"), "-o", str(chrome)], check=True)
        cls.hosts["chrome"] = chrome
        for browser in ["edge", "firefox"]:
            path = cls.build / ("mac-helper-companion-" + browser)
            shutil.copy2(chrome, path)
            cls.hosts[browser] = path
        # Compile the same socket client in the one-shot mode used by Safari.
        # Apple's extension sandbox and Safari's loader are separate checks.
        safari = cls.build / "safari"
        safari.mkdir()
        (safari / "main.swift").write_text("""
import Foundation
let message: [String: Any] = ["type": "getStatus", "extension": "org.example.tool"]
let reply = try CompanionBrokerClient.safariReply(to: message, extensionBundleIdentifier: "org.example.tool.safari")
let encoded = try JSONSerialization.data(withJSONObject: reply)
FileHandle.standardOutput.write(encoded)
""")
        cls.safari = safari / "adapter-fixture"
        subprocess.run(["swiftc", "-D", "MACHELPER_COMPANION_TESTING", str(safari / "main.swift"),
                        str(sources / "CompanionBrokerClient.swift"), "-o", str(cls.safari)], check=True)

    def setUp(self):
        root = tempfile.TemporaryDirectory(prefix="mhb-", dir="/tmp")
        self.addCleanup(root.cleanup)
        self.directory = Path(root.name)
        self.socket_name = ("1" * 32) + ".sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(self.listener.close)
        self.listener.bind(str(self.directory / self.socket_name))
        self.listener.listen()
        self.listener.settimeout(4)
        pointer = self.directory / "endpoint"
        pointer.write_text(self.socket_name)
        pointer.chmod(0o600)
        self.env = dict(os.environ, MACHELPER_COMPANION_TEST_DIRECTORY=str(self.directory))

    def start(self, browser, message=None, arguments=None):
        if arguments is None:
            arguments = ([str(self.directory / "com.localaibasetools.companion.json"), FIREFOX_ID]
                         if browser == "firefox" else [f"chrome-extension://{CHROMIUM_ID}/"])
        process = subprocess.Popen([self.hosts[browser], *arguments], env=self.env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop, process)
        if message is not None:
            process.stdin.write(frame(message))
            process.stdin.flush()
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=4)

    def accept(self):
        connection, _ = self.listener.accept()
        self.addCleanup(connection.close)
        connection.settimeout(4)
        return connection

    def test_invoke_keeps_the_payload_opaque_and_exact_browser_identity(self):
        payload = '{"title":"日本語","result":"the worker owns this format"}'
        message = {"type": "invoke", "extension": TOOL_ID, "command": "render", "payload": payload}
        for browser in self.hosts:
            with self.subTest(browser=browser):
                process = self.start(browser, message)
                connection = self.accept()
                identifier = FIREFOX_ID if browser == "firefox" else CHROMIUM_ID
                self.assertEqual(read_frame(connection.fileno()),
                                 dict(message, browser=browser, companion=identifier))
                reply = {"ok": True, "payload": "any worker response"}
                connection.sendall(frame(reply))
                self.assertEqual(read_frame(process.stdout.fileno()), reply)
                self.assertEqual(process.wait(timeout=4), 0)

    def test_browser_payload_cannot_choose_a_companion_or_broker_operation(self):
        for message in [{"type": "watchStatus", "extension": TOOL_ID, "browser": "safari"},
                        {"type": "replace", "extension": TOOL_ID},
                        {"type": "invoke", "extension": TOOL_ID, "command": "render", "payload": "x" * 32769},
                        {"type": "invoke", "extension": TOOL_ID, "command": "render\n", "payload": "x"}]:
            with self.subTest(operation=message["type"]):
                process = self.start("chrome", message)
                self.assertEqual(read_frame(process.stdout.fileno()), {"ok": False, "error": "invalid"})
        self.listener.settimeout(0.1)
        with self.assertRaises(TimeoutError):
            self.listener.accept()

    def test_invalid_native_arguments_never_open_a_socket(self):
        pairs = [("chrome", [f"https://{CHROMIUM_ID}/"]),
                 ("edge", [f"chrome-extension://{CHROMIUM_ID}/extra"]),
                 ("firefox", ["com.localaibasetools.companion.json", FIREFOX_ID]),
                 ("firefox", ["/tmp/com.localaibasetools.companion.json", "not-an-extension-id"])]
        for browser, arguments in pairs:
            with self.subTest(browser=browser, arguments=arguments):
                process = self.start(browser, arguments=arguments)
                self.assertEqual(process.communicate(timeout=4), (b"", b""))
        self.listener.settimeout(0.1)
        with self.assertRaises(TimeoutError):
            self.listener.accept()

    def test_status_stream_and_browser_disconnect_close_the_broker_socket(self):
        process = self.start("edge", {"type": "watchStatus", "extension": TOOL_ID})
        connection = self.accept()
        self.assertEqual(read_frame(connection.fileno()),
                         {"type": "watchStatus", "extension": TOOL_ID, "browser": "edge", "companion": CHROMIUM_ID})
        for enabled in [False, True, False]:
            status = {"type": "status", "enabled": enabled}
            connection.sendall(frame(status))
            self.assertEqual(read_frame(process.stdout.fileno()), status)
        process.stdin.close()
        self.assertEqual(connection.recv(1), b"")
        self.assertEqual(process.wait(timeout=4), 0)
        # communicate() tries to flush stdin when the attribute is still set.
        process.stdin = None

    def test_rejects_symlink_endpoint_and_non_boolean_broker_replies(self):
        pointer = self.directory / "endpoint"
        pointer.rename(self.directory / "other")
        pointer.symlink_to("other")
        message = {"type": "getStatus", "extension": TOOL_ID}
        process = self.start("chrome", message)
        self.assertEqual(read_frame(process.stdout.fileno()), {"ok": False, "error": "unavailable"})
        pointer.unlink()
        (self.directory / "other").rename(pointer)
        process = self.start("chrome", message)
        connection = self.accept()
        self.assertEqual(read_frame(connection.fileno())["type"], "watchStatus")
        connection.sendall(frame({"type": "status", "enabled": 1}))
        self.assertEqual(read_frame(process.stdout.fileno()), {"ok": False, "error": "unavailable"})

    def test_safari_native_receiver_can_read_one_status_without_stdin(self):
        process = subprocess.Popen([self.safari], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop, process)
        connection = self.accept()
        self.assertEqual(read_frame(connection.fileno()),
                         {"type": "watchStatus", "extension": TOOL_ID, "browser": "safari", "companion": SAFARI_ID})
        status = {"type": "status", "enabled": True}
        connection.sendall(frame(status))
        stdout, stderr = process.communicate(timeout=4)
        self.assertEqual(stderr, b"")
        self.assertEqual(json.loads(stdout), status)
        self.assertEqual(connection.recv(1), b"")


if __name__ == "__main__":
    unittest.main()
