---
rfc: "0460"
title: "공식 클라이언트 레인의 창은 한 번의 결정이다 — 자른 뒤 고치지 않는다"
status: Draft
created: 2026-09-22
updated: 2026-10-07
author: vincent + claude
supersedes: []
superseded_by: null
related: ["keeper-context-window-in-tokens", "librarian-lifecycle"]
implementation_prs: ["#37879", "#41369"]
---

# RFC-0460 — 공식 클라이언트 레인의 창은 한 번의 결정이다

## 0. 요약

이 RFC가 다룬 결함은 창을 적용한 뒤 Librarian 요약(working state)을 붙이고 다시 자르면서 생긴 연속성 손실이다. 앞머리를 먼저 읽고, 요약을 pinned로 물린 조립 결과가 요약 없는 결과보다 atom을 더 밀어내는지 비교한다.

#37821 은 조립이 끝난 목록을 한 번 더 잘라서 이를 막았다. 그 두 번째 자르기가 요약 바로 뒤 atom 들을 버린다. 그러면 **요약이 덮은 끝과 실제로 보낸 첫 atom 사이에 아무도 덮지 않는 구간**이 생긴다. 그 구간은 `own_first_atom` 이 애초에 막으려던 바로 그 구멍이다. 두 번 재는 대가로 지키려던 것을 두 번째 자르기가 깬다.

현재 적용 범위(#41369): Antigravity와 Muse는 별도 시작 상한 없이 조립된 carried range를 보낸다. Claude Code와 Codex도 첫 시도에는 별도 시작 상한을 두지 않으며, typed overflow 뒤 재시도에서 받은 용량에만 창을 적용한다. 아래 비교 규칙은 로컬 상한을 요구하지 않는다. 범위를 자르지 않는 레인에서는 요약이 atom을 밀어내지 않으므로 요약을 그대로 싣는다.

## 1. 결정

1. 요약은 atom 을 밀어낼 때 싣지 않는다. 요약을 얹어서 범위의 atom 이 하나라도 더 빠지면, 요약 없이 같은 위치를 보낸다. 요약 뒤에 요약도 안 덮고 요청에도 없는 구간을 만들지 않는다.
2. 공급자 거절 뒤 재시도 용량이 주어지면 요약을 포함한 조립 결과로 **모양을 고른다**. 별도 시작 상한을 만들거나, 고른 목록을 다시 자르지 않는다.
3. 요약을 못 실으면 요약 없이 보낸다. 턴은 살린다. 대신 그 턴은 세고 WARN 으로 말한다 (§7.1). 요약이 상한에 아예 안 들어가는 경우도 같다.
4. 비교에서 거절은 요약 없는 모양도 조립되지 않을 때만 한다. 입력 투영 오류나 재시도 용량의 부족을 그대로 돌려준다. 모델 창이 작다는 이유로 시작 전에 거절하지 않는다.
5. 레인들은 같은 `compose_librarian_range` 규칙을 쓴다. 범위를 자르는지는 레인의 projection이 정한다.

## 2. 해결한 결함

모양은 셋이고, 셋째가 연속성을 깨뜨린다.

```
A)  요약[0, e)  +  atom[e, N)        요약을 쓴다
B)  요약 없음    +  atom[e, N)        같은 위치를 요약 없이. 상한이 자르면 A 와 똑같이 자른다
C)  요약[0, e)  +  atom[e+d, N)      [e, e+d) 는 요약도 안 됐고 발송도 안 됐다
```

C는 #37821에서 생긴 모양이다. 당시 로그는 버린 atom 수만 적고, 그 atom들이 요약에도 없다는 사실은 드러내지 않았다.

`own_first_atom`은 반대 방향에서 같은 구멍을 막는다. 앞머리가 창의 컷보다 **뒤로** 물러나면 `[e, cut)`이 비므로, 그 컷을 앞머리의 하한으로 삼는다.

Antigravity 는 같은 자리가 다르게 틀려 있었다. 창이 `allow_empty_history:true` 로 돌아서 clamp 가 보장한 최신 atom 까지 버리고 요약만 내보낼 수 있었다 (#37827, #37835).

## 3. 왜 이렇게 됐나 — 순서

```
결함이 있던 순서:  상한 컷 → own_first_atom → 앞머리 선택 → 조립 → 상한 컷 또
```

상한이 **요약을 알기 전에** 먼저 자른다. 그런데 요약을 실을지는 그 컷이 정한다 (`librarian_must_reach`). 컷이 앞머리를 정하고, 앞머리가 pinned 를 정하고, pinned 가 컷을 바꾼다. 고리다.

#37821 은 고리를 끊지 않고 마지막 칸을 한 번 더 돌렸다.

## 4. Agent Core 는 왜 한 번만 재나

`compose_carried_model_input` 에는 capacity 인자가 없다.

```
Agent Core:  앞머리/연속성 선택 (상한이 입력이 아님) → demotion → project_from_atom 한 번
```

한 번만 재도 되는 이유는 공급자가 typed `ContextOverflow` 를 돌려주기 때문이다. 넘치면 shrink 사다리가 capacity 를 반씩 줄여 다시 보낸다 (`RFC-keeper-context-window-in-tokens` §1.2).

공식 클라이언트도 레인별로 신호가 다르다. Claude Code와 Codex는 typed overflow 뒤 재시도 용량을 줄인다. Antigravity의 typed oversized 거절 부재는 로컬 바이트 상한을 두는 근거로 삼지 않는다(#41369). Antigravity와 Muse에는 조립된 범위를 넘기며, 클라이언트 내부의 압축·거절이 연속성을 보존하는지는 별도로 관측해야 한다(#41341).

| | 크기 압력을 다루는 방법 | 창을 재는 횟수 |
|---|---|---|
| Agent Core | demotion + 공급자의 typed overflow → shrink 사다리 | 앞머리에서 한 번 |
| Claude Code / Codex | 첫 시도는 전체 carried range, typed overflow 뒤에만 줄인 재시도 용량 적용 | §5의 모양 선택 안에서 적용 |
| Antigravity / Muse | carried range를 자르지 않고 전달; 클라이언트가 자체 입력을 처리 | 로컬 용량 창 없음 |

전송량 관측과 입력 제한은 다르다. 로컬 창이 없는 레인의 window observation도 carried front와 전송량을 기록하며, 조립 범위의 `atoms_kept`는 전체 carried atom 수다.

## 5. 설계

```
1. Librarian 앞머리를 먼저 읽는다.                      (상한 필요 없음)
2. 스냅숏이면 요약을 얹어 레인의 projection으로 조립한다.
3. 범위의 atom 을 하나도 안 버렸다               → A. 보낸다.
4. 버렸다 → 같은 위치를 요약 없이 다시 투영한다 (Librarian_progress, 스냅숏 끝).
5. 요약 쪽이 최신 atom 을 싣고, 요약 없는 쪽만큼 atom 을 실었다
                                                  → A. 상한이 둘을 똑같이 잘랐다.
6. 아니면                                         → B. 요약 없이 보낸다. WARN + 카운터.
7. B 가 조립되지 않으면 그 오류로 거절한다.
```

`Keeper_official_client_host.compose_librarian_range`가 이 규칙이다. Claude Code와 Codex는 `Host.start_range_projection`을 통해, Antigravity와 Muse는 `carried_history_projection`에서 이를 사용한다. 후자의 `compose`는 범위를 자르지 않아 3번에서 요약을 실은 결과를 고른다.

Host가 별도의 바이트 추정으로 컷을 정하면 실제 projection과 어긋날 수 있다. 그래서 각 레인이 조립한 결과의 **나간 atom 수를 비교**한다. Gate 참조처럼 source projection이 덧붙인 맥락은 durable atom 수에 넣지 않는다.

두 번 조립하는 건 요약을 못 실을 때뿐이다. 흔한 경우(요약이 들어간다)는 3 번에서 한 번으로 끝난다. 두 번째 조립도 "자르고 고치기" 가 아니다. 둘 중 하나를 고르고, 고른 것은 그 창이 남긴 그대로 나간다.

## 6. 없어지는 것

- #37821 의 두 번째 패스 전체
- 창이 preamble 을 두 번 매기던 것. `Host.window_carried_range`가 창에 넘기기 전에 preamble을 떼고, 아무것도 안 버렸으면 다시 붙인다. 이 창은 Claude Code와 Codex의 `start_range_projection`에서만 쓴다.
- `allow_empty_history` 를 레인마다 다르게 주는 것 (#37835 포함)
- Antigravity 창 관측이 떨어뜨린 preamble 을 durable atom 으로 세던 것 (`Int.min projection.dropped_atoms carried_atoms`). 범위가 assistant 턴으로 시작하면 하나 적게 보고하고 front 가 한 atom 늦었다. 위 창은 preamble 을 떼고 세므로 따로 보정할 것이 없다.
- 레인마다 요약의 atom 밀어내기를 다르게 판정하는 것. 같은 조립 규칙을 쓴다.

요약 때문에 atom이 더 밀려나는 경우는 6번이 흡수하고 턴을 계속한다.

`own_first_atom`은 남는다. 재시도 창의 컷이 앞머리의 바닥을 정하더라도, 요약이 그 뒤에 얹혀서 atom을 더 밀어내면 6번이 요약을 뺀다. 창이 없는 Antigravity·Muse는 이 값을 0으로 넘긴다.

## 7. 결정과 남은 것

### 7.1 요약을 버리는 게 맞나 — 버린다 (결정됨, 2026-09-22)

요약을 못 싣는 띠는 둘이다.

| reason | 뜻 | 저절로 풀리나 |
|---|---|---|
| `displaces_atoms`, `leaves_no_turn` | 요약을 얹으면 atom 이 밀려나거나 하나도 안 남는다. 대개 이력이 크고 Librarian 이 아직 못 따라온 자리 | 풀린다. Librarian 이 읽어 나가면 요약 끝이 앞으로 온다 |
| `does_not_fit` | 요약 자체가 상한에 안 들어간다 | 안 풀린다. 상한이나 요약 크기를 봐야 한다 |

첫 띠에서 거절하면 Librarian 이 따라잡는 동안 턴이 계속 죽는다. 고칠 것이 없는데 죽으므로 신호가 틀렸다.

둘째 띠에서도 요약 없는 결과가 조립되면 턴을 살린다. `reason=does_not_fit`으로 따로 세어 재시도 용량과 요약 크기를 조사할 수 있게 한다. 로컬 창이 없는 Antigravity·Muse에서 요약이 atom을 밀어낸다고 가정하지 않는다.

거절 자리는 §5 의 7 번 하나뿐이다. 요약 없는 모양도 조립되지 않을 때다.

B 모양이 연속성을 **지키는** 것은 아니다. 요약이 덮던 `[0, e)` 는 요청에서 빠지고, 그 atom 들은 Keeper 의 기억에만 있다. 지키는 것은 살아 있음이다. 그래서 조용히 버리지 않는다.

- 카운터: `masc_keeper_librarian_working_state_not_carried_total{keeper, runtime, reason}`
- WARN: `model input working state not carried runtime=… reason=… summary_end=… first_atom=…` 에 요약 쪽과 요약 없는 쪽이 각각 남긴 atom 수를 같이 적는다.

### 7.2 공식 레인의 demotion

`Keeper_model_input_demotion`은 Agent Core 경로에서 쓰며, 공식 레인의 입력 조립에는 적용하지 않는다.

Agent Core는 압력이 오면 도구 결과를 스토어로 내려서 대화를 지킨다. Claude Code·Codex의 재시도 창은 대화 범위를 줄이며, Antigravity·Muse는 로컬에서 자르지 않고 클라이언트의 입력 처리에 맡긴다. 공식 레인에 같은 demotion이 필요할지는 별도 측정 대상이다.

§7.1 을 연속성 기준으로 정했으므로 이 항목의 방향도 같이 정해진다. §5 의 3 번 앞에 demotion 을 한 번 돌리면 5 번(요약을 버리는 자리)으로 떨어지는 경우 자체가 줄고, 줄어든 만큼이 지켜진 연속성이다. **버리는 것보다 안 버리게 만드는 쪽이 먼저다.**

다만 이 RFC 의 §5 와 독립이다. §5 는 모양을 고르는 규칙이고 demotion 은 고르기 전에 압력을 줄이는 일이라, 순서만 정해지면 따로 들어갈 수 있다.

**결정 필요**: 얼마나 줄어드는지 먼저 재고 착수한다. 측정은 §9 의 세 번째 항목으로 붙인다.

## 8. 이행

§5의 공통 조립 규칙은 #37879가 넣었다. #41369는 이 규칙을 유지하면서 Antigravity와 Muse의 시작 입력 바이트 상한을 없앤다. 모델 `max-context`로 시작 용량을 계산하거나 별도 상한 선언을 요구하지 않는다.

## 9. 측정

- 요약이 나간 요청은 요약 끝부터 범위의 atom 을 모두 싣거나, 요약 없는 쪽과 똑같이 잘린다. 두 레인 테스트가 이것을 고정한다.
- 요약을 못 쓴 턴 수 (§7.1 의 카운터). `does_not_fit` 이 0 이 아니면 상한이나 요약 크기, 나머지가 계속 0 이 아니면 Librarian 흡수 속도를 본다.
- 로컬 조립 실패와 실제 클라이언트 거절을 구분해 기록한다. 시작 상한을 없앤 것이 공급자·클라이언트의 크기 제한까지 없앤 것은 아니다.
- §7.2 착수 전 근거: 요약을 못 쓴 턴 중, 그 턴의 도구 결과를 강등했다면 요약이 들어갔을 비율. 이 값이 작으면 demotion 은 이 문제의 답이 아니다.

## 10. 확신도

- §2·§3은 #37879가 고친 결함의 설명이다. 현재 레인별 범위는 §4와 #41369의 소스를 따른다.
- §5의 #37879 구현 당시 세 스위트와 돌연변이 테스트 결과는 당시 조립 규칙의 근거다. #41369의 상한 제거 뒤 실행 결과를 대신하지 않는다.
- §7.2 (demotion 이 5 번을 줄인다): 방향은 맞지만 얼마나 줄이는지는 안 재 봤다. 낮음.
