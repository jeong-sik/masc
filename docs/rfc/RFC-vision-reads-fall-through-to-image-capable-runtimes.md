---
rfc: "vision-reads-fall-through-to-image-capable-runtimes"
title: "이미지 읽기는 목록이 막히면 이미지를 받는 다른 runtime 으로 넘어간다"
status: Draft
created: 2026-11-21
updated: 2026-11-21
author: claude
supersedes: []
superseded_by: null
related: ["exact-lane-waits-for-a-stated-reset", "exact-lane-walks-one-slot-list"]
---

# 이미지 읽기는 목록이 막히면 이미지를 받는 다른 runtime 으로 넘어간다

## 0. 요약

텍스트 전용 runtime 이 돈 Keeper 가 화면 PNG 를 읽으려면 `keeper_analyze_image` 가 다른 모델을 부른다.
부를 수 있는 모델은 `[runtime].media_failover` 에 적힌 runtime 뿐이다.
2026-11-21 설정에는 둘이 적혀 있었다: `kimi_coding.kimi-for-coding` 과 `ollama_cloud.ollama-cloud-deepseek-v4-1-flash`.

- Ollama Cloud 는 주간 한도를 다 써서 2026-11-23T00:00Z 까지 쉬었다. 읽기는 Kimi 하나로 돌았다.
- Kimi 가 한 번 실패하면 부를 runtime 이 없었다. msx-retro-mania 가 화면을 못 읽었다.
- 이미지 입력을 받는 runtime 은 설정에 더 있다. 부르지 못한 것은 목록에 없어서다.

규칙은 하나다. **이미지 읽기의 후보는 `media_failover` 가 앞에 오고, 그 뒤에 이미지 입력을 받는 나머지 runtime 이 이어진다.**

- 앞부분(`media_failover`)은 운영자가 정한 순서다. 지금과 같다.
- 뒷부분은 목록에서 도출한다. 손으로 적지 않는다.
- 쉬는 runtime 을 빼고 순서를 정하는 규칙은 지금 것을 전체 목록에 한 번 적용한다.
- 설정 필드와 TUI·대시보드의 `media_failover` 설정면은 그대로 둔다.

## 1. 증상과 증거

### 1.1 읽기가 하루 약 240번 이 경로를 탄다

msx-retro-mania 는 11-19, 11-20, 11-21 에 `keeper_analyze_image` 를 각각 239, 243, 32번 불렀다.
같은 기간 `keeper_image_read`(모델이 직접 보는 도구)는 0번이다.
출처: `logs/system_log_2026-11-{19,20,21}.jsonl` 의 `keeper:msx-retro-mania tool_call tool=...` 줄.

### 1.2 읽은 runtime 은 Kimi 하나였다

`tool_calls/2026-11/` 의 `vision_candidate` 행(11-19 ~ 11-21 01:23Z)에서 성공 행은 약 500건이고 모두 `kimi_coding.kimi-for-coding` 이다.
Ollama Cloud 는 한 번도 불리지 않았다.
Ollama Cloud 의 `ollama.balance` 읽기는 `seven_day` 100% 사용, 리셋 `1795392000`(2026-11-23T00:00:00Z)을 11-21 13:53Z 에 보고했다.

### 1.3 Kimi 의 실패 4번이 모두 "11-23 까지 기다림"이 됐다

`runtimes_held` 결과 4건(11-20 01:02:51Z, 13:47:29Z, 14:11:46Z, 11-21 12:17:50Z)은 모두 같은 초에 있는 Kimi 후보 실패와 겹친다.
실패 종류는 `timeout`, `candidate_policy_error`, `transient_provider_error` 2번이다.
이 가림은 별도 수정으로 고친다(부른 runtime 의 실패가 쉬는 runtime 의 기다림보다 앞선다).
이 RFC 는 그 뒤에도 남는 문제를 다룬다: Kimi 가 실제로 쓸 수 없는 때 후보가 없다.

### 1.4 후보가 될 수 있는 runtime 은 더 있다

`runtime.toml` 에서 `supports-image-input = true` 인 모델과 같은 이름의 binding 을 센 근사값은 63개다.
provider 별로 openrouter 19, Claude Code 계정 runtime 26, Ollama Cloud 7, Kimi 5, Codex 5, GLM Coding Plan 1이다.
이 중 `media_failover` 에 있는 것은 둘이다.

## 2. 원인

이미지 읽기의 후보 집합이 설정의 손 목록 하나다(`keeper_vision_tool.ml` 의 `vision_runtime_candidates` 가 `Runtime_agent.media_candidates` 만 쓴다).
이 목록의 runtime 이 모두 쉬거나 실패하면, 이미지를 받는 runtime 이 설정에 더 있어도 읽기가 끝난다.
목록에 하나를 더 적으면 증상은 가라앉는다. 그 하나가 쉬는 날 같은 일이 다시 생긴다.

이미지를 받는 모델은 이미 모델 선언(`supports-image-input`)이 말한다.
후보를 손으로 적을 이유는 순서뿐이다.

## 3. 설계

### 3.1 후보 순서

1. 앞: `media_failover` 를 적힌 순서대로. 지금과 같다.
2. 뒤 1묶음: 앞에 없는 runtime 중 이미지 입력을 받는 HTTP runtime(`Agent_core`). `runtime.toml` 에 선언된 순서.
3. 뒤 2묶음: 앞에 없는 runtime 중 이미지 입력을 받는 공식 클라이언트(`Codex_app_server`, `Claude_code`). 선언된 순서.

묶음 순서는 exact lane 이 HTTP slot 을 먼저 걷고 `cli_slots` 를 나중에 걷는 규칙과 같다.
받는 판정은 지금 vision 도구가 앞부분에 쓰는 판정과 같은 함수를 쓴다(`caps_admit_required_modalities` 에 `["image"]`).
`Antigravity_cli`, `Muse_serve`, `Vibe_cli` 는 지금처럼 후보가 아니다.

### 3.2 쉼과 기다림

`Runtime_candidate_standing.order_exact` 를 위 전체 목록에 한 번 적용한다. 새 규칙은 없다.

- provider 가 시각을 말한 runtime 은 `held` 로 빠지고 부르지 않는다.
- masc 가 정한 쉼은 같은 묶음 안에서 뒤로 간다.
- 부를 runtime 이 하나도 없을 때만 `Vo_runtimes_held` 가 나온다.

### 3.3 하지 않는 것

- `media_failover` 를 지우지 않는다. TUI 선택기, 대시보드 설정, `/api/v1/runtime/config/routing`, 파서, 계정 제거 경로가 이 필드를 쓴다(파일 약 60개). 운영자가 앞 순서와 비용을 정하는 수단이다.
- 새 설정 필드를 만들지 않는다.
- 후보 수나 시간에 상한 숫자를 두지 않는다(헌법 `magic_number`, `budget_gate`). 순회는 첫 성공에서 끝난다.
- Keeper 턴이 이 후보로 넘어가는 경로는 만들지 않는다. `media_candidates` 의 호출처는 vision 도구 하나다.

### 3.4 바뀌는 곳

| 곳 | 변경 |
|---|---|
| `lib/runtime/runtime_agent.ml(i)` | 앞(`media_candidates_of`)은 그대로 두고, 뒤 두 묶음을 도출하는 함수를 더한다. |
| `lib/keeper/keeper_vision_tool.ml` | `vision_runtime_candidates` 가 앞+뒤를 `order_exact` 에 넘긴다. |
| `docs/RUNTIME-TOML-REFERENCE.md` | `media_failover` 가 앞 순서이고 뒤는 도출된다고 적는다. |
| `config/runtime.toml` 주석 | 같은 문장. |
| 시험 | 4장. |

### 3.5 이 꼬리를 한 번 없앤 결정(#35179)

`media_candidates_of` 는 예전에 `media_failover` 뒤에 선언된 나머지 runtime 을 모두 이어 붙였다.
#35179(2026-09, 이슈 #34823)가 그 꼬리를 없앴다.

- 이유: 부팅 검사가 배정, `media_failover`, verifier slot 의 runtime 만 검사했다. 꼬리의 runtime 은 검사를 받지 않았고, 걸음 중간에 로컬 요청 본문 상한 검사가 `Config` 오류를 냈다. `Config` 는 다음 후보로 넘어가지 않아서 뒤에 살아 있는 후보까지 막혔다.
- 그 결정은 "걸음이 닿는 범위는 부팅이 검사한 목록까지"였다.

이 RFC 는 그 이유가 지금은 성립하지 않는다고 본다.

- #36828(2026-09-16)이 요청 본문 상한 선언과 로컬 거절(`Request_body_too_large`)을 끝까지 없앴다. 클라이언트가 본문 크기를 재서 거절하는 곳이 없다. 크기는 provider 의 거절(413)이 판정한다.
- 남은 로컬 거절은 `AcceptRejected` 다. 호출자 쪽 transport 배선을 보내기 전에 거절한 것이라 모든 후보가 같은 배선을 거절한다(`keeper_vision_tool.ml` 의 `wiring_rejected`). 후보가 늘어도 걸음이 끝나는 조건은 같다.
- 계정이 거절한 runtime 은 걸음이 `Candidate_refused` 로 적고 다음 후보로 넘어간다.

꼬리가 지킬 조건은 하나다. 꼬리의 runtime 도 앞부분과 같은 함수(`caps_admit_required_modalities` 에 `["image"]`)로 이미지 입력을 받는지 본다. 이 함수는 dispatch 의 capability gate 와 같은 판정이라서, 꼬리가 gate 가 거절할 runtime 에 닿지 않는다.

확인 필요: 위 근거는 #36828 의 변경 설명과 `request_body_bytes` 검색 결과(진단 용도만 남음)다. 구현 PR 이 꼬리 runtime 의 시도 시점 거절 경로(`authorize_api` 거절, 공급자 오류)를 시험으로 확인한다.

## 4. 시험

기능 단위로 본다(헌법 `testing`).

- 앞 runtime 이 모두 쉬면 뒤 HTTP runtime 이 불린다. 뒤 HTTP runtime 도 모두 쉬면 공식 클라이언트가 불린다.
- 앞에 있는 runtime 은 뒤에 중복되지 않는다.
- 이미지 입력을 받지 않는 runtime 은 후보에 없다.
- 쉬는 뒤 runtime 은 부르지 않고, 모두 쉬면 `Vo_runtimes_held` 가 나온다.
- `test_keeper_vision_tool.ml` 에서 `vision_runtime_ids` 가 정확한 목록을 단언하는 시험은 시험용 `runtime.toml` 에 이미지 입력 runtime 이 앞 목록 밖에 있는지 보고 고친다.

## 5. 위험

- **비용.** 뒤 묶음에 토큰 과금 API(OpenRouter 등)와 구독 공식 클라이언트가 든다. 앞이 모두 쉬거나 실패했을 때만 불린다. 운영자가 뒤에서 특정 runtime 을 뺄 수단은 이 RFC 에 없다(6장 1번).
- **순회 길이.** 모든 provider 가 장애일 때 후보가 많아 순회가 길다. 후보 사이 대기는 지금처럼 `KeeperVision` 의 `candidate_backoff_*` 값이 정한다. 쉬는 계정은 `order_exact` 가 미리 빼서 보통 짧다.
- **선언은 있으나 실제로는 못 받는 runtime.** 400 으로 거절되면 다음 후보로 넘어간다. 거절당한 호출 한 번이 낭비다.

## 6. 열린 질문

1. 뒤에서 runtime 을 뺄 수단이 필요한가. 필요하면 목록이 아니라 runtime 선언의 닫힌 값으로 둔다.
2. 구독 공식 클라이언트(Claude Code, Codex)를 뒤 2묶음에 기본으로 넣는가. Sonnet 구독 토큰을 아끼려면 넣지 않는 쪽이 낫다. 넣지 않으면 HTTP runtime 이 모두 막힌 날 읽기가 끝난다.

## 7. 대안

| 대안 | 버리는 이유 |
|---|---|
| 손 목록에 runtime 을 더 적는다 | 지금 증상을 한 칸 미룰 뿐이다. 2026-11-21 에 GLM Coding Plan 한 줄을 임시로 더했다. |
| `media_failover` 를 지우고 전부 도출한다 | 설정면 약 60개 파일을 바꾸고, 운영자가 앞 순서와 비용을 정할 수단이 없어진다. |
| vision 전용 exact lane(`slots` + `cli_slots`)을 만든다 | 손 목록이 하나 더 생기고 설정면이 늘어난다. |
| Keeper 레인을 이미지를 받는 runtime 으로 바꿔 서브콜을 없앤다 | 서브콜이 필요한 일을 가장 직접 줄인다. 다만 텍스트 전용 레인을 쓰는 Keeper 는 계속 생긴다. 이 RFC 와 같이 쓴다. |

## 8. 적용

PR 하나다. `media_failover` 의 11-21 임시 항목(`glm-coding.glm-5.3-flash`)은 병합 뒤 지운다. 도출된 뒤 묶음이 같은 runtime 을 이미 포함한다.
설정 변경은 필요 없다. 서버를 다시 시작하면 반영된다.
