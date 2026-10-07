# Aerie — Skybound

A native **Godot 4** interactive 3D wallpaper prototype for Hyprland. A rigged dragon flies freely through an endlessly streamed open world while a smooth third-person camera follows from behind. Each launch gets a new world seed; press `R` to reshuffle while flying.

## Included

- Open-world streaming terrain: **steppe, mountains, glaciers, volcanoes, forests, deserts, lake country, highlands**, plus merged **seas**, winding **rivers**, and lake basins deep enough to dive.
- Water-body clustering: neighboring water cells merge into big lakes and seas; rivers carve positional channels across chunk borders.
- A rigged CC0 dragon (Quaternius) with a looping flight animation, heading-driven free flight with banking, and U-turns anywhere.
- **Swimming mode**: dive below the waterline and the wings fold back, the beat slows, the tail sways, and the body pitches into the swim.
- Real-clock **day/night cycle** with dawn/dusk blends, a light-anchored sun and moon, and a compass in the HUD.
- Semi-random **weather machine** (Clear / Cloudy / Fog / Storm) with a wind-drifted cloud deck, camera-tracking rain, and lightning strikes.
- **Shout-to-erupt volcanoes**: loud voice input near a volcano triggers a 12s eruption with lava fountain, magma spill, glow surge, and boom.
- Voice reactivity (mic analyzed, never played back), ambient beds that mix by weather and volcano proximity, underwater muffle, and external notification hooks.
- Terrain collision (no flying through mountains), dive camera, and a hideable HUD.

## Assets

- `assets/models/quaternius_dragon.glb` — "Dragon" by Quaternius, CC0 1.0.
- `assets/audio/bsb_*.ogg` — BigSoundBank / La Sonotheque (Joseph SARDIN), CC0. See `assets/audio/CREDITS.md`.

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
| `W` / `S` or `↑` / `↓` | Climb / descend (dive / surface underwater) |
| `A` / `D` or `←` / `→` | Turn left / right (hold ~2s for a U-turn) |
| Middle mouse button | Capture or release mouse for steering |
| `R` | Generate a fresh random world around the dragon |
| `Space` | Pause / resume flight |
| `T` | Toggle day / night (manual override; system clock otherwise) |
| `Z` | Superspeed rush: 10s zoom, then a cooldown before reuse |
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

- `scripts/world_generator.gd`: biomes, water classes, terrain scale/colors, mesh density, chunk grid, prop counts, volcano kits.
- `scripts/dragon.gd`: flight speed, height limits, model scale, swim fold, and steering response.
- `scripts/wallpaper.gd`: camera framing, collision, dive state, HUD.
- `scripts/environment_director.gd`: day/night clock, weather machine, cloud deck, sun/moon.
- `scripts/audio_reactor.gd`: voice level, beat threshold, mic vs monitor source.
- `scripts/sfx_manager.gd`: ambience mix, thunder, eruption boom, underwater muffle.
- `scripts/fx_manager.gd`: lightning bolts, floater pool, sun flash decay.
- `scripts/external_event_server.gd`: TCP `127.0.0.1:42420` + `/tmp/aerie-events.jsonl`.

See `docs/EVENTS.md` for voice + notification wiring (`tools/aerie-bridge.py`, `tools/notify_to_aerie.sh`).

This is a source project, not an exported Linux binary. Godot 4 on the target Arch machine runs it directly.
