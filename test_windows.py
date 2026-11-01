"""Exercise the real watcher against a local Hyprland IPC fixture."""

import importlib.util
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import time
import unittest

PLUGIN = Path(__file__).parent
spec = importlib.util.spec_from_file_location("windows", PLUGIN / "windows.py")
windows = importlib.util.module_from_spec(spec)
spec.loader.exec_module(windows)


class WatcherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        directory = Path(self.temp.name) / "hypr" / "fixture"
        directory.mkdir(parents=True)
        self.clients = [self.client("0xa", 0), self.client("0xb", 100)]
        self.active = {"address": "0xa"}
        self.monitors = [{"id": 0, "name": "TEST", "activeWorkspace": {"id": 1, "name": "1"}}]
        self.stop = threading.Event()
        self.command_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.command_socket.bind(str(directory / ".socket.sock"))
        self.command_socket.listen()
        self.command_socket.settimeout(0.1)
        self.event_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.event_socket.bind(str(directory / ".socket2.sock"))
        self.event_socket.listen()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.process = subprocess.Popen(
            ["python3", "-u", str(PLUGIN / "windows.py")],
            env={**os.environ, "XDG_RUNTIME_DIR": self.temp.name, "HYPRLAND_INSTANCE_SIGNATURE": "fixture"},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.events, _ = self.event_socket.accept()
        self.pending = b""
        self.read_state(1)

    @staticmethod
    def client(address, x):
        return {"address": address, "mapped": True, "workspace": {"id": 1},
                "at": [x, 0], "class": "fixture", "title": address, "monitor": 0}

    def serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.command_socket.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with connection:
                command = connection.recv(65536).decode()
                values = {"j/clients": self.clients, "j/monitors": self.monitors, "j/activewindow": self.active}
                if command.startswith("[[BATCH]]"):
                    commands = command.removeprefix("[[BATCH]]").split(";")
                    response = "\n\n\n".join(json.dumps(values[c]) for c in commands)
                else:
                    response = json.dumps(values[command])
                connection.sendall(response.encode())

    def read_state(self, timeout):
        return self.read_panel(timeout)["windows"]

    def read_panel(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                self.fail(f"Tab state did not update within {timeout * 1000:.0f} ms")
            self.pending += os.read(self.process.stdout.fileno(), 65536)
        line, self.pending = self.pending.split(b"\n", 1)
        return json.loads(line)["panels"]["TEST"]

    def tearDown(self):
        self.process.terminate()
        self.process.wait(timeout=2)
        self.process.stdout.close()
        self.process.stderr.close()
        self.stop.set()
        self.thread.join(timeout=1)
        self.events.close()
        self.command_socket.close()
        self.event_socket.close()
        self.temp.cleanup()

    def test_swap_without_event_updates_within_150ms(self):
        self.clients = [self.client("0xa", 100), self.client("0xb", 0)]
        entries = self.read_state(0.15)
        self.assertEqual([e["address"] for e in entries], ["0xb", "0xa"])
        self.assertEqual([e["address"] for e in entries if e["focused"]], ["0xa"])

    def test_focus_event_updates_within_50ms(self):
        self.active = {"address": "0xb"}
        self.events.sendall(b"activewindowv2>>b\n")
        entries = self.read_state(0.05)
        self.assertEqual([e["address"] for e in entries if e["focused"]], ["0xb"])

    def test_rapid_focus_and_swap_keep_window_identity(self):
        for i in range(8):
            address = "0xa" if i % 2 else "0xb"
            self.active = {"address": address}
            self.clients = [self.client("0xa", (1 - i % 2) * 100), self.client("0xb", (i % 2) * 100)]
            self.events.sendall(f"activewindowv2>>{address[2:]}\n".encode())
            deadline = time.monotonic() + 0.15
            while True:
                entries = self.read_state(max(0, deadline - time.monotonic()))
                focused = [e["address"] for e in entries if e["focused"]]
                if focused == [address] and entries[0]["address"] == address:
                    break

    def test_fullscreen_event_hides_strip_within_50ms(self):
        self.clients[1]["fullscreen"] = 2
        self.events.sendall(b"fullscreen>>1\n")
        self.assertTrue(self.read_panel(0.05)["fullscreen"])
        self.clients[1]["fullscreen"] = 0
        self.events.sendall(b"fullscreen>>0\n")
        self.assertFalse(self.read_panel(0.05)["fullscreen"])

    def test_maximized_window_keeps_strip(self):
        # Maximize (mode 1) keeps the bar on screen, so the strip stays too.
        clients = [{**self.client("0xa", 0), "fullscreen": 1}]
        state = windows.build_state(clients, self.monitors, self.active)
        self.assertFalse(state["panels"]["TEST"]["fullscreen"])

if __name__ == "__main__":
    unittest.main()
