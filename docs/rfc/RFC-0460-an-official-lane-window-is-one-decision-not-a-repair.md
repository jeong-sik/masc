---
rfc: "0460"
title: "공식 클라이언트 레인의 창은 한 번의 결정이다 — 자른 뒤 고치지 않는다"
status: Draft
created: 2026-09-22
updated: 2026-09-22
author: vincent + claude
supersedes: []
superseded_by: null
related: ["keeper-context-window-in-tokens", "librarian-lifecycle"]
implementation_prs: []
---

# RFC-0460 — 공식 클라이언트 레인의 창은 한 번의 결정이다

## 0. 요약

Claude Code 와 Antigravity 는 상한을 먼저 자르고, 그 다음에 Librarian 앞머리를 읽고, 앞머리가 이기면 요약(working state)을 앞에 얹는다. 상한은 그 요약 바이트를 재 본 적이 없다. 그래서 요약을 실은 요청은 선언한 상한을 넘겨서 나간다.

#37821 은 조립이 끝난 목록을 한 번 더 잘라서 이를 막았다. 그 두 번째 자르기가 요약 바로 뒤 atom 들을 버린다. 그러면 **요약이 덮은 끝과 실제로 보낸 첫 atom 사이에 아무도 덮지 않는 구간**이 생긴다. 그 구간은 `own_first_atom` 이 애초에 막으려던 바로 그 구멍이다. 두 번 재는 대가로 지키려던 것을 두 번째 자르기가 깬다.

이 RFC 는 순서를 바꾼다. 앞머리를 먼저 읽고, 요약을 pinned 로 물린 채 상한을 재고, 그 결과로 **모양을 고른다**. 조립과 창은 그 뒤에 한 번씩만 돈다.

## 1. 결정

1. 공식 클라이언트 레인이 보내는 범위는 요약이 덮은 구간과 맞붙어 있어야 한다. 요약을 쓰면 `atom[e, N)` 을 싣는다. 못 실으면 요약을 쓰지 않는다. 그 사이는 없다.
2. 상한은 조립 전에 한 번 재서 **모양을 고르는 데** 쓴다. 조립한 목록을 다시 자르지 않는다.
3. 요약이 상한의 컷까지 닿지 못하면 요약을 버리고 요약 없는 모양으로 간다. 턴은 살린다. 대신 그 턴은 세고 로그로 말한다 (§7.1).
4. 거절은 요약 없는 모양도 안 될 때만 한다. 그때의 뜻은 하나다 — "선언한 상한이 hooks 컨텍스트와 atom 하나도 못 담는다". 설정 오류다.
5. 두 레인은 같은 함수를 쓴다. `allow_empty_history` 를 레인마다 다르게 주지 않는다.

## 2. 지금 무슨 일이 나나

모양은 셋이고, 셋째가 지금 나간다.

```
A)  요약[0, e)  +  atom[e, N)        요약을 쓴다
B)  요약 없음    +  atom[cut, N)      요약을 안 쓴다
C)  요약[0, e)  +  atom[e+d, N)      [e, e+d) 는 요약도 안 됐고 발송도 안 됐다
```

C 는 #37821 이 만든다. 로그는 `model input declared ceiling cuts the carried range again ... the working state is pinned and the atoms in front of it go` 로 몇 개를 버렸는지 말하지만, 버린 atom 들이 요약에 안 들어 있다는 말은 하지 않는다.

`own_first_atom` 은 반대 방향에서 같은 구멍을 막는다. 앞머리가 상한 컷보다 **뒤로** 물러나지 못하게 한다. 물러나면 `[e, cut)` 이 비니까. 그러니 이 레인은 같은 모양의 구멍을 한 자리에서는 금지하고 다른 자리에서는 만든다.

Antigravity 는 같은 자리가 다르게 틀려 있었다. 창이 `allow_empty_history:true` 로 돌아서 clamp 가 보장한 최신 atom 까지 버리고 요약만 내보낼 수 있었다 (#37827, #37835).

## 3. 왜 이렇게 됐나 — 순서

```
지금:  상한 컷 → own_first_atom → 앞머리 선택 → 조립 → 상한 컷 또
```

상한이 **요약을 알기 전에** 먼저 자른다. 그런데 요약을 실을지는 그 컷이 정한다 (`librarian_must_reach`). 컷이 앞머리를 정하고, 앞머리가 pinned 를 정하고, pinned 가 컷을 바꾼다. 고리다.

#37821 은 고리를 끊지 않고 마지막 칸을 한 번 더 돌렸다.

## 4. Agent Core 는 왜 한 번만 재나

`compose_carried_model_input` 에는 capacity 인자가 없다.

```
Agent Core:  앞머리/연속성 선택 (상한이 입력이 아님) → demotion → project_from_atom 한 번
```

한 번만 재도 되는 이유는 공급자가 typed `ContextOverflow` 를 돌려주기 때문이다. 넘치면 shrink 사다리가 capacity 를 반씩 줄여 다시 보낸다 (`RFC-keeper-context-window-in-tokens` §1.2).

공식 클라이언트 레인에는 그 신호가 없다. Antigravity 의 admission 오류 문구가 그대로 말한다 — "the CLI has no typed oversized-input refusal". 그래서 로컬 상한은 **뺄 수 없다**. 같은 RFC §13.6 이 이 레인을 예외로 적어 둔 이유다.

| | 크기 압력을 다루는 방법 | 창을 재는 횟수 |
|---|---|---|
| Agent Core | demotion + 공급자의 typed overflow → shrink 사다리 | 앞머리에서 한 번 |
| Claude Code | 선언한 `max-prompt-bytes` 로 로컬 컷 | 두 번 (#37821 이후) |
| Antigravity | 같음 | 한 번, 단 flag 가 front 에 따라 다름 (#37835 이후) |

여기서 나오는 결론은 "재지 말자" 가 아니다. **재되 한 번, 그리고 그 결과로 모양을 고르자** 다.

## 5. 설계

```
1. Librarian 앞머리를 먼저 읽는다.                 (상한 필요 없음)
2. 스냅숏이면 그 요약을 pinned 로 미리 물린다.
3. 그 상태로 상한 컷을 잰다                        → cut'
4. e >= cut'   → A 모양. atom[e, N) 을 싣는다.
                 cut' 정의상 이미 들어간다. 창은 조립 뒤 한 번, 아무것도 안 버린다.
5. e <  cut'   → 요약이 상한 컷까지 못 닿는다. 쓰면 반드시 C 가 된다.
                 요약을 버리고 B 모양. atom[cut, N).
6. B 도 안 되면 거절.
```

4 번이 들어가는 근거: `cut'` 은 요약을 pinned 로 물린 채 잰 컷이다. `e >= cut'` 이면 `atom[e, N) ⊆ atom[cut', N)` 이므로 요약과 함께 이미 상한 안이다. 조립 뒤 창은 확인만 하고 아무것도 안 버린다.

두 번 재는 것처럼 보이지만 성격이 다르다. 3 번과 5 번은 **결정**이고, 조립은 결정이 끝난 뒤 한 번, 창도 한 번이다. 지금처럼 조립한 목록을 다시 자르는 자리가 없다.

## 6. 없어지는 것

- #37821 의 두 번째 패스 전체
- `preamble_dropped` 보정, 그리고 두 번째 패스에서 preamble 이 두 번 잡히던 것 (`undroppable_bytes` 로 한 번, carried 목록 머리의 기존 preamble 이 atom 0 바이트로 또 한 번)
- `allow_empty_history` 를 레인마다 다르게 주는 것 (#37835 포함)
- `own_first_atom` 이 앞머리 선택에 들어가는 고리 — 3 번이 그 자리를 대신한다
- 두 레인이 서로 다른 모양인 것. 같은 함수가 된다

거절이 드물어지고 뜻이 분명해진다. 지금은 요약이 크면 턴이 죽는다. 이 설계에서는 5 번이 흡수하고 턴은 산다.

## 7. 정해야 할 것

### 7.1 요약을 버리는 게 맞나

Antigravity 주석이 반대 논거를 갖고 있다 — "요약 없이 다시 조립하면 몇 KB 벌고, 운영자가 손봐야 할 상한을 가린다".

일리 있다. 다만 그 문장은 *pinned 만으로 상한 초과* 인 띠를 말한다. 5 번은 두 모양 중 고르는 것이라 성격이 다르다. 그래도 **조용히 버리면 안 된다.** 요약을 못 쓴 턴은 카운터와 WARN 으로 보여야 한다. 안 그러면 Keeper 가 연속성을 영영 잃는 걸 아무도 모른다.

대안은 그 띠에서 거절하는 것이다 (지금 #37821 이 하는 것). 그러면 턴이 죽지만 운영자가 바로 안다.

**결정 필요**: 5 번(버리고 보이게) 인가, 거절인가.

### 7.2 공식 레인의 demotion

`Keeper_model_input_demotion` 은 Agent Core 경로에서만 쓴다. 공식 레인 세 파일에 한 번도 나오지 않는다.

Agent Core 는 압력이 오면 도구 결과를 스토어로 내려서 대화를 지킨다. 공식 레인은 레버가 "대화를 자른다" 하나뿐이다. 같은 상한에서 대화를 훨씬 많이 잃는다.

3 번 앞에 demotion 을 한 번 돌리면 5 번으로 떨어지는 경우 자체가 크게 준다. 범위가 이 RFC 보다 크므로 별도 항목으로 둔다.

**결정 필요**: 이 RFC 에 넣나, 뒤로 미루나.

## 8. 이행 순서

1. #37821, #37835 를 먼저 병합한다. 지금 나가는 두 결함(상한 초과, 답할 턴 없는 요청)을 멈추는 값이 있다.
2. 이 RFC 의 §5 를 `Keeper_official_client_host` 에 넣고 두 레인이 그것만 부르게 한다.
3. 그때 #37821 의 두 번째 패스와 #37835 의 front 별 flag 를 지운다. `RFC-keeper-context-window-in-tokens` §13.4 와 CHANGELOG 의 "on both lanes" 문장도 §5 의 말로 고친다.

2 번을 1 번보다 먼저 하면 그동안 결함이 계속 나간다. 1 번을 하고 3 번에서 지우는 것이 레거시를 남기는 게 아니다 — 두 PR 은 지금 켜져 있는 결함을 끄는 값이 있고, §5 가 들어오는 순간 같은 커밋에서 사라진다.

## 9. 측정

- C 모양이 몇 번 나갔는지: `model input declared ceiling cuts the carried range again` 줄의 `dropped_atoms` 합. 이 RFC 가 들어가면 0 이어야 한다.
- 요약을 못 쓴 턴 수 (§7.1 의 카운터). 0 이 아니면 그 Keeper 의 상한이나 Librarian 흡수 속도를 봐야 한다.
- 두 레인의 거절 수. §5 뒤에는 설정 오류일 때만 나와야 한다.

## 10. 확신도

- §2 (C 모양이 나간다), §3 (순서), §4 (Agent Core 는 capacity 인자가 없다): 코드 경로를 다 읽었다. 높음.
- §5 의 4 번이 "정의상 들어간다": `project_with_drop` 이 pinned 를 undroppable 로 먼저 물리는 것을 읽고 유도했다. 높음. 다만 구현할 때 preamble 이 어느 쪽에 잡히는지 한 번 더 확인해야 한다.
- §7.2 (demotion 이 5 번을 줄인다): 방향은 맞지만 얼마나 줄이는지는 안 재 봤다. 낮음.
