---
rfc: "attached-service-tool-scoping"
title: "부착 서비스 도구를 매 턴 전량 싣는 것을 그만둔다"
status: Draft
created: 2026-08-29
updated: 2026-08-29
author: vincent
related: []
---

# RFC: 부착 서비스 도구 스코핑

## 0. Summary

내장 도구 축을 닫을 때 이런 관측이 있었다.

> 바이트의 본체는 이 축 밖에 있었다. (…) 부착 스코핑은 별도 축이다.

이 문서가 그 축이다. Keeper 가 OAuth 로 서비스를 한 번 붙이면, 그 서비스의 도구 스키마
전량이 **그 Keeper 의 모든 턴, 모든 provider 요청**에 실린다. 한 번도 호출되지 않아도
실린다. 2026-08-29 에 그것이 Keeper 하나를 멈춰 세웠다.

## 1. 관측 — 2026-08-29

전부 `<base-path>/wire-capture/2026-08/29*.jsonl` 의 `kind = "request"` 행과
`<base-path>/tool_calls/2026-08/*.jsonl` 에서 다시 잴 수 있다.

### 1.1 표면 크기

| keeper | 도구 수 | 스키마 바이트 |
|---|---|---|
| edgar.a.poe | 177–223 | 403,960 – 451,844 |
| 나머지 함대 8기 | 140 | 133,281 |

8/21 측정값은 중앙값 78,916B 였다. 8일 만에 중앙값 133,252B, 최대 451,844B 다.

### 1.2 그 바이트의 주인

edgar 의 마지막 요청(08:48:07Z, 177개 405,373B)을 접두사로 가른 값:

| 접두사 | 도구 수 | 바이트 | 비중 |
|---|---|---|---|
| amplitude | 41 | 238,087 | 58.7% |
| atlassian | 31 | 49,721 | 12.3% |
| masc | 43 | 31,884 | 7.9% |
| slack | 11 | 31,583 | 7.8% |
| github | 19 | 25,876 | 6.4% |
| keeper | 30 | 25,683 | 6.3% |

부착 서비스 4종이 345,267B — **표면의 85%** 다. 내장 도구(masc + keeper + 기타)는 60KB 다.

### 1.3 그중 실제로 쓰인 것

edgar 의 최근 7일 `tool_calls` 3,521건:

| 접두사 | 호출 수 |
|---|---|
| slack | 442 |
| atlassian | 130 |
| **amplitude** | **0** |

한 번도 부르지 않은 서비스가 요청 본문의 58.7% 를 차지했다.

### 1.4 그래서 무슨 일이 일어났나

edgar 의 런타임(`glm-coding.glm-5-turbo`)은 `max-request-body-bytes = 524288` 이다.
window 가 charge 하는 non-history reserve 는 도구 스키마 + 시스템 프롬프트 +
미측정 여유분이고, 실측 **469,638B** 였다. 남는 자리:

```
524,288 − 469,638 − 42,532(undroppable) = 12,118 bytes
```

히스토리에 12KB. 그 상태에서 overflow 가 나면 shrink 가 capacity 를 반으로 줄여
재시도했고(별도 결함, #31694 에서 수정), 결국 매 턴 실패했다.

### 1.5 그것이 세운 turn 은 412건이다

RFC 초안은 "Keeper 하나를 멈춰 세웠다" 로 적었다. 세운 수를 잰다.
`<base-path>/logs/system_log_2026-08-29.jsonl` 의 `turn completed ... stop=` 값:

| stop 사유 | turn 수 | 비중 |
|---|---|---|
| **Context overflow** | 412 | 58.5% |
| checkpoint sink failed | 183 | 26.0% |
| Rate limited (429) | 58 | 8.2% |
| Server error 500 | 17 | 2.4% |
| provider timeout | 11 | 1.6% |

turn completed 3,772건 중 704건이 error 로 끝났고, 그 **58.5% 가 이 축이다.**
overflow 는 07–08시(UTC)에만 났고 그 뒤 0건이다. 그 시간에 edgar 의 표면이
222개 449,554B 였고, 08시 이후 145개 142,257B 로 떨어졌다 — amplitude 가 통째로
빠졌고 atlassian 31→8, slack 11→4 로 줄었다. 즉 **이번엔 우연히 멈췄다.**
`Keeper_identity_switch` 는 운영자가 알아채야 작동하고, 다시 붙이면 그날로 재발한다.

§1.4 의 reserve 는 후보를 바꿔도 따라오지 않는다. 산식
(`keeper_turn_driver_try_provider.ml:500`)의 `capacity_bytes / 10` 항을 빼면 로그의
두 사례가 같은 수로 떨어진다:

- `capacity=65536  reserved=463084` → tool+system 456,531
- `capacity=524288 reserved=508959` → tool+system 456,531

capacity 를 8배 키워도 같은 456KB 가 먼저 예약된다. 더 큰 컨텍스트 후보로 넘겨서
푸는 문제가 아니라는 뜻이고, 반대로 `capacity=65536` 후보는 표면만으로 예산의 7배라
어떤 대화도 받지 못한다 — lane 후보 목록에 있어도 항상 실패하는 자리다.

### 1.6 색인으로 바꾸면 얼마인가

edgar 의 현재 표면(145개, 142,257B)을 다시 인코딩한 값:

| 형태 | 바이트 | 비중 |
|---|---|---|
| 전체 스키마 | 142,257 | 100% |
| 이름 + 한 줄 요약 | 13,116 | **9.2%** |
| 이름만 | 3,193 | 2.2% |

같은 날 `tool_name` 이 로그에 남은 호출은 **29종**이다 (145개 중 20%), 상위는
전부 `masc_*` 내장이다. 한 턴이 provider 요청 83건이므로 이 절감은 턴마다
83배로 곱해진다.

## 2. 문제의 모양

`Keeper_identity_tools.for_turn` 은 매 턴 이렇게 동작한다.

1. 선언된 provider 를 전부 순회한다
2. 이 Keeper 가 붙인 것의 catalog 를 읽는다
3. 그 catalog 의 **모든 도구**를 offering 에 넣는다

부착 = 전량 적재다. 그 사이에 "이 턴에 쓸 것 같은가" 라는 질문이 없다.

제어 수단은 하나 있다 — `Keeper_identity_switch` 로 (keeper, provider) 를 끌 수 있다.
2026-08-29 에 edgar↔amplitude 를 이걸로 껐고, reserve 는 469KB → 231KB 로 떨어진다.
하지만 스위치는 **운영자가 알아채야** 작동한다. 붙이는 순간 요청 본문의 절반이
사라진다는 사실은 어디에도 표시되지 않고, 붙인 뒤 한 번도 안 쓰였다는 사실도
아무도 말해주지 않는다. edgar 은 그 상태로 며칠을 돌았다.

## 3. 설계 후보

### A. 선언형 부착 스코핑

Keeper TOML 이 실을 provider 를 고른다.

- 장점: 기계가 이미 있다(switch store, `for_turn` 의 필터 지점). 선언 축만 추가하면 된다.
- 단점: 여전히 provider 단위 전부-아니면-전무다. atlassian 31개 중 2개만 쓰는 Keeper 도
  31개를 다 싣는다. 그리고 사람이 손으로 유지해야 한다.

### B. 지연 적재 (deferred / lazy)

부착 서비스 도구를 **이름 + 한 줄 요약**만 실은 얇은 색인으로 바꾸고, 스키마는 모델이
요청할 때 넘긴다. Claude Code 와 Codex 가 쓰는 방식이다.

실현 가능성의 근거: masc 의 한 턴은 provider 요청 여러 개로 이뤄진다 (라이브 wire
capture 기준 turn 12263 이 83건, 15638 이 62건). 요청 N 에서 모델이 검색 도구로
스키마를 받고, 요청 N+1 의 `tools` 에 그 도구가 포함되면 그 턴 안에서 호출까지 끝난다.
provider 프로토콜을 바꾸지 않아도 된다.

- 장점: 부착을 늘려도 표면이 선형으로 늘지 않는다. 사람이 유지할 목록이 없다.
- 단점: 왕복이 한 번 는다. 모델이 색인에서 원하는 도구를 못 찾으면 못 부른다 — 색인의
  이름과 요약 품질이 곧 도구 발견율이 된다. 그 품질을 무엇으로 재는지 정해야 한다.

#### B 를 막고 있는 것 — AGENT_CORE 의 도구 집합은 턴 중에 안 바뀐다

"요청 N+1 의 `tools` 에 그 도구가 포함되면" 은 지금 코드에서 성립하지 않는다. 세 곳을
읽으면 그 이유가 닫힌다.

- `agent_types.ml:142-154` 의 `Agent.t` 는 `state` 와 `lifecycle` 만 `mutable` 이고
  `tools : Tool_set.t` 는 불변 필드다.
- `agent.ml:165` 의 tool-round 루프는 `agent` 를 재바인딩하지 않는다. 루프 밖에서
  캡처한 같은 값을 매 round 넘긴다.
- `pipeline.ml:169` 의 `admit_tool_use_names` 는 `agent.tools` 로 만든 색인에 없는
  `tool_use` 를 히스토리 이전에 떨어뜨린다. 그래서 "스키마만 텍스트로 주고 부르게
  한다" 는 우회는 조용히 실패한다 — 모델은 부르고, 호출은 사라진다.

따라서 B 는 AGENT_CORE 변경을 선행으로 요구한다. 최소 형태는 `tools` 를 `mutable` 로
바꾸고 이미 있는 `mu : Eio.Mutex.t` 로 확장을 보호하는 것이다. 확장 자체의 선례는
같은 파일에 있다 — `agent.ml:663` 이 handoff 에서
`Tool_set.merge agent.tools (Tool_set.of_list handoff_tools)` 로 집합을 넓힌다.
영속화도 새로 만들 것이 없다: `checkpoint_types.ml:69` 에 `Replace_tools of
tool_schema list` 델타가 이미 있고 `checkpoint_delta.ml:149` 가 도구가 바뀌면 그것을
기록한다.

### C. 사용 기반 자동 축소

`tool_calls` 를 읽어 N일간 0회인 provider 를 자동으로 내린다.

- 이 저장소 방향에서는 채택하지 않는 쪽으로 본다. 과거 사실을 scheduling gate 로 쓰는
  모양이고(`projects.md` 의 autonomy 규칙), "안 썼으니 못 쓴다" 는 자기 실현이 된다.
  다만 §5 의 관측 지표로는 쓸 수 있다.

## 4. 결정

2026-08-29 에 넷 다 정했다.

1. **B 로 간다. A 는 하지 않는다.** A 의 선언 축은 B 가 오면 지워야 하는 죽은 축이고,
   §1.4 가 A 의 한계를 실측으로 보인다 — `Keeper_identity_switch` 는 있었지만
   운영자가 알아챌 때까지 412 turn 이 죽었다.
2. **색인 단위는 도구다.** 이름 + 한 줄 요약이 표면의 9.2%(13KB)이라 provider 단위로
   더 아낄 값이 크지 않고(이름만은 2.2%), provider 단위 색인은 모델에게 "amplitude 를
   쓸 수 있다" 까지만 말해서 무엇을 부를지는 여전히 모르게 둔다. 발견율을 색인 품질로
   판정하기로 한 이상, 판정 대상이 없는 색인을 고를 이유가 없다.
3. **발견 실패는 새 관측점으로 잰다.** `tool_search` 를 부른 뒤 그 턴에서 부착 도구
   호출이 0건인 turn 을 센다. §5 의 도구 호출 성공률과 같은 저장소(`tool_calls`)에서
   나오지만 같은 수가 아니다 — 이건 "찾지 못했다" 이고 저건 "불렀는데 실패했다" 다.
4. **내장 도구는 B 로 가지 않는다.** 같은 날 로그에 남은 호출 29종이 전부 내장이다.
   실사용률이 높은 축을 색인 뒤로 감추면 왕복만 늘고 아끼는 바이트는 없다. 내장
   57KB 는 상시 적재로 둔다. 이 결정은 §5 의 중앙값이 목표에 못 미치면 다시 연다.

## 4.5 구현 순서

세 단계이고 각각 별도 PR 이다. 1 이 없으면 2 는 조용히 실패한다(§3 B 의 제약).

**1. AGENT_CORE — 턴 중 도구 확장을 허용한다**

`Agent.t` 의 `tools` 를 `mutable` 로 바꾸고, 이미 있는 `mu` 로 보호되는 확장 함수를
연다. 축소는 열지 않는다 — 턴 중에 도구가 사라지면 진행 중인 `tool_use` 가
`admit_tool_use_names` 에서 떨어진다. 확장만 허용하면 그 경로가 생기지 않는다.
체크포인트는 `agent.tools` 를 읽으므로 별도 배선이 없다.

**2. masc — 부착 도구를 색인 뒤로 옮긴다**

`Keeper_identity_tools.for_turn` 은 지금대로 전량을 반환한다(그것이 진실이다).
바뀌는 것은 소비 지점이다: 부착 도구는 이름 + 한 줄 요약만 색인으로 싣고, 내장
도구는 그대로 싣는다. `tool_search` 가 색인을 질의해 스키마를 돌려주면서 1 의 확장
함수로 그 도구를 집합에 넣는다. 그 턴의 다음 요청부터 호출이 통과한다.

`extend_tools` 는 `Agent.t` 를 받는데 도구 핸들러는 그것을 쥐고 있지 않다. 배선은
읽어서 확인한 이 경로다. hook 으로는 안 된다 — `Hooks.hook` 은
`hook_event -> hook_decision` 이라 agent 가 없다.

| 자리 | 전 | 후 |
|---|---|---|
| `keeper_run_tools_setup.ml` | — | 셀을 여기서 만들고 `agent_setup` 레코드에 실어 올린다 |
| `keeper_agent_run.ml:839` | `agent_ref` 를 `prepare_agent_setup`(699) **뒤에** 만든다 | 올라온 셀을 쓴다 |
| `keeper_tools_agent_core_bundle.ml:538` | `identity_tools` 전량을 `Keeper_identity_gate.agent_tool` 로 만든다 | 목록 + `keeper_tool_search` 하나를 싣고, 핸들러가 셀을 캡처한다 |
| `keeper_turn_driver_try_provider.ml:903` | 시도마다 `local_agent_ref` 를 새로 만든다 | `ctx.agent_ref` 가 있으면 그것을 쓴다 |
| `keeper_tool_approval_policy.ml` | — | `keeper_tool_search` 를 `Control` 갈래에 넣는다 |

마지막 줄이 이 배선의 이음매다. 지금 `ctx.agent_ref` 는 `checkpoint_after_attempt`
에만 쓰이는 출력 채널이고, 실제 `Agent.t` 를 받는 것은 try_provider 안에서 시도마다
새로 만드는 `local_agent_ref` 다(903). 같은 셀을 쓰면 `runtime_agent.ml:1099` 가
agent 를 만든 직후 채우므로, 도구가 실행될 때는 이미 들어 있다. `checkpoint_after_attempt`
는 지금도 `!local_agent_ref` 를 받으므로 값이 달라지지 않는다.

*2026-08-29 반영됨.* 계획과 두 군데가 다르다. 셀은 optional 인자로 다섯 자리를
뚫는 대신 `agent_setup` 레코드에 실어 올렸다 — 도구를 만드는 자리에서 만들고 호출
자리가 받아 쓴다. 그리고 부착 도구와 셀은 한 레코드(`Keeper_identity_tool_search.surface`)
로 묶어서, 셀 없이 도구만 넘기는 호출을 타입에서 없앴다. 그 조합은 목록에 이름은
올라가는데 아무것도 부를 수 없는 턴이 되기 때문이다.

승인 정책 한 줄이 계획에 없었다. `Keeper_tool_approval_policy` 는 descriptor 가
없는 이름을 만나면 운영자에게 묻는데, 새 도구가 거기 걸려서 매 호출 승인 창을
띄울 뻔했다. 번들의 기존 가드(`the approval policy can classify every tool in it`)
가 잡았다. 이름을 읽고 집합을 넓힐 뿐 서비스에 닿지 않으므로 묻지 않고 실행하는
`Control` 갈래에 넣었고, 부착 도구 자체의 호출은 그대로 Gate 가 판단한다.

**3. 관측 — 발견 실패를 센다**

§4 결정 3 의 관측점. 이것이 없으면 §5 의 세 번째 지표를 읽을 수 없고, 설계가 옳은지
판정되지 않는다.

2 가 남긴 계측 구멍도 여기서 닫는다. `record_tool_assignment` 와
`record_requested_tool_names` 는 셋업 때 계산한 `all_tool_names` 를 넘긴다. 턴 중에
집합이 넓어지면 그 뒤 라운드의 기록은 실제로 실린 것보다 좁다 — 지금은 목록 도구
하나만 적히고 그 턴에 불러온 부착 도구는 안 적힌다. 관측점을 만들 때 라운드마다
살아있는 `agent.tools` 를 읽도록 같이 고친다. 따로 고치면 "무엇이 실렸나" 와
"무엇을 찾았나" 를 두 군데서 따로 세게 된다.

*2026-08-30 반영됨.* 결정 3 은 이 수를 `tool_calls` 에서 뽑는다고 썼는데, 그 저장소만
으로는 안 된다. 행은 도구 이름을 적지 그 도구가 어디서 왔는지는 안 적는다. 그래서
`github_pull_request_read` 를 부착 도구로 알아보는 방법이 이름 앞부분을 보는 것밖에
없고, 그건 이 저장소가 닫아둔 축이다(`software-development.md` 시그니처 2). 저장소에
출처 칸을 새로 다는 것도 답이지만, 그 칸은 여기서 세려는 수보다 훨씬 넓은 변경이다.

대신 도구를 만든 자리에서 센다. 목록이 무엇을 실었는지 알고, 실어준 도구를 한 겹 더
감싸 그것이 실행되면 표시한다. 턴이 끝날 때
(`run_with_setup_cleanup` 이 정상·예외 양쪽에서 보장하는 thunk) 셋 중 하나로 판정한다:

| 판정 | 뜻 | 기록 |
|---|---|---|
| `Listing_unused` | 모델이 목록에 묻지 않았다 | 없음 |
| `Loaded_and_used` | 물었고, 받은 것을 불렀다 | 없음 |
| `Loaded_unused` | 물었고, 받았고, 하나도 안 불렀다 | WARN + 이름들 |

분모는 여전히 `tool_calls` 다 — `keeper_tool_search` 행이 있는 turn 수. 분자만 로그에서
온다. 성공 케이스에 줄을 남기지 않는 건 WARN 노이즈를 늘리지 않기 위해서고, 분모가
저장소에 이미 있으므로 비율은 그대로 나온다.

## 5. 판정 기준

이 RFC 가 성공했는지는 다음으로 잰다. 전부 이미 있는 저장소에서 나온다.

- `wire-capture` request 행의 `tool_schema_bytes` 함대 중앙값
- 부착 서비스가 그중 차지하는 비중
- 도구 호출 성공률 — 지연 적재가 발견 실패로 호출을 잃으면 여기서 드러난다
- 발견 실패 turn 수 — `tool_search` 를 부르고도 부착 도구를 하나도 못 부른 turn.
  분자는 `keeper_attached_tool_loaded_unused` WARN, 분모는 `tool_calls` 의
  `keeper_tool_search` 행이 있는 turn 수
- `stop=error:Context overflow` turn 수 — 이 축이 세운 것을 직접 세는 지표

시작점 (2026-08-29): 중앙값 133,252B, edgar 최대 451,844B, 부착 비중 85%,
overflow 로 죽은 turn 412건(그날 turn 실패의 58.5%).

## 6. 하지 않는 것

- provider 의 스키마를 masc 가 줄여 쓰지 않는다. 원문이 계약이다.
- `max-request-body-bytes` 를 올려 표면을 수용하지 않는다. 그건 같은 낭비를 더 큰
  그릇에 담는 것이고, provider 가 그 크기를 받는지도 미검증이다.
