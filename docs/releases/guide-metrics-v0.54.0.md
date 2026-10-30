# Guide coverage — v0.54.0

- Added 항목: 17
- 가이드 없음 표기: 9

이 노트는 영어 표기 `"No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md)"` 를 썼습니다. 앞으로는 한국어 표기 `가이드 없음(대상 문서: ...)` / `가이드 없음(문서 없음)` 하나로 통일합니다 (계수기는 둘 다 인식).

- Experimental: Board post attachments accept the kinds `file`, `audio`, `score` and `midi` and an optional `name`; the dashboard reads them and offers a stored one as a download No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42766).
- Experimental: `POST /api/v1/artifacts` stores an uploaded file of up to 32 MiB in the artifact store and returns its sha256 and size No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42767).
- Experimental: The TUI board read pane lists a post's attachments by kind, name and size No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42769).
- Experimental: TUI board compose attaches local files with Ctrl-A and uploads them when the post is sent; a path that is not a regular file, or a file over the artifact store's 32 MiB limit, is refused before it is read No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42775).
- Experimental: The TUI highlights `alphatex` code blocks No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42777).
- Experimental: The TUI draws an `alphatex` code block as guitar tablature, breaking at bar lines to fit the pane; a score it cannot draw shows its source with the reason No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42779).
- Experimental: The TUI alphaTex reader takes repeat signs: `\ro` opens a repeat, `\rc N` closes it with the count of total plays, and `\ae n …` names the ending passes a bar plays on No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42858).
- Experimental: The ending list also reads alphaTab own parenthesized form, \ae (1 2 3), which is the form the writer emits, so a shared tab round-trips instead of failing the reader No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42858).
- Experimental: The TUI guitar tab draws repeat signs: a bar an `\ro` opened starts past `|:`, one an `\rc N` closed ends in `:|xN` with the count of total plays, and `\ae` numbers ride the left barline No guide yet (none found in docs/guides, TUI-GUIDE.md or KEEPER-USER-MANUAL.md) (#42859).

측정: scripts/release/count-guideless-added.py
규칙: changelog.d Added 항목의 사용 가이드 1장 (규약 제안 #1)
