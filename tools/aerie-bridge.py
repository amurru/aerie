#!/usr/bin/env python3
"""Aerie bridge: D-Bus notifications + optional audio level -> Godot TCP.

Sources:
- org.freedesktop.Notifications Notify on session bus (Discord, Telegram, Spotify, ...).
- Optional --audio-monitor <pulse/pipewire monitor name>: reads RMS via parec and
  emits {"type":"beat"} on threshold crossings.

Sink: newline-delimited JSON to 127.0.0.1:42420, also appended to /tmp/aerie-events.jsonl.
Godot side: scripts/external_event_server.gd.

Requires: dbus-python (present), parec or pw-record for --audio-monitor.
"""
import argparse
import json
import socket
import subprocess
import sys
import threading
import time

try:
    import dbus
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib
    HAVE_DBUS = True
except Exception as exc:
    print(f"dbus unavailable: {exc}", file=sys.stderr)
    HAVE_DBUS = False


def send_event(port: int, payload: dict) -> None:
    line = json.dumps(payload)
    try:
        with open("/tmp/aerie-events.jsonl", "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=1.0)
        s.sendall((line + "\n").encode("utf-8"))
        s.close()
    except OSError:
        pass


def watch_notifications(port: int, allow: set) -> None:
    if not HAVE_DBUS:
        return
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()

    def on_notify(app, _replaces, _icon, summary, body, _actions, _hints, _timeout):
        if allow and app not in allow:
            return
        send_event(port, {"app": str(app), "title": str(summary), "body": str(body)})

    bus.add_signal_receiver(
        on_notify,
        bus_name="org.freedesktop.Notifications",
        dbus_interface="org.freedesktop.Notifications",
        signal_name="Notify",
    )
    GLib.MainLoop().run()


def watch_audio_monitor(port: int, device: str, threshold: float) -> None:
    # parec raw float32 stereo 48k; compute RMS blocks, emit beat on rising edge.
    cmd = ["parec", f"--device={device}", "--format=float32le", "--rate=48000", "--channels=2", "--raw"]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    except FileNotFoundError:
        print("parec not found, audio monitor disabled", file=sys.stderr)
        return
    import struct

    block = 4096 * 8  # bytes
    cooldown_until = 0.0
    while True:
        data = proc.stdout.read(block)
        if not data:
            time.sleep(0.2)
            continue
        n = len(data) // 4
        if n == 0:
            continue
        fmt = "<" + "f" * n
        try:
            samples = struct.unpack(fmt, data[: n * 4])
        except struct.error:
            continue
        rms = (sum(s * s for s in samples) / max(1, n)) ** 0.5
        level = min(1.0, rms * 4.0)
        now = time.time()
        if level >= threshold and now >= cooldown_until:
            cooldown_until = now + 0.4
            send_event(port, {"type": "beat", "strength": level})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=42420)
    ap.add_argument("--allow", default="Discord,Vesktop,TelegramDesktop,Spotify",
                    help="comma-separated app names, empty = all")
    ap.add_argument("--audio-monitor", default="",
                    help="Pulse/PipeWire monitor source, e.g. alsa_output...monitor")
    ap.add_argument("--threshold", type=float, default=0.45)
    args = ap.parse_args()
    allow = set(a for a in args.allow.split(",") if a) if args.allow else set()

    threads = []
    if args.audio_monitor:
        t = threading.Thread(target=watch_audio_monitor,
                             args=(args.port, args.audio_monitor, args.threshold),
                             daemon=True)
        t.start()
        threads.append(t)
    # Notification watcher runs in main thread (needs GLib loop).
    watch_notifications(args.port, allow)
    for t in threads:
        t.join()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
