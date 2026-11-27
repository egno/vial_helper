# Vial Helper

Menu-bar app for macOS that shows the keymap of your Vial-configured split keyboard
(by default a splitkb Aurora Corne) as a floating overlay.

![Vial Helper overlay showing all layers of an Aurora Corne keymap](docs/screenshot.png)

- Lives in the menu bar (no Dock icon). Left-click the keyboard icon to toggle the overlay,
  right-click for the menu (Show, Reload Keymap, Open .vil File…, Reveal in Finder, Settings, Quit).
- Global shortcut toggles the overlay from anywhere (default `⌃⌥⌘K`, change it in Settings).
- Ghost mode (menu → "Ghost Mode", default shortcut `⌃⌥⌘G`): the see-through keys (no window behind them) of the layer that is active
  right now stay on the screen you are working on while you get used to the layout. It never takes the
  keyboard focus and clicks pass through it. It is available only while the keyboard is connected (keyboard
  link, see below): it disappears with the keyboard and, if it was on, comes back with it. It follows the keyboard's layers as you hold or lock them (firmware
  with the `0xF4` live state, see below; otherwise it shows the base layer); transparent keys show, dimmed, the
  key of the active layer below. Settings → Ghost mode sets the shortcut, corner, opacity and size.
  The ghost keeps out of the way: it fades to almost nothing while the pointer is over it, and away while the full
  overlay is open. Settings → Ghost mode → Show chooses when it is on screen: always, only on layers above the base
  layer, fading out a few seconds after you return to the base layer (these two need the `0xF4` live state), or
  "While typing": it appears with any key press (also a layer key or a held Shift), stays while a layer or a
  key is held and fades out after "Hide after" seconds without a key. Only the keys of this keyboard count: the
  keyboard reports them itself (`0xF7` events, see below), so typing on the laptop's own keyboard leaves the ghost
  hidden. Without those events (older firmware, or while Vial is talking to the keyboard) only a layer change
  brings it up.
  "Move Ghost…" (menu or Settings) lets you drag it anywhere: Done, Return or a click elsewhere keeps the place,
  Esc cancels; the place is remembered per screen, and picking a Position (or Reset) goes back to the corners.
  "Hide from screenshots and screen sharing" keeps it out of captures.
  Above the keys a small badge names the shown layer, with chips for what else the keyboard reports: held and
  one-shot modifiers, Caps Word, Caps Lock, locked layers, a one-shot layer. While Shift is held or a one-shot Shift
  is pending, digits and punctuation show their shifted legends (taken from the active input source; Caps Word
  changes only `-`, as in stock QMK; letters are upper case anyway). "Background opacity" fades only the dark plates:
  the legends stay opaque, with a dark halo that keeps them readable over light windows. "Simplified labels" (on by
  default) keeps the tap legend and the hold legend of tap-hold keys, in larger type, and drops hold-alone marks,
  `✱` and the notes under other keys. "Hide keys inherited from lower layers" turns upper layers into a diff view:
  only the keys the layer itself defines are drawn. "Highlight pressed keys" (off by default) lights up the keys
  you are holding, with a short afterglow so quick taps show; with it on, typing also counts as activity for
  "fading out on the base layer". It needs firmware with the `0xF7` events and has a privacy cost, see below.
- Reads a Vial export (`.vil`); path is configurable, default `~/aurora.vil`.
  The file is re-read automatically whenever it changes on disk.
- Settings → Keymap source → "Keyboard when connected" (the default): the keymap, encoders, combos, tap dances,
  key overrides and QMK settings are read live from the keyboard over the Vial protocol (read-only, under half a
  second), on connect and again in the background each time the overlay opens, so edits made in the Vial GUI show
  up without re-exporting. The header shows "<keyboard> · live" instead of the file name. The `.vil` is used while
  the keyboard is away or a read fails.
- Overlay shows all non-empty layers at once (layers with only transparent/unassigned keys are hidden); press `0`–`9` to zoom into a layer, `a` for all,
  `←`/`→` to cycle, `Esc` to close. Clicking anywhere else also closes it.
- Shows mod-taps (hold modifier under the tap key), layer-taps, combos and encoder bindings.
  Layer names from Settings replace "L1"-style legends on layer keys and in the layer chips.
  Settings → Encoders picks which half's encoder to draw (Vial exports a slot per half even if unused).
- Hold-alone actions (firmware with `hold_alone.c`): set Settings → Hold-alone actions → Config layer
  (e.g. "Last layer"). That layer is hidden and its keys show in teal (`◔`) at the top right of the
  layer-tap / mod-tap keys they belong to; bindings the firmware can never send are flagged below the keymap.
- Custom keycodes (`USER00`… / `QK_KB_0`…) show the names from Settings → Custom keycode names
  (comma-separated, or "Load from vial.json…" to take `customKeycodes[].shortName`); unnamed ones show as `U0`, `U1`…
- Below the keymap: enabled key overrides (trigger + mods → replacement, with a layer restriction if any) and a
  line with the tap-hold QMK settings stored in the `.vil` (tapping term, Permissive Hold, Chordal Hold, Flow Tap…).
- Tap-hold keys exempt from Chordal Hold's same-hand rule are marked with a small `✱` (once the set is known).
- Keyboard link (raw HID, firmware with the `vial_full` keymap's `host_hid.c`, see
  [egno/vial-qmk](https://github.com/egno/vial-qmk/tree/vial/keyboards/splitkb/aurora/corne/keymaps/vial_full)): the menu shows whether
  the keyboard is connected plus its firmware commit and build date. With Settings → "Show clock and
  input source on the keyboard OLED" (on by default) the right OLED shows the time and the active
  input source ("EN", "RU"); the text is cleared on quit and expires by itself after 90 s otherwise.
  The device is opened shared, so the Vial GUI keeps working alongside.
- Live data over the same link (each part needs firmware that answers the command; older builds are
  simply left alone until the next connect):
  - Misfire heatmap (`0xF3`): base-layer mod-taps are tinted by how often their tap/hold decision was
    corrected with Backspace; zoomed into the base layer the counts show too (bottom left held by
    mistake, bottom right tapped by mistake). The tint is relative between keys, the counters live in
    the keyboard's RAM and "tapped" includes ordinary typos. `m` hides/shows it; the menu has
    "Reset Misfire Counters".
  - Active layers (`0xF4`, polled ~12 times a second while the overlay or the ghost is on screen, unless the
    keyboard pushes its state, see `0xF7`): outlined cards and dotted chips for the
    layers that are on, a lock for Layer Lock, and chips for trainer / Caps Word / Caps Lock / one-shot
    mods and layer. With a single layer zoomed, the overlay switches to the highest active layer as it
    changes (Settings → "Follow the active layer", on by default).
  - Push instead of poll (`0xF7`): while the overlay or the ghost is on, the app subscribes to the keyboard's
    events (for 5 s at a time, renewed every 1.7 s) and the keyboard reports state changes by itself, so layers
    and modifiers show without the polling delay and `0xF4` is asked only every 5 s as a safety net. The
    subscription is ended when nothing needs it and on quit, and expires by itself if the app dies. Firmware
    without `0xF7`, or a subscription that cannot be kept up, means polling as before.
    - Privacy: a subscriber is also sent the positions of the keys that are physically down, and every program
      that has the raw HID interface open can read those reports (with the keymap that is what is being typed,
      without any input-monitoring permission). The app looks at them only for the ghost's "Highlight pressed
      keys" (off by default) and, in "While typing", to notice that a key went down (which key is not kept or
      shown); it ignores them otherwise. The firmware sends them to any subscriber regardless.
    - Vial GUI: Vial pairs replies with its requests by order only, so a report the keyboard sends unasked can
      corrupt what Vial reads. While the Vial app is running (bundle id `today.vial`, or any app whose name or
      bundle id has a word starting with "vial") the app holds no subscription and polls instead; it
      subscribes again when Vial quits.
    - Any other program on the raw HID interface (Vial run from source, vial.rocks in a browser): noticed by
      the replies to requests this app did not send. The app then drops the subscription and stops polling and
      feeding the OLED, so nothing of its own reaches that program, and starts again two minutes after the last
      such reply; the ghost shows the last known state meanwhile. A report or two can still get through before
      the other program sends its first request (vial.rocks logs `g_read_timeout is not defined` for those).
  - Chordal Hold exemptions (`0xF6`) fill the `✱` markers, and the tap-hold line shows Chordal Hold and
    the Flow Tap term as the keyboard applies them now.
  - Trainer results (`0xF5`): every finished trainer session is appended to
    `~/Library/Application Support/VialHelper/trainer-history.json` (noticed within ~5 s, also with the
    overlay closed). Menu → "Trainer History…" shows speed and accuracy over sessions, misses by kind
    and the slowest / least accurate characters. Per-character numbers in a record are what was added
    since the previous record of the same keyboard power cycle (see `TrainerHistory.swift`).

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
swift run VialHelper --render out.png --chordal-exempt 303,304,305  # mark keys (row*100+col) as Chordal Hold exempt
swift run VialHelper --render out.png --ghost   # render the ghost-mode view (layer from --inject-state, see below)
                                                # over a light-to-dark backdrop; --ghost-opacity 0.3 sets the plate opacity,
                                                # -ghostSimplifiedLabels NO / -ghostHideInherited YES override those settings
swift run VialHelper --selftest                 # open overlay, exercise key handling, exit 0/1
swift run VialHelper --settings                 # launch with the Settings window open
swift run VialHelper --hid-version              # print firmware version, build date, commit and exit
swift run VialHelper --hid-status "12:34|EN"    # send one OLED status text (rows split by "|"), print the reply
swift run VialHelper --hid-status "" [--ttl N]  # empty text clears it; --ttl sets the lifetime in seconds (default 90)
swift run VialHelper --hid-raw "f0 02"          # send raw hex bytes as one report, print the reply
swift run VialHelper --vial-dump out.json       # read the keymap live over the Vial protocol, write it as .vil-like JSON
swift run VialHelper --vial-diff [file.vil]     # compare the live read with a .vil (default: the configured one), list every difference
swift run VialHelper --render out.png --live    # render from the live read (falls back to the file if it fails)
                                                # modifiers: --vial-timeout 0.00001 (force a failure), --vial-no-definition
swift run VialHelper --hid-misfire              # print the keyboard's misfire table (and it as an --inject-misfires argument)
swift run VialHelper --hid-live                 # ask 0xF4 / 0xF5 / 0xF6 / 0xF7 (state, pressed keys; no subscription) once and print what comes back
swift run VialHelper --live-probe 5             # run the live data for 5 s as if the overlay were open: whether the state is
                                                # pushed (0xF7) or polled, requests per command, events received
swift run VialHelper --live-selftest            # report parsers, trainer history, 0xF7 event routing and push logic against
                                                # a simulated keyboard (also part of --selftest)
swift run VialHelper --render out.png --fake-misfires            # or --inject-misfires "hex;hex;…" (0xF3 replies)
swift run VialHelper --render out.png --inject-state "f4 00 …"   # a 0xF4 reply: active / locked layers, indicators
swift run VialHelper --render out.png --inject-taphold "f6 00 …" # a 0xF6 reply: Chordal Hold exemptions, tap-hold line
swift run VialHelper --render out.png --ghost --inject-matrix "f7 02 00 08 06 01 00 00 00 00 40"  # a 0xF7 matrix event:
                                                # those keys drawn as pressed (here 0,0 and 7,4), whatever the setting says
swift run VialHelper --render-trainer out.png --fake-trainer     # Trainer History window (or --trainer-history file.json)
```

## Toolchain note

The project builds with the Command Line Tools alone. On the macOS 27 SDK SwiftUI's `@State`
is a compiler macro whose plugin ships only with Xcode, so views keep transient state in
`ObservableObject`s (`@ObservedObject`) instead of `@State`.

## License

[MIT](LICENSE)
