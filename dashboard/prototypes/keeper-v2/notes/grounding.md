# Grounding — jeong-sik/masc@main (refreshed 2026-08-18 · 소스 v0.23.0)

> 디자인 에셋이 소스와 **더 잘 맞도록** 잡은 단일 진실원천(SSOT).
> 원칙: **실제 와이어링되는 것만 살린다.** 상태 범례 = README Features 표.
> ✅ working now · 🟡 partial · ❌ not working(실사용 불가)
>
> **2026-08-18 갱신 요약** (소스 v0.21.2 → **v0.23.0**):
> - **자율 턴 결과 자동 전달 제거 (0.22.0, breaking)**: 자율 턴의 최종 텍스트가 깨운 채널로 자동 전달되지 않음. continuation-delivery 계열 + 예약 "결과 전달" 대시보드 화면 제거. keeper 발화는 speech 도구(`keeper_surface_post` · 커넥터 포스트)로만 나감.
> - **턴 배칭 (0.22.0, RFC-0377)**: 한 턴이 **한 대화의 밀린 자극을 묶어서** 소비 — 자극 1건 = 턴 1회가 아님. 대기 건수로 턴 횟수를 추정하면 안 됨.
> - **Agent Core 내재화 (0.22.0)**: 실행 엔진이 `masc.agent_core` 로 편입 — 런타임/텔레메트리/저장 필드 이름이 Agent Core 계약을 직접 사용(`agent_core_turn_ordinal` 등).
> - **Fleet Messages 계층 (0.23.0)**: 다른 keeper 발화 최신 N건이 상시 컨텍스트 (`keeper.fleet.messages.max`, 기본 10 · 0이면 끔). `Pending Messages` 는 나를 멘션한 것 + Owner 작성만 — 두 칸은 겹치지 않음.
> - **워크스페이스 메시지 큐 진입 (0.23.0)**: keeper 를 호명한 메시지가 `Keeper_event_queue.Workspace_message` 로 정식 진입(request id 중복 제거) + `keeper_chat_appended` SSE. keeper 발화 투영은 큐 항목도 wake 도 만들지 않음.
> - **브로드캐스트 발화/기록 분리 (0.23.0)**: `audience` 필수 — 발화 5종(masc_broadcast · keeper_broadcast · gRPC Broadcast · 대시보드 라우트 · 운영자 액션)만 대화창에 뜨고, 기록 9종(태스크·세션·워크스페이스 init)은 어디에도 안 뜸.
> - **승인 해결 우선 전달 (0.23.0)**: 승인 게이트에서 멈춘 턴이 큐 순서를 앞질러 승인으로 재개 — `hitl_resolution` 누락 버그 수정. `Agent (Self)` 배지 제거, LSP 호출/인라인 디스패처 제거.
>
> **2026-07-15 갱신 요약** (소스가 2026-06-30 이후 이동):
> - **Gate 재설계**: governance pipeline·risk taxonomy·deny 바닥·command/tool-name 휴리스틱·global admission blocker·failure-derived pause 전부 **제거**. 외부 효과는 세 **비계층** 처분으로 수렴 — **Always Allow · LLM Auto Judge · HITL**(nonblocking, exact one-use). rail 라벨 `승인`→**Gate**.
> - **Provider Failover 🟡→❌**: 자동 페일오버 미구현, provider 실패 시 runtime.toml 수정+재시작. 턴 내 transient 재시도만 자동.
> - **`[bootstrap] max_active_keepers` 도 dead** (README): `autoboot_max` 만 autoboot 제어. global active-keeper cap 없음.
> - **Settings 16→12**: SETTINGS_ROUTE_SECTION_IDS = account·runtime·routing·runtimes·paths·mcp·repositories·notify·prompts·fusion·logs·display. (제거: policy·lifecycle·sandbox·ide·gate)
> - **Registry** rail primary surface 추가 · **Discord = in-process WSS 게이트웨이**(Python sidecar 삭제).
> - risk_class/severity 는 디자인에서 제거(사용자 결정) · admission/backpressure = 관측 전용.

---

## 1. 기능 와이어링 상태 (README Features — 디자인 판단 기준)

| 기능 | 상태 | 디자인에서 의미 |
|---|:--:|---|
| Keepers (resident agents) | ✅ | 정상 표현 OK. autoboot on server start, state→disk |
| Board (posts/comments/votes) | ✅ | 정상 표현 OK |
| Dashboard SPA | ✅ | 우리 mock의 대상 |
| HITL / Gate | 🟡 | 큐 동작. **비계층 3모드**(Always Allow · LLM Auto Judge · HITL). HITL nonblocking(요청 영속·레인 wake). governance/risk 계층 제거. 보안경계 아님 |
| Sandbox (Docker) | 🟡 | docker run 실제 호출하나 local fallback 존재 → 경계 아님 |
| Goal + Task | 🟡 | CRUD/transition/verify 동작. **자동 스케줄링 없음**(관측용) |
| Multi-Runtime | 🟡 | `runtime.toml` keeper별 provider×model 라우팅 |
| Fusion (+JoJ) | 🟡 | simple/refine/conditional 동작. **JoJ는 live config에 judges 패널 없어 fail-closed 에러**. 레지스트리 in-memory(재시작 시 소실) |
| Multi-Channel | 🟡 | gate 메시지로 turn 시작/응답. **Discord만 live**. Slack/Telegram sidecar 필요 |
| OpenTelemetry | 🟡 | OTLP HTTP + GenAI semconv 동작. 다수 신호 미수집 |
| Provider Failover | ❌ | **자동 페일오버 미구현** — provider 실패 시 runtime.toml 수정 + 서버 재시작. 턴 내 transient 재시도(0.19.56 · #23383/#23392 로 무한루프 캡)만 자동. capacity_backpressure = 관측 신호(pause 아님) |
| CODE / IDE (observational) | ❌ | LSP proxy·overlay·shell은 있으나 flow 미검증 → **실사용 불가** |
| TUI | ❌ | binary 존재하나 CJK/스트리밍/렌더 갭으로 실사용 불가 (mock 범위 밖) |

---

## 2. 정식 IA — dashboard/src/config/navigation.ts

**Primary rail (`V2_PRIMARY_SURFACE_IDS`)** — 2026-07 순서/구성 (이게 정답):
`overview · keepers · registry · monitoring(Monitor) · workspace(Work) · approvals(Gate) · schedule · board · fusion · logs · code(IDE) · connectors · settings`
→ navigation.ts 주석이 명시: 이 순서는 2026-07 keeper-v2 export rail 을 미러링(Monitor 재진입 + Logs를 IDE 앞으로). **Registry** 가 primary surface 로 추가됨. approvals rail 라벨 = **Gate**.

**Rail 밖 surface**: `command(Command)`, `lab(Lab)`. `cockpit`은 `hidden:true`(UI 비노출). (Monitor 는 이제 rail 안)

**Sectionless surfaces**: overview, logs, settings, keepers, registry, board, schedule, approvals(Gate), fusion (서브섹션 없음 — 단일 탭).

**섹션 있는 surface**:
- monitoring: `agents(Keeper Fleet)` · `fleet-health(Tool Monitor)` · `runtime(Runtime)` · `observatory`. (hidden: transport-health, feature-health, journey, cognition)
- command: `operations(Actions)` 단일.
- connectors: `connector-status(All)` 단일 — 내부 picker로 discord/imessage/slack/telegram 전환(2026-04-30 병합).
- workspace: `work · planning(Plans & Goals) · repositories · verification`. (hidden: board, sub-boards, moderation)
- lab: `tools · harness(Safety Harness) · performance · memory-subsystems(Memory OS) · keeper-memory-health(키퍼 메모리 상태)`.
- code: `ide-shell(Code IDE)` 단일.

**Settings 섹션 (`SETTINGS_ROUTE_SECTION_IDS`, 2026-07 · 12개 — 정확히 정답)**:
`account · runtime · routing · runtimes · paths · mcp · repositories · notify · prompts · fusion · logs · display`
→ mock 도 12개로 정렬. 소스에서 제거된 섹션: **policy**(tool_policy 미사용) · **lifecycle** · **sandbox**(→ keeper별/레지스트리) · **ide** · **gate**(→ Gate 상위 surface). 렌더 블록은 orphan 상태로 남아있으나 nav 미노출(inert).

---

## 3. 설정/구성 진실 — 실제 와이어링되는 키

**runtime.toml** (서버 부팅 필수: 없으면 `refusing to boot` exit 1)
- `[runtime].default = "<provider>.<model>"` — 필수
- `[runtime.assignments]` `keeper = "provider.model"` — keeper별 override (선택)
- 라우팅 레인: `[runtime]` `default / librarian / cross_verifier / media_failover`
- `[bootstrap] autoboot_max` — **서버 부팅 시 autoboot 할 keeper 수 제어** (유일한 살아있는 fleet-크기 키)
- `[fusion]` 패널/심판 프리셋

**keepers/<name>.toml**: `goal`, `instructions`, `persona_name`, `sandbox_profile`(`docker`|`local`), `active_goal_ids`
- 모델/런타임은 **여기 없음** → runtime.toml에서 지정
- sandbox: `network_mode`(기본 `inherit`, `none` 가능)

**repo 작업 시에만**: `repositories.toml`, `keeper_repo_mappings.toml`, `credentials.toml`

**HITL**: tool-dispatch 경계서 강제. bypass = `MASC_DISABLE_HITL=true`(기본 false) 또는 keeper `always_approve` 규칙.

---

## 4. ☠️ DEAD / 안 읽히는 설정 (소스가 명시)

- `[autonomous] concurrency` — **dead code, 코드가 안 읽음**. → 설정 UI에 있으면 제거/"dead" 표기.
- `[bootstrap] max_active_keepers` — **dead** (README 2026-07: 이 키도 안 읽힘). fleet 크기는 `autoboot_max` 만 제어 · global active-keeper cap 없음.
- `tool_policy.toml` 내용 — config-root 마커일 뿐 **런타임에서 안 읽음**(legacy). 도구 접근은 registry/descriptor 기반. (settings `policy` 섹션 소스에서 제거됨)
- 거버넌스 파이프라인 / risk taxonomy / 무조건 deny 바닥 / command-name authorization heuristic / fleet-wide stop condition / failure-derived pause — 전부 **제거**(Unreleased changelog). cost/token/turn/FD/disk/provider-health/queue-depth 는 관측으로만 남음.

## 5. 가짜(존재하지 않던) 식별자 — 이미 mock에서 제거됨, 재유입 금지
`masc_start`(README엔 onboarding 언급되나 레지스트리 도구로는) · `masc_handoff` · `masc_compact` · `masc_amplitude_query` · `masc_trace_window` · `masc_board_metrics` · `masc_git_blame` — registry에 없던 이름.

## 6. Keeper 상태 머신 (12)
`Offline · Running · Failing · Overflowed · Compacting · HandingOff · Draining · Paused · Stopped · Crashed · Restarting · Dead`. "한 keeper는 동시 1 turn"; 병렬성은 keeper 多.
