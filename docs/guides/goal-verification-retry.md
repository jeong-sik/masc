# Goal 검증 재시도 (Goal verification retry) 사용 가이드

> 대상 변경: #47185 (병합 2026-11-02T09:07:49Z, merge commit `cd48f4e10c08ec7893fea90fbf5a2eb87d818330`)
> 상태: **실험적 기능 표기 없음(기본 동작)** — 단, 아래 "검증 한계" 참고

## 무엇인가

Dashboard와 TUI에서 관측된 Goal 검증(verification) 요청을 **명시적으로 재시도**할 수 있고, 재시도 결과를 네 가지로 구분해 보여준다:

- 새 요청 (new request)
- 재조정 (reconciliation)
- 거부 (refusal)
- 불명 효과 (unknown effect)

같은 PR에서 Pause·Resume·Block·Unblock이 각자의 TUI 확인 키를 쓰도록 분리됐고, MCP progress 이벤트나 malformed 응답이 성공 전환으로 오인되지 않게 됐다. 기존 non-Goal MCP 쓰기의 응답 본문 타임아웃 동작은 그대로다.

## 켜는 법

**별도 스위치 없음 — 기본 켜짐.** `config/tools/masc_goal_transition.toml`에 이 동작을 끄는 토글은 없다(병합 트리 원문 기준).

## 켜지는 조건과 실패 증상

`masc_goal_transition` 도구(wire name 그대로)의 `action="request_complete"` 재시도 규칙:

- **`request_id`를 주면**: 표시된 Goal phase·criterion·proof request에 결속된다. 서버가 변경된 phase·criterion·request를 거부한다("The server rejects a changed phase, criterion or request").
- **retry 때 `evidence_refs`를 생략하면**: 제출된 스냅샷을 유지한다("Omit on retry to keep the submitted snapshot").
- **retry 때 변경된 evidence를 주면**: 새 요청이 생성된다("supplying changed evidence creates a new request").
- **`request_id` 생략**: 관측된 verification이 idle일 때만 허용된다("Omit request_id only when the observed verification is idle").
- **workspace 경로 불일치**: Goal을 바꾸기 전에 전이가 거부된다("A mismatch refuses the transition before changing the Goal").
- **실패 증상**: 거부 시 Goal은 변경되지 않고 거부 사유가 Dashboard/TUI에 표시된다. 알 수 없는 효과(unknown effect)는 성공으로 표시되지 않는다.

## 실행 예시 (wire name 그대로)

```
masc_goal_transition
  goal_id     = "goal-..."
  action      = "request_complete"
  request_id  = "<표시된 proof request id>"   # idle이 아니면 필수
  evidence_refs = ["board:p-..."]             # 최초 제출 시; retry 때 생략하면 스냅샷 유지
```

## 끄는 법

**끄는 스위치 없음(기본 동작).** 이 기능은 `masc_goal_transition` 도구의 기본 동작이며 설정으로 비활성화할 수 없다.

## 검증 한계 (과장 없음)

이 PR의 Evidence 원문이 스스로 밝힌 한계를 그대로 옮긴다:

- "No CI completion, installed binary, deployment, or live mutation is claimed." — 완료된 CI·설치 바이너리·배포·라이브 변경 검증은 주장되지 않았다.
- 수정된 OCaml 소스는 파싱만 통과했고 OCaml 타입체크·빌드는 실행되지 않았다("Modified OCaml sources passed parsing only").
- 사전 리베이스 브라우저 실습은 synthetic API 대상이었고 live 서버 테스트가 아니었다.
- 동일 경로의 독립 마운트 서버를 구별하거나 작업 중 바뀐 workspace symlink를 고정하지 못한다.

즉 **설치·운영 환경에서의 실측은 아직 없다.** 본 가이드는 병합된 소스와 PR 본문 원문에서 옮긴 동작 설명이며, 운영 실측 결과가 아니다.
