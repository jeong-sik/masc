# TUI layout requirement audit

## 공통 헤더

- 날짜(ISO8601): 2026-10-02T08:10:58.698276+00:00
- 작성자: Codex
- 결정 ID: tui-layout-requirements-20261002
- 적용 대상: native implementation309cae280bd14bc390454781e8f2adb0164b13f8, PRs #40810 / #40814 / #40821
- 결정 상태: 추적 필요

The user requested contextual regrouping, small supporting portraits, a better chat sidebar/portrait position, aligned rows/columns, and meaningful borders/dividers. This audit covers those layout requirements in the implemented candidate; integration and production deployment remain separate.

## 근거 (Evidence)

- 항목: user-requested layout behavior in the combined native candidate
- 출처: final-32/manifest.json, panes-24/manifest.json, native-source-binding.json; earlier layout/face/currency evidence bundles
- 확인일시: 2026-10-02T08:10:58.698276+00:00
- 신뢰도: High within recorded synthetic terminal fixtures
- 제한조건: native fixture PTY rendered by xterm/Chromium; no installed or production observation

Native binary SHA-256 `68b82214a337203b4b41ca014bbb36e1a3f26ff2abd2a33bf4908369cb16b987` embeds implementation commit309cae. The committed bin/lib tree IDs match the final candidate, with no uncommitted native delta. The final capture helpers are explicitly hashed in each manifest. They are evidence tooling changes, not product rendering changes. Older screenshots retain their overlay provenance; these final captures bind the combined committed native implementation.

| Requirement | Implementation and direct evidence |
| --- | --- |
| Information belongs to its current object | Info groups Identity, Current Work and Live Context beside the selected Keeper icon; Failure/Board/Gate remain below. Personal balance stays in Info; workspace supply/status lives in Usage; technical pressure stays in Telemetry. final-32/keeper-info-* and usage-*, currency committed-head-scope-pty.txt. |
| Supporting portraits are small icons | Info/chat use face-centred 16×8 Mosaic cells or four negotiated pixel rows. Items retains the full outfit preview. Face evidence Info/NO_COLOR/Kitty/full Items PTY plus portrait unit11/11; final Info/chat images. |
| Chat lower-left portrait/sidebar is improved | Conversation owner's icon and name sit above a framed selectable roster. Changing the roster cursor does not change the open chat owner. Composer and content keep their space. Chat PTY6 scenarios and unit5/5; final-32/keeper-chat-*. |
| Rows/columns align | Info uses one label width and computes adjacent text width from the icon band. Chat icon width follows negotiated cell geometry. Native captures at80/120/240 columns,24/32 rows; earlier long metadata and no-color/pixel PTY; Code memo full author/body/physical scroll PTY. |
| Borders/dividers express context | Chat roster frame separates selection from owner; Info headings and spacing separate identity/live facts from evidence; Usage divider separates workspace economics from Keeper usage. Code/Resources/Fusion retain a list boundary when split and drop redundant outer frames when narrow. panes-24 shows each at80/120/240 columns, including Fusion question and recorded evidence. Board detail captures preserve post/comment boundary and full comment width. |

The main matrix includes Dashboard, Work, Keepers, Info, Chat, Usage, Board, Workspace, System and Board detail. The supplementary matrix includes Resources, Code, Fusion overview and its recorded-evidence end, all at actual24 rows. Screens were read visually as well as hash-checked; readiness requires distinctive fixture content rather than only a navigation title.

## 검증 (Verification)

- 1차: focused native build and personal/workspace scope PTY pass on committed309cae.
- 2차: portrait unit11/11, chat unit5/5, chat PTY6, Resources PTY and Code memo layout PTY pass. No-color/Kitty/outfit-specific proof remains in the face unit bundle.
- 3차: independent source review found no P0/P1/P2 in each product unit and the final capture-helper delta. This is advisory source review, not repository approval.
- 재현 결과: parent fails the new information-ownership regression; candidate passes. Captured Code/Resources/Fusion show narrow single-content views and wide split boundaries. Ruff passes both helpers; Pyright six diagnostics match the unchanged baseline. Diff whitespace check passes.

Capture tool changes add an explicit pane matrix and preserve selected Code directory across width changes. Fusion uses separate Home/question and End/evidence captures. Startup output is spooled to a temporary file rather than left in an unread pipe, and failures print launch diagnostics. Earlier incomplete attempts are superseded by complete manifests; no timeout was reinterpreted as a pass.

## 불확실성 (Uncertainty)

- 미확인 항목: merged/installed/production behavior, repository approval and release readiness
- 영향: this is a completed implementation/layout validation candidate, not a deployed release
- 추가 확인 필요: maintain independent review and integration workflow for the Draft stack

Known unrelated failures remain explicit: Item account/unread authority #40803; full currency ready-to-booting Help withdrawal and Home populated approval fixture timeout reproduce on parents (#40598). They are not suppressed or counted as green. The Usage screenshot deliberately shows an unavailable Keeper usage fixture; it proves layout/status wrapping, not populated metrics. The user did not request a runtime-authority repair or deployment.

## 적용범위 (Scope)

- 영향 받는 영역: TUI layout, portrait presentation, capture tooling and reviewable evidence
- 제약/배제: runtime/account semantics, all-product full-suite or production certification
- 롤백 조건: loss of owner distinction, unreadable icon or a misplaced context boundary; repair before integration
