(** One producer-owned named submission for an original SDK invocation.
    The original source is durable before broker entry. An acceptance response
    may be lost without creating a replacement run or request on replay. *)

type request
type t
type permit

type error =
  | Invalid_request of string
  | Identity_conflict
  | Missing_intent
  | Unreadable_intent of string
  | Corrupt_intent of string
  | Source_conflict
  | Journal_rejected of Keeper_tool_execution_journal.error
  | Submission_in_progress
  | Stale_permit
  | Persistence_failed of string

val error_to_string : error -> string

val request :
  keeper_name:string -> trace_id:Keeper_id.Trace_id.t -> physical_turn_ref:Ids.Turn_ref.t ->
  invocation:Agent_core.Tool_contract.Invocation.t -> source_task_id:string option ->
  skill_reference:Skill_reference.t -> tool_name:string ->
  plan:Keeper_tool_plan.t -> (request, error) result
(** The original physical frame is supplied by the sealed activation recorder;
    SDK coordinates alone do not identify an occurrence across client sessions.
    Invocation coordinates are supplied by the SDK, never model arguments.
    Exact Skill, bound plan and original Task must match on every replay. *)

val prepare :
  base_path:string -> request ->
  make_source:(unit -> (Keeper_tool_execution_journal.t, error) result) ->
  (t, error) result
(** Materialize the first original source once under the owned intent
    transaction. Existing source is strictly loaded and compared; missing or
    corrupt existing evidence never invokes [make_source] as a repair. *)

val load : base_path:string -> request -> (t option, error) result
(** Read only the original producer source. [None] is absence of the intent,
    not proof that no submission effects occurred. Admission is read separately;
    a damaged phase tail cannot hide an intact, canonically accepted source. *)

val source : t -> Keeper_tool_execution_journal.source
val journal : t -> Keeper_tool_execution_journal.t
val accepted : t ->
  (Keeper_composition_dependency.composition option, error) result
(** Read only the canonical first named admission. This can recover acceptance
    even when the caller never received the submission acknowledgement. *)

val unconfirmed_request_id : t -> (string option, error) result
(** Preserve an actual broker request ID when admission remains uncertain.
    This grants no membership, worker or continuation. *)

val begin_submit : t -> (permit, error) result
(** Commit a unique broker-entry permit before any submission effects. A
    competing or interrupted entry cannot issue a replacement permit. *)

val observe_submit_error : permit -> Keeper_msg_async.submit_error ->
  (unit, error) result
(** Only typed pre-acceptance broker failures release the same source for a
    later attempt. Partial acceptance, reconciliation and fork uncertainty keep
    the entry reserved. No string inference, deadline or retry budget. *)

val observe_submit_outcome : permit -> Keeper_msg_async.submit_outcome ->
  (unit, error) result
(** Retain the actual original request ID, including reconciliation outcomes.
    This observation is separate from canonical named admission. *)
