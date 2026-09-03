# Prompt Map

`config/prompts` 의 파일이 각각 누구에게 읽히고 wire 의 어느 자리에 붙는지. 2026-09-04 기준, main 에서 코드를 따라가 확인했다.

## 원칙

모델에게 나가는 문장은 코드에 박지 않는다. 제목·행 틀·상태 라벨까지 전부 `config/prompts` 에 있고, 운영자가 재정의할 수 있다.

## 자리는 셋뿐이다

모델 호출 하나는 **system prompt · user message · tool result** 로 나뉜다. 파일 10개는 이 셋 중 어디에 붙느냐로 갈린다.

## Keeper 한 턴

`keeper.md` 하나가 세 자리에 모두 관여한다. 읽는 사람이 하나라서 한 파일이다.

### system 자리 — `keeper_prompt.ml` 의 조립 순서

```
<system> keeper.md 본문(첫 마커 앞) </system>   ← keeper 전원이 글자 그대로 공유
keeper.md ### identity                          ← "너는 <이름>이다"
keeper.md ### workspace                         ← 샌드박스 루트
<instructions> keeper TOML 의 instructions </instructions>
```

공유 블록이 맨 앞인 것은 의도적이다. keeper 여럿이 같은 접두를 쓰면 provider 의 KV 캐시가 재사용된다. keeper 별로 달라지는 것은 그 뒤에 온다.

### user 자리 — 턴마다 새로 조립되는 세계 상태

```
keeper.md ### world.frame.frame
그 아래 층이 Keeper_context_layers.ordered 순서로:
  active_goals · current_task · approval_authority · connected_surfaces
  namespace_state · repository_freshness · autonomous_trigger
  scheduled_automation · completion_authority · task_cancellations
  pending_mentions · scope_messages · own_board_posts · board_activity
  own_recent_actions · fleet_messages
```

각 층이 `keeper.md` 의 슬롯을 골라 쓴다. 층에 내용이 없으면 통째로 빠지고, 예산을 넘으면 뒤에서부터 잘린다.

`world.frame.frame` 이 맨 앞에 있는 이유가 있다. `### Your Recent Board Posts` 만 보면 keeper 가 자기가 조회한 결과로 읽고 "보드를 확인했다"고 보고한다. 런타임이 모아준 것이라고 먼저 말해야 그 구분이 생긴다.

| 슬롯 그룹 | 무엇 |
|---|---|
| `world.*` | 목표·과제·보드·메시지·일정의 제목, 행, 상태 문장 |
| `context.*` | 체크아웃 현황과 승인 권한 |
| `observation.*` | 이전 턴이 왜 멈췄는지, 현재 과제를 왜 못 봤는지 |

### tool result 자리

| 파일·슬롯 | 언제 |
|---|---|
| `tool_failure.md` 5슬롯 | 도구가 실패했을 때 등급별 다음 수 (의존성 없음 / 정책 거부 / 런타임 실패 / 워크플로 거부 / 운영자 취소) |
| `keeper.md ### gate_replay.*` | 승인된 조작을 호스트가 대신 실행한 뒤 "다시 요청하지 마라" |

## 나머지 아홉 파일

각각 다른 모델 호출이다.

| 파일 | 호출하는 곳 | 자리 |
|---|---|---|
| `librarian.md` | `keeper_librarian_runtime.ml` — 턴 끝 기억 선별 | user (system 은 빈 문자열) |
| `verification.md` | `task/anti_rationalization.ml` — Task 완료 검증 | system. 계약·증거·조회도구 슬롯이 본문에 끼워짐 |
| `judge.md ### effect` | `keeper/hitl_summary_worker.ml` — 외부 효과 승인 판정 | system. `effect.output_contract` 가 JSON 계약 |
| `judge.md ### board` | `keeper/keeper_board_attention_exact_flow.ml` | system |
| `goal_verification.md` | `goal_verification_agent.ml` — metric 이 target 에 닿았나 | system. `lookup` 이 `proof` 안에 끼워짐 |
| `fusion.judge.md` | `fusion/fusion_judge.ml` — 1차·재심·메타 3위상 | system. 셋이 같은 `output` 슬롯을 공유 |
| `mcp.md` | `mcp_server_eio_tool_profile.ml` | MCP 프로토콜의 instructions 필드 (모델 호출 아님) |
| `lane_cli_probe.md` | `bin/masc_lane_cli_probe.ml` | system+user 픽스처 쌍 |
| `eval.calibration.few_shot.md` | `eval_calibration.ml` | 다른 프롬프트 안에 끼워짐 |

## 파일 경계의 규칙

- **읽는 사람이 같으면 한 파일.** `keeper.md` 는 자리가 셋으로 나뉘어도 독자가 keeper 하나라 한 파일이다.
- **호출이 다르면 다른 파일.** `judge.md` 의 board 와 effect 는 성격이 같아 한 파일이지만 서로 다른 호출이고, 서로 다른 슬롯이다.
- **키 접두사가 파일을 정한다.** 슬롯 키는 `<파일 키>.<마커>` 다. 그래서 `keeper.world.frame.frame` 은 `keeper.md` 의 `world.frame.frame` 마커에 산다. 파일을 합칠 때 마커가 옛 파일 이름을 지면 키가 그대로 남고 소비 코드가 안 바뀐다.

## system 자리에 실제로 실리는 것

`config/prompts` 는 그 일부다. 블록은 다섯이다: `keeper_instructions`, `dynamic_context`(세계 상태), `temporal_summary`, `memory_os_recall`, `operator_note` (`lib/types/prompt_block_id.ml`).

2026-09-03 11:10Z, analyst 한 턴의 실측 배분:

| 조각 | 바이트 | 비중 |
|---|---|---|
| 도구 스키마 | 66,271 | 43.4% |
| 기억 회상 | 40,761 | 26.7% |
| 세계 상태 | 15,196 | 9.9% |
| 도구 결과 | 13,367 | 8.7% |
| keeper 지침 | 10,698 | 7.0% |
| 나머지 | 6,510 | 4.3% |

프롬프트 파일을 정리해도 모델이 읽는 양의 대부분은 도구 스키마와 기억 회상이다. 창을 줄이려면 그 둘을 봐야 한다.

## 슬롯의 성격

`keeper.md` 슬롯 110개를 본문 모양으로 세면:

| 그룹 | 슬롯 | 문장 | 서식(제목·라벨·행 틀) |
|---|---|---|---|
| `world.*` | 82 | 32 | 50 |
| `context.*` | 13 | 6 | 7 |
| `observation.*` | 8 | 4 | 4 |
| `gate_replay.*` | 7 | 7 | 0 |

서식도 config 에 남는다. 운영자가 바꿀 일이 드물 뿐 바꿀 수 있어야 한다. 다만 재정의 목록에서 문장과 서식이 같은 무게로 보이면 목록이 읽히지 않으므로, 표시 등급은 따로 다룬다 (#32890).

## 파일 수의 내력

| 시점 | md |
|---|---|
| 2026-09-03 아침 | 58 |
| 조각 통합 (#32780, #32789, #32818) | 14 |
| `keeper.world.*` 유입 (#32848) | 32 |
| world 접기 (#32889) | 17 |
| 읽는 사람별 접기 (#32899) | 10 |
