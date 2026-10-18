# Official alphaTex terminal score view

Observed on macOS arm64, 2026-10-18. This record covers the companion and source
integration; it does not claim a rebuilt or installed MASC TUI or a Ghostty
screen capture.

- `pnpm --dir tools/alphatex test`: 23/23 passed. The official examples cover
  bass metadata, multi-track/grand staff, grace notes, tuplets, repeats,
  percussion, multiple voices, bends, slurs, numbered notation, slash notation
  and chord diagrams. Checks exercise PNG generation and audible finite PCM,
  not an exhaustive visual comparison with every notation in the language.
- The original failure has two causes: MASC's ASCII subset refuses official
  `\instrument 34`; the screenshot's `\staff {score tab}` is also rejected by
  official alphaTab. The latter uses `tabs`, with AT205 and source coordinates.
- `scripts/install-alphatex.sh --prefix /private/tmp/masc-score-install-20261018/bin`:
  locked package installation succeeded, installed launcher printed help,
  and the installed viewer launched independently of the source worktree.
- Separate PTY, 150 columns by 45 rows, cell geometry 8 by 16: installed viewer
  emitted PNG graphics, handled source/zoom/stop/exit input, and exited 0 with
  image deletion, cursor restoration and alternate-screen exit bytes.
- With access to the audio device, Space created a 12-second WAV and started
  `afplay .../masc-score-.../1.wav`, observed as an actual running process.
  Direct `afplay` of the exported WAV also exited 0. This establishes player
  execution, not that the operator heard the expected sound.
- Generated output was opened and visually inspected as a PNG: Korean title,
  clef/signature, four measures, rests/dots and four-string tablature. This is
  [the generated image](bass.png), not a terminal screenshot.
- Independent agent source review identified diagnostics being discarded,
  uncancelled synthesis and queued obsolete renders. These were repaired:
  official diagnostics remain readable, synthesis cancellation is checked
  between chunks and removes partial files, and rendering coalesces requests.
- OCaml parser-only checks and `git diff --check` passed. No local Dune build
  or OCaml behavior test was run, following the execution protocol.

Remaining verification: exact-head TUI compilation, actual `/score` invocation
inside the newly built TUI, and visible terminal fidelity/return. Playback has
no synchronized cursor; the interactive full score requires Kitty graphics
and measured cell geometry. Ordinary review does not imply release approval.
