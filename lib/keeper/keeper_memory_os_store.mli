(** Canonical, fresh-state-only Memory OS persistence.

    HEAD is the sole mutable authority:

    {v HEAD -> immutable commit -> immutable manifest
             -> immutable facts and episode objects v}

    Only objects reachable through the current HEAD have meaning. Every
    [snapshot], [prepared_commit], [commit_receipt], and
    [pending_publication] carries an opaque runtime store binding. Passing a
    value to a different store instance fails closed.

    The winning genesis publication creates an opaque persisted store
    identifier. Every later HEAD and commit preserves that exact identifier,
    which distinguishes independently created stores and participates in every
    commit receipt commitment. *)

module Sha256 : sig
  type t

  val equal : t -> t -> bool
  val to_string : t -> string
end

type state =
  { facts : Keeper_memory_os_types.fact list
  ; episodes : Keeper_memory_os_types.episode list
  }

type t
type snapshot
type prepared_commit
type commit_receipt
type pending_publication
type publication_obligation
type settlement_warning
type error

type persisted_artifact =
  [ `Facts
  | `Episode
  | `Manifest
  | `Commit
  | `Head_row
  ]

(** Diagnostic projection for the store's private contiguous-allocation safety
    ceiling. This is not a product capacity, admission policy, runtime limit,
    provider/model capability, or pricing input. *)
type implementation_safety_violation =
  { artifact : persisted_artifact
  ; observed_at_least_bytes : int64
  ; ceiling_bytes : int64
  }

(** [prepare] performs a final live HEAD revalidation against [expected].
    [Stale_expected current] reports the authoritative snapshot observed when
    that exact cursor check fails.

    [Current_commit_replay] is returned only when that final revalidation still
    identifies the exact commit authoritative in [expected], and that commit
    has the same operation identifier and exact state digest. Earlier commits
    are not inspected and no broader execute-once guarantee is implied.
    Reusing that current operation identifier with a different state is an
    error. *)
type prepare_outcome =
  | Prepared of prepared_commit
  | Current_commit_replay of commit_receipt
  | Stale_expected of snapshot

(** Publication outcomes are effect-first.

    [Committed] includes a publication whose authoritative effect was proven
    even when later resource settlement produced warnings. [Stale current]
    proves that this call did not publish and carries the authoritative
    snapshot observed by the failed compare-and-swap. [Indeterminate] means
    publication may have occurred; callers must pass the pending value to
    [settle] and must not dispatch [publish] again. Any [Error] returned by
    [publish] means this call did not publish HEAD. *)
type publish_outcome =
  | Committed of commit_receipt
  | Stale of snapshot
  | Indeterminate of pending_publication

(** [Settled_not_published] is returned only when the previous authority is
    still proven current. A different later authority cannot by itself prove
    whether the pending publication occurred, so it remains
    [Still_indeterminate]. An [Error] from [settle] also leaves the original
    pending publication unresolved. Only [settle] may be retried with that
    pending value; [publish] must not be dispatched again. *)
type settle_outcome =
  | Settled_committed of commit_receipt
  | Settled_not_published of snapshot
  | Still_indeterminate of pending_publication

(** Restart recovery is current-only. [Recovered_committed] proves that the
    exact desired HEAD row and receipt are authoritative now.
    [Recovered_not_published] proves that the exact expected prior authority is
    still current. [Recovered_superseded] reports a valid third authority; it
    does not prove whether the desired publication was authoritative earlier
    and must therefore fail closed without automatic republication. *)
type recovery_outcome =
  | Recovered_committed of commit_receipt
  | Recovered_not_published of snapshot
  | Recovered_superseded of snapshot

(** Open a store below an already-authorized private root capability. The
    callback delimits the lifetime of the open store resources. Values are not
    generatively typed: the implementation embeds an opaque runtime binding and
    rejects values produced by any other store instance. *)
val with_store :
  secure_random:Eio.Flow.source_ty Eio.Resource.t ->
  root:Eio.Fs.dir_ty Eio.Path.t ->
  owner_id:string ->
  (t -> ('a, error) result) ->
  ('a, error) result

val load : t -> (snapshot, error) result

val snapshot_state : snapshot -> state
val snapshot_generation : snapshot -> int64
val snapshot_settlement_warnings : snapshot -> settlement_warning list

val prepare :
  t ->
  expected:snapshot ->
  operation_id:string ->
  state:state ->
  (prepare_outcome, error) result

(** Capture the exact expected and desired current-authority evidence from a
    prepared commit. Production access must durably persist the canonical bytes
    before dispatching [publish].

    An obligation contains no facts or episodes, is not a Memory OS read
    authority, and provides no publish, delete, fallback, or migration
    operation. Its desired immutable commit reference is a restart-stable scope
    proof: recovery must find and validate that exact prepared commit below the
    opened private root before classifying an expected or superseding HEAD.
    Unlike runtime-bound prepared and pending values, its canonical bytes are
    intended to survive callback and process restart. *)
val publication_obligation_of_prepared :
  t ->
  prepared_commit ->
  (publication_obligation, error) result

(** Encode or decode only the exact current obligation schema. The checksum is
    domain-separated and binds owner, expected and desired HEAD publication
    evidence (including the exact immutable commit references), desired
    operation, and desired state digest. *)
val publication_obligation_to_bytes : publication_obligation -> string

val publication_obligation_of_bytes :
  string ->
  (publication_obligation, error) result

val publish :
  t ->
  prepared_commit ->
  (publish_outcome, error) result

val settle :
  t ->
  pending_publication ->
  (settle_outcome, error) result

(** Classify a durable obligation against the validated current HEAD and its
    reachable immutable graph. This never publishes, retries, deletes, or
    changes HEAD or immutable Memory OS authority. Recovery rejects a private
    root that does not contain the exact desired commit scope proof and rejects
    impossible store, generation, or receipt relationships instead of treating
    them as supersession. The underlying HEAD read may initialize or settle
    private stable-lock mechanism metadata. Callers must retain and use the
    obligation to block successor mutations until the wider transaction
    explicitly resolves it. *)
val recover_publication :
  t ->
  publication_obligation ->
  (recovery_outcome, error) result

val committed_snapshot : commit_receipt -> snapshot

(** A receipt identifier is the domain-separated SHA-256 digest of the
    canonical commit envelope: schema, persisted store identifier, owner,
    generation, operation identifier, exact manifest reference, and state
    digest. The envelope contains no parent commit reference. The receipt proves
    the exact commit identity that was authoritative when publication was
    established; it proves neither ancestry nor that the commit remains current
    after a later publication. *)
val commit_receipt_id : commit_receipt -> Sha256.t
val commit_receipt_operation_id : commit_receipt -> string
val commit_receipt_state_sha256 : commit_receipt -> Sha256.t
val commit_receipt_generation : commit_receipt -> int64
val commit_receipt_settlement_warnings :
  commit_receipt ->
  settlement_warning list

val pending_publication_operation_id : pending_publication -> string
val pending_publication_generation : pending_publication -> int64
val pending_publication_receipt_id : pending_publication -> Sha256.t
val pending_publication_settlement_warnings :
  pending_publication ->
  settlement_warning list

val settlement_warning_to_string : settlement_warning -> string
val error_settlement_warnings : error -> settlement_warning list
val error_implementation_safety_violation :
  error ->
  implementation_safety_violation option
val error_to_string : error -> string

module For_testing : sig
  type error_tag =
    | Invalid_layout_error
    | Store_not_active_error
    | Runtime_store_binding_mismatch_error
    | Persisted_store_binding_mismatch_error
    | Invalid_domain_value_error
    | Conflicting_operation_error
    | Generation_exhausted_error
    | Entropy_source_failed_error
    | Implementation_safety_ceiling_exceeded_error
    | Byte_accounting_overflow_error
    | Immutable_create_failed_error
    | Immutable_read_failed_error
    | Immutable_digest_mismatch_error
    | Invalid_store_json_error
    | Head_busy_unchanged_error
    | Head_operation_failed_error
    | Head_row_too_large_error
    | Pending_publication_mismatch_error
    | Invalid_publication_obligation_error
    | Publication_obligation_owner_mismatch_error
    | Publication_obligation_mismatch_error

  type warning_tag =
    | Head_settlement_warning_tag
    | Head_effect_warning_tag
    | Head_indeterminate_warning_tag
    | Immutable_settlement_warning_tag

  val error_tag : error -> error_tag
  val warning_tag : settlement_warning -> warning_tag

  (** Exercise the production publication state machine with deterministic
      hooks from the underlying capability-relative HEAD primitive. *)
  val publish_with_head_hooks :
    Fs_compat.Capability_head.For_testing.hooks ->
    t ->
    prepared_commit ->
    (publish_outcome, error) result

  val prepare_with_implementation_ceiling :
    maximum:int64 ->
    t ->
    expected:snapshot ->
    operation_id:string ->
    state:state ->
    (prepare_outcome, error) result

  val canonical_state_bytes : state -> (string, error) result
  val state_sha256 : state -> Sha256.t
end
