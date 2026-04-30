# IDE Mockup ↔ design-system v0.4 Mapping Audit (2026-04-30)

**Status**: SSOT for IDE Plane production migration
**Trigger**: claude.ai/design `MASC Cockpit.html` `code-mode.js` mockup 이 production 진입 후보로 부상. 사용자 지시 "supervisor 에이전트가 우리 mockup의 raw hex를 그대로 베껴쓸까" — 즉 mockup을 그대로 픽셀 카피하지 말고 v0.4 SSOT로 번역할 매핑이 선행되어야 한다.
**Audience**: IDE Plane production migration 을 수행하는 agent / contributor
**Plan reference**: `/Users/dancer/me/planning/claude-plans/zany-yawning-nebula.md` (Phase 0)

---

## 1. 결정적 발견

mockup은 design-system v0.4 의 외부 신규 plane 이 **아니다**. v0.4 의 `dashboard/design-system/ui_kits/cockpit/` 프로토타입에 이미 정의된 `IdePlane` 의 **refinement / superset** 이다.

증거:
- `ui_kits/cockpit/Planes.jsx:144-198` 에 `IdePlane` 함수가 5 modes (`edit / review / merge / graph / search`) + terminal toggle + tree+center+right grid 로 구현됨.
- `ui_kits/cockpit/App.jsx` mode tab list 에 `Dashboard / Work / Comms / Observe / Cognition / IDE` 로 IDE 가 이미 등재.
- `ui_kits/cockpit/cockpit.css` 의 `.ide-v2-*` 클래스는 모두 v0.4 Semantic tier 토큰 사용 (`var(--color-fg-disabled)` 등). raw tier 직접 참조 0.
- RFC 0014 (TreeView) §1: "Stage 5 IDE plane needs ... file explorer ... keyboard parity with VS Code".
- RFC 0015 (Tabs) §1: "Mode tabs in the topbar (Dashboard / Work / Comms / Observe / Cognition / IDE)".
- RFC 0014/0015 모두 "Consumes: `--sidebar-*`, `--tree-*`, `--tab-*` tokens (IDE Chrome, #11948)" 명시.

**함의**: production migration 의 base 는 cockpit prototype `IdePlane` 이며, mockup 의 "E1~E5 Code IDE plane" 표현은 prototype 의 5 modes 와 의미적으로 일치 (E = edit/review/merge/graph/search 5 modes). mockup 은 prototype 위에 LAYERS / ACTIVITY THIS RUN / INTERJECT 3 영역과 view-tab refinement 를 추가한다.

`source_styles/code.css` (`.code-tree / .code-editor / .code-review / .code-activity`) 는 cockpit prototype 과 **별개의 더 작은 prototype** 이다. mockup 의 grid 와 cockpit prototype `.ide-v2-*` grid 가 동일 구조이므로, production migration 은 `.code-*` 가 아닌 `.ide-v2-*` 를 base 로 한다.

---

## 2. Element 매핑 (시안 mockup → v0.4 SSOT)

| 시안 mockup element | v0.4 prototype / RFC 매핑 | 매칭도 | production 작업 |
|---------------------|--------------------------|--------|------------------|
| 모드 tab `COCKPIT/CODE/SPLIT/TERMINAL` (topbar) | `App.jsx` `Dashboard/Work/Comms/Observe/Cognition/IDE` mode tab + RFC 0015 tabs | partial — 라벨 다름 | `IDE` mode 를 `CODE` 로 rename 또는 alias. `SPLIT` 은 IDE-internal mode 로 흡수 (IdePlane 의 `merge`). `TERMINAL` 은 IDE-internal terminal toggle 로 흡수. cockpit topbar 4-tab 분리는 mockup 의 시각적 변형이며 prototype 6-mode 흐름이 의미상 동일 |
| KPI strip (NCV/QAK/MIP/SGS/RMA/TSK/JTR) | `KpiStripIslandSync` (RFC 0017 §7d sync-mount) | high — 동일 | 그대로 재사용. IDE plane 진입 시에도 KPI strip 유지 (cockpit 공통 chrome) |
| Topbar breadcrumb `default / ~/me / nick0cave` | cockpit `Topbar` brand+goal+keeper switcher | high | cockpit `Chrome.jsx` 의 `Topbar` 그대로 |
| Topbar 우측 `mcp · connected / supervisor: local / build 0.12.4` | cockpit `StatusBar` 일부 | partial — topbar 위치 vs prototype statusbar 위치 | mockup 은 topbar 우측에 metadata 합침. `StatusBar` 컴포넌트를 topbar slot 로 hoist 하거나 별도 `TopbarMeta` 컴포넌트 |
| Keeper presence chips `* runtime / main / nick0cave@dkr-a1 / improver@wt-run-47` | RFC 0010 collaboration-cursor + cockpit `Topbar` keepers | partial | RFC 0010 base 에 worktree label (`@dkr-a1`, `@wt-run-47`) 표시 확장. `keeper-presence-store.ts` 신규 |
| EXPLORER 패널 `(10 FILES)` + tree | `ide-v2-tree` + `IxTreeDiff` (Planes.jsx:186) + RFC 0014 tree-view | high — prototype 일치 | RFC 0014 어댑터 + `file-tree-store.ts` (signal). IxTreeDiff 의 keeper dot + diff count semantics 를 store contract 로 캡처 |
| 에디터 (`router.ts`) line 좌측 keeper ownership label | `IxEditAttrib` (Planes.jsx:155 — `attrib` = attribution = blame-by-keeper) | partial — naming 일치, 구현 미상 | **신규 RFC 0019: keeper-line-ownership**. `IxEditAttrib` 의 placeholder reference 와 prototype 클래스가 base. `keeper-line-ownership-store.ts` 신규 |
| 라인 숫자 옆 색깔 dot (변경 표시) | (없음) | none | `keeper-line-ownership-store` 의 line-level event 에서 derive |
| LAYERS toggle `Time / Parallel / Tools / Approve / Notes / EXPLODE` | (prototype 없음) | **신규** | **신규 RFC 0020: layered-overlay-system**. multi-select toggle (RFC 0015 tabs 어댑터 변형) + overlay rendering layer. mock data 부터 |
| CONVERSATION rail 우측 상단 `FLAG/QUESTION/APPROVE/NOTE/SUGGEST` | `IxPrThread` (Planes.jsx:158, review mode 우측) + RFC 0010 collaboration-cursor (anchor 일부) | partial — review mode 에만 prototype, anchored thread 미명세 | **신규 RFC 0021: anchored-thread-rail**. line anchor (`router.ts:34`) → editor scroll, 5 thread kinds (FLAG/QUESTION/APPROVE/NOTE/SUGGEST) + replies. `anchored-thread-store.ts` 신규 |
| ACTIVITY THIS RUN 우측 하단 keeper timeline | (prototype 없음) | **신규** | `activity-stream-store.ts` (sse-store.ts 패턴) + virtual-list rendering. RFC 0017 §7c 의 sustained 16-keeper bench 재사용 |
| INTERJECT 하단 input + `Send/Approve/Pause/Drain` 컨트롤 | (prototype 없음) | **신규** | `interject-store.ts` 신규 + 기존 `keeper-actions.ts` 확장 (Send/Approve/Pause/Drain 액션) |
| view tabs `SOURCE / SPLIT DIFF / UNIFIED / BLAME` (editor 상단) | IdePlane modes `edit / review / merge / graph / search` 일부 | partial — 이름/축 다름 | `SOURCE` ↔ `edit + IxEditAttrib`, `SPLIT DIFF` ↔ `merge + IxEditMerge`, `UNIFIED` ↔ `merge` 의 unified diff variant, `BLAME` ↔ `edit + IxEditAttrib` blame-on view. RFC 0015 tabs 어댑터 + view-state mapping table |
| `Apply refactor` 버튼 (topbar 우측) | 기존 `keeper-actions.ts` action shape | high | action dispatch slot 만 추가 |
| Terminal mode (mockup TERMINAL tab) | IdePlane terminal toggle (`terminalOpen`) + `IxTerm` (Planes.jsx:192) | partial — prototype 은 toggle, mockup 은 별도 mode | mockup TERMINAL = topbar mode 분리이지만 IdePlane internal terminal toggle 과 동일 wire. mode tab 4-way (COCKPIT/CODE/SPLIT/TERMINAL) 에서 TERMINAL 은 cockpit + bottom terminal full-height variant |

---

## 3. Token tier 사용 룰 (raw hex 베껴쓰기 방지)

mockup 의 어떤 hex (`#0c0b08`, `#d4a14a`, `#c46a5a` 등) 도 production 에 직접 사용하지 않는다. 변환 룰:

| mockup hex 패턴 | v0.4 token (Semantic) | v0.4 raw fallback |
|----------------|----------------------|-------------------|
| 페이지 배경 `#0c0b08` | `var(--color-bg-page)` | `var(--bg-0)` |
| 패널 surface `#141210`, `#1a1815` | `var(--color-bg-surface)`, `var(--color-bg-panel-alt)` | `var(--bg-1)`, `var(--bg-2)` |
| 카드 elevated `#211e1a` | `var(--color-bg-elevated)` | `var(--bg-3)` |
| hover row `#2a2621` | `var(--color-bg-hover)` | `var(--bg-4)` |
| primary text `#f0e9dc` | `var(--color-fg-primary)` | `var(--fg-1)` |
| muted text `#7a7065` | `var(--color-fg-muted)` | `var(--fg-3)` |
| disabled `#4a453e` | `var(--color-fg-disabled)` | `var(--fg-4)` |
| brass accent `#d4a14a` | `var(--color-accent-fg)` | `var(--brass-1)` |
| keeper 1~12 hue | `var(--color-keeper-N-glow)` (semantic) | `var(--k-N)` (raw) |
| status ok `#6b9e6b` | `var(--color-status-ok)` | `var(--ok)` |
| status err `#c46a5a` | `var(--color-status-err)` | `var(--err)` |

**룰**:
1. IDE production component 는 **Semantic tier** 만 참조한다 (Role tier 가 표현하는 경우 Role tier 우선).
2. Raw tier 직접 참조는 cockpit prototype (`source_styles/`) 의 escape hatch 이며 production 진입 시 Semantic 으로 격상한다.
3. Mockup 의 raw hex 가 v0.4 token 으로 표현 불가능한 경우 → **token PR 선행**. `tokens/source.ts` 에 새 entry 추가, codegen 실행, `tokens-drift` CI 4 gate 통과 후 production component 진행.
4. `dashboard_bonsai/` 와 `dashboard/` 양쪽이 동일 token 을 공유해야 한다 (SPEC §3).

**검증**: production IDE PR 마다 `rg -E '#[0-9a-fA-F]{3,8}' src/components/ide/` 출력이 0 lines 여야 한다 (단, syntax-highlight 기본 색상 코드 같은 사용처 제외 — 그 경우 ESLint disable 이유 명시).

---

## 4. 신규 RFC 항목 (production 작업 의존성)

| RFC | 제목 | 매핑 element | 의존성 | 우선순위 |
|-----|------|-------------|--------|---------|
| **0019** | keeper-line-ownership | blame-by-keeper, line color dot | RFC 0010 collaboration-cursor 의 keeper identity primitive | P1 (PR-5 blocking) |
| **0020** | layered-overlay-system | LAYERS toggle (Time/Parallel/Tools/Approve/Notes/EXPLODE) | RFC 0015 tabs (multi-select 변형), RFC 0019 (overlay layer 가 ownership 데이터 활용) | P2 (PR-5 이후) |
| **0021** | anchored-thread-rail | CONVERSATION rail | RFC 0010 collaboration-cursor (anchor 일부 정의), RFC 0014 tree-view (thread navigation) | P2 (PR-6 blocking) |

본 audit 은 RFC 0019/0020/0021 의 **scope 정의** 만 캡처한다. 각 RFC 본문은 별도 PR 로 작성 (Draft 상태). production migration PR-5 / PR-6 는 해당 RFC Draft 가 머지된 후 시작한다.

---

## 5. Solid island 경계 (RFC 0017 §7c-d 정합)

production component 별 framework 결정:

| component | N (예상) | framework | 근거 |
|-----------|---------|-----------|------|
| EXPLORER tree (file-tree-store) | 500-5000 노드 | **Solid** | RFC 0017 §7c large-N regime, fine-grained reactivity 우위 |
| Editor + blame strip | 100-2000 라인 | **Solid** | per-line signal, large-N |
| LAYERS toggle | 6 entries | **Preact** | small-N, RFC 0017 §7d 회귀 영역 |
| CONVERSATION rail | 5-30 threads | **Preact** | small-N |
| ACTIVITY THIS RUN | 100-1000 events | **Solid** (sustained workload, 측정 후 결정) | RFC 0017 §7c sustained bench 적용 |
| INTERJECT input | 1 input + 4 actions | **Preact** | small-N |
| Cockpit mode tabs (topbar) | 4-6 tabs | **Preact** | small-N |
| View tabs (SOURCE/SPLIT DIFF/UNIFIED/BLAME) | 4 tabs | **Preact** | small-N |

**Sync-mount 강제**: Solid component 마운트 시 RFC 0017 §7d 의 `KpiStripIslandSync` 패턴 (`useLayoutEffect` + ref callback) 적용. `useEffect` 마운트 금지 (작은-N 회귀).

---

## 6. Audit checklist (production PR 마다)

PR 마다 다음을 확인:

- [ ] Component 가 raw hex (`#xxxxxx`) 를 직접 사용하지 않음 (`rg '#[0-9a-fA-F]{3,8}' <changed files>`).
- [ ] Component 가 Semantic 또는 Role tier token 만 참조 (Raw tier 참조 시 PR description 에 escape hatch 사유 명시).
- [ ] Component 가 cockpit prototype `IdePlane` 의 grid 구조 (`.ide-v2-tree / .ide-v2-center / .ide-v2-right / .ide-v2-terminal`) 에 정합.
- [ ] Solid component 는 RFC 0017 §7d sync-mount 패턴 사용 (`useLayoutEffect` ref callback).
- [ ] 새 token 이 필요한 경우 token PR 이 선행되었음 (`tokens-drift` CI 4 gate 통과).
- [ ] mockup ↔ v0.4 매핑 (본 §2) 에서 element 출처 (existing / 신규 RFC) 명시.
- [ ] `dashboard_bonsai/` 영역 영향 검토 (Bonsai 도 IDE plane 가지므로 token 변경 시 양쪽 빌드).

---

## 7. Out of scope of this audit

- **Backend 데이터 모델** — `keeper-line-ownership` / `anchored-thread` / `activity-stream` 의 wire format / persistence / event sourcing 은 backend RFC 트랙 (Kimi roadmap Phase 1-3, gap_analysis Gap-001) 별도.
- **시안 mockup 의 모든 픽셀** — mockup 은 디자인 SSOT 가 아니라 reference. v0.4 SSOT 가 픽셀 의사결정 기준이 되며, mockup 픽셀이 v0.4 와 충돌할 경우 v0.4 가 이긴다 (mockup 수정 필요).
- **Editor library 결정 (Shiki vs Monaco vs CodeMirror)** — 본 audit 은 ownership / blame strip 데이터 모델만 다룸. 라이브러리 선정은 PR-5 결정.
- **Bonsai surface 동기화** — Bonsai 의 IDE plane 도 본 매핑을 따라야 하나, 본 audit 은 `dashboard/` (Preact + Solid island) 만 다룸.

---

## 8. References

- `dashboard/design-system/SPEC.md` §2 token taxonomy, §3 canonical vocabulary
- `dashboard/design-system/CHANGELOG.md` v0.4 SSOT codegen migration 기록
- `dashboard/design-system/RFC/0014-tree-view.md` — EXPLORER primitive
- `dashboard/design-system/RFC/0015-tabs.md` — mode + view tabs primitive
- `dashboard/design-system/RFC/0010-collaboration-cursor.md` — keeper presence + anchor base
- `dashboard/design-system/RFC/0017-solidjs-migration.md` §7c-d — sync-mount pattern, sustained-load bench
- `dashboard/design-system/ui_kits/cockpit/Planes.jsx:144-198` — `IdePlane` prototype (5 modes, terminal toggle)
- `dashboard/design-system/ui_kits/cockpit/App.jsx` — cockpit mode tab list
- `dashboard/design-system/ui_kits/cockpit/cockpit.css` — `.ide-v2-*` grid (v0.4 token 정합)
- `/Users/dancer/me/planning/claude-plans/zany-yawning-nebula.md` — 본 plan
- `/Users/dancer/Downloads/Kimi_Agent_반응형 멀티 IDE/masc_keeper_ide_upgrade_roadmap_v2.md` Phase 4 IDE 화 vision
- `/Users/dancer/Downloads/Kimi_Agent_반응형 멀티 IDE/masc_gap_analysis.md` Gap-001~012 (backend 트랙 위험 카탈로그)
- claude.ai/design `MASC Cockpit.html` `code-mode.js` mockup (사용자 image 첨부, 2026-04-30)
