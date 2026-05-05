(** Coord_task_classify — State classification, task actor kind, working agents,
    event helpers.

    This module is [include]d by {!Coord_task}; all bindings are part of
    the public Coord interface.  Re-exports {!Coord_utils} and
    {!Coord_state}. *)

include module type of Coord_utils
include module type of Coord_state

(** {1 Task FSM drift observability (#9795)} *)

val drift_variant_label : Coord_task_lifecycle.drift -> string
(** Canonical label string for each [Coord_task_lifecycle.drift]
    variant.  Exhaustive — adding a new drift case forces reviewers
    to update both the match and dashboards that consume the
    [variant] label.  The emit runs through
    {!Coord_hooks.fsm_drift_observer_fn}, wired to
    {!Coord.record_fsm_drift} by [lib/coord.ml].  [masc_coord]
    cannot call Prometheus directly — it sits below that module
    in the library dep graph. *)

(** {1 Task completion path observability (#10449)} *)

val classify_contract_state : Masc_domain.task_contract option -> string
(** Three-way classification of a task's contract surface:
    - ["no_contract"] — [task.contract = None]
    - ["empty_contract"] — contract record present but both
      [completion_contract] and [required_evidence] are empty lists
    - ["with_contract"] — at least one of those lists is non-empty,
      so the verifier-gate redirect in [Tool_task] would fire on a
      [Done_action]

    Used as the [contract_state] label of
    [masc_task_completion_path_total]. *)

val classify_completion_path :
  action:Masc_domain.task_action ->
  drift:Coord_task_lifecycle.drift option ->
  force:bool ->
  string
(** Classify the FSM path that produced a [Done] new_status:
    - ["via_verification"] — [Approve_verification] action (verifier
      redirect path)
    - ["forced_done"] — [force=true] override regardless of drift
    - ["claimed_to_done_skip"] — drift signal from
      {!Coord_task_lifecycle.Claimed_to_done_skip} without force
    - ["in_progress_to_done"] — normal [InProgress → Done] transition

    Used as the [path] label of
    [masc_task_completion_path_total].  Together with
    {!classify_contract_state} this lets operators split the
    bypass-rate documented in issue #10449 by creation-side
    (missing contracts) vs. gate-side (redirect mis-firing). *)

(** {1 Task activity helpers} *)

val update_local_agent_state :
  config -> agent_name:string -> (Masc_domain.agent -> Masc_domain.agent) -> unit
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

val trim_opt : string option -> string option

val working_agents : config -> string list

val resolve_agent_name_strict : config -> string -> string

val normalize_execution_links : Masc_domain.task_execution_links -> Masc_domain.task_execution_links

val normalize_task_contract : Masc_domain.task_contract -> Masc_domain.task_contract

val empty_task_contract : Masc_domain.task_contract

val task_required_tools : Masc_domain.task -> string list

val missing_required_tools : allowed:string list -> string list -> string list

val required_tool_claim_guard :
  config -> agent_name:string -> ?agent_tool_names:string list -> Masc_domain.task ->
  (unit, Masc_domain.masc_error) result

val default_verification_evidence_refs : string list

val first_line : string -> string

val truncate : max_len:int -> string -> string

val default_completion_contract_text : title:string -> description:string -> string

val ensure_task_contract_for_verification :
  ?contract:Masc_domain.task_contract -> title:string -> description:string ->
  unit -> Masc_domain.task_contract

val merge_execution_links :
  Masc_domain.task_execution_links ->
  ?session_id:string -> ?operation_id:string -> ?autoresearch_loop_id:string ->
  unit -> Masc_domain.task_execution_links

val merge_envelope_into_payload :
  ?correlation_id:string -> ?run_id:string -> Yojson.Safe.t -> Yojson.Safe.t

val task_status_to_string : Masc_domain.task_status -> string

val task_assignee_of_status : Masc_domain.task_status -> string option

val valid_next_actions_for_status : Masc_domain.task_status -> Masc_domain.task_action list
(** Issue #7646: actions that [transition_task_r] accepts from the given
    [task_status]. Used to enrich "Invalid transition" error messages so
    LLM keepers see what they SHOULD have called, not just what failed.
    Empty list for terminal states ([Done], [Cancelled]). *)

val next_actions_hint : Masc_domain.task_status -> string
(** Issue #7646: rendered hint string suitable for embedding in error
    messages, e.g. [", valid_next_actions=[claim;cancel]"]. Returns the
    empty string for terminal states. *)

val task_started_at_unix : Masc_domain.task_status -> float

val task_transition_details :
  from_status:Masc_domain.task_status ->
  to_status:Masc_domain.task_status ->
  ?notes:string -> ?reason:string -> ?duration_ms:int ->
  ?forced:bool -> unit -> Yojson.Safe.t

val observe_task_transition :
  config -> agent_name:string -> task_id:string ->
  transition:Masc_domain.task_action -> details:Yojson.Safe.t -> unit

(** {1 Transition event types} *)

type transition_event_type =
  | Task_transition
  | Task_cancelled

val transition_event_type_to_string : transition_event_type -> string

val transition_log_event :
  event_type:transition_event_type ->
  agent_name:string ->
  task_id:string ->
  from_status:Masc_domain.task_status ->
  to_status:Masc_domain.task_status ->
  ?action:string -> ?notes:string -> ?reason:string -> ?duration_ms:int ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  ?forced:bool -> ?now:string -> unit -> Yojson.Safe.t
