# Browser form control observation

## 공통 헤더

- 날짜(ISO8601): 2026-09-30T13:34:00+09:00
- 작성자: Codex
- 결정 ID: browser-form-controls-40153
- 적용 대상: browser_scene_script.ml, browser_page_script.ml, browser_interaction.ml and the matching live extension scripts
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: Native radio/checkbox labels and declared ARIA form/menu controls need actionable observations, including current selection and disability.
- 출처: https://html.spec.whatwg.org/multipage/forms.html#the-label-element ; https://www.w3.org/TR/wai-aria/#radio
- 확인일시: 2026-09-30T13:34:00+09:00
- 신뢰도: High
- 제한조건: The live finance app failure motivated this fixture; its private DOM was not exported and the revised scripts were not deployed there.

## 검증 (Verification)

- 1차: WHATWG label activation and WAI-ARIA role/state contracts read directly.
- 2차: Node syntax check and shared native/extension script parity tests pass. Chromium 147.0.7727.15 executes the worktree scripts against test/fixtures/browser-form-controls.html.
- 3차: proof.json records 22 checks, including the base script missing the labelled radio and ARIA menu, label activation, selected states, disabled pre-effect refusal, and ordinary textarea preservation. form-controls.json contains scene/elements observations; form-controls.png shows the resulting fixture.
- 재현 결과: All 22 fixture checks pass. Existing Node elements/navigation tests pass (18 cases), interaction dispatch assertions pass, and scene resource/parity assertions pass. Ruff reports 103 existing findings and Pyright reports 4 existing errors on both base and modified test_browser_scene.py; the added lines introduce none. No local Dune build was run.

## 불확실성 (Uncertainty)

- 미확인 항목: Current-head PR compile checks and the real Gecko probe are pending at initial publication. General MCP screenshot ownership and SPA settling remain separate work under #40153.
- 영향: Fixture behavior does not prove that the private app uses these declared semantics, or that a deployed MASC binary has this patch.
- 추가 확인 필요: Browser Host Proof runs the expanded Gecko scene probe. CI and review must be complete before any merge/deployment claim.

## 적용범위 (Scope)

- 영향 받는 영역: Live Firefox extension and WebDriver shared scene/elements/interaction scripts; browser-lanes observation guidance.
- 제약/배제: No site-name, CSS-class, cursor, or text matching is used to infer a control. Framework controls without declared semantics still need a supported visual path. No finance registration or submission was performed during this code task.
- 롤백 조건: Revert the patch if browser proof finds incorrect activation or loss of observed controls. Existing document/node identity and URL guards remain in force.
