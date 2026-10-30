# Readable secondary TUI text and typed tool presentation

Issue: #45304. This evidence covers source and color arithmetic. It does not
certify the compiled renderer, terminal pixels, keyboard focus, resizing,
installed runtime or whole-product accessibility conformance.

## Changes

Secondary text uses the terminal's measured foreground/background, preserving
4.5:1 contrast after output-capability projection. The previous 3:1 floor
mistook secondary information for large text. The 4.5:1 benchmark follows
[WCAG 2.2 SC 1.4.3](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html).
Palette absence, insufficient starting contrast, unsupported colour depth or
lossy quantization that breaks this floor retains default foreground. This
fallback preserves the user's palette; it cannot repair an unreadable terminal
configuration. Chat Tool/Journal/Skill/Thinking bodies and span closures use
this foreground without an extra SGR dim. Palette generations invalidate
Markdown closing-string caches when a theme changes.

The renderer no longer parses words such as `failed`/`running`, middle dots,
counts, units or glyph prefixes to infer tool identity/status colours.
Compact/full rows retain producer-generated typed status glyphs and labels in
neutral secondary text. Results retains its typed result-state colours;
received output is distinct from success, and missing outcome evidence remains
explicit. Colour-independent glyphs/labels follow the principle in
[SC 1.4.1](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html).
No new tool-state or approval behavior is introduced.

## Direct measurements

`probe.ml` links the actual three colour modules, their interfaces, original
terminfo C stub and ncurses. It decodes emitted SGR foreground sequences and
checks their RGB contrast against all 53 shipped TOML palettes, at truecolor,
ANSI256, ANSI16 and unknown capability: **212 observations**. It also checks
the disabled-colours branch and missing palette for each case. A separate
process with `NO_COLOR=1 MASC_TUI_FORCE_COLOR=0` asserts the actual startup
policy and production `recede` token (`no-color-env.txt`). This is not an
actual NO_COLOR TUI screen observation. `receipt.json` binds the exact
source files by SHA-256; no substitute colour implementation is linked.

| Palette | Previous truecolor RGB ratio | Candidate truecolor RGB ratio | Candidate ANSI256 |
| --- | ---: | ---: | --- |
| Solarized Dark | 3.005464669 | 4.552146269 | default foreground, 5.614162720 |
| Solarized Light | 3.027556692 | 4.503465608 | projected foreground, 4.867990331 |

The previous values are from the earlier source-RGB audit at
`afd3b7e02fb39d2b5764f6f39f17263bba682b7a`, not an installed-screen capture.
The candidate values come from this native probe. All overridden foregrounds
clear 4.5:1; minimum observed **4.500599145**. Across the 212 cases, 119 use the
default-foreground fallback. None of these 53 palettes has a default foreground
below 4.5:1. Seven changed OCaml source/interface files were syntax-parsed;
the three colour modules
were also type-checked by the native probe compilation. The complete renderer
was not locally built.

Run `bash docs/evidence/2026-10-23-tui-semantic-readability/run.sh` from this
checkout to rebuild only the standalone colour probe. OCaml 5.5 and ncurses are
required. This is not a project/Dune build. Generated output stays in a fresh
private temporary directory. `themes.tsv` and `results.tsv` are the recorded
inputs/observations; the runner regenerates inputs from the selected checkout.

## Remaining observations

A separate exact-source macOS TUI artifact is required before exercising a
candidate. Inspect dark/light/NO_COLOR, narrow width, keyboard focus, selection,
compact/results/full tools and theme changes after emphasized text/links in a
private terminal. These are manual observations, not wording/layout snapshot
assertions. Source inspection found box helpers use whitespace and a seven-item
main navigation family strip; it did not prove every visible screen is clear.
Internal approval labels and broader screen semantics remain outside this
bounded contrast/presentation change.

Dashboard artifact remains disabled. No installed binary/assets were replaced;
no live server restart was performed. Source, CI, artifact, visible UI and
installed-runtime claims must remain separate.

## Native build follow-up

[Run 39900708827](https://github.com/jeong-sik/masc/actions/runs/39900708827)
at source `365b78c22cea4141ae3413c88d21bdfee0bd2da8` completed source/configuration
checks, then failed to compile the TUI: removing the old summary parser also
removed `is_tool`, while one ambient-background condition still referred to it.
`native-build-failure.txt` retains the diagnostic. The behavior suites and
candidate packaging were skipped; no usable native TUI was established.

Repair `bf1f7c48d2fcbfee151abe1cbd949d43ad32102f` removes the redundant
`not is_tool` condition. `Chat_theme.body_context` enables ambient background
only for User rows with a known background; every Tool row already has it
disabled. The remaining condition preserves that typed decision. Syntax and
whitespace checks passed; independent source review checked that exact repair
against `73028e4450921a3f130b7297d013c907df2e7f49`. Earlier source review missed
the undefined reference and must not be treated as compile evidence.

The colour-module observations above remain separate. A new native candidate
build and manual screen observations are still required after this repair.
