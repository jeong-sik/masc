# Board reaction source: browser and source evidence

The actual BoardSurface now keeps unavailable reaction state distinct from an empty result. A failed newer batch revokes authority even when the cached post carried an empty list and known emoji catalog. A failed toggle keeps the last counts for display and offers a read-only retry.

The final run used real Chromium in task space 60, page p1, the versioned isolated [fixture](../../../dashboard/fixtures/board-reactions-source/README.md), and synthetic HTTP. Every application fetch is intercepted locally. No live Board write was sent.

- [Unavailable source](unknown.png), [record](unknown.json): both emoji controls are disabled, omit aria-pressed, and avoid a known-empty label. An actual mouse click sends no POST.
- [Failed toggle](failed-write.png), [record](failed-write.json): one POST fails; count 1 remains as the last observation and both controls lose mutation authority. The footer wraps so pin/delete remain readable.
- [Failed read retry](failed-read.json): controls stay disabled and the POST count remains one.
- [Recovered read](recovered.png), [record](recovered.json): a successful GET supplies count 2 and unselected state; controls become enabled without replaying the POST.

The root opened all three final PNGs and visually checked them. The earlier capture exposed pin/delete labels squeezed into vertical text; moving the existing footer wrap rule to all viewport sizes fixes that observed layout. The final captures retain the error message and readable controls.

[manifest.json](manifest.json) preserves the exact capture source pins, source-file and capture hashes, and observation bounds. Its `dashboard_source_tree` identifies `dashboard/src`. Those pins are historical capture identities; later delivery commits must be compared to these bytes, not substituted into this manifest. The [parsing receipt](source-parsing.json) belongs to its original upper `657cfe55`; all 33 OCaml input hashes were compared equal at capture. Parsing used OCaml 5.5.1 while the repository targets 5.5.2; it is not typing or backend execution.

[Frontend checks](frontend-checks.json) record 81/81 tests across three files, whole-Dashboard TypeScript checking, and targeted ESLint. Their TS/JS inputs are unchanged in the capture; the subsequent CSS-only layout fix was verified in Chromium. The new fixture is outside tsconfig's include paths.

Seven backend scenarios are authored and unexecuted: stale toggle, stale ordinary compaction, orphan-preserving real compaction, canonical public target spelling after restart, partial source through Dashboard/shared HTTP results, post-rename unknown without replay, and known rewrite before reserved stable-lock cleanup. They use real-file/public-store fixtures; no backend pass is claimed.

This bundle does not establish an OCaml type/warning check, a backend build or run, durable multi-source deletion recovery, CI, installation, or deployment. Issue #26378 remains open for the remaining product work.

The [integrated follow-up run](integrated/README.md) records the later vote-source merge, both-source integration, 218 focused tests, and fresh Chromium captures. The original capture manifest above remains historical.

The [batch ordering follow-up](ordering/README.md) records a subsequently found
P2, its failing baseline and repair, 224 focused tests, and a real feed whose
late pre-toggle batch cannot undo its confirmed selected count. Earlier captures
and their source pins remain historical.
