---
rfc: "context-overflow-semantic-recovery"
title: "ContextOverflow 이후 원본을 보존하는 의미 기반 전송 복구"
status: Draft
created: 2026-09-08
updated: 2026-09-08
author: codex
supersedes: []
superseded_by: null
related: ["tool-results-age-out-of-context"]
implementation_prs: []
---

# ContextOverflow 이후 원본을 보존하는 의미 기반 전송 복구

## 문제와 확인 범위

Keeper의 모든 선언 runtime 후보가 typed `ContextOverflow`를 반환하면 현재 턴은
실패하지만 Keeper는 살아 있다. 다음 정상 cadence에서 같은 pending stimulus를
다시 선택할 수 있다. 원본 checkpoint는 그대로 복원되므로 이미 수용할 수 없던
대화가 다음 요청에도 들어갈 수 있다. 시각·관측 문구가 변하므로 매번 wire bytes가
동일하다는 뜻은 아니다. **실패한 입력을 의미 있게 재구성하는 연결이 없다.**

이 문서는 main 기반의 구현 제안이다. optional caller cap 변경
[#34163](https://github.com/jeong-sik/masc/pull/34163)과 seed 정책 변경
[#34171](https://github.com/jeong-sik/masc/pull/34171)은 같은 프로그램의 앞선 작업이며
기술적 필수 의존성은 아니다. 명시적인 byte cap을 가진 runtime에도 실제 token context
overflow가 발생할 수 있고 같은 의미 기반 복구가 필요하다.
감사는 `cf8aa2a9de83e3fab9e96611cc5be309b8952b73`에서 수행했다. source와 CI는
실행 중인 바이너리, 장기 운전 성공, 모델의 요약 정확성 증거를 대신하지 않는다.

| 현재 경계 | source에서 확인한 동작 |
|---|---|
| [unified execution](../../lib/keeper/keeper_unified_turn_execution.ml) | 후보 소진 후 `Agent_core_context_window_exceeded`와 typed 오류 기록 |
| [failure route](../../lib/keeper_runtime/keeper_runtime_failure_route.ml), [failure observation](../../lib/keeper/keeper_unified_turn_failure.ml) | `Exhausted_visible_alive Context_overflow`; 실패 횟수 기록, lifecycle은 active |
| [heartbeat](../../lib/keeper/keeper_heartbeat_loop.ml) | 실패한 stimulus를 소비하지 않고 정상 cadence 유지; 재시도 예약 가능 |
| [run context](../../lib/keeper/keeper_run_context.ml) | canonical checkpoint 복원, dispatch 전 임의 압축 없음 |
| [AGENT_CORE pipeline](../../packages/agent_core/lib/pipeline/pipeline.ml) | provider context 오류를 반환; transcript 변경·implicit retry 없음 |
| [run result](../../lib/keeper/keeper_agent_run.ml), [finalization](../../lib/keeper/keeper_agent_run_finalize_response.ml) | 오류는 성공 finalization 이전 반환; Librarian post-turn 작업에 도달하지 않음 |
| [recall](../../lib/keeper/keeper_run_tools_hooks.ml) | 기존 Memory OS facts를 관측 문맥에 추가; canonical history 대체 아님 |

이미 실행 중이던 다른 memory 작업, runtime 설정 변경, 새 입력에 따라 결과가 달라질
수 있다. 모든 overflow가 영구 반복된다고 단정하지 않는다. 현재
`test_keeper_optional_request_cap`은 같은 cycle의 후보 failover를 검증하며,
**모든 후보 실패 이후 다음 cycle의 의미 기반 회복은 검증하지 않는다.**

## 결정

원본 checkpoint를 고치지 않고 **출처에 결합된 durable transmission projection**을
만든다. 다음 Keeper 요청은 이 projection과 그 뒤의 원본 suffix를 사용한다.
Keeper가 원문을 다시 읽는 경로는 계속 제공한다. 요약은 원문이 아니며, 실행·승인·
Tool 결과를 요약의 문장만으로 확정하지 않는다.

복구는 typed provider context 거절에서 시작한다. HTTP body bytes 제한, token context
제한, 오류 문자열, 누적 비용·턴 수를 섞지 않는다. caller가 명시한 양수 byte cap은
그대로 존중한다. cap이 없다는 이유로 512KiB, `max_int`, 토큰/바이트 환산값을 만들지
않는다. JSON 허용량의 10%를 비워 두거나 실패할 때마다 절반으로 줄이는 정책도 이
복구의 근거가 아니다.

Memory OS facts는 별도의 의미를 가진다. 출처 결합 여부가 서로 다른 기존 facts를
canonical 입력의 대체 권위로 승격하지 않는다. `Keeper_librarian_runtime`은 현재
**tool-free**이며 성공 이후의 fact selection을 수행한다. 단순히 그 함수를 실패
경로에서도 호출하는 것으로 이 RFC를 구현했다고 볼 수 없다.

## 영속 대상과 타입의 의미

다음은 제안하는 도메인 계약이다. 구현된 모듈·wire schema라는 주장이 아니다.

- `source`: Keeper identity, trace/admission identity, canonical checkpoint revision,
  원본 파일 SHA-256, 전송 대상으로 선택한 message prefix의 digest, 원문 artifact ref.
  원본 파일 digest와 projection 입력 digest를 구분한다. 재인코딩한 JSON을 원본 파일
  bytes라고 부르지 않는다.
- `refusal`: 실제 요청/run ID, 순서가 보존된 후보별 typed failure, 관측된 token limit
  option, 최종 wire 관측 ref. 없는 limit·usage·cost는 관측 없음으로 남긴다.
- `work`: recovery ID, owner generation, source, 진행 cursor와 읽은 범위,
  부분 결과 artifact refs, 선택한 worker runtime/lane 및 실행 receipts.
- `proposal`: source digest, 유지할 원본 atom refs, 출처가 붙은 요약 블록,
  미해결 사항·사용자 요구·작업 상태, pending stimulus ID 집합과 source watermark,
  원문 조회 manifest, proposal digest. 현재 Task 계약·사용자 직접 지시·미완료
  continuation은 host가 고정한 required source refs이며 요약 제안으로 삭제할 수 없다.
  각 요약 주장은 원문 범위 참조를 가진다. 구조 검증 성공은 의미 충실성의 증명이 아니다.
- `binding`: 검증된 proposal digest, 적용할 exact source prefix, 적용 runtime의
  capability/config snapshot, 마지막 실제 admission/dispatch 결과. 전송 성공을
  요약 승인이나 복구 성공과 혼동하지 않는다.

state는 `Pending | Running | Ready | Failed | Cancelled | Superseded`로 표현하고,
`Ready`는 사용 가능한 projection이 durable 하게 게시됐다는 뜻이다. 실제 Keeper의
다음 턴 성공은 별도 receipt다. `Failed`는 typed 이유와 부분 증거를 보존한다.
`Cancelled`와 프로세스 재시작에 의한 미완료 상태도 구별한다.

## 원본과 Tool 관계 보존

1. Keeper Owner가 실패한 admission과 source snapshot을 결합해 work를 먼저 저장한다.
   원본 bytes는 [Tool_blob_store.put_file_durable](../../lib/tool_blob_store/tool_blob_store.mli)
   또는 이미 durable 한 exact content address를 통해 보존한다. 저장 실패는 ref를
   발명하지 않고 typed 실패로 반환한다.
2. schema로 읽은 message·content block·ToolUse/ToolResult ID로 atom index를 만든다.
   문자열 prefix, 인접 timestamp, 모델의 자유문장으로 관계를 추정하지 않는다.
3. 전송에 원본 ToolUse를 남기면 그 결과도 같은 tool ID로 남긴다. 이미 끝난 tool
   교환을 요약으로 대체할 때는 **교환 전체**를 교체한다. 미완료 tool cycle과 현재
   continuation은 요약 대상이 아니다. 원본의 ID·순서·bytes는 계속 조회 가능하다.
4. 요약 텍스트는 명시적인 derived context로 보낸다. 가짜 assistant 실행 메시지나
   ToolResult로 합성하지 않는다. pending 외부효과, approval/replay 권위는 기존 typed
   receipt/continuation 경계를 그대로 사용한다.
5. source가 같은 prefix에서 append만 됐다면 그 prefix digest를 검증하고 새 suffix는
   원문 그대로 추가할 수 있다. 수정·재정렬·trace 교체는 `Source_changed`로 격리한다.
   최신 내용에 오래된 요약을 조용히 끼워 넣지 않는다. pending stimulus 집합과
   source watermark도 적용 시 검증한다. 그 뒤 접수한 지시는 새 suffix/attention으로
   보존하고 이전 proposal이 읽거나 처리한 것으로 표시하지 않는다.

## 큰 원문을 읽는 worker

새 executor를 만들지 않는다. 기존 per-Keeper memory lane은 작업을 실행할 위치이고,
기존 AGENT_CORE tool loop는 worker의 모델·도구 실행을 맡는다. worker runtime 선택은
TOML의 명시적인 lane 설정을 통해 기존 resolver를 사용한다. 기본 경로는 읽기를 수행한
같은 worker가 **typed proposal Tool**로 제안을 제출하고, Keeper Owner의 동일한
schema/source-digest validator가 받는 것이다. JSON 형식만 맞추기 위한 두 번째 LLM
호출은 두지 않는다. Tool의 receipt는 제안 저장 결과이며 원래 Keeper 작업 완료가 아니다.

선택된 runtime이 이 Tool 계약을 지원하지 않고 기존 exact-output 실행이 가능한
경우에만 tool-free 경로를 후보로 둔다. 이 경로는 host가 artifact 페이지와 부분 결과를
준비해 기존 `Exact_output.execute_flow_once`에 전달한다. Tool 지원 여부는 typed
capability에서 읽으며 runtime 이름으로 추측하지 않는다. 두 경로는 같은 proposal
schema·출처·소유권 검증을 공유한다. 기존 Librarian flow가 tool-free라는 사실은 그대로다.
recovery 도메인의 요청 조립/읽기 진행 연결은 **구현할 부분**이며 새 executor가 아니다.

worker의 첫 입력은 실패한 전체 history가 아니라 source manifest, 목적, 현재 작업·
미완료 권위의 refs다. 원문 접근은 기존
[keeper_artifact_read](../../lib/keeper/keeper_artifact_read.mli)의
`sha256, offset, max_bytes` 요청과 `next_offset, total_bytes, eof, encoding` 응답을
사용한다. 바이트 cursor는 읽기의 위치이며 토큰 추정치가 아니다. 기존 도구의 응답
크기 제한은 wire 전달 자원 경계로 그대로 사용한다. provider에 넣을 문서는 UTF-8/
base64 타입에 맞게 해석하고 source atom 범위를 정확히 기록한다.

긴 페이지들을 worker의 한 대화에 무한히 누적하지 않는다. source atom 단위 작업과
읽기 cursor, 부분 요약을 durable하게 남기고 다음 단위를 기존 runner의 새 호출로
읽는다. 긴 atom은 동일 digest의 다음 offset으로 이어 읽는다. 부분 요약도 커지면
artifact에 저장하고 계층적으로 결합한다. **전체 원문을 봤다는 표시는 모든 선언된
범위의 읽기 증거가 있을 때만** 가능하다. 읽기 완료는 이해·충실성의 증명은 아니다.
중요한 범위의 생략은 proposal에 명시하며 최종 검증에서 처리한다.

후보 worker 요청은 기존 최종 serializer로 측정한다. provider native token count가
지원되면 그 정확한 값과 typed 한계를 사용할 수 있다. 미지원이면 바이트를 token으로
환산하지 않는다. 실제 typed overflow를 받으면 완료된 source 작업은 보존하고 다음
선언 후보나 더 세분화된 source 작업으로 이어간다. 최소 manifest/미완료 atom조차
처리할 수 없으면 `Worker_input_not_admissible`로 노출한다. 빈 요약을 성공으로 만들지
않는다. 몇 번 실패했다는 횟수 대신 남은 source와 실제 진행 상태를 기록한다.

## 소유권, 실패와 재시작

[Keeper_memory_lane](../../lib/keeper/keeper_memory_lane.mli)은 현재 프로세스 내부의
latest-wins drain이다. 제출된 closure나 `Submitted` 응답 자체는 durable work가 아니다.
복구 요구는 먼저 별도 owner record에 저장하고, lane은 그 record의 미완료 작업을
읽는다. 일반 Librarian snapshot의 coalescing이 복구 요구를 삭제하지 않아야 한다.
같은 source/admission의 중복 요구는 기존 exact identity로 같은 work를 찾는다.
다른 요구의 교체는 `Superseded` 관계와 이유를 남긴다.

- 기존 Keeper Owner가 work 생성·projection binding 게시를 직렬화한다. worker는
  원본 checkpoint나 pending stimulus를 소비할 권한이 없다.
- 기존 lane lifecycle의 drain/cancel을 사용하고, worker 결과는 generation과 source
  digest가 여전히 맞을 때만 CAS로 게시한다. 늦게 도착한 결과는 적용하지 않는다.
- 취소 요청과 실제 worker 종료를 나눠 기록한다. 종료/cleanup 확인 전 다른 worker를
  같은 owner로 중복 실행하지 않는다. 정리 실패도 typed failure로 보인다.
- 재시작은 같은 recovery ID와 durable cursor로 미완료 작업을 재개한다. process-local
  `Running` 표시는 완료 증거가 아니다. 새 owner generation을 획득한 뒤 남은 작업만
  실행한다. 이미 durable 한 결과는 다시 게시하지 않는다.
- 실패한 Keeper admission은 복구 요구와 결합해 `waiting for recovery`로 관측한다.
  같은 거절 입력을 cadence마다 무조건 재전송하는 동작을 대체한다. 이는 Keeper 전체
  pause나 비용 게이트가 아니다. heartbeat·운영 제어·새 source 접수는 계속 동작한다.
- `Ready`의 typed wake는 그 admission을 다시 평가하게 한다. 실패·취소는 이유, 원문,
  재개 경로를 보여 준다. worker lane/config/source 변경 또는 명시적 retry가 새 시도를
  소유한다. 숫자 backoff나 무한 동일 proposal 제출로 진행을 꾸미지 않는다.
- Keeper의 성공/기존 완료 계약이 성립하기 전에는 pending stimulus를 ack하지 않는다.
  복구 worker의 성공은 원래 사용자 요청의 완료가 아니다.

## 적용과 기억 사용성

최종 provider config, Tool schemas, streaming 옵션이 결정된 뒤 실제 serializer의
admission에 projection을 넣는다. 앞선 messages-only hook에서 다른 요청을 측정하고
통과로 간주하지 않는다. 선택된 serialized artifact와 실제 POST는 같은 bytes여야
한다. explicit byte cap과 provider token context는 별도 결과로 남긴다.

다음 Keeper 입력은 무엇이 derived context인지, source artifact digest와 어떻게 원문을
읽는지, 어떤 범위를 요약했는지 명시한다. `keeper_artifact_read`는 실행 가능한 Tool
surface에서 실제로 제공돼야 한다. Tool Group에서 제외됐거나 runtime이 못 쓰면
`Source_access_unavailable`이며 원문 접근 가능이라고 표시하지 않는다. 성공한 복구
projection은 동일 prefix 동안 그대로 재사용한다. 매 턴 재요약하여 prefix를 흔들지
않는다. 이 설계가 cache hit를 개선한다는 것은 후속 실측 대상이지 현재 성과가 아니다.

Dashboard/TUI는 recovery ID, 원본/제안 digest, worker 상태·runtime·Tool calls,
관측 token/cost, 읽기 진행, 적용 여부와 Keeper 재개 결과를 같은 원장에서 읽는다.
`Ready`와 `Keeper turn succeeded`를 나란히 구분한다. 숨은 reasoning은 만들지 않는다.

## 실제 기능 검증

CI의 loopback HTTP peer와 임시 base path로 다음 **연속 cycle**을 실행한다.

1. canonical checkpoint에 오래된 요구, 중요한 반론, 완료 Tool 교환, pending stimulus를
   저장한다. 첫 cycle의 모든 runtime은 기존 parser가 지원하는 typed context refusal을
   보낸다. 각 후보의 실제 요청·오류를 기록한다.
2. Keeper active와 pending stimulus 보존을 확인한다. 같은 source에 여러 wake를 넣어도
   기존 recovery 하나를 소유하며, 동일 거절 입력의 의미 없는 재전송이 없음을 확인한다.
3. worker가 실제 artifact handler로 여러 offset을 읽는다. provider fixture의 proposal이
   읽은 source 범위와 결합되는지 검사한다. canonical 파일 SHA와 tool ID 쌍은 전후 동일하다.
4. projection 게시 뒤 다음 Keeper cycle이 실제 변경된 요청을 전송하고 성공한다.
   모델이 요약에서 원문 ref를 사용해 옛 Tool 결과를 실제로 다시 읽는 것까지 실행한다.
   성공 전에는 stimulus ack가 없고, 성공 후에만 기존 계약대로 ack된다.
5. 중간 재시작·취소·source 수정·동시 append를 주입한다. exact recovery ID와 cursor,
   stale 결과 비적용, 소유자 하나, 고아 ToolResult 0건을 확인한다. 복구 실패는 visible
   terminal evidence로 남으며 성공으로 세지 않는다.
6. 새 projection도 provider가 거절하는 경우 원본/부분 작업을 잃지 않고 typed 다음
   작업으로 이어지는지 검증한다. 관측되지 않은 token/cost/완료율을 0이나 성공으로 채우지 않는다.

기존 구성요소는 `test_keeper_optional_request_cap`, `test_keeper_runtime_failure_route`,
`test_keeper_replay_checkpoint`, `test_keeper_memory_lane`, `test_keeper_librarian_retry`다.
`test_runtime_codex_app_server`의 `run_production_keeper_turn`은 실제 Keeper owner/
checkpoint 연결의 참고 fixture이며 HTTP 다중 cycle 증거를 대신하지 않는다.
전체 복구 scenario는 새 기능 검사가 필요하다. CI raw log, 정확한 source/binary SHA,
별도 격리 runtime 관측, Dashboard/TUI 브라우저 캡처를 각각 남긴다.

## 작은 구현 순서와 미검증 가정

1. source snapshot/work owner/state와 durable ledger 계약. 이 단계는 기록과 독립적인
   소유권 검증만 추가하며 기존 Keeper scheduling을 기다림 상태로 돌리지 않는다.
2. artifact cursor worker와 typed proposal Tool. tool-free exact-output 후보는 실제
   capability가 요구할 때 같은 validator로 연결한다.
3. source-bound projection 적용, canonical/Tool pair 보존, 원문 다시 읽기와 typed wake를
   완성한다. usable worker, 검증된 projection 적용, wake가 모두 연결된 뒤에만 실패한
   admission을 recovery waiting으로 보내는 scheduling 전환을 활성화한다. 실행할 worker가
   없는 중간 단계에서 stimulus 재시도를 차단하는 임시 복구 게이트를 배포하지 않는다.
4. 실제 다중 cycle proof와 Dashboard/TUI. 이후 여러 provider·10턴·장기 운전으로 확장.

현재 미검증 사항은 다음과 같다. 이 RFC 승인으로 해결된 것으로 보지 않는다.

- 기존 latest-wins memory lane에서 일반 fact 작업과 durable recovery 작업을 함께
  소비하는 최소 integration. 조용한 coalescing 손실이 없음을 먼저 증명해야 한다.
- 같은 worker의 typed proposal 제출과 tool-free exact-output fallback의 실제
  capability 조합. 미지원 runtime은 typed 이유를 표시하고 다른 선언 후보를 사용한다.
- 요약의 의미 충실성, 모순/미해결 요청 보존, 직접 원문 조회가 충분한지에 대한
  실제 모델 평가. schema/digest 일치만으로 이 항목을 통과시키지 않는다.
- 최소 worker 입력조차 수용되지 않는 경우의 사용자 재구성 경로. 무한 재시도를
  해결책으로 삼지 않으며 거대한 단일 사용자 입력의 성공을 보장하지 않는다.
- tool paging/final serialization의 실제 latency·token/cache 영향. 현재 수치 목표를
  발명하지 않고 baseline 및 같은 입력의 대조 실행으로 제시한다.

## 비교 근거

Anthropic의 [context engineering 글](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)은
지연 조회, compaction, 영속 노트를 별개 수단으로 설명한다. 이 RFC도 원문 조회와
요약의 역할을 분리한다. [MemGPT 원 논문](https://arxiv.org/abs/2310.08560)은 모델의
제한된 문맥과 외부 memory 사이의 이동을 다룬다. 둘 다 MASC의 source digest,
원자적 Tool 교환, Keeper Owner 재시작 계약이 구현됐다는 증거는 아니다.

원문 확인: 2026-09-08. 비교는 설계 경계에만 사용하며 성능 또는 기억 정확도를
그 제품의 결과에서 MASC로 이전해 주장하지 않는다.
