# Face icons for Keeper identity

## 공통 헤더

- 날짜(ISO8601): 2026-10-02T07:07:44Z
- 작성자: Codex
- 결정 ID: tui-face-icons-20261002
- 적용 대상: native TUI, parent d9fac602750b971b78681152cd6884eb046f6b6d / PR #40810
- 결정 상태: 추적 필요

Info/chat now use a face-centred identity thumbnail: 16×8 Mosaic cells or four negotiated pixel rows. This reduces the previous 24×12 Mosaic band while enlarging the face inside it. Peripheral outfit pieces are cropped in the icon; Items retains the unchanged full outfit preview. Full, compact and icon cache entries have distinct typed identities. Name, observed equipment and image size remain part of each cache key.

## 근거 (Evidence)

- 항목: smaller readable faces, distinct preview cache, unchanged navigation/composer and outfit inspection
- 출처: repo wrapper build, native unit/PTY commands below, [capture manifest](face-32/manifest.json)
- 확인일시: 2026-10-02T07:07:44Z
- 신뢰도: High for recorded synthetic fixtures
- 제한조건: isolated fixture PTY/browser; no installed or production session was used

The [source overlay](candidate-source.patch) was built over the parent while uncommitted. Captured binary SHA-256: `4477c19ba87390dc2fc12c6586c952472c81ee462b2c3cc9339c4becd3acbdec`. Its embedded build commit is the parent, not the eventual PR head. The executable was copied to a fixed temporary path before capture. `face-32/manifest.json` reports complete and binds all 30 PNG/text capture pairs, actual 80/120/240×32 geometry, fixture hash and script hashes. The earlier `preview` attempt was invalidated because its executable changed during capture; it is excluded from this evidence.

[Chat icon](face-32/keeper-chat-120.png), [Info icon](face-32/keeper-info-80.png).

## 검증 (Verification)

- 1차: independent source reviewer found no P0/P1/P2; stale API comment corrected. This is advisory source review, not GitHub approval.
- 2차: focused native TUI and portrait test builds passed. Ruff passed both modified Python helpers; chat helper Pyright passed.
- 3차: [portrait unit 11/11](checks/portrait-unit.txt), [chat PTY six scenarios](checks/chat-pty.txt), [Info/NO_COLOR/Kitty/full Items preview PTY](checks/info-pty.txt) passed.
- 재현 결과: facial gear changes both image bytes and rendered Mosaic cells; repeated gear/identity reuses its cache; icon and full preview pixels remain distinct. Chat owner stays independent from roster cursor. Active turn redraws restore the picture without retransmitting unchanged pixels.

Commands:
```sh
eval "$(opam env --switch=5.5.1 --set-switch)"
bash scripts/dune-local.sh build bin/masc_tui.exe test/test_tui_keeper_portrait.exe test/test_tui_chat_portrait.exe
MASC_TUI_FORCE_COLOR=1 _build/default/test/test_tui_keeper_portrait.exe
_build/default/test/test_tui_chat_portrait.exe
python3 test/test_tui_chat_portrait_pty.py _build/default/bin/masc_tui.exe
python3 scripts/capture-tui-audit.py <copied-native-binary> --rows 32 --out <bundle> --provenance worktree_face_icon_fixture_PTY
```

The earlier parent record's two color-distinction unit failures came from the invoking process's `NO_COLOR` environment: SGR colors were removed even though the test supplied a true-color projection. The portrait test action now explicitly sets the existing `MASC_TUI_FORCE_COLOR=1` fixture. No-color product behavior remains separately checked in PTY. These assertions were retained, not suppressed. Full outfit preview still tests glasses versus shades.

Info icon tests now assert visible facial equipment; peripheral full-outfit visibility belongs to Items' retained preview, matching the new user-facing presentation. A face icon is not a complete outfit preview.

## 불확실성 (Uncertainty)

- 미확인 항목: installed/production behavior, real terminal screenshot, every sub-tab/overlay and the remaining global/per-Keeper information-ownership audit
- 영향: full user goal #40806 remains active; these fixtures do not prove release readiness or whole-product completion
- 추가 확인 필요: finish contextual regrouping and broader boundary audit, bind final committed head evidence, obtain independent repository approval before integration

## 적용범위 (Scope)

- 영향 받는 영역: portrait face framing, Info/chat band budget and cache, portrait visual checks
- 제약/배제: runtime/Item account authority, deployment, provider configuration
- 롤백 조건: icon hides owner/facial distinctions or contaminates outfit preview; repair before integration
