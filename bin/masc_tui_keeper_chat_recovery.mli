(** Durable TUI-side fence for a Keeper chat whose terminal outcome has not
    yet been observed. *)

type request = Masc_tui_keeper_chat_projection.request

type phase =
  | Prepared
  | Accepted
(** [Prepared] means server acceptance was not durably observed. A surviving
    record may have crossed the chat POST boundary, so it may only be rewritten
    with the same request identity; exact-ID replay is allowed after that rewrite
    returns [Fsync_completed]. [Accepted] means the server acceptance event was
    observed, so restart recovery uses the exact read-only operation lookup. *)

type pending =
  { request : request
  ; phase : phase
  }

type persistence_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string
  | Durable_write_cancelled of string
  | Accepted_already
(** [Visible_sync_unconfirmed] means rename installed the exact record but the
    parent-directory fsync failed. It converges the visible phase without
    granting a prepared request permission to POST. [Accepted_already] means
    another process advanced the same exact fence; the caller must issue zero
    POSTs and switch to read-only operation reconciliation. [Fsync_completed]
    includes durable preparation of a newly created directory chain.
    [Durable_write_cancelled] means that the requested phase became durable but
    cooperative cancellation won before the caller's next side effect. For
    [persist_pending], the caller must keep the prepared fence and issue no POST
    until an explicit retry. For [mark_accepted], the accepted phase is durable
    and a settled caller must defer further cleanup to an explicit retry. *)

val recovery_path : base_path:string -> string
val persist_pending :
  base_path:string -> request -> (persistence_outcome, string) result
val mark_accepted :
  base_path:string -> request -> (persistence_outcome, string) result
(** Record observed server acceptance. This is idempotent for the same exact
    request and recreates a missing fence rather than losing restart recovery. *)
val load_pending : base_path:string -> (pending option, string) result
val clear_pending : base_path:string -> request -> (unit, string) result
(** Remove the exact fence and fsync its parent directory. A visible unlink
    whose parent sync fails remains an error so callers retain the request
    identity until recovery is reloaded. *)

val resume_pending :
  pending ->
  retry_prepared:(request -> 'a) ->
  reconcile_accepted:(request -> 'a) ->
  'a
(** Route a restart record without conflating pre-dispatch durability retry
    with post-acceptance operation reconciliation. *)

val max_reconciliation_polls : int
val next_reconciliation_poll : remaining:int -> [ `Poll of int | `Stop ]

module For_testing : sig
  type staged_writer =
    string -> string -> (unit, Fs_compat.atomic_replace_failure) result

  type durable_bytes_writer =
    on_durable_commit:(unit -> unit) ->
    ownership_root:string ->
    string ->
    string ->
    ( Masc.Keeper_fs.durable_commit_outcome
    , Masc.Keeper_fs.durable_write_error )
    result

  type durable_file_remover =
    ownership_root:string ->
    string ->
    (unit, Masc.Keeper_fs.durable_remove_error) result

  val persist_pending_with_writer :
    save_file_atomic_strict_staged:staged_writer ->
    base_path:string ->
    request ->
    (persistence_outcome, string) result

  val mark_accepted_with_writer :
    save_file_atomic_strict_staged:staged_writer ->
    base_path:string ->
    request ->
    (persistence_outcome, string) result

  val clear_pending_with_remover :
    remove_file:(string -> unit) ->
    base_path:string ->
    request ->
    (unit, string) result

  val save_file_durable_staged_with :
    save_bytes_durable_atomic_observed:durable_bytes_writer ->
    base_path:string ->
    staged_writer

  val remove_file_durable_with :
    remove_file_durable:durable_file_remover ->
    base_path:string ->
    string ->
    unit
end
