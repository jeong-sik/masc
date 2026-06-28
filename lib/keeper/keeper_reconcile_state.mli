(** Reconciler back-off state for TOML hot-reload.

    Tracks per-keeper consecutive failures of [ensure_keeper_meta] inside
    the [keeper_runtime] periodic sweep. Without back-off the sweep emits
    one WARN per failed keeper every [~30s] forever — a [Workaround
    Rejection Bar §retry loop] anti-pattern. See the May 2026
    MASC/OAS error-warn reduction audit §P6 (config drift).

    Classifications returned by [record_failure]:

    - [`First]: first failure for this (keeper, error fingerprint).
      Caller should keep the existing WARN log (behaviour preservation).
    - [`Repeated]: same (keeper, fingerprint) seen again. Caller should
      demote the WARN to DEBUG. The counter still increments.
    - [`Threshold_disable]: consecutive failures reached
      [disable_threshold] (default 10). Caller should ERROR-log once and
      mark the keeper as disabled. Subsequent sweeps skip until
      [reset_on_mtime_change] fires.

    Note: in-process state, [Hashtbl.t] guarded by a [Mutex]. No
    cross-process synchronisation — each server replica maintains its own
    counters. Threshold defaults are conservative; the dedup/demote tier
    is a [WORKAROUND-CARRYOVER §Symptom-억제] band-aid for invalid TOML
    drift, not a structural fix. Root fix: invalid keeper TOML cleanup +
    [keeper_assignable=false] policy decision (separate RFC). *)

(** Outcome of recording a reconcile failure. *)
type record_outcome =
  [ `First
  | `Repeated
  | `Threshold_disable
  ]

(** [default_disable_threshold] consecutive failures before a keeper is
    disabled. *)
val default_disable_threshold : int

(** [record_failure ~keeper ~error ~toml_mtime] registers a reconcile
    failure for [keeper] with the raw error string [error] and the TOML
    mtime [toml_mtime] observed at failure time. Returns the
    classification.

    Internally:
    - Computes [error_digest] from [error] (first 96 bytes, sanitised).
    - If [keeper] has no existing entry, creates one and returns
      [`First].
    - If the entry exists and [fingerprint] matches:
      increments [consecutive_failures]; returns [`Repeated] until the
      counter would reach [disable_threshold], then returns
      [`Threshold_disable] (idempotent on subsequent calls until reset).
    - If the entry exists with a different [fingerprint]: resets
      [consecutive_failures] to 1 and returns [`First] (a fresh error is
      newly visible). *)
val record_failure :
     keeper:string
  -> error:string
  -> toml_mtime:float
  -> record_outcome

(** [is_disabled ~keeper] returns [true] iff [keeper] has been disabled
    by [`Threshold_disable] and not yet reset by an mtime change. *)
val is_disabled : keeper:string -> bool

(** [reset_on_mtime_change ~keeper ~new_mtime] clears the failure state
    for [keeper] iff its tracked [toml_mtime] differs from [new_mtime].
    Returns [true] if a reset happened, [false] otherwise (no entry or
    same mtime). Caller invokes this on every sweep so a user's TOML
    edit re-enables the reconciler. *)
val reset_on_mtime_change : keeper:string -> new_mtime:float -> bool

(** [record_success ~keeper] clears any failure state for [keeper]. Used
    when [ensure_keeper_meta] succeeds, so a transient failure doesn't
    leave stale counters across cycles. *)
val record_success : keeper:string -> unit

(** Testing-only: snapshot the current per-keeper state.
    Returns [(consecutive_failures, disabled, error_digest)] or [None]
    if no entry exists. *)
val peek_for_test : keeper:string -> (int * bool * string) option

(** Testing-only: clear all in-memory state. *)
val reset_all_for_test : unit -> unit
