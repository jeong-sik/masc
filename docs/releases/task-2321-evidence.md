# task-2321 실행 영수증

실행: bash scripts/release/run-guideless-check.sh /tmp/guideless-check-v3
날짜: 2026-10-23T01:46:12Z
브랜치: polish/task-2321-guideless-counter
커밋: 796344f2deaed4e7bb37ad80589a8fc380d11fae

```
== scenario A (old note, no markers) ==
{
  "tag": "v0.51.0",
  "added_total": 2,
  "guideless_total": 0,
  "guideless_items": []
}
== scenario B (new note, 2 markers) ==
{
  "tag": "v0.52.0",
  "added_total": 3,
  "guideless_total": 2,
  "guideless_items": [
    "BiDi host cgroup default (#42250). 가이드 없음(대상 문서: docs/design/browser-bidi-live-host.md)",
    "Stability fix for 4.0.7 hosts (#42186). 가이드 없음(문서 없음)"
  ]
}
== scenario C (English marker, 2 guideless) ==
{
  "tag": "v0.54.0",
  "added_total": 3,
  "guideless_total": 2,
  "guideless_items": [
    "An English-spelled guideless entry (#42902). No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md)",
    "Another English guideless (#42903). No guide yet (…)"
  ]
}
== scenario R (real v0.54.0 CHANGELOG extract, AC1) ==
{
  "tag": "v0.54.0",
  "added_total": 17,
  "guideless_total": 9,
  "guideless_items": [
    "Experimental: Board post attachments accept the kinds `file`, `audio`, `score` and `midi` and an optional `name`; the dashboard reads them and offers a stored one as a download No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42766).",
    "Experimental: `POST /api/v1/artifacts` stores an uploaded file of up to 32 MiB in the artifact store and returns its sha256 and size No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42767).",
    "Experimental: The TUI board read pane lists a post's attachments by kind, name and size No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42769).",
    "Experimental: TUI board compose attaches local files with Ctrl-A and uploads them when the post is sent; a path that is not a regular file, or a file over the artifact store's 32 MiB limit, is refused before it is read No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42775).",
    "Experimental: The TUI highlights `alphatex` code blocks No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42777).",
    "Experimental: The TUI draws an `alphatex` code block as guitar tablature, breaking at bar lines to fit the pane; a score it cannot draw shows its source with the reason No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42779).",
    "Experimental: The TUI alphaTex reader takes repeat signs: `\\ro` opens a repeat, `\\rc N` closes it with the count of total plays, and `\\ae n …` names the ending passes a bar plays on No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42858).",
    "Experimental: The ending list also reads alphaTab own parenthesized form, \\ae (1 2 3), which is the form the writer emits, so a shared tab round-trips instead of failing the reader No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42858).",
    "Experimental: The TUI guitar tab draws repeat signs: a bar an `\\ro` opened starts past `|:`, one an `\\rc N` closed ends in `:|xN` with the count of total plays, and `\\ae` numbers ride the left barline No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42859)."
  ]
}
== summary ==
scenario A: 2 added, 0 guideless
scenario B: 3 added, 2 guideless
scenario C: 3 added, 2 guideless
scenario R: 17 added, 9 guideless (real v0.54.0 CHANGELOG)
PASS: --expect-* assertions all held
```
