(** Durable binding records, source captures and assertions. Slices are queries;
    no cached query result is authoritative. All paths are below [root]. *)
type t
val create : root:string -> t
val root : t -> string
val digest : string -> string
val blob_reference : string -> Lane_addon_types.evidence
(** Content-addressed reference without writing. It may be used to measure a
    complete acquisition envelope; publish it only after [write_blob] succeeds. *)
val write_blob : t -> string -> (Lane_addon_types.evidence, string) result
val read_blob : t -> Lane_addon_types.evidence -> (string, string) result
type jsonl_snapshot = { entry_count : int; reference : Lane_addon_types.evidence }
val retain_jsonl : t -> history:string -> entry_count:int -> newest_first:'a list ->
  encode:('a -> string) -> (jsonl_snapshot, string) result
(** Retains an immutable append-only history. The native owner guarantees that
    [history] changes on replacement/restore and the list is a captured prefix.
    Only new records are encoded; an older concurrent capture gets its old root.
    Call from a system thread: the store serializes its cursor updates. *)
val read_jsonl : t -> Lane_addon_types.evidence -> (string, string) result
(** Reads a complete retained sequence, oldest first, validating every node.
    Explicit full-history reads allocate the requested result; capture does not. *)
val save_binding : t -> instance_id:string -> Yojson.Safe.t -> (unit, string) result
val remove_binding : t -> instance_id:string -> (unit, string) result
(** Removes one binding record. A missing record is already removed. *)
val save_action : t -> instance_id:string -> request_id:string -> Yojson.Safe.t -> (unit, string) result
(** Publishes every directory ancestor before accepting a durable receipt,
    including ancestors left visible by earlier failed publication attempts. *)
val load_action : t -> instance_id:string -> request_id:string -> (Yojson.Safe.t option, string) result
(** Missing receipts return [None]. Existing receipts are accepted only after
    strictly syncing the exact opened file and parent directory, verifying the
    bytes and both path identities again. A visible rename alone is not durable
    confirmation. Sync/read/identity failures return [Error] without replay or
    changing the result. Reads keep the existing full-receipt allocation policy. *)
val save_broadcast : t -> instance_id:string -> request_id:string -> Yojson.Safe.t -> (unit, string) result
val load_broadcast : t -> instance_id:string -> request_id:string -> (Yojson.Safe.t option, string) result
(** Retain the exact published evidence before sending its idempotent Broadcast.
    Repeated sends read that original artifact, not a changing live binding. *)
val save_sampling_request : t -> instance_id:string -> request_id:string ->
  Yojson.Safe.t -> (unit, string) result
val sampling_requests : t -> instance_id:string -> (Yojson.Safe.t list, string) result
val save_sampling_outcome : t -> instance_id:string -> request_id:string ->
  Yojson.Safe.t -> (unit, string) result
(** Independently retain the terminal request/outcome link before replacing the
    primary request index. Recovery can discover it if that replacement fails. *)
val iter_sampling_requests : t -> instance_id:string -> max_bytes:int ->
  f:(Yojson.Safe.t -> (unit, string) result) -> (unit, string) result
(** Stream recovery records with bounded per-record reads and constant directory
    memory. Terminal recovery links are visited first, then unresolved requests.
    The callback can stop immediately with [Error]; directory and decoding errors
    are explicit. Call from a system thread. No ordering is guaranteed. *)

(** Discover requests after cancellation or restart, including pending rows that
    have no terminal evidence. Records are atomically replaced, never removed. *)
val bindings : t -> (Yojson.Safe.t list, string) result
(** Reconciles each binding sequence with retained observation filenames so a
    failed binding write cannot hide a renamed observation. Exact record reads
    still require their own durability and payload verification. *)
type observation_write_error =
  | Observation_rejected of string
  | Publication_failed of { failure : Fs_compat.atomic_replace_failure;
      verification_error : string option }
val observation_write_error_to_string : observation_write_error -> string
val append_observation : t -> instance_id:string -> seq:int ->
  sources:Yojson.Safe.t -> Lane_addon_types.output -> (unit, observation_write_error) result
(** The staged writer's [After_rename] knowledge is preserved even if exact
    visible-byte verification fails. [verification_error] records that failure;
    neither case establishes durability. The runtime must reserve the renamed
    sequence before propagating uncertainty; this never authorizes action replay. *)
val observations : t -> instance_id:string ->
  ((Yojson.Safe.t * Lane_addon_types.output) list, string) result
val read_observation : instance_id:string -> seq:int -> max_bytes:int -> t ->
  (Lane_addon_types.output, string) result
(** One immutable completed record. Missing, oversized and malformed records
    fail; callers must not advance a consumer cursor on those failures.
    The exact opened record and parent directory are strictly synced before
    accepting bytes, including when an earlier publication was unconfirmed.
    This does not rewrite or repair corrupted data. *)
val query_observations : t -> instance_id:string -> expected_seq:int -> max_bytes:int ->
  since:float option -> until:float option -> lane_id:string option ->
  (Lane_addon_types.output, string) result
(** Streams retained sequence files with bounded response and per-record reads.
    Matching rows have priority over source coverage. A second pass over the
    inspected prefix returns coverage for selected records first, then other
    source coverage, including observations without rows. Each coverage buffer
    is bounded by the space remaining after rows. The query receipt identifies
    the inspected prefix and explicitly reports omitted rows, omitted coverage,
    or unreadable observations; source coverage is not a chronological ledger. *)
val freeze : t -> instance_id:string -> binding:Yojson.Safe.t ->
  row_ids:string list -> (Yojson.Safe.t, string) result
val publish_for_keeper : base_path:string -> t -> Yojson.Safe.t ->
  (Yojson.Safe.t, string) result
(** Publishes a frozen bundle, its selected records and their retained source
    bodies byte-for-byte through the existing Tool artifact store. Only this
    store's verified content addresses are read; source bodies stay opaque. Host-owned [lane-sequence:] nodes alone are followed
    through their typed previous references, with every digest and count checked.
    The returned [message] is an exact retained artifact marker, and
    [keeper_artifact] names the manifest whose child references retain all
    published bytes for [keeper_artifact_read]. No message is sent here. *)

module For_testing : sig
  val write : sync_parent:(string -> unit) -> t -> string -> string -> (unit, string) result
  val save_action : sync_parent:(string -> unit) -> t -> instance_id:string ->
    request_id:string -> Yojson.Safe.t -> (unit, string) result
  val load_action : sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    t -> instance_id:string -> request_id:string -> (Yojson.Safe.t option, string) result
  val append_observation :
    replace_file:(string -> string -> (unit, Fs_compat.atomic_replace_failure) result) ->
    t -> instance_id:string -> seq:int -> sources:Yojson.Safe.t ->
    Lane_addon_types.output -> (unit, observation_write_error) result
  val read_observation : sync_file:(Unix.file_descr -> unit) -> sync_parent:(Unix.file_descr -> unit) ->
    instance_id:string -> seq:int -> max_bytes:int -> t -> (Lane_addon_types.output, string) result

end
