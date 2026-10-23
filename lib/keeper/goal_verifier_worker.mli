(** One actual retained Goal review attempt. Uses the shared original/progress
    store and the existing tool-capable reviewer. No Goal/Task transition,
    human confirmation, new attempt allocation or replacement is performed.
    The serialized host owner selects the original attempt and owns any
    explicit linked-successor decision after a definite terminal refusal. *)

type run_identity = { run_id : string; started_at : float }
type receipt = {
  run : run_identity;
  result : Task.Anti_rationalization.review_result;
  tools : Verification_run_registry.tool_observation list;
  elapsed_s : float;
}

type error =
  | Store_unavailable of string
  | Original_invalid of string
  | Authority_changed of string
  | Execution_pending of string

type retained

val retain :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  run:run_identity -> Goal_verifier_original.t -> (retained, error) result
(** Retain the complete original before dispatch. The fixed run identity is
    part of the owner summary; changing it cannot reset an existing attempt.
    A wake must first restore its original instead of inventing another run. *)

val load :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  goal_id:string -> request_id:string -> attempt:int ->
  (retained option, error) result
val inventory :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  (retained list, error) result
(** Strict actual scope discovery. A malformed, missing or changed published
    original rejects the inventory; partial results are not a complete list.
    Neither function creates an original, authorizes dispatch or picks a retry. *)

val original : retained -> Goal_verifier_original.t
val run_identity : retained -> run_identity
val progress : retained -> Lane_addon_request_progress.t
val restored_receipt : retained -> (receipt option, error) result
(** A retained judgment/terminal refusal and all actual tool observations, independent
    of today's lookup availability. Captured/admission/pending returns None. *)

val run :
  ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  ?sw:Eio.Switch.t option ->
  store:Lane_addon_store.t -> retained:retained ->
  authority:Verification_authority_tools.goal_review ->
  provider_rest:(string -> Task.Anti_rationalization.provider_rest) ->
  unit -> (receipt, error) result
(** Restore exact prior judgments first. Otherwise confirm original authority
    and persist dispatch intent before using the actual retained reviewer.
    Unknown dispatch/cancellation never redispatches; a proven pre-admission
    refusal may reuse the same original. Persist the structured reply and full
    tool observations atomically before returning control to the Goal host.
    Host proof commitment and run-registry publication remain separate. *)
