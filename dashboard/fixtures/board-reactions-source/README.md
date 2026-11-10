# Reaction source browser fixture

From `dashboard/`, run `pnpm exec vite --config fixtures/board-reactions-source/vite.config.mjs` and open the printed loopback URL. Use `?case=unknown` for a failed batch and fallback read, or `?case=known` for an initially selected reaction whose toggle returns a synthetic 503.

The fixture replaces all window fetches before importing the real BoardSurface. Unexpected requests fail locally. It sends no live Board write. A cached empty list deliberately accompanies a known catalog, so a failed fresh batch must still revoke authority.

After the known case's failed toggle, “다시 확인” first fails a read. To simulate source recovery, set `window.fixtureControl.readAvailable = true`, `window.fixtureControl.count = 2`, and `window.fixtureControl.reacted = false` in page code, then click “다시 확인”. The displayed count must update through the real read path; the POST count in `window.fixtureCalls` remains one. This simulation changes HTTP fixture state, not the component's state or DOM.

Write new captures under `artifacts/dashboard/`; retained captures and their source identities are in `docs/evidence/2026-11-10-board-reactions-source/`.

For `?case=ordering`, the feed starts with two rows and known unselected reactions.
Click the first row's reaction to start a held POST, set `fixtureControl.holdBatches = true`,
then use the visible body filter with `조회가` to draw just that row and start a held batch GET.
Call `fixtureControl.releaseWrite()` to complete the POST; its resulting count is one/selected.
After the actual post-write GET confirms it, call `fixtureControl.releaseBatches()` to return the
captured pre-write batch. The first row must keep count one/selected with one POST total.
These controls release synthetic HTTP responses; they do not change component state or DOM.
