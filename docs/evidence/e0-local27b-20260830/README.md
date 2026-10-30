# E0 캠페인 실행 `e0-local27b-830b` — 2026-08-30

E0 멀티 키퍼 협업 캠페인을 한 번 돌렸을 때 러너가 쓴 파일 중 남은 것이다.
러너는 `health.json`, `raw/`, `observations/`, `keeper-status/` 도 썼지만 남지 않았다.
격리 base(`/private/tmp/e0base-830`)도 지금은 없다.
2026-08-30 13:16Z 에 사전 점검을 통과했고 14:34Z 에 멈췄다.
[#31845 코멘트](https://github.com/jeong-sik/masc/issues/31845#issuecomment-5469311783)가 이 폴더를 근거로 적었다.

## 이 실행으로 로컬 27B 를 평가할 수 없다

#31845 는 이 실행을 로컬 27B 평가로 쓸 수 없다고 적었다.
원인으로 든 "로컬 세 역할이 동시성 1짜리 런타임 하나를 같이 썼다"는 이 폴더에 없는 내용이다.
파일 26개 어디에도 동시성 설정이 없다.

파일이 보여 주는 것은 이렇다.

- 13:16:50Z 에 로컬 턴 셋(`parallel-builder-a`, `parallel-builder-b`, `parallel-coordinator`)이 같은 순간 `Running` 으로 시작했다.
  런타임 자리가 하나였다면 둘은 `Queued` 였어야 한다.
- `Queued` 턴 7개는 모두 같은 키퍼가 먼저 받은 턴이 아직 안 끝난 상태에서 제출됐다.
  builder-a 5개, builder-b 1개, coordinator 1개다.
- 같은 런타임의 builder-b 는 턴 셋을 7초, 41초, 13초 만에 끝냈다(`invalid-tool`, `debate-rebut`, `qa-test`).
  builder-a 는 한 턴도 끝내지 못했다.

그래서 "키퍼마다 앞 턴이 멈춰 뒤 턴이 밀렸다"와 "런타임 자리를 기다렸다"를 이 파일만으로는 가를 수 없다.
그걸 가를 턴 상태 전이 기록(`raw/turn-state-*`)은 남지 않았다.

그 밖에 확인할 수 있는 것은 이렇다.

- 실패한 12턴 중 7턴은 420초가 지날 때까지 `operation_state: "Queued"` 였다. 그 뒤 상태는 파일에 없다.
- `verifier_exact`(`glm-coding.glm-5.3`)가 task-009 제출을 거절했다. verifier 가 적은 사유는 "요구한 artifact 가 sandbox 에 없다"이고, `fatal.json` 의 `error` 에 있다.

## 구성

| 역할 | 런타임 |
|---|---|
| coordinator, builder-a, builder-b | `ollama.qwen3-8-27b` |
| researcher | `codex_subscription.gpt-5.6-sol` |
| reviewer | `codex_subscription.gpt-5-6-sol-high` |

격리 base 는 `/private/tmp/e0base-830`, 서버는 `127.0.0.1:8977` 이다.
커밋은 파일에 적힌 그대로 옮긴다.
`preflight.json` 의 `runtime_binary_commit`·`runner_source_sha` 는 `79f35e8`,
`fatal.json` 의 `source_sha` 는 `79f35e8`, `runner_source_sha` 는 `fe977da` 다.
두 커밋은 patch-id(`2747abb65b10`)와 작성 시각이 같다. `fe977da` 는 `79f35e8` 을 실행 도중(13:56:04Z) rebase 한 커밋이다.
러너는 기록하는 순간의 `git rev-parse HEAD` 를 적으므로, 러너 코드가 바뀐 것은 아니다.
`79f35e8` 은 GitHub 에 올라간 적이 없다.

## 턴 집계

`turns/` 파일 24개를 센 값이다.
실패한 12턴은 모두 420초 안에 끝나지 않은 턴이다 (`did not settle within 420.0s`).

| 역할 | 통과 | 실패 | 실패 중 `Queued` | 실패 중 `Running` |
|---|---|---|---|---|
| researcher | 4 | 0 | 0 | 0 |
| reviewer | 5 | 0 | 0 | 0 |
| builder-a | 0 | 6 | 5 | 1 |
| builder-b | 3 | 3 | 1 | 2 |
| coordinator | 0 | 3 | 1 | 2 |

#31845 코멘트 표는 coordinator 를 1턴으로 적어 로컬을 3/13 으로 셌다.
파일에는 coordinator 턴이 3개라 로컬은 3/15 다.

## 파일

- `preflight.json` — 부팅 뒤 사전 점검. 도구 39개, 필요한 스킬 참조, `status: passed`.
- `fatal.json` — 실행이 멈춘 시점의 기록. `status: failed`, 멈춘 사유(`error`), 역할별 키퍼와 런타임(`resources`), 끝난 턴 24개(`completed_turns`).
- `turns/<label>.json` — 턴 하나에 파일 하나. `fatal.json` 의 `completed_turns` 와 JSON 값이 같다.
