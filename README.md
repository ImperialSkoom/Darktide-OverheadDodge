# Overhead Dodge

A Warhammer 40,000: Darktide mod that detects supported Crusher and Mauler overhead attacks and captain ground slams. When an incoming attack is within reach, the mod turns your camera toward the attacker and attempts a dodge before impact.

## Installation

1. Set up Darktide Mod Loader and Darktide Mod Framework (DMF).
2. Place the `OverheadDodge` folder in Darktide’s `mods` directory. The entry point should be at `mods/OverheadDodge/OverheadDodge.mod`.
3. Add `OverheadDodge` on its own line in `mods/mod_load_order.txt`, after `dmf`.
4. Launch the game and open Mod Options to enable or configure OverheadDodge.

## Settings

**Seconds before impact** controls when the mod attempts the dodge. It defaults to **0.32 seconds** and accepts values from **0.10 to 0.48 seconds**. Higher values trigger the attempt earlier. As a client, the mod estimates impact time from replicated attack animations and adjusts for latency.

The mod attempts dodges while you’re grounded and walking or sprinting. It skips attempts during UI input and interactions, and respects the game’s dodge cooldown.
