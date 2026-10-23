(** Submit-once host owner for original completed-history Memory requests.
    Caller holds the workspace process lease and serializes this Keeper owner. *)
type error = Lane_addon_submit_once.error =
  | Unavailable of string | Rejected of string | Uncertain of string
val error_to_string : error -> string
type wait = Lane_addon_submit_once.wait =
  | Capacity | Worker_pending | Worker_unknown | Worker_unreachable
  | Missing_after_dispatch | Journal_recheck
type publication =
  | Publication_pending of string
  | Publication_complete of Lane_addon_tool_request_owner.retained
type publish = original:Lane_addon_tool_request_owner.retained ->
  request:Keeper_librarian_durable_request.t ->
  proposal:Keeper_librarian_runtime.durable_proposal -> (publication, error) result
(** Root's actual source-locked publication port: recover/persist the complete
    original Gate transcript, commit intent, actual Memory/range receipts and
    source/cursor ACK before Finished. It must be idempotent and validate all
    source/owner/disposition authority itself. Complete is checked against the
    durable original record; no callback acceptance is a completed publication. *)
type call = expected:Keeper_librarian_durable_request.destination ->
  original:Lane_addon_tool_request_owner.retained -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_submit_once.call_error) result
(** Actual Runtime call edge must recheck the original semantic destination and
    physical owner immediately before RPC. Only failures before RPC are Not_sent. *)
type outcome =
  | Pending of wait * Lane_addon_tool_request_owner.retained
  | Publication_waiting of string
  | Refused of Lane_addon_exact.final * Lane_addon_tool_request_owner.retained
  | Finished of Lane_addon_tool_request_owner.retained
val retain : store:Lane_addon_store.t -> Keeper_librarian_durable_request.t ->
  (Lane_addon_tool_request_owner.retained, error) result
(** Persist the full original before any dispatch, retaining its existing journal.
    The caller must retain new work under Runtime's fresh configured-destination
    serializer; this port alone grants no live configuration authority. A write
    failure never proves absence or permits a replacement request ID. *)
val discover : store:Lane_addon_store.t -> base_path:string -> keepers_dir:string ->
  keeper_id:string ->
  ((Lane_addon_tool_request_owner.retained * Keeper_librarian_durable_request.t) list, error) result
(** Strictly restore the entire physical scope before a fresh source selector.
    Any malformed original/owner/epoch refuses the inventory. Finished originals
    remain observations; only active originals should block or drive new work. *)
val resume : store:Lane_addon_store.t -> config:Workspace.config -> reserved:string list ->
  original:Lane_addon_tool_request_owner.retained -> request:Keeper_librarian_durable_request.t ->
  call:call -> publish:publish -> wake:(unit -> unit) -> (outcome, error) result
(** Host retained/latest proof and complete raw domain validation precede any
    publication callback, including recovery while Off. Unknown work is never
    resubmitted; only shared submit-once pre-admission/Not_sent rules retry.
    Existing Finished is strictly restored but not republished against today's
    moving range receipt. Wake submits to the same Memory lane only after newly
    observed durable Finished; scheduling acceptance is not execution success. *)
