(** Submit-once host owner for the original requests of the durable message
    floor. A step runs through the same journal as a completed-history request
    and ends at its answer: the answer stays the judgment of a [Judged] record,
    because the Memory commit belongs to the whole chain, not to one step.
    Caller holds the workspace process lease and serializes this Keeper owner. *)
type error = Lane_addon_submit_once.error =
  | Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string
type wait = Lane_addon_submit_once.wait =
  | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type call = expected:Keeper_librarian_durable_request.destination ->
  original:Lane_addon_tool_request_owner.Record.t -> arguments:Yojson.Safe.t ->
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
  | Before_dispatch_replaced of Lane_addon_tool_request_owner.retained
      (** An unadmitted step ended with bound before-dispatch evidence. Its
          source stays unread; this supplies no hole or smaller-input evidence. *)
(** [Pending] covers a host terminal [Outcome_unknown] as {!Keeper_librarian_durable_owner}
    does: it is never a refusal and never permits another submission. [Refused]
    holds a terminal host refusal whose final the host's records confirm. *)
val retain : store:Lane_addon_store.t -> Keeper_librarian_floor_step_request.t ->
  (Lane_addon_tool_request_owner.retained, error) result
(** Persist the full step before any dispatch, retaining its existing journal.
    The caller must retain new work under Runtime's fresh configured-destination
    serializer. A write failure never proves absence or permits another ID. *)
val discover : store:Lane_addon_store.t -> owner:Keeper_librarian_durable_request.owner ->
  ((Lane_addon_tool_request_owner.Record.t * Keeper_librarian_floor_step_request.index) list, error) result
(** Strictly decode the whole owner's published record inventory and indexes,
    without reading bodies. Any malformed metadata refuses the inventory.
    Select a range from this observation, then {!load} every original it needs.
    Discovery alone grants no execution, answer, settlement or ACK authority. *)
val load : store:Lane_addon_store.t ->
  Lane_addon_tool_request_owner.Record.t * Keeper_librarian_floor_step_request.index ->
  (Lane_addon_tool_request_owner.retained * Keeper_librarian_floor_step_request.header, error) result
(** Restore one selected original's canonical body and confirm its discovered
    immutable binding and header. Its progress is read now. The complete
    preparation and Exact digest are checked by
    {!Keeper_librarian_floor_step_request.restore}
    where a consumer needs the step, as before.
    A missing/changed record or unreadable body is an error, never permission
    to create another original. Blocking store work is offloaded as a whole. *)
val resume : store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  original:Lane_addon_tool_request_owner.retained -> step:Keeper_librarian_floor_step_request.t ->
  call:call -> (outcome, error) result
(** Run the step by the shared submit-once rules: a retained answer or refusal
    needs no live worker, a pending request is never submitted again, and only
    a pre-send failure permits another submission. The host's retained terminal and latest execution proof precede
    any answer. Fresh admission also requires counterpart coverage by the
    frozen prompt; observing pending/unknown or retained terminals does not
    rewrite the step or authorize another dispatch. The step's gate judgment
    and Memory decision are not made here. *)
val resume_with_admission : before_admission:(unit -> (unit, error) result) ->
  store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  original:Lane_addon_tool_request_owner.retained -> step:Keeper_librarian_floor_step_request.t ->
  call:call -> (outcome, error) result
(** The same machine, with an additional retained whole-source basis check
    before fresh dispatch. No such check blocks reobservation of an already
    dispatched or terminal original. It grants no extra dispatch authority. *)
