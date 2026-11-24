---
rfc: "0522"
title: "실측 provider 실패를 로컬 대역 끝점에서 재생해 생산 호출 체인으로 고정한다"
status: Draft
created: 2026-11-17
updated: 2026-11-17
author: claude
supersedes: []
superseded_by: null
related: ["turn-failure-visible-stop", "0492"]
---

# RFC-0522: 실측 provider 실패를 로컬 대역 끝점에서 재생해 생산 호출 체인으로 고정한다

- 상태: 초안(2판. 리뷰 4건 — be-sleepers 둘, pangyo-preachers, anyang-keepers — 의 지적을 반영했다).
- 이슈: #52580.
- 관련 이슈: #51648(GLM 요청이 응답 머리 전에 끊긴다, 집계 창 2026-11-12 00:00Z~약 09:30Z 동안 21건), #48991(깨진 청크 크기 줄을 완결로 읽고 연결을 캐시에 돌린다), #46722(레인 정체와 provider 무응답 기록), #52403(#52386 스택의 배포 뒤 측정). OpenRouter 계정 크레딧 소진 402(2026-11-13)는 이슈 번호가 없는 세션 기록이다.
- 비대상(§4): #28072(CLI spawn 결함, HTTP 와이어 없음), #38403(호스트 잠자기 착시).
- 먼저 있는 결정:
  - 2026-11-12 사용자 결정: PR·병합당 CI run 수를 늘리는 설계는 하지 않는다(constitution build_and_ci "PR·일반 branch push 로 자동 CI 를 시작하지 않는다"와 같은 방향). 재생 시험은 기존 테스트 binary 안에서만 돈다.
  - RFC-turn-failure-visible-stop: 실패 면제와 클래스별 예산을 걷어냈고, 각 레인이 소유한 유한한 시도가 끝나 턴이 실패하면 원인 불문 crash 계정에 오른다. 이 RFC 는 그 계정에 오르는 입력을 실측 모양 그대로 만들어 준다. 계정 규칙은 바꾸지 않는다.
  - RFC-0492: provider 연결은 프로세스 하나의 캐시에서 재사용되고, 쓰기 실패는 request_not_delivered/Possibly_delivered 로 갈라 재전송 여부를 정한다. #51648 의 두 와이어 모양은 이 구분의 입력이다.
  - 판정 서버 거절(#52386): 닫힌 합타입으로 나뉘고 Refusing 중에는 새 시도를 만들지 않는다. 판정 서버 재생은 이 RFC 의 1단계 범위 밖이다(§5 D2).
  - constitution forbidden#budget_gate, #string_matching: 재생 시험은 분류·회전 규칙에 새 숫자·문자열 판단을 넣지 않는다.
  - constitution testing: feature_surface 의 기능을 시험한다. 이 RFC 가 시험하는 기능은 runtime 그룹의 Model Free·Provider Free·failover 다. 함수 시험을 늘리는 게 아니다.
- 코드 좌표는 `origin/main` `277c8f55816d` 에서 읽었다(리뷰가 지적한 retry.ml·http_client.mli·RUNTIME-TOML-REFERENCE.md §9·test_http_client_cache.ml 좌표는 리뷰 시점 base 에서 재확인했다). 운영 로그는 읽지 않았다.

## 읽기 전에 — 말의 뜻

- **provider**: 런타임 binding 이 가리키는 모델 호출 상대다. GLM, OpenRouter, Claude, Ollama 같다. 판정 서버(TypeSafe)는 별개 클라이언트라 이 RFC 의 1단계에서 빼고 §5 D2 에 둔다.
- **생산 호출 체인**: `Llm_provider.Http_client` 가 요청을 보내고 응답을 읽어 `Agent_core.Error.t` 나 결과로 매핑하고, `Keeper_error_classify` 가 분류하고, crash 계정이 세고, `Keeper_runtime_attempt` 가 후보 회전을 정하는 길 전부다. run 단위 재시도 결정(`connection_recovery_sequence`, `same_run_retry_allowed`)은 이 체인의 뒤에 있고 1단계 범위 밖이다(§2.3).
- **값 주입 시험**: `Agent_core.Error.t` 값을 시험 안에서 직접 만들어 분류·계정·상태 다리만 돌리는 시험이다. `test/test_keeper_runtime_observation_boundaries.ml` 이 이 형태다. 생산자(HTTP 클라이언트와 와이어 해석)를 지나치지 않는다.
- **재생(replay)**: 실측 사건의 와이어 모양 — 상태줄과 본문, 연결 종료 시점, 깨진 인코딩 — 을 로컬 대역 끝점이 그대로 내보내는 것이다. 값 주입과 다르게 생산 호출 체인 전부를 통과한다.
- **대역 끝점(stand-in)**: 시험 안에서 돌아가는 로컬 서버다. 진짜 provider 가 아니다.

## 0. 요약

provider 실패 사건은 전부 사후 분석으로 발견했다(#51648 의 21건, #48991, OpenRouter 402). 지금 시험은 두 부류뿐이다. 값 주입은 생산자를 지나치지 않아 #51648·#48991 의 와이어 모양(응답 머리 전 EOF, 쓰기 중 EPIPE, 깨진 청크 줄)을 아예 만들지 못하고, 국소 대역은 fixture 마다 제각각 손으로 만든다.

**규칙: HTTP 와이어로 표현되는 실측 provider 실패 사건 하나는 재생 시험 하나로 남는다. 재생은 값을 만들어 넣지 않고 로컬 대역 끝점이 와이어 모양을 내보내 생산 호출 체인 전부를 통과한다.**

끝점 교체는 이미 있다. 런타임 TOML §2 의 `endpoint` 표 행(문서 70행)에 로컬 주소를 주면 된다. 단 binding 은 §9 거절표와 맞물린다(§2.1). 새로 만드는 것은 test/ 공용 대역 fixture 하나와 실측에서 뽑은 실패 프로파일뿐이다.

## 1. 문제

### 1.1 사건과 발견 비용

- #51648: GLM 요청이 끊겼다. 실측 모양은 둘뿐이다. `closed by peer` 15건은 cohttp-eio 가 응답 머리를 읽다 EOF 를 만난 경우로 응답 바이트를 하나도 받지 못했고, `writev` 6건은 요청을 쓰다 Broken pipe 가 난 경우다(RFC-0492 의 request_not_delivered). TLS 사건은 없고 스트림 도중 끊김도 없다. 사후 로그로 발견.
- #48991: 청크 크기 줄이 16진수가 아닌 값을 만나면 잘린 본문을 성공으로 받고 그 연결을 캐시에 돌려놓는다. 생산자(전송) 계층 결함이다. 이슈의 재현 입력(비-16진수 청크 줄 + 캐시를 켠 두 번째 요청)이 문서로 남아 있다. 사후 발견.
- #46722: 레인이 느리거나 멈추자 턴 큐가 한 시간 가까이 붙잡혔다. 이슈는 provider 무응답 실측(first_token 타임아웃, 머리 없는 응답, Muse 300초 무응답)도 같이 기록한다.
- OpenRouter 계정 크레딧 소진(2026-11-13, 이슈 없는 세션 기록): 모든 호출이 402 로 돌아왔다. probe.sh 는 키 한도만 읽어 크레딧 소진을 몰랐다. 사후 발견.

공통점: 실패 클래스마다 사람이나 에이전트가 로그·원장을 뒤져 원인을 찾았다. 같은 와이어 모양이 시험에 담겨 있었다면 사건은 회귀 시험 한 줄로 끝난다.

### 1.2 이미 있는 것 — 다시 만들지 않는다

- 닫힌 실패 얼개: `Agent_core.Error.t` 의 `Provider_wire_error`(malformed·unknown event·incomplete·oversized), `Provider_reported_error`, `Api (InvalidRequest _)`, `EmptyCompletion`, `TimeoutError`(phase 별). 읽는 곳: `lib/keeper/keeper_error_classify.mli`, `packages/agent_core/lib/llm_provider/`.
- 402 의 typed 매핑: `Retry.classify_error` 가 402 를 `PaymentRequired` 로 매핑하고 `is_retryable` 은 false 다(retry.ml). `keeper_runtime_attempt.ml` 이 `PaymentRequired` 를 code 402 로 되돌린다. 인라인 시험이 매핑을 고정한다.
- 값 주입 시험: `test/test_keeper_runtime_observation_boundaries.ml` 이 분류 → crash 계정 → 레지스트리 → 공개 상태 다리까지 고정한다. RFC-turn-failure-visible-stop 이 만든 체인 회귀도 이미 있다.
- 국소 대역: `test/librarian_floor_fixture.ml` 이 Eio 로컬 HTTP 서버를 띄우고 테스트마다 `respond` 를 바꾼다. 머리글이 선언대로 "Docker, real paid providers, visible UI 를 요구하지 않는다". `test/lane_addon_fake_engine/` 도 같은 부류다.
- raw TCP 대역 전례: `packages/agent_core/test/test_http_client_cache.ml` 의 `start_raw_server`, `test/test_provider_connection_cache_wiring.ml`.
- 끝점 교체: 런타임 TOML `endpoint` 필드와 loopback 인식(`binding_base_url_is_loopback`).
- loopback SSE 인프라: `test/bench_sse_pump_throughput.ml`(RFC-0493)이 한 프로세스에서 서버·리더를 돌린다.

### 1.3 빈 곳

와이어 수준 실패를 내보내는 공용 대역이 없다. #51648 의 두 모양(머리 전 EOF, 쓰기 중 EPIPE)과 #48991 의 모양(깨진 청크 줄 + 같은 연결 재사용)은 값 주입으로 만들 수 없고, fixture 마다 서버를 손으로 만들면 사건마다 중복이다. 그래서 생산자 계층 결함은 시험 없이 사후에만 발견된다.

## 2. 제안

### 2.1 공용 대역 fixture

`test/provider_failure_replay_fixture.ml` 를 만든다. `exact_output_fixture` 처럼 test/ 안의 공용 모듈로 두고, lib 노출은 하지 않는다. 두 번째 소비자가 실제로 생기면 그때 다시 본다.

서버: raw TCP 리스너가 기본이다. 머리 전 종료, 쓰기 중 끊기, 비-16진수 청크 줄처럼 임의 바이트와 연결 제어가 필요한 프로파일이 많아서다(`start_raw_server` 형). 정상 스트림이 필요한 시험에서만 그 위에 HTTP/SSE 를 얹는다. 진짜 provider 의 인증을 흉내 내지 않는다(§4).

binding: 미등록 provider binding(`kind = "glm"`)에 대역 주소를 `endpoint` 로 준다. §9 거절표 때문에 카탈로그 행이 있는 id 는 `kind` 를 못 쓰고 keyed 자격 선언에 묶이므로 카탈로그 밖 id 를 쓴다. 자격 원천은 §9 가 요구하는 대로 선언한다(시험용 키 파일). 미등록 끝점은 max-context 도 직접 선언한다. 이 binding 은 자격이 있고 loopback 이므로 `local` 이 아니라 `direct_api` 로 분류된다(`runtime_kind_of_binding` 은 No_auth 이면서 loopback 일 때만 `local`).

시험은 체인을 실제로 돌린 다음 결과를 본다. fixture 는 기존 테스트 binary 안에서 돈다. 프로세스를 새로 띄우지 않는다.

### 2.2 실패 프로파일 — 실측 사건에서만 뽑는다

| 프로파일 | 와이어 모양 | 근거 사건 |
|---|---|---|
| P1 거절 상태 | HTTP 402 와 크레딧 소진 본문 | OpenRouter 402(2026-11-13, 이슈 없는 세션 기록). 1단계 방언에서 본문은 합성이다(§5 D1) |
| P2 머리 전 EOF | 요청을 받은 뒤 응답 머리 한 줄도 안 보내고 연결을 닫는다 | #51648 `closed by peer` 15건 |
| P3 쓰기 중 EPIPE | 클라이언트가 요청을 쓰는 사이에 연결을 닫는다 | #51648 `writev` 6건(RFC-0492 request_not_delivered) |
| P4 무응답 | 요청을 받고 아무것도 돌려주지 않는다 | #46722 의 provider 무응답 기록(first_token 타임아웃, Muse 300초 무응답) |
| P5 깨진 청크 줄 | 청크 본문 중간에 비-16진수 크기 줄을 넣고, 같은 연결로 두 번째 요청을 받는다 | #48991 재현 입력 |

TLS 프로파일은 넣지 않는다. 실측 TLS 사건이 없다(#51648 에 한 건도 없다). 생기면 그때 넣되 https loopback 과 self-signed 인증서라는 비용이 따른다(§4). 상상한 프로파일을 더 넣지 않는다. 위 다섯 외에는 다음 실측 사건이 가져온다.

### 2.3 각 시험이 고정하는 것

각 프로파일 시험은 생산 호출 체인을 통과한 뒤 세 가지를 고정한다.

1. **내려오는 typed 모양**: 그 와이어가 어느 `Agent_core.Error.t` 변형인지. 402→`PaymentRequired` 매핑은 값 수준에서 이미 고정돼 있지만(retry.ml), 와이어 모양에서 시작해 후보 회전까지 잇는 end-to-end 시험은 없다. 이 시험이 그 사슬을 고정한다.
2. **crash 계정과 상태**: RFC-turn-failure-visible-stop 규칙대로, 각 레인이 소유한 유한한 시도가 끝나 턴이 실패하면 첫 실패부터 계정에 오르고 Failing 이 보이는지.
3. **후보 회전**: `Keeper_runtime_attempt` 의 회전 조건이 그 실패 클래스에서 무엇을 정하는지.

범위 못박기: #51648 이 실제로 막힌 run 단위 재시도 결정(`connection_recovery_sequence`, `same_run_retry_allowed` — RFC-0492 계열)은 이 RFC 가 고정하지 않는다. P2·P3 시험이 그 결정의 입력(머리 전 EOF 인가, 쓰기 중 끊김인가)을 재생 모양으로 공급할 뿐이다. run 재시도 재생은 별도 후보로 남긴다.

판정 서버(TypeSafe) 프로파일은 2단계다(§5 D2). #52386 이 방금 병합돼 측정(#52403)을 기다리는 중이니, 그 측정이 프로파일 목록을 채운 뒤에 붙인다.

## 3. 증명

- 규칙이 돌아가는지는 다음 실제 provider 사건으로 잰다. 이슈가 열리거나 사건이 기록된 시각부터, 그 와이어 모양의 재생 시험이 커밋되기까지 하루 안이다. 기록 위치: 사건 이슈 본문에 재생 시험 PR 번호와 커밋 시각을 적는다. 셈 방법을 바꾸지 않고 계속 잰다.
- 재생 통과가 실전 안전을 말하지 않는다. 대역은 진짜 provider 가 아니고, 실측되지 않은 행동은 내보내지도 않는다.

## 4. 하지 않는 것

- 방언 전체 프로토콜 흉내를 새로 쓰지 않는다. `Llm_provider` 가 이미 말하는 방언을 그대로 쓴다.
- CI 에 서비스나 run 을 추가하지 않는다(사용자 결정 2026-11-12). 기존 테스트 binary 안에서만 돈다.
- 보안·인가 시험 주장을 하지 않는다. 대역은 자격 평가를 흉내 내지 않는다.
- Gate·누적 상한·문자열 분류기를 만들지 않는다. 재생은 있는 규칙을 검사할 뿐 새 규칙을 만들지 않는다.
- lib 노출을 하지 않는다. test/ 공용 모듈로 시작한다.
- **비대상 사건**: HTTP 와이어로 표현되지 않는 결함은 이 재생이 담지 않는다. #28072(CLI spawn 의 E2BIG argv catch-all — 와이어가 없다), #38403(호스트 잠자기 착시). 이들은 각자의 이슈에서 따로 다룬다. TLS 도 실측 사건이 생길 때까지 빼며, 생기면 https loopback 과 self-signed 인증서 비용이 fixture 에 더해진다.

## 5. 열린 결정

운영자가 2026-11-17 에 추천 승인으로 답했다("ok"). 리뷰가 밝힌 숨은 대가를 보태서 적는다.

- **D1 1단계 방언 = GLM.** 근거: #51648(21건)이 가장 큰 사건 뭉치고 P2·P3·P5 가 그 사건들의 실측 와이어 모양이다. 대가: (a) 다른 방언의 사건은 다음 사건이 올 때까지 기다린다. (b) P1 의 402 본문은 OpenRouter 방언의 것이어서 GLM 끝점에서 내면 합성이다. 1단계에서 P1 이 고정하는 것은 상태줄과 매핑·회전 사슬이지, 실측 본문 문장이 아니다.
- **D2 판정 서버 재생 = 2단계.** 근거: TypeSafe 클라이언트는 모델 binding 과 다른 길이고 #52403 측정이 남아 있다. 대가: (a) 판정 서버 사건은 1단계가 끝날 때까지 값 주입·사후 분석에 남는다. (b) 두 경로가 `Agent_core.Error.t` 매핑을 공유하면 provider 재생이 잡은 매핑 회귀가 판정 서버 쪽에 그대로 닿는지 별도 확인이 필요하고, 공유하지 않는다면 왜 아닌지를 2단계 근거에 적는다. 2단계 설계 때 매핑 공유 여부를 먼저 확인한다.
- **D3 P4 무응답의 끝 = 시험 binding 의 `connect-timeout-s`.** 응답 머리 전 구간에 걸리는 이 설정(기본값 없음)을 시험 binding 에서 짧게 두면, 무응답은 `TimeoutError`(phase 별) 로 끝난다. 새 타임아웃 코드가 없다(forbidden#budget_gate 와 같은 방향). 대가: (a) 시험 실행마다 설정값만큼의 벽시계 시간을 쓴다. run 수를 늘리지 않는 결정과 별개로 테스트 시간이 늘어난다. (b) 클라이언트가 끊는 것으로 끝나므로 시험의 단언은 "클라이언트가 timeout 으로 끊었다"이지 "서버가 응답하지 않았다"가 아니다. 느린 provider 와 고장난 provider 를 구분하지 못한다. (c) 설정값보다 긴 실제 정체는 담지 못한다.

## 6. 이력

- 2026-11-17 초안.
- 2026-11-17 2판: 리뷰 4건 반영. P2·P3 를 실측 모양(머리 전 EOF, 쓰기 중 EPIPE)으로 바꾸고 TLS 를 뺐다(#51648 본문 대조). #48991 용 P5 를 추가했다. 규칙을 "HTTP 와이어로 표현되는" 사건으로 한정하고 #28072·#38403 를 비대상으로 옮겼다. §2.1 에 raw TCP 서버와 §9 맞춤 binding 경로를 적었다. 402→PaymentRequired 기존 매핑 서술을 정정하고 end-to-end 구멍으로 좁혔다. D1~D3 의 숨은 대가를 보탰다. 배경 연구: `~/me` `knowledge/research/2026-11-17-masc-provider-failure-emulator.md`(jeong-sik/me PR #1339).
