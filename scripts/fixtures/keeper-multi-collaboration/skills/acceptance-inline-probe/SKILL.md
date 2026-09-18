---
name: acceptance-inline-probe
description: "Acceptance campaign fixture. Reads board statistics and your execution lane at the same time, then searches board posts for the lane profile that the lane read returned and shows at most one matching post as one line, all inside this turn. Call it only when a mission prompt names it."
---

# acceptance-inline-probe

`scripts/harness/workload/keeper_multi_collaboration_acceptance.py` 의 `--run` 이 캠페인 서버에
설치하고, 미션 프롬프트가 Keeper 에게 부르게 하는 시험용 합성이다. 모든 사용자에게 배포되면 안 되므로
제품 빌트인 `skills/` 가 아니라 하네스 fixture 옆에 둔다.

한 번 부르면 하네스가 재는 성질 세 가지가 한꺼번에 생긴다.

| 노드 | 도구 | 하네스가 보는 것 |
|---|---|---|
| `board` | `masc_board_stats` | `lane` 과 같은 batch 0 에서 동시에 돈다 |
| `lane` | `keeper_lane_status` | `board` 와 같은 batch 0 에서 동시에 돈다. 출력의 `profile` 이 `search` 의 입력이 된다 |
| `search` | `masc_board_search` | `lane` 출력을 기다려야 해서 batch 1 에서 혼자 돈다. 입력 `query` 가 같은 실행에서 `lane` 이 돌려준 `profile` 과 같아야 한다 |

- 세 도구 모두 descriptor 가 `Concurrent` 다. `board`·`lane` 은 의존이 없어 한 batch 로 묶이고,
  `search` 는 `lane` 출력을 참조하므로 다음 batch 로 밀린다.
- 하네스는 중첩 행의 출력이 잘리지 않았는지(도구 호출 로그 출력 상한 4000 바이트, `truncated_to` 없음)도 본다.
  그래서 저장된 본문을 그대로 돌려주는 도구는 넣지 않는다. `masc_board_stats` 와 `keeper_lane_status` 는
  모양이 고정돼 있고, `search` 는 `limit = 1`, `compact = true` 라 글 하나의 id·제목·작성자 한 줄만 돌려준다.
  `keeper_memory_search` 는 걸린 사실의 본문을 돌려주고 그 길이에 상한이 없어서 쓰지 않는다.
- 대시보드 브라우저 증명은 `search` 행을 펼쳐 입력과 출력이 보이는지 확인한다.
- 노드 id·도구·batch 모양을 바꾸면 하네스의 `INLINE_FIXTURE_*` 상수와
  `test/test_acceptance_composition_fixtures.ml` 을 같이 고친다.

```toml composition
[[compositions]]
name = "acceptance-inline-probe"
description = "Acceptance campaign fixture. Reads board statistics and your execution lane at the same time, then searches board posts for the lane profile that the lane read returned and shows at most one matching post as one line, all inside this turn. Call it only when a mission prompt names it."
execution = "inline"

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

[[compositions.nodes]]
id = "search"
tool = "masc_board_search"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "output"
node = "lane"
pointer = "/profile"
[[compositions.nodes.input.fields]]
name = "limit"
[compositions.nodes.input.fields.value]
kind = "literal"
value = 1
[[compositions.nodes.input.fields]]
name = "compact"
[compositions.nodes.input.fields.value]
kind = "literal"
value = true
```
