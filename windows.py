#!/usr/bin/env python3
"""Publish workspace window lists from Hyprland's local IPC sockets."""

import argparse
import json
import os
from pathlib import Path
import select
import socket
import sys
import time

POLL_INTERVAL = 0.05


def socket_dir():
    return Path(os.environ["XDG_RUNTIME_DIR"]) / "hypr" / os.environ["HYPRLAND_INSTANCE_SIGNATURE"]


def request(command):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2)
        client.connect(str(socket_dir() / ".socket.sock"))
        client.sendall(command.encode())
        chunks = []
        while chunk := client.recv(65536):
            chunks.append(chunk)
        return b"".join(chunks).decode()


def app_name(class_name):
    known = {
        "com.mitchellh.ghostty": "Ghostty", "foot": "Foot",
        "Alacritty": "Alacritty", "kitty": "Kitty",
        "md.obsidian.Obsidian": "Obsidian", "dev.zed.Zed": "Zed",
        "com.t3tools.T3Code": "T3 Code", "zen": "Zen",
        "brave-browser": "Brave", "Spotify": "Spotify",
        "claude-desktop": "Claude", "codex": "Codex",
    }
    return known.get(class_name, class_name.rsplit(".", 1)[-1] or "Window")


def build_state(clients, monitors, active):
    """Positions are global logical coordinates, including off-screen columns."""
    panels = {}
    for monitor in monitors:
        workspace = monitor.get("specialWorkspace", {})
        if not workspace.get("id"):
            workspace = monitor["activeWorkspace"]
        entries = []
        fullscreen = False
        for client in clients:
            # Inactive members of a window group are hidden behind the active one.
            if not client.get("mapped", False) or client.get("hidden", False):
                continue
            if client["workspace"]["id"] != workspace["id"] and not (
                client.get("pinned") and client.get("monitor") == monitor["id"]
            ):
                continue
            # Mode bit 2 is real fullscreen. Maximized (1) keeps the bar visible.
            fullscreen = fullscreen or bool(client.get("fullscreen", 0) & 2)
            entries.append({
                "address": client["address"],
                "app": app_name(client.get("class", "")),
                "class": client.get("class", ""),
                "title": client.get("title", ""),
                "floating": bool(client.get("floating")),
                "focused": client["address"] == active.get("address"),
                "x": client["at"][0], "y": client["at"][1],
            })
        # Floating windows have no column position. Give them a stable order.
        entries.sort(key=lambda entry: (
            entry["floating"],
            0 if entry["floating"] else entry["x"],
            0 if entry["floating"] else entry["y"],
            entry["address"],
        ))
        panels[monitor["name"]] = {
            "workspace": workspace["name"], "windows": entries, "fullscreen": fullscreen,
        }
    return {"panels": panels, "error": ""}


def snapshot():
    # One compositor request prevents a focus/swap between separate reads.
    payload = request("[[BATCH]]j/clients;j/monitors;j/activewindow")
    decoder = json.JSONDecoder()
    values = []
    while payload.strip():
        value, end = decoder.raw_decode(payload.lstrip())
        values.append(value)
        payload = payload.lstrip()[end:]
    if len(values) != 3:
        raise ValueError("Incomplete Hyprland snapshot")
    return build_state(*values)


def watch():
    previous = None

    def publish(state):
        nonlocal previous
        encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        if encoded != previous:
            print(encoded, flush=True)
            previous = encoded

    # Event bursts arrive in one read and trigger an immediate snapshot.
    # Poll positions too: swaps/resizes do not always emit an IPC event.
    ignored = {"activelayout", "submap", "bell", "urgent", "screencast"}
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as events:
                events.connect(str(socket_dir() / ".socket2.sock"))
                publish(snapshot())
                pending = b""
                next_refresh = time.monotonic() + POLL_INTERVAL
                while True:
                    timeout = max(0, next_refresh - time.monotonic())
                    ready, _, _ = select.select([events], [], [], timeout)
                    if ready:
                        chunk = events.recv(65536)
                        if not chunk:
                            raise ConnectionError("Hyprland event socket closed")
                        pending += chunk
                        lines = pending.split(b"\n")
                        pending = lines.pop()
                        if any(line.partition(b">>")[0].decode(errors="replace") not in ignored for line in lines):
                            next_refresh = time.monotonic()
                    if time.monotonic() >= next_refresh:
                        publish(snapshot())
                        next_refresh = time.monotonic() + POLL_INTERVAL
        # TypeError/AttributeError cover malformed fields such as an unexpected null.
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            print(f"Window Strip: {error}", file=sys.stderr, flush=True)
            publish({"panels": {}, "error": "Reconnecting to Hyprland…"})
            time.sleep(2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    if parser.parse_args().once:
        print(json.dumps(snapshot(), ensure_ascii=False))
    else:
        watch()
