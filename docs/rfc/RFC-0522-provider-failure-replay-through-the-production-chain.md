---
rfc: "0522"
title: "실측 provider 실패를 로컬 대역 끝점에서 재생해 생산 호출 체인으로 고정한다"
status: Draft
created: 2026-11-17
updated: 2026-11-17
author: claude
supersedes: []
superseded_by: null
related: ["turn-failure-visible-stop", "librarian-gate-waits-on-the-destination-not-on-passes"]
---

# RFC-0522: 실측 provider 실패를 로컬 대역 끝점에서 재생해 생산 호출 체인으로 고정한다

- 상태: 초안.
- 이슈: #52580.
- 관련 이슈: #51648(GLM 요청이 응답 전에 끊긴다, 11-12 하루 21건), #48991(깨진 응답을 완결로 읽고 연결을 캐시에 돌린다), #28072(Spawn_failed catch-all 이 영구 결함을 일시적으로 분류한다), #46722(레인 정체가 턴 큐를 한 시간 붙잡는다), #38403(잠든 맥의 실패를 provider 탓으로 적는다).
- 먼저 있는 결정:
  - 2026-11-12 사용자 결정: PR·병합당 CI run 수를 늘리는 설계는 하지 않는다. 재생 시험은 기존 테스트 binary 안에서만 돈다.
  - RFC-turn-failure-visible-stop: 실패 면제와 클래스별 예산을 걷어냈고, 실패한 턴은 원인 불문 첫 실패부터 crash 계정에 오른다. 이 RFC 는 그 계정에 오르는 입력을 실측 모양 그대로 만들어 준다. 계정 규칙은 바꾸지 않는다.
  - RFC-librarian-gate-waits-on-the-destination-not-on-passes(#52386): 판정 서버 거절은 닫힌 합타입으로 나뉘고 Refusing 중에는 새 시도를 만들지 않는다. 판정 서버 재생 프로파일은 이 상태기계를 검사한다. 판정 서버 재생은 이 RFC 의 1단계 범위 밖이다(§5 D2).
  - constitution forbidden#budget_gate, #string_matching: 재생 시험은 분류·회전 규칙에 새 숫자·문자열 판단을 넣지 않는다.
  - constitution testing: feature_surface 의 기능을 시험한다. 이 RFC 가 시험하는 기능은 runtime 그룹의 Model Free·Provider Free·failover 다. 함수 시험을 늘리는 게 아니다.
- 코드 좌표는 `origin/main` `277c8f55816d` 에서 읽었다. 사건 수치는 각 이슈에 적힌 값이다. 운영 로그는 읽지 않았다.

## 읽기 전에 — 말의 뜻

- **provider**: 런타임 binding 이 가리키는 모델 호출 상대다. GLM, OpenRouter, Claude, Ollama 같다. 판정 서버(TypeSafe)는 별개 클라이언트라 이 RFC 의 1단계에서 빼고 §5 D2 에 둔다.
- **생산 호출 체인**: `Llm_provider.Http_client` 가 요청을 보내고 SSE·NDJSON 을 해석해 `Agent_core.Error.t` 나 결과로 매핑하고, `Keeper_error_classify` 가 분류하고, crash 계정이 세고, `Keeper_runtime_attempt` 가 후보 회전을 정하는 길 전부다.
- **값 주입 시험**: `Agent_core.Error.t` 값을 시험 안에서 직접 만들어 분류·계정·상태 다리만 돌리는 시험이다. `test/test_keeper_runtime_observation_boundaries.ml` 이 이 형태다. 생산자(HTTP 클라이언트와 와이어 해석)를 지나치지 않는다.
- **재생(replay)**: 실측 사건의 와이어 모양 — HTTP 상태와 본문, 스트림 도중 끊김, 연결 실패 — 을 로컬 대역 끝점이 그대로 내보내는 것이다. 값 주입과 다르게 생산 호출 체인 전부를 통과한다.
- **대역 끝점(stand-in)**: 시험 안에서 돌아가는 로컬 HTTP 서버다. 진짜 provider 가 아니다.

## 0. 요약

provider 실패 사건은 전부 사후 분석으로 발견했다(#51648 의 21건, #48991, #28072, OpenRouter 402). 지금 시험은 두 부류뿐이다. 값 주입은 생산자를 지나치지 않아 #48991 부류(전송 계층 결함)를 구조적으로 못 잡고, 국소 대역은 fixture 마다 제각각 손으로 만든다.

**규칙: 실측 provider 실패 사건 하나는 재생 시험 하나로 남는다. 재생은 값을 만들어 넣지 않고 로컬 대역 끝점이 와이어 모양을 내보내 생산 호출 체인 전부를 통과한다.**

끝점 교체는 이미 있다. 런타임 TOML `endpoint`(docs/RUNTIME-TOML-REFERENCE.md §70)에 로컬 주소를 주면 되고, loopback binding 은 이미 `local` 로 분류한다(`lib/runtime_model/runtime_provider_binding.ml` 의 `binding_base_url_is_loopback`). 새로 만드는 것은 test/ 공용 대역 fixture 하나와 실측에서 뽑은 실패 프로파일뿐이다.

## 1. 문제

### 1.1 사건과 발견 비용

- #51648: GLM 요청이 응답 전에 끊겨 턴이 실패하고 Muse 로 넘어갔다. 11-12 하루 21건. 사후 로그로 발견.
- #48991: 청크 줄 크기가 깨진 응답을 다 읽은 것으로 보고하고 그 연결을 캐시에 돌려놓았다. 생산자(전송) 계층 결함이다. 값 주입 시험은 이 결함이 만드는 와이어 모양 자체를 재현하지 않으니 구조적으로 못 잡는다.
- #28072: `Spawn_failed` catch-all 이 영구 결함을 일시적으로 분류해 유료 재시도가 무한히 늘었다. 분류 계층의 결함이다.
- OpenRouter 계정 크레딧 소진(2026-11-13): 모든 호출이 402 로 돌아왔다. probe.sh 는 키 한도만 읽어 크레딧 소진을 몰랐다. 사후 발견.
- #46722: 레인이 느리거나 멈추자 턴 큐가 한 시간 가까이 붙잡혔다.

공통점: 실패 클래스마다 사람이나 에이전트가 로그·원장을 뒤져 원인을 찾았다. 같은 와이어 모양이 시험에 담겨 있었다면 사건은 회귀 시험 한 줄로 끝난다.

### 1.2 이미 있는 것 — 다시 만들지 않는다

- 닫힌 실패 얼개: `Agent_core.Error.t` 의 `Provider_wire_error`(malformed·unknown event·incomplete·oversized), `Provider_reported_error`, `Api (InvalidRequest _)`, `EmptyCompletion`, `transport_error_kind`(`Llm_provider.Http_client.Tls_error`, `Timeout`). 읽는 곳: `lib/keeper/keeper_error_classify.mli`.
- 값 주입 시험: `test/test_keeper_runtime_observation_boundaries.ml` 이 분류 → crash 계정 → 레지스트리 → 공개 상태 다리까지 고정한다. RFC-turn-failure-visible-stop 이 만든 체인 회귀도 이미 있다.
- 국소 대역: `test/librarian_floor_fixture.ml` 이 Eio 로컬 HTTP 서버를 띄우고 테스트마다 `respond` 를 바꾼다. 머리글이 선언대로 "Docker, real paid providers, visible UI 를 요구하지 않는다". `test/lane_addon_fake_engine/` 도 같은 부류다.
- 끝점 교체: 런타임 TOML `endpoint` 필드와 loopback 인식.
- loopback SSE 인프라: `test/bench_sse_pump_throughput.ml`(RFC-0493)이 한 프로세스에서 서버·리더를 돌린다.

### 1.3 빈 곳

와이어 수준 실패를 내보내는 공용 대역이 없다. 사건이 나면 지킬 수 있는 선택지는 값 주입(생산자 우회)이나 fixture 에 서버 하나 더 손으로 만들기뿐이다. 그래서 생산자 계층 결함(#48991)과 와이어 모양에 좌우되는 분류 결함(#28072)은 시험 없이 사후에만 발견된다.

## 2. 제안

### 2.1 공용 대역 fixture

`test/provider_failure_replay_fixture.ml` 를 만든다. `exact_output_fixture` 처럼 test/ 안의 공용 모듈로 두고, lib 노출은 하지 않는다. 두 번째 소비자가 실제로 생기면 그때 다시 본다.

fixture 는:

1. Eio 로컬 HTTP 서버를 띄운다. 인증은 요청을 받고 기각하는 시험용 자격만 둔다. 진짜 자격을 흉내 내지 않는다(보안 시험 주장 금지, §4).
2. 한 방언의 정상 스트림을 낸다. 1단계 방언은 §5 D1 에서 고른다.
3. 실패 프로파일을 시험마다 고른다. 프로파일은 와이어 모양이지 `Agent_core.Error.t` 값이 아니다.

시험은 런타임 TOML `endpoint` 를 이 서버로 향하게 한 binding 을 만들고, 체인을 실제로 돌린 다음, 결과를 본다. fixture 서버는 기존 테스트 binary 안에서 돈다. 프로세스를 새로 띄우지 않는다.

### 2.2 실패 프로파일 — 실측 사건에서만 뽑는다

| 프로파일 | 와이어 모양 | 근거 사건 |
|---|---|---|
| P1 거절 상태 | HTTP 402 와 크레딧 소진 본문 | OpenRouter 402(2026-11-13) |
| P2 스트림 도중 끊김 | SSE 를 몇 프레임 보내다 연결을 끊는다 | #51648 |
| P3 연결 실패 | TLS 경고를 내고 연결을 끊는다 | #51648 의 앞단계, `Tls_error` |
| P4 무응답 | 요청을 받고 아무것도 돌려주지 않는다 | #46722 |

P4 는 새 타임아웃 코드를 만들지 않는다. 시험 binding 의 클라이언트 timeout 설정을 짧게 두고, 이미 있는 `Llm_provider.Http_client.Timeout` 경로가 끝나는 것을 본다. 상상한 프로파일을 더 넣지 않는다. 위 넷 외에는 다음 실측 사건이 가져온다.

### 2.3 각 시험이 고정하는 것

각 프로파일 시험은 생산 호출 체인을 통과한 뒤 세 가지를 고정한다.

1. **내려오는 typed 모양**: 그 와이어가 어느 `Agent_core.Error.t` 변형인지. 402 가 지금 문서상 어디에 담기는지 확정된 값이 없다. 재생 시험이 이 값을 처음으로 고정한다.
2. **crash 계정과 상태**: RFC-turn-failure-visible-stop 의 규칙대로 첫 실패부터 계정에 오르고 Failing 이 보이는지.
3. **후보 회전**: `Keeper_runtime_attempt` 의 회전 조건이 그 실패 클래스에서 무엇을 정하는지. #28072 부류의 회귀(영구 결함을 일시적으로 분류해 유료 재시도가 무한히 늘기)가 여기서 잡힌다.

판정 서버(TypeSafe) 프로파일은 2단계다(§5 D2). #52386 이 방금 병합돼 측정(#52403)을 기다리는 중이니, 그 측정이 프로파일 목록을 채운 뒤에 붙인다.

## 3. 증명

- 규칙이 돌아가는지는 다음 실제 provider 사건으로 잰다. 이슈가 열리거나 사건이 기록된 시각부터, 그 와이어 모양의 재생 시험이 커밋되기까지 하루 안이다. 셈 방법을 바꾸지 않고 계속 잰다.
- 재생 통과가 실전 안전을 말하지 않는다. 대역은 진짜 provider 가 아니고, 실측되지 않은 행동은 내보내지도 않는다. 이 문장은 AWS Emulator 문서가 자기 제품에 대해 스스로 못박은 것과 같은 못박이다.

## 4. 하지 않는 것

- 방언 전체 프로토콜 흉내를 새로 쓰지 않는다. `Llm_provider` 가 이미 말하는 방언을 그대로 쓴다.
- CI 에 서비스나 run 을 추가하지 않는다(사용자 결정 2026-11-12). 기존 테스트 binary 안에서만 돈다.
- 보안·인가 시험 주장을 하지 않는다. 대역은 자격 평가를 흉내 내지 않는다.
- Gate·누적 상한·문자열 분류기를 만들지 않는다. 재생은 있는 규칙을 검사할 뿐 새 규칙을 만들지 않는다.
- lib 노출을 하지 않는다. test/ 공용 모듈로 시작한다.

## 5. 열린 결정

- **D1 1단계 방언.** 정석 추천: GLM 방언(`kind = "glm"`). 근거: #51648 의 21건이 가장 큰 사건 뭉치고 P2·P3 가 그 사건의 와이어 모양이다. 대가: 다른 방언의 사건은 다음 사건이 올 때까지 기다린다.
- **D2 판정 서버 재생 포함 여부.** 정석 추천: 2단계로 미룬다. 근거: TypeSafe 클라이언트는 모델 binding 과 다른 길이고(#52386 스택이 방금 병합됐다), #52403 측정이 남아 있다. 대가: 판정 서버 사건은 1단계가 끝날 때까지 값 주입·사후 분석에 남는다.
- **D3 P4 무응답의 끝.** 정석 추천: 시험 binding 의 timeout 설정으로 끝낸다. 새 타임아웃 코드가 없다(forbidden#budget_gate 와 같은 방향). 대가: timeout 값보다 긴 실제 정체는 이 시험이 담지 못한다.

## 6. 이력

- 2026-11-17 초안. 배경 연구: `~/me` `knowledge/research/2026-11-17-masc-provider-failure-emulator.md`(jeong-sik/me PR #1339, AWS Emulator 소식에서 패턴을 뽑았다).
