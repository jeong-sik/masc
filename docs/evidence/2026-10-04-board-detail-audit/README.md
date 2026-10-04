# Board detail field preservation (audit U1)

Product source tested: `49e434b7327adc69f363529d3cd40683a5d6a934`.

Opening a post absent from the feed used to drop normalized attachments, origin,
viewer votes and reactions. The regression test invokes the real HTTP decoder
with a synthetic response and then the real detail loader. Before the fix it
fails because `origin` is undefined. After the fix the three relevant suites pass
175 tests:

```sh
pnpm --dir dashboard test src/components/board/board-state.test.ts src/api/board.test.ts src/components/board/post-detail.test.ts
```

`tests-before.txt` and `tests-after.txt` retain the failure/pass evidence. The
browser used the real `PostDetail`, API decoder, state loader and dashboard CSS
through Vite with the feed empty, intercepting HTTP with the same synthetic
post. `board-browser-result.json` records the normalized post, empty feed and
button state. The attachment link and origin-turn button rendered; the existing
upvote was pressed and the reaction was retained. No JavaScript page errors were
observed. The screenshot is a source-component fixture, not the installed app or
production. No backend, provider, native build or full CI was run for this change.
