# Integrated vote and reaction sources

This is a new run after the actual vote stack (#50918/#50919) reached main `fdde0336`. The original parent-directory captures and manifest are retained unchanged. This run is bound to upper `aa9e06339e79a2d6e51af2564b0e7245885f786d` and lower `039c2fdb5f034133bde3af2d53cfd2ccf925be76` in [manifest.json](manifest.json).

The whole Native Stack rebase resolved both typed source owners together: five immutable source IO slots, 37 matching store fields, both public reloads, and both own-source gates for sweep/deletion/flush. Fixtures load actual vote and reaction files, including the incoming vote fault store whose deletion must reach its real fault. No mutable admission flags were restored.

The actual [browser fixture](../../../../dashboard/fixtures/board-reactions-source/README.md) was rerun in task space 60, page p1. An initial cold-import wait expired before any write; observing the same page showed ready=true, no fixture failures, and only GETs. The run resumed on that page and completed with exit 0.

- [Unknown](unknown.png), [record](unknown.json): disabled reaction buttons, omitted aria-pressed, mouse click POST 0. The separately unavailable vote state also stays unavailable.
- [Failed write](failed-write.png), [record](failed-write.json): one POST, last count retained, controls disabled, visible error and readable footer actions.
- [Failed read retry](failed-read.json): GET only, controls stay disabled, total POST 1.
- [Successful read retry](recovered.png), [record](recovered.json): fresh count 2, enabled/unselected reaction controls, total POST 1. The independent unknown vote controls stay disabled.

All three PNGs were opened and visually inspected by the root. This measures actual source components against synthetic HTTP; it sends no live Board write and is not a backend durability or deployment check.

[Frontend checks](frontend-checks.json): 218/218 tests across the five named files, whole-Dashboard TypeScript check and targeted ESLint exit 0. [Source parsing](source-parsing.json): 34 OCaml files parsed with 5.5.1 against repository target 5.5.2, 37 store field names/order match, whitespace check exit 0. Parsing is not typing or warning checking. Seven new reaction backend cases remain authored and unexecuted.

Issue #26378 stays open for durable multi-source deletion/restart recovery and parent/policy readsets. No Dune, backend run, CI, installation or deployment result is claimed.
