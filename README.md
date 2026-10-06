# Aerie — Skybound

A native **Godot 4** interactive 3D wallpaper prototype for Hyprland. A copper-winged dragon flies continuously through an endlessly streamed, voxel-inspired landscape while a smooth third-person camera follows from behind. Each launch gets a new world seed; press `R` to reshuffle while flying.

## Included

- Low-poly stepped terrain with **steppe, mountains, glaciers, volcanoes, forests, deserts, lake country, and highlands**.
- Biome-specific colors and props: pine groves, desert plants, ice spires, water, and a lava-crowned volcano.
- A continuously flying dragon with flapping articulated wings and keyboard / captured-mouse steering.
- Smooth chase camera, dusk sky, fog, sun shadows, and a hideable HUD.
- No imported assets, add-ons, or network access required at runtime.

## Run on Arch Linux

Install Godot 4 if needed, then start the project:

```sh
sudo pacman -S godot
chmod +x run.sh
./run.sh
```

It opens fullscreen by default; press **F11** to switch fullscreen/windowed mode.

## Controls

| Input | Action |
|---|---|
| `W` / `S` or `↑` / `↓` | Climb / descend |
| `A` / `D` or `←` / `→` | Steer left / right |
| Middle mouse button | Capture or release mouse for steering |
| `R` | Generate a fresh random world around the dragon |
| `Space` | Pause / resume flight |
| `L` | Debug: simulate Discord notification (lightning) |
| `B` | Debug: simulate voice beat (floaters + boost) |
| `M` | Toggle voice reactivity |
| `F1` | Hide / show the HUD |
| `F11` | Toggle fullscreen / windowed |
| `Esc` | Release a captured mouse |

The Aerie window needs keyboard focus to receive controls.

## Hyprland integration: important limitation

This is a **fullscreen Godot scene, not a Wayland layer-shell client**. Current Hyprland window rules do not provide a general “put this regular window behind every normal window” effect, so fullscreen alone is not equivalent to a persistent desktop wallpaper. For a safe first run, use a dedicated workspace for Aerie and switch to it when you want the animated scene. To make it a true always-behind wallpaper on every workspace, it needs a compatible layer-shell host/backend; this project does not bundle one.

Check the [current Hyprland Window Rules documentation](https://wiki.hypr.land/Configuring/Basics/Window-Rules/) for the syntax supported by your installed release. Avoid pasting old `below` examples into a newer config without checking that version's documentation. `hyprctl clients` shows the actual window title/class if you need to match it.

## Tuning

- `scripts/world_generator.gd`: biome selection, terrain scale/colors, mesh density, chunk length, and prop counts.
- `scripts/dragon.gd`: flight speed, height limits, wing articulation, and steering response.
- `scripts/wallpaper.gd`: camera framing, sky, lighting, fullscreen default, and HUD.
- `scripts/audio_reactor.gd`: voice level, beat threshold, mic vs monitor source.
- `scripts/fx_manager.gd`: lightning bolts, floater pool, sun flash decay.
- `scripts/external_event_server.gd`: TCP `127.0.0.1:42420` + `/tmp/aerie-events.jsonl`.

See `docs/EVENTS.md` for voice + notification wiring (`tools/aerie-bridge.py`, `tools/notify_to_aerie.sh`).

This is a source project, not an exported Linux binary. Godot 4 on the target Arch machine runs it directly.
