# Keeper v2 디자인 델타 오디트 — 2026-07-03

소스: claude.ai/design 프로젝트 export `v2 (28)` (2026-07-03 01:47 다운로드, `v2 (27)`과 keeper-v2 동일 → 최신 상태로 간주).
비교 대상: `dashboard/src` @ main 62b8535f3c6.
Baseline: `docs/design/keeper-v2-standalone-gap-current.md` (2026-06-21) + vendored CSS (2026-06-28).
방법: 10개 영역 병렬 오디트 — 각 델타를 dashboard_state(missing/partial/present) × backing(backed/unbacked) × 권고(implement/defer/skip)로 판정. backing은 masc lib/ 실코드로 검증.

## 판정 합계

106개 델타: implement 35 / defer 21 / skip 50.

## Implement (backed 확인, 표면별)

### Settings (이 PR + 후속)
- **Repositories 섹션** — 이 PR(#23041)에서 구현. `GET/POST/DELETE /api/v1/repositories`.
- Routing 독립 섹션 [S] — `POST /api/v1/runtime/config/routing`이 default 레인 포함 전 레인 지원. 현재 default는 read-only 표시(settings-surface.ts:1100-1104)라 쓰기 셀렉터로 승격 가능.
- runtime.default 쓰기 셀렉터 [S] — 위와 동일 API.
- IA 5그룹 재편 부분 채택 [S] — 프론트 전용. 단 디자인이 nav에서 뺀 mcp/display는 live-backed 동작 섹션이므로 **유지** (디자인 측 확인 필요 — grounding.md 06-30판은 '16섹션 병합 금지'라고 서술, export 최신판은 13섹션. 노트가 export보다 구버전).

### Fusion (fusion.jsx/fusion-data.jsx/fusion.css)
- 활성 [fusion] 정책 푸터 [M], JoJ 1차 심판 카드 확장 [M], 파이프라인 JoJ/refine 분기 [S], meta reconcile 격리 배너 [S], topology 칩+행 태그 [S], resolved_answer 클램프+전문 펼치기 [S].

### 메모리/턴 인스펙터 (memory.jsx/memory.css/turn-inspector.jsx)
- memory.css 94줄 동기화 [S], TTL/current pill(.mem-ttl, salience bar 대체 — RFC-0247) [S], legend '메모리' 태그 [S], 에피소드 turn 범위 [M], 전체 스코프 category 분포 바 [S] + 최근 확인 사실 [S] + keeper 행 클릭→개별 보기 [S], 턴 인스펙터 namespace 잔재 제거('# world snapshot') [S].

### Fleet/Logs/Dock (fleet.jsx/logs.jsx/dock.jsx + css)
- Fleet aside attention 목록 [S], 반응형 컬럼 shedding(@1320/@720) [S], Logs 모바일 카드(@640) [S], fl-sandbox 'worktree 격리' 배지 [S], 모델 ID 전체 표기(claude- prefix 절단 제거) [S], Dock ns 표기 제거 [S].
- 주의: monitoring 표면은 shell의 "no own header" 목록 — 리빌드 시 중복 헤더 금지 (V2-RESKIN-PROGRESS.md의 revert 교훈).

### Work/Schedule (work.jsx/schedule.jsx)
- Task lineage 타임라인 [M], 칸반 카드→goal 점프 [S], Schedule 우측 운영 aside [M], 예약 액션 결과 배너 [S], 거부 사유 인라인 [S], 예약 pending nav 배지+탑바 칩 [S].
- 주의: Schedule 취소(cancel)는 unbacked → defer. mutation 구현 전 개별 API 존재 재검증 필수.

### Runtime 편집기
- 라우팅 레인 JSON capability 검증(⚠ 경고) [S], 모델 capability 칩 [M], 바인딩 가격 표시 [S], keeper별 capability 카드 [M].

### Prompt Book (신규 표면, prompts 섹션 내장)
- 9-block 조립 뷰 [M], 프롬프트 라이브러리 catalog [S]. Full Text 뷰/{{var}} 치환/변수 출처 주석은 unbacked → defer (조립 스냅샷 API 필요).

### Keeper 설정 드로어
- 조립 추적(.kasm) [M], Goals picker 검색 [S], per-tool 토글 그리드 [M].

## Defer (백엔드 계약 선행 필요 — 대표)

- Settings account/lifecycle/sandbox 섹션 (auth 세션/lifecycle knob/namespace 기본값 저장소 부재).
- Prompt Book full-text/치환 뷰 (주입 스냅샷 API), keeper effort 세그 mutation, persona 편집, 알림 엔진 wiring, 압축 3열 diff, autoboot_max·컴팩션 임계치 (raw TOML 외 scalar patch 경로 없음 — UX상 전용 patch 권장).

## 디자인 측 정정 필요 (역피드백)

1. **sandbox_profile 값 drift**: 디자인 `local/container/none` vs 실제 closed variant `local|docker` (keeper_sandbox_config.mli). network_mode도 `off/allow` vs 실제 `none|host`.
2. **grounding.md 구버전**: 06-30판 "Settings 16섹션 완전 일치·병합 금지" vs export 13섹션 재편 (mcp/policy/ide/display가 nav에서 빠지고 render 블록 orphan). mcp/display는 dashboard에서 live-backed이므로 삭제 반대.
3. Gate 섹션 mutation(트리거 정책/채널 토글/base URL)은 전부 게이트웨이 기동 시 1회 설정 — 런타임 setter 없음.

## 전체 findings 원본

세션 워크플로 journal(wf_e33d84b3-5a0) — 106항목 전체 JSON. 요약 표는 이 문서, 근거 인용은 각 슬라이스 PR 본문에 기재.
