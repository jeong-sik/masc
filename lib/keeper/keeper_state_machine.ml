(** Keeper State Machine — Deterministic Core (RFC-0002).
    See .mli for documentation. *)

(* ── Phase ─────────────────────────────────────────────── *)

type phase =
  | Offline
  | Running
  | Failing
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting
  | Dead

let phase_to_string = function
  | Offline -> "offline"
  | Running -> "running"
  | Failing -> "failing"
  | Overflowed -> "overflowed"
  | Compacting -> "compacting"
  | HandingOff -> "handing_off"
  | Draining -> "draining"
  | Paused -> "paused"
  | Stopped -> "stopped"
  | Crashed -> "crashed"
  | Restarting -> "restarting"
  | Dead -> "dead"
;;

let phase_of_string = function
  | "offline" -> Some Offline
  | "running" -> Some Running
  | "failing" -> Some Failing
  | "overflowed" -> Some Overflowed
  | "compacting" -> Some Compacting
  | "handing_off" -> Some HandingOff
  | "draining" -> Some Draining
  | "paused" -> Some Paused
  | "stopped" -> Some Stopped
  | "crashed" -> Some Crashed
  | "restarting" -> Some Restarting
  | "dead" -> Some Dead
  | _ -> None
;;

let all_phases =
  [ Offline
  ; Running
  ; Failing
  ; Overflowed
  ; Compacting
  ; HandingOff
  ; Draining
  ; Paused
  ; Stopped
  ; Crashed
  ; Restarting
  ; Dead
  ]
;;

(* ── Conditions ────────────────────────────────────────── *)

type conditions =
  { launch_pending : bool
  ; fiber_alive : bool
  ; heartbeat_healthy : bool
  ; turn_healthy : bool
  ; context_within_budget : bool
  ; context_handoff_needed : bool
  ; compaction_active : bool
  ; handoff_active : bool
  ; operator_paused : bool
  ; stop_requested : bool
  ; restart_budget_remaining : bool
  ; backoff_elapsed : bool
  ; guardrail_triggered : bool
  ; drain_complete : bool
  ; context_overflow : bool
  ; compact_retry_exhausted : bool
  }

let default_conditions =
  { launch_pending = false
  ; fiber_alive = false
  ; heartbeat_healthy = true
  ; turn_healthy = true
  ; context_within_budget = true
  ; context_handoff_needed = false
  ; compaction_active = false
  ; handoff_active = false
  ; operator_paused = false
  ; stop_requested = false
  ; restart_budget_remaining = false
  ; backoff_elapsed = false
  ; guardrail_triggered = false
  ; drain_complete = false
  ; context_overflow = false
  ; compact_retry_exhausted = false
  }
;;

(* ── Events ────────────────────────────────────────────── *)

type auto_rule_summary =
  { reflect : bool
  ; plan : bool
  ; compact : bool
  ; handoff : bool
  ; guardrail_stop : bool
  ; guardrail_reason : string option
  ; goal_drift : float
  }

type event =
  | Heartbeat_ok
  | Heartbeat_failed of
      { consecutive : int
      ; max_allowed : int
      }
  | Turn_succeeded
  | Turn_failed of
      { consecutive : int
      ; max_allowed : int
      }
  | Context_measured of
      { context_ratio : float
      ; message_count : int
      ; token_count : int
      ; auto_rules : auto_rule_summary
      }
  | Compaction_started
  | Compaction_completed of
      { before_tokens : int
      ; after_tokens : int
      }
  | Compaction_failed of { reason : string }
  | Handoff_started
  | Handoff_completed of
      { new_trace_id : string
      ; generation : int
      }
  | Handoff_failed of { reason : string }
  | Operator_pause
  | Operator_resume
  | Operator_stop of { remove_meta : bool }
  | Stop_requested
  | Drain_complete
  | Fiber_started
  | Fiber_terminated of { outcome : string }
  | Supervisor_restart_attempt of { attempt : int }
  | Restart_budget_exhausted
  | Guardrail_stop of { reason : string }
  | Context_overflow_detected of
      { source : [ `Prompt_rejected | `Oas_signal ]
      ; token_count : int
      ; limit_tokens : int option
      }
  | Auto_compact_triggered
  | Compact_retry_exhausted
  (** Issue #8581: latch the [compact_retry_exhausted] condition.

        Before this event existed, the field was read in [derive_phase]
        but never set in OCaml — the right disjunct of the Paused
        promotion ([context_overflow] /\ [compact_retry_exhausted]) was
        dead code. The retry-loop in [keeper_unified_turn] paused the
        keeper via [Operator_pause] instead, conflating "operator paused"
        with "auto-compact retry budget exhausted" on dashboards.

        Dispatchers should fire this BEFORE [Operator_pause] so the
        Paused phase carries the real reason (budget exhaustion) for
        observability, while the existing first disjunct
        ([operator_paused]) still drives derive_phase deterministically. *)
  | Operator_compact_requested
  | Operator_clear_requested of
      { preserve_system : bool
      ; reason : string
      }

let event_to_string = function
  | Heartbeat_ok -> "heartbeat_ok"
  | Heartbeat_failed r ->
    Printf.sprintf "heartbeat_failed(%d/%d)" r.consecutive r.max_allowed
  | Turn_succeeded -> "turn_succeeded"
  | Turn_failed r -> Printf.sprintf "turn_failed(%d/%d)" r.consecutive r.max_allowed
  | Context_measured r -> Printf.sprintf "context_measured(ratio=%.3f)" r.context_ratio
  | Compaction_started -> "compaction_started"
  | Compaction_completed r ->
    Printf.sprintf "compaction_completed(%d->%d)" r.before_tokens r.after_tokens
  | Compaction_failed r -> Printf.sprintf "compaction_failed(%s)" r.reason
  | Handoff_started -> "handoff_started"
  | Handoff_completed r -> Printf.sprintf "handoff_completed(gen=%d)" r.generation
  | Handoff_failed r -> Printf.sprintf "handoff_failed(%s)" r.reason
  | Operator_pause -> "operator_pause"
  | Operator_resume -> "operator_resume"
  | Operator_stop r -> Printf.sprintf "operator_stop(remove_meta=%b)" r.remove_meta
  | Stop_requested -> "stop_requested"
  | Drain_complete -> "drain_complete"
  | Fiber_started -> "fiber_started"
  | Fiber_terminated r -> Printf.sprintf "fiber_terminated(%s)" r.outcome
  | Supervisor_restart_attempt r ->
    Printf.sprintf "supervisor_restart_attempt(%d)" r.attempt
  | Restart_budget_exhausted -> "restart_budget_exhausted"
  | Guardrail_stop r -> Printf.sprintf "guardrail_stop(%s)" r.reason
  | Context_overflow_detected r ->
    let src =
      match r.source with
      | `Prompt_rejected -> "prompt_rejected"
      | `Oas_signal -> "oas_signal"
    in
    let lim =
      match r.limit_tokens with
      | Some n -> string_of_int n
      | None -> "?"
    in
    Printf.sprintf
      "context_overflow_detected(%s,tokens=%d,limit=%s)"
      src
      r.token_count
      lim
  | Auto_compact_triggered -> "auto_compact_triggered"
  | Compact_retry_exhausted -> "compact_retry_exhausted"
  | Operator_compact_requested -> "operator_compact_requested"
  | Operator_clear_requested r ->
    Printf.sprintf
      "operator_clear_requested(preserve_system=%b,reason=%s)"
      r.preserve_system
      r.reason
;;

(* ── Entry Actions ─────────────────────────────────────── *)

(** Runtime contract mirrors [.mli]:
    - [Publish_lifecycle] is executed by the registry as an observability
      side effect.
    - [Start_compaction] is executed by the registry only for the
      [Overflowed] auto-compact path, which emits
      [Auto_compact_triggered] after the transition is committed.
    - The remaining variants describe runtime-owned work and remain
      explicit phase-entry intent until that integration is unified. *)
type entry_action =
  | Start_compaction
  | Start_handoff
  | Start_drain
  | Schedule_restart of { delay_sec : float }
  | Publish_lifecycle of
      { event_name : string
      ; detail : string
      }
  | Mark_dead_tombstone
  | Cleanup_and_unregister

(* ── Transition Types ──────────────────────────────────── *)

type transition_result =
  { prev_phase : phase
  ; new_phase : phase
  ; updated_conditions : conditions
  ; entry_actions : entry_action list
  ; event_applied : event
  ; timestamp : float
  }

type transition_error =
  | Terminal_state of
      { current : phase
      ; attempted_event : string
      }
  | Invalid_transition of
      { from_phase : phase
      ; to_phase : phase
      ; reason : string
      }

let transition_error_to_string = function
  | Terminal_state r ->
    Printf.sprintf
      "terminal_state: %s cannot accept %s"
      (phase_to_string r.current)
      r.attempted_event
  | Invalid_transition r ->
    Printf.sprintf
      "invalid_transition: %s -> %s (%s)"
      (phase_to_string r.from_phase)
      (phase_to_string r.to_phase)
      r.reason
;;

(* ── Transition Matrix ─────────────────────────────────── *)

let can_transition ~from_phase ~to_phase =
  match from_phase, to_phase with
  (* Terminal states accept nothing *)
  | Stopped, _ -> false
  | Dead, _ -> false
  (* Offline -> Running | Stopped | Draining (stop while not yet started) *)
  | Offline, (Running | Stopped | Draining) -> true
  | Offline, _ -> false
  (* Running -> buffer states, Paused, Stopped, Crashed (fiber death),
     Overflowed (prompt exceeded provider budget) *)
  | ( Running
    , ( Failing
      | Overflowed
      | Compacting
      | HandingOff
      | Draining
      | Paused
      | Stopped
      | Crashed ) ) -> true
  | Running, _ -> false
  (* Failing -> Running (recovery) | Crashed (threshold) | Draining (stop)
     | Paused (operator can pause for investigation)
     | Overflowed (context overflow distinct from generic failure) *)
  | Failing, (Running | Overflowed | Crashed | Draining | Paused) -> true
  | Failing, _ -> false
  (* Overflowed -> Running (operator_clear resolves the overflow in-place)
     | Compacting (auto-recovery, the default next step)
     | Paused (compact retry budget exhausted — operator needed)
     | Draining (operator stop) | Crashed (fiber died). *)
  | Overflowed, (Running | Compacting | Paused | Draining | Crashed) -> true
  | Overflowed, _ -> false
  (* Compacting -> Running (done, overflow cleared)
     | Overflowed (Compaction_failed leaves context_overflow=true; the keeper
     re-enters Overflowed so the retry loop can decide next step — if the
     caller has latched [compact_retry_exhausted], derive_phase immediately
     promotes to Paused instead)
     | Failing (hb fail / guardrail during)
     | Crashed (fatal) | Draining (operator stop during). *)
  | Compacting, (Running | Overflowed | Failing | Crashed | Draining) -> true
  | Compacting, _ -> false
  (* HandingOff -> Running (done) | Failing | Crashed
     | Draining (operator stop during handoff) *)
  | HandingOff, (Running | Failing | Crashed | Draining) -> true
  | HandingOff, _ -> false
  (* Draining -> Stopped (done) | Crashed (fatal during drain) *)
  | Draining, (Stopped | Crashed) -> true
  | Draining, _ -> false
  (* Paused -> Running (resume) | Draining (stop) | Stopped (remove)
     | Crashed (fiber can die while keeper is paused)
     | Compacting (operator invoked masc_keeper_compact on paused keeper
     to clear an overflow-induced pause) *)
  | Paused, (Running | Compacting | Draining | Stopped | Crashed) -> true
  | Paused, _ -> false
  (* Crashed -> Restarting (backoff done) | Dead (budget exhausted) *)
  | Crashed, (Restarting | Dead) -> true
  | Crashed, _ -> false
  (* Restarting -> Running (success) | Crashed (fail) | Dead (budget)
     | Draining (stop_requested persists) | Paused (operator_paused persists) *)
  | Restarting, (Running | Crashed | Dead | Draining | Paused) -> true
  | Restarting, _ -> false
;;

let can_execute_turn = function
  | Running | Failing -> true
  | Offline
  | Overflowed
  | Compacting
  | HandingOff
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting
  | Dead -> false
;;

(* ── derive_phase ──────────────────────────────────────── *)

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

  (* 1. Completed stop — drain succeeded AND no buffer ops in flight *)
  if
    c.stop_requested
    && c.drain_complete
    && (not c.compaction_active)
    && not c.handoff_active
  then Stopped (* 2. Pre-start registration. This is the only path into Offline. *)
  else if c.launch_pending && not c.fiber_alive
  then Offline (* 3. Fiber lifecycle — Dead / Restarting / Crashed *)
  else if (not c.fiber_alive) && not c.restart_budget_remaining
  then Dead
  else if (not c.fiber_alive) && c.restart_budget_remaining && c.backoff_elapsed
  then Restarting
  else if (not c.fiber_alive) && c.restart_budget_remaining
  then Crashed (* 4. In-progress stop — still draining *)
  else if c.stop_requested
  then Draining (* 5. Guardrail -> Failing *)
  else if c.guardrail_triggered
  then
    Failing
    (* 6. Operator pause OR auto-compact retry budget exhausted.
     When [compact_retry_exhausted] is latched together with an ongoing
     [context_overflow], the keeper MUST land on [Paused] so that an
     operator has to intervene; otherwise [Overflowed → Compacting]
     would loop indefinitely. *)
  else if c.operator_paused || (c.context_overflow && c.compact_retry_exhausted)
  then Paused (* 7. Buffer states: in-progress operations *)
  else if c.handoff_active
  then HandingOff
  else if c.compaction_active
  then
    Compacting
    (* 7b. Context overflow awaiting auto-compact.
     Transient: [entry_actions_for] emits [Start_compaction] on entry,
     which flips [compaction_active] via [Auto_compact_triggered] and the
     next [derive_phase] returns [Compacting]. If [compaction_active] is
     already set (compaction already started), priority 7 wins and the
     keeper reads as [Compacting], not [Overflowed]. *)
  else if c.context_overflow
  then Overflowed (* 8. Health degradation *)
  else if (not c.heartbeat_healthy) || not c.turn_healthy
  then Failing (* 9. Healthy running *)
  else if c.fiber_alive
  then Running
  (* 10. Initial / unreachable fallback *)
  else Offline
;;

(* ── Condition Updaters ────────────────────────────────── *)

(** Update conditions based on an event. Returns new conditions. *)
let update_conditions (c : conditions) (ev : event) : conditions =
  match ev with
  | Heartbeat_ok -> { c with heartbeat_healthy = true }
  | Heartbeat_failed { consecutive; max_allowed } ->
    (* Any failure makes heartbeat unhealthy. Recovery requires Heartbeat_ok.
       The consecutive count is for audit/logging, not for health determination. *)
    let _ = max_allowed in
    { c with heartbeat_healthy = consecutive = 0 }
  | Turn_succeeded -> { c with turn_healthy = true }
  | Turn_failed { consecutive; max_allowed } ->
    let _ = max_allowed in
    { c with turn_healthy = consecutive = 0 }
  | Context_measured { auto_rules; _ } ->
    { c with
      guardrail_triggered = auto_rules.guardrail_stop
    ; context_handoff_needed = auto_rules.handoff
    }
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
    ; guardrail_triggered = false
    ; drain_complete = false
    ; stop_requested = false
    ; context_overflow = false
    ; compact_retry_exhausted = false
    }
  | Fiber_terminated _ -> { c with fiber_alive = false }
  | Supervisor_restart_attempt _ -> { c with backoff_elapsed = true }
  | Restart_budget_exhausted -> { c with restart_budget_remaining = false }
  | Guardrail_stop _ -> { c with guardrail_triggered = true }
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
    (post-turn lifecycle or supervisor). *)
let entry_actions_for ~prev_phase ~new_phase ~(event : event) : entry_action list =
  let lifecycle name detail = Publish_lifecycle { event_name = name; detail } in
  match prev_phase, new_phase with
  | _, Compacting -> [ Start_compaction; lifecycle "compaction_started" "" ]
  | _, HandingOff -> [ Start_handoff; lifecycle "handoff_started" "" ]
  | _, Draining -> [ Start_drain; lifecycle "draining" "" ]
  | _, Dead -> [ Mark_dead_tombstone; lifecycle "dead" "restart budget exhausted" ]
  | _, Stopped ->
    [ Cleanup_and_unregister
    ; lifecycle
        "stopped"
        (match event with
         | Operator_stop { remove_meta } -> Printf.sprintf "remove_meta=%b" remove_meta
         | _ -> "drain_complete")
    ]
  | Crashed, Restarting -> [ lifecycle "restarting" "backoff elapsed" ]
  | Restarting, Running -> [ lifecycle "restarted" "fiber launched" ]
  (* [Overflowed] entry actions: request a compaction so the registry can
     promote the committed [Overflowed] transition into the follow-up
     [Auto_compact_triggered] event, and publish the transition so
     operators can see "context overflow" distinctly from generic failure. *)
  | _, Overflowed ->
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
         | _ -> event_to_string event)
    ]
  | _, Failing -> [ lifecycle "failing" (event_to_string event) ]
  | Failing, Running -> [ lifecycle "recovered" "failure counters reset" ]
  | _, Paused ->
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
      | _ -> "operator request"
    in
    [ lifecycle "paused" detail ]
  | Paused, Running ->
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
      | _ -> "operator request"
    in
    [ lifecycle "resumed" detail ]
  | _ -> []
;;

(* ── apply_event ───────────────────────────────────────── *)

let apply_event ~current_phase ~conditions ~event ~now =
  (* Terminal states reject all events *)
  match current_phase with
  | Stopped | Dead ->
    Error
      (Terminal_state { current = current_phase; attempted_event = event_to_string event })
  | _ ->
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
           })
;;

(* ── JSON Serialization ────────────────────────────────── *)

let phase_to_json p = `String (phase_to_string p)

let conditions_to_json (c : conditions) =
  `Assoc
    [ "launch_pending", `Bool c.launch_pending
    ; "fiber_alive", `Bool c.fiber_alive
    ; "heartbeat_healthy", `Bool c.heartbeat_healthy
    ; "turn_healthy", `Bool c.turn_healthy
    ; "context_within_budget", `Bool c.context_within_budget
    ; "context_handoff_needed", `Bool c.context_handoff_needed
    ; "compaction_active", `Bool c.compaction_active
    ; "handoff_active", `Bool c.handoff_active
    ; "operator_paused", `Bool c.operator_paused
    ; "stop_requested", `Bool c.stop_requested
    ; "restart_budget_remaining", `Bool c.restart_budget_remaining
    ; "backoff_elapsed", `Bool c.backoff_elapsed
    ; "guardrail_triggered", `Bool c.guardrail_triggered
    ; "drain_complete", `Bool c.drain_complete
    ; "context_overflow", `Bool c.context_overflow
    ; "compact_retry_exhausted", `Bool c.compact_retry_exhausted
    ]
;;

let event_to_json (ev : event) : Yojson.Safe.t =
  let obj typ fields = `Assoc (("type", `String typ) :: fields) in
  match ev with
  | Heartbeat_ok -> obj "heartbeat_ok" []
  | Heartbeat_failed r ->
    obj
      "heartbeat_failed"
      [ "consecutive", `Int r.consecutive; "max_allowed", `Int r.max_allowed ]
  | Turn_succeeded -> obj "turn_succeeded" []
  | Turn_failed r ->
    obj
      "turn_failed"
      [ "consecutive", `Int r.consecutive; "max_allowed", `Int r.max_allowed ]
  | Context_measured r ->
    obj
      "context_measured"
      [ "context_ratio", `Float r.context_ratio
      ; "message_count", `Int r.message_count
      ; "token_count", `Int r.token_count
      ; ( "auto_rules"
        , `Assoc
            [ "reflect", `Bool r.auto_rules.reflect
            ; "plan", `Bool r.auto_rules.plan
            ; "compact", `Bool r.auto_rules.compact
            ; "handoff", `Bool r.auto_rules.handoff
            ; "guardrail_stop", `Bool r.auto_rules.guardrail_stop
            ; "goal_drift", `Float r.auto_rules.goal_drift
            ] )
      ]
  | Compaction_started -> obj "compaction_started" []
  | Compaction_completed r ->
    obj
      "compaction_completed"
      [ "before_tokens", `Int r.before_tokens; "after_tokens", `Int r.after_tokens ]
  | Compaction_failed r -> obj "compaction_failed" [ "reason", `String r.reason ]
  | Handoff_started -> obj "handoff_started" []
  | Handoff_completed r ->
    obj
      "handoff_completed"
      [ "new_trace_id", `String r.new_trace_id; "generation", `Int r.generation ]
  | Handoff_failed r -> obj "handoff_failed" [ "reason", `String r.reason ]
  | Operator_pause -> obj "operator_pause" []
  | Operator_resume -> obj "operator_resume" []
  | Operator_stop r -> obj "operator_stop" [ "remove_meta", `Bool r.remove_meta ]
  | Stop_requested -> obj "stop_requested" []
  | Drain_complete -> obj "drain_complete" []
  | Fiber_started -> obj "fiber_started" []
  | Fiber_terminated r -> obj "fiber_terminated" [ "outcome", `String r.outcome ]
  | Supervisor_restart_attempt r ->
    obj "supervisor_restart_attempt" [ "attempt", `Int r.attempt ]
  | Restart_budget_exhausted -> obj "restart_budget_exhausted" []
  | Guardrail_stop r -> obj "guardrail_stop" [ "reason", `String r.reason ]
  | Context_overflow_detected r ->
    let source =
      match r.source with
      | `Prompt_rejected -> "prompt_rejected"
      | `Oas_signal -> "oas_signal"
    in
    let limit_tokens =
      match r.limit_tokens with
      | Some n -> `Int n
      | None -> `Null
    in
    obj
      "context_overflow_detected"
      [ "source", `String source
      ; "token_count", `Int r.token_count
      ; "limit_tokens", limit_tokens
      ]
  | Auto_compact_triggered -> obj "auto_compact_triggered" []
  | Compact_retry_exhausted -> obj "compact_retry_exhausted" []
  | Operator_compact_requested -> obj "operator_compact_requested" []
  | Operator_clear_requested r ->
    obj
      "operator_clear_requested"
      [ "preserve_system", `Bool r.preserve_system; "reason", `String r.reason ]
;;

let transition_result_to_json (tr : transition_result) =
  `Assoc
    [ "prev_phase", phase_to_json tr.prev_phase
    ; "new_phase", phase_to_json tr.new_phase
    ; "conditions", conditions_to_json tr.updated_conditions
    ; "event", event_to_json tr.event_applied
    ; "timestamp", `Float tr.timestamp
    ]
;;

(* ── Mermaid State Diagram ────────────────────────────── *)

(** Maps a phase to the capitalized state ID used in the Mermaid diagram. *)
let phase_to_mermaid_id = function
  | Offline -> "Offline"
  | Running -> "Running"
  | Failing -> "Failing"
  | Overflowed -> "Overflowed"
  | Compacting -> "Compacting"
  | HandingOff -> "HandingOff"
  | Draining -> "Draining"
  | Paused -> "Paused"
  | Stopped -> "Stopped"
  | Crashed -> "Crashed"
  | Restarting -> "Restarting"
  | Dead -> "Dead"
;;

let phase_to_mermaid ~(current : phase) : string =
  let b = Buffer.create 512 in
  let p fmt = Printf.bprintf b fmt in
  p "stateDiagram-v2\n";
  (* Phase nodes with display names *)
  p "    [*] --> Offline\n";
  p "    Offline --> Running : Fiber_started\n";
  p "    Offline --> Draining : stop requested\n";
  p "    Offline --> Stopped : stop while not started\n";
  p "    Running --> Failing : hb/turn/reconcile fail\n";
  p "    Running --> Overflowed : prompt exceeded max context\n";
  p "    Running --> Compacting : compact start\n";
  p "    Running --> HandingOff : handoff start\n";
  p "    Running --> Draining : stop requested\n";
  p "    Running --> Paused : operator pause\n";
  p "    Running --> Stopped : stop requested\n";
  p "    Running --> Crashed : fiber death\n";
  p "    Failing --> Running : clean turn recovery\n";
  p "    Failing --> Overflowed : prompt exceeded max context\n";
  p "    Failing --> Crashed : fiber death\n";
  p "    Failing --> Draining : stop requested\n";
  p "    Failing --> Paused : operator pause\n";
  p "    Overflowed --> Running : operator clear\n";
  p "    Overflowed --> Compacting : auto-compact\n";
  p "    Overflowed --> Paused : retry exhausted\n";
  p "    Overflowed --> Draining : stop requested\n";
  p "    Overflowed --> Crashed : fiber death\n";
  p "    Compacting --> Running : compact done\n";
  p "    Compacting --> Overflowed : compact failed (overflow persists)\n";
  p "    Compacting --> Failing : hb fail\n";
  p "    Compacting --> Crashed : fiber death\n";
  p "    Compacting --> Draining : stop requested\n";
  p "    HandingOff --> Running : handoff done\n";
  p "    HandingOff --> Failing : hb fail\n";
  p "    HandingOff --> Crashed : fiber death\n";
  p "    HandingOff --> Draining : stop requested\n";
  p "    Draining --> Stopped : drain done\n";
  p "    Draining --> Crashed : fiber death\n";
  p "    Paused --> Running : operator resume\n";
  p "    Paused --> Compacting : operator compact\n";
  p "    Paused --> Draining : stop requested\n";
  p "    Paused --> Stopped : stop requested\n";
  p "    Paused --> Crashed : fiber death\n";
  p "    Crashed --> Restarting : backoff elapsed\n";
  p "    Crashed --> Dead : budget exhausted\n";
  p "    Restarting --> Running : fiber started\n";
  p "    Restarting --> Crashed : launch fail\n";
  p "    Restarting --> Dead : budget exhausted\n";
  p "    Restarting --> Draining : stop requested\n";
  p "    Restarting --> Paused : operator pause\n";
  p "    Stopped --> [*]\n";
  p "    Dead --> [*]\n";
  (* Highlight current phase with classDef *)
  p "\n";
  p "    classDef active fill:#22c55e,stroke:#16a34a,color:#fff,stroke-width:3px\n";
  p "    classDef terminal fill:#6b7280,stroke:#4b5563,color:#fff\n";
  p "    classDef buffer fill:#f59e0b,stroke:#d97706,color:#fff\n";
  (match current with
   | Stopped | Dead -> p "    class %s terminal\n" (phase_to_mermaid_id current)
   | Failing | Overflowed | Compacting | HandingOff | Draining | Restarting ->
     p "    class %s buffer\n" (phase_to_mermaid_id current)
   | _ -> p "    class %s active\n" (phase_to_mermaid_id current));
  Buffer.contents b
;;

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
;;
