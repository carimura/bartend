# Bartend

A tiny macOS 27 menu bar app that hides chosen menu bar icons behind a `•••` button.

## Use

- **⌘-drag** icons to the left of the `•••` to hide them; icons to its right always stay.
- **Click** the `•••` to hide or show them. The arrangement is re-read each time you hide, so rearrange while expanded.
- **Right-click** for **Launch at Login** and Quit.
- Lost the `•••`? Open Bartend again from Finder to show everything. Quitting (or a crash) also restores every icon.

Reading icon positions needs **Accessibility** permission (Bartend asks on first launch).

## Build

```sh
bash scripts/build.sh   # builds, signs, installs to /Applications/Bartend.app
open /Applications/Bartend.app
```

Signs with your Apple Development identity if one exists, so the Accessibility grant survives rebuilds.

## How it works

macOS 27 draws all status items inside `MenuBarAgent`, which broke the old window-moving and spacer tricks (Ice, Bartender, Hidden Bar, and the previous Bartend). Bartend instead uses MenuBarAgent's private *visibility restriction* (the mechanism behind exam/assessment mode, via `MenuBarClientCore.framework`): while collapsed it holds an assertion that allowlists every running app except the hidden ones; expanding invalidates it.

## Caveats

- Hiding is **per app**, not per icon.
- While collapsed, MenuBarAgent hides icons from apps **outside `/Applications`** (e.g. apps run from a build folder) and the transient **Now Playing** item, even if they aren't selected.
- Private API: a macOS update may break it. If it disappears, the `•••` becomes a warning triangle and nothing is hidden.
