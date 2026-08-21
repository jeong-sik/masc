# Keeper Agent v3 / v4 / v5 — design prototype (reference only)

Byte-faithful export of the `keeper-v2/Keeper Agent v*.html` prototypes from the
Claude Design project (https://claude.ai/design/p/6e69560a-2558-4572-9baa-59a7252efc76).
Mock-data standalone SPA: React 18 UMD + Babel standalone, 48 JSX surfaces,
20 CSS files. No build step, no server wiring — it renders entirely from the
hardcoded roster/threads in `data*.jsx`.

## Entry points

All four entry points load the same JSX set and the same base CSS; they differ
only in which tone layer is active (v2 predates the lanes/journey surfaces, so
its script list is shorter):

| File | Root attribute | Tone layer |
|---|---|---|
| `Keeper Agent v2.html` | (none) | base v2 skin, pre-lanes surface set |
| `Keeper Agent v3.html` | (none) | base v2 skin |
| `Keeper Agent v4.html` | `data-tone="instrument"` | `styles/instrument.css` |
| `Keeper Agent v5.html` | `data-tone="tempered"` | `styles/tempered.css` |

`instrument.css` is scoped entirely to `[data-tone="instrument"]` and loads
last, so it cannot affect v3. It restates the skin's tokens (flat surfaces, a
neutral gray ink ladder, one brass accent, mono chrome type) and then walks
parts of that back in two revision passes the file documents inline.

`tempered.css` is the sibling tone to `instrument.css`, not its successor: it
keeps the brass/bone identity and edits three things — the ink ladder is widened
so hierarchy reads at a glance, the brass glow is halved, and status chips lose
their filled grounds so colour survives as text and a pip. The dashboard runs
this tone (`data-tone="tempered"` in `dashboard/index.html`), so of the four
entry points `Keeper Agent v5.html` is the one that matches what ships.

`instrument.css` is exported but not vendored — the dashboard runs one tone.

Purpose: reference material for the real `dashboard/` implementation. The FSM
states, Gate dispositions (Always / LLM Judge / HITL), schedule approval flow,
and Fusion deliberation surfaces here encode design decisions the dashboard
should implement. It is intentionally OUTSIDE `dashboard/src`, so eslint,
tsc, vitest, and the drift ratchet never touch it.

## Run

```
cd dashboard/prototypes/keeper-v2
python3 -m http.server
# open "Keeper Agent v3.html" or "Keeper Agent v4.html"
# deep links: ?surface=schedule, ?keeper=<id>
```

Requires network for the React/Babel CDN scripts and Google Fonts.

## Binary assets (not committed — see .gitignore)

- `styles/fonts/Cinzel-Regular.ttf`: original from the Design project.
- `styles/fonts/NotoSansKR-Regular.ttf`: the Design API caps reads at 256KiB,
  so this is the Google Fonts variable TTF instead:
  `curl -sL -o styles/fonts/NotoSansKR-Regular.ttf "https://github.com/google/fonts/raw/main/ofl/notosanskr/NotoSansKR%5Bwght%5D.ttf"`
- `assets/portraits/*.png` (12 keeper portraits): all exceed the 256KiB read
  cap and are not exported yet. The `Avatar` component falls back to sigil
  badges via `onError`, so the page renders without them.

Note: the mock display strings include `~/.masc` paths, which is why this
directory must stay out of the `check-ssot.sh` R6 scan roots (bin/lib/scripts/docs).
