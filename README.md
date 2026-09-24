# Vial Helper

Menu-bar app for macOS that shows the keymap of your Vial-configured split keyboard
(by default a splitkb Aurora Corne) as a floating overlay.

- Lives in the menu bar (no Dock icon). Left-click the keyboard icon to toggle the overlay,
  right-click for the menu (Show, Reload Keymap, Open .vil File…, Reveal in Finder, Settings, Quit).
- Global shortcut toggles the overlay from anywhere (default `⌃⌥⌘K`, change it in Settings).
- Reads a Vial export (`.vil`); path is configurable, default `~/aurora.vil`.
  The file is re-read automatically whenever it changes on disk.
- Overlay shows all non-empty layers at once (layers with only transparent/unassigned keys are hidden); press `0`–`9` to zoom into a layer, `a` for all,
  `←`/`→` to cycle, `Esc` to close. Clicking anywhere else also closes it.
- Shows mod-taps (hold modifier under the tap key), layer-taps, combos and encoder bindings.
  Layer names from Settings replace "L1"-style legends on layer keys and in the layer chips.
  Settings → Encoders picks which half's encoder to draw (Vial exports a slot per half even if unused).

## Build

Requires the Swift toolchain (Command Line Tools are enough, no Xcode needed), macOS 13+.

```sh
./build.sh            # -> build/VialHelper.app
./build.sh --run      # build and launch
./build.sh --install  # build and copy to /Applications (needed for "Launch at login")
```

## Debug

```sh
swift run VialHelper --show                     # launch with the overlay already open
swift run VialHelper --render out.png           # render the overlay to a PNG and exit
swift run VialHelper --render out.png --layer 1 # render a single layer
swift run VialHelper --selftest                 # open overlay, exercise key handling, exit 0/1
```

## Toolchain note

The project builds with the Command Line Tools alone. On the macOS 27 SDK SwiftUI's `@State`
is a compiler macro whose plugin ships only with Xcode, so views keep transient state in
`ObservableObject`s (`@ObservedObject`) instead of `@State`.
