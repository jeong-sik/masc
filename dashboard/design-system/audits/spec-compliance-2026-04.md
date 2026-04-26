# SPEC Compliance Audit — 2026-04-26

**Status**: read-only audit (Stage 0 of design system prod alignment series)
**Scope**: `dashboard/` (Preact) + `dashboard_bonsai/` (Bonsai/OCaml)
**Reference**: `dashboard/design-system/SPEC.md` (canonical, Phase 0)
**Method**: rg/comm/wc 정량 측정 + 파일 위치 grep
**Outcome**: 양쪽 prod이 SPEC v0.1 vocabulary를 얼마나 따르는지 + Stage 1+ PR 시리즈 우선순위 근거

---

## TL;DR

| 영역 | 측정값 | SPEC 정합도 |
|------|--------|-------------|
| Bonsai inline hex (raw) | 8 hex (`shell_view.ml` `.flame_*` 클래스) | **0% Semantic** |
| Bonsai var() fallback hex | 25 hex (이미 `var(--*, #fallback)` 패턴) | **alias만 추가하면 됨** |
| Preact `tokens.css` 토큰 정의 | 65 ID | **SPEC Semantic tier 0% 사용** |
| Preact 컴포넌트 토큰 사용 | 4,000+ var() 참조 | top 25 모두 raw tier |
| Bonsai `colors_and_type.css` 토큰 | 72 ID, 5 테마 | SPEC source_styles와 49 ID 일치 |
| SPEC `source_styles/tokens.css` | 322 ID | `--color-*` Semantic tier 양쪽 prod 0% |
| Bonsai mount HTML 위치 | `lib/server/server_routes_http_pages.ml:319` | inline string에 link tag 추가 가능 |
| Drift 발견 | `dashboard_bonsai/static/colors_and_type.css` (540) ≠ `dashboard/design-system/colors_and_type.css` (159) | 별도 follow-up |

**핵심 결론**:
1. Stage 1 작업 = **SPEC Semantic tier alias 도입** (시각 변화 zero, 토큰 vocabulary만 정합)
2. raw hex 정정은 작은 작업 (`shell_view.ml` `.flame_*` 8 hex만)
3. Bonsai mount HTML 위치 확정 → Stage 1 link tag 추가 위치 결정
4. `colors_and_type.css` 분기는 본 audit scope 외, 별도 이슈

---

## 1. Bonsai inline hex 분석

### 1.1 위치별 분포 (총 33 hex)

| 파일 | hex 개수 | var() fallback | raw 사용 |
|------|---------|----------------|---------|
| `pill.ml` | 10 | 10 (모두 fallback) | 0 |
| `meta.ml` | 7 | 7 | 0 |
| `shell_view.ml` | 6 | 1 (`.flame_wait`) | 5 (`.flame_plan/exec/wait/err`) |
| `sec.ml` | 5 | 5 | 0 |
| `hero.ml` | 5 | 5 | 0 |
| `keepers_directory.ml` | 1 | 1 | 0 |
| **합계** | **34** | **29** | **5** (실제 8 hex 라인) |

`shell_view.ml` `.flame_*` 5 라인 중 4 라인이 `background: #hex; color: #hex;` 2개 hex씩 → 실제 raw hex 라인 4개, 8 hex 값.

### 1.2 var() fallback에서 사용된 변수 vocabulary

```
--bg-panel-alt    (1회)
--text-dim        (5회 — meta/pill/sec/hero에 분산)
--text-bright     (2회 — meta/hero)
--text-primary    (1회 — hero)
--accent-brass    (3회 — meta/pill/hero)
--accent-blood    (2회 — meta/pill)
--status-ok       (2회 — meta/pill)
--status-warn     (1회 — pill)
--border-main     (3회 — meta/pill/sec)
--border-highlight (1회 — sec)
```

10개 변수가 6개 primitive에서 SPEC §3.1~§3.5 카테고리와 1:1 정합:

| Bonsai 변수 | SPEC Semantic | SPEC 카테고리 |
|-----------|---------------|---------------|
| `--text-primary` | `--color-fg-primary` | §3.2 Text |
| `--text-dim` | `--color-fg-muted` | §3.2 Text |
| `--text-bright` | (없음, raw 유지) | §3.2 Text bonsai 고유 |
| `--accent-brass` | `--color-accent-fg` | §3.4 Accent |
| `--accent-blood` | (없음, status로 분류) | §3.5 Status (err/danger) |
| `--status-ok` | `--color-status-ok` | §3.5 Status |
| `--status-warn` | `--color-status-warn` | §3.5 Status |
| `--border-main` | `--color-border-default` | §3.3 Border |
| `--border-highlight` | `--color-border-strong` | §3.3 Border |
| `--bg-panel-alt` | `--color-bg-panel-alt` | §3.1 Surface |

### 1.3 Stage 1 작업량 추정 (Bonsai)

- **alias 추가 (시각 변화 zero)**: `colors_and_type.css` 또는 `source_styles/tokens.css`에 `--color-fg-muted: var(--text-dim);` 류 alias 10개 — `:root` 또는 테마별 정의
- **inline hex raw 정정**: `shell_view.ml` `.flame_*` 4 라인 8 hex → SPEC trace frame 토큰 (§3.7 bonsai-only `--t-llm/tool/think/wait/err`) 매핑
- **fallback hex 유지**: 25 fallback hex는 ppx_css 안전망으로 유지 (CSS 변수 누락 시 시각 깨짐 방지)

---

## 2. Preact 토큰 사용 분석

### 2.1 컴포넌트 토큰 사용 top 25

```
 952 var(--text-muted
 462 var(--text-dim
 379 var(--text-body
 303 var(--card-border
 255 var(--text-strong
 238 var(--warn
 232 var(--white-8
 222 var(--accent
 210 var(--ok
 197 var(--white-3
 176 var(--white-4
 169 var(--white-10
 145 var(--bad
 135 var(--bad-light
 120 var(--white-5
  93 var(--accent-10
  86 var(--warn-10
  86 var(--bad-10
  80 var(--white-2
  77 var(--ok-10
  73 var(--white-6
  58 var(--warn-20
  54 var(--bg-0
  51 var(--bad-20
  46 var(--accent-20
```

총 4,000+ var() 참조. SPEC `--color-*` Semantic tier 사용량은 **0건** (top 25 모두 raw tier).

### 2.2 SPEC Semantic alias 매핑 (Stage 1 작업)

| Preact raw | SPEC Semantic | SPEC 카테고리 | 사용량 |
|-----------|---------------|---------------|--------|
| `--text-muted` | `--color-fg-muted` | §3.2 Text | 952 |
| `--text-dim` | `--color-fg-disabled` | §3.2 Text | 462 |
| `--text-body` | `--color-fg-primary` | §3.2 Text | 379 |
| `--text-strong` | `--color-fg-secondary` | §3.2 Text | 255 |
| `--card-border` | `--color-border-default` | §3.3 Border | 303 |
| `--warn` | `--color-status-warn` | §3.5 Status | 238 |
| `--accent` | `--color-accent-fg` | §3.4 Accent | 222 |
| `--ok` | `--color-status-ok` | §3.5 Status | 210 |
| `--bad` | `--color-status-err` | §3.5 Status | 145 |
| `--bad-light` | `--ok-soft` 류 (4-slot §3.5) | §3.5 4-slot | 135 |
| `--bg-0` | `--color-bg-page` | §3.1 Surface | 54 |
| `--white-N` (alpha) | (raw 유지, dashboard 고유) | §3.1 Surface raw | 1,070+ |

**Stage 1 alias 추가 = 11개 SPEC 토큰을 Preact `tokens.css`에 정의** (시각 변화 zero, 양방향 alias 가능):

```css
:root {
  /* SPEC §3.2 Text */
  --color-fg-primary: var(--text-body);
  --color-fg-secondary: var(--text-strong);
  --color-fg-muted: var(--text-muted);
  --color-fg-disabled: var(--text-dim);

  /* SPEC §3.3 Border */
  --color-border-default: var(--card-border);

  /* SPEC §3.4 Accent */
  --color-accent-fg: var(--accent);

  /* SPEC §3.5 Status */
  --color-status-ok: var(--ok);
  --color-status-warn: var(--warn);
  --color-status-err: var(--bad);

  /* SPEC §3.1 Surface */
  --color-bg-page: var(--bg-0);
}
```

신규 컴포넌트는 Semantic 토큰 사용 권장. 기존 4,000+ raw 참조는 점진 deprecation (Stage 2+ 화면별).

---

## 3. Bonsai colors_and_type.css 분석

### 3.1 위치 + 크기

- **prod**: `dashboard_bonsai/static/colors_and_type.css` (540줄, 72 토큰)
- **design system**: `dashboard/design-system/colors_and_type.css` (159줄)
- **drift**: 두 파일 다름 (`diff -q` 확인). prod 540줄이 더 풍부 (5 테마 정의 포함)

### 3.2 5 테마 vocabulary

```
[data-theme="dark-fantasy"]   (default)
[data-theme="cyberpunk"]
[data-theme="terminal"]
[data-theme="parchment"]
[data-theme="paper"]
```

SPEC §4.2 "Named variants (bonsai 자산, canonical 화)" 와 매칭. theme switching mechanism은 SPEC §4.4 참고.

### 3.3 SPEC source_styles/tokens.css와의 정합

- 일치 ID: 49 / 72 (Bonsai) → 약 **68%** Bonsai 토큰이 SPEC vocabulary에 등록됨
- Bonsai only: 23 토큰 (`--brass`, `--brick`, `--ember`, `--forest`, `--ink-5/6`, `--plum`, `--slate`, `--teal`, `--font-{body,display,ui}`, `--radius-{xs,sm,md,lg,pill}`, `--scrollbar-*`, `--shadow-*`)
- 누락 카테고리: 폰트 (`--font-*`), 반경 (`--radius-*`), 스크롤바, 그림자, raw 색
- SPEC only: 273 토큰 (대부분 dashboard 전용 + Semantic tier + attribution)

### 3.4 권장

- Bonsai only 23 토큰 중 폰트/반경/스크롤바/그림자는 SPEC v0.2에서 추가 검토 (별도 SPEC PR)
- raw 색 (`--brass`, `--brick`, ...) 은 5 테마 내부에서 raw tier로 유지

---

## 4. ARIA Pattern Catalog

### 4.1 위치 + 인벤토리

`dashboard/design-system/patterns/a11y/`:
- `dialog.md`
- `list.md`
- `log.md`
- `radiogroup.md`
- `region.md`
- `tablist.md`

총 565 라인. 6개 패턴 명세.

### 4.2 양쪽 prod ARIA 사용 분포

**Bonsai**:
- `view` 모듈에서 explicit `role=` 사용 측정 필요 (Stage 0 본 audit에서는 측정 미완)
- 추정: pill/sec/hud는 `role` attribute 거의 없음 (시각 primitive 위주)

**Preact common 97 primitive 중 role/aria-* 사용**:
- top: `toast.test.ts` (9), `heartbeat-strip.test.ts` (7), `skeleton.ts` (4), `observatory-filter-bar.ts` (3), `feedback-state.ts` (3)
- 대부분 컴포넌트가 ARIA 속성 미사용. SPEC ARIA 정합 작업 여지 큼

### 4.3 Stage 2~N 작업

화면별 PR에서 SPEC §5 ARIA 패턴 (region/log/list/tablist/radiogroup/dialog) 을 해당 화면이 사용하는 컴포넌트에 적용. 일괄 정합은 비효율 — 화면별 적용이 검증/리뷰 단위로 적합.

---

## 5. Bonsai mount HTML 위치

### 5.1 발견

`lib/server/server_routes_http_pages.ml:319`:
```ocaml
<link rel="stylesheet" href="/dashboard/b/assets/colors_and_type.css?v=%s">
```

`lib/server/server_routes_http_routes_frontend.ml:114`:
```ocaml
|> Http.Router.prefix_get "/dashboard/b/assets/"
   ...
   let prefix_len = String.length "/dashboard/b/assets/" in
```

즉:
- `/dashboard/b/*` 라우트가 Bonsai SPA를 서빙
- HTML은 OCaml 서버 코드의 inline string에 embed
- Static asset은 `/dashboard/b/assets/` 프리픽스로 라우터가 디렉토리 매핑
- 현재 `colors_and_type.css` 한 개만 link

### 5.2 Stage 1 token import 추가 위치

옵션 A (권장): `server_routes_http_pages.ml:319` 의 inline HTML에 link tag 추가:
```html
<link rel="stylesheet" href="/dashboard/b/assets/source_styles/tokens.css?v=%s">
```
+ `server_routes_http_routes_frontend.ml` 의 prefix handler가 `dashboard_bonsai/static/source_styles/tokens.css` 를 서빙하도록 `dashboard/design-system/source_styles/tokens.css` 를 `dashboard_bonsai/static/source_styles/`로 심볼릭 링크 또는 빌드 카피.

옵션 B (간단): SPEC `source_styles/tokens.css` 의 `--color-*` 알리아스 정의를 `dashboard_bonsai/static/colors_and_type.css` 의 `:root` 블록 끝에 직접 추가 (Bonsai static 540줄에 한 블록 추가). 별도 link tag 불필요.

**Stage 1 PR 권장: 옵션 B** (변경 단순, 빌드 카피 없음).

---

## 6. 화면 매핑 우선순위 (Stage 2~N)

### 6.1 양쪽 prod 매핑 표

| Bonsai view (라인) | Preact 동등 | SPEC 매핑 | 우선순위 | 사유 |
|---|---|---|---|---|
| overview_view (422) | `overview/overview.ts` | cb-group-a Topbar + cb-group-d KPI | **P1** | 양쪽 모두 작음, 안전한 첫 케이스 |
| keepers_view (145) + roster (228) + swim (323) | `agent-roster.ts` (855) + `keeper-detail-panels.ts` (1264) | cb-group-i Backbone + Trace frame | **P2** | 가장 많은 사용자 시간 |
| goals_view (431) | `goals/*` | cb-group-d (recursive tree) | **P3** | recursive tree 검증 사례 |
| logs_view (2374) | logs 탭 (별도) | cb-group-h Evidence | **P4** | Bonsai 거대, 분리 필요 |
| archive_runs_view (342) | `autoresearch.ts` (592) | cb-group-h | **P5** | 단순 list |
| dead_keepers_view (106) | (없음) | cb-group-i KeeperMultiSelect | **P6** | Bonsai only |

### 6.2 Preact-only 화면 (Stage N+)

Bonsai에 동등 화면 없음, Preact 단독:

| Preact 컴포넌트 | 라인 | SPEC 매핑 | 우선순위 |
|---|---|---|---|
| `connector-status.ts` | 1740 | (별도 패턴 필요) | N+1 |
| `cascade-config-panel.ts` | 1364 | cb-group-d Config | N+2 |
| `keeper-detail-panels.ts` | 1264 | cb-group-i + cb-group-d | N+3 (Stage 3 Keepers와 통합 가능) |
| `keeper-config-panel.ts` | 1182 | cb-group-d | N+4 |
| `keeper-detail.ts` | 1163 | (Stage 3에서 처리) | N+3 |
| `fsm-hub.ts` | 1011 | (별도 패턴) | N+5 |
| `telemetry-unified.ts` | 970 | cb-group-h Evidence | N+6 |
| `fleet-fsm-matrix.ts` | 952 | cb-group-d | N+7 |
| `journey-panel.ts` | 824 | cb-group-h | N+8 |
| `fleet-telemetry-panel.ts` | 782 | cb-group-h | N+9 |
| `memory-subsystems.ts` | 758 | cb-group-h | N+10 |

---

## 7. 신규 발견 사항 (별도 follow-up 권장)

### 7.1 colors_and_type.css 분기

`dashboard_bonsai/static/colors_and_type.css` (540줄) ≠ `dashboard/design-system/colors_and_type.css` (159줄). 어느 쪽이 SSOT인지 SPEC.md에 명시 없음. 별도 GitHub Issue로 trace 권장 — drift 해소 작업이 본 SPEC alignment series와 분리되어야 함.

### 7.2 SPEC.md에 token import 메커니즘 누락

SPEC.md는 vocabulary와 theme matrix를 정의하지만 **prod이 어떻게 SPEC tokens.css를 import하는지** 명시 없음. Stage 1 PR에서 SPEC §6 신규 섹션 "Token Import Mechanism" 추가 권장 (옵션 A vs B, Bonsai vs Preact 차이).

### 7.3 SPEC `--cmt-*` (code review semantic) 미사용

SPEC source_styles/tokens.css 에 `--cmt-{approve,flag,note,question,suggest}` 정의되어 있으나 양쪽 prod 모두 0% 사용. dashboard PR review 화면 도입 시 활용 가능. 별도 epic.

### 7.4 lighthouse a11y baseline 부재

SPEC §5 ARIA pattern catalog는 명세, 자동 검증 없음. Stage 1+ PR에서 lighthouse a11y CI 통합 별도 인프라 PR 권장.

---

## 8. Stage 1 작업 권장 (Audit 결과 기반)

### 8.1 Stage 1 PR 범위

1. **Preact `tokens.css` 알리아스 추가** (1 파일, ~30 라인)
   - SPEC §3.1~3.5 Semantic 토큰 11개 alias
   - 시각 변화 zero (raw → semantic forward alias만)

2. **Bonsai `colors_and_type.css` 알리아스 추가** (1 파일, ~10 라인)
   - 동일한 SPEC §3.1~3.5 Semantic 토큰 alias (Bonsai 변수 → SPEC alias)
   - 5 테마 모두에서 동작 (alias는 raw tier 변수 참조이므로)

3. **Bonsai `shell_view.ml` `.flame_*` raw hex 정정** (1 파일, 4 라인)
   - 8 hex → SPEC §3.7 trace frame 토큰 (`--t-llm/tool/think/wait/err`)

4. **Stage 1 시각 검증**:
   - 양쪽 prod 빌드 통과
   - 양쪽 prod 모든 화면 시각 byte-identical (alias = forward 매핑이므로 cascade에서 같은 값 도달)
   - DOM dump role/aria 변화 없음

PR 크기 추정: ~50 라인 변경 + 빌드/시각 검증.

### 8.2 미적용 (Stage 1 scope 외)

- chrome (Topbar/Sidebar/SectionHeading) 의 SPEC ARIA 정합 → Stage 1.5 또는 Stage 2와 통합
- raw 토큰 → semantic tier 마이그레이션 (4,000+ var() 참조의 점진 치환) → Stage 2~N 화면별
- Bonsai SPEC v0.2 (폰트/반경/스크롤바/그림자 SPEC 추가) → 별도 SPEC PR
- colors_and_type.css drift 해소 → 별도 issue

### 8.3 위험 + 완화

| 위험 | 완화 |
|------|------|
| alias chain (raw → semantic → component)이 cascade에서 늘어남 | 11개 alias만 추가 → 무시할 수준. 브라우저 CSS 변수 lookup은 1-2 hop |
| Bonsai 5 테마에서 alias 동작 확인 | Stage 1 PR에서 5 테마 모두 dashboard_bonsai 시각 검증 |
| Preact 4,000+ raw 참조의 deprecation timing | Stage 2+ 화면별로 점진. Stage 1에서는 deprecation 표기 없음 |
| SPEC.md token import mechanism 누락 | Stage 1 PR에 SPEC §6 신규 섹션 추가 (옵션 A vs B 명세) |
| `colors_and_type.css` 분기로 인한 alias 위치 혼동 | Stage 1 PR에서 prod (`dashboard_bonsai/static/`)에 alias 추가, design-system (`dashboard/design-system/`)는 본 audit scope 외 |

---

## 9. 측정 메서드 (재현)

```bash
# Bonsai inline hex
rg -n "#[0-9a-fA-F]{3,8}\b" dashboard_bonsai/src/{pill,meta,shell_view,sec,hero,keepers_directory}.ml

# Preact 토큰 사용 분포
grep -rohE 'var\(--[a-z][a-z0-9-]+' dashboard/src/components/ | sort | uniq -c | sort -rn | head -25

# Bonsai vs SPEC 토큰 일치
rg "^\s*(--[a-z][a-z0-9-]+):" dashboard_bonsai/static/colors_and_type.css -or '$1' | sort -u > /tmp/bonsai-tokens.txt
rg "^\s*(--[a-z][a-z0-9-]+):" dashboard/design-system/source_styles/tokens.css -or '$1' | sort -u > /tmp/ds-tokens.txt
comm -12 /tmp/bonsai-tokens.txt /tmp/ds-tokens.txt | wc -l

# Bonsai mount HTML 위치
rg -n '"/dashboard/b' --type ml --type ts | grep -v ".worktrees"
```

---

**Audit 작성일**: 2026-04-26
**Audit base commit**: `839441dfd4` (origin/main)
**Stage 1 PR 진입 조건**: 본 audit의 §8.1 권장 검토 + 사용자 승인
