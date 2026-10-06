# Aerie external events

Godot listens on `127.0.0.1:42420` (override with `AERIE_EVENT_PORT`) for
newline-delimited JSON, plus tails `/tmp/aerie-events.jsonl` as fallback.
See `scripts/external_event_server.gd`.

## Message shapes

```json
{"app":"Discord","title":"ping","body":"hello"}
{"type":"notification","app":"TelegramDesktop","title":"t","body":"b"}
{"type":"beat","strength":0.8}
{"type":"level","value":0.3}
```

`app` names observed here: `Discord`, `TelegramDesktop`, `Spotify`.
Voice needs `audio/driver/enable_input=true` (set in `project.godot`).
System-audio monitors on this host:

```
easyeffects_sink.monitor
alsa_output.pci-0000_00_1f.3.analog-stereo.monitor
bluez_output.E4_A7_4C_A8_C3_13.1.monitor
```

Use `AudioServer.get_input_device_list()` in-Godot, or
`tools/aerie-bridge.py --audio-monitor <name>` for mix + mic.

## Wiring

- `scripts/event_bus.gd` - signals `audio_level`, `audio_beat`, `notification_received`.
- `scripts/audio_reactor.gd` - mic/monitor -> level + beat.
- `scripts/external_event_server.gd` - TCP + file -> event bus.
- `scripts/fx_manager.gd` - beat -> floaters + dragon boost, Discord -> lightning.
- `tools/notify_to_aerie.sh` - dunst `script =` hook.
- `tools/aerie-bridge.py` - D-Bus Notify sniffer + optional parec RMS.

## Debug keys (no daemon needed)

- `L` simulate Discord notification
- `B` simulate voice beat
- `M` toggle voice reactivity
