# MASC Quick Start

## 1-Step Setup

```
masc_start(path="/your/project", task_title="My first task")
```

This sets the room, joins you as an agent, creates a task, claims it, and sets it as your current task.

## Step-by-Step (if you need control)

```
masc_set_room(path="/your/project")
masc_join()
masc_add_task(title="My task")
masc_claim_next()
# masc_claim_next auto-binds current_task in current builds
# masc_plan_set_task(task_id="task-001")  # only if current_task is still missing
```

## Modes

Default mode is **Coding** (~80 tools). Switch if needed:

```
masc_switch_mode(mode="full")       # All 371+ tools
masc_switch_mode(mode="minimal")    # Core only (~20 tools)
masc_switch_mode(mode="coding")     # Back to default
```

## Error Recovery

Failed tool calls include recovery hints automatically. Common patterns:

| Error | Recovery |
|-------|----------|
| "not initialized" | `masc_init` or `masc_start(path=...)` |
| "not joined" | `masc_join` or `masc_start` |
| "no unclaimed tasks" | `masc_add_task(title="...")` |
| "task not found" | `masc_status` to see available tasks |

## Reference

- `docs/COMMAND-PLANE-RUNBOOK.md` — CPv2 benchmark/swarm path
- `docs/SUPERVISOR-MODE.md` — supervised team session path
- `docs/BENCHMARK-RUNBOOK.md` — single-agent vs swarm recipes
