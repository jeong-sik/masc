# Keeper layout: first implementation and rendered audit

## 공통 헤더

- 날짜(ISO8601): 2026-10-02T06:43:33Z
- 작성자: Codex
- 결정 ID: tui-layout-identity-20261002
- 적용 대상: native MASC TUI, base 6458f92ef3d407bd9bacfbfcf25548c06fb0be27
- 결정 상태: 추적 필요

The full user request is tracked in [#40806](https://github.com/jeong-sik/masc/issues/40806). This patch addresses the Keeper header and conversation sidebar. It does not complete the small Mosaic icon work.

## Changes

- Info groups Identity, Current Work and Live Context beside the portrait, using one label column and the available width. Failure, Board attention and Gate remain full-width operational sections below it. Candle diagnostics follow operational facts instead of preceding current work.
- Chat shows its actual conversation owner above the selectable roster. Moving the roster cursor does not change this owner. The frame encloses the selection list; the current-owner header is a separate read-only region.
- Negotiated pixel portraits take four rows, with width derived from reported terminal cell dimensions. Items keeps the larger outfit preview. Mosaic retains 24×12 cells because the tested 16-cell full portrait loses equipped facial details; improving that icon is still required.
- Short screens return portrait space to navigation; narrow screens collapse the roster. No-color uses text identity.

## 근거 (Evidence)

- 항목: grouping, alignment, portrait sizing and context boundaries
- 출처: actual native binary through isolated fixture PTY/ttyd; commands below and adjacent manifests/logs
- 확인일시: 2026-10-02T06:43:33Z
- 신뢰도: High for the recorded fixtures; source review for unexercised states
- 제한조건: synthetic Keeper/Board/usage/workspace data; unavailable fixture endpoints return HTTP 503. No provider calls, production runtime or installed terminal session was used.

Each capture includes text, PNG, actual terminal dimensions and hashes. `main-before-32` runs a native binary built with all changed native sources restored to the exact base. `after-32` runs the candidate including `candidate-source.patch`; its embedded build commit is still the base because it was built from an uncommitted worktree. Do not describe it as a clean exact-head or installed binary.

| Bundle | Measured geometry | Captures | Binary SHA-256 |
|---|---|---:|---|
| [main-before-32](main-before-32/manifest.json) | 80×32, 120×32, 240×32 | 30 | bc8f1aa0d6a2d29add31d98be53252f0e52e220d5ceebfd8dbef29b9560a3283 |
| [after-32](after-32/manifest.json) | 80×32, 120×32, 240×32 | 30 | a44bade474be0f27c8af7c8d7985be02beafb316ab1677edcbfdc6d5a48f80ae |
| [after-24](after-24/manifest.json) | 80×24, 120×24, 240×24 | 30 | 567ef440d5cf672d26fc4c2393592548668acc24720ba7c965e4dc3ead4ac79f |

The 24-row candidate precedes comment-only native changes; its separate binary hash is retained. The screenshot matrix covers Dashboard, Work, Keepers, Keeper Info, Keeper Chat, Usage Plan, Board list/read, Workspace list and System runtime-config error view. It does not prove every sub-tab, overlay or production journey.

Before/after: [Info before](main-before-32/keeper-info-80.png), [Info after](after-32/keeper-info-80.png), [Chat before](main-before-32/keeper-chat-120.png), [Chat after](after-32/keeper-chat-120.png). [Short Info](after-24/keeper-info-80.png) keeps task/context/failure visible without a mosaic.

## 검증 (Verification)

- 1차: independent advisory source review found a non-2:1 cell geometry bug; fixed and re-reviewed. Final grouping/placement delta had no P0/P1/P2 findings. This is not a GitHub approval.
- 2차: focused build of native TUI and portrait test executables passed with the repo wrapper and process-local opam switch 5.5.1 environment.
- 3차: [chat PTY](logs/chat-pty.log) passed six scenarios; [Info/Items and metadata PTY](logs/info-focused-pty.log) passed mosaic/pixels/no-color, outfit preview and long fields through scrolling.
- 재현 결과: chat unit 5/5; Ruff passed all three modified Python files. Chat Python type check passed. Existing capture type diagnostics remain 6/6 against its unchanged source; existing Item PTY type diagnostics remain 39/39. No new type diagnostic was introduced by the layout diff.

Commands:
```sh
eval "$(opam env --switch=5.5.1 --set-switch)"
bash scripts/dune-local.sh build test/test_tui_chat_portrait.exe test/test_tui_keeper_portrait.exe bin/masc_tui.exe
_build/default/test/test_tui_chat_portrait.exe
python3 test/test_tui_chat_portrait_pty.py _build/default/bin/masc_tui.exe
python3 test/test_tui_keeper_metadata_wrap_pty.py _build/default/bin/masc_tui.exe
python3 scripts/capture-tui-audit.py _build/default/bin/masc_tui.exe --rows 24 --out <bundle> --provenance candidate_worktree_binary_fixture_PTY
python3 scripts/capture-tui-audit.py _build/default/bin/masc_tui.exe --rows 32 --out <bundle> --provenance candidate_worktree_binary_fixture_PTY
```

## 불확실성 (Uncertainty)

- 미확인 항목: every sub-tab/overlay, real terminal graphics screenshot, installed/production behavior, small readable Mosaic face icon, global-versus-per-Keeper placement beyond this patch.
- 영향: this is a first layout patch, not full-goal completion or release proof.
- 추가 확인 필요: render a compact face icon with readable identity/equipment, preserve Items as a full preview, then continue whole-surface audit. Validate the eventual committed head and obtain repository review before integration.

Existing failures are retained rather than described as passing: [unchanged-source portrait unit](logs/baseline-unit.log) fails two Mosaic equipment distinctions, also reproduced on candidate; see [#39827](https://github.com/jeong-sik/masc/issues/39827). [Item roster authority](logs/baseline-item-authority.log) fails before and after the layout patch; tracked separately in [#40803](https://github.com/jeong-sik/masc/issues/40803). The entire Item suite is not green.

## 적용범위 (Scope)

- 영향 받는 영역: Info header, chat owner/roster allocation, pixel portrait budget and capture fixture/geometry.
- 제약/배제: runtime/Item authority, provider orchestration, deployment and release.
- 롤백 조건: a real render hides owner/task/failure or places pixels over text; fix the rendering delta before integration.
