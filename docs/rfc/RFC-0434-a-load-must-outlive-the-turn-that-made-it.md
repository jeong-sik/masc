---
rfc: "0434"
title: "로드는 그것을 만든 턴보다 오래 살아야 한다 — 한 턴에 한 번만 쓰는 도구는 영영 못 불린다"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: vincent
supersedes: null
superseded_by: null
related: ["0433"]
---

## 1. 문제

운영자가 `sangsu` 에게 보이스로 답하라고 했다. 키퍼의 추론은 규칙을 정확히
말한다.

> "So this turn I must call keeper_voice_speak directly — no tool_search, no
> plan statement."

그리고 실제로 나간 호출은 `keeper_tool_search {"names":["keeper_voice_speak"]}`
였다. 2026-09-06 실측:

```
sangsu    keeper_tool_search   14회 (연속)
          keeper_voice_speak    0회
```

키퍼 자신의 기억 카드가 이미 적어 두었다 — *"m78이 기억된 뒤에도 2026-09-06
열한 차례 연속 재로드로 재발"*.

**규칙을 알고, 규칙을 말하고, 그다음 규칙을 어긴다.** 그러면 원인은 모델이
아니다.

## 2. 기전

`keeper_voice_speak` 는 `config/tools/keeper_voice_speak.toml` 에
`defer_loading = true` 다. deferred 도구가 불릴 수 있게 되는 경로는 하나다.

```
keeper_identity_tool_search.mli:53
  agent_cell : Agent_core.Agent.t option ref
    "The agent this turn is running ... deferred tools without a cell are
     tools this can name and never make callable."
```

**그 턴의 에이전트에만** 놓인다. 다음 턴에도 놓이려면 carry 집합에 들어야
하는데, 그 집합은 이렇게 만들어진다.

```
keeper_identity_tool_search.ml:294  carry_from_history
  observe 는 ToolUse 블록에만 돈다

mli:
  "Read from the tools' own [ToolUse] blocks, not from what was asked for.
   Asking is not evidence of need."
```

**검색은 호출이 아니다.** 그래서 carry 에 안 들어간다.

```
턴 N    voice_speak 필요 → 안 놓임 → tool_search
        tool_search 가 이번 턴 에이전트에 놓아줌
        ← 도구 호출이 턴을 끊는다. 에이전트 소멸.
턴 N+1  carry 는 ToolUse 만 본다. voice_speak 는 불린 적 없다.
        → 안 놓임 → 목록에 이름만 → tool_search
        GOTO 턴 N
```

`make` 의 주석은 회복 비용을 이렇게 적었다.

> "Recovering costs one round trip."

**그 왕복은 검색과 호출이 같은 턴일 때만 성립한다.** 도구 호출이 턴을 끊으면
전제가 깨지고, 왕복이 아니라 루프가 된다.

## 3. 이 저장소는 이미 이것을 알고 있다

`turn_discovery` 에 이름이 붙어 있다.

```ocaml
| Loaded_unused of string list
    (** It asked, loaded these, and called none of them. *)
```

그리고 `already_used` 의 주석이 그 실측을 적어 두었다.

> "A load reaches the agent of the turn that made it and no further, so
> without this the model re-asks every turn: measured 2026-08-30, one Keeper
> asked for [github_issue_read] on five consecutive turns and for
> [github_get_label] 34 times in a day, and **39 of 84 turns that used the
> listing loaded a tool the turn then ended before using**."

`already_used` 는 이 문제를 **두 번째 호출부터** 고친다. 한 번이라도 실제 호출이
들어가면 그 뒤로 carry 가 잡아 준다. 첫 호출이 영영 안 들어가는 경우는 안
고친다.

## 4. 왜 voice 만 갇히는가

2026-09-06 하루, `loaded_unused` WARN 19 건의 분포다.

| 도구 | 건수 |
|---|---|
| **`keeper_voice_speak`** | **14** |
| `masc_schedule_cancel` | 2 |
| `github_get_file_contents` | 2 |
| 나머지 6 종 | 각 1 |

| 키퍼 | 건수 |
|---|---|
| **`sangsu`** | **14** |
| `lane-smith` | 2 |
| `rondo` · `analyst` · `polisher` | 각 1 |

**대부분의 도구는 한두 번 겪고 빠져나온다.** 연달아 여러 번 쓰이는 도구라,
어쩌다 한 번 검색과 호출이 같은 턴에 성립하면 그 뒤로 `already_used` 가 잡는다.

`keeper_voice_speak` 는 반대다. **한 턴에 딱 한 번 단독으로** 부르는 도구이고,
m78 이 그렇게 지시하기까지 한다("첫이자 유일한 도구 호출"). 그래서 첫 호출이
성립할 창이 없고, 매번 처음부터 시작한다.

`config/tools/` 의 `defer_loading = true` 중 voice 계열이 넷이다 —
`speak`·`listen`·`session_start`·`sessions`. 전부 같은 모양으로 보인다.

## 5. 제안 — 직전 턴의 로드를 한 번만 이어 준다

carry(장기)와 별개로, **직전 턴이 로드했고 아직 안 쓴 이름**을 다음 요청 한 번만
놓아 준다.

```
carry        : 이 대화가 실제로 부른 도구      (기존, ToolUse 기반, 장기)
+ 이월 예약  : 직전 턴이 로드했고 안 쓴 이름   (신규, 한 요청만 유효)
```

- 한 번만 유효하므로 표면이 누적되지 않는다. `Loaded_unused` 가 두 턴 연속이면
  두 번째 이월은 없다 — 그 이름은 목록으로 돌아간다.
- `make` 주석의 "one round trip" 이 실제로 한 번이 된다.
- 이미 있는 값으로 만든다. `observe_turn` 이 `Loaded_unused of string list` 로
  그 이름들을 **이미 계산한다.** 새 관측을 안 만든다.

### 5.1 왜 검색을 carry 에 넣지 않는가

그것이 가장 단순하지만 mli 가 명시적으로 거부했고, 근거가 실측이다.

> "Asking is not evidence of need, and carrying every request grows the
> surface back toward the full attached list -- measured an hour after that
> change shipped, one Keeper was at 111 tools of a possible 133 and still
> climbing."

이 거부는 옳다. 다만 지금은 **부풀지 않는 대신 못 부르는** 상태다. 한 요청짜리
이월은 두 실패 사이를 지난다 — 누적되지 않고, 한 번은 부를 수 있다.

### 5.2 어디에 사는가

`already_used` 와 같은 자리다. 다만 그것은 히스토리에서 유도되고 이월은 직전
턴의 관측이라 **저장되는 상태가 하나 는다.** 그 값은:

- 키퍼 하나당 문자열 목록 하나
- 다음 요청에서 소비되고 비워진다
- 없어도 durable truth 가 안 상한다 — 없으면 오늘 동작으로 돌아간다

그러므로 체크포인트에 넣지 않는다. 재시작하면 비고, 그 턴은 오늘처럼 한 번 더
로드한다.

## 6. 무엇을 하지 않는가

- **`defer_loading` 을 끄지 않는다.** deferred 표면은 실측된 이유로 있다.
- **이름으로 특례를 만들지 않는다.** `keeper_voice_speak` 를 아는 코드를 넣지
  않는다 — 그러면 다음 도구가 같은 자리에서 다시 걸린다.
- **carry_window 를 늘리지 않는다.** 이 문제는 창의 길이가 아니라 **무엇을
  세느냐**다. 창을 무한히 늘려도 안 불린 이름은 여전히 안 들어간다.
- **turn 경계를 바꾸지 않는다.** 도구 호출이 턴을 끊는 것은 별개 사실이고,
  이 RFC 는 그 위에서 동작한다.

## 7. 검증

| 무엇 | 어떻게 |
|---|---|
| 로드 다음 턴에 부를 수 있다 | 로드만 하고 끝난 턴 다음 요청에 그 이름의 스키마가 있다 |
| 두 번은 안 이어진다 | 두 턴 연속 로드-미사용이면 세 번째 요청에는 없다 |
| 부르면 carry 가 인계한다 | 이월로 부른 뒤에는 `already_used` 가 잡는다 |
| 표면이 안 부푼다 | 로드-미사용을 반복해도 도구 배열 크기가 단조 증가하지 않는다 |
| 오늘 사례가 풀린다 | `sangsu` 가 `voice_speak` 를 실제로 부른다 |

네 번째가 이 RFC 의 안전선이다. 5.1 이 인용한 실측(133 중 111)이 다시 나면 이
설계는 틀린 것이다.

## 8. 위험

**한 요청이 맞는 창인지 모른다.** 로드한 턴이 다른 이유로 끊기고, 다음 턴도
안 부르고, 세 번째에 부르는 흐름이 있다면 이월이 짧다. 그 경우 오늘과 같아지고
나빠지지는 않는다. 창을 늘리는 것은 표면이 부푸는 쪽이므로, 늘리기 전에
`Loaded_unused` 가 두 턴 연속으로 나는 빈도를 먼저 잰다.

**저장되는 상태가 하나 는다.** 6 절의 이유로 durable 하지 않게 두지만, 상태는
상태다. 없어도 정확성이 안 상하는 것이 그 근거다.

## 9. 측정 근거

전부 2026-09-06, 이 워크스페이스.

```
sangsu           keeper_tool_search 14회 연속 / keeper_voice_speak 0회
                 (~/me/.masc/tool_calls/2026-09/06.jsonl)

loaded_unused    하루 19건
  keeper_voice_speak       14   (전부 sangsu)
  masc_schedule_cancel      2
  github_get_file_contents  2
  나머지 6종               각 1

키퍼별              sangsu 14 · lane-smith 2 · rondo/analyst/polisher 각 1
```

그리고 코드가 2026-08-30 에 이미 적어 둔 것:

```
github_issue_read   5 턴 연속 재요청
github_get_label    하루 34회
listing 을 쓴 84 턴 중 39 턴이 로드하고 안 쓰고 끝남
```
