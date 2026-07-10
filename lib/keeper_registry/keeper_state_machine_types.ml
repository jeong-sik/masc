(* Keeper_state_machine_types — phase, conditions, event, entry_action,
   transition types, can_transition matrix, and can_execute_turn.
   Extracted from keeper_state_machine.ml during godfile decomposition. *)

type phase = Keeper_state_machine_phase.phase =
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
  | Zombie

let phase_to_string = Keeper_state_machine_phase.phase_to_string
let phase_of_string = Keeper_state_machine_phase.phase_of_string
let all_phases = Keeper_state_machine_phase.all_phases

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
  ; drain_complete : bool
  ; context_overflow : bool
  ; compact_retry_exhausted : bool
  ; terminal_failure_latched : bool
  ; credential_archived : bool
  ; zombie_timeout_reached : bool
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
  ; drain_complete = false
  ; context_overflow = false
  ; compact_retry_exhausted = false
  ; terminal_failure_latched = false
  ; credential_archived = false
  ; zombie_timeout_reached = false
  }
;;

(* ── Events ────────────────────────────────────────────── *)

type context_actions =
  { compact : bool
  ; handoff : bool
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
      ; context_actions : context_actions
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
  | Fiber_terminated of
      { outcome : string
      ; provider_id : string option
      ; http_status : int option
      }
  | Supervisor_restart_attempt of { attempt : int }
  | Restart_budget_exhausted
  | Credential_archived
  | Zombie_timeout
  | Terminal_failure_detected of { reason : string }
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
  | Restart_budget_exhausted -> "restart_budget_exhausted"
  | Credential_archived -> "credential_archived"
  | Zombie_timeout -> "zombie_timeout"
  | Terminal_failure_detected r -> Printf.sprintf "terminal_failure_detected(%s)" r.reason
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
  | Mark_zombie_tombstone
  | Cleanup_and_unregister
  | Trigger_immediate_cleanup
  | Cancel_pending_oas

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

   Terminal source phases (Stopped/Dead/Zombie) keep [_ -> false] because
   the semantic IS "any phase, including future ones, is unreachable from a
   terminal state" — the wildcard correctly captures the universal denial.
   The universal arms [_, Zombie -> true] and [_, Dead -> true] are kept
   for the same reason: terminal failure / external hard-stop can strike
   any non-terminal phase, including future additions to the variant. *)
let can_transition ~from_phase ~to_phase =
  match from_phase, to_phase with
  (* Terminal states accept nothing *)
  | Stopped, _ -> false
  | Dead, _ -> false
  | Zombie, _ -> false
  (* Terminal failure can strike from any non-terminal phase *)
  | _, Zombie -> true
  (* External hard-stop signals such as credential archival can terminate any
     non-terminal keeper without going through crash/restart budget flow. *)
  | _, Dead -> true
  (* Offline -> Running | Stopped | Draining (stop while not yet started) *)
  | Offline, (Running | Stopped | Draining) -> true
  | ( Offline
    , ( Offline
      | Failing
      | Overflowed
      | Compacting
      | HandingOff
      | Paused
      | Crashed
      | Restarting ) ) -> false
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
  | Running, (Offline | Running | Restarting) -> false
  (* Failing -> Running (recovery) | Crashed (threshold) | Draining (stop)
     | Paused (operator can pause for investigation)
     | Overflowed (context overflow distinct from generic failure)
     | Compacting (post-turn compaction can run while the keeper remains in
     the health-failing lane; completion returns to Failing if the health latch
     is still set). *)
  | Failing, (Running | Overflowed | Compacting | Crashed | Draining | Paused) -> true
  | ( Failing
    , (Offline | Failing | HandingOff | Stopped | Restarting) ) ->
    false
  (* Overflowed -> Running (operator_clear resolves the overflow in-place)
     | Compacting (auto-recovery, the default next step)
     | Paused (compact retry budget exhausted — operator needed)
     | Draining (operator stop) | Crashed (fiber died). *)
  | Overflowed, (Running | Compacting | Paused | Draining | Crashed) -> true
  | ( Overflowed
    , (Offline | Failing | Overflowed | HandingOff | Stopped | Restarting) ) ->
    false
  (* Compacting -> Running (done, overflow cleared)
     | Overflowed (Compaction_failed leaves context_overflow=true; the keeper
     re-enters Overflowed so the retry loop can decide next step — if the
     caller has latched [compact_retry_exhausted], derive_phase immediately
     promotes to Paused instead)
     | Paused (operator pause during compaction)
     | Failing (hb fail / guardrail during)
     | Crashed (fatal) | Draining (operator stop during). *)
  | Compacting, (Running | Overflowed | Failing | Crashed | Draining | Paused) -> true
  | Compacting, (Offline | Compacting | HandingOff | Stopped | Restarting) -> false
  (* HandingOff -> Running (done) | Failing | Crashed
     | Draining (operator stop during handoff)
     | Paused (operator pause during handoff) *)
  | HandingOff, (Running | Failing | Crashed | Draining | Paused) -> true
  | ( HandingOff
    , (Offline | Overflowed | Compacting | HandingOff | Stopped | Restarting) )
    -> false
  (* Draining -> Stopped (done) | Crashed (fatal during drain) *)
  | Draining, (Stopped | Crashed) -> true
  | ( Draining
    , ( Offline
      | Running
      | Failing
      | Overflowed
      | Compacting
      | HandingOff
      | Draining
      | Paused
      | Restarting ) ) -> false
  (* Paused -> Running (resume) | latent states exposed by resume
     (Failing/Overflowed/HandingOff/Restarting/Offline) | Draining (stop)
     | Stopped (remove) | Crashed (fiber can die while keeper is paused)
     | Compacting (operator invoked masc_keeper_compact on paused keeper
     to clear an overflow-induced pause).

     Operator_resume only clears [operator_paused]; it intentionally does not
     erase already-observed launch, health, overflow, handoff, or restart conditions.
     If one of those latches still derives a non-running phase, accepting the
     transition lets the registry commit the resume intent and surface the real
     blocker instead of rejecting the event and leaving the keeper permanently
     paused. *)
  | ( Paused
    , ( Running
      | Failing
      | Overflowed
      | Compacting
      | HandingOff
      | Draining
      | Stopped
      | Crashed
      | Offline
      | Restarting ) ) -> true
  | Paused, Paused -> false
  (* Crashed -> Restarting (backoff done). Dead is covered by the global
     hard-stop/budget terminal transition above. *)
  | Crashed, Restarting -> true
  | ( Crashed
    , ( Offline
      | Running
      | Failing
      | Overflowed
      | Compacting
      | HandingOff
      | Draining
      | Paused
      | Stopped
      | Crashed ) ) -> false
  (* Restarting -> Running (success) | Crashed (fail)
     | Draining (stop_requested persists) | Paused (operator_paused persists) *)
  | Restarting, (Running | Crashed | Draining | Paused) -> true
  | ( Restarting
    , (Offline | Failing | Overflowed | Compacting | HandingOff | Stopped | Restarting) )
    -> false
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
  | Dead
  | Zombie -> false
;;
