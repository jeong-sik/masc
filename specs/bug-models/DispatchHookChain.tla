---- MODULE DispatchHookChain ----
\* Bug Model: Tool dispatch pre-hook / post-hook execution order.
\*
\* Models tool_dispatch.ml: dispatch_structured.
\* Pre-hooks run in order; first Reject short-circuits.
\* Proceed replaces args for subsequent hooks.
\* Post-hooks transform the result.
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
    post_hooks_ran,     \* Boolean: post-hooks executed
    phase               \* "pre_hooks" | "handler" | "post_hooks" | "done"

vars == <<hook_idx, hook_actions, args_version, short_circuited, handler_ran, post_hooks_ran, phase>>

Init ==
    /\ hook_idx = 1
    /\ hook_actions \in [1..NumPreHooks -> {"pass", "proceed", "reject"}]
    /\ args_version = 0
    /\ short_circuited = FALSE
    /\ handler_ran = FALSE
    /\ post_hooks_ran = FALSE
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
    /\ UNCHANGED <<handler_ran, post_hooks_ran, phase, hook_actions>>

\* All pre-hooks done, transition to handler or done
PreHooksDone ==
    /\ phase = "pre_hooks"
    /\ (hook_idx > NumPreHooks \/ short_circuited)
    /\ phase' = IF short_circuited THEN "done" ELSE "handler"
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, handler_ran, post_hooks_ran>>

\* ── Handler ────────────────────────────────────────────

RunHandler ==
    /\ phase = "handler"
    /\ handler_ran' = TRUE
    /\ phase' = "post_hooks"
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, post_hooks_ran>>

\* ── Post-hooks ─────────────────────────────────────────

RunPostHooks ==
    /\ phase = "post_hooks"
    /\ post_hooks_ran' = TRUE
    /\ phase' = "done"
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, handler_ran>>

\* ── Next ───────────────────────────────────────────────

Next ==
    \/ RunPreHook
    \/ PreHooksDone
    \/ RunHandler
    \/ RunPostHooks

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ──────────────────────────────────

\* If short-circuited, handler must NOT run.
ShortCircuitSkipsHandler ==
    (short_circuited /\ phase = "done") => ~handler_ran

\* Post-hooks only run after handler.
PostHooksAfterHandler ==
    post_hooks_ran => handler_ran

\* Handler only runs if no rejection.
HandlerRequiresNoReject ==
    handler_ran => ~short_circuited

\* ── Bug Model ──────────────────────────────────────────

\* Bug: short-circuit does NOT skip handler (e.g. missing check).
BuggyPreHooksDone ==
    /\ phase = "pre_hooks"
    /\ (hook_idx > NumPreHooks \/ short_circuited)
    /\ phase' = "handler"  \* Bug: always proceeds to handler
    /\ UNCHANGED <<hook_idx, hook_actions, args_version, short_circuited, handler_ran, post_hooks_ran>>

NextBuggy ==
    \/ RunPreHook
    \/ BuggyPreHooksDone
    \/ RunHandler
    \/ RunPostHooks

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

====
