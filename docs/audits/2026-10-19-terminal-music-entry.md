# Terminal music entry and library continuation

Issue #43890; Native Stack #43894 contains PRs #43892 and #43893. Its destination
is `feat/music-phrase-vst-picker`, the top of the separate VST phrase stack.
It is not an assertion that these features have reached main.

## Entry and ownership

Dashboard `s` opens music without choosing a Keeper. Chat `/music` opens the
same workbench. Unlike `/score`, this entry has no graphics or score-fence
prerequisite. MASC derives project and take roots from the current local base:
`<base-path>/.masc/music/projects` and `<base-path>/.masc/music/sessions`.
It passes those paths as executable arguments, never shell text.

The workbench owns asynchronous, independent project and take directory reads.
Missing roots are empty libraries; other source failures remain visible alongside
available entries. Explicit refresh retires the previous read. Applying a result
preserves the selection as it stands at response time, including movement while
loading. A source read does not parse all project contents or take manifests.
The selected editor validates its own document.

One child view owns input and its draft at a time. `q` returns from that editor
to a refreshed library. Workbench close aborts the child and outstanding reads,
then waits for their actual completion before restoring its caller's terminal.
New phrases, arrangements and recordings use existing editors. Saved project,
MIDI-source and take paths can also be entered explicitly.

The MASC terminal handoff is shared with the score viewer. It restores the
terminal on child success, nonzero exit and partial handoff failure. Score entry
checks the currently observed graphics capability and cell dimensions.

## Focused executed checks

At functional source head `75664a7a05351683877616643f9706068ee1f31f`:

```sh
cd tools/alphatex
node --test test/music-workbench.test.mjs test/sequencer-close.test.mjs \
  test/arrangement-close.test.mjs
```

18 tests passed, none failed or skipped. They inspect actual library paths and
partial failures, saved project continuation, exact child options, one-child
ownership, cancellation/cleanup, read supersession and selection movement.
Existing phrase and arrangement close checks remained in this focused set.

The new `test/test_tui_music_launcher.ml` was also compiled and executed with
the actual command and launcher modules using `ocamlfind ocamlc`, in an isolated
temporary directory. Four checks passed: literal child argv and exit outcomes,
missing-helper ownership, restoration after partial handoff failure, and typed
local-command parsing (including refusal of extra or multiline input).
The compiler enabled warnings 4, 32 and 69 with warnings treated as errors.
This was a small standalone check, not a Dune or full MASC build.
The main loop, key catalog and feature catalog passed OCaml syntax parsing only;
that does not establish their complete consumer typecheck.

## Actual terminal observation

An isolated tmux terminal directly ran `node tools/alphatex/viewer.mjs --music`
at `ce9ce139cbb928e834041f69f6ec0042d2cb2183`, with separate library and VST-state
directories. It needed no graphics query response. Enter opened a new phrase;
Enter inserted C4; `q` saved it and returned to the library. The new JSON project
appeared in that library. Reopening retained the note, and a title edit survived
another save and return. `i` opened the real installed VST instrument catalog
from that phrase. The saved project retained one note and the title
`Continued from the music library` after exit. Captures and the saved project are
retained with the local audition artifact. No screen-text/layout assertion test
was added.

The prior source review found a P2 in selection restoration during a delayed
refresh. A response agent reproduced it and corrected response-time selection;
the reviewer then reported source PASS for lower head
`03e5a18f0d930c1d242ee9b8bf34a70195845239`.

## Remaining evidence

Direct JavaScript execution proves the companion path, not the changed MASC
Dashboard or chat entry. A native TUI artifact and an actual MASC terminal
round-trip are still required for that claim. Source review, focused checks,
installation, GitHub approval, CI and merge remain separate evidence stages.
The broader rich music and nonmusic TUI objective remains unfinished.
