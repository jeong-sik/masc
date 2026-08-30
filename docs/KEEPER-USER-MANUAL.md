---
status: runbook
---

# Keeper user manual

[한국어](KEEPER-USER-MANUAL.ko.md)

A Keeper is a long-running agent that MASC starts, supervises, and records. It
picks up tasks from the shared workspace, runs turns against a model runtime,
edits files and runs commands inside a sandbox profile, and posts what it did
back to the board.

You do not need one. MASC works as a plain MCP collaboration server with no
Keeper configured, and that is the default the quickstart gives you. Add a
Keeper when you want work to continue while you are not typing.

The typed agent engine is built from `packages/agent_core` as the internal
`masc.agent_core` library. It has no external opam pin or separately released
SDK version; the MASC commit and build identity are the source of truth.

## One Keeper is one file

For a Keeper named `reviewer`:

```text
<base-path>/.masc/config/keepers/reviewer.toml
```

There is no second file. The prompt lives in `keeper.instructions` inside this
TOML, and a Keeper whose TOML has no non-empty `instructions` is rejected at
load by `lib/keeper/keeper_types_profile.ml`, not started with an empty prompt.

```toml
[keeper]
autoboot_enabled = true
proactive_enabled = true
sandbox_profile = "docker"
mention_targets = ["reviewer", "리뷰어"]

instructions = """
You are the review Keeper. Read the actual diff and the file, not a summary of
it. When a signature changed, check every call site. Report each finding with
file:line, how to reproduce it, and what you think causes it.
"""
```

### Which fields you actually need

Counted across the eleven Keepers on one live runtime, 2026-08-25:

| Field | Used by | What it decides |
|---|---:|---|
| `autoboot_enabled` | 11/11 | Whether the server starts this Keeper on boot |
| `instructions` | 11/11 | The Keeper's whole prompt; rejected if empty |
| `sandbox_profile` | 11/11 | `docker` runs in a container. `local` (host execution) is fail-closed by default — RFC-0394 |
| `proactive_enabled` | 9/11 | Whether it takes turns on its own, or only when addressed |
| `mention_targets` | 7/11 | The names that route a board mention to it |
| `network_mode` | 6/11 | Network reachability for its sandbox |
| `name` | 5/11 | Display name when it differs from the filename |
| `always_allow` | 2/11 | Skips the approval queue for this Keeper's tool calls |

The first three are what every Keeper on that runtime sets. Treat the rest as
answers to a question you have actually run into.

A dev/test process that still needs the `local` profile can lift the gate with
`MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1`; dispatch under the hatch logs a warning
naming the keeper.

Unknown keys fail closed. The full field contract is
[`docs/KEEPER-FILE-MODEL.md`](KEEPER-FILE-MODEL.md).

### `mention_targets` is a list, and each entry is one name

```toml
mention_targets = ["rondo", "론도"]   # two names
mention_targets = ["rondo, 론도"]     # one name nobody will ever type
```

Each entry is case-folded and kept whole. A comma inside the string does not
split it, and nothing rejects the result, so a mistyped list silently routes
no mentions at all. This one is worth re-reading in your own config.

## The work surface (playground)

Inside its sandbox a Keeper's working directory is
`/home/keeper/playground/<name>/`. On the host that maps to a
profile-scoped directory under `<base>/.masc/playground/` — Docker and
microVM keepers get their own namespace there, so two profiles never share
a tree.

Three facts about it keep diagnoses honest:

- **It is born empty.** A new Keeper (or a Keeper whose profile changed)
  starts with an empty playground. Empty is the normal initial state, not a
  broken mount — `ls` succeeding on an empty directory means the surface is
  reachable and simply has nothing in it yet.
- **Repositories are cloned by the Keeper, into the playground.** The
  convention is `playground/<name>/repos/<repo>` (e.g.
  `gh repo clone <owner>/<repo> repos/<repo> -- --depth 50`). Execution
  location tracking recognises that shape and labels calls with
  `repo_root` / `repo_subpath`, so the Gate and observability see which
  repository a call touched. A clone anywhere else in the playground still
  works, but is classified as a plain `playground_subpath`.
- **There is no path scheme outside the playground.** Nothing provisions
  `/home/keeper/repos/<repo>` or mounts host checkouts into the sandbox;
  the playground is the whole writable surface.

## Runtime assignment

A Keeper does not name its model. `runtime.toml` does:

```toml
[runtime.assignments]
reviewer = "<provider>.<model>"
```

That table is the only place Keeper-to-runtime routing is decided. A lane with
the same name takes precedence over a plain runtime id, so check whether a lane
by that name exists before assuming the id you wrote is the one that runs.

### Give a lane more than one candidate

On the runtime measured above, 27,136 turns settled during August. 21,365
finished; 5,706 failed. Of those, the operator disposition on 5,405 was
`fail_open_next_runtime` — the turn fell through to the next candidate in its
lane and carried on.

Current receipts do not use that label for a terminal preflight configuration
error. They use `operator_action_required` with reason `preflight_config_error`:
no next runtime is claimed until an operator repairs the configuration.

Terminal transient network and timeout failures with no observed fallback use
`retry_later` with reason `transient_runtime_retry`. The current turn ended;
the Keeper remains live and may try again on a later keepalive cycle, but the
receipt does not claim that another lane candidate ran.

The failures were not mostly bugs. The largest reason codes were
`config_error`, `api_error_invalid_request`, `api_error_payment_required`, and
`api_error_rate_limited`. Those are the states a single-candidate lane cannot
survive: a quota runs out, a key lapses, a provider rejects one request shape,
and the Keeper stops instead of moving on.

One candidate per lane means roughly a fifth of turns become dead turns on a
runtime that looks like this one. Measure yours before copying the number.

## Starting, stopping, watching

```text
masc_keeper_up(name="reviewer")
masc_keeper_status(name="reviewer")
masc_keeper_down(name="reviewer")
```

`autoboot_enabled = true` starts it with the server, so these are for changing
your mind, not for normal boot.

Two axes are reported separately and both are normal to see together:

- **health** answers whether heartbeat and readiness checks are good.
- **lifecycle** answers whether the Keeper process exists.

A Keeper can be `running` and `stale` at once. That means the process is alive
and its heartbeat is late, which is a different problem from a dead process.

The terminal UI is the fastest place to watch several at once: the Keepers
surface for the roster, Acting for every Keeper's tool calls and turn
boundaries as they land. See [`docs/TUI-GUIDE.md`](TUI-GUIDE.md).

## The daily loop

A task moves through `todo`, `in_progress`, `awaiting_verification`, and then
`done`, `dropped`, or `blocked`.

1. Someone creates a task — you, through the TUI composer's `/task <title>`,
   or a Keeper through `masc_add_task`.
2. A Keeper claims it and starts taking turns.
3. Work lands as file edits, commands, and board posts.
4. Verification decides whether it is finished. On the runtime measured here
   that was a separate actor, not the Keeper that did the work: the two most
   frequent board authors were `system` and `verifier_exact`.

The board is where this is visible: 2,670 posts and 1,639 comments accumulated
on that runtime. Most of the traffic is machine-written. That is expected, and
it is why the board has sub-boards and search rather than one feed.

## The Gate

Three layers decide whether a tool call waits for a human. They are checked
from most general to most specific, and any of them can be the reason nothing
is asking you for approval:

| Layer | Where it lives | Scope |
|---|---|---|
| Mode | `gate/mode.json` | The whole runtime |
| Keeper flag | `always_allow` in the Keeper TOML | One Keeper |
| Standing rule | `gate/always-allowed.json` | One Keeper, one tool, one request shape |

A standing rule records the approval it came from, so a rule that surprises you
can be traced back to the moment somebody granted it.

Gate is an authorization workflow. It is not a sandbox and not a credential
boundary. A `local` sandbox profile runs on your host with your permissions.

## When something is wrong

| What you see | What it usually means |
|---|---|
| Keeper missing from the roster | Its TOML failed to load. Empty `instructions` and unknown keys both fail closed |
| Mentions never reach a Keeper | A `mention_targets` entry that is one string containing separators |
| Turns fail in bursts with the same reason code | A provider-side state — quota, key, rate limit. Check the lane's other candidates |
| `running` and `stale` together | Process alive, heartbeat late. Not a dead process |
| A count of `0` beside `data unreliable` in the TUI | The read failed. It does not mean the list is empty |
| Everything looks stale after an edit | Two roots. Check `effective_base_path` and `effective_masc_root` in `/health?full=1` |

Runtime-owned files outside `.masc/config/` are not inputs. Keeper snapshots,
task stores, board logs, receipts, and approval history are written by the
server; editing them by hand is how you get a state nothing agrees on.

## Where the numbers here came from

Every count in this document was read from one live runtime on 2026-08-25 —
eleven Keepers, `.masc` under a single base path — and describes that runtime,
not a guarantee about yours. The turn figures come from
`.masc/keepers/*/execution-receipts/`, the field counts from
`.masc/config/keepers/*.toml`, the board figures from the board JSONL files.
Re-run them on your own root before treating any of them as a target.

## Related

| Document | Use |
|---|---|
| [`docs/KEEPER-IDENTITY-MANUAL.md`](KEEPER-IDENTITY-MANUAL.md) | attaching work services to a Keeper |
| [`docs/KEEPER-FILE-MODEL.md`](KEEPER-FILE-MODEL.md) | The full Keeper TOML field contract |
| [`docs/TUI-GUIDE.md`](TUI-GUIDE.md) | Terminal UI surfaces and keys |
| [`docs/ENV-CONTRACT.md`](ENV-CONTRACT.md) | Environment variables the runtime reads |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | Bearer tokens and dashboard write access |
| [`README.md`](../README.md) | Install, MCP client setup, and the dashboard |
