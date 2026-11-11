# Goal 검증 재시도 (Goal verification retry) 사용 가이드

> 대상 변경: #47185 (병합 2026-11-02T09:07:49Z, merge commit `cd48f4e10c08ec7893fea90fbf5a2eb87d818330`)
> 상태: **실험적 기능 표기 없음(기본 동작)** — 단, 아래 "검증 한계" 참고

## 무엇인가

Dashboard와 TUI에서 관측한 Goal 검증 요청을 명시적으로 재시도할 수 있다.
검증 중에는 기존 요청의 복구나 저장된 판정의 반영을 요청한다. Dashboard는
재시도와 기존 판정 반영을 구분해 표시한다. TUI는 반환 메시지를 보여 주며,
오류가 나면 결과를 확정할 수 없으므로 다시 시도하기 전에 Goal 상태를 확인하도록
안내한다.

같은 PR에서 Pause·Resume·Block·Unblock이 각자의 TUI 확인 키를 쓰도록 분리됐고, MCP progress 이벤트나 malformed 응답이 성공 전환으로 오인되지 않게 됐다. 기존 non-Goal MCP 쓰기의 응답 본문 타임아웃 동작은 그대로다.

## 켜는 법

**별도 스위치 없음 — 기본 켜짐.** `config/tools/masc_goal_transition.toml`에 이 동작을 끄는 토글은 없다(병합 트리 원문 기준).

## 요청과 재시도 조건

`masc_goal_transition`의 `action`을 `request_complete`로 지정한다. 화면에서 확인한
Goal 상태에 결속하려면 `expected_verification` 안에 `phase`와
`criterion_revision`을 넣고, 관측한 proof request가 있으면 `request_id`도 넣는다.
`request_id`는 최상위 인자가 아니다. `executing` 상태에서 관측된 verification이
idle일 때만 이 객체에서 `request_id`를 생략한다. 상태·기준·요청이 달라졌다면
서버는 거부하므로 다시 조회한 뒤 판단한다.

- **검증 중인 요청 재시도**: 관측한 `phase="verifying"`과 원래 `request_id`를
  사용한다. `evidence_refs`를 생략하면 제출 당시 스냅샷을 유지한다. 다른 증거
  스냅샷은 이전 검토가 아직 진행 중일 수 있어 거부된다. 원래 실행이 진행 중이거나
  원본이 없거나 일치하지 않아도 재시도가 거부될 수 있다.
- **판정이 이미 저장된 경우**: `verifying` 단계에서는 `evidence_refs`를 빼고
  판정 반영을 요청한다. 이후 상태를 다시 확인한다.
- **REJECT 판정 후 새 제출**: Goal이 `executing`으로 돌아온 뒤 현재 표시된 상태와
  요청에 결속해 다시 완료를 요청한다. 이때 새 증거를 제출할 수 있으며 성공하면
  새 proof request가 만들어진다. 같은 기준에서 `evidence_refs`를 생략하면 이전에 제출한
  스냅샷을 유지한다.
- **workspace 경로 불일치**: 선택적으로 전달한 `expected_workspace`가 맞지 않으면
  Goal을 바꾸기 전에 전이가 거부된다. 효과를 확인할 수 없는 응답은 성공으로
  취급하지 말고 상태를 다시 확인한다.

## 실행 예시

먼저 `masc_goal_list`를 `goal_id`로 불러 그 Goal의 전체 행을 읽는다. 목록 행은
`detailed=true`일 때만 `verification`을 싣는다. 그 항목의
`phase`와 `criterion_revision`을 사용한다. `verification.completion.state`가
`proof_pending`이면 같은 `completion`의 `request_id`를, 판정이 있으면
`completion.verdict.request_id`를 확인한다. `verification.completion.state`의
`stale_criterion`은 이전 기준의 기록이고, `verification.state`의 `ledger_error`는
원장 조회 실패이므로 현재 요청으로 추정하지 않는다.

아래는 검증 중인 요청을 재시도하는 `masc_goal_transition` 인자다. 꺾쇠 안에는 실제로
관측한 값을 넣는다. 기존 증거를 유지하도록 `evidence_refs`는 생략했다.

```json
{
  "goal_id": "goal-...",
  "action": "request_complete",
  "expected_verification": {
    "phase": "verifying",
    "criterion_revision": "<표시된 기준 revision>",
    "request_id": "<표시된 proof request id>"
  }
}
```

`executing`이고 verification이 idle인 최초 제출에서는 `phase`를 `"executing"`으로
지정하고 `request_id`를 생략한다. 제출할 증거가 있다면 최상위 인자로
`"evidence_refs": ["board:<post_id>"]`를 넣는다. 기존 판정이 표시된 `executing`
상태에서는 그 판정의 현재 `request_id`도 `expected_verification`에 넣는다.

## 끄는 법

**끄는 스위치 없음(기본 동작).** 이 기능은 `masc_goal_transition` 도구의 기본 동작이며 설정으로 비활성화할 수 없다.

## 검증 한계 (과장 없음)

이 PR의 Evidence 원문이 스스로 밝힌 한계를 그대로 옮긴다:

- "No CI completion, installed binary, deployment, or live mutation is claimed." — 완료된 CI·설치 바이너리·배포·라이브 변경 검증은 주장되지 않았다.
- 수정된 OCaml 소스는 파싱만 통과했고 OCaml 타입체크·빌드는 실행되지 않았다("Modified OCaml sources passed parsing only").
- 사전 리베이스 브라우저 실습은 synthetic API 대상이었고 live 서버 테스트가 아니었다.
- 동일 경로의 독립 마운트 서버를 구별하거나 작업 중 바뀐 workspace symlink를 고정하지 못한다.

**#47185 본문에는 설치·운영 환경 실측이 제시되지 않았다.** 본 가이드는 병합된 소스와 해당 PR 본문을 바탕으로 한 동작 설명이다.
