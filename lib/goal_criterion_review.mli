(** Creation-time semantic review, separate from completion proof and human
    confirmation. The complete criterion revision, original prompts and actual
    reviewer observations are durable before they grant any current verdict.
    An uncertain execution is never replayed. Goal -> review-ledger lock order. *)

type original = { prompt : string; system_prompt : string; lookup_binding : string }
type receipt = {
  original : original;
  result : Task.Anti_rationalization.review_result;
  tools : Verification_run_registry.tool_observation list;
}
type phase =
  | Pending of string option
  | Dispatching of original
  | Judged of receipt
  | Reviewed of receipt
  | Deferred of receipt
  | Execution_unknown of { original : original; detail : string;
      tools : Verification_run_registry.tool_observation list }
  | Superseded of receipt
type record = {
  goal_id : string;
  request_id : string;
  criterion : Goal_store.criterion;
  requested_by : string;
  requested_at : string;
  supersedes : string option;
  phase : phase;
}
type error =
  | Store_unavailable of string
  | Goal_unavailable of Goal_store.write_error
  | Conflict of string
val error_to_string : error -> string
val authority : Masc_domain.completion_authority
val path : Workspace_utils.config -> string
val load : Workspace_utils.config -> (record list, error) result
val current_for_goal : record list -> Goal_store.goal -> record option
val current_lookup : record list -> (Goal_store.goal -> record option)
val request : ?expected_criterion:Goal_store.criterion -> ?expected_request_id:string -> Workspace_utils.config -> goal_id:string -> actor:string ->
  retry:bool -> (record, error) result
(** Idempotent for a current criterion. An explicit actor action or typed
    retryable failure may replace a definitely settled non-verdict. Pending, judged and uncertain
    originals cannot be replaced; all earlier requests remain in the ledger.
    A missing request after a creation interruption is reconstructible from
    the authoritative Goal and its criterion revision. *)
val begin_dispatch : Workspace_utils.config -> record -> original -> (record, error) result
(** Revalidate the current Goal and revision before persisting dispatch intent.
    Paused, blocked and terminal Goals admit no new model call. *)
val retain_reply : Workspace_utils.config -> record -> receipt -> (record, error) result
(** Retain the actual structured reply before checking current Goal authority. *)
val publish : Workspace_utils.config -> record -> (record, error) result
(** CAS against the complete current criterion. Stale judgments remain
    [Superseded], never a verdict for the replacement criterion. A current
    reasonless or absent verdict becomes [Deferred], not semantic rejection. *)
val retain_unknown : Workspace_utils.config -> record -> original -> detail:string ->
  tools:Verification_run_registry.tool_observation list -> (unit, error) result
val defer_preparation : Workspace_utils.config -> record -> detail:string -> (unit, error) result
val recover_interrupted : Workspace_utils.config -> (unit, error) result
(** Called once by a newly installed application lane, before it starts any
    workers. A prior process's retained dispatch intent has no live owner in
    this lane: preserve it as execution-unknown and never replay it. *)
val projection : (record list, error) result -> Goal_store.goal -> Yojson.Safe.t
val projector : (record list, error) result -> (Goal_store.goal -> Yojson.Safe.t)
(** A strict unavailable marker, unchecked, or the exact current revision's
    review. Does not read stores, dispatch a reviewer or assert completion. *)
val summary_projector : (record list, error) result -> (Goal_store.goal -> Yojson.Safe.t)
(** {!projector} without the reviewer's evidence, the [review] result and the
    [tools] it called. The state, request id, revision, reason, detail and
    authority stay. For a list of many goals, where the evidence is most of the
    bytes. *)
