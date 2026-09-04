---
rfc: "0412"
title: 키퍼 채팅은 하나의 정준 이벤트 로그와 그 projection이다
status: Draft
created: 2026-09-04
author: Kimi Code CLI
supersedes: []
superseded_by: null
related: ["0409"]
---

## 0. 한 줄 요약

키퍼 채팅의 라이브 스트림과 durable transcript를 하나의 정준 이벤트 로그로
통一하고, TUI(와 모든 소비자)는 그 로그의 projection만 그린다. reasoning은
로그에 영속화하고 "reasoning"으로 표현된 채 settle 후에도 남는다.
런타임별 손수 번역기 3개는 하나의 정규화 델타 계약으로 수렴한다.

**주의 — 이 RFC는 프라이버시 정책을 하나 뒤집는다.** reasoning 원문의
디스크 영속화는 `Withheld_thinking` posture(증거:
`docs/evidence/keeper-thinking-privacy-live-2026-08-17.json`)의 의식적
번복이다. 제목만으로는 보이지 않는 결정이므로 여기에 명시한다 (§3.1, §5).

## 1. 증상

오퍼레이터가 보고한 것:

1. 어떤 런타임은 스트리밍이 아예 안 된다.
2. 내용이 나오다가 프레임 단위로 통째로 사라졌다 다시 나타난다.
3. reasoning이 마치 대화인 것처럼 렌더링되다가 settle 순간 증발한다.
4. Ctrl-R(reasoning 표시 토글)이 제대로 동작하지 않고 런타임마다 다르다.
5. thinking/reasoning/tools가 엉켜 있고, 복잡도가 런타임 수만큼 곱해진다.
6. 런타임/프로바이더마다 대화 표시가 제멋대로다 — ollama cloud 계열
   (deepseek flash, minimax, glm flash …), antigravity, local qwen,
   glm coding, kimi coding 전체가 올바르게 돌아야 한다. 게다가 Memory
   journal 행까지 대화에 섞여 나와 시장판이다.

## 2. 원인 (조사 확정분)

### 2.1 한 대화가 세 개의 표현으로 존재한다

TUI는 같은 대화를 세 자료구조로 들고 렌더 시점에 병합한다:

- `msg_live` — 라이브 턴의 ordered trail (`bin/masc_tui_keeper_chat_transcript.ml:139-173`)
- `msg_history` — 이 세션에서 로컬 append한 row
- `msg_loaded` — durable transcript. **"replaced wholesale by a load rather
  than merged"** (`bin/masc_tui_types.ml:3046-3049`)

세 표현은 인터리빙 규칙이 각각 다르고, 전환은 전부 append가 아니라
replace다:

- **settle**: `settle_live_turn`이 `Trail_thinking`/`Trail_text`를 버리고
  (`bin/masc_tui.ml:2084-2085`) `msg_live <- None` (:2092). 라이브 뷰 전체가 한
  프레임에 사라지고 strict-decode reply row 하나로 대체된다. reasoning은
  여기서 영구 소실 — `bin/masc_tui_keeper_chat_transcript.ml:270-274` 주석이
  그대로 말한다:
  "Reasoning is the only part of a live turn the durable transcript does
  not keep."
- **transcript reload**: tick마다 history를 다시 읽고
  (`bin/masc_tui.ml:7016-7026`) `forget_session_rows_the_transcript_holds`가
  세션 row를 지운 뒤 `msg_loaded`를 통째로 교체 (`bin/masc_tui.ml:4700-4752,
  10002-10032`). physical-identity 메모 4단(`chat_rows_memo`
  `masc_tui_types.ml:3786`, `chat_timeline_ats_memo`/`visible_timeline_memo`/
  `layout_entries_memo` `masc_tui_render.ml:7501-8013`)이 전부 무효화되어
  pane 전체가 다시 레이아웃/렌더된다.
- **런타임 재시도**: `KEEPER_RUNTIME_ATTEMPT_STARTED`가 텍스트 버퍼 둘과
  진행 중 trail 노드를 지운다
  (`bin/masc_tui_keeper_chat_transcript.ml:1040-1053`).

### 2.2 reasoning 비영속은 현재 "기능"이다

- `keeper_chat_store`의 `chat_message`에는 reasoning 필드가 없고 append
  경로 어디도 받지 않는다. 쓰기 지점
  `server_routes_http_keeper_stream.ml:2076-2083`은 thinking을 넘기지
  않는다.
- `lib/keeper/keeper_agent_run_thinking_trajectory.ml:24-70`은 thinking
  텍스트를 의도적으로 버리고 `char_count` 등만 `Withheld_thinking`으로
  기록한다 (`trajectory.ml:161-180`의 `content_withheld: true`).
  `docs/evidence/keeper-thinking-privacy-live-2026-08-17.json`이 이
  posture를 문서화한다.

### 2.3 런타임 × 손수 번역기

`Runtime_execution.t` = Claude_code | Codex_app_server | Antigravity_cli |
Agent_core. CLI 3종은 각자 ~1000-1200라인 런타임 모듈 안에 80% 중복된
스트림 번역 콜백을 갖는다 (`keeper_claude_code_runtime.ml:158-255`,
`keeper_codex_runtime.ml:206-300`,
`keeper_antigravity_runtime.ml:283-380`). 셋 모두 턴 끝에 "스트리밍 못
받은 분량을 한 방에 토하는" buffered fallback을 갖고, harness가 델타를
안 주면 턴 내내 침묵하다 마지막에 전체가 뜬다. `emit_synthetic_events`
(`packages/agent_core/lib/llm_provider/streaming.ml:248-301`)가 있지만
프로덕션 호출자가 없다.

reasoning 자체도 런타임 시드 속성이다: `Runtime_inference.for_runtime`이
ThinkingDelta 존재 여부를 정하고(`keeper_turn_driver.ml:540-556`), MiniMax의
`ReasoningDetailsDelta`는 thinking lane에 접힌다
(`keeper_chat_agent_core_stream_bridge.ml:796-812`). 가시성 토글
(`msg_reasoning_visibility`)은 렌더 시점에만 적용되고(`masc_tui_render.ml:
7550-7559, 8382-8384`), 라이브 trail과 history `Reasoning` row에 서로 다른
규칙으로 작용한다 — 세 표현 문제의 증상이 토글에서 그대로 재현된다.

프로바이더 차원에서도 분산이다. Agent_core arm 아래로 ollama cloud 계열
(deepseek flash, minimax, glm flash …), local qwen, glm coding,
kimi coding 등 프로바이더마다 reasoning 표현(전용 델타, content 채널 내
포함 — 예: `feat(agent-core): separate reasoning a model embeds in its
content channel` #32840), tool-call 인코딩, 스트리밍 지원 여부가 다르고,
그 차이가 정규화되지 않은 채 표시까지 새어 나온다.

journal은 별 생산자 레인인데 timestamp로 대화에 섞인다: Memory OS journal
행이 `msg_entries`에 끼어들고(`masc_tui_types.ml:337-387`,
`masc_tui_message_layout.mli:43`), summary/full/hidden 토글
(`masc_tui_keys.ml:124`)이 따로 있다. 대화 + journal + 방송 + 다른 키퍼의
행이 시계열로 뒤섞이는 것이 "시장판"의 나머지 절반이다.

### 2.4 서버 측 사실

- 정준화의 재료는 좋다: `keeper_chat_events`(`lib/keeper/keeper_chat_events.ml:
  60-158`)는 단일 publisher의 완전한 순서 스트림이고, SSE projection
  (`lib/server/server_keeper_chat_agui_projection.ml`)은 pure fold라
  리플레이 가능하다.
- 빠진 것: 이벤트에 `seq`/`ts`/serde가 없고, 저널링이 없고(버스는 턴마다
  생성/폐기), durable 쪽은 손실형 JSONL row store다.
- **dashboard 함정**: `/chat/history` 페이로드에 새 `blocks[].t` variant를
  넣으면 valibot union이 row 전체를 조용히 드롭한다
  (`dashboard/src/api/schemas/keeper-chat-history.ts:136-233`, #28407
  전과). v1 스키마 불변이 전환기의 안전장치다.
- 다중 클라이언트: fan-out은 있으나 resume/catch-up이 없고, dashboard는
  chunk seq가 없어 dedup을 못 한다는 주석이 이미 있다
  (`dashboard/src/keeper-stream.ts:514-531`).
- 크기: history 응답은 이미 trace 블록이 지배한다(실측 2.51MB 중 1.65MB,
  22,296 스텝). reasoning full text 영속화는 이 축을 키우므로 읽기 창과
  별도 채널이 필요하다.

## 3. 설계

### 3.1 정준 이벤트 로그 (서버)

턴(operation)의 이벤트 스트림이 유일한 진실이다.

- 이벤트에 `seq`(operation 내 단조 증가)와 `ts`를 부착한다. 지금 ts는
  projection 시점 주입인데 로그에 새기면 리플레이가 정확해진다.
- `keeper_chat_event`의 버전드 JSON codec을 새로 쓴다 (envelope `"v":1`,
  additive 진화).
- 저널: `<base>/.masc/keeper_chat_events/<keeper>/<operation_id>.jsonl`.
  bridge 출력 직후 동기 append. atomicity는 기존 관용구
  (`Fs_compat.append_private_jsonl_durable_locked_result`, fsync +
  truncate-rollback, `fs_compat.ml:3439`)를 쓴다. 버스 용량 512라
  저널링은 라이브 경로를 블록하지 않는 선에서 동기로 간다.
- reasoning은 로그에 **full text로 영속화**한다. 이는
  `Withheld_thinking` 정책의 번복이며, 이 문서가 그 결정을 담는다.
  redaction 제거는 사용자가 별도 축으로 진행한다 — 로그는 "bridge가
  보낸 것"을 저장하므로 redaction이 제거되면 자동으로 raw가 저장된다.
  두 레이어(bridge `keeper_chat_agent_core_stream_bridge.ml:793,812`,
  projection edge) 모두 이 설계와 직교한다.

### 3.2 서빙: SSE와 history는 같은 문서의 projection

- SSE: 라이브 중엔 지금대로 push. 늦은 구독자/재접속은 로그 리플레이 +
  `?since_seq=` 커서. projection이 pure fold이므로 `initial`부터 재생하면
  같은 스트림이 재현된다.
- `GET /api/v1/keepers/:name/chat/events` (v2, 신설): 이벤트 로그 그대로,
  paged, reasoning 포함. **TUI는 스테이지 3에서 v2로 전환한다** — 그래야
  리로드 후에도 reasoning이 살아남는다.
- `/chat/history` (v1): **응답 바이트 불변**. 내부적으로 로그의
  projection으로 재구현하되 스키마는 그대로 — dashboard의 block-union
  드롭 함정을 건드리지 않는다.
- 기존 `keeper_chat_store` JSONL: 전환기 dual-write → v1 읽기가 로그
  기반으로 검증된 후 신규 쓰기 중단, 읽기 전용 보존.
- trace 블록(200 스텝 캡)은 로그에서 파생하는 요약 projection으로
  유지한다. reasoning full text는 v2 events 채널로만 간다 — v1 응답
  크기를 지키기 위해서다.

### 3.3 TUI: 단일 projection

- `msg_live`/`msg_history`/`msg_loaded` → **단일 ordered event log**
  (seq 키) + projection 하나. 라이브 델타와 history 응답이 같은 이벤트
  타입으로 들어온다.
- settle은 "표현 교체"가 아니라 **이벤트의 committed 플래그**다.
  리로드는 같은 문서의 continuation이라 replace-플리커가 구조적으로
  소멸한다.
- reasoning은 처음부터 **대화와 다른 카테고리**로 렌더한다 (dim +
  reasoning 레이블). settle 후에도 그대로 남는다 — "대화처럼 나오다가
  사라지는" 것의 양쪽 절반을 둘 다 고친다.
- Ctrl-R을 포함한 가시성 토글은 projection의 규칙 한 곳에만 존재한다.
  런타임 차이는 projection이 아니라 이벤트 유무로만 표현된다 (3.4).
- physical-identity 메모 4단 → seq 기반 구조적 공유/리비전 카운터로
  교체한다.
- 재시도(`ATTEMPT_STARTED`)는 버퍼 wipe 대신 "이 attempt는 superseded"
  마킹으로 바꾼다 — 읽던 내용이 사라지지 않는다.
- journal도 같은 로그의 **타입드 이벤트(자기 레인)**다. projection이
  "대화 레인 / reasoning 레인 / tool 레인 / journal 레인"을 규칙으로
  그리고, summary/full/hidden 토글은 그 규칙의 파라미터 하나다.
  timestamp 섞임으로 자리를 만드는 현행 방식은 폐기한다.

### 3.4 런타임/프로바이더 어댑터 수렴

- 3개 번역기를 하나의 정규화 델타 계약(사실상 이미
  `Agent_core.Types.sse_event`)로 수렴하고, 공통 80%를 단일 어댑터
  모듈로 올린다. harness 특이분만 얇은 훅으로 남긴다.
- **프로바이더 매트릭스 전체가 계약 아래로 들어온다**: ollama cloud
  계열(deepseek flash, minimax, glm flash …), antigravity, local qwen,
  glm coding, kimi coding. 프로바이더별 reasoning 표현(전용 델타 vs
  content 채널 내 포함), tool-call 인코딩, 스트리밍 지원 여부는 어댑터
  경계에서 정규화되고, 그 위(로그/projection/렌더)에는 프로바이더
  분기가 존재하지 않는다. 표시가 프로바이더마다 다르다는 것 자체가
  정규화 누수의 증거이므로, 매트릭스 × 동일 시나리오의 골든 스트림으로
  검증한다(§6).
- buffered fallback 정책 통一: 델타가 없는 런타임/시도는
  `emit_synthetic_events` 기반 합성 스트리밍으로 의사 델타를 만들어
  "턴 내내 침묵"을 없앤다.
- 런타임의 reasoning 지원 여부는 **선언된 capability**로 표면화한다
  (`Runtime_inference`가 이미 씨드). TUI는 "이 런타임은 reasoning을
  보내지 않는다"를 알 수 있어야 하고, Ctrl-R은 capability 없는 런타임에서
  조용히 아무것도 안 하는 대신 그 사실을 표시한다.

### 3.5 전환기 정합성: fail-open은 언제 fail-closed가 되는가

스테이지 1의 저널은 부차적 사본이라 fail-open이 맞다(append 실패는 로그만
남기고 턴은 계속). 그러나 스테이지 2에서 읽기 경로가 로그를 원천으로
서빙하는 순간, fail-open의 구멍은 곧 유실된 행이다. 전환은 이렇게 통제한다:

- **dual-write 구간의 어긋남은 정합성 감사자가 잡는다.** 스테이지 2의 첫
  태스크로, 턴 단위로 저널 이벤트와 `keeper_chat_store` row를 대조하는
  감사(이벤트 수, 터미널 outcome, assistant 텍스트 해시, 그리고 seq gap —
  hook 예외가 삼켜지면 seq는 소비되지만 저널 행은 없으므로 gap 자체가
  불일치 신호다)을 돌린다. 불일치는 `Log.Keeper.error` + 운영 메트릭으로
  표면화한다. 읽기 경로를 바꾸기 **전에** 돌아가야 한다.
- **fail-closed 전환점 = 첫 읽기 전환.** v1 history의 로그 기반 재구현이
  켜지는 그 PR에서 append 실패는 더 이상 삼키지 않는다 — 턴 에러 이벤트 +
  오퍼레이터 가시 신호로 격상한다. 즉 fail-open은 "로그가 부차 사본인
  기간"에만 유효한 한시적 posture다.
- **스테이지 2 진입 조건**: 감사자가 일정 soak 창(최소 수일의 실운영 턴)
  동안 미설명 불일치 0건을 보고할 것. 이 조건을 못 채우면 읽기 전환을
  미룬다.

### 3.6 god 파일 분리

채팅 수명주기(queue → dispatch → stream → settle → reload)와 렌더링을
`masc_tui.ml`(16.9k)/`masc_tui_render.ml`(16.4k)에서 분리한다. 단일
이벤트 로그가 생긴 뒤에야 경계가 자연스럽다 — 순서상 마지막 스테이지.

## 4. 단계

각 스테이지는 독립 PR 체인이다.

1. **정준 로그**: codec + seq/ts + 저널 + dual-write. 읽기 경로 불변.
2. **서빙 전환**: 정합성 감사자(dual-write 대조, §3.5) → soak 통과 확인
   → SSE since_seq/리플레이, v2 events 엔드포인트, v1의 로그 기반 재구현
   (바이트 호환 검증 — 이 시점에 저널은 fail-closed로 전환), reasoning의
   trajectory 대체. retention 스윕은 이 스테이지의 컷오버 **전에** 땅에
   닿아 있어야 한다(§5).
3. **TUI 단일 projection**: 세 표현 통一, 토글 단일화, 메모 교체,
   attempt superseded.
4. **런타임 수렴**: 어댑터 통一, 합성 스트리밍, capability 선언.
5. **god 파일 분리**.

## 5. 비목표 / 리스크

- redaction 제거 — 별도 축(사용자 진행 예정). 이 설계는 redaction 유무와
  직교하게 "bridge 출력을 저장"한다.
- v1 history 스키마 변경 — 하지 않는다.
- 프라이버시 posture 번복(3.1)은 의식적 결정이다. 로그 파일은 기존 채팅
  스토어와 같은 base-path 하위라 외부 노출 면이 새로 생기지는 않지만,
  reasoning full text가 디스크에 남는다는 점은 변화다.
- 크기: reasoning 영속화로 로그가 커진다. 읽기 창(v1의 4MiB 캡에
  상응하는 v2 페이징)은 스테이지 2 범위로 두되, **retention은 스테이지
  2로 온전히 미루지 않는다** — 이 장비의 데이터 볼륨이 이미 3.5Ti/3.6Ti
  수준이고 history 응답의 1.65MB/2.51MB가 trace인 현실에서 "한 스테이지
  유예"의 값이 크다. `dated_jsonl` 패턴의 보존 기간 스윕(예: N일 경과
  저널 삭제)을 스테이지 1 직후의 소형 후속 PR로 땅에 내리고, 스테이지 2
  컷오버의 선행 조건으로 둔다.
- 버스 backpressure: 저널 append가 라이브를 블록하지 않아야 한다 —
  스테이지 1의 성능 검증 항목.

## 6. 검증

- 스테이지 1: 로그 리플레이 == 라이브 스트림 바이트 동등 (골든 테스트).
- 스테이지 2: v1 응답 바이트 회귀 테스트(기존 fixture), dashboard
  계약 스모크(`scripts/harness_dashboard_keeper_chat_contract_smoke.sh`),
  그리고 컷오버 게이트 — 정합성 감사자의 soak 창 미설명 불일치 0건(§3.5).
- 스테이지 3: 기존 TUI 테스트 스위트(projection/transcript/history/
  timeline ~9.8k 라인)는 세 표현 시대에 쓰였으므로 일부는 현행 병합
  동작을 고정하고 있을 것이다. "그대로 통과"를 기대하지 않는다 —
  병합 동작을 핀한 테스트를 식별하고 갈아엎을 분량을 스테이지 착수 시
  산정하는 것이 첫 태스크다. 그 위에서 settle/리로드/재시도 시나리오의
  "행 소멸 없음" 신규 핀을 추가한다.
- 스테이지 4: 런타임별 동일 시나리오 스트림 골든(합성 델타 포함).
