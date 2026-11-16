(** Durable denial of one completed-history original's future Memory effect.
    This neither decides the unknown execution outcome nor consumes its source. *)
type guard = {
  owner_record_sha256 : string;
  memory_revision : int option;
  memory_sha256 : string option;
  cursors_sha256 : string;
}

type cut_basis = private {
  declaration_id : string;
  request_id : string;
  exact_digest : string;
  attempt_ordinal : int;
  record_sha256 : string;
  proof_sha256 : string option;
}
type authority = Worker_absent | Excluded_cut of cut_basis
(** A persisted account of the authority held when publishing the fence.
    An [Excluded_cut] is not a live Exact claim or successor grant. *)

type t = private {
  scope : string;
  request_id : string;
  request_digest : string;
  physical_owner : Yojson.Safe.t;
  source_sha256 : string;
  original_record : Yojson.Safe.t;
  authority : authority;
  expected : guard;
  actor : string;
  reason : string;
  fenced_at : float;
}

val guard_to_json : guard -> Yojson.Safe.t
val guard_of_json : Yojson.Safe.t -> (guard, string) result
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
val create : request:Keeper_librarian_durable_request.t ->
  original:Lane_addon_tool_request_owner.retained -> expected:guard ->
  actor:string -> reason:string -> now:float -> (t, string) result
val create_cut : store:Lane_addon_store.t ->
  request:Keeper_librarian_durable_request.t ->
  original:Lane_addon_tool_request_owner.retained -> expected:guard ->
  exclusion:Lane_addon_exact.cut_exclusion ->
  actor:string -> reason:string -> now:float -> (t, string) result
(** Reconfirms the live callback-scoped claim and retained Cut. The caller
    must retain that claim through fence publication and strict readback,
    under the source/Memory locks and actual serialized Memory owner. *)
val read : store:Lane_addon_store.t -> scope:string -> request_id:string ->
  (t option, string) result
val confirm_binding : request:Keeper_librarian_durable_request.t ->
  original:Lane_addon_tool_request_owner.retained -> t -> (unit, string) result
(** Immutable identity/source binding only; never grants the old effect. *)
val confirm_binding_index : index:Keeper_librarian_durable_request.index ->
  original:Lane_addon_tool_request_owner.Record.t -> t -> (unit, string) result
(** {!confirm_binding} from the record and its index: the fence's source
    digest is the index's, its owner the index's. Reads no body. *)
val check_unfenced : store:Lane_addon_store.t ->
  request:Keeper_librarian_durable_request.t ->
  original:Lane_addon_tool_request_owner.retained -> (unit, string) result
(** A fence blocks by immutable identity, even if a late observation changed
    the current progress. Malformed, rebound or unreadable fences also refuse. *)
val publish : store:Lane_addon_store.t -> t ->
  (Lane_addon_store.history_fence_publication, string) result
(** Caller holds source and Memory locks and serialized Memory-lane ownership.
    Publication compares the entire expected owner under the existing scope
    mutex. An uncertain save is never permission to execute a successor. *)
