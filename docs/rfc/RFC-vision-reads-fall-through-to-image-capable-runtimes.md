---
rfc: "vision-reads-fall-through-to-image-capable-runtimes"
title: "이미지 읽기는 목록이 막히면 이미지를 받는 다른 runtime 으로 넘어간다"
status: Dropped
created: 2026-11-21
updated: 2026-11-22
author: claude
supersedes: []
superseded_by: null
related: ["exact-lane-waits-for-a-stated-reset", "exact-lane-walks-one-slot-list"]
---

# RFC: 이미지 읽기는 목록이 막히면 이미지를 받는 다른 runtime 으로 넘어간다 — 하지 않는다

- 상태: Dropped. 제안(꼬리)은 하지 않는다. 이 문서는 하지 않는 이유와 대신 한 일만 적는다.

## 1. 제안이었던 것

`[runtime].media_failover` 의 runtime 이 모두 쉬면, 이미지 입력을 선언한 나머지 runtime 을 그 뒤에 이어 걸었다. 증상은 keeper 의 화면 읽기가 `media_failover` 후보 둘이 한도에 걸려 멈춘 것이었다.

## 2. 하지 않는 이유

- **후보가 너무 많이 붙는다.** 이미지 입력을 선언한 model 에 묶인 binding 중 `media_failover` 에 없는 것을 `python3 tomllib` 으로 셌다(2026-11-21 밤).
  - 라이브 `~/me/.masc/config/runtime.toml`: binding 177개 중 목록 3개 뒤에 HTTP 29개와 공식 클라이언트(`codex-app-server`·`claude-code`) 31개, 모두 60개가 붙는다.
  - 배포 기본 `config/runtime.toml`(`3e2f6b7bb0`): binding 133개 중 목록 1개 뒤에 HTTP 33개와 공식 클라이언트 38개, 모두 71개가 붙는다.
- **keeper 를 오래 붙잡는다.** 후보 하나의 상한은 라이브 `provider_call_deadline_sec = 900` 이다. 읽기는 턴 안에서 동기로 돌고 걸음 전체의 상한이 없다. 후보가 모두 시간 초과하는 최악은 HTTP 29개만 이어도 29 × 900초 ≈ 7.25시간, 60개면 15시간이다(산술, 측정하지 않음). `media_failover` 3개는 45분이다.
  - 실측: `~/me/.masc/tool_calls/2026-11` 의 11-19~21 `keeper_analyze_image` 519건(직접 센 값은 518건)을 두 번 따로 센 결과, 성공 495건은 p50 약 25초, p99 178초였고 실패 한 건이 900.0초였다.
- **숫자 상한으로 막을 수 없다.** 걸음 길이를 후보 수로 자르면 `docs/constitution.xml` 의 `magic_number`·`budget_gate` 에 걸린다.
- **운영자가 일부러 뺀 runtime 이 불린다.** 배포 기본 설정 주석은 느린 로컬 모델을 목록에서 일부러 뺐다고 적는다. 꼬리는 그 선택을 뒤집는다.
- **선행 사례가 있다.** #35179 (이슈 #34823, 2026-09)가 같은 모양의 「선언된 모든 runtime」 꼬리를 없앴다. 그때의 이유(로컬 본문 상한 `Config` 오류)는 #36828 이 없앴지만, 후보가 늘면 후보별 로컬 거절이 걸음을 끝내는 같은 구멍이 남는다(아래 3장).

## 3. 대신 한 것

- **가려진 실패를 드러냈다(#54332).** 호출했다 실패한 runtime 의 실패가, 뒤에 있는 쉬는(held) runtime 의 hold 에 가려지던 것을 고쳤다.
- **후보별 로컬 거절이 걸음을 끝내지 않게 했다(#54339).** `AcceptRejected` 는 호출자 배선만이 아니라 후보별 요청 검증(`packages/agent_core/lib/llm_provider/complete_common.ml` 의 `validate_common`)에서도 나온다. 이 RFC 초안의 「남은 로컬 거절은 호출자 배선뿐」은 틀렸다. 이제 `AcceptRejected` 는 후보 하나의 판정이고 걸음은 다음 후보로 넘어간다.
- **운영 설정으로 후보를 늘렸다.** `media_failover` 에 `glm-coding.glm-5.3-flash` 를 셋째로 더했다(2026-11-21 밤, 서버 재시작 전).
- **이미지를 못 받는 runtime 에 묶인 keeper 를 이미지를 받는 lane 으로 옮겼다.** 이미지 입력을 선언한 runtime 이면 화면 결과가 모델 입력에 바로 붙어서(`keeper_tools_agent_core_bundle.ml` 의 `image_admission`) 서브콜이 필요 없다.

## 4. 다시 열 조건

후보 목록이 운영자 손에서 계속 말라 같은 사고가 되풀이되고, 읽기를 턴 밖으로 떼는 변경(걸음이 턴을 붙잡지 않게 하는 것)이 먼저 들어간 뒤에 연다. 그때도 꼬리 길이를 후보 수로 자르지 않고 걸음이 턴을 붙잡지 않는 구조로 푼다.
