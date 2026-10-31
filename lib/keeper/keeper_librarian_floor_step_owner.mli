(** Submit-once host owner for the original requests of the durable message
    floor. A step runs through the same journal as a completed-history request
    and ends at its answer: the answer stays the judgment of a [Judged] record,
    because the Memory commit belongs to the whole chain, not to one step.
    Caller holds the workspace process lease and serializes this Keeper owner. *)
type error = Lane_addon_submit_once.error =
  | Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string
type wait = Lane_addon_submit_once.wait =
  | Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type call = expected:Keeper_librarian_durable_request.destination ->
  original:Lane_addon_tool_request_owner.retained -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_submit_once.call_error) result
(** Actual Runtime call edge must recheck the original semantic destination and
    physical owner immediately before RPC. Only failures before RPC are Not_sent. *)
type answer = {
  raw : Yojson.Safe.t;
      (** The model's answer as the host retained it. The absorb gate's journal
          is prepared from these bytes. *)
  proposal : Keeper_librarian_runtime.durable_step_proposal;
}
type outcome =
  | Pending of wait * Lane_addon_tool_request_owner.retained
  | Answered of answer * Lane_addon_tool_request_owner.retained
  | Refused of Lane_addon_exact.final * Lane_addon_tool_request_owner.retained
(** [Pending] covers a host terminal [Outcome_unknown] as {!Keeper_librarian_durable_owner}
    does: it is never a refusal and never permits another submission. [Refused]
    holds a terminal host refusal whose final the host's records confirm. *)
val retain : store:Lane_addon_store.t -> Keeper_librarian_floor_step_request.t ->
  (Lane_addon_tool_request_owner.retained, error) result
(** Persist the full step before any dispatch, retaining its existing journal.
    The caller must retain new work under Runtime's fresh configured-destination
    serializer. A write failure never proves absence or permits another ID. *)
val discover : store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
  ((Lane_addon_tool_request_owner.retained * Keeper_librarian_floor_step_request.header) list, error) result
(** Strictly read every record of the owner's step scope, with the header of
    each. Any malformed record refuses the inventory. Steps of every chain of the
    owner are listed, in scope order; the chain's own check picks its steps. *)
val resume : store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  original:Lane_addon_tool_request_owner.retained -> step:Keeper_librarian_floor_step_request.t ->
  call:call -> (outcome, error) result
(** Run the step by the shared submit-once rules: a retained answer or refusal
    needs no live worker, a pending request is never submitted again, and only
    a pre-send failure or an explicit capacity reply permits another
    submission. The host's retained terminal and latest execution proof precede
    any answer. Fresh admission also requires counterpart coverage by the
    frozen prompt; observing pending/unknown or retained terminals does not
    rewrite the step or authorize another dispatch. The step's gate judgment
    and Memory decision are not made here. *)
