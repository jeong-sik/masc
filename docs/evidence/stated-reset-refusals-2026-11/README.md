# 한도 표가 이미 알던 provider 행에 다시 보낸 호출 (2026-11-10 00:00Z ~ 11-15 10:00Z)

한 Keeper 가 한도 거절을 받으면 provider 가 말한 풀리는 시각이 한도 표에 적혀요.
같은 행을 쓰는 다른 Keeper 의 walk 는 그 표를 순서로만 읽어요. 부를 후보가 그것뿐이면 그대로 보내고 다시 거절돼요.
그런 호출이 몇 번이었는지 세요. RFC-provider-path-rest 6.1 의 근거예요.

`measure_stated_reset_refusals.py` 가 `~/me/.masc/logs/system_log_2026-11-1[0-5].jsonl` 을 읽기만 했어요.
11-15 파일은 서버가 아직 쓰는 중이라 `--until 2026-11-15T10:00:00Z` 로 잘랐어요.
출력에는 Keeper 이름과 provider 행이 없어요. 오류 글에 적힌 provider 이름(`claude_code`, `muse_serve` 등)만 나가요.

## 결과

`result-2026-11-10_to_11-15T10.json` 이에요. 그동안 서버가 29번 시작했어요.

| heartbeat 턴의 한도 거절(풀리는 시각까지 기다린 것) | 보낸 때 = composition 줄 | 보낸 때 = 시도 시작 |
|---|---:|---:|
| 전체 | 155 | 155 |
| 같은 프로세스의 다른 Keeper 가 보내기 전에 적음 (`known_from_another_keeper`) | 41 | 33 |
| 자기 앞선 거절만 적음 (`known_from_itself`) | 1 | 1 |
| 앞선 프로세스만 적음 (`known_before_restart`) | 69 | 77 |
| 처음 들은 시각 (`first`) | 39 | 39 |
| 보낸 때를 모름 (`no_dispatch_mark`) | 5 | 5 |

- 전체 155건의 provider 는 claude_code 135, muse_serve 8, codex_app_server 7, glm-coding 5 예요.
- `known_from_another_keeper` 41건은 Keeper 17명이 냈어요. claude_code 39건, muse_serve 2건이에요.
- 앞선 거절과 이 호출 사이는 중앙값 39초, 가장 길게 1,568초(26분)예요.
- 날짜별로는 11-12 에 22건으로 가장 많아요.
- `known_before_restart` 69건은 (서버 세대, provider 행) 짝 30개에서 나왔어요.
- `no_dispatch_mark` 5건은 모두 glm-coding 이에요. Agent Core HTTP 실행은 시작 줄을 Keeper 이름이 아니라 `agent_core-<runtime>` 이름으로 적어요.

## 판정 방법

거절 하나는 같은 Keeper 가 쓴 줄 세 개가 짝을 이룬 것이에요.

1. `<keeper>: turn terminal (non-exhaustion error) — err=Provider '<provider>' hard quota exhausted: …` (`lib/keeper/keeper_unified_turn_terminal_error.ml`, 오류 글은 `packages/agent_core/lib/llm_provider/error.ml`).
2. 턴 끝 줄 `<keeper>: keeper cycle FAILED runtime=…`, `… keeper cycle rested until=<t> waiting_on=<id> runtime=…`, `… keeper cycle <결과> runtime_lane=…` (`lib/keeper/keeper_unified_turn.ml`, `keeper_unified_turn_success.ml`).
3. `<keeper>: the next dispatch waits <초>s for <runtime> to be released at <epoch>` 가 provider 행과 풀리는 시각을 줘요(`lib/keeper/keeper_heartbeat_loop.ml`).

provider 행은 runtime id 의 첫 `.` 앞이에요.
앞서 같은 행에 같거나 늦은 시각이 적혔고, 그때가 이 턴이 보낸 때보다 앞서면 「이미 알던 시각」이에요.

- 보낸 때는 그 턴 안에서 Keeper 이름으로 찍힌 마지막 `turn composition:` 줄이에요. 공식 client runtime 만 이 줄을 써요.
- 그 줄이 없으면 Keeper 이름으로 찍힌 마지막 `agent started` 줄이에요(`lib/keeper/keeper_event_bridge.ml`). 후보 시도마다 시도 안에서 찍혀요.
- 「그 턴 안」은 앞선 턴 끝 줄 뒤부터예요. Keeper 하나는 한 번에 턴 하나만 돌려요(`lib/keeper/keeper_owner.mli`).
- 채팅 턴은 Keeper 이름으로 표시를 쓰지만 턴 끝 줄은 쓰지 않아요. 그래서 자기 표시가 없는 heartbeat 턴(Agent Core HTTP)은 그 사이 채팅 턴의 표시를 가져갈 수 있어요. 그 표시는 실제로 보낸 때보다 앞이에요. 판정을 「처음」 쪽으로만 옮기고, 「이미 알던 시각」을 늘리지 않아요. 이번 기간의 glm-coding 5건은 모두 「보낸 때를 모름」으로 남았어요.
- 「시도 시작」 열은 composition 줄을 버리고 모두 `agent started` 로 잡은 값이에요. 후보를 부르기 직전에 표를 읽는 walk 가 막을 수 있는 몫에 가까워요.
- 서버 시작은 `[Startup] retained checkpoint sweep` 요약 줄이에요(`bin/main_eio.ml`). 같은 머리의 sweep 실패 줄은 서버 시작으로 세지 않아요.

## 세지 못한 것

- 「먼저 적은 때」는 먼저 거절된 Keeper 의 대기 줄 시각이에요. 표에 실제로 적히는 때는 거절 때라서 그보다 앞이에요. 거절 줄(`turn terminal`) 시각으로 다시 세면 `known_from_another_keeper` 가 보낸 때 기준 43건, 시도 시작 기준 34건이에요.
- 한도 표는 scope(credential 참조, client home, provider 행)로 묶어요. provider 행 하나는 scope 하나라서, 두 행이 scope 를 나눠 쓰면 여기서는 따로 세요. 그래서 위 숫자는 아래 한계예요.
- 채팅 턴의 거절, 다음 후보로 넘어가 성공한 턴의 거절, lane 실행의 거절은 세지 않았어요. 그 로그 줄은 provider 행을 적지 않아요.
- 같은 기간(11-15 10:00Z 까지) agent-core 기록(`agent-core-events/2026-11/{10..15}.jsonl` 의 `agent_failed`, `error_code = provider_error_hard_quota`)은 506번이고 그중 451번이 시각을 말했어요. 이 기록은 provider 이름만 적어요.
- `known_from_itself` 1건이 어느 길로 나갔는지는 보지 않았어요.

## 다시 돌리기

```sh
python3 -I docs/evidence/stated-reset-refusals-2026-11/measure_stated_reset_refusals.py \
  --until 2026-11-15T10:00:00Z ~/me/.masc/logs/system_log_2026-11-1[0-5].jsonl
python3 -m unittest discover -s docs/evidence/stated-reset-refusals-2026-11
```

시험은 합성 로그로 판정 갈래와 우선순위를 확인해요. 스크립트가 읽는 로그 글이 아직 소스에 있는지도 확인해요.
