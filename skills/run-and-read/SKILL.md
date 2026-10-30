---
name: run-and-read
description: "Runs a finite Bash command with pipefail, then returns its exit status, stdout and stderr. Use when the command may outlast one wait but should keep running within this turn. Requires bash in the sandbox. Read settle.exit first: exited with code 0 is shell success; a nonzero code or signal is not. pipefail preserves a failed pipeline stage, so piping a capture command to tail does not hide its failure. timed_out means still running: continue with the returned handle using keeper_spawn_wait/read. Processes end with the turn. Use keeper_spawn directly for a server, watcher or TUI, and wait for its readiness condition; use Execute for a finite command that can finish within its timeout."
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
| `start` | `keeper_spawn` | `argv = ["bash", "-o", "pipefail", "-c", command]` |
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
description = "Runs a finite Bash command with pipefail, then returns its exit status, stdout and stderr. Use when the command may outlast one wait but should keep running within this turn. Requires bash in the sandbox. Read settle.exit first: exited with code 0 is shell success; a nonzero code or signal is not. pipefail preserves a failed pipeline stage, so piping a capture command to tail does not hide its failure. timed_out means still running: continue with the returned handle using keeper_spawn_wait/read. Processes end with the turn. Use keeper_spawn directly for a server, watcher or TUI, and wait for its readiness condition; use Execute for a finite command that can finish within its timeout."
execution = "inline"

[[compositions.params]]
name = "command"
type = "string"
description = "One Bash command line. pipefail preserves nonzero pipeline exits; later semicolon-separated commands can still replace the exit status."

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
value = "bash"
[[compositions.nodes.input.fields.value.items]]
kind = "literal"
value = "-o"
[[compositions.nodes.input.fields.value.items]]
kind = "literal"
value = "pipefail"
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
