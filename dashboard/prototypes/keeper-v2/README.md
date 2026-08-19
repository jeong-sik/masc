# Keeper Agent v3 — design prototype (reference only)

Byte-faithful export of the `keeper-v2/Keeper Agent v3.html` prototype from the
Claude Design project (https://claude.ai/design/p/6e69560a-2558-4572-9baa-59a7252efc76).
Mock-data standalone SPA: React 18 UMD + Babel standalone, 48 JSX surfaces,
19 CSS files. No build step, no server wiring — it renders entirely from the
hardcoded roster/threads in `data*.jsx`.

Purpose: reference material for the real `dashboard/` implementation. The FSM
states, Gate dispositions (Always / LLM Judge / HITL), schedule approval flow,
and Fusion deliberation surfaces here encode design decisions the dashboard
should implement. It is intentionally OUTSIDE `dashboard/src`, so eslint,
tsc, vitest, and the drift ratchet never touch it.

## Run

```
cd dashboard/prototypes/keeper-v2
python3 -m http.server
# open "Keeper Agent v3.html"; deep links: ?surface=schedule, ?keeper=<id>
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
