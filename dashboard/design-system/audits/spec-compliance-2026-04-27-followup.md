# SPEC Compliance Audit Follow-up — 2026-04-27

**Status**: read-only audit follow-up to `spec-compliance-2026-04.md`
**Scope**: `dashboard/` (Preact) — Tailwind arbitrary value sweep gap
**Reference**: `dashboard/design-system/SPEC.md` v0.4 (Phase 0)
**Method**: rg quantitative + token-pairing analysis
**Outcome**: Identifies the next mechanical sweep target unblocked by SPEC PR

---

## TL;DR

| 영역 | 측정값 | 진척 (vs 2026-04-26) |
|------|--------|--------------------|
| Bonsai inline raw hex | shell_view.ml `.flame_block` 2 (escape hatch only) | **was 8 → now 2** (this PR closes 6) |
| Preact `--color-*` semantic 사용 (components) | 3,119 references | **was ~0 → now 3,119** |
| Preact `--color-*` semantic 사용 (handwritten styles) | 17 references | **was 0 → now 17** (legacy 그대로) |
| Tailwind arbitrary `text-[#xxx]` / `bg-[#xxx]` (components) | 58 occurrences | **새 측정** — 미발견 sweep target |
| Tailwind arbitrary `bg-[rgba(..)]` (components) | 50+ | **새 측정** |
| SPEC TBD slot | `--color-status-info` raw 미정 | 변동 없음 |

**핵심 결론**: 2026-04-26 audit Stage 1 essentially complete. **다음 mechanical 작업 = SPEC §3.5 4-slot fg tier 신규 정의 후 sweep**.

---

## 1. Stage 1 진척 정리

### 1.1 완료된 항목 (audit 권장 대비)

| Audit 권장 (§8.1) | 상태 | 증거 |
|---|---|---|
| Preact `tokens.css` 11 alias | **completed** | `tokens.css`에 `--color-*` 56개 (목표의 5배 over) |
| Bonsai `colors_and_type.css` 10 alias | **completed** | static 파일에 `--color-*` 16개 + 5 테마 적용 |
| Bonsai `shell_view.ml .flame_*` raw hex | **in this PR** | 4 클래스 → `--t-think/tool/wait/err`, 잔존 2(default block, escape hatch) |

### 1.2 이 PR 변경 요약

**Bonsai trace-frame 이행** (1 file, +4/−4):

```diff
-  .flame_plan { background: #2a3a2a; color: #c4dcb0; }
-  .flame_exec { background: #3a2a2a; color: #e4b8b0; }
-  .flame_wait { background: #1a1410; color: var(--color-fg-muted); }
-  .flame_err  { background: #3a1010; color: #e0b8a8; }
+  .flame_plan { background: var(--t-think); color: var(--color-fg-primary); }
+  .flame_exec { background: var(--t-tool);  color: var(--color-fg-primary); }
+  .flame_wait { background: var(--t-wait);  color: var(--color-fg-muted); }
+  .flame_err  { background: var(--t-err);   color: var(--text-bright); }
```

CHANGELOG `[Unreleased] v0.4 — Trace-frame tokens (bonsai-side PR pending)` 항목 종결.

`.flame_block` (default block container) 2 hex는 SPEC §2 Tier 간 참조 방향 규칙의 escape hatch ("Semantic이 표현 못 하는 경우") 명시 적용.

**4-slot fg slot 부분 codification** (raw tier, 시각 byte-identical):

| 신규 토큰 | 값 | 사용처 |
|---|---|---|
| `--rose-fg` | `#fecdd3` | `text-[#fecdd3]` 5 callsite (config-resolution-panel × 4, kanban-components × 1) |
| `--emerald-fg` | `#bbf7d0` | `text-[#bbf7d0]` 3 callsite (config-resolution-panel × 3) |

Sweep 결과: `text-[#fecdd3]` 0건, `text-[#bbf7d0]` 0건 (모두 `text-[var(--rose-fg)]` / `text-[var(--emerald-fg)]`로 치환). Forward alias이므로 시각 변화 없음.

**Codification 기준** (적용한 규칙):
- 같은 hex가 ≥3 callsite에서 일관된 paired context (`bg-[var(--family-N)]` 옆)으로 등장하면 codification 가능
- 페어링이 명확하고 family naming 충돌이 없을 때만 진행
- 1-2회 단발 사용은 invention 위험 → skip
- 명명 충돌 발생 시 (예: raw `--accent-fg` vs Semantic `--color-accent-fg`) skip

**Cycle 적용 대상에서 제외된 후보** (이 PR 범위 외):
- `text-[#dff3ff]` (4x, paired with `--accent-*`) — `--color-accent-fg` Semantic 충돌, 신규 명명 결정 필요
- `text-[#fda4af]` / `text-[#f7b6b6]` / `text-[#f7b7b7]` — bad-family soft 변형 다수, 단일 토큰화 불가
- `bg-[#0f1117]` (3x) — SPEC §3.1 surface stack 5단계 외 새 semantic 필요
- `bg-[#5f7199]` (3x) — `--slate-{500,600}` 사이 새 step, scale 확장 결정
- `text-[#000]` (3x) — `bg-[var(--color-status-ok)]` 의도적 black, 토큰화 ROI 낮음

---

## 2. 미발견 sweep target — Tailwind arbitrary values

### 2.1 측정 (dashboard/src/components/)

```bash
rg --no-filename -o '\b(?:bg|text|border|fill|stroke|ring|outline|shadow|from|to|via)-\[#[0-9a-fA-F]{3,8}\]' dashboard/src/components/ | sort | uniq -c | sort -rn
```

상위 분포 (총 58 occurrences, 30+ 고유 hex):

| 빈도 | Arbitrary | 추정 의도 |
|---|---|---|
| 5 | `text-[#fecdd3]` | rose-fg (paired with `--rose-10/28`) |
| 4 | `text-[#dff3ff]` | sky-fg (paired with `--sky-*`) |
| 3 | `text-[#c084fc]` | purple-fg (thinking / status) |
| 3 | `text-[#bbf7d0]` | emerald-fg (paired with `--emerald-*`) |
| 3 | `text-[#000]` | 강제 black (light theme) |
| 3 | `bg-[#5f7199]` | slate surface |
| 3 | `bg-[#0f1117]` | page bg variant |
| 2 | `text-[#f7b7b7]` | bad-fg variant |
| 2 | `text-[#c4b5fd]` | violet-fg |
| 2 | `text-[#9af3ba]` | emerald-fg variant |
| 2 | `bg-[#555]` | offline gray |
| 14 | (1회씩) | tool-call category, mission state |

### 2.2 패턴 — SPEC §3.5 4-slot fg tier 부재

| Family | bg tier | border tier | fg tier | 상태 |
|---|---|---|---|---|
| `--rose` | `--rose-10` ✓ | `--rose-28` ✓ | `text-[#fecdd3]` (4 callsite) | **fg slot 부재** |
| `--emerald` | `--emerald-10/12/8/30` ✓ | `--emerald-28` ✓ | `text-[#bbf7d0]/#9af3ba]` | **fg slot 부재** |
| `--sky` | `--sky-4/8` ✓ | `--sky-28` ✓ | `text-[#dff3ff]/#bae6fd]` | **fg slot 부재** |
| `--purple` | `--purple-12` ✓ | `--purple-24` ✓ | `text-[#c084fc]/#c4b5fd]` | **fg slot 부재** |
| `--accent` | `--accent-10/12/20` ✓ | `--accent-28/-soft` ✓ | (Mostly migrated) | partially complete |

`--bad-light: #f87171`이 정의돼 있으나 inline `text-[#f7b7b7]/#fecdd3]`와 다른 색조. inline 값이 더 soft (light보다 lighter).

### 2.3 결론 — Stage X 작업 = 4-slot fg slot 정식화

**선행 조건 (SPEC PR)**:
1. SPEC §3.5 4-slot table에 `fg` 컬럼 추가 (`base / fg / soft / border` 명시)
2. 각 family에 `-fg` 토큰 추가:
   - `--rose-fg: #fecdd3`
   - `--emerald-fg: #bbf7d0`
   - `--sky-fg: #dff3ff`
   - `--purple-fg: #c084fc`
   - `--violet-fg: #c4b5fd` (or merge with purple)
   - `--bad-soft-fg: #f7b7b7` (vs `--bad-light: #f87171` 구분)
3. Light/dark 테마 페어링 검증

**후속 sweep PR** (mechanical, 시각 변화 zero):
1. 단일 family씩 PR 분할 (rose-only, emerald-only, …)
2. Regex sweep: `text-\[#fecdd3\]` → `text-[var(--rose-fg)]`
3. 시각 byte-identical 검증 (forward alias)

### 2.4 위험 + 완화

| 위험 | 완화 |
|---|---|
| 같은 hex가 여러 의도로 쓰일 수 있음 | callsite 별 paired bg/border 컨텍스트로 family 식별 (이 audit §2.2) |
| Light theme에서 동일 토큰이 다른 hex여야 함 | SPEC PR에서 light theme 변형 함께 정의 |
| `text-[#000]` 같은 brand-neutral 강제값 | 토큰화 대상 외 — 명시적 black 의도 보존 |
| `text-[#c084fc]` / `text-[#c4b5fd]` 가까운 hex 중복 | family 통합 vs 분리 결정 — 디자이너 리뷰 필요 |

---

## 3. SPEC.md TBD 항목

`SPEC.md:83`:
```
| `--color-status-info` | `--info` | (없음, `--accent-ink` 가까움) | pending, queued |
```

bonsai raw 미할당. SPEC v0.5 에서 결정 권장:
- 옵션 A: `--accent-ink` (이미 정의됨)을 정식으로 매핑
- 옵션 B: 신규 `--info-ink` raw 도입

---

## 4. Bonsai raw hex 잔존 (`.flame_block`)

`dashboard_bonsai/src/shell_view.ml:487-488`:
```ocaml
.flame_block {
  ...
  background: #2a2838;
  color: #b8c0e0;
}
```

SPEC §2 escape hatch 명시 허용. 단, default block 의도가 trace frame 전체의 "기본" 인지 또는 별도 의미인지 SPEC §3.7 확장 검토 권장. v0.5 후속.

---

## 5. 측정 메서드 (재현)

```bash
# Tailwind arbitrary hex
rg --no-filename -o '\b(?:bg|text|border|fill|stroke)-\[#[0-9a-fA-F]{3,8}\]' \
  dashboard/src/components/ | sort | uniq -c | sort -rn

# Tailwind arbitrary rgba
rg --no-filename -o '\b(?:bg|text|border)-\[rgba?\([^]]+\)\]' \
  dashboard/src/components/ | sort | uniq -c | sort -rn

# Token paired pattern (text-[#xxx] near var(--family-N))
rg "text-\[#[0-9a-f]+\]" dashboard/src/components/ | \
  grep -oE 'var\(--[a-z]+-(10|28|8|12|24|30)' | sort | uniq -c | sort -rn

# Bonsai raw hex (no var fallback)
rg -n "^[^/]*: ?#[0-9a-fA-F]{3,8}" dashboard_bonsai/src/*.ml | grep -v "var("

# --color-* semantic usage
grep -rohE 'var\(--color-[a-z0-9-]+' dashboard/src/components/ | wc -l
grep -rohE 'var\(--color-[a-z0-9-]+' dashboard/src/styles/ | wc -l
```

---

**Audit 작성일**: 2026-04-27
**Audit base commit**: `8ce8bb4811` (origin/main)
**Stage X 진입 조건**: §2.3 SPEC PR 검토 + 디자이너 리뷰 (4-slot fg hex 결정)
**참조**: `audits/spec-compliance-2026-04.md` (Stage 0 baseline)
