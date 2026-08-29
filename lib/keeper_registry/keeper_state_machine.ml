(** Keeper State Machine — Deterministic Core (RFC-0002).
    See .mli for documentation. *)

(* ── Phase ─────────────────────────────────────────────── *)

(* Types, transition matrix, and predicates extracted to
   [Keeper_state_machine_types] (godfile decomp). *)
include Keeper_state_machine_types

(** [is_terminal phase] is true iff [phase] cannot accept new turns.

    Stopped is terminal: in [can_transition] every outgoing edge from that
    source is denied. Centralized here so the FSM, health surfaces, and the
    mermaid renderer share one source of truth instead of re-matching the
    terminal phase at each consumer.
    Exhaustive (no [_] wildcard) so adding a phase variant surfaces a
    compile-time warning here. *)
let is_terminal = function
  | Stopped -> true
  | Offline
  | Running
  | Failing
  | Draining
  | Paused
  | Crashed
  | Restarting -> false


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

     *)

  (* 1. Completed stop — drain succeeded *)
  if c.stop_requested && c.drain_complete
  then Stopped (* 2. Pre-start registration. This is the only path into Offline. *)
  else if c.launch_pending && not c.fiber_alive
  then Offline (* 3. Fiber lifecycle — Restarting / Crashed *)
  else if (not c.fiber_alive) && c.restart_requested
  then Restarting
  else if not c.fiber_alive
  then Crashed (* 5. In-progress stop — still draining *)
  else if c.stop_requested
  then Draining
    (* 6. Only an explicit operator action pauses a Keeper. Recovery
       observations and retry counts never synthesize operator authority. *)
  else if c.operator_paused
  then Paused
  else if
    (not c.heartbeat_healthy)
    || (not c.turn_healthy)
    || c.credential_archived
  then Failing (* 10. Healthy running *)
  (* [fiber_alive] is guaranteed here: branch 3 routes a dead fiber to
     Crashed, so the fallthrough can only be Running. *)
  else Running
;;

(* ── Condition Updaters ────────────────────────────────── *)

(** Update conditions based on an event. Returns new conditions. *)
let update_conditions (c : conditions) (ev : event) : conditions =
  match ev with
  | Heartbeat_ok -> { c with heartbeat_healthy = true }
  | Heartbeat_failed _ ->
    (* Any failure makes heartbeat unhealthy. Recovery requires Heartbeat_ok.
       The [consecutive] payload is an observation, not an authorization
       threshold — mirrors TLA+ HeartbeatFailed which sets
       [heartbeat_healthy' = FALSE] unconditionally
       (specs/keeper-state-machine/KeeperStateMachine.tla §HeartbeatFailed). *)
    { c with heartbeat_healthy = false }
  | Turn_succeeded -> { c with turn_healthy = true }
  | Turn_failed _ ->
    (* Mirrors TLA+ TurnFailed: [turn_healthy' = FALSE] unconditional.
       Same observational payload semantics as Heartbeat_failed. *)
    { c with turn_healthy = false }
  | Context_measured { context_actions; _ } ->
    { c with context_handoff_needed = context_actions.handoff }
  | Operator_pause -> { c with operator_paused = true }
  | Operator_resume -> { c with operator_paused = false }
  | Operator_stop _ -> { c with stop_requested = true }
  | Stop_requested -> { c with stop_requested = true }
  | Drain_complete -> { c with drain_complete = true }
  | Fiber_started ->
    (* A new fiber = a new life. Reset health, buffer, backoff, and stop conditions.
       Previous heartbeat/turn failures, context-handoff recommendations,
       and supervisor backoff state are all irrelevant to the new fiber.

       TLA+ model checking found that preserving stop_requested across fiber
       restart causes a liveness violation: the new fiber enters Draining
       immediately and can never complete drain, creating an infinite loop.
       Restart = "bring this keeper back" which contradicts "stop this keeper."
       Therefore stop_requested is reset on fiber start.

       operator_paused IS preserved — pause is an operator investigation tool
       that should survive restarts. *)
    { c with
      launch_pending = false
    ; fiber_alive = true
    ; heartbeat_healthy = true
    ; turn_healthy = true
    ; restart_requested = false
    ; drain_complete = false
    ; stop_requested = false
    }
  | Fiber_terminated _ -> { c with fiber_alive = false }
  | Supervisor_restart_attempt _ -> { c with restart_requested = true }
  | Credential_archived ->
    { c with
      fiber_alive = false
    ; credential_archived = true
    }
  | Operator_clear_requested _ ->
    (* Last resort: context fully dropped by [masc_keeper_clear]. The
       context payload change is owned by the clear runtime; no lifecycle
       condition changes. *)
    c
;;

(** Compute entry actions for a phase transition.
    [Publish_lifecycle] is consumed by the registry runtime; the remaining
    variants describe work whose effects are owned by their runtime boundary.

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
  | Draining -> [ Start_drain; lifecycle "draining" "" ]
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
         | Operator_pause
         | Operator_resume
         | Stop_requested
         | Fiber_started
         | Fiber_terminated _
         | Supervisor_restart_attempt _
         | Credential_archived
         | Operator_clear_requested _ -> event_to_string event)
    ]
  | Failing -> [ lifecycle "failing" (event_to_string event) ]
  | Paused ->
    let detail =
      match event with
      | Operator_pause -> "operator request"
      | Heartbeat_ok
      | Heartbeat_failed _
      | Turn_succeeded
      | Turn_failed _
      | Context_measured _
      | Operator_resume
      | Operator_stop _
      | Stop_requested
      | Drain_complete
      | Fiber_started
      | Fiber_terminated _
      | Supervisor_restart_attempt _
      | Credential_archived
      | Operator_clear_requested _ ->
        (* These events should not normally trigger a Paused transition,
           but if they do, label generically rather than mis-attributing
           to "operator request". *)
        event_to_string event
    in
    [ lifecycle "paused" detail ]
  | Restarting ->
    (match prev_phase with
     | Crashed -> [ lifecycle "restarting" "supervisor restart requested" ]
     | Offline
     | Running
     | Failing
     | Draining
     | Paused
     | Stopped
     | Restarting ->
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
       let detail =
         match event with
         | Operator_resume -> "operator request"
         | Fiber_terminated _ -> "fiber recovered"
         | Heartbeat_ok
         | Heartbeat_failed _
         | Turn_succeeded
         | Turn_failed _
         | Context_measured _
         | Operator_stop _
         | Operator_pause
         | Stop_requested
         | Drain_complete
         | Fiber_started
         | Supervisor_restart_attempt _
         | Credential_archived
         | Operator_clear_requested _ ->
           (* These events should not normally trigger a Paused→Running
              transition; label generically via [event_to_string]. *)
           event_to_string event
       in
       [ lifecycle "resumed" detail ]
     | Offline
     | Running
     | Draining
     | Stopped
     | Crashed ->
       (* [register] takes Init → Running without traversing this function
          (it uses [register_with_state] directly). For other prevs the
          registry runtime publishes its own lifecycle event covering the
          recovery semantics. Intentional
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

   This helper enforces structural buffer-operation preconditions at the
   [apply_event] boundary so silent corruption becomes a typed
   [Precondition_violation] result.  Operator_clear_requested is
   deliberately *not* arm-enforced beyond the terminal guard — see its arm
   below for the operator escape-hatch rationale.
   Other events have no spec preconditions beyond NotTerminal and are
   listed explicitly in the final arm.

   Background:
     - iter 9 audit memo: docs/tla-audit/ksm-precondition-enforcement-gap-2026-05-12.md
     - iter 9 PR #14730 (systematic gap class) *)
let check_event_precondition (c : conditions) (ev : event)
  : (unit, transition_error) result
  =
  (* [reason] strings are short stable tags ("context_overflow=false" etc).
     They flow into [transition_error_to_string] log lines and the
     [Attribution.policy_failed.reason] telemetry field — keeping them
     low-cardinality lets operators aggregate / alert on the exact
     precondition that failed, while the long explanatory text stays
     in source comments above each branch. *)
  match ev with
  | Operator_clear_requested _ ->
    (* TLA+ §OperatorClearRequested deliberately requires only NotTerminal
       (lib §masc_keeper_clear: "Last-resort: operator drops the keeper's
       context entirely").  The terminal guard at the top of [apply_event]
       already enforces this, so no extra arm is needed here.  Documented
       to make the deliberate minimal precondition explicit — adding any
       check beyond NotTerminal would weaken the operator escape-hatch. *)
    Ok ()
  (* The remaining events have no TLA+ state preconditions beyond what
     [apply_event]'s terminal guard already enforces; their semantics
     are encoded in [update_conditions] + [derive_phase] (e.g.
     [Heartbeat_failed] always flips [heartbeat_healthy] to false
     regardless of prior state).  Adding speculative checks here would
     drift from the spec.

     They are listed rather than caught by [| _ ->] so that adding an
     event forces this decision to be made once, in this arm, instead of
     inheriting Ok () silently.  Listing is not a check: the answer for
     every event below is still "no precondition". *)
  | Heartbeat_ok
  | Heartbeat_failed _
  | Turn_succeeded
  | Turn_failed _
  | Context_measured _
  | Operator_pause
  | Operator_resume
  | Operator_stop _
  | Stop_requested
  | Drain_complete
  | Fiber_started
  | Fiber_terminated _
  | Supervisor_restart_attempt _
  | Credential_archived -> Ok ()
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
  | Stopped ->
    Error
      (Terminal_state { current = current_phase; attempted_event = event_to_string event })
  | Offline
  | Running
  | Failing
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
        ; "precondition_reason", `String reason
        ]
    in
    Attribution.policy_failed ~origin:Det ~gate:"keeper_fsm" ~evidence ~reason
;;
