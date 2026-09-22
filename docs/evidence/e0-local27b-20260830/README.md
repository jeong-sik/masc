# E0 캠페인 실행 `e0-local27b-830b` — 2026-08-30

E0 멀티 키퍼 협업 캠페인을 한 번 돌린 원본 기록이다.
2026-08-30 13:16Z 에 사전 점검을 통과했고 14:34Z 에 멈췄다.
[#31845 코멘트](https://github.com/jeong-sik/masc/issues/31845#issuecomment-5469311783)가 이 폴더를 근거로 적었다.

## 이 실행으로 로컬 27B 를 평가할 수 없다

로컬 세 역할(coordinator, builder-a, builder-b)이 동시성 1짜리 런타임 하나를 같이 썼다.
그래서 로컬 역할의 실패 숫자는 모델 성능이 아니라 줄 서서 기다린 시간이다 (#31845).

이 폴더로 확인할 수 있는 것은 두 가지다.

- 로컬 역할 턴 일부가 시작도 못 하고 `operation_state: "Queued"` 로 끝났다.
- `verifier_exact`(`glm-coding.glm-5.3`)가 task-009 제출을 거절했다. 요구한 artifact 가 sandbox 에 없었다. 사유는 `fatal.json` 의 `error` 에 있다.

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
