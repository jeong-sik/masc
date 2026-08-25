(** Lifecycle types, transition guards, and pure helpers for the Agent module.

    Extracted from agent.ml to reduce file size.  No dependency on
    [Agent.t] — all functions take explicit parameters.

    {2 Transition Guards}

    The [transition] function enforces a valid state machine:
    - [Accepted] -> [Ready | Failed]
    - [Ready]    -> [Running | Failed]
    - [Running]  -> [Ready | Completed | Failed]
    - [Completed] and [Failed] are terminal (no outgoing transitions).
    - Same-state transitions on non-terminal states are allowed (reaffirm).
    [Running -> Ready] supports multi-turn agent loops where each turn
    cycles through [Ready -> Running -> Ready -> ...] before terminating.

    @stability Evolving
    @since 0.93.1
    @since 0.105.0 transition guards *)

(** {1 Lifecycle status} *)

type lifecycle_status =
  | Accepted
  | Ready
  | Running
  | Completed
  | Failed
[@@deriving show, yojson]

(** {1 Transition guards} *)

type transition_error =
  | InvalidTransition of
      { from_status : lifecycle_status
      ; to_status : lifecycle_status
      }
  | AlreadyTerminal of { status : lifecycle_status }

(** [is_terminal status] returns [true] for [Completed] and [Failed]. *)
val is_terminal : lifecycle_status -> bool

(** [valid_transitions status] returns the list of statuses reachable
    from [status]. Terminal states return the empty list. *)
val valid_transitions : lifecycle_status -> lifecycle_status list

(** [transition ~from ~to_] validates a state transition.
    Returns [Ok to_] on success, [Error _] on invalid transition.
    Same-state transitions on non-terminal states return [Ok] (reaffirm). *)
val transition
  :  from:lifecycle_status
  -> to_:lifecycle_status
  -> (lifecycle_status, transition_error) result

(** Human-readable description of a transition error. *)
val transition_error_to_string : transition_error -> string

(** {1 Snapshot} *)

(** Snapshot of an agent's lifecycle at a given moment. *)
type lifecycle_snapshot =
  { current_run_id : string option
  ; agent_name : string
  ; worker_id : string option
  ; runtime_actor : string option
  ; status : lifecycle_status
  ; requested_provider : string option
  ; requested_model : string option
  ; resolved_provider : string option
  ; resolved_model : string option
  ; last_error : string option
  ; accepted_at : float option
  ; ready_at : float option
  ; first_progress_at : float option
  ; started_at : float option
  ; last_progress_at : float option
  ; finished_at : float option
  }
[@@deriving yojson]

(** {1 Construction} *)

(** String representation of a hook decision for tracing. *)
val hook_decision_to_string : Hooks.hook_decision -> string

(** Build a new lifecycle snapshot, optionally merging with [previous].
    Pure function — the caller handles mutation on [Agent.t]. *)
val build_snapshot
  :  agent_name:string
  -> model:Types.model
  -> ?provider_config:Llm_provider.Provider_config.t
  -> ?previous:lifecycle_snapshot
  -> ?current_run_id:string
  -> ?worker_id:string
  -> ?runtime_actor:string
  -> ?last_error:string
  -> ?accepted_at:float
  -> ?ready_at:float
  -> ?first_progress_at:float
  -> ?started_at:float
  -> ?last_progress_at:float
  -> ?finished_at:float
  -> lifecycle_status
  -> lifecycle_snapshot
