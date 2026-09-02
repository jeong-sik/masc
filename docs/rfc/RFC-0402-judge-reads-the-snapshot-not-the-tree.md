---
rfc: "0402"
title: "판정자의 읽기 경로 — 지금은 제출 스냅샷과 스필이 정본이고, sandbox 읽기는 트리를 소유한 레인이 생긴 뒤에 돌아온다"
status: Draft
created: 2026-09-02
updated: 2026-09-02
author: claude (codex-mcp-client) + Vincent
supersedes: []
superseded_by: null
related: ["0387", "0398", "0400", "0401"]
---

# RFC-0402: 판정자의 읽기 경로

## 0. Summary

완료 판정자(`lib/completion_authority_agent.ml`)는 producer 의 트리를 읽으려고
`tool_read_file`·`tool_search_files` 를 받는다(`lib/verification_authority_tools.ml:13-15`,
`:68`). 그런데 세 레인 중 둘에서 그 읽기는 구조적으로 실패한다.

- microvm: 판정자는 자기 턴이 없어 sandbox factory 가 없고, 코드는 그 경우를 typed 로
  거절한다(`lib/keeper/keeper_sandbox_read_backend.ml:198-233`, 주석
  `lib/verification_authority_tools.ml:279-282`). 전 기간 44건. RFC-0400 뒤 guest 가 트리를
  소유하므로 호스트 존재 검사도 틀린 답을 낸다(`:348-387`, 33건).
- remote_ssh: 트리가 둘이다. 제출 스냅샷(`lib/workspace/workspace_verification_store.ml:787-832`)과
  커넥터가 저장한 artifact 는 호스트 트리를, 판정자의 읽기는 endpoint 트리를 본다. 그래서
  판정자가 찾는 파일은 호스트에 있고 endpoint 에 없다(#32568, 59건). 오류 문자열의 호스트
  경로는 `Keeper_remote_path.rewrite_output`(`lib/keeper/keeper_sandbox_remote.ml:440`)이
  되쓴 것이라 경로 버그처럼 보였다.
- docker: fallback 컨테이너 읽기는 daemon 이 없으면 `image_not_found` 다(#32570, 42건).

최근 7일 완료 판정 64건 중 47건이 sandbox 읽기 전부 실패다
(`~/me/artifacts/evidence/keeper-brief-gates-20260902/judge-lane-readable-weekly.json`).
승인은 인라인 스냅샷으로 났고, 거절 23건 중 읽기 실패를 근거로 든 것은 6건쯤이다. 즉
판정자는 이미 스냅샷으로 판정하고 있고, 읽기 도구는 실패 문장만 남긴다. 판정 프롬프트는
그 실패를 "쓸 수 없는 증거" 로 다루라고 하지만(`config/prompts/verification.md:33`),
못 읽은 것과 없는 것이 같은 문장으로 기록된다.

결정은 둘로 나눈다.

- **지금**: 판정의 정본은 제출 시점 스냅샷과 스필 파일(RFC-0401 §4)이다. 판정자에게는
  트리를 소유한 레인이 있을 때만 sandbox 읽기 도구를 준다. 지금 그 레인은 없으므로
  producer sandbox 읽기 도구는 노출하지 않는다.
- **방향**: 트리를 하나로 합친다. RFC-0400 이 microvm 에 한 일(guest 가 트리를 소유,
  Write/Edit 는 shim 경유)을 remote_ssh 와 커넥터 artifact 쓰기에도 적용하고, 그때
  판정자에게 트리 소유 레인을 통한 읽기 세션을 준다. 그 뒤 읽기 도구가 돌아온다.

이 RFC 는 "지금" 만 구현 범위다. "방향" 은 별도 RFC 다.

## 1. 지금 바꾸는 것

### 1.1 판정 도구 표면

`Verification_authority_tools.create ~config ~producer` 는 producer 의 `sandbox_profile` 로
도구 집합을 고른다. 닫힌 match 다.

| producer 트리 위치 | 지금 | 이 RFC |
|---|---|---|
| `Endpoint_owned` (microvm, remote_ssh) | Read_file, Search_files, Web_fetch | Web_fetch, Spill_read |
| `Shared_mount` (docker) | Read_file, Search_files, Web_fetch | Web_fetch, Spill_read |
| Workspace_producer (Goal proof) | Read_file, Web_fetch | 그대로 |

`Spill_read` 는 검증 저장소 아래 스필 파일(RFC-0401 §4)의 구간을 읽는 도구다. producer
트리가 아니라 검증 저장소를 읽으므로 레인과 무관하다. RFC-0401 §4 가 먼저 들어와야 한다.
스필이 없는 동안은 Web_fetch 만 남는다.

### 1.2 프롬프트

`config/prompts/verification.md` 의 lookup 절은 "이 producer 의 트리는 판정자가 읽을 수
없다. 스냅샷과 스필이 전부다" 를 typed 로 렌더한다(프롬프트 자산 세 자리 등록 규칙은
RFC-0401 §3 과 같다). "파일이 없다" 는 문장은 스냅샷이 `Evidence_artifact_unreadable(missing)`
을 들 때만 나온다. 판정자가 시도하지 않은 읽기를 실패로 적을 일이 없어진다.

### 1.3 제출 경계

바뀌지 않는다. `artifact:` 참조는 지금처럼 제출 시점에 스냅샷된다. 스냅샷이 호스트
트리를 읽는다는 사실(`workspace_verification_store.ml:808-832`)이 곧 "정본은 호스트 트리"
라는 뜻이다. producer 가 guest 트리에만 쓴 파일은 스냅샷에 못 들어간다. 그건 이 RFC 가
숨기지 않는다. 아래 측정이 그걸 센다.

## 2. 측정

`goal-judge-lane-readable-20260902` 의 metric 을 바꾼다. 지금 metric(판정자 sandbox 읽기
전부 실패 비율)은 읽기 도구를 빼는 순간 0 이 되어 아무것도 말하지 않는다. 정본이 스냅샷이면
재야 할 것은 스냅샷이 못 읽은 비율이다.

- 새 metric: 최근 7일 검증 요청의 `artifact:` 참조 중 스냅샷 시점에
  `Evidence_artifact_unreadable` 인 비율. 2026-09-02 실측은 전 기간 3,097건 중 1,571건(51%,
  missing 1,141 · invalid 424).
- target: 0. 이 숫자를 내리는 것은 이 RFC 가 아니라 "방향"(트리 하나)이다. 이 RFC 는
  판정자가 거짓 실패를 적는 것을 멈출 뿐이다.

캠페인 점수판(#32567)의 판정 레인 preflight(Goal 0b)는 이 metric 이 재는 것과 같다.
스냅샷이 producer 의 artifact 를 못 읽으면 라운드는 무효다.

## 3. 하지 않는 것

- 판정자가 호스트 트리를 직접 읽게 하지 않는다. remote_ssh 는 살지만 microvm 은 그대로이고,
  "판정자는 host 를 몰래 들여다보지 않는다" 는 기존 경계(`verification_authority_tools.ml:279-282`)를
  깬다.
- 읽기 실패 문자열을 분류해 "레인 문제" 와 "파일 없음" 을 가르는 코드를 넣지 않는다.
  시도를 없애면 분류할 문자열도 없다.
- docker daemon 을 살리거나 endpoint 에 `rg` 를 넣는 일은 #32570 이다. 이 RFC 뒤에도
  keeper 자신의 턴 읽기에는 필요하다.

## 4. 순서

| 단계 | 내용 | 닫히는 것 |
|---|---|---|
| 1 | RFC-0401 §4 스필 + `Spill_read` 도구 | `goal-verification-input-spills-20260902` |
| 2 | `create` 의 profile 별 도구 집합, 프롬프트 lookup 절 | #32568, #32569 의 "지금" 부분 |
| 3 | Goal 0b metric 을 스냅샷 unreadable 비율로 교체(`masc_goal_upsert` update) | `goal-judge-lane-readable-20260902` |
| 4 | 트리 하나 RFC (remote_ssh·커넥터 쓰기의 shim 경유, 판정 읽기 세션) | #32569 의 "방향" |

## 5. 열린 결정 — Vincent 결정 대기

1. 1.1 의 표에서 docker(`Shared_mount`)도 읽기 도구를 뺄지. daemon 이 살아 있으면 지금
   경로가 동작한다. 빼면 레인 셋이 같은 규칙이 되고, 두면 docker 만 예외가 된다.
2. 스필이 들어오기 전에 2 단계를 먼저 넣을지. 먼저 넣으면 판정자는 한동안 Web_fetch 만
   갖는다. 승인 24건이 인라인 스냅샷으로 났으니 판정은 계속 되지만, 큰 artifact 는
   `truncated=true` 로 남는다.

관련: #32568, #32569, #32570, RFC-0400, RFC-0401 초안 #32565, E0 점수판 #32567.
계획 문서: https://claude.ai/code/artifact/dfe118e1-b5e0-4a0b-a3aa-261acd65a8e4
