(** Durable TUI-side fence for a Keeper chat whose terminal outcome has not
    yet been observed. *)

type request = Masc_tui_keeper_chat_projection.request

type phase =
  | Prepared
  | Dispatching
  | Replayable
  | Accepted
  | Rejected
(** [Prepared] means no dispatcher has durably claimed permission to POST.
    [Dispatching] means the current lock owner may have crossed the POST
    boundary, but no later POST is authorized; recovery is read-only.
    [Replayable] means an outcome-unverified result was observed and exact-ID
    replay permission was durably recorded. [Accepted] means the server
    acceptance event was observed, so restart recovery uses the exact read-only
    operation lookup. [Rejected] means the server definitively rejected the
    request before acceptance, so restart recovery may only remove the fence. *)

type pending =
  { request : request
  ; phase : phase
  }

type persistence_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string
  | Durable_write_cancelled of string
  | Dispatching_already
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
    and a settled caller must defer further cleanup to an explicit retry.
    [Dispatching_already] means another process has claimed the exact fence; a
    caller must enter the serialized dispatch path instead of rewriting it to
    [Prepared]. *)

type dispatch_claim =
  | First_dispatch
  | Reconcile_dispatch
  | Replay_dispatch
  | Accepted_dispatch
  | Rejected_dispatch
(** A claim is returned once the fence has been advanced to match it.
    [First_dispatch] is the only path from [Prepared]. [Reconcile_dispatch]
    authorizes zero POSTs and exact operation lookup only. [Replay_dispatch]
    rewrites an existing [Replayable] fence to [Dispatching] durably before
    another exact-ID POST.
    [Accepted_dispatch] authorizes zero POSTs and exact operation lookup only.
    [Rejected_dispatch] authorizes zero POSTs/GETs and cleanup only. *)

val recovery_path : base_path:string -> string
val persist_pending :
  base_path:string -> request -> (persistence_outcome, string) result
val mark_rejected :
  base_path:string -> request -> (persistence_outcome, string) result
(** Record a definitive pre-acceptance rejection before attempting cleanup. *)
val mark_replayable :
  base_path:string -> request -> (persistence_outcome, string) result
(** Durably authorize an exact-ID replay only after an outcome-unverified
    dispatch result has been observed. The exact fence must already be
    [Dispatching] or [Replayable]; absence, [Prepared], and terminal phases fail
    closed without creating or rewriting replay authority. *)
val mark_accepted :
  base_path:string -> request -> (persistence_outcome, string) result
(** Record observed server acceptance. This is idempotent for the same exact
    request and recreates a missing fence rather than losing restart recovery. *)
val load_pending : base_path:string -> (pending option, string) result
val clear_pending : base_path:string -> request -> (unit, string) result
(** Remove the exact fence and fsync its parent directory. A visible unlink
    whose parent sync fails remains an error so callers retain the request
    identity until recovery is reloaded. *)

val with_dispatch_claim :
  base_path:string ->
  request ->
  (dispatch_claim -> 'a) ->
  ('a, string) result
(** Win the exact fence, then run [f] with the claim it granted.

    The fence is re-read under its own transaction lock and advanced
    monotonically before [f] runs, and that lock is released before it does.
    Exclusion is the phases' job, not the caller's scope: a second claimer
    reads [Dispatching] and gets [Reconcile_dispatch], which authorizes no
    POST, and [persist_pending] refuses both a different request and a rewrite
    of [Dispatching]. Holding a lock across [f] added nothing to that and cost
    every other TUI on the workspace its turn whenever one turn stopped
    settling. *)

val with_dispatch_lock :
  base_path:string -> (unit -> 'a) -> ('a, string) result
(** Serialize a follow-up mutation, such as retrying cleanup, against every
    active or replaying POST without changing the durable phase. *)

val resume_pending :
  pending ->
  retry_prepared:(request -> 'a) ->
  reconcile_dispatching:(request -> 'a) ->
  retry_replayable:(request -> 'a) ->
  reconcile_accepted:(request -> 'a) ->
  cleanup_rejected:(request -> 'a) ->
  'a
(** Route a restart record without conflating first dispatch, serialized replay,
    fail-closed dispatch reconciliation, authorized replay, post-acceptance
    operation reconciliation, and rejected-fence cleanup. *)

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

  val with_dispatch_claim_with_writer :
    save_file_atomic_strict_staged:staged_writer ->
    base_path:string ->
    request ->
    (dispatch_claim -> 'a) ->
    ('a, string) result

  val mark_accepted_with_writer :
    save_file_atomic_strict_staged:staged_writer ->
    base_path:string ->
    request ->
    (persistence_outcome, string) result

  val mark_rejected_with_writer :
    save_file_atomic_strict_staged:staged_writer ->
    base_path:string ->
    request ->
    (persistence_outcome, string) result

  val mark_replayable_with_writer :
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
