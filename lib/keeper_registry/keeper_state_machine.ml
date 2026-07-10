(** Keeper State Machine — Deterministic Core (RFC-0002).
    See .mli for documentation. *)

(* ── Phase ─────────────────────────────────────────────── *)

(* Types, transition matrix, and predicates extracted to
   [Keeper_state_machine_types] (godfile decomp). *)
include Keeper_state_machine_types

(** [is_terminal phase] is true iff [phase] cannot accept new turns.

    Stopped, Dead, and Zombie are terminal: in [can_transition] every
    outgoing edge from these sources is denied. Centralized here so the
    FSM, health surfaces, and the mermaid renderer share one source of
    truth instead of re-matching the terminal triple at each consumer.
    Exhaustive (no [_] wildcard) so adding a phase variant surfaces a
    compile-time warning here. *)
let is_terminal = function
  | Stopped | Dead | Zombie -> true
  | Offline
  | Running
  | Failing
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Crashed
  | Restarting -> false


(* ── derive_phase ──────────────────────────────────────── *)

(* Spec navigation (OCaml priority -> TLA+ line) — plan §3 Tier C1 Phase 0
   anchor. Authoritative spec mirror is KeeperReconcileLiveness.tla:88-101
   (DerivePhase operator). The priority runtime below is preserved
   verbatim; this block adds OCaml -> spec citations so drift is
   grep-discoverable from this side too.

     Priority | Spec citation
     ---------+----------------------------------------------------------
       1      | KeeperReconcileLiveness.tla:89-90 (Stopped: drain_complete
              |   AND ~compaction_active AND ~handoff_active)
       2      | (no spec — see Note A: launch_pending is pre-FSM)
       3a-c   | KeeperReconcileLiveness.tla:91-93 (Dead/Restarting/Crashed)
              |   boundary/KeeperRecoveryOrchestration.tla:53-57 (recovery)
       4      | KeeperReconcileLiveness.tla:94 (Draining)
       5      | KeeperReconcileLiveness.tla:96 (Paused — operator_paused;
              |   compact_retry_exhausted clause is OCaml-stricter, see
              |   Note B below — refinement, not drift)
       7a     | KeeperReconcileLiveness.tla:97 (HandingOff)
              |   KeeperConditionsGovernPhase.tla:96-100 (Transition action)
       7b     | KeeperReconcileLiveness.tla:98 (Compacting)
              |   KeeperCompactionLifecycle.tla:171-184 (Compacting cycle)
       7c     | KeeperCompactionLifecycle.tla:154 (Overflowed) — partition
              |   (KeeperReconcileLiveness omits Overflowed; coverage by
              |    sibling spec is intentional, see Note C)
       8      | KeeperReconcileLiveness.tla:99 (Failing — health degraded)
       9      | KeeperReconcileLiveness.tla:100 (Running)
              |   KeeperCoreTriad.tla:147,316 (turn_healthy=true -> Running)
      10      | KeeperReconcileLiveness.tla:101 (Offline fallback)

   Reverse direction (spec -> this function) anchors:
     KeeperReconcileLiveness.tla:86      "matching OCaml derive_phase"
     KeeperConditionsGovernPhase.tla:44  cites line 351 (HandingOff)
     KeeperCoreTriad.tla:147,316         cites Running mirror
     bug-models/KeeperPhaseRace.tla:7-10 cites this function entry

   Classification (plan §1 4-way):
     Note A — Resolved. Priority 2 Offline (launch_pending AND
       ~fiber_alive) is mirrored by
       specs/keeper-state-machine/KeeperLaunchPending.tla, a 3-phase
       projection (Offline / Running / Dead) with bug-action
       FiberStartedWithoutClearing. The lifecycle audit cites
       keeper_registry.ml:340 (set), this file:520 (clear in FSM),
       keeper_registry.ml:407 (clear on death) — all three sources
       are anchored in the spec's source-citation block.
     Note B — Refinement (acknowledged). Priority 6 OCaml clause
       `context_overflow AND compact_retry_exhausted -> Paused` is
       stricter than spec line 96 (operator_paused only). Without it
       Overflowed -> Compacting loops indefinitely when retries are
       exhausted; KeeperReconcileLiveness scope deliberately excludes
       compact retry semantics, which live in KeeperCompactionLifecycle.
     Note C — Partition (acknowledged). Overflowed phase derivation
       lives in KeeperCompactionLifecycle.tla; KeeperReconcileLiveness
       omits it because reconcile liveness is independent of overflow.
       Multi-spec coverage by design, not drift.

   C1 follow-up scope (plan §3, sequenced):
     - Phase 1 (per-priority): convert each branch to `let try_<action>
       state` mirroring the corresponding TLA+ Next-action enablement.
     - Phase 2 (compile-time): exhaustiveness ratchet — every spec
       action has exactly one OCaml try_ counterpart.
     - Phase 3 (optional, plan §11.1 not adopted by default): runtime
       gate `emit_phase_transition` — review hook only, not production. *)

let derive_phase (c : conditions) : phase =
  (* Priority order: first match wins.

     Design note: stop_requested + drain_complete -> Stopped is checked
     BEFORE fiber_alive checks. This means a keeper that completed its
     drain cleanly (drain_complete=true) reaches Stopped even if the
     fiber subsequently exits. This is correct: the drain succeeded,
     so the keeper should be Stopped, not Crashed.

     However, if the fiber dies DURING drain (drain_complete=false),
     the fiber_alive checks fire first and the keeper goes to Crashed.
     This is also correct: the drain did not complete.

     TLA+ model checking (TLC) found a deadlock where Stopped is entered
     while compaction_active or handoff_active is still TRUE. This is a
     semantic contradiction: drain_complete means ALL work is finished,
     which includes buffer operations. Guard Stopped against active buffer
     ops so the keeper stays in Draining until compaction/handoff exits. *)

  (* 0. Forced terminal state — external cleanup/credential signals. *)
  if c.credential_archived || c.zombie_timeout_reached
  then Dead (* 1. Completed stop — drain succeeded AND no buffer ops in flight *)
  else if
    c.stop_requested
    && c.drain_complete
    && (not c.compaction_active)
    && not c.handoff_active
  then Stopped (* 2. Pre-start registration. This is the only path into Offline. *)
  else if c.launch_pending && not c.fiber_alive
  then Offline (* 3. Terminal structural failure — Zombie (non-recoverable) *)
  else if c.terminal_failure_latched
  then Zombie (* 4. Fiber lifecycle — Dead / Restarting / Crashed *)
  else if (not c.fiber_alive) && not c.restart_budget_remaining
  then Dead
  else if (not c.fiber_alive) && c.restart_budget_remaining && c.backoff_elapsed
  then Restarting
  else if (not c.fiber_alive) && c.restart_budget_remaining
  then Crashed (* 5. In-progress stop — still draining *)
  else if c.stop_requested
  then Draining
    (* 6. Operator pause OR auto-compact retry budget exhausted.
     When [compact_retry_exhausted] is latched together with an ongoing
     [context_overflow], the keeper MUST land on [Paused] so that an
     operator has to intervene; otherwise [Overflowed → Compacting]
     would loop indefinitely. *)
  else if c.operator_paused || (c.context_overflow && c.compact_retry_exhausted)
  then Paused (* 8. Buffer states: in-progress operations *)
  else if c.handoff_active
  then HandingOff
  else if c.compaction_active
  then
    Compacting
    (* 8b. Context overflow awaiting auto-compact.
     Transient: [entry_actions_for] emits [Start_compaction] on entry,
     which flips [compaction_active] via [Auto_compact_triggered] and the
     next [derive_phase] returns [Compacting]. If [compaction_active] is
     already set (compaction already started), priority 8 wins and the
     keeper reads as [Compacting], not [Overflowed]. *)
  else if c.context_overflow
  then Overflowed (* 9. Health degradation *)
  else if (not c.heartbeat_healthy) || not c.turn_healthy
  then Failing (* 10. Healthy running *)
  else if c.fiber_alive
  then Running
  (* 11. Initial / unreachable fallback *)
  else Offline
;;

(* ── Condition Updaters ────────────────────────────────── *)

(** Update conditions based on an event. Returns new conditions. *)
let update_conditions (c : conditions) (ev : event) : conditions =
  match ev with
  | Heartbeat_ok -> { c with heartbeat_healthy = true }
  | Heartbeat_failed _ ->
    (* Any failure makes heartbeat unhealthy. Recovery requires Heartbeat_ok.
       The [consecutive] / [max_allowed] payload is for audit/logging, not
       for health determination — mirrors TLA+ HeartbeatFailed which sets
       [heartbeat_healthy' = FALSE] unconditionally
       (specs/keeper-state-machine/KeeperStateMachine.tla §HeartbeatFailed). *)
    { c with heartbeat_healthy = false }
  | Turn_succeeded -> { c with turn_healthy = true }
  | Turn_failed _ ->
    (* Mirrors TLA+ TurnFailed: [turn_healthy' = FALSE] unconditional.
       Same payload semantics as Heartbeat_failed (audit only). *)
    { c with turn_healthy = false }
  | Context_measured { context_actions; _ } ->
    { c with context_handoff_needed = context_actions.handoff }
  | Compaction_started -> { c with compaction_active = true }
  | Compaction_completed { before_tokens; after_tokens } ->
    (* #9988: "completed" alone does not mean the overflow was resolved.
       In production 98.4% of [Compaction_completed] events arrive with
       [before_tokens = after_tokens] because the checkpoint reducers
       produced no savings (no tool_result sections to strip, pure-text
       turns, etc).  Clearing [context_overflow] unconditionally created
       an infinite loop with [Context_overflow_detected]: the next turn
       re-measures the same context, re-fires overflow, re-attempts a
       noop compaction, and clears the flag again.  #9935 observed
       45-71 imminent events/day with zero observable reduction action.

       Treat [saved_tokens <= 0] as a noop: keep [context_overflow] set
       so the next layer (operator alert, stronger compaction profile,
       handoff) can take over. Only a real reduction clears the flag
       and releases the retry-exhausted latch. *)
    let saved_tokens = before_tokens - after_tokens in
    if saved_tokens > 0
    then
      { c with
        compaction_active = false
      ; context_overflow = false
      ; compact_retry_exhausted = false
      }
    else (
      Log.Keeper.warn
        "[fsm] compaction_completed with no savings (before=%d after=%d); keeping \
         context_overflow=true to avoid noop re-trigger loop"
        before_tokens
        after_tokens;
      { c with compaction_active = false })
  | Compaction_failed _ ->
    (* Leave [context_overflow] set — the overflow has not been resolved.
       The retry-exhausted latch is owned by the caller (keeper_unified_turn
       retry loop) and is promoted into this state machine via a subsequent
       [Operator_clear_requested] or [Context_overflow_detected] after
       the retry budget is depleted. *)
    { c with compaction_active = false }
  | Handoff_started -> { c with handoff_active = true }
  | Handoff_completed _ -> { c with handoff_active = false }
  | Handoff_failed _ -> { c with handoff_active = false }
  | Operator_pause -> { c with operator_paused = true }
  | Operator_resume -> { c with operator_paused = false }
  | Operator_stop _ -> { c with stop_requested = true }
  | Stop_requested -> { c with stop_requested = true }
  | Drain_complete -> { c with drain_complete = true }
  | Fiber_started ->
    (* A new fiber = a new life. Reset health, buffer, backoff, and stop conditions.
       Previous heartbeat/turn failures, in-progress compaction/handoff, and
       supervisor backoff state are all irrelevant to the new fiber.

       TLA+ model checking found that preserving stop_requested across fiber
       restart causes a liveness violation: the new fiber enters Draining
       immediately and can never complete drain, creating an infinite loop.
       Restart = "bring this keeper back" which contradicts "stop this keeper."
       Therefore stop_requested is reset on fiber start.

       operator_paused IS preserved — pause is an operator investigation tool
       that should survive restarts. Budget is preserved — it's a supervisor
       policy, not a fiber concern. *)
    { c with
      launch_pending = false
    ; fiber_alive = true
    ; heartbeat_healthy = true
    ; turn_healthy = true
    ; compaction_active = false
    ; handoff_active = false
    ; backoff_elapsed = false
    ; drain_complete = false
    ; stop_requested = false
    ; context_overflow = false
    ; compact_retry_exhausted = false
    ; terminal_failure_latched = false
    }
  | Fiber_terminated _ -> { c with fiber_alive = false }
  | Supervisor_restart_attempt _ -> { c with backoff_elapsed = true }
  | Restart_budget_exhausted -> { c with restart_budget_remaining = false }
  | Credential_archived ->
    { c with
      restart_budget_remaining = false
    ; fiber_alive = false
    ; credential_archived = true
    }
  | Zombie_timeout ->
    { c with restart_budget_remaining = false; zombie_timeout_reached = true }
  | Terminal_failure_detected _ -> { c with terminal_failure_latched = true }
  | Context_overflow_detected _ ->
    (* Hard overflow reported by the provider. The phase derivation
       maps this to either [Overflowed] (auto-compact path) or [Paused]
       (if the retry latch is already set). *)
    { c with context_overflow = true }
  | Auto_compact_triggered ->
    (* Emitted as part of [Overflowed] entry actions.  Promotes the
       keeper into [Compacting] on the next derivation without waiting
       for [Compaction_started] from the post-turn lifecycle. *)
    { c with compaction_active = true }
  | Compact_retry_exhausted ->
    (* Issue #8581: latch the retry-exhausted condition. Mirrors the
       TLA+ [CompactRetryExhausted] action. The right disjunct of
       [derive_phase]'s Paused branch — [(context_overflow &&
       compact_retry_exhausted)] — was previously dead code because
       no event ever set this flag; now [pause_keeper_for_overflow]
       dispatches it before [Operator_pause] so the Paused phase
       carries the actual reason for dashboards / observability. *)
    { c with compact_retry_exhausted = true }
  | Operator_compact_requested ->
    (* Operator override: same as [Auto_compact_triggered] but also
       releases the retry latch so that a fresh compaction sequence
       starts. *)
    { c with compaction_active = true; compact_retry_exhausted = false }
  | Operator_clear_requested _ ->
    (* Last resort: context fully dropped by [masc_keeper_clear].
       Conditions reset in-place without passing through [Compacting]. *)
    { c with context_overflow = false; compact_retry_exhausted = false }
;;

(** Compute entry actions for a phase transition.
    [Publish_lifecycle] is always consumed by the registry runtime.
    [Start_compaction] is additionally consumed for the auto-compact
    [Overflowed] path; the remaining variants stay descriptive here
    because their side effects are still owned elsewhere
    (post-turn lifecycle or supervisor).

    Structure (Iteration 2, /loop FSM drift hunt — Phase A-2):
    Outer match is on [new_phase] so every phase variant is exhaustively
    enumerated and the compiler warns on future phase addition. Inner
    matches on [prev_phase] enumerate every variant explicitly (no
    wildcard) so the same future-proofing applies to prev-dependent arms.
    Pre-refactor behaviour is preserved verbatim — the four classes that
    previously fell through the [| _ -> []] catch-all (transitions into
    Offline, Crashed, into Running from non-{Restarting,Failing,Paused},
    into Restarting from non-Crashed) now return [] from explicit arms
    with comments documenting *why* the no-op is intentional. *)
let entry_actions_for ~prev_phase ~new_phase ~(event : event) : entry_action list =
  let lifecycle name detail = Publish_lifecycle { event_name = name; detail } in
  match new_phase with
  | Compacting -> [ Start_compaction; lifecycle "compaction_started" "" ]
  | HandingOff -> [ Start_handoff; lifecycle "handoff_started" "" ]
  | Draining -> [ Start_drain; lifecycle "draining" "" ]
  | Dead ->
    [ Mark_dead_tombstone
    ; lifecycle "dead" (event_to_string event)
    ; Trigger_immediate_cleanup
    ; Cancel_pending_oas
    ]
  | Zombie -> [ Mark_zombie_tombstone; lifecycle "zombie" "terminal structural failure" ]
  | Stopped ->
    [ Cleanup_and_unregister
    ; lifecycle
        "stopped"
        (match event with
         | Operator_stop { remove_meta } -> Printf.sprintf "remove_meta=%b" remove_meta
         | Drain_complete -> "drain_complete"
         | Heartbeat_ok
         | Heartbeat_failed _
         | Turn_succeeded
         | Turn_failed _
         | Context_measured _
         | Compaction_started
         | Compaction_completed _
         | Compaction_failed _
         | Context_overflow_detected _
         | Compact_retry_exhausted
         | Handoff_started
         | Handoff_completed _
         | Handoff_failed _
         | Operator_pause
         | Operator_resume
         | Stop_requested
         | Fiber_started
         | Fiber_terminated _
         | Supervisor_restart_attempt _
         | Restart_budget_exhausted
         | Credential_archived
         | Zombie_timeout
         | Terminal_failure_detected _
         | Auto_compact_triggered
         | Operator_compact_requested
         | Operator_clear_requested _ -> event_to_string event)
    ]
  (* [Overflowed] entry actions: request a compaction so the registry can
     promote the committed [Overflowed] transition into the follow-up
     [Auto_compact_triggered] event, and publish the transition so
     operators can see "context overflow" distinctly from generic failure. *)
  | Overflowed ->
    [ Start_compaction
    ; lifecycle
        "overflowed"
        (match event with
         | Context_overflow_detected r ->
           let lim =
             match r.limit_tokens with
             | Some n -> Printf.sprintf ",limit=%d" n
             | None -> ""
           in
           Printf.sprintf "tokens=%d%s" r.token_count lim
         | Compact_retry_exhausted
         | Heartbeat_ok
         | Heartbeat_failed _
         | Turn_succeeded
         | Turn_failed _
         | Context_measured _
         | Compaction_started
         | Compaction_completed _
         | Compaction_failed _
         | Handoff_started
         | Handoff_completed _
         | Handoff_failed _
         | Operator_pause
         | Operator_resume
         | Operator_stop _
         | Stop_requested
         | Drain_complete
         | Fiber_started
         | Fiber_terminated _
         | Supervisor_restart_attempt _
         | Restart_budget_exhausted
         | Credential_archived
         | Zombie_timeout
         | Terminal_failure_detected _
         | Auto_compact_triggered
         | Operator_compact_requested
         | Operator_clear_requested _ -> event_to_string event)
    ]
  | Failing -> [ lifecycle "failing" (event_to_string event) ]
  | Paused ->
    (* Distinguish operator-pause from overflow-induced pause so the
       dashboard can surface the right message.
       Issue #8728: Compact_retry_exhausted (added in #8581 specifically
       to stop conflating operator pauses with auto-compact budget
       exhaustion) used to fall into the catch-all and get re-labelled
       as "operator request" - defeating the new event's whole purpose.
       List both overflow-class events explicitly so the distinction
       reaches the dashboard. *)
    let detail =
      match event with
      | Context_overflow_detected _ | Compact_retry_exhausted ->
        "auto-compact retry exhausted"
      | Operator_pause -> "operator request"
      | Heartbeat_ok
      | Heartbeat_failed _
      | Turn_succeeded
      | Turn_failed _
      | Context_measured _
      | Compaction_started
      | Compaction_completed _
      | Compaction_failed _
      | Handoff_started
      | Handoff_completed _
      | Handoff_failed _
      | Operator_resume
      | Operator_stop _
      | Stop_requested
      | Drain_complete
      | Fiber_started
      | Fiber_terminated _
      | Supervisor_restart_attempt _
      | Restart_budget_exhausted
      | Credential_archived
      | Zombie_timeout
      | Terminal_failure_detected _
      | Auto_compact_triggered
      | Operator_compact_requested
      | Operator_clear_requested _ ->
        (* These events should not normally trigger a Paused transition,
           but if they do, label generically rather than mis-attributing
           to "operator request". *)
        event_to_string event
    in
    [ lifecycle "paused" detail ]
  | Restarting ->
    (match prev_phase with
     | Crashed -> [ lifecycle "restarting" "backoff elapsed" ]
     | Offline
     | Running
     | Failing
     | Overflowed
     | Compacting
     | HandingOff
     | Draining
     | Paused
     | Stopped
     | Restarting
     | Dead
     | Zombie ->
       (* Direct transitions to Restarting from non-Crashed phases are not
          a normal lifecycle path; the supervisor / registry owns publishing
          for those rare corner cases. Intentional no-op (matches the
          pre-refactor catch-all [| _ -> []]). *)
       [])
  | Running ->
    (match prev_phase with
     | Restarting -> [ lifecycle "restarted" "fiber launched" ]
     | Failing -> [ lifecycle "recovered" "failure counters reset" ]
     | Paused ->
       (* Issue #8732 (sibling of #8728): resume is event-driven, not always
          operator-initiated. [Compaction_completed] / [Fiber_terminated]
          clear the latched [compact_retry_exhausted] flag and let
          [derive_phase] leave Paused; if we hardcode "operator request"
          the dashboard claims a human resumed the keeper when in fact
          auto-compact recovered. Mirror the per-event arms used in the
          Paused-detail label. *)
       let detail =
         match event with
         | Operator_resume -> "operator request"
         | Compaction_completed _ -> "auto-compact recovered"
         | Fiber_terminated _ -> "fiber recovered"
         | Heartbeat_ok
         | Heartbeat_failed _
         | Turn_succeeded
         | Turn_failed _
         | Context_measured _
         | Compaction_started
         | Compaction_failed _
         | Handoff_started
         | Handoff_completed _
         | Handoff_failed _
         | Operator_stop _
         | Operator_pause
         | Stop_requested
         | Drain_complete
         | Fiber_started
         | Supervisor_restart_attempt _
         | Restart_budget_exhausted
         | Credential_archived
         | Zombie_timeout
         | Terminal_failure_detected _
         | Auto_compact_triggered
         | Operator_compact_requested
         | Context_overflow_detected _
         | Compact_retry_exhausted
         | Operator_clear_requested _ ->
           (* These events should not normally trigger a Paused→Running
              transition; label generically via [event_to_string]. *)
           event_to_string event
       in
       [ lifecycle "resumed" detail ]
     | Offline
     | Running
     | Overflowed
     | Compacting
     | HandingOff
     | Draining
     | Stopped
     | Crashed
     | Dead
     | Zombie ->
       (* [register] takes Init → Running without traversing this function
          (it uses [register_with_state] directly). For other prevs (e.g.
          Compacting → Running on auto-compact success, Overflowed →
          Running similarly), the registry runtime publishes its own
          lifecycle event covering the recovery semantics. Intentional
          no-op (matches the pre-refactor catch-all [| _ -> []]). *)
       [])
  | Offline ->
    (* Returning to Offline is rare and typically driven by registry-level
       lifecycle (register_offline or unregister-then-readmit). Intentional
       no-op (matches the pre-refactor catch-all [| _ -> []]). Future RFC
       candidate: emit a distinct "offline" lifecycle when transitioning
       *from* a non-Offline phase, for dashboard auditability. *)
    []
  | Crashed ->
    (* The fiber terminated unexpectedly. The supervisor publishes its own
       lifecycle event via [Supervisor_restart_attempt] follow-up, so we
       avoid double-publishing here. Intentional no-op (matches the
       pre-refactor catch-all [| _ -> []]). Future RFC candidate: emit a
       distinct "crashed" lifecycle with the terminating event's detail
       so dashboards can distinguish crash cause without relying on the
       supervisor's follow-up. *)
    []
;;

(* ── Event preconditions (R-A-9 minimal layer) ──────────

   TLA+ KeeperStateMachine.tla enumerates state preconditions per
   action (e.g. CompactRetryExhausted requires
   [context_overflow /\ ~compaction_active /\ ~compact_retry_exhausted]).
   [update_conditions] is a pure record-update and ignores them — a
   mis-ordered caller can set [compact_retry_exhausted = TRUE] on a
   non-overflowed keeper, which then latches the keeper into [Paused]
   the next time an overflow event arrives (silent forced operator
   intervention).

   This helper enforces a subset of those preconditions at the
   [apply_event] boundary so silent corruption becomes a typed
   [Precondition_violation] result.  Coverage extended incrementally
   across the spec/code refinement chain (R-A-9, then R-A-6.b):
     - PR-1: Compact_retry_exhausted (latch correctness)
     - PR-2: Context_overflow_detected, Auto_compact_triggered (overflow
       lifecycle — the two events that drive Overflowed↔Compacting)
     - PR-3: Operator_compact_requested (operator-driven buffer op
       exclusivity).  Operator_clear_requested is deliberately *not*
       arm-enforced beyond the terminal guard — see its arm below for
       the operator escape-hatch rationale.
     - R-A-6.b: Restart_budget_exhausted (non-idempotency — pairs with
       §S3 BudgetNeverRevives liveness invariant; iter 14 audit).

   Coverage: 5/5 R-A-9 events (Compact_retry_exhausted,
   Context_overflow_detected, Auto_compact_triggered,
   Operator_compact_requested, Operator_clear_requested) plus the
   adjacent R-A-6.b Restart_budget_exhausted arm (iter 14 follow-up).
   Other events have no spec preconditions beyond NotTerminal and
   fall through the catch-all.

   Background:
     - iter 9 audit memo: docs/tla-audit/ksm-precondition-enforcement-gap-2026-05-12.md
     - iter 9 PR #14730 (systematic gap class)
     - TLA+ §ContextOverflowDetected, §AutoCompactTriggered,
       §CompactRetryExhausted in KeeperStateMachine.tla *)
let check_event_precondition (c : conditions) (ev : event)
  : (unit, transition_error) result
  =
  (* [reason] strings are short stable tags ("context_overflow=false" etc).
     They flow into [transition_error_to_string] log lines and the
     [Attribution.policy_failed.reason] telemetry field — keeping them
     low-cardinality lets operators aggregate / alert on the exact
     precondition that failed, while the long explanatory text stays
     in source comments above each branch.

     TLA+ §CompactRetryExhausted predicates: context_overflow=true /\
     ~compaction_active /\ ~compact_retry_exhausted. *)
  match ev with
  | Compact_retry_exhausted ->
    if not c.context_overflow
    then
      (* Latching the retry flag on a non-overflowed keeper would force
         Paused on the next overflow event (TLA+ violation). *)
      Error
        (Precondition_violation
           { event = event_to_string ev; reason = "context_overflow=false" })
    else if c.compaction_active
    then
      (* Latching the retry flag while a compaction is in flight
         conflates the in-progress attempt with budget exhaustion. *)
      Error
        (Precondition_violation
           { event = event_to_string ev; reason = "compaction_active=true" })
    else if c.compact_retry_exhausted
    then
      (* Retry latch is idempotent — re-latching surfaces a duplicate
         dispatch in the caller. *)
      Error
        (Precondition_violation
           { event = event_to_string ev; reason = "already_latched" })
    else Ok ()
  | Context_overflow_detected _ ->
    if c.compaction_active
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §ContextOverflowDetected requires ~compaction_active; \
                an overflow signal while compaction is already running means \
                the in-flight compaction is the runaway — the retry latch \
                must catch it, not a fresh overflow event that conflates the \
                two attempts"
           })
    else Ok ()
  | Auto_compact_triggered ->
    if not c.context_overflow
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §AutoCompactTriggered requires context_overflow=true; \
                triggering auto-compaction on a non-overflowed keeper flips \
                compaction_active outside the Overflowed→Compacting transition \
                and corrupts the overflow lifecycle invariant"
           })
    else if c.compaction_active
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §AutoCompactTriggered requires ~compaction_active; \
                re-triggering while a compaction is already in flight \
                duplicates the buffer op and tangles the ordering"
           })
    else if c.handoff_active
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §AutoCompactTriggered requires ~handoff_active; \
                starting a compaction during handoff entangles two buffer \
                ops on the same keeper"
           })
    else if c.compact_retry_exhausted
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §AutoCompactTriggered requires ~compact_retry_exhausted; \
                the retry budget is spent — DerivePhase routes the next \
                overflow to Paused, and a fresh auto-compact would defeat \
                that latch (Issue #8581 root cause)"
           })
    else Ok ()
  | Operator_compact_requested ->
    (* TLA+ §OperatorCompactRequested.  Operator path differs from
       AutoCompactTriggered: it does NOT require [context_overflow], so
       an operator can pre-emptively compact a not-yet-overflowed
       keeper.  But the two buffer-op exclusivity preconditions are
       identical — concurrent compaction or handoff entangles ops. *)
    if c.compaction_active
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §OperatorCompactRequested requires ~compaction_active; \
                stacking operator-driven compaction on top of an in-flight \
                buffer op duplicates the work and confuses the retry latch \
                that OperatorCompactRequested clears as a side-effect"
           })
    else if c.handoff_active
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §OperatorCompactRequested requires ~handoff_active; \
                handoff already owns the buffer, so a concurrent operator \
                compaction would race on the same keeper context"
           })
    else Ok ()
  | Operator_clear_requested _ ->
    (* TLA+ §OperatorClearRequested deliberately requires only NotTerminal
       (lib §masc_keeper_clear: "Last-resort: operator drops the keeper's
       context entirely").  The terminal guard at the top of [apply_event]
       already enforces this, so no extra arm is needed here.  Documented
       to make the deliberate minimal precondition explicit — adding any
       check beyond NotTerminal would weaken the operator escape-hatch. *)
    Ok ()
  | Restart_budget_exhausted ->
    (* TLA+ §RestartBudgetExhausted requires [restart_budget_remaining];
       re-exhausting an already-exhausted budget is a logical no-op in
       isolation, but masks a duplicate dispatch in the caller and —
       paired with the §S3 [BudgetNeverRevives] invariant — indicates
       the supervisor's restart-vs-mark-dead gate was bypassed.

       This is the 6th R-A-9 candidate, identified in iter 14 audit
       memo `docs/tla-audit/ksm-a6-budget-never-revives-2026-05-12.md`
       — same systematic gap class as the 5 events in iter 9's
       original enumeration. *)
    if not c.restart_budget_remaining
    then
      Error
        (Precondition_violation
           { event = event_to_string ev
           ; reason =
               "TLA+ §RestartBudgetExhausted requires \
                restart_budget_remaining=true; re-exhausting an already-\
                exhausted budget masks a duplicate dispatch and \
                signals the supervisor's restart-vs-mark-dead gate \
                may have been bypassed (see §S3 BudgetNeverRevives)"
           })
    else Ok ()
  (* Other events have no TLA+ state preconditions beyond what
     [apply_event]'s terminal guard already enforces; their semantics
     are encoded in [update_conditions] + [derive_phase] (e.g.
     [Heartbeat_failed] always flips [heartbeat_healthy] to false
     regardless of prior state).  Adding speculative arms here would
     drift from the spec. *)
  | _ -> Ok ()
;;

(* ── apply_event ───────────────────────────────────────── *)

let apply_event ~current_phase ~conditions ~event ~now =
  (* Terminal states reject all events. Non-terminal phases enumerated
     explicitly per software-development.md §"FSM Sparse Match" — if a
     new phase variant is added, this match surfaces warning 8 instead
     of silently routing the new phase to the non-terminal branch
     (which is wrong if the new phase is itself intended terminal).
     Mirrors the [can_transition] exhaustive refactor in #16747. *)
  match current_phase with
  | Stopped | Dead | Zombie ->
    Error
      (Terminal_state { current = current_phase; attempted_event = event_to_string event })
  | Offline
  | Running
  | Failing
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Crashed
  | Restarting ->
    (match check_event_precondition conditions event with
     | Error _ as e -> e
     | Ok () ->
    let updated_conditions = update_conditions conditions event in
    let new_phase = derive_phase updated_conditions in
    (* Validate transition is allowed *)
    if new_phase = current_phase
    then
      (* No transition — still valid *)
      Ok
        { prev_phase = current_phase
        ; new_phase
        ; updated_conditions
        ; entry_actions = []
        ; event_applied = event
        ; timestamp = now
        }
    else if can_transition ~from_phase:current_phase ~to_phase:new_phase
    then
      Ok
        { prev_phase = current_phase
        ; new_phase
        ; updated_conditions
        ; entry_actions = entry_actions_for ~prev_phase:current_phase ~new_phase ~event
        ; event_applied = event
        ; timestamp = now
        }
    else
      (* derive_phase produced a phase that can_transition rejects.
         This indicates a logic error between derive_phase and the matrix. *)
      Error
        (Invalid_transition
           { from_phase = current_phase
           ; to_phase = new_phase
           ; reason =
               Printf.sprintf
                 "event %s caused derive_phase to produce %s from %s, but this \
                  transition is not in the matrix"
                 (event_to_string event)
                 (phase_to_string new_phase)
                 (phase_to_string current_phase)
           }))
;;

(* ── JSON Serialization ────────────────────────────────── *)

(* JSON wire encoders extracted to [Keeper_state_machine_json]
   (godfile decomp). No reverse alias - wrapped-library cycle blocks
   it (PR #16880 pattern). External callers reference the sibling. *)

(* ── Mermaid State Diagram ────────────────────────────── *)

(** Maps a phase to the capitalized state ID used in the Mermaid diagram. *)
(* Mermaid rendering extracted to [Keeper_state_machine_mermaid]
   (godfile decomp).  No reverse alias here: wrapped-library sibling
   would create an import cycle (Keeper_state_machine_rendering attempt
   2026-05; see ~/me memory). Callers must use the sibling directly. *)

(* --- Attribution envelope conversion (Layer 1) ---
   Keeper FSM is Det by design: non-deterministic measurements are
   already translated into typed events at the boundary before this
   module sees them. See the [event] type docstring. *)

let attribution_of_transition
      ~event
      (result : (transition_result, transition_error) result)
  : Attribution.t
  =
  let event_name = event_to_string event in
  match result with
  | Ok tr ->
    let evidence : Yojson.Safe.t =
      `Assoc
        [ "event", `String event_name
        ; "from_phase", `String (phase_to_string tr.prev_phase)
        ; "to_phase", `String (phase_to_string tr.new_phase)
        ; "timestamp", `Float tr.timestamp
        ]
    in
    Attribution.passed ~origin:Det ~gate:"keeper_fsm" ~evidence
  | Error (Invalid_transition { from_phase; to_phase; reason }) ->
    let evidence : Yojson.Safe.t = `Assoc [ "event", `String event_name ] in
    Attribution.transition_blocked
      ~origin:Det
      ~gate:"keeper_fsm"
      ~evidence
      ~from_state:(phase_to_string from_phase)
      ~to_state:(phase_to_string to_phase)
      ~reason
  | Error (Terminal_state { current; attempted_event }) ->
    let evidence : Yojson.Safe.t =
      `Assoc
        [ "event", `String event_name
        ; "current_phase", `String (phase_to_string current)
        ; "attempted_event", `String attempted_event
        ]
    in
    let reason =
      Printf.sprintf
        "keeper in terminal phase %s, event %s ignored"
        (phase_to_string current)
        attempted_event
    in
    Attribution.policy_failed ~origin:Det ~gate:"keeper_fsm" ~evidence ~reason
  | Error (Precondition_violation { event = ev; reason }) ->
    let evidence : Yojson.Safe.t =
      `Assoc
        [ "event", `String event_name
        ; "violated_event", `String ev
        ; "precondition_reason", `String reason
        ]
    in
    Attribution.policy_failed ~origin:Det ~gate:"keeper_fsm" ~evidence ~reason
;;
