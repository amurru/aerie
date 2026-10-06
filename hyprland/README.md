# Hyprland notes

Aerie is a fullscreen Godot scene, not a Wayland layer-shell client. Current Hyprland window-rule APIs do not provide a general way to put an ordinary window below every other window, so the safe first run is on a dedicated workspace. For a true wallpaper that stays behind applications across workspaces, a compatible layer-shell backend/host would need to be added; it is not bundled here.

Run `../run.sh` to start. Press `F11` to switch between fullscreen and windowed mode. To bind the app to a dedicated workspace, use the syntax supported by your installed Hyprland release; modern Hyprland versions use Lua configuration while older releases use hyprlang. Check the [current Window Rules documentation](https://wiki.hypr.land/Configuring/Basics/Window-Rules/) and run `hyprctl clients` to confirm the window title/class before matching it.
