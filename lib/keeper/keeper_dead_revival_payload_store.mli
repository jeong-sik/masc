(** Private durable storage operations for immutable revival payloads. *)

val create :
  Workspace.config ->
  prepared ->
  (create_outcome, error) result
(** Durably creates one exclusive mode-[0600] payload. Existing leaves are
    never replaced. [Target_unchanged] fails closed as [Create_unsettled];
    only [Target_created] may reconcile after exact reread and parent fsync. *)

val read :
  Workspace.config ->
  expected_ref:immutable_ref ->
  expected_authority_leaf:string ->
  transaction_id:string ->
  owner_id:string ->
  keeper_name:string ->
  expected_trace_id:Keeper_id.Trace_id.t ->
  expected_generation:int ->
  (payload, error) result
(** Reads exactly the referenced byte count, verifies its revival-domain
    digest, decodes only the current canonical schema, and checks every caller
    binding. *)

val delete :
  Workspace.config ->
  keeper_name:string ->
  expected_authority_leaf:string ->
  transaction_id:string ->
  immutable_ref ->
  (unit, error) result
(** Idempotently removes the immutable payload and durably anchors absence.
    The caller must continuously hold the matching revival authority lock. *)

val payload_directory : Workspace.config -> string
val payload_shard_directory : Workspace.config -> string -> string
val reraise_fatal : exn -> Printexc.raw_backtrace -> unit

val authority_shard_is_valid :
  Keeper_dead_revival_payload_types.authority_shard ->
  bool
