# flashbangcolorchanger
Flashbang Color Changer for Counter Strike 2

This script will change the color of the flashbangs, instead of being pure white it will make them any color you want.
Optionally, it has an eyelids key which allows you to close your eyes before being flashed.

Created by Brian Vuksanovich.

Visit my YouTube channel to learn more about this script and also to report bugs:

https://www.youtube.com/@brian-vuksanovich

Thank you so much!

## Dynamic overlay (v2.53)

The overlay no longer jumps to a fixed opacity. Its opacity follows an **estimated**
flash intensity, so a partial flash gives a faint overlay and only a full white screen
reaches the opacity you set in the settings.

How it works (details at the top of `FlashBangColorChanger.ahk`):

1. A grid of points (4x3 by default) is read on the primary monitor with `PixelGetColor`.
2. Each point gets a score from its brightness (luminance) and how neutral/white it is,
   so bright yellow, a blue sky, etc. do not count as a flash.
3. The global level is the score reached by at least `CoverageThreshold` % of the points,
   so a small white area (HUD, lamp, window) cannot trigger the overlay by itself.
4. Weak readings must repeat (`ConfirmChecks`), the result is smoothed over time, and the
   overlay fades out at the speed set by "Fading".
5. Opacity = `Transparency` x curve(intensity). `Transparency` is now the **maximum**.

### Settings (`settings.ini`)

Existing keys keep their meaning (`Transparency` is now the maximum opacity, reached
only at full intensity). Missing keys get these defaults; invalid values are reset.

| Key | Default | Meaning |
|---|---|---|
| `IntensitySensitivity` | `1.0` | Multiplier on the estimated intensity (0.25-4). Also in the settings window. |
| `IntensityThreshold` | `0.25` | Intensity below which no overlay is shown (0-0.95). Also in the settings window. |
| `ResponseCurve` | `1.5` | Shape of the response: >1 keeps partial flashes faint, 1 = linear. |
| `SmoothingAlpha` | `0.7` | How fast the overlay rises (per 50 ms, 0.05-1). |
| `WhiteTolerance` | `96` | Max difference between RGB channels still treated as white (0-255). |
| `BrightnessFloor` | `0.45` | Luminance (0-1) under which a point does not count at all. |
| `CoverageThreshold` | `70` | Percent of points that must be flashed (10-100). |
| `SampleColumns`, `SampleRows` | `4`, `3` | Sample grid. Cost = columns x rows `PixelGetColor` calls per check (3x2 = old cost). |
| `ConfirmChecks` | `2` | Consecutive checks needed before a weak/medium flash is shown. |
| `TargetProcess` | `cs2.exe` | Only detect while this program is the active window. Empty = any window. |
| `ShowDebug` | `0` | `1` shows the live values (intensity, opacity, sampling time) in a tooltip. |

### Limitations

- RGB colours do not contain the real opacity of the CS2 flash; this is an estimate.
  Anything neutral and bright that fills the screen (a light grey wall, a loading
  screen) can look like a partial flash. Lower the sensitivity or raise
  `IntensityThreshold` / `BrightnessFloor` if that happens on a map.
- Only the primary monitor is analysed and covered.
- Use windowed / fullscreen windowed (borderless) mode in CS2.
- Nothing reads or modifies the game: the script only reads screen colours.

### Eyelids key

The eyelids key is now a true toggle: closed stays closed (full opacity) until you
press it again, whatever the detection sees. When you reopen, the overlay fades out,
or keeps following a flash that is still on screen.

### Tests

`tests/` contains a harness that loads the real script functions and checks the
scenarios (normal screen, weak/strong flash, local white areas, fade-out, eyelids,
enable/disable, soak test) on synthetic screens. See `tests/run_tests.sh`.
