---
name: run-and-read
description: "Runs one shell command line with `sh -c`, waits up to `timeout_sec` for it to exit, and returns its exit status, stdout and stderr in one call instead of separate keeper_spawn, keeper_spawn_wait and keeper_spawn_read calls. Use for a command that ends on its own but may run past the bound you set. Read the `settle` action first. `exited` means the command ended: its `exit` has kind `exited` with a `code`, or kind `signalled` with the `signal` that ended it. `timed_out` means the command was still running when the bound passed: empty or partial output then is not a failure, and `settle` returns the `handle` so keeper_spawn_wait or keeper_spawn_read can continue it in this turn. The process ends when the turn ends. A server, watcher or TUI never exits, so this call can only time out on it: start it with keeper_spawn and wait with keeper_spawn_wait using until=output_contains and a needle. Execute stops a command at its timeout; use this when the command should keep running past the bound."
---

# run-and-read

`keeper_compose_run-and-read` 는 `keeper_spawn` → `keeper_spawn_wait(until=exit)` →
`keeper_spawn_read`(stdout, stderr) 를 한 번의 호출로 묶는다.

Keeper 에게 보이는 설명은 아래 fence 의 `description` 과 params 설명뿐이다.
이 본문은 사람이 읽는다. 쓰임새를 바꾸려면 fence 안 `description` 을 고치고,
frontmatter `description` 도 같은 값으로 맞춘다.

## 노드

| id | 도구 | 입력 |
|---|---|---|
| `start` | `keeper_spawn` | `argv = ["sh", "-c", command]` |
| `settle` | `keeper_spawn_wait` | `handle = start./handle`, `until = "exit"`, `timeout_sec` |
| `stdout` | `keeper_spawn_read` | `handle = start./handle`, `stream = "stdout"` |
| `stderr` | `keeper_spawn_read` | `handle = start./handle`, `stream = "stderr"` |

- `keeper_spawn` 은 composable 출력으로 `status`·`handle` 을 선언한다
  (`lib/keeper/keeper_tool_descriptor.ml` `spawn_start_output_schema`). 그래서 `/handle` 을
  다음 노드에 넘길 수 있다. wait·read 출력은 opaque 라 다른 노드 입력으로 쓸 수 없다.
- `keeper_spawn_read` 의 `stream` 기본값은 stdout 이다. 명령이 실패한 이유는 대개 stderr 에
  있어서 두 스트림을 따로 읽는다.
- `keeper_spawn_wait` 는 시간 초과를 오류가 아니라 `status = "timed_out"` 결과로 돌려준다
  (`lib/tool_spawn/tool_spawn.ml`). 그래서 시간 초과 뒤에도 두 read 노드가 돈다.

```toml composition
[[compositions]]
name = "run-and-read"
description = "Runs one shell command line with `sh -c`, waits up to `timeout_sec` for it to exit, and returns its exit status, stdout and stderr in one call instead of separate keeper_spawn, keeper_spawn_wait and keeper_spawn_read calls. Use for a command that ends on its own but may run past the bound you set. Read the `settle` action first. `exited` means the command ended: its `exit` has kind `exited` with a `code`, or kind `signalled` with the `signal` that ended it. `timed_out` means the command was still running when the bound passed: empty or partial output then is not a failure, and `settle` returns the `handle` so keeper_spawn_wait or keeper_spawn_read can continue it in this turn. The process ends when the turn ends. A server, watcher or TUI never exits, so this call can only time out on it: start it with keeper_spawn and wait with keeper_spawn_wait using until=output_contains and a needle. Execute stops a command at its timeout; use this when the command should keep running past the bound."
execution = "inline"

[[compositions.params]]
name = "command"
type = "string"
description = "One shell command line, passed to sh -c."

[[compositions.params]]
name = "timeout_sec"
type = "number"
description = "Seconds to wait for the command to exit. Must be positive. When it passes, the command keeps running and settle reports timed_out."

[[compositions.nodes]]
id = "start"
tool = "keeper_spawn"
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "argv"
[compositions.nodes.input.fields.value]
kind = "array"
[[compositions.nodes.input.fields.value.items]]
kind = "literal"
value = "sh"
[[compositions.nodes.input.fields.value.items]]
kind = "literal"
value = "-c"
[[compositions.nodes.input.fields.value.items]]
kind = "param"
name = "command"

[[compositions.nodes]]
id = "settle"
tool = "keeper_spawn_wait"
after = ["start"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "handle"
[compositions.nodes.input.fields.value]
kind = "output"
node = "start"
pointer = "/handle"
[[compositions.nodes.input.fields]]
name = "until"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "exit"
[[compositions.nodes.input.fields]]
name = "timeout_sec"
[compositions.nodes.input.fields.value]
kind = "param"
name = "timeout_sec"

[[compositions.nodes]]
id = "stdout"
tool = "keeper_spawn_read"
after = ["settle"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "handle"
[compositions.nodes.input.fields.value]
kind = "output"
node = "start"
pointer = "/handle"
[[compositions.nodes.input.fields]]
name = "stream"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "stdout"

[[compositions.nodes]]
id = "stderr"
tool = "keeper_spawn_read"
after = ["settle"]
[compositions.nodes.input]
kind = "object"
[[compositions.nodes.input.fields]]
name = "handle"
[compositions.nodes.input.fields.value]
kind = "output"
node = "start"
pointer = "/handle"
[[compositions.nodes.input.fields]]
name = "stream"
[compositions.nodes.input.fields.value]
kind = "literal"
value = "stderr"
```
