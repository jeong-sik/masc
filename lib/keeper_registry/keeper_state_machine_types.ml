(* Keeper_state_machine_types — phase, conditions, event, entry_action,
   transition types, can_transition matrix, and can_execute_turn.
   Extracted from keeper_state_machine.ml during godfile decomposition. *)

type phase = Keeper_state_machine_phase.phase =
  | Offline
  | Running
  | Failing
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting

let phase_to_string = Keeper_state_machine_phase.phase_to_string
let phase_of_string = Keeper_state_machine_phase.phase_of_string
let all_phases = Keeper_state_machine_phase.all_phases

(* ── Conditions ────────────────────────────────────────── *)

type conditions =
  { launch_pending : bool
  ; fiber_alive : bool
  ; heartbeat_healthy : bool
  ; turn_healthy : bool
  ; context_handoff_needed : bool
  ; operator_paused : bool
  ; stop_requested : bool
  ; restart_requested : bool
  ; drain_complete : bool
  ; credential_archived : bool
  }

let default_conditions =
  { launch_pending = false
  ; fiber_alive = false
  ; heartbeat_healthy = true
  ; turn_healthy = true
  ; context_handoff_needed = false
  ; operator_paused = false
  ; stop_requested = false
  ; restart_requested = false
  ; drain_complete = false
  ; credential_archived = false
  }
;;

(* ── Events ────────────────────────────────────────────── *)

type context_actions = { handoff : bool }

type event =
  | Heartbeat_ok
  | Heartbeat_failed of
      { consecutive : int }
  | Turn_succeeded
  | Turn_failed of
      { consecutive : int }
  | Context_measured of
      { context_ratio : float
      ; message_count : int
      ; token_count : int
      ; context_actions : context_actions
      }
  | Operator_pause
  | Operator_resume
  | Operator_stop of { remove_meta : bool }
  | Stop_requested
  | Drain_complete
  | Fiber_started
  | Fiber_terminated of
      { outcome : string
      ; provider_id : string option
      ; http_status : int option
      }
  | Supervisor_restart_attempt of { attempt : int }
  | Credential_archived
  | Operator_clear_requested of
      { preserve_system : bool
      ; reason : string
      }

let event_to_string = function
  | Heartbeat_ok -> "heartbeat_ok"
  | Heartbeat_failed r -> Printf.sprintf "heartbeat_failed(%d)" r.consecutive
  | Turn_succeeded -> "turn_succeeded"
  | Turn_failed r -> Printf.sprintf "turn_failed(%d)" r.consecutive
  | Context_measured r -> Printf.sprintf "context_measured(ratio=%.3f)" r.context_ratio
  | Operator_pause -> "operator_pause"
  | Operator_resume -> "operator_resume"
  | Operator_stop r -> Printf.sprintf "operator_stop(remove_meta=%b)" r.remove_meta
  | Stop_requested -> "stop_requested"
  | Drain_complete -> "drain_complete"
  | Fiber_started -> "fiber_started"
  | Fiber_terminated { outcome; provider_id = None; http_status = None } ->
    Printf.sprintf "fiber_terminated(%s)" outcome
  | Fiber_terminated { outcome; provider_id; http_status } ->
    let prov =
      Option.fold provider_id ~none:""
        ~some:(Printf.sprintf " provider=%s")
    in
    let http =
      Option.fold http_status ~none:""
        ~some:(Printf.sprintf " http=%d")
    in
    Printf.sprintf "fiber_terminated(%s%s%s)" outcome prov http
  | Supervisor_restart_attempt r ->
    Printf.sprintf "supervisor_restart_attempt(%d)" r.attempt
  | Credential_archived -> "credential_archived"
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
    - The remaining variants describe runtime-owned work and remain
      explicit phase-entry intent until that integration is unified. *)
type entry_action =
  | Start_drain
  | Schedule_restart of { delay_sec : float }
  | Publish_lifecycle of
      { event_name : string
      ; detail : string
      }
  | Cleanup_and_unregister
  | Trigger_immediate_cleanup
  | Cancel_pending_agent_core

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
  | Precondition_violation of
      { event : string
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
  | Precondition_violation r ->
    Printf.sprintf "precondition_violation: %s — %s" r.event r.reason
;;

(* ── Transition Matrix ─────────────────────────────────── *)

(* Anti-pattern fix (software-development.md §"FSM Sparse Match"): replaces
   per-from [| <from>, _ -> false] wildcards on the 10 non-terminal source
   phases with explicit deny-lists. Adding a new variant to [phase] now
   surfaces 10 compile errors (one per source group) instead of silently
   routing through every wildcard as [false]. Mirrors the
   compiler-checked-exhaustive pattern already established in
   [can_execute_turn] below.

   The terminal source phase [Stopped] keeps [_ -> false] because the semantic
   IS "any phase, including future ones, is unreachable from a terminal
   state" — the wildcard correctly captures the universal denial. *)
let can_transition ~from_phase ~to_phase =
  match from_phase, to_phase with
  (* Terminal states accept nothing *)
  | Stopped, _ -> false
  (* Offline -> Running | Stopped | Draining (stop while not yet started) *)
  | Offline, (Running | Stopped | Draining) -> true
  | ( Offline
    , ( Offline
      | Failing
      | Paused
      | Crashed
      | Restarting ) ) -> false
  (* Running -> buffer states, Paused, Stopped, Crashed (fiber death). *)
  | ( Running
    , ( Failing
      | Draining
      | Paused
      | Stopped
      | Crashed ) ) -> true
  | Running, (Offline | Running | Restarting) -> false
  (* Failing -> Running (recovery) | Crashed (threshold) | Draining (stop)
     | Paused (operator can pause for investigation). *)
  | Failing, (Running | Crashed | Draining | Paused) -> true
  | ( Failing
    , (Offline | Failing | Stopped | Restarting) ) ->
    false
  (* Draining -> Stopped (done) | Crashed (fatal during drain) *)
  | Draining, (Stopped | Crashed) -> true
  | ( Draining
    , ( Offline
      | Running
      | Failing
      | Draining
      | Paused
      | Restarting ) ) -> false
  (* Paused -> Running (resume) | latent states exposed by resume
     (Failing/Restarting/Offline) | Draining (stop)
     | Stopped (remove) | Crashed (fiber can die while keeper is paused).

     Operator_resume only clears [operator_paused]; it intentionally does not
     erase already-observed launch, health, or restart conditions.
     If one of those latches still derives a non-running phase, accepting the
     transition lets the registry commit the resume intent and surface the real
     blocker instead of rejecting the event and leaving the keeper permanently
     paused. *)
  | ( Paused
    , ( Running
      | Failing
      | Draining
      | Stopped
      | Crashed
      | Offline
      | Restarting ) ) -> true
  | Paused, Paused -> false
  (* Crashed -> Restarting (backoff done). *)
  | Crashed, Restarting -> true
  | ( Crashed
    , ( Offline
      | Running
      | Failing
      | Draining
      | Paused
      | Stopped
      | Crashed ) ) -> false
  (* Restarting -> Running (success) | Crashed (fail)
     | Draining (stop_requested persists) | Paused (operator_paused persists) *)
  | Restarting, (Running | Crashed | Draining | Paused) -> true
  | ( Restarting
    , (Offline | Failing | Stopped | Restarting) )
    -> false
;;

let can_execute_turn = function
  | Running | Failing -> true
  | Offline
  | Draining
  | Paused
  | Stopped
  | Crashed
  | Restarting -> false
;;
