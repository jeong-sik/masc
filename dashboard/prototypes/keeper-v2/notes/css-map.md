# CSS 맵 — keeper-v2/styles/

14개 파일로 분리. `Keeper Agent v2.html` head의 `<link>` 순서 = 아래 로드 순서(뒤가 앞을 덮어씀).

## 로드 순서

1. `colors_and_type.css` — DS 베이스 토큰(색·타입). 보통 안 건드림.
2. (Google Fonts: Space Grotesk)
3. `v2.css` — **메인.** 아래 "v2.css 안내" 참고.
4. `surfaces.css` — 비-keepers 화면들.
5. `dock.css` — Copilot 도크.
6. `craft.css` — 밀도·모션·스크롤바(오버라이드라 늦게 로드).
7. `inspector.css` — 턴 인스펙터 드로어.
8. `perf.css` — 성능/텔레메트리 위젯.
9. `fleet.css` — Monitor.
10. `logs.css` — 로그.
11. `keeper-config.css` — keeper 설정 드로어.
12. `fusion.css` — Fusion.
13. `memory.css` — 메모리 인스펙터.
14. `schedule.css` — 예약.
15. `runtime.css` — 런타임 편집기.

> 우선순위 주의: `craft.css`(밀도)가 `v2.css`보다 **뒤에** 온다. 같은 셀렉터 특이도면 craft가 이김 → v2에서 밀도 패딩을 덮으려면 특이도를 한 단계 올려라(예: `.v2-app[data-mobile] .ctx-drawer .ctx-scroll`).

## 파일별 책임

| 파일 | 담당 | 대표 셀렉터 |
|---|---|---|
| **v2.css** | 스킨 토큰 + 앱 셸 + 로스터 + 채팅 + 컴포저 + 컨텍스트 레일 + **모바일 전부** | `.v2-app .v2-top .v2-body .v2-nav .roster .kp-row .thread .bubble .composer .ctx-*` |
| surfaces.css | 개요·설정·승인·cockpit + 공통 | `.ov-* .set-* .ap-* .cp-* .nav-badge` |
| dock.css | Copilot 도크·FAB·상단 Chat | `.dock .dock-fab .topbar-copilot` |
| craft.css | 밀도(여유/균형/압축)·모션·스크롤바·reduced-motion | `[data-density] [data-motion] ::-webkit-scrollbar` |
| inspector.css | 턴 인스펙터 | `.turn-*` |
| perf.css | 성능 위젯 | `.perf-*` |
| fleet.css | Monitor | `.fl-*` |
| logs.css | 로그 | `.lg-*` |
| keeper-config.css | keeper 설정 드로어 | `.kcf-*` |
| fusion.css | Fusion | `.fus-*` |
| memory.css | 메모리 인스펙터 | `.mem-*` |
| schedule.css | 예약 | `.sch-*` |
| runtime.css | 런타임 편집기 | `.rt-*` |

## 셀렉터 프리픽스 → 파일 (역인덱스)

- `.ov-*` → surfaces · `.set-*` → surfaces · `.ap-*` → surfaces · `.cp-*` → surfaces
- `.fl-*` → fleet · `.fus-*` → fusion · `.sch-*` → schedule · `.rt-*` → runtime
- `.mem-*` → memory · `.kcf-*` → keeper-config · `.turn-*` → inspector · `.lg-*` → logs
- `.dock* .topbar-copilot` → dock
- 그 외 셸/채팅(`.ctx-* .kp-* .bubble .roster .composer .thread .v2-*`) → **v2.css**

## 자주 찾는 것 위치 (v2.css)

- **모바일 미디어쿼리** — `@media (max-width: 900px)` 블록. 하단 탭바, 단일 컬럼 master-detail, 칩 표시/숨김.
- **더보기 시트** — `.mnav-back .mnav-sheet .mnav-tile` (900 미디어쿼리 아래).
- **반응형 레일** — 데스크톱 컬럼은 JS(`app.jsx`)가 `gridTemplateColumns` 인라인으로 계산. ≤1180px에서 컨텍스트 레일을 드로어로 접는 로직도 `app.jsx`/`keepers.jsx`에 있음(CSS 아님).
- **컨텍스트 드로어** — `.ctx-overlay .ctx-drawer` (모바일·narrow 공용).
- **attention 칩** — `.v2-statchip .attn-wrap .attn-menu`.
- **스킨/Voltage 토큰** — 파일 최상단 `[data-skin="v2"]`, `[data-volt="blood|ice"]`, `[data-theme="paper"]`.

## 레이아웃은 CSS만으로 안 됨 (중요)

keepers 화면의 4-컬럼 폭(nav·로스터·채팅·컨텍스트)은 **`app.jsx`가 인라인 `gridTemplateColumns`로** 결정한다. CSS의 `.v2-body { grid-template-columns }`는 모바일 `!important` 가드용일 뿐. 폭/브레이크포인트 관련은 `app.jsx`(cols 계산 + `compactCtx`)와 `keepers.jsx`(레일/드로어 렌더 조건)를 봐라.
