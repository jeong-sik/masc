# TUI theme palettes in TOML

The 14 built-in presets keep their colors in `config/themes/<preset>.toml`.
The compiled-in values in `lib/masc_tui/core/theme.ml` are only the fallback
when no file is present; editing the file is how you operate the palette.

## Use

```sh
cp -r config/themes <base-path>/.masc/config/themes
# edit <base-path>/.masc/config/themes/midnight.toml, then restart masc-tui
```

`masc-tui` reads the directory once at startup (`Theme_file.load_overrides`).
To read a different directory, pass `--themes-dir <path>`; existing
`--theme <name>` then picks the edited palette automatically. There is no
hot reload: restarting the TUI applies the edits.

| Preset file | Floors |
| --- | --- |
| `midnight.toml`, `arcade_hi.toml`, `paper_light.toml`, `mono.toml` | standard |
| `muted*.toml` (5 files) | down-tone |
| `solarized_dark.toml`, `nord.toml`, `dracula.toml`, `gruvbox_dark.toml`, `catppuccin_mocha.toml` | aa |

Floors (WCAG contrast ratios) stay in `Theme.text_floors`; the files carry
colors only.

## Format

Each file is a flat table of `"#RRGGBB"` hex strings. Keys match the palette
fields in `lib/masc_tui/core/theme.mli`:

`surface_0`, `surface_1`, `surface_2`, `border_subtle`, `border_inactive`,
`border_focused`, `text_bright`, `text_primary`, `text_secondary`,
`text_muted`, `status_ok`, `status_active`, `status_attention`,
`status_critical`, `status_ai`, `status_historical`, `accent`,
`selection_bg`, `selection_fg`, and `cool_stops` / `warm_stops` / `ai_stops`
(arrays of exactly three hex strings).

- A missing key keeps the built-in color, so you can override one color.
- An unknown key, a non-string color, a wrong-size stops array, or a parse
  error makes the whole file fall back and prints one warning per file to the
  TUI log (`[masc-tui] theme: <path>: <reason> (kept built-in)`) plus a
  startup toast. Other valid files still apply.
- Unknown preset files are ignored because the preset set is a closed type;
  `--theme` and `[tui].theme` in `runtime.toml` only name the 14 presets.

Text, status, and accent colors are lifted in Oklab to meet the floors, so a
color you write below the floor is shown lighter than written.
