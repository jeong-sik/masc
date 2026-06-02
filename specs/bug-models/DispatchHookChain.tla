---- MODULE DispatchHookChain ----
\* Bug Model: Tool dispatch pre-hook / dispatch observer execution order.
\*
\* Models tool_dispatch.ml: dispatch_structured.
\* Pre-hooks run in order; first Reject short-circuits.
\* Proceed replaces args for subsequent hooks.
\* Dispatch observers inspect the result.
\*
\* Bug: a Proceed hook coerces args, then a later Reject hook fires.
\* The coerced args are logged/observed but the handler never ran.
\* This is semantically confusing but not a crash — the model verifies
\* the handler-skip invariant holds even with coercion.

EXTENDS Naturals, Sequences

CONSTANTS NumPreHooks  \* Number of registered pre-hooks (e.g. 3)

VARIABLES
    hook_idx,           \* Current pre-hook index (1..NumPreHooks, 0=done)
    hook_actions,       \* Function: hook index -> "pass" | "proceed" | "reject"
    args_version,       \* Tracks coercion: 0=original, 1+=coerced
    short_circuited,    \* Boolean: a Reject was encountered
    handler_ran,        \* Boolean: main handler executed
    observers_ran,      \* Boolean: dispatch observers executed
    phase               \* "pre_hooks" | "handler" | "observers" | "done"

vars == <<hook_idx, hook_actions, args_version, short_circuited, handler_ran, observers_ran, phase>>

Init ==
    /\ hook_idx = 1
    /\ hook_actions \in [1..NumPreHooks -> {"pass", "proceed", "reject"}]
    /\ args_version = 0
    /\ short_circuited = FALSE
    /\ handler_ran = FALSE
    /\ observers_ran = FALSE
    /\ phase = "pre_hooks"

\* ── Pre-hook execution ─────────────────────────────────

RunPreHook ==
    /\ phase = "pre_hooks"
    /\ hook_idx <= NumPreHooks
    /\ ~short_circuited
    /\ CASE hook_actions[hook_idx] = "pass" ->
            /\ hook_idx' = hook_idx + 1
            /\ UNCHANGED <<args_version, short_circuited>>
         [] hook_actions[hook_idx] = "proceed" ->
            /\ hook_idx' = hook_idx + 1
            /\ args_version' = args_version + 1
            /\ UNCHANGED short_circuited
         [] hook_actions[hook_idx] = "reject" ->
            /\ short_circuited' = TRUE
            /\ hook_idx' = hook_idx + 1
            /\ UNCHANGED args_version
    /\ UNCHANGED <<handler_ran, observers_ran, phase, hook_actions>>

\* All pre-hooks done, transition to handler or done
PreHooksDone ==
    /\ phase = "pre_hooks"
    /\ (hook_idx > NumPreHooks \/ short_circuited)
    /\ phase' = IF short_circuited THEN "done" ELSE "handler"
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, handler_ran, observers_ran>>

\* ── Handler ────────────────────────────────────────────

RunHandler ==
    /\ phase = "handler"
    /\ handler_ran' = TRUE
    /\ phase' = "observers"
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, observers_ran>>

\* ── Dispatch observers ─────────────────────────────────

RunDispatchObservers ==
    /\ phase = "observers"
    /\ observers_ran' = TRUE
    /\ phase' = "done"
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, handler_ran>>

\* ── Next ───────────────────────────────────────────────

Next ==
    \/ RunPreHook
    \/ PreHooksDone
    \/ RunHandler
    \/ RunDispatchObservers

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ──────────────────────────────────

\* If short-circuited, handler must NOT run.
ShortCircuitSkipsHandler ==
    (short_circuited /\ phase = "done") => ~handler_ran

\* Dispatch observers only run after handler.
ObserversAfterHandler ==
    observers_ran => handler_ran

\* Handler only runs if no rejection.
HandlerRequiresNoReject ==
    handler_ran => ~short_circuited

\* ── Bug Model ──────────────────────────────────────────

\* Bug: short-circuit does NOT skip handler (e.g. missing check).
BuggyPreHooksDone ==
    /\ phase = "pre_hooks"
    /\ (hook_idx > NumPreHooks \/ short_circuited)
    /\ phase' = "handler"  \* Bug: always proceeds to handler
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, handler_ran, observers_ran>>

NextBuggy ==
    \/ RunPreHook
    \/ BuggyPreHooksDone
    \/ RunHandler
    \/ RunDispatchObservers

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

====
