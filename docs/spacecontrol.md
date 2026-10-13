# SpaceControl

SpaceControl is a fork of [Axial](https://github.com/consi/axial) (MIT, © consi)
that adds a full input-mapping layer to the driver: a 6×6 axis-mixing matrix,
per-axis response shaping, axis locks, rich button assignments and per-application
profiles. The event ABI, the 3Dconnexion compatibility frameworks and the existing
`settings.json` format are unchanged. Every new setting is optional.

- [Features](#features)
- [Processing order](#processing-order)
- [Profile JSON schema](#profile-json-schema)
- [Control API and monitor additions](#control-api-and-monitor-additions)
- [Compatibility](#compatibility)
- [Performance](#performance)
- [Build and permissions](#build-and-permissions)

## Features

The settings window has seven tabs: **Live**, **Mapping**, **Tuning**, **Buttons**,
**Profiles**, **Test** and **Service**. The sidebar selects the profile being
edited. Every change is saved and applied right away.

### Live

Two real-time 3D views sit side by side. The first is the **physical
SpaceExplorer**: the cap follows the raw HID input and pressed keys light up.
The second is the **mapped 6DoF output**, a gizmo driven by the post-mapping
stream, so it shows exactly what the CAD application receives. A readout table
lists raw and mapped values for every axis. The view always previews the
profile selected in the sidebar, even when another application is in front
(see [`preview`](#control-api-and-monitor-additions)).

### Mapping: 6×6 mixing matrix

Rows are the outputs sent to the application (X, Y, Z, RX, RY, RZ). Columns are
the physical inputs. Each cell holds a weight from −4 to 4.

| Operation | How |
| --- | --- |
| Route an input | Drag an input chip onto an output row. The input moves there and is removed from every other row |
| Swap outputs | Drag an output's ⠿ handle onto another output |
| Invert | Use a negative weight in a cell, or the per-output **Invert** switch |
| Disable | Turn off the per-output **On** switch |
| Mix | Set more than one weight in a row, e.g. tilt also pans |
| Translation ↔ rotation | Any input can drive any output, e.g. twist → zoom |
| Fine weights | Click a cell to cycle 0 → +1 → −1, or right-click it for ±0.25…±2 |

Each output row also has a **Speed** slider (output gain) and a live bar.
**Presets** offers: straight through, twist → zoom, swap push/pull ↔ lift/press,
pan & zoom only, rotate only, invert all rotations, lift/press → zoom, and tilt
also pans.

### Tuning (per input axis)

- **Sensitivity**: multiplier applied after the curve.
- **Deadzone**: measured in raw units around the calibrated center. The output
  is *rescaled*, so it starts at 0 at the edge of the deadzone and still reaches
  full scale at full deflection, with no jump.
- **Response curve** for the normalized magnitude `x` (1 = full calibrated
  deflection) and strength `k`:

  | Curve | Formula |
  | --- | --- |
  | Linear | `x` |
  | Expo | `(1−k)·x + k·x³` |
  | Power | `x^(1+3k)` |
  | S-curve | `(1−k)·x + k·x²(3−2x)` |

  Every curve maps 0 → 0 and 1 → 1 and is monotonic. Past full deflection the
  curve continues linearly, so the output never saturates early. The plot draws
  the service's exact shaping function together with the live input.
- **Smoothing**: an exponential filter with a time constant in ms, where
  `α = 1 − e^(−dt/τ)` and `dt` comes from report timestamps. The result does not
  depend on the report rate. When the shaped input returns to zero, the filter
  *snaps to rest* immediately, so the view never drifts after you let go.
- **Calibration wizard**: step 1 averages the resting position for 2 s with
  hands off (center). Step 2 records 10 s of full travel on every axis (range).
  Axes that move less than 60 units keep the nominal ±350.
- **Axis locks** (per profile): *Free 6DoF*, *Dominant axis only* (only the
  output with the largest magnitude passes), or *Translate OR rotate* (group:
  whichever of the translation or rotation groups has the larger peak passes).
  **Translation** and **Rotation** master switches are also available.
- **Apply to all axes** and **Apply to translation/rotation axes** copy the
  settings of the selected axis.

### Buttons

All 15 SpaceExplorer keys are supported (1, 2, Top, Left, Right, Front, Esc, Alt,
Shift, Ctrl, Fit, Panel, +, −, 2D), as are the controls of other devices. To
select a key, click it or press it on the device. Each key gets one behaviour:

| Behaviour | Details |
| --- | --- |
| Native button | The application decides (default) |
| Keyboard shortcut | A recorded key + modifiers, held for as long as the button is held |
| Macro | Up to 64 steps of *key chord*, *type text* and *delay (ms)*. Real modifier keys are pressed around each chord for apps such as Blender and Fusion |
| Application command | A command id from the catalog the app published (Navlib apps such as Fusion), or typed in by hand |
| Driver action | `dominant`, `group`, `translation`, `rotation` (toggles), `pause` (all motion on/off), `faster` / `slower` (all output speeds ×/÷ 1.25, clamped to 0.01…20), `resetSpeed` (back to the profile's speeds), `fit` (sends the Fit command to the foreground app) |
| Open | A URL (anything with `://`), file, folder or application path |
| Shell | A `/bin/sh -c` command, run in the background as the user with no stdin or stdout |

**Also send the native button to the application** is the `passthrough` flag.
New custom assignments start with it turned off, which withholds the native
button event so the press doesn't trigger two actions. Application commands
always reach the app. Driver toggles change runtime state only: they reset when
the profile is resolved again (after an app switch or a configuration save).

### Profiles

A profile is chosen automatically from the bundle id of the frontmost
application. The service tries these keys in order:

1. `bundle@vvvv:pppp` (app on a specific device, e.g. `com.autodesk.fusion360@046d:c627`)
2. `bundle`
3. `*@vvvv:pppp`
4. `*` (all applications)

The built-in application presets have tuned defaults:

| Application | Bundle id | Preset |
| --- | --- | --- |
| Autodesk Fusion | `com.autodesk.fusion360` | expo 0.35, deadzone 8, smoothing 12 ms |
| OrcaSlicer | `com.orcaslicer.OrcaSlicer` | expo 0.5, deadzone 10, roll speed 0.6 |
| Blender | `org.blenderfoundation.blender` | S-curve 0.4, deadzone 6, smoothing 8 ms |
| PrusaSlicer | `com.prusa3d.slic3r.` | expo 0.5, deadzone 10 |
| FreeCAD | `org.freecad.FreeCAD` | expo 0.3, deadzone 8 |

**Choose application…** adds any other app. In the **Profiles** tab you can
rename a profile, duplicate it to another app or to the connected device, reset
it, or delete it. **Export…** writes one profile to `Name.spacecontrol.json`;
**Export all…** writes every profile. **Import…** accepts a SpaceControl bundle,
a full Axial `settings.json`, or a bare profile object (which replaces the
selected profile). The bundle format is:

```json
{"format": "axial-spacecontrol-profiles", "version": 1, "profiles": {"com.autodesk.fusion360": {}}}
```

## Processing order

`sn::Processor::process` (`include/axial/mapping.hpp`) runs on the HID input
queue for every motion report:

1. **Calibrate**: `centered = raw − center`, with `range` as full deflection.
2. **Deadzone (rescaled)**: if `|centered| ≤ deadzone`, the result is 0.
   Otherwise `m = (|centered| − dz) / (range − dz)`, with dz capped at 95 % of
   the range.
3. **Response curve**: `curve(m, curveAmount)`.
4. **Sensitivity**: `× sensitivity × 350` (nominal full scale), keeping the sign.
5. **Smoothing**: the time-constant filter; a zero input snaps to rest.
6. **6×6 matrix**: `out[o] = Σ matrix[o][i] · shaped[i]`.
7. **Gates**: `enabled[o]`, plus `translation` (outputs 0–2) and `rotation`
   (outputs 3–5).
8. **Axis lock**: `dominant` or `group`.
9. **Output stage**: `× gain[o]`, then `invert[o]`, then round and clamp to int16.
10. **Orbit flag**: `Flags::orbit` is set from `orbit`.

After processing, the service clears suppressed buttons (held across a focus
change) and withheld buttons (`passthrough: false`) from the event. Then it
delivers the event to the foreground clients and the web API. Button and
reset/removed events reuse the last mapped axes, or zeros, without advancing
the smoothing state. Axis order everywhere: 0 X, 1 Y, 2 Z, 3 RX (tilt), 4 RY (roll),
5 RZ (spin).

## Profile JSON schema

Profiles live in `~/Library/Application Support/Axial/settings.json`, or in the
file named by `AXIAL_CONFIG`:

```json
{"version": 1, "web": {"enabled": true}, "profiles": {"*": {}, "org.blenderfoundation.blender": {}}}
```

The file may hold at most 128 profiles. Keys must be 1–255 characters. The
service validates the whole file (`parseProfile` in `src/service.mm`), so a
single invalid value rejects the configuration: `setConfig` returns
`Invalid version 1 configuration` and the running configuration stays in place.
All fields are optional. Arrays marked `[6]` must have exactly six entries.

| Field | Type | Range / values | Default | Stage |
| --- | --- | --- | --- | --- |
| `name` | string | ≤ 128 chars | — | display name |
| `gain` | number[6] | 0…20 | 1 | output speed (legacy) |
| `invert` | bool[6] | | false | output (legacy) |
| `enabled` | bool[6] | | true | output on/off |
| `deadzone` | number[6] | 0…1000 raw units | 0 | input (legacy key) |
| `sensitivity` | number[6] | 0…10 | 1 | input |
| `curve` | string[6] | `linear` `expo` `power` `scurve` | `linear` | input |
| `curveAmount` | number[6] | 0…1 | 0 (the app writes 0.5) | input |
| `smoothing` | number[6] | 0…500 ms (≤ 0.5 = off) | 0 | input |
| `center` | number[6] | −1000…1000 | 0 | calibration |
| `range` | number[6] | 10…2000 | 350 | calibration |
| `matrix` | number[6][6] | −4…4, `matrix[output][input]` | identity | mix |
| `lock` | string | `none` `dominant` `group` | `none` | lock |
| `dominant` | bool | legacy; `true` means `lock: "dominant"` unless `lock` names another lock | false | lock |
| `translation`, `rotation` | bool | | true | gates |
| `orbit` | bool | | true | event flag |
| `led` | bool | | true | device LED |
| `buttons` | object[≤ 32] | indexed by HID button | — | buttons |

Each `buttons[i]` object may set **at most one** of `keyCode`, `command`, `action`,
`macro`, `open` and `shell`:

| Field | Type | Range / values |
| --- | --- | --- |
| `keyCode` | integer | 0…127 (macOS virtual key code) |
| `modifiers` | integer | 0…0xffffffff (`CGEventFlags` mask) |
| `command` | string | ≤ 4096 chars, an application command id |
| `action` | string | `dominant` `translation` `rotation` `faster` `slower` `fit` `group` `pause` `resetSpeed` |
| `macro` | step[≤ 64] | every step has one of `{"keyCode", "modifiers"?}`, `{"text"}` (≤ 1024 chars) or `{"delay"}` (0…10000 ms), plus an optional `label` (≤ 128) |
| `open` | string | ≤ 4096 chars: a URL, or a path (`~` is expanded) |
| `shell` | string | ≤ 4096 chars, run with `/bin/sh -c` |
| `passthrough` | bool | `false` withholds the native button (ignored for `command`) |
| `label` | string | ≤ 128 chars |

Example:

```json
{
  "name": "Blender",
  "curve": ["scurve","scurve","scurve","scurve","scurve","scurve"],
  "curveAmount": [0.4,0.4,0.4,0.4,0.4,0.4],
  "deadzone": [6,6,6,6,6,6],
  "smoothing": [8,8,8,8,8,8],
  "matrix": [[1,0,0,0,0,0],[0,0,0,0,0,1],[0,0,1,0,0,0],[0,0,0,1,0,0],[0,0,0,0,1,0],[0,0,0,0,0,0]],
  "lock": "none",
  "buttons": [
    {"keyCode": 6, "modifiers": 1048576, "label": "⌘Z", "passthrough": false},
    {"action": "group", "passthrough": false},
    {"macro": [{"keyCode": 1, "modifiers": 131072}, {"delay": 50}, {"text": "hello"}], "passthrough": false},
    {"open": "https://docs.blender.org", "passthrough": false},
    {"shell": "osascript -e 'beep'", "passthrough": false}
  ]
}
```

## Control API and monitor additions

The control socket (`/tmp/axial-$UID/events.control`, newline-delimited JSON)
gains one operation:

```json
{"op": "preview", "profile": "com.autodesk.fusion360"}
```

It returns `{"ok": true}`, and from then on mapped monitors mirror the output
of that exact profile key instead of the active one. If the key doesn't exist,
the service resolves it the normal way (by its bundle part, then the fallbacks).
An empty or missing `profile` clears the preview. A non-string `profile`, or one
longer than 255 characters, returns `{"error": "Invalid preview profile"}`.
Driver actions are applied to the previewed profile as well, so the Live view
stays in sync.

`status` gains two string fields: `activeProfile` (the profile key matched for
the foreground app, or `""`) and `previewProfile` (the current preview key, or
`""`).

On the event socket, a monitor can also ask for the post-mapping stream by
setting `Flags::mapped = 16` in its hello record together with `monitor`
(`flags = 17`). For each motion report it then receives the usual raw record,
followed by a mirrored record with `Flags::processed = 32` set and the mapped
axes. The event queue coalesces the raw and processed streams separately.
Monitors that don't set `mapped`, and normal subscribers, see no change.

## Compatibility

- **Event ABI**: unchanged (64-byte records, version 1). `mapped` and `processed`
  are new flag bits, and old clients never set them.
- **Frameworks** (3DconnexionClient, Navlib, 3DconnexionJS web API): unchanged.
  They receive the fully mapped event.
- **settings.json**: legacy profiles load unchanged, and upstream Axial ignores
  the new keys. Legacy fields map onto the new pipeline:
  - `gain` and `invert` are the output stage (after the matrix).
  - `deadzone` is the input stage. It is now rescaled, so full deflection still
    reaches full output, where upstream subtracted the deadzone.
  - `dominant: true` becomes `lock: "dominant"`. The app writes both keys so that
    upstream Axial can still read the file.

## Performance

The engine is pure and deterministic, and it doesn't allocate on the input
path. A fixed `std::array` state per device keeps it free of locks on the HID
queue. `tests/mapping_tests.cpp` covers every stage: matrix swap and mix, locks,
deadzone, calibration, curves, smoothing, queue coalescing and clamping. It
also replays a real SpaceExplorer capture 200 times through a busy mapping
(expo, deadzone, smoothing, mix, group lock) while counting allocations. The
engine costs about **34–40 ns per report** on Apple silicon (RelWithDebInfo),
which is negligible next to the 8 ms HID report interval. The test fails at
2 µs or when any allocation occurs.

```sh
ctest --test-dir ~/Library/Caches/axial-build/native -R mapping --output-on-failure
```

## Build and permissions

The build directory must not contain spaces. If the checkout lives in a path
with spaces, configure out of tree:

```sh
cmake -S . -B ~/Library/Caches/axial-build/native -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build ~/Library/Caches/axial-build/native
ctest --test-dir ~/Library/Caches/axial-build/native -LE gui
```

The app is built at `~/Library/Caches/axial-build/native/bin/Axial.app`.

The service needs two permissions:

- **Input Monitoring**: required for the exclusive HID open (seize). Without
  it, the service exits with `Exclusive HID open failed … Check Input Monitoring
  permission`.
- **Accessibility**: required for keyboard shortcuts and macros (synthetic key
  events). Without it, shortcut and macro presses are dropped. The **Service**
  tab and the **Buttons** editor have a button to request it. Ad-hoc rebuilt
  binaries may need the permission granted again.

Open and shell actions need neither permission.
