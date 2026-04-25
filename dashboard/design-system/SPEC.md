# MASC Cockpit — Design System Specification

**Status**: canonical (Phase 0)
**Scope**: `dashboard/` (Preact) + `dashboard_bonsai/` (Bonsai/OCaml)
**Audience**: agents, contributors, reviewers adding new tokens or components

---

## 1. Why this exists

masc-mcp 레포는 두 dashboard surface가 같은 서버에서 병존 서빙된다. 같은 design intent를 표현하는데 vocabulary가 분기되어 있어, surface 간 이동 시 색·간격·타이포가 미묘하게 달라진다. 이 spec은 두 surface가 공유하는 canonical vocabulary와 design rule을 정의한다.

| Surface | 경로 | 스타일 시스템 | 테마 |
|---------|------|----------------|------|
| `dashboard/` | `/dashboard/*` | Preact + Tailwind utility + raw CSS | dark / light |
| `dashboard_bonsai/` | `/dashboard/b/*` | Bonsai + ppx_css inline + `colors_and_type.css` | dark-fantasy / cyberpunk / terminal / parchment / paper |

이 spec이 **변경되기 전에 코드가 변경되어선 안 된다.** 새 token, 새 컴포넌트 패턴, 테마 추가는 모두 SPEC PR이 선행해야 한다.

---

## 2. Token taxonomy (3 tier)

| Tier | 이름 패턴 | 역할 | 변경 빈도 | 예시 |
|------|-----------|------|-----------|------|
| **Raw** | `--bg-0`, `--brass-1`, `--ok` | 원시 색·치수값. 테마별 다른 값을 가질 수 있는 가장 낮은 layer. | 테마 추가/조정 시 | `--bg-0: #0c0b08;` |
| **Semantic** | `--color-bg-page`, `--color-status-added` | "페이지 배경", "추가된 라인"처럼 **의도**를 표현. raw에 alias로 매핑되며, 테마 override 시 의미는 유지하고 raw만 바뀐다. | spec 갱신 시 | `--color-bg-page: var(--bg-0);` |
| **Role** | `--type-body`, `--elev-3` | 컴포넌트 사용처. semantic을 조합하여 "본문 텍스트", "elevation 3단계 카드"처럼 컴포넌트 contract을 표현. | 컴포넌트 패턴 추가 시 | `--type-body: var(--fs-14)/var(--lh-body) var(--font-body);` |

**Tier 간 참조 방향**: Role → Semantic → Raw (반대 방향 금지). 컴포넌트 CSS는 가능하면 Role 또는 Semantic만 참조하고, Raw 직접 참조는 Semantic이 표현 못 하는 경우(예: bonsai의 trace frame)에만 escape hatch로 허용한다.

---

## 3. Canonical vocabulary

### 3.1 Surface stack (background)

| Canonical (Semantic) | dashboard raw | bonsai raw | 의미 |
|---------------------|---------------|------------|------|
| `--color-bg-page` | `--bg-0` | `--bg-deep` | 페이지 배경 (가장 낮음) |
| `--color-bg-surface` | `--bg-1` | `--bg-panel` | 패널/topbar 베이스 |
| `--color-bg-panel-alt` | `--bg-2` | `--bg-panel-alt` | 패널 변형 |
| `--color-bg-elevated` | `--bg-3` | `--bg-card` | 떠있는 카드 |
| `--color-bg-hover` | `--bg-4` | `--bg-card-hover` | hover/active row |

**Raw 보존 규칙**: dashboard의 `--bg-0~4`와 bonsai의 `--bg-deep/panel/...`는 **양쪽 다 raw tier에 보존**한다. 컴포넌트는 가능하면 Semantic을 쓰되, surface별 고유 emotional palette(bonsai의 "rotted wood / bruised meat" 같은 brand voice)를 잃지 않도록 raw 직접 참조도 허용.

### 3.2 Text

| Canonical (Semantic) | dashboard raw | bonsai raw | 의미 |
|---------------------|---------------|------------|------|
| `--color-fg-primary` | `--fg-1` | `--text-primary` | 본문 텍스트 (기본) |
| `--color-fg-secondary` | `--fg-2` | (분리: `--text-bright`/`--text-dim` 사이) | 보조 정보 |
| `--color-fg-muted` | `--fg-3` | `--text-dim` | 라벨, 메타데이터 |
| `--color-fg-disabled` | `--fg-4` | (없음, `--text-dim` 사용) | 비활성/placeholder |
| (없음, raw로) | (없음) | `--text-bright` | 헤드라인/강조 (bonsai 고유) |

### 3.3 Border

| Canonical (Semantic) | dashboard raw | bonsai raw | 의미 |
|---------------------|---------------|------------|------|
| `--color-border-default` | `--line-1` | `--border-main` | 기본 경계 |
| `--color-border-strong` | `--line-2` | `--border-highlight` | 강조 경계 |
| `--color-border-divider` | `--line-3` | (없음, `--border-highlight` 사용) | 영역 구분 |

### 3.4 Accent (the ONE accent)

| Canonical (Semantic) | dashboard raw | bonsai raw | 의미 |
|---------------------|---------------|------------|------|
| `--color-accent-fg` | `--brass-1` | `--accent-brass` | running/active 상태 강조 (active tab, 실행 중 keeper, primary button) |
| `--color-accent-fg-dim` | `--brass-3` | `--accent-brass-dim` | dim 동반색 |
| `--color-accent-glow` | `--brass-glow` (rgb triplet) | `--accent-glow` | box-shadow alpha용 |

**Discipline**: accent는 **한 가지만**. 색을 늘리고 싶을 때마다 "이 자리는 정말 active running 상태인가? 아니면 다른 의도인가?"를 먼저 묻는다. 다른 의도면 status 또는 attribution 토큰을 쓴다.

### 3.5 Status (data, not chrome)

| Canonical (Semantic) | dashboard raw | bonsai raw | 의미 |
|---------------------|---------------|------------|------|
| `--color-status-ok` | `--ok` | `--status-ok` | 성공, 완료 |
| `--color-status-warn` | `--warn` | `--status-warn` | 경고, at-risk |
| `--color-status-err` | `--err` | `--status-bad` | 실패, blocker |
| `--color-status-info` | `--info` | (없음, `--accent-ink` 가까움) | pending, queued |
| `--color-status-idle` | `--idle` | `--status-idle` | 유휴, noop |
| `--color-status-stalled` | `--stalled` | (없음, `--accent-mold` 가까움) | drift, stall |
| `--color-status-added` | `--ok` | `--status-ok` | diff: 추가된 라인 |
| `--color-status-modified` | `--warn` | `--status-warn` | diff: 변경된 라인 |
| `--color-status-deleted` | `--err` | `--status-bad` | diff: 삭제된 라인 |

**4-slot 패턴**: dashboard는 status마다 4 slot(`--ok-soft`, `--ok-fg`, `--ok-border`, `--ok-ring`)을 정의한다. bonsai는 단일 slot. SPEC v0.1에서는 **dashboard 4-slot이 canonical**, bonsai는 단일 slot을 fallback로 유지(컴포넌트가 4 slot을 요구하면 bonsai에서 동일 raw를 4번 참조).

### 3.6 Attribution (dashboard only — Phase 0)

| Canonical | dashboard raw | bonsai | 의미 |
|-----------|---------------|--------|------|
| `--color-keeper-1` | `--k-nick` | (없음) | keeper attribution dot 1 |
| `--color-keeper-2` | `--k-masc` | (없음) | keeper 2 |
| `--color-keeper-3` | `--k-sangsu` | (없음) | keeper 3 |
| `--color-keeper-4` | `--k-qa` | (없음) | keeper 4 |
| `--color-keeper-5` | `--k-rama` | (없음) | keeper 5 |
| `--p-anthropic` | `--p-anthropic` | (없음) | provider cascade chip |
| `--p-moonshot` | `--p-moonshot` | (없음) | provider cascade chip |
| `--p-openai` | `--p-openai` | (없음) | provider cascade chip |
| `--p-xai` | `--p-xai` | (없음) | provider cascade chip |

bonsai는 현재 keeper attribution을 색이 아닌 텍스트(`@nick0cave` 등)로 표현. SPEC v0.1에서는 attribution을 **dashboard-only canonical**로 두고, bonsai에서 도입 시 raw 그대로 참조하도록 허용.

### 3.7 Trace frame (bonsai only — Phase 0)

| Canonical | bonsai raw | dashboard | 의미 |
|-----------|------------|-----------|------|
| (없음, raw로) | `--t-llm` | (없음) | trace frame: inference |
| (없음, raw로) | `--t-tool` | (없음) | trace frame: tool call |
| (없음, raw로) | `--t-think` | (없음) | trace frame: reasoning |
| (없음, raw로) | `--t-wait` | (없음) | trace frame: idle |
| (없음, raw로) | `--t-err` | (없음) | trace frame: error |

bonsai의 timeline view 전용. dashboard에서 timeline 도입 시 동일 vocabulary로 canonical 화 검토.

### 3.8 Focus

| Canonical | dashboard raw | bonsai | 의미 |
|-----------|---------------|--------|------|
| `--color-focus-ring` | `--brass-1` (color value) | `--accent-brass` (대응) | `:focus-visible` outline color |

**주의**: dashboard 기존에 `--focus-ring` (box-shadow recipe) 존재. `--color-focus-ring`은 **color 값**만, `--focus-ring`은 box-shadow 전체 recipe. 둘은 다른 tier.

---

## 4. Theme matrix

### 4.1 Canonical themes (dashboard 표준)

| Theme | data-theme | 사용처 | Status |
|-------|------------|--------|--------|
| **dark** | (default, no attribute) | dashboard 기본 | canonical |
| **light** | `[data-theme="light"]` | dashboard light mode (Phase 0 placeholder values) | canonical, but **light palette는 디자이너 검토 미완** |

`prefers-color-scheme: light` 미디어 쿼리는 `:root:not([data-theme])` 가드로 OS 설정을 따른다. URL hash 또는 toggle UI가 `data-theme`를 명시하면 그게 우선.

### 4.2 Named variants (bonsai 자산, canonical 화)

bonsai의 5 테마는 production user에게 URL hash로 공유 가능한 자산. canonical theme matrix에 등재되지만 dashboard와 bonsai 모두에서 활성화될 수 있어야 한다.

| Theme | data-theme | 의도 | Status |
|-------|------------|------|--------|
| **dark-fantasy** | `[data-theme="dark-fantasy"]` | bonsai 기본 — visceral horror palette ("rotted wood / bruised meat / dried clot") | canonical variant |
| **cyberpunk** | `[data-theme="cyberpunk"]` | neon edge | canonical variant |
| **terminal** | `[data-theme="terminal"]` | green-on-black classic terminal | canonical variant |
| **parchment** | `[data-theme="parchment"]` | warm light, aged paper | canonical variant (light family) |
| **paper** | `[data-theme="paper"]` | clean light | canonical variant (light family) |

**규칙**: 새 theme은 SPEC PR에서 추가하고, 모든 raw token category(surface/text/border/accent/status)를 override해야 등재 자격. partial override는 `:root` 기본값에 fallback되어 hybrid가 발생하므로 금지.

### 4.3 테마별 토큰 override 의무 카테고리

| 카테고리 | dark | light | dark-fantasy | cyberpunk | terminal | parchment | paper |
|----------|------|-------|--------------|-----------|----------|-----------|-------|
| Surface stack (`--bg-*`) | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 |
| Text (`--fg-*`/`--text-*`) | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 |
| Border (`--line-*`/`--border-*`) | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 |
| Accent (`--brass-*`/`--accent-brass`) | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 | 필수 |
| Status | 권장 | 권장 | 권장 | 권장 | 권장 | 권장 | 권장 |
| Attribution (`--k-*`/`--p-*`) | 선택 | 선택 | 선택 | 선택 | 선택 | 선택 | 선택 |
| Trace (`--t-*`) | 선택 | 선택 | 권장 | 권장 | 권장 | 권장 | 권장 |

### 4.4 Theme switching mechanism

| Surface | 메커니즘 | localStorage key | URL hash | Default |
|---------|----------|------------------|----------|---------|
| dashboard/ | `cb-shared.jsx` `getTheme()` / `setTheme(t)` | `masc-ds-theme` | (없음, 향후 검토) | dark (또는 prefers-color-scheme) |
| dashboard_bonsai/ | `bin/main.ml` `install_theme_listener` | `masc.bonsai.theme` | `#cyberpunk` 등 | dark-fantasy |

**SPEC v0.1의 입장**: 두 메커니즘은 **분리 유지**한다. localStorage key 통합과 URL hash 정책 통합은 향후 별도 spec 갱신 사안 (사용자 영향 큼).

---

## 5. ARIA pattern catalog (요약)

상세 예시 코드는 `dashboard/design-system/patterns/a11y/<pattern>.md` (PR-S3에서 추가). 본 spec은 6개 패턴의 contract만 정의.

### 5.1 region

| 항목 | 값 |
|------|-----|
| 사용 시점 | mock 시각화, 데이터 시각화 박스, 명명된 영역 |
| 필수 attr | `role="region"` + `aria-label` (또는 `aria-labelledby`) |
| 키보드 | 별도 동작 없음 (일반 콘텐츠) |
| SR 기대값 | "<label>, region" announcement |

### 5.2 list / listitem

| 항목 | 값 |
|------|-----|
| 사용 시점 | 동질적 항목의 컬렉션 (keeper 리스트, 로그 라인, swimlane row) |
| 필수 attr | 부모 `role="list"` + `aria-label`, 자식 `role="listitem"` |
| 키보드 | 별도 동작 없음 (탐색용) |
| SR 기대값 | "list, N items, <itemlabel>" |

### 5.3 tablist / tab

| 항목 | 값 |
|------|-----|
| 사용 시점 | 콘텐츠 전환 (keeper inspector tab, deck mode tab) |
| 필수 attr | 부모 `role="tablist"` + `aria-label`, 자식 `role="tab"` + `aria-selected` + `aria-controls` (해당 panel id) |
| 키보드 | Arrow Left/Right로 tab 이동, Enter/Space로 활성화, Home/End로 처음/끝 |
| SR 기대값 | "tab, <label>, selected, N of M" |

### 5.4 radiogroup / radio

| 항목 | 값 |
|------|-----|
| 사용 시점 | 단일 선택 (branch selector, channel chooser) |
| 필수 attr | 부모 `role="radiogroup"` + `aria-label`, 자식 `role="radio"` + `aria-checked` |
| 키보드 | Arrow Up/Down으로 이동 + 자동 선택, Enter/Space로 명시 활성화 |
| SR 기대값 | "<label>, radio button, checked/not checked, N of M" |

### 5.5 log

| 항목 | 값 |
|------|-----|
| 사용 시점 | 시간순 추가 콘텐츠 (operator nudge log, activity feed, 로그 뷰어) |
| 필수 attr | `role="log"` + `aria-live="polite"` + `aria-label` |
| 키보드 | 별도 동작 없음 (탐색용) |
| SR 기대값 | 새 항목 추가 시 자동 announce |

### 5.6 dialog

| 항목 | 값 |
|------|-----|
| 사용 시점 | 모달, drawer, confirm prompt |
| 필수 attr | `role="dialog"` + `aria-modal="true"` + `aria-labelledby` (제목 id) + `aria-describedby` (선택) |
| 키보드 | Escape로 닫기, Tab은 dialog 내부 trap, 첫 focus는 의미있는 요소로 |
| SR 기대값 | "dialog, <title>, <description>" |

### 5.7 보조 attribute 규약

| Attribute | 사용 패턴 |
|-----------|-----------|
| `aria-pressed` | 토글 버튼 (filter chip 등). `aria-checked`와 혼용 금지 |
| `aria-checked` | 체크박스, 라디오, switch |
| `aria-selected` | tablist의 tab, listbox의 option (checked와 다름 — selected는 "현재 보여지는 것") |
| `aria-current` | 현재 위치 표시 (현재 페이지, 현재 단계). `selected`와 다름 — current는 "지금 여기" |
| `aria-hidden="true"` | 시각 장식 (아이콘, 구분자). 부모의 aria-label에 의미가 흡수되어야 함 |
| `aria-live="polite"` | 비방해 announcement (status, log) |
| `aria-live="assertive"` | 즉시 announcement (error, alert) — 신중히 사용 |
| `tabIndex={0}` | 키보드 focus 가능. `onKeyDown`으로 Enter/Space 처리 필수 |

---

## 6. Governance

### 6.1 새 token 추가 절차

1. 본 SPEC.md에 token 항목 추가 PR 선행
2. SPEC PR 머지 후 `tokens.css`에 정의 (또는 기존 PR rebase로 정합화)
3. tier 결정: 같은 의미를 가진 raw가 이미 있으면 Semantic만 추가. 새 raw 추가는 테마 모두에서 override 가능해야 함

### 6.2 Hardcoded color/spacing 금지

`*.jsx`, `*.css`, `*.ml` 어디에서도 `#abc123`, `rgb(...)`, 픽셀 직접값 사용 금지. 예외:

| 예외 | 위치 | 사유 |
|------|------|------|
| `keeperColor()` 헬퍼 | `dashboard/design-system/preview/cb-group-i.jsx` | 12 keeper persona를 attribution token 5종으로 환원 불가 — hex extension 의도적 |
| `rgba(... / .NN)` alpha 조합 | 어느 곳이든 | `rgb(var(--token-glow) / .12)` 형태로 raw token alpha 조합은 허용 |
| 폰트 fallback chain | `--font-*` 정의 내 | system font name (e.g., `Inter`, `JetBrains Mono`) |

### 6.3 Surface 적용 의무

| 변경 종류 | dashboard 적용 | bonsai 적용 | SPEC 갱신 |
|----------|----------------|-------------|-----------|
| 새 raw token | 필수 | 필수 | 필수 |
| 새 semantic token | 필수 | 권장 (가능하면 동시) | 필수 |
| 새 role token | 사용처에만 | 사용처에만 | 필수 |
| 새 theme | 두 surface 양쪽 | 두 surface 양쪽 | 필수 |
| 새 ARIA 패턴 | catalog에 추가 | catalog에 추가 | 필수 |

### 6.4 Out of scope (이 SPEC v0.1에서 다루지 않는 것)

- 양쪽 surface theme listener 통합 (별도 storage key, URL hash 정책 다름)
- 양쪽 surface 폰트/리셋 통합 (분리 유지)
- 컴포넌트 컨트랙트 SSOT (button/card/input 등의 시각·동작 규약 — 향후 v0.2)
- Motion timing curves의 의미적 표준화 (현재 dashboard 5 curve, bonsai 0 — 향후 v0.2)
- iconography (현재 양쪽 거의 없음 — 도입 시 spec 갱신)

---

## 7. Migration map (현재 코드 → canonical)

### 7.1 dashboard/ 마이그레이션 우선순위

1. **PR #10427** (이미 진행 중): `tokens.css`에 19 semantic alias 등재. 본 SPEC §3.1~3.8과 1:1 일치.
2. **PR #10437** (이미 진행 중): preview cb-group-a~i에 ARIA 281건 추가. 본 SPEC §5와 1:1 일치.
3. (후속 plan) `source_styles/components.css` 등 component CSS의 raw token 직접 참조를 Semantic으로 점진 치환.
4. (후속 plan) `colors_and_type.css` (159줄 별개 파일) 정합화 또는 폐기.

### 7.2 dashboard_bonsai/ 마이그레이션 우선순위

1. (PR-S2) `static/colors_and_type.css`에 Semantic alias tier 도입 — bonsai의 5 테마 각각이 SPEC §3 canonical alias를 정의하도록 확장.
2. (PR-S2) bonsai와 dashboard가 같은 raw token SSOT를 공유하도록 build/import 통합.
3. (후속 plan) `src/*.ml`의 ppx_css 인라인 블록에서 raw token 직접 참조를 Semantic으로 점진 치환.
4. (후속 plan) 누락 production view에 SPEC §5 ARIA 패턴 추가.

### 7.3 Vocabulary alignment summary

| Bonsai 토큰 | Canonical (Semantic) | 마이그레이션 액션 |
|------------|---------------------|-------------------|
| `--bg-panel` | `--color-bg-surface` | bonsai에 alias 추가, 사용처는 점진 치환 |
| `--bg-card` | `--color-bg-elevated` | 동일 |
| `--text-primary` | `--color-fg-primary` | 동일 |
| `--text-dim` | `--color-fg-muted` | 동일 |
| `--accent-brass` | `--color-accent-fg` | 동일 |
| `--border-main` | `--color-border-default` | 동일 |
| `--status-ok` | `--color-status-ok` (= `--color-status-added`) | 동일 |
| `--status-bad` | `--color-status-err` (= `--color-status-deleted`) | 동일 |
| `--t-llm/tool/think/wait/err` | (raw, canonical에 직접 등재) | 변경 없음 |
| `--bg-deep/panel-alt/card-hover` | (raw, dashboard와 별도 등재) | 변경 없음 |

---

## 8. References

- 본 spec이 통합하는 두 surface의 README:
  - `dashboard/design-system/README.md` (dashboard design intent + token tier 다이어그램)
  - `dashboard_bonsai/README.md` (bonsai phase 상태 + 5 테마 설명)
- ARIA pattern catalog 상세: `dashboard/design-system/patterns/a11y/<pattern>.md` (PR-S3에서 추가)
- 진행 중 PR:
  - #10427 — dashboard semantic alias matrix (SPEC §3 구현)
  - #10437 — dashboard preview cb-group-a~i ARIA (SPEC §5 구현)
  - #10394 — dashboard preview cb-group-j/k + Planes.jsx ARIA (SPEC §5 구현, 머지됨)

---

## 9. Versioning

| Version | Date | 변경 |
|---------|------|------|
| v0.1 | 2026-04-26 | 초안. dashboard PR #10427 alias matrix와 bonsai 5 테마를 canonical 형태로 통합. |
