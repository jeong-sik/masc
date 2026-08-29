# 정합 · 숙청 계획 — 소스 기준 (2026-06-30 재작성)

> 기준 = `grounding.md`(README Features 상태표 + navigation.ts IA + 실 config 키).
> 원칙: **실제 와이어링되는 것만 남긴다.** 아래는 제안 — 컷 여부는 사용자가 지정.
> ⚠️ 이전 버전의 "설정 16→10 병합" 제안은 **철회**: 16개가 `SETTINGS_ROUTE_SECTION_IDS`와 정확히 일치(소스 정답). 병합 금지.

---

## A. ☠️ 죽은/안 읽히는 설정 — 제거 또는 "dead" 배지

| 항목 | 소스 근거 | 처리 |
|---|---|---|
| `[autonomous] concurrency` | README: "dead setting not read by the code" | ✅ UI에 애초에 없음 — lifecycle은 `autoboot_max ([bootstrap])`만 사용. 처리 불필요 |
| `tool_policy.toml` 내용 의존 | README: "contents are not consumed at runtime" (config-root 마커) | ✅ policy 섹션 문구 정정 + `legacy` 점선 노트: 도구 접근=registry/descriptor, tool_policy=미사용 마커 |

→ 확인: lifecycle/policy 섹션 실제 UI 점검 후 반영.

## B. 🟥 상태 정직성 — 실제 ❌/🟡인데 mock이 '동작'처럼 보이는 것

"디자인 에셋이 소스와 더 잘 맞게" = 와이어링 상태를 **눈에 보이게**.

| Surface/기능 | 실제 | mock 현재 | 제안 |
|---|:--:|---|---|
| IDE (code) | ❌ 실사용 불가 | rail에 일반 surface로 노출 | surface에 `실험·미검증` 배지 + 빈/제한 상태 |
| Provider Failover | ❌ 미구현(수동 재시작) | routing에 `media_failover` 레인 노출 | "자동 failover 미구현 — 수동" 주석 (이미 `media_failover=[]` 표기 있음 → 문구 강화) |
| Fusion JoJ | 🟡 live config선 fail-closed | 완전 동작 JoJ run 샘플 표시 | "데모 데이터 · live JoJ는 judges 패널 없어 fail-closed" 주석 |
| Goal+Task 자동 스케줄 | ❌ 관측용 | schedule surface | "자동 turn 구동 안 함 — 관측/수동" 주석 |
| Multi-Channel | 🟡 Discord만 live | connectors에 4채널 | slack/telegram = `sidecar 필요·미가동` 상태 (이미 일부 반영) |

→ 공통 패턴: surface 헤더에 상태 배지(`✅/🟡/❌`) 컴포넌트 1개 도입해 일관 적용.

## C. 🧭 IA 정합 — 정식 rail과 어긋남

**정식(`V2_PRIMARY_SURFACE_IDS`)**: overview · work · keepers · board · schedule · approvals · fusion · IDE · connectors · settings · logs. Monitor/Command/Lab은 **rail 밖**.

**mock rail 현재**: overview · keepers · monitor · work · approvals · schedule · board · fusion · logs · ide · connectors (+settings footer).

불일치:
1. **순서**가 정식과 다름 → 정식 순서로 재배열 제안.
2. **Monitor를 rail로 승격** — 정식은 rail 밖(operator가 route로 접근). → rail에서 빼고 secondary 진입(또는 의도적 deviation으로 문서화).
3. **Command/Lab surface 부재** — 정식엔 rail 밖 surface로 존재(operations, tools/harness/performance/memory-os). mock엔 없음 → 누락(숙청 아님). 추가 여부 사용자 결정.

→ 제안: rail을 정식 순서로 맞추고, Monitor/Command/Lab은 "secondary surfaces" 묶음으로 분리.

## D. ✂️ 코드/파일 중복 — 숙청 후보

| 대상 | 사유 | 처리 |
|---|---|---|
| `keeper-v2/fleet.jsx`의 `FL_ATTN` | 정식 `ATTENTION`과 중복 | ✅ 이미 제거 |
| 하드코딩 `v0.19.45` | 화면별 불일치 | ✅ 상수화 |
| 루트 `fleet.jsx` (프로젝트 루트) | `keeper-v2/fleet.jsx`와 중복 · HTML 미참조 | ✅ 삭제(2026-07-11) |
| 루트 `MASC Keeper Agent (standalone).html` | 구 번들 산출물 · 최신 아님 | ✅ 삭제(2026-07-11) |
| `keeper-v2/MASC Keeper Agent (standalone).html` | 구 번들(이름 이전) · superseded | ✅ 삭제(2026-07-11) |
| `keeper-v2/Keeper Agent v2 (standalone).html` | 번들 산출물 · 금일 와이어링 이전 = stale | ✅ 재생성(2026-07-11) |
| 루트 `Canvas.dc.html` + `support.js` + `.thumbnail` | keeper-v2 와 무관한 빈 design-canvas 스캐폴드 | ⏳ 사용자 확인 대기(무관 스크래치일 수 있음) |

## E. ✅ 이미 소스 충실 — 유지 (숙청 X)

- 설정 16섹션 = 정답.
- 가짜 도구명(`masc_start/handoff/compact/...`) 이미 제거됨 → **재유입 금지** 가드.
- TOOL_GROUPS / LAST_TURN_SAFE / EXEC_GUARD = tool_policy 구조 충실.
- Fusion 위상=judge-array shape 기반 렌더(이름 하드코딩 안 함) = RFC 충실.
- sandbox_profile / network_mode = 실 키.
- Keeper 12-state machine 충실.

---

## F. 작업 순서 (컷 확정 후)
1. 상태 배지 컴포넌트 도입(B) — IDE/failover/JoJ/schedule/connectors.
2. 죽은 설정 처리(A).
3. IA rail 정합(C).
4. 알람 실동작 + 반응형 문자열 + 스레드 상세(기존 UX 정비).
5. 파일 중복 정리(D) — 사용자 컷 후.

---

## G. ✅ 2026-07-15 적용 (소스 갱신 반영 — 사용자 컷 승인)

- **Gate 재설계**: approvals surface → **Gate**(3 비계층 모드: Always Allow / LLM Auto Judge / HITL). risk-tier Manual/Auto_low_risk + SoD 프레이밍 제거. `sev`(bad/warn/info) 전면 제거(data/approvals/overview). governance_approval 가드 라벨 → Gate 라우팅. rail·palette·composer·logs·keepers·organisms 라벨 `승인`→`Gate`.
- **risk_class 전면 제거**: schedule-data(SCHEDULES/SIGNALS/KEEPER_BG) + schedule.jsx(SchRisk/riskCls/SCHED_RISK) 삭제.
- **Provider Failover 🟡→❌**: ops-data(RT_ROTATION/ROTATION_EVENTS) · fleet.jsx(AsideRotation) · runtime-editor([runtime.failover] 섹션·toml) 를 "자동 미구현·수동 재시작·턴 내 transient 재시도만" 으로 재프레이밍. capacity_backpressure = 관측 신호(pause 아님).
- **Fleet-wide stop → 관측 전용**: FleetLanes admission 밴드에 "관측 전용" 노트, backpressure = 관측.
- **Settings 16→12**: SET_SECTIONS/SET_GROUPS 를 SETTINGS_ROUTE_SECTION_IDS 12개로 정렬(lifecycle/sandbox/gate 제거, mcp/display 추가). 제거된 섹션 render 블록은 orphan(inert)로 잔존.
- **max_active_keepers dead**: UI 미참조 확인 · autoboot_max 만 유지. FL_VERSION v0.19.45→v0.20.1.
- **Discord in-process**: CONNECTORS 에 transport 필드 + Discord in-process WSS 게이트웨이 노트. 게이트 설정 버튼이 제거된 `gate` 섹션으로 가던 문제 수정.
- **Deck**: 승인 슬라이드→Gate 3모드, 페일오버 슬라이드→❌ 수동, 기능 그리드 갱신.

## H. ✅ 2026-08-06 적용 (소스 cf68b4fc · 0.21.2 기준 — 전부 적용 승인)

근거 정리 = `notes/grounding-2026-08.md`.

**추가**
- **Monitor 섹션 탭 신설**: Keeper Fleet · **Internal Agents**(monitoring?section=internal-agents) · **감사 무결성**(lab?section=audit-integrity) · **비용 원장**(monitoring?section=runtime&view=cost). mock 은 Lab surface 를 따로 두지 않으므로 Monitor 에 모으고 각 패널에 정식 라우트를 표기. 새 파일 `internal-agents.jsx` + `styles/monitor.css`.
- Internal Agents = Exact lane(librarian_exact · hitl_auto_judge · board_attention_exact) + verification + fusion run, 필터 5종 · 펼치면 input/result 증거 · verification 은 도구 disposition/ms/IO.
- 감사 무결성 = keeper별 hash-chain verify(엔트리 수 · 정상/실패 · 첫 단절 index · 상세).
- 비용 원장 = date-split `.masc/costs/YYYY-MM/DD.jsonl`, 정확 신원 병합, `state`(구 status), 다중 모델 집계엔 model 미표기, dup/malformed 진단.
- Settings paths 에 **상태 스토어 레이아웃** 블록(root-state.json · costs · telemetry · gate · keepers · audit-approvals) + FD 압박 오버라이드 단일화 고지.
- Settings runtime 에 `turn.stream_idle_timeout_sec` floor 600s · 모델 카탈로그(agent-core-models-overlay.toml / MASC_MODEL_CATALOG).
- 프롬프트북: 챕터별 `rev` (본문+변수계약 SHA256) + override envelope 설명(contract drift = fail-closed).

**제거 · 재프레이밍**
- **context occupancy → not_observed**: 컨텍스트 레일 게이지·%·compact 임계선 마크 삭제 → "마지막 턴 input / window (provider 보고)" + not_observed 고지. Fleet 열 머리 `컨텍스트`→`마지막 턴 usage`, aside 압박 카드도 동일. keeper-config health 의 ctxUtil 삭제.
- **컴팩션 정책 오써링 제거**: keeper-config 의 자동 컴팩션·임계값·비율 게이트, settings 의 자동 컴팩션 토글/슬라이더 삭제. 남은 것은 `Compaction_started` 관측 + 수동 실행. 스냅샷 빈 상태 문구도 임계치→overflow/owner-lane 으로 교체.
- **핸드오프**: auto handoff 임계치 삭제(+ `Handoff_triggered`/`handoff_rate` 제거 고지). HandingOff FSM 상태와 task handoff_context 는 유지.
- **keeper.base 상속 제거**: 프롬프트 조립 레이어 `공유 베이스(runtime.toml [keeper.base])` → **월드 프롬프트 `prompts/keeper.world.md`**, 매니페스트는 personas/{persona}/profile.json overlay 표기.
- **Memory OS 주기 consolidation 제거**: 메모리 스토어에 "GC = valid_until 지난 행만 · semantic supersession/tombstone 없음" 고지.
- 임계치 기반 알림·로그·스케줄 픽션 정리: 알람 이벤트 `컨텍스트 임계치 초과`→`컨텍스트 오버플로우 · 압축`, notify 슬라이더 → 이벤트 기반, COMPACTIONS 트리거 문구, ATTENTION/overview 문구, schedule 의 compact.sweep(threshold_pct) → keeper.wake.
- FL_VERSION v0.20.1 → **v0.21.2**.
- 파일: `Keeper Agent v3.html` 신규(구 v2 스냅샷 = `Keeper Agent v2 (standalone).html`). 덱은 "최근 병합" 슬라이드를 신규 4종으로 교체.

## H. ✅ 2026-08-18 적용 (소스 v0.23.0 반영 — 전체 컷 승인)

- **FL_VERSION v0.21.2 → v0.23.0.**
- **턴 배칭**: 턴 워터폴에 「이 턴이 함께 처리한 자극 N건」 스트립(즉시/보통), 레인·큐에 "대기 3건 ≠ 턴 3회" 고지.
- **결과 자동 전달 제거**: 예약 화면 상단 고지 + "결과 전달 화면은 제거됨" 명시.
- **워크스페이스 메시지**: 대기 소스에 `workspace_message` 추가 (post_id `workspace-message:<request_id>` · message_from · urgency=immediate).
- **발화 / 기록**: `KVM.Broadcast` 에 `audience` prop — 기록은 "대화창에는 뜨지 않음" 표기.
- **Fleet Messages**: 프롬프트북에 「받은 메시지(Pending Messages)」·「플릿 메시지(Fleet Messages)」 챕터 신설(조건부 — pbFill 에서 keeper별로 채움), 설정·런타임에 `keeper.fleet.messages.max` (기본 10 · 0 = 끔).
- **운영자 언어 컷**: 레인·큐 / 턴 워터폴 / Fleet 헤더의 배선 이름(필드명·enum·producer·trace id·WFQ·capacity_backpressure·p95·not_observed)은 화면에서 빼고 「기술 상세」 토글 또는 툴팁으로만 노출. 레인 이름·상태값·오류 사유 전부 한국어.
- 파일: `lanes.jsx`(스윔레인·파이프라인·대기 나이·드레인), `journey.jsx`(턴 워터폴·라이브 이벤트), `styles/lanes.css`, `fleet.jsx`, `schedule.jsx`, `molecules.jsx`, `messages.jsx`, `prompt-book-data.jsx`, `prompt-book.jsx`, `settings.jsx`. 덱은 슬라이드 08 「최근 병합」 9종 교체 + 3열.
