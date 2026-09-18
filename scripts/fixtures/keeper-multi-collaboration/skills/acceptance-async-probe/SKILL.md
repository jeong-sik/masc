---
name: acceptance-async-probe
description: "Acceptance campaign fixture. Hands board statistics and your execution lane read to the durable async broker and returns a request_id at once; read the result with keeper_composition_status and that request_id. Call it only when a mission prompt names it."
---

# acceptance-async-probe

`scripts/harness/workload/keeper_multi_collaboration_acceptance.py` 의 `--run` 이 캠페인 서버에
설치하고, researcher 미션이 턴을 붙잡지 않는 합성 제출을 재려고 부르게 하는 시험용 합성이다. 제품 빌트인
`skills/` 에 두지 않는다.

| 노드 | 도구 | 하네스가 보는 것 |
|---|---|---|
| `board` | `masc_board_stats` | async 로 실행돼 완료되고, 부모 `tool_use_id` 가 제출 호출을 가리킨다 |
| `lane` | `keeper_lane_status` | 같다 |

- async 합성의 노드는 descriptor 가 정적으로 읽기 전용이어야 한다. 두 도구 모두 그렇다.
- 하네스는 제출 결과의 `request_id` 로 `keeper_composition_status` 를 불러 `queued`/`running` 뒤에
  `done` 이 오는지 본다.
- 노드 id·도구를 바꾸면 하네스의 `ASYNC_FIXTURE_NODES` 와
  `test/test_acceptance_composition_fixtures.ml` 을 같이 고친다.

```toml composition
[[compositions]]
name = "acceptance-async-probe"
description = "Acceptance campaign fixture. Hands board statistics and your execution lane read to the durable async broker and returns a request_id at once; read the result with keeper_composition_status and that request_id. Call it only when a mission prompt names it."
execution = "async"

[[compositions.nodes]]
id = "board"
tool = "masc_board_stats"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "lane"
tool = "keeper_lane_status"
[compositions.nodes.input]
kind = "literal"
value = {}
```
