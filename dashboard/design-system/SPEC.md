# MASC Cockpit — Design System Specification

**Status**: canonical (Phase 0)
**Scope**: `dashboard/` (Preact) + `dashboard_bonsai/` (Bonsai/OCaml)
**Audience**: agents, contributors, reviewers adding new tokens or components

---

## 1. Why this exists

masc 레포는 두 dashboard surface가 같은 서버에서 병존 서빙된다. 같은 design intent를 표현하는데 vocabulary가 분기되어 있어, surface 간 이동 시 색·간격·타이포가 미묘하게 달라진다. 이 spec은 두 surface가 공유하는 canonical vocabulary와 design rule을 정의한다.

| Surface | 경로 | 스타일 시스템 | Active 테마 |
|---------|------|----------------|------|
| `dashboard/` | `/dashboard/*` | Preact + Tailwind utility (`src/styles/tokens.generated.css`) + handwritten component CSS | dark / light |
| `dashboard_bonsai/` | `/dashboard/b/*` | Bonsai + ppx_css inline + `static/colors_and_type.generated.css` | dark-fantasy (default) / paper |
| `dashboard/design-system/preview/` | `/dashboard/design-system/preview/*` | preview surface, generated tokens (`source_styles/tokens.generated.css`) | dark / light |

Archived themes (cyberpunk · terminal · parchment) live in `dashboard_bonsai/static/themes/archive/` — 보존만 하고 default rotation 에서는 제외 (Wave 2 #11301).

모든 토큰 정의는 `dashboard/design-system/tokens/source.ts` SSOT 에서 codegen 으로 7 개 artifact 가 emit 된다. hand-written `tokens.css` / `semantic.css` / `colors_and_type.css` 는 모든 surface 에서 삭제되었다 (Wave 2). 자세한 이행 기록은 §12 audit 참조.

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

### 3.6 Attribution (dashboard only — Phase 0, **v0.3 revised**)

#### 3.6.1 Palette — 12-slot OkLCH spectrum

| Canonical | dashboard raw | 의미 |
|-----------|---------------|------|
| `--color-keeper-1`  | `--k-1`  | slot 01 · H=000° · rose |
| `--color-keeper-2`  | `--k-2`  | slot 02 · H=030° · clay |
| `--color-keeper-3`  | `--k-3`  | slot 03 · H=060° · amber |
| `--color-keeper-4`  | `--k-4`  | slot 04 · H=090° · olive |
| `--color-keeper-5`  | `--k-5`  | slot 05 · H=120° · moss |
| `--color-keeper-6`  | `--k-6`  | slot 06 · H=150° · jade |
| `--color-keeper-7`  | `--k-7`  | slot 07 · H=180° · teal |
| `--color-keeper-8`  | `--k-8`  | slot 08 · H=210° · cyan |
| `--color-keeper-9`  | `--k-9`  | slot 09 · H=240° · azure |
| `--color-keeper-10` | `--k-10` | slot 10 · H=270° · iris |
| `--color-keeper-11` | `--k-11` | slot 11 · H=300° · violet |
| `--color-keeper-12` | `--k-12` | slot 12 · H=330° · magenta |

OkLCH parameters fixed at L=68%, C=0.09, hue stride 30° — all slots ≥4.5:1
contrast on `--bg-0`, all adjacent ΔE ≥ 25. Each slot also exposes
`-soft`, `-border`, `-ring`, `-glow` companions (4-slot semantics).

Old named tokens (`--k-nick`, `--k-masc`, `--k-sangsu`, `--k-qa`, `--k-rama`)
were removed in v0.4. New code MUST use `--k-N` (1..12) or, preferably,
the canonical façade `--color-keeper-N`. Or — best — the `<KeeperBadge>`
primitive, which resolves slot + sigil from a keeper id automatically.

#### 3.6.2 Mapping — keeper id → slot

`kSlot(id)` (cb-shared.jsx) is canonical. Five anchor IDs are pinned in
`KEEPER_REGISTRY`; everything else is FNV-1a hashed mod 12. This avoids
re-mapping when the roster grows.

#### 3.6.3 Attribution rule — color is not enough

Color alone MUST NOT identify a keeper. Every attribution carries a
**second channel**: a 2-letter sigil (`kSigil(id)`). Concretely:

- ✅ `<KeeperBadge id="...">` — the canonical primitive (sigil + colored name)
- ✅ Code-gutter sigil column ≥ 22px wide
- ✅ Activity blocks containing the sigil glyph
- ❌ Bare colored stripe / dot as the *only* attribution carrier
- ❌ Stacked >4 raw sigils — collapse to `+N` via `<KeeperStack cap={4}>`

Rationale: a 12-hue ring at C=0.09 cannot remain pairwise distinguishable
under (a) ≥7 simultaneously-active keepers, (b) deuteranopia/protanopia,
(c) low-gamut external displays. The sigil is the recovery channel.

#### 3.6.4 Status × keeper non-collision

Keeper hues sit at C=0.09 (muted ring). Status hues use higher chroma
(C ≥ 0.13) and a different shape vocabulary (pill vs sigil-square). No
keeper hex coincides with any status hex. Components MUST NOT reuse
`--color-status-*` tokens for attribution, and vice-versa.

#### 3.6.5 Provider runtime (removed by RFC-0168 / RFC-0170)

The closed-roster `--p-<vendor>` palette was removed by RFC-0168
(13 vendor tokens) and RFC-0170 (the missed `--p-moonshot` triple).
Runtime chips now render with neutral border-default styling.

bonsai는 현재 keeper attribution을 색이 아닌 텍스트(`@nick0cave` 등)로
표현 — SPEC v0.3에서도 텍스트-only 가 valid attribution 으로 인정된다
(sigil 의 degenerate case). bonsai 가 색을 도입할 경우 dashboard
의 12-slot canonical 을 그대로 참조한다.

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

### 3.9 Mobile operator touch target

| Canonical (Role) | backing raw | density | 적용 범위 | 의미 |
|------------------|-------------|---------|-----------|------|
| `--mobile-touch-target-min` | `--sp-8` (`40px`) | invariant | dashboard mobile operator controls | pointer 입력이 필요한 control의 최소 hit area |

이 값은 일반 row/control density와 분리한다. compact density에서도 물리적 hit
area가 줄어들면 안 되므로 `--row-h-tall`이나 `--ctrl-h-*`를 대신 사용하지 않는다.
컴포넌트는 보이는 control에 `min-width`/`min-height`로 적용하고, 작은 checkbox처럼
실제 input이 더 작아야 하는 경우에는 클릭 가능한 `label` wrapper의 `width`/`height`에
적용한다. button이 아닌 wrapper도 touch target이면 `touch-action: manipulation`을
명시한다.

---

## 4. Theme matrix

### 4.1 Canonical themes (dashboard 표준)

| Theme | data-theme | 사용처 | Status |
|-------|------------|--------|--------|
| **dark** | (default, no attribute) | dashboard 기본 | canonical |
| **light** | `[data-theme="light"]` | dashboard light mode (Phase 0 placeholder values) | canonical, but **light palette는 디자이너 검토 미완** |

`prefers-color-scheme: light` 미디어 쿼리는 `:root:not([data-theme])` 가드로 OS 설정을 따른다. URL hash 또는 toggle UI가 `data-theme`를 명시하면 그게 우선.

### 4.2 Named variants (bonsai 자산)

bonsai 의 active 테마는 **dark-fantasy + paper** 두 종. 옛 5 테마 (cyberpunk · terminal · parchment) 는 source.ts SSOT 에 포함되지 않으며 `dashboard_bonsai/static/themes/archive/` 에 보존 (Wave 2 #11301). 부활시키려면 source.ts theme array 에 재정의 + Bonsai theme listener 등록 + SPEC PR 이 모두 선행되어야 한다.

| Theme | data-theme | 의도 | Status |
|-------|------------|------|--------|
| **dark-fantasy** | `:root, [data-theme="dark-fantasy"]` | bonsai 기본 — visceral horror palette ("rotted wood / bruised meat / dried clot") | active (canonical) |
| **paper** | `[data-theme="paper"]` | clean light | active (canonical, light family) |
| **cyberpunk** | `[data-theme="cyberpunk"]` | neon edge | archived (`static/themes/archive/cyberpunk.css`) |
| **terminal** | `[data-theme="terminal"]` | green-on-black classic terminal | archived (`static/themes/archive/terminal.css`) |
| **parchment** | `[data-theme="parchment"]` | warm light, aged paper | archived (`static/themes/archive/parchment.css`) |

**규칙**: 새 theme 은 source.ts theme array 추가 + SPEC PR 이 동시에 진행되어야 한다. 모든 raw token category(surface/text/border/accent/status)를 override 해야 등재 자격. partial override 는 `:root` 기본값에 fallback 되어 hybrid 가 발생하므로 금지.

### 4.3 테마별 토큰 override 의무 카테고리

| 카테고리 | dark | light | dark-fantasy | paper |
|----------|------|-------|--------------|-------|
| Surface stack (`--bg-*`) | 필수 | 필수 | 필수 | 필수 |
| Text (`--fg-*`/`--text-*`) | 필수 | 필수 | 필수 | 필수 |
| Border (`--line-*`/`--border-*`) | 필수 | 필수 | 필수 | 필수 |
| Accent (`--brass-*`/`--accent-brass`) | 필수 | 필수 | 필수 | 필수 |
| Status | 권장 | 권장 | 권장 | 권장 |
| Attribution (`--k-*`/`--p-*`) | 선택 | 선택 | 선택 | 선택 |
| Trace (`--t-*`) | 선택 | 선택 | 권장 | 권장 |

archived 테마 (cyberpunk · terminal · parchment) 는 본 의무 매트릭스 적용 대상이 아니다 — 보존 자료.

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

1. 본 SPEC.md 에 token 항목 추가 PR 선행
2. SPEC PR 머지 후 `dashboard/design-system/tokens/source.ts` 에 정의 (raw 또는 semantic 배열)
3. `pnpm tokens:build` (`dashboard/` 에서) 실행 → 7 generated artifact emit:
   - `dashboard/design-system/source_styles/tokens.generated.css` (preview)
   - `dashboard/src/styles/tokens.generated.css` (Tailwind v4 `@theme`)
   - `dashboard/src/styles/tokens.generated.ts` (Preact typed)
   - `dashboard_bonsai/src/tokens.ml` + `tokens.mli` (OCaml polyvar)
   - `dashboard/design-system/tokens/build/tokens.json` (DTCG 2025.10)
   - `dashboard_bonsai/static/colors_and_type.generated.css` (Bonsai naming)
4. tier 결정: 같은 의미를 가진 raw 가 이미 있으면 Semantic 만 추가. 새 raw 추가는 active 테마 모두에서 override 가능해야 함
5. CI 강제: `tokens-drift` workflow 가 idempotent build (재실행 후 git diff = ∅), tier integrity (generated artifact 직접 수정 차단), keeper OkLCH ΔE < 2, status canon pin 4 gate 검증

### 6.2 Hardcoded color/spacing 금지

`*.jsx`, `*.css`, `*.ml` 어디에서도 `#abc123`, `rgb(...)`, 픽셀 직접값 사용 금지. 예외:

| 예외 | 위치 | 사유 |
|------|------|------|
| `rgba(... / .NN)` alpha 조합 | 어느 곳이든 | `rgb(var(--token-glow) / .12)` 형태로 raw token alpha 조합은 허용 |
| 폰트 fallback chain | `--font-*` 정의 내 | system font name (e.g., `Inter`, `JetBrains Mono`) |
| 4-slot status pattern | `source.ts` 의 `--{ok\|warn\|err\|info\|idle\|stalled}-{soft\|fg\|border\|ring}` | 컴포넌트별 정교한 surface/text/border/ring 4 slot 조합. single-slot semantic alias 로 환원 불가. 컴포넌트는 raw 참조 허용. |
| `--brass-2` mid tone | accent palette mid-tone 사용처 | §3.4 는 accent 를 fg/fg-dim 2 slot 만 정의. 사용 빈도 증가 시 `--color-accent-fg-mid` 추가 검토. |

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

> **historical note**: §7.1 / §7.2 의 옛 PR-S 시리즈 (PR-S2, PR-S2.5, PR-S3, PR-M5, PR #10427, PR #10437 등) 진행 표시는 모두 머지/완료되었다. 자세한 이행 결과는 §12 audit 참조. 이 절은 현재 진행 중 작업이 아니라 점진적 컴포넌트 마이그레이션의 가이드 역할만 한다.

### 7.1 dashboard/ 마이그레이션 우선순위

1. ✅ semantic alias matrix 등재 + ARIA 패턴 — Wave 0/1 머지 완료
2. ✅ `colors_and_type.css` / `tokens.css` 삭제, source.ts SSOT 단일화 — Wave 2 머지 완료
3. (지속) `source_styles/components.css` 등 component CSS 의 raw token 직접 참조를 Semantic 으로 점진 치환

### 7.2 dashboard_bonsai/ 마이그레이션 우선순위

1. ✅ Bonsai 측 `colors_and_type.css` 삭제 + `colors_and_type.generated.css` 로 전환 — Wave 2 #11301
2. ✅ source.ts 가 dashboard / bonsai 양쪽 raw token SSOT — Wave 2 머지 완료
3. (지속) `src/*.ml` 의 ppx_css 인라인 블록에서 raw token 직접 참조를 Semantic / Tokens module 로 점진 치환
4. (지속) 누락 production view 에 SPEC §5 ARIA 패턴 추가

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
- ARIA pattern catalog 상세: `dashboard/design-system/patterns/a11y/<pattern>.md`
- Token SSOT: `dashboard/design-system/tokens/source.ts`
- Codegen driver: `dashboard/design-system/tokens/build.ts`
- Equivalence checker: `dashboard/design-system/tokens/scripts/check-equivalence.mjs`
- CI workflow: `.github/workflows/tokens-drift.yml`
- 2026-04 SSOT 이행 PR 시리즈: §12 audit

---

## 9. Versioning

| Version | Date | 변경 |
|---------|------|------|
| v0.1 | 2026-04-26 | 초안. dashboard PR #10427 alias matrix와 bonsai 5 테마를 canonical 형태로 통합. |
| v0.2 | 2026-04-27 | Wave 5 docs sweep. source.ts SSOT 이행 반영, archived 테마 (cyberpunk · terminal · parchment) 분리, hand-written `tokens.css` / `colors_and_type.css` 참조 제거, §12 audit 섹션 신규. |

---

## 12. 2026-04 SSOT 이행 완료 (audit)

다음 PR 시리즈로 디자인 시스템이 codegen SSOT 로 통일되었다. 이전 §6 / §7 의 옛 PR-S 진행 표시 (PR-S2, PR-S2.5, PR-S3, PR-S3g, PR-M5 등) 는 모두 머지/완료되어 archived.

| Wave | PR | 내용 |
|------|----|------|
| 1b | #11189 | codegen scaffold (`source.ts` → 4 generated outputs) |
| 1b | #11235 | build.ts artifact 7/7 (Bonsai `colors_and_type.generated.css`) |
| 2 | #11250 | preview swap (`tokens.css` 880L + `semantic.css` 117L + façade 20L 삭제) |
| 2 | #11255 | Preact swap (`dashboard/src/styles/tokens.css` 137L 삭제) |
| 2 | #11275 | source.ts superset extension (+32 토큰, Preact 컴포넌트 호환) |
| 2 | #11301 | Bonsai swap (`dashboard_bonsai/static/colors_and_type.css` 566L 삭제 + 3 archived themes 보존) |
| 5 | #11330 | `check-equivalence.mjs` 복원 (status canon + keeper ΔE 단순화) |
| 5 | #11293 | `tokens-drift` CI workflow (Tokens drift + Tier integrity 게이트) |

이행 결과:

- hand-written CSS 모든 surface 에서 삭제 (preview, Preact, Bonsai)
- 2 themes (dark-fantasy + paper) 만 active, 3 archived themes (cyberpunk, terminal, parchment) 는 `dashboard_bonsai/static/themes/archive/` 보존
- drift 방지 CI 4 gate 활성화: idempotent build, status canon pin, keeper OkLCH ΔE < 2, tier integrity (generated 직접 수정 차단)
- §6.1 새 token 추가 절차가 SSOT 단일 경로 (source.ts → `pnpm tokens:build` → 7 artifact emit) 로 단순화됨

historical note: 본 audit 섹션 머지 이전, SPEC 본문 §6.2 governance 예외 목록에는 `--font-mono` stack divergence (PR-S2.5) 와 `--shadow-inset` vs `--shadow-ring` rename (PR-S3g) 항목이 active exception 으로 등재되어 있었다. 두 divergence 모두 source.ts 단일 SSOT 도입 후 해소되어 예외 목록에서 제거.
