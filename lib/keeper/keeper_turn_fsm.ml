(* Keeper-side shim over the pure Turn FSM ([Turn_fsm], library masc_turn).

   The pure state machine — states, reasons, the [classify_transition] matrix,
   labels, TLA symbols — lives in [Turn_fsm] (lib/turn_fsm/), which has zero
   Keeper_* dependencies. This module [include]s it and adds the keeper-coupled
   tail:
     - [guard_transition] / [observe_phase_dwell] / [emit_transition]: telemetry
       / audit / metrics emission (Log.Keeper, Keeper_transition_audit,
       Otel_metric_store + Keeper_metrics, Keeper_fsm_guard_runtime).
     - [require_active_state]: identity guard whose [@@fsm_guard] ppx_tla
       expansion injects [Keeper_fsm_guard_runtime].

   All existing [Keeper_turn_fsm.X] call sites resolve unchanged: pure surface
   via the [include], glue via the local definitions below. Dependency
   direction is Keeper -> Turn. *)

include Turn_fsm

let guard_transition ?ctx ~keeper_name ~turn_id ~from_state ~to_state () =
  match assert_transition_allowed ?ctx ~from_state ~to_state () with
  | Ok _ -> ()
  | Error violation ->
      (* Log first: [wrap_unit] catches the raised exception only to
         bump the Otel_metric_store counter, then re-raises. Anything
         sequenced after [wrap_unit] would never run, so the
         diagnostic warn has to precede it for operators to see
         *which* transition violated. *)
      Log.Keeper.emit
        Log.Warn
        ~keeper_name
        ~turn_id
        ~category:Log.Fsm
        ~details:
          (`Assoc
            [ "from_state", `String violation.from_state
            ; "to_state", `String violation.to_state
            ; "reason", `String violation.reason
            ])
        (Printf.sprintf
           "[fsm:transition:violation] %s -> %s (%s)"
           violation.from_state
           violation.to_state
           violation.reason);
      let stage = violation.from_state ^ "->" ^ violation.to_state in
      (* [Invalid_argument] (not [assert false]) carries an explicit
         message into the re-raise backtrace.  Operators reading a
         crash dump or test failure see the violating transition +
         reason without having to cross-reference the WARN line by
         keeper/turn id.  See [keeper_fsm_guard_runtime.mli] for the
         "any escaping exception is the spec-violation channel"
         contract that lets this be a plain exception rather than
         the typed [Keeper_registry.Runtime_transition_violation]
         (naming the typed exception here would form a module
         dependency cycle). *)
      let detail =
        Printf.sprintf
          "fsm:transition:violation keeper=%s turn=%d from=%s to=%s \
           reason=%s"
          keeper_name turn_id violation.from_state violation.to_state
          violation.reason
      in
      Keeper_fsm_guard_runtime.wrap_unit
        ~action:"KeeperTurnFSM.Next"
        ~stage
        (fun () -> invalid_arg detail)

(* Per-keeper last-transition wallclock, used to record the dwell time
   spent in [prev] state when a transition fires. Kept as an immutable
   [StringMap] under an [Atomic.t] and updated with a CAS loop so
   concurrent Eio fibers do not need a mutex. Stale entries left behind
   by terminal transitions are bounded by keeper count. *)
module StringMap = Set_util.StringMap

let last_transition_at : float StringMap.t Atomic.t = Atomic.make StringMap.empty

let observe_phase_dwell ~keeper_name ~from_label =
  match StringMap.find_opt keeper_name (Atomic.get last_transition_at) with
  | None -> ()
  | Some prev_at ->
    let now = Unix.gettimeofday () in
    let dwell = Float.max 0.0 (now -. prev_at) in
    (* Cancel-aware: bare [try ... with _ -> ()] would swallow (* cancel-guard-ok: prose; the code below routes through Safe_ops.protect *)
       [Eio.Cancel.Cancelled] and break switch teardown. *)
    Safe_ops.protect ~default:() (fun () ->
      Otel_metric_store.observe_histogram
        Keeper_metrics.(to_string TurnPhaseDuration)
        ~labels:[ ("keeper", keeper_name); ("from", from_label) ]
        dwell)

let emit_transition ?ctx ~keeper_name ~turn_id ?prev state =
  let now = Unix.gettimeofday () in
  let prev_label =
    match prev with
    | Some s -> turn_state_label s
    | None -> "-"
  in
  (match prev with
   | Some _ -> observe_phase_dwell ~keeper_name ~from_label:prev_label
   | None -> ());
  Lockfree_atomic.update last_transition_at (fun m ->
    StringMap.add keeper_name now m);
  let classified =
    match prev with
    | Some from_state ->
        classify_transition ?ctx ~from_state ~to_state:state ()
    | None -> None
  in
  (match prev with
   | Some from_state ->
       guard_transition ?ctx ~keeper_name ~turn_id ~from_state ~to_state:state ()
   | None -> ());
  let state_label = turn_state_label state in
  (* [action_label] used to be a single "unknown" marker for two
     distinct cases:
       1. [prev = None] — the first emit for a turn; there is no
          [from_state] to classify against, so "initial" is the
          accurate label.
       2. [prev = Some _] with [classified = None] — the transition
          is *allowed* (otherwise [guard_transition] would have
          raised above) but {!classify_transition} has no arm for the
          (from, to) pair, so the audit trail loses the action.
          This is a *classifier gap* the operator can fix by adding
          an arm; surface it as a separate label + WARN so it is
          discoverable from the same log line as the transition. *)
  let action_label =
    match classified, prev with
    | Some action, _ -> transition_action_label action
    | None, None -> "initial"
    | None, Some _ ->
        Log.Keeper.emit
          Log.Warn
          ~keeper_name
          ~turn_id
          ~category:Log.Fsm
          ~details:
            (`Assoc
              [ "from_state", `String prev_label
              ; "to_state", `String state_label
              ; "action", `String "unclassified"
              ; "reason", `String "classify_transition has no arm for this (from, to) pair"
              ])
          (Printf.sprintf
             "[fsm:transition:unclassified] %s -> %s — classify_transition \
              has no arm for this (from, to) pair; add one in \
              lib/turn_fsm/turn_fsm.ml::classify_transition so the \
              audit trail captures the action"
             prev_label
             state_label);
        "unclassified"
  in
  let stop_signaled_before, stop_signaled_after, stop_label =
    match ctx with
    | Some c ->
      ( Some c.stop_signaled_before
      , Some c.stop_signaled_after
      , Printf.sprintf
          " stop_before=%b stop_after=%b"
          c.stop_signaled_before
          c.stop_signaled_after )
    | None -> None, None, ""
  in
  let transition : Keeper_transition_audit.turn_fsm_transition_record =
    { turn_fsm_turn_id = turn_id
    ; turn_fsm_prev_state = prev_label
    ; turn_fsm_new_state = state_label
    ; turn_fsm_action = action_label
    ; turn_fsm_stop_signaled_before = stop_signaled_before
    ; turn_fsm_stop_signaled_after = stop_signaled_after
    ; turn_fsm_wall_clock_at = now
    }
  in
  (* No log line for an ordinary transition. The record itself is kept: the
     next line writes it to the transition-audit store, and the OTel counter
     below carries the same (from, to, action) for rates. The INFO line was a
     third copy of both, and it spent the operator log on internal
     state-machine vocabulary -- an operator reading
     "streaming -> failed:provider_error action=ProviderError" learns nothing
     the keeper's own failure line does not already say, and a busy keeper
     emits one per transition. Violations and unclassified transitions still
     log above: those are defects, not traffic. *)
  Keeper_transition_audit.record_turn_fsm_transition
    ~keeper_name
    transition;
  Otel_metric_store.inc_counter Keeper_metrics.(to_string TurnFsmTransitions)
    ~labels:
      [ ("from", prev_label);
        ("to", state_label);
        ("action", action_label);
        ("keeper", keeper_name);
      ]
    ()

(* Cycle 12 / Tier I3 smoke test: first real-module use of [@@fsm_guard].

   [require_active_state] is the identity on its argument; the [@@fsm_guard]
   payload is parsed by [ppx_tla] and injected as a runtime [assert] at
   the function body entry. The invariant — turn states that have
   already terminated must not re-enter execution paths — was previously
   only guarded by reviewer-eye inspection of call sites. Stays here (not in
   the pure [Turn_fsm] lib) because the ppx expansion references
   [Keeper_fsm_guard_runtime]. *)
