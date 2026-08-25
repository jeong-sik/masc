---
title: Keeper Capability Probe Lane
rfc: "0374"
status: Draft
created: 2026-08-12
---

# RFC-0374: Keeper Capability Probe Lane

| Field    | Value                                                              |
|----------|--------------------------------------------------------------------|
| Status   | Draft                                                              |
| Scope    | `lib/keeper/keeper_capability_probe.{ml,mli}` (new), `lib/server/` route, `test/` |
| Conflict | None expected — additive lane, no change to the turn driver         |
| Issue    | masc#28414                                                          |

## Problem

There is no way to ask "can keeper K reach tool T on runtime R" without making
the keeper actually do it in its own conversation. Every answer today costs a
real turn, and a real turn is durable in three places:

```
keeper_chat/<k>.jsonl             re-injected into the next prompt
traces/<trace>/trace-*.json       the Agent Core checkpoint
config/keepers/<k>.memory-*.json  librarian output, survives both of the above
```

Measurement therefore mutates the thing being measured. On 2026-08-12 a
47-runtime audit ran 361 turns through the chat surface and the third layer
closed on it: the librarian read the accumulated probe traffic and committed a
`lesson` fact at 20:27 —

```
RTPROBE 프로브 작업은 echo, read, board_post, board_list, add_task,
keeper_tasks_list, goal_upsert, goal_list, board_comment, board_vote 등
반복 실행으로 컨텍스트만 잠식하므로 무응답 처리하는 것이 적절하다.
```

— naming all ten probed tools and prescribing non-response. 25 subsequent
turns across 6 runtimes came back `visible_reply` with `tools=[]`. The keeper
was not wrong: repeated tool exercise does consume its context, and declining
is a reasonable response to it.

Two properties make this structural rather than incidental:

1. **It regenerates.** The librarian retired an earlier instance of the same
   fact on its own (rev 1657 added 18:06, rev 1659 removed 18:20) and wrote a
   new one at 20:27 once probing continued. Clearing state does not help while
   the method stays the same, and rewording the probe does not change the
   pattern that produced the rule.
2. **It destroys attribution, not just throughput.** The rule is soft — after
   20:27 `ollama-cloud-deepseek-v4-flash-0731` still scored 4/4 and
   `gpt-5.3-codex-spark` 2/3. So a zero result in that window is consistent
   with both "the runtime cannot reach the tool" and "the keeper chose not
   to", and nothing in the record separates them.

A control turn confirms the rule is scoped, not over-general: an ordinary
request with no probe marker and no tool-forcing ("보드에 최근 올라온 글이
뭐가 있는지 좀 보여줘") called `masc_board_list` in 14.2 s. Production
behaviour is intact. What is blocked is measurement.

## Boundary

The question "can K invoke T on R" decomposes into three parts with different
determinism, and the current method conflates them:

| Part                                          | Determinism   | Needs a model call   |
|-----------------------------------------------|---------------|----------------------|
| Is T in the tool surface projected for R       | deterministic | no                   |
| Does the provider accept a request carrying T  | deterministic | round-trip only      |
| Does the model choose T when asked             | stochastic    | yes                  |

Only the third needs a turn, and it needs *a* conversation — not *the*
keeper's conversation. That is the separation this RFC draws: a probe supplies
its own minimal conversation and its own session identity, and writes to
neither of the keeper's durable stores.

The keeper's conversation is the SSOT for what the keeper has done. A
capability probe is not something the keeper has done, so it does not belong
there. This is a boundary correction, not a new subsystem.

## Design

### Seam

The per-kind runners are already parameterized on exactly the two things that
have to differ:

```ocaml
val run :
  runtime_id:string ->
  keeper_name:string ->        (* session store key + antigravity home leaf *)
  base_path:string ->
  tools:Agent_core.Tool.t list ->
  initial_messages:Agent_core.Types.message list ->   (* caller supplies *)
  ...
```

`initial_messages` means no runner reads the keeper transcript for itself, and
`keeper_name` is what `Session_store.load ~base_path ~keeper_name`
(`keeper_antigravity_runtime.ml:225`) and `~owner_leaf` (`:318`) key on. A
probe passes a synthetic message list and a distinct identity; nothing else in
the runners has to change.

Persistence is already a separate concern, and the runners do not participate
in it. Measured on `origin/main`:

```
                                  Keeper_chat_store.  Keeper_checkpoint_store.
keeper_antigravity_runtime.ml              0                    0
keeper_claude_code_runtime.ml              0                    0
keeper_codex_app_server_runtime.ml         0                    0
```

Control: both symbols do resolve elsewhere — `Keeper_checkpoint_store.save*`
in `keeper_agent_run.ml`, `keeper_agent_run_finalize_response.ml`,
`keeper_context_core.ml`; `Keeper_chat_store.` across the tool and delivery
modules — so the zeros above are absence, not a mistyped pattern.

Checkpoint persistence is owned by `Keeper_agent_run` and its finalizer. A
probe that calls a runner directly and stops there writes nothing, without
needing a flag anywhere in the persistence layer.

### Probe identity

```ocaml
(** Probe identity is a distinct keeper id, not a flag on the real one.
    A boolean would leave one session store serving two purposes and put the
    burden of "was this a probe" on every reader; a separate id makes the
    isolation structural. *)
type identity = private string

val probe_identity : keeper_name:string -> identity
```

`probe_identity ~keeper_name:"sangsu"` yields a reserved id in a namespace that
cannot collide with a configured keeper. The official-client session store and
antigravity home for that id are separate directories, so a probe never
start-or-resumes the keeper's real session.

Reserved-namespace enforcement belongs at keeper registration: a configured
keeper whose name falls in the probe namespace must be rejected at config
admission, the same way other identity collisions are.

### Result type

Make the three outcomes that today all read as "0" distinguishable at the type
level, so callers cannot collapse them:

```ocaml
type outcome =
  | Tool_invoked      of { tool : string; elapsed_s : float }
  | Replied_no_tool   of { reply_bytes : int; tools_seen : string list }
  | Not_projected     of { requested : string; projected : string list }
  | Provider_rejected of Agent_core.Error.t
  | Transport_failed  of Agent_core.Error.t
```

`Not_projected` is decidable before the model call: MASC either puts the tool
in the surface it hands the client, or it does not. When it does not, no turn
is worth spending.

**Its converse is not "reachable", and the naming has to keep that visible.**
Projection is MASC's side of the wire; consumption is the client's. The two
diverge, and that divergence is the largest single finding of the audit this
RFC comes from — the antigravity bridge advertised 97 tools including all ten
probed, `initialize` and `tools/list` both answered, and the models still
reported no masc tool present. A probe that resolved capability from the
projected surface alone would have called those runtimes healthy.

So the lane keeps the two questions apart:

| Question                        | Answered by      | Cost   |
|---------------------------------|------------------|--------|
| Does MASC project T?            | `probe_surface`  | none   |
| Does the client consume what MASC projects? | `probe_invocation`, and only by observing a call | one turn |

`Not_projected` is therefore a *sufficient* explanation for failure and never
a sufficient basis for success. `probe_surface` returning "projected" means
the turn is worth spending, nothing more.

No `Unknown -> permissive` arm. An unresolvable runtime id is an `Error`, per
RFC-0206 §2.1 and the same rule `resolve_runtime_providers` already follows.

### Interface

```ocaml
val probe_surface :
  runtime_id:string ->
  keeper_name:string ->
  tool:string ->
  (surface_result, error) result
(** Deterministic. No provider call, no session, no turn. *)

val probe_invocation :
  runtime_id:string ->
  keeper_name:string ->
  base_path:string ->
  tool:string ->
  prompt:string ->
  (outcome, error) result
(** One provider round-trip against a synthetic conversation under a probe
    identity. Writes nothing to keeper_chat, the checkpoint, or memory. *)
```

### What the probe must not do

These are the invariants the tests exist to hold:

- no `Keeper_chat_store.append_*` under a probe identity
- no `Keeper_checkpoint_store.save_agent_core_*` under the real keeper's session
- no write to `config/keepers/<real>.memory-*`
- no mutation of the real keeper's official-client `session.json`

## Verification

| Check | Method |
|-------|--------|
| Probe leaves keeper_chat byte-identical | hash before/after a probe run |
| Probe leaves the real checkpoint byte-identical | hash before/after |
| Probe leaves memory revision unchanged | compare `revision` before/after |
| `Not_projected` needs no provider call | probe a nonexistent tool with the provider unreachable; must still answer |
| "projected" is not reported as reachable | a runtime whose client ignores the surface (antigravity) yields `Replied_no_tool`, never a success from `probe_surface` alone |
| Probe identity cannot be a configured keeper | config admission rejects a keeper named in the probe namespace |
| Outcomes stay distinguishable | a quota-exhausted runtime yields `Provider_rejected`, never `Replied_no_tool` |

The load-bearing test is the first three as a set: run N probes, assert all
three stores are unchanged. That is the property the whole RFC exists to
provide, and it is the one that regresses silently if a future caller reaches
for the ordinary turn path.

## Alternatives considered

**Fact provenance instead (masc#28414 proposal 1).** Tag operator-injected
turns so the librarian excludes them from summarization. Smaller change, and it
addresses the librarian's actual blind spot. Rejected as the *primary* fix
because it leaves the first two contamination layers intact — probe turns still
land in the transcript and the checkpoint, still get re-injected, still grow the
payload at ~900 KB/h under load. It remains worth doing, and is complementary
rather than exclusive.

**Rename the probe marker.** Cheapest, and wrong. The lesson enumerates tool
names, so wording is unlikely to evade it; and the librarian re-promoted the
rule twice under sustained load, so volume regenerates it regardless. Beyond
effectiveness: a number obtained by circumventing the subject's stated policy
is not evidence.

**Delete the memory fact when it appears.** Treats a loop as a state. The
journal shows the librarian already retires and re-adds this fact on its own;
hand-editing a locked, journaled, revision-counted document owned by a
concurrent writer adds a race for no durable benefit.

## Out of scope

- Changing what the librarian summarizes (proposal 1, separate RFC)
- Any change to the turn driver's dispatch or the per-kind runners
- Karma: the keeper has no read path to it at all
  (`lib/tool_surface/` references 0, control `masc_board_vote` 3), so no probe
  lane can measure it. That is a tool-surface gap, tracked separately.
