(** Coord_task -- Task lifecycle: add, claim, transition, complete, cancel.

    This module is [include]d by {!Coord}; all bindings are part of
    the public Coord interface.  Re-exports {!Coord_utils} and
    {!Coord_state}. *)

include module type of Coord_utils
include module type of Coord_state

(** {1 Task activity helpers} *)

val update_local_agent_state :
  config -> agent_name:string -> (Types.agent -> Types.agent) -> unit
(** Update the on-disk agent state record under its own
    [with_file_lock] on the agent file.  The callback receives the
    current agent record and returns the updated one; the helper
    silently skips writes when the agent file is missing (matching
    the pre-existing best-effort mirror semantics) and logs JSON
    parse failures with the agent name for diagnostic context.

    Callers that hold an outer lock on a different file (e.g. the
    backlog in [Coord_task_schedule.claim_next_r]) must nest this
    call inside the outer lock; lock acquisition order is always
    {b outer path → agent file} across every call site to keep the
    graph acyclic.

    @since PR #6634 — previously inline at six sites in [Coord_task]
    task transitions; exposed here so [Coord_task_schedule] can reuse
    the same discipline for its own agent-state writes. *)

val emit_task_activity :
  ?correlation_id:string -> ?run_id:string ->
  config -> agent_name:string -> task_id:string ->
  kind:string -> payload:Yojson.Safe.t -> unit
(** Optional [correlation_id] / [run_id] are merged into the activity
    payload as additional fields when present, so call sites can opt in
    without breaking existing callers. Backed by
    [merge_envelope_into_payload]. *)

val task_actor_kind : string -> string

val task_status_to_string : Types.task_status -> string

val valid_next_actions_for_status : Types.task_status -> Types.task_action list
(** Issue #7646: actions that [transition_task_r] accepts from the given
    [task_status]. Used to enrich "Invalid transition" error messages so
    LLM keepers see what they SHOULD have called, not just what failed.
    Empty list for terminal states ([Done], [Cancelled]). *)

val next_actions_hint : Types.task_status -> string
(** Issue #7646: rendered hint string suitable for embedding in error
    messages, e.g. [", valid_next_actions=[claim;cancel]"]. Returns the
    empty string for terminal states. *)

val task_started_at_unix : Types.task_status -> float

val task_transition_details :
  from_status:Types.task_status ->
  to_status:Types.task_status ->
  ?notes:string -> ?reason:string -> ?duration_ms:int ->
  ?forced:bool -> unit -> Yojson.Safe.t

val observe_task_transition :
  config -> agent_name:string -> task_id:string ->
  transition:string -> details:Yojson.Safe.t -> unit

(** {1 Task creation} *)

val add_task :
  ?contract:Types.task_contract ->
  ?required_preset:string ->
  config -> title:string -> priority:int -> description:string -> string

val add_task_with_role :
  ?contract:Types.task_contract ->
  config -> title:string -> priority:int -> description:string ->
  required_role:Types_core.role -> string

val batch_add_tasks :
  config -> (string * int * string) list -> string

val batch_add_tasks_with_contracts :
  config -> (string * int * string * Types.task_contract option) list -> string

(** {1 Task claiming} *)

val claim_task :
  config -> agent_name:string -> task_id:string -> string

val claim_task_r :
  config -> agent_name:string -> task_id:string ->
  ?agent_role:Types_core.role -> unit -> string Types.masc_result

(** {1 Task transitions} *)

val transition_task_r :
  config -> agent_name:string -> task_id:string -> action:Types_core.task_action ->
  ?expected_version:int -> ?notes:string -> ?reason:string ->
  ?handoff_context:Types.task_handoff_context ->
  ?force:bool -> unit -> string Types.masc_result

val release_task_r :
  config -> agent_name:string -> task_id:string ->
  ?expected_version:int ->
  ?handoff_context:Types.task_handoff_context -> unit -> string Types.masc_result

val force_release_task_r :
  config -> agent_name:string -> task_id:string ->
  ?handoff_context:Types.task_handoff_context -> unit -> string Types.masc_result

val force_done_task_r :
  config -> agent_name:string -> task_id:string ->
  notes:string -> unit -> string Types.masc_result

(** {1 Task cancellation} *)

val cancel_task_r :
  config -> agent_name:string -> task_id:string ->
  reason:string -> string Types.masc_result

val link_task_execution_artifacts_r :
  config -> task_id:string ->
  ?session_id:string -> ?operation_id:string -> ?autoresearch_loop_id:string ->
  unit -> string Types.masc_result

(** {1 Re-exported type (backward compatibility)} *)

type claim_next_result = Types.claim_next_result =
  | Claim_next_claimed of {
      task_id : string;
      title : string;
      priority : int;
      released_task_id : string option;
      message : string;
    }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of { excluded_count : int; preset_filtered : int }
  | Claim_next_error of string
