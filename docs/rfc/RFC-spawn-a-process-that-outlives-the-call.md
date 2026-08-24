---
rfc: "spawn-a-process-that-outlives-the-call"
title: "Spawn: a process that outlives the call"
status: Draft
created: 2026-08-25
updated: 2026-08-25
author: vincent
supersedes: []
superseded_by: null
related: ["execute-subset-dispositions"]
implementation_prs: []
---

# Spawn: a process that outlives the call

## 1. Problem

`RFC-execute-subset-dispositions` sorted the constructs the Execute subset
excludes into the call each one should have been. Twelve of the thirteen with
an answer are work a shell does *before* `exec`: a heredoc builds stdin, `$(…)`
builds an argument, `{a,b}` builds a list. None of them survives into the
running process, so the gate can express them.

`&` is the exception. It asks for a process that outlives the call, and there
is no other call to rewrite it into.

**1.1 The result type cannot hold one.**

```ocaml
type dispatch_result = { status : Unix.process_status; stdout : string; stderr : string }
```

Every field is filled in by a process that has ended. A live process has no
status yet and its output is not finished. Nothing about this record can carry
one, and that is not a gap to patch — it is what the record means.

**1.2 The absence does not show up as demand.**

`tools/costume_census` over 24 days of recorded Execute calls:

```
costumes=1584   background=5
```

Five is not a measurement of how much backgrounding is wanted. `&` is refused
and has no alternative, so a caller that needs it does not ask — it reaches
for something else, and that reach is not recorded as an Execute call at all.
This is the one construct in the corpus whose count cannot be read as
priority.

**1.3 The workaround is already in the repository's own history.**

The session that produced the parent RFC opened with this, written by an agent
that needed a long-lived TUI and had no way to ask for one:

```
tmux new-session -d -s tscroll "…masc_tui.exe…" ; sleep 9 ; tmux send-keys …
```

`tmux` is a session manager smuggled in as a command, because spawn, write,
read and stop had to come from somewhere. `sleep 9` is a wait with no failure
mode: when the program took longer, the keys went nowhere and the measurement
that followed was wrong rather than absent.

**1.4 Other harnesses have not solved it either.**

Open in `openai/codex`: #3968 (background terminal sessions), #32188
(event-driven wakeup when a background exec completes), #14314 (agent stuck on
"Waited for background terminal" after the command finished), #34115
("drops canonical process identity and hides a live background wait"), #10767
(no tool call keeps a process alive across turns), #26382 (a cancelled task
kept running and saturated a server), #6965 (cannot run a command longer than
a second).

Those seven are the failure list this design is checked against. #34115 in
particular is §1.1 restated from the outside: put a live process into a shape
built for a finished one, and its identity is what gets lost.

## 2. Boundary & invariants

- **`dispatch_result` does not change.** Spawn is a separate surface, so the
  fourteen non-test consumers of the Execute result are untouched. §4 rejects
  the alternative.
- **A handle names one process for the life of a run, and is never reused.**
  A number that can be recycled is how #34115 happens.
- **No wait is a poll.** There is no interval anywhere in this design, because
  an interval would be a number nobody can defend. What a caller waits for is
  an event the runtime already observes.
- **No default timeout.** A wait states its own bound. A default would be a
  magic number wearing the costume of a convenience, and the failure it
  produces — a wait that ends early, or never — is worse than being asked.
- **A spawned process cannot outlive its switch.** Teardown is structural, not
  a step a caller can forget.
- **Buffered output is bounded by configuration, and the bound is visible when
  it is reached.** A cap that silently truncates is a lie; a cap that says how
  much it dropped is a limit.

## 3. Design

### 3.1 The surface

Four operations, not one. The shapes differ, so a single call would have to
return a sum of everything and every caller would match on all of it.

```ocaml
val spawn : sw:Eio.Switch.t -> Registry.t -> Masc_exec.Shell_ir.simple -> Handle.t

type finished = { status : Unix.process_status }

val wait
  :  Registry.t
  -> Handle.t
  -> until:until
  -> timeout:Duration.t
  -> (waited, [ `Timed_out | `Unknown_handle ]) result

val read
  :  Registry.t
  -> Handle.t
  -> stream:stream
  -> from:Offset.t
  -> (chunk, [ `Unknown_handle ]) result

val stop : Registry.t -> Handle.t -> (unit, [ `Unknown_handle ]) result
```

`spawn` takes a `Shell_ir.simple`, so a backgrounded command crosses the same
gate as any other: path scope, redirect policy, and the sandbox target all
apply before a process exists.

### 3.2 A handle is an identity, not an index

```ocaml
module Handle : sig
  type t
  val to_string : t -> string
  val of_string : string -> t option
end
```

The wire form is `<run>-<n>`. `run` is given to `Registry.create` by its
caller rather than read from a global, so a test fixes it and production
derives it once per process. `n` counts up and is never reissued within a run.

Two properties follow, and both are what #34115 lost:

- a handle from an earlier run cannot name a process in this one, because
  `run` differs;
- a handle whose process has ended still names that process, not whatever
  started next.

`of_string` returning `option` is deliberate: a handle that came back from a
model is a string until it is parsed, and the parse is where an unknown one is
found. `Unknown_handle` is a value in every result type here for the same
reason — a stale handle is an ordinary answer, not an exception.

### 3.3 Waiting is driven by events, never by a clock

```ocaml
type until =
  | Exit
  | Output_contains of { stream : stream; needle : string }

type waited =
  | Exited of finished
  | Matched of Offset.t
```

`Exit` is `Eio.Process.await`. `Output_contains` is evaluated as each chunk
arrives from the pipe reader, so a match is noticed when the bytes appear and
not on the next tick of something.

There is no `After of Duration.t`. `sleep` is not a synchronisation primitive,
and the parent RFC's own session is the exhibit: a fixed wait that was long
enough on one machine produced a wrong number rather than a failure on
another. Claude Code blocks foreground `sleep` outright and directs callers to
a condition; this says the same thing in the type, where it cannot be argued
with.

`needle` is the caller's own literal, matched literally. Nothing is inferred
from it — it is not a classifier, it is the protocol the caller already has
with the program it started.

`timeout` has no default. `Timed_out` is returned, never a `waited` that
happens to look plausible.

### 3.4 Reading is resumable

```ocaml
type chunk = { bytes : string; next : Offset.t; dropped_before : int }
```

`read ~from` returns what the stream holds after that offset and the offset to
continue from. A caller that reads twice sees each byte once, and a caller
that reads after a gap is told how many bytes it missed rather than handed a
seamless-looking string that is missing the middle.

`dropped_before` is how the buffer bound stays honest. The bound is a Keeper
runtime setting with a registry row, not a literal: a deployment that watches
a chatty build sets it differently from one that watches a test run, and
neither has to edit OCaml to do it.

### 3.5 Teardown is the switch

`spawn` registers `Eio.Switch.on_release` for the process it starts: signal,
then reap. When the switch ends — the turn finishing, the keeper stopping, a
cancellation — no spawned process survives it. This is codex#26382 answered
structurally rather than by remembering to clean up.

A handle stays usable until its switch releases: `read` still returns what was
buffered, `wait ~until:Exit` returns the status immediately, `stop` on an
already-dead process is `Ok ()`. A caller never has to race the process to ask
about it.

### 3.6 What the tool surface exposes

`masc_spawn`, `masc_spawn_read`, `masc_spawn_wait`, `masc_spawn_stop`, each
mapping to one operation above. The handle crosses as its string form. Every
error is a typed result rendered as a message that names the next call, in the
sense `Subset_rewrite` established: an unknown handle says the process is gone
rather than that something failed.

The `Background` arm of `Subset_rewrite` already answers `call_this_instead:
spawn`. It becomes true when this ships; today it names a call that does not
exist yet, which is the same gap §1 of the parent RFC described in the other
direction.

## 4. Rejected alternatives

- **Widen `dispatch_result` into `Finished | Live`.** Correct in the abstract,
  and it touches fourteen non-test consumers to give twelve of them a case
  that cannot occur for them. Execute stays synchronous; the new shape lives
  where it is the only shape.
- **`Execute` with a `background: true` flag.** One call returning either a
  result or a handle, matched everywhere. This is the shape codex#34115
  reports on.
- **Poll with a default interval.** Any interval is a number with no defence,
  and the two failure modes are both silent: too short burns cycles, too long
  reports a state that has already changed. §3.3 waits on the event instead.
- **A default timeout.** Same objection, one level up. A caller that cannot
  say how long it is willing to wait has not decided what it is doing.
- **Reuse handle numbers once a process ends.** Cheaper and exactly the bug in
  #34115.
- **Unbounded output buffering.** A watched build can produce more than the
  process watching it should hold. §3.4 bounds it and says so.

## 5. Test plan

- **Identity:** two spawns in one run get different handles; a handle from a
  registry created with a different `run` is `Unknown_handle`, not a hit.
- **Liveness:** a process that has not exited answers `read` with its output so
  far and `wait ~until:Exit ~timeout` with `Timed_out`, and the same handle
  answers `Exited` once it ends.
- **Event-driven wait, not a poll:** `Output_contains` returns for a program
  that prints its needle after an interval unrelated to any constant in the
  implementation, and the elapsed time tracks the program rather than a tick.
- **No sleep in the tests.** A test that waits by sleeping would be asserting
  the thing this RFC removes. Waits are on the same primitives the code uses.
- **Teardown:** a process spawned inside `Switch.run` is not running after the
  switch ends. Asserted on the process, not on a log line.
- **Resumable read:** two reads from the returned offsets concatenate to the
  whole output with nothing repeated and nothing missing.
- **Bounded read:** with the buffer bound set low, `dropped_before` is
  non-zero and the returned bytes are the tail, not a silent prefix.
- **Stale handle:** every operation answers `Unknown_handle` for a handle that
  parses but names nothing.

## 6. Verification (closed) & open questions

Closed by reading, 2026-08-25:

- `Eio.Process` in this tree (eio 1.3) has `spawn`, `await`, `signal` and
  `pipe`; `Process_eio` uses all four, so nothing new is needed underneath.
- `Process_eio`'s existing `run_argv_*` are all run-to-completion, which is why
  none of them can be reused here.
- `dispatch_result` has fourteen non-test consumers, measured, which is the
  cost §4 declines to pay.

Open:

- **Whose switch?** A turn's switch ends when the turn does, which is the
  behaviour codex#10767 complains about. A keeper's switch outlives turns,
  which is what a dev server needs and also what makes #26382 possible if
  teardown is wrong. This RFC does not choose; the first implementation takes
  the switch as an argument and the caller decides, and the decision needs its
  own evidence before a default exists.
- **Does `Output_contains` need more than a literal?** A regexp would invite
  inferring meaning from output, which the workspace rules forbid elsewhere
  for good reason. Left literal until a case shows up that a literal cannot
  express.

## 7. Non-goals / future

- Not a scheduler. Nothing here restarts a process, retries it, or notices it
  died and acts on that.
- No cross-run persistence. A handle is meaningless after the process that
  issued it ends, which §3.2 makes explicit rather than accidental.
- Not a terminal. `read` is bytes off a pipe; nothing interprets escape
  sequences or maintains a screen.

## 8. Workaround self-check (CLAUDE.md bar)

- **Telemetry-as-fix?** No. This adds capability; nothing here counts a
  failure in place of fixing it.
- **String/substring classifier?** `Output_contains` matches a literal the
  caller supplied and infers nothing from it. No string is classified.
- **N-of-M?** The four operations ship together; a subset would be a handle
  nobody can wait on.
- **Cap/cooldown/dedup/repair?** The output bound is a cap, declared as one:
  it is configuration with a registry row, and `dropped_before` reports every
  byte it cost. A cap that reports is a limit; a cap that hides is the
  anti-pattern.
- **Magic numbers?** None. No interval, no default timeout, no buffer literal.
  The three numbers this design could have hidden are the three §2 forbids.
- **Test backdoor?** None. `Registry.create` takes its `run` as an argument,
  which is how a test fixes it — an argument every caller passes, not a seam
  only tests use.
- **Second SSOT?** The buffer bound lives in the Keeper runtime setting
  registry, where the CI check already requires every setting to have a row.
