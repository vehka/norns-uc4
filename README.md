# norns-uc4

A mod that makes a [Faderfox UC4](https://www.faderfox.de/uc4.html) work
with every norns script, without changes to the scripts:

- the UC4 gets one fixed setup, "Norn", which the mod can send to it
- when a script starts, its params are mapped to the UC4's controls
- the UC4's display values and button LEDs follow the params
- touching a control shows on the norns screen what the controls of that
  group are mapped to

Files: `lib/mod.lua` is the mod, `lib/uc4.lua` the library it uses.

## Install

Put this repository in `dust/code/` (as `norns-uc4`), enable it in
SYSTEM > MODS and restart norns. Then load the Norn setup to the UC4, once
(see below).

## How params are mapped

When a script has started, the mod maps its params by the first of these
that exists:

1. `dust/data/uc4/<script name>.lua`, a layout you made
2. `dust/code/<script>/lib/uc4_layout.lua`, a layout that comes with the
   script
3. automap

**Automap** takes the params in the order the script added them:

- controls, tapers, numbers and options go to the encoders, then to the
  faders. Each section of the params (a separator or a group) starts a new
  encoder group, so a section's params sit side by side.
- binary params go to the green buttons (1-7 of each group, 8 is the param
  view switch), then to the encoder push buttons
- the params of norns itself (levels, reverb, compressor, softcut, clock)
  and params with `allow_pmap` off are left out. A layout can still map
  them, e.g. `fader9 = "output_level"`.
- the params other mods add to every script go to the last encoder groups,
  one mod per group, starting from group 8
- nothing is overridden: a param that has a mapping already (made in
  PARAMETERS > MAP, to the UC4 or to any other controller) keeps it, and a
  UC4 control that is in use is skipped

**A layout** is a lua file that returns the param ids for each control, one
list per group:

```lua
return {
  enc = {
    {"cutoff", "resonance"},      -- encoder group 1
    {"attack", false, "release"}, -- group 2, encoder 2 skipped
  },
  fader = {{"level"}},
  fader9 = "main_level",
  button = {{"mute"}},
  push = {},
  automap = true, -- map the other params to the free controls
}
```

Param ids are shown in maiden with `params:print()` or
`params:list()`. With `automap = false` only the params in the layout are
mapped.

The mappings are ordinary norns MIDI mappings with echo on, so they show up
in PARAMETERS > MAP, and norns sends a param's new value to the UC4 whenever
it changes. Mappings saved by the script (PARAMETERS > MAP writes all of
them to the script's `.pmap` file) are kept by automap, but a layout
replaces them for the params and controls it names.

## Param view

Turn, move or press a UC4 control and the norns screen shows the eight
controls of that group with the names and values of their params, the
touched one highlighted. It goes away 1.5 seconds after the last touch.

Push an encoder to look without changing anything: the view stays up for as
long as the encoder is held. (The UC4's shift key isn't sent over MIDI, so
it can't be used for this.) The view isn't shown while the norns menu is
open.

**Green button 8 turns the view on and off**, in every button group. Its
LED is lit when the view is on. The setting is kept over restarts. Automap
leaves button 8 free in every group; if you map a param to one of them, that
one is a normal button again.

## The Norn setup

Every control sends an absolute 7 bit CC. Each kind of control has its own
MIDI channel, and the CC number is `(group - 1) * 8 + (control - 1)`:

| Control | Channel | CC | Notes |
|---|---|---|---|
| Encoders 1-8 | 13 | 0-63 | max acceleration, value shown on the display |
| Encoder push buttons 1-8 | 14 | 0-63 | momentary (127 / 0) |
| Faders 1-8 | 15 | 0-63 | snap mode |
| Fader 9 | 15 | 64 | the same in all groups |
| Green buttons 1-8 | 16 | 0-63 | momentary (127 / 0), LED set by norns |

The encoder groups are named `nor1` to `nor8`.

### Loading it to the UC4

The UC4 only takes setup data when it is in receive mode, and the Norn setup
**overwrites one of its 18 setups** (setup 16 by default). Make a backup first
if that setup is in use: in setup mode, hold encoder 8 (`SndA`) while a sysex
tool on a computer records the dump.

1. Install and enable the mod (see above).
2. On the UC4, hold shift and press edit twice (setup mode). Select the
   setup to overwrite with encoder 1 (`SE16`). Then press encoder 7 and
   keep it down while the bar lines run across the display, until they
   finish. (A short press only shows the function name, `rEc`, and the UC4
   then ignores the data.)
3. On norns, open SYSTEM > MODS > NORNS-UC4. With `norn setup` selected, E3
   picks the setup number (the same as on the UC4), K3 sends.
4. The UC4 shows the setup number (`SE16`) when the setup is stored. If it
   still shows `rEc`, receive mode wasn't active: repeat from step 2. Press
   edit to leave setup mode.

`.syx` dumps copied to `dust/data/uc4/` show up in the same menu (E2), for
restoring a backup.

## Using the library in a script

A script can also use `lib/uc4.lua` directly, for example to map params
itself: `local uc4 = include("norns-uc4/lib/uc4")`.

| Function | |
|---|---|
| `uc4.connect()` | the UC4's midi device, nil when it isn't connected |
| `uc4.map(dev, id, kind, group, n)` | map one param; kind is `"enc"`, `"push"`, `"fader"` or `"button"` |
| `uc4.apply_layout(dev, layout)` | map params as a layout table says |
| `uc4.automap(dev, opts)` | map the remaining params; `opts.filter(id)`, `opts.sections = false` |
| `uc4.control(kind, group, n)` | cc number and channel of a control |
| `uc4.redraw(dev, id)` | send one mapped param's value to the UC4 |
| `uc4.refresh_values(dev)` | send all mapped params' values |
| `uc4.watch(dev)` / `uc4.unwatch(dev)` | turn the param view on / off |
| `uc4.send_norn_setup(dev, slot)` | send the Norn setup (UC4 in receive mode) |
| `uc4.load_conf(dev, filename)` | send a `.syx` setup dump (UC4 in receive mode) |

## Notes

- Encoders have 128 steps. norns MIDI mappings are 7 bit, so the UC4's
  14 bit mode isn't used.
- Number and option params have fewer values than a control has positions.
  With norns' echo on, each small turn of an encoder would be answered with
  the position of the value the param is still at, and the encoder would
  never get anywhere. So echo is off for these params; the library tracks
  where each control is and sends a value only when needed.
- On an encoder, a short turn steps a number or option param to its next
  value, also when there are only two: each value takes 8 positions in the
  middle of the encoder's range (fewer for long lists), and the encoder is
  set back to the exact position of the current value when it has been left
  alone for a moment. The number on the UC4's display is that position; the
  param view on norns shows the value. Faders use their whole range.
- While the param view is up, the mod swaps `screen.update` for a function
  that does nothing, so the script's own drawing isn't shown, and calls the
  script's `redraw()` when the view goes away.
- The setup dump format was worked out from dumps made by a UC4 with
  firmware 2.03. It is described at the top of the setup section in
  `lib/uc4.lua`.
