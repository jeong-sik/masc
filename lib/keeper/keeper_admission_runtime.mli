(** Runtime singletons for the new admission router (RFC-0026 PR-E-1.6).

    Holds two lookup functions that [Keeper_admission_glue.decide] needs:

      - [policy_lookup]  — keeper_id -> Keeper_admission_policy.t option
      - [bucket_lookup]  — provider  -> Keeper_provider_token_bucket.t option

    Both default to a constant [fun _ -> None].  The default is the
    "no policies registered yet" state — [decide] returns [Legacy_path]
    in that case, so the call site is safe to invoke before any
    registration happens.

    Population path (PR-E-1.7, separate PR):
      cascade_config_loader -> Keeper_admission_registry.load_from_json
      -> [set_policy_lookup]
      provider rate-limit table -> per-provider [Keeper_provider_token_bucket.create]
      -> [set_bucket_lookup]

    This module is the shadow-mode shim.  [observe] calls
    [Keeper_admission_glue.decide_shadow] (not [decide]) and increments
    the [metric_keeper_admission_shadow_outcome] counter so we can read
    a 24h distribution of "what would the new router have done" before
    any real swap.  The shadow path bypasses [MASC_ADMISSION_USE_NEW]
    and does not consume tokens. *)

(** {1 First-call lazy init} *)

val init_once_from_base_path : base_path:string -> unit
(** Idempotent init.  First successful call:
      1. Reads [<base_path>/.masc/config/cascade.json] via
         [Cascade_config_loader.load_json] (mtime-cached).
      2. Builds [Keeper_admission_registry] from the [admission]
         sub-object.
      3. Sets [policy_lookup] to [Keeper_admission_registry.lookup].
      4. Sets [bucket_lookup] to a lazy per-provider hashtbl (default
         capacity 10, refill 1.0 RPS — PR-E-1.8 makes this
         configurable per-provider from cascade rate-limit blocks).
    Once installed, subsequent calls are no-ops.

    Concurrency model: a three-state flag (Idle/In_progress/Done) is
    guarded by a [Mutex.protect] that is held ONLY across state
    transitions, never across the file I/O step.  This prevents
    domain-wide stalls when [Cascade_config_loader.load_json] traces
    via [Eio.traceln] or blocks on disk.

    Failure model: a transient load failure logs via [Log.Keeper.warn],
    reverts the flag to Idle, and returns.  The next heartbeat tick
    re-enters and retries.  Until the registry is installed, the call
    site continues to return [Legacy_path]. *)

(** {1 Lookup registration (alternative entry, e.g. for tests)} *)

val set_policy_lookup : Keeper_admission_glue.policy_lookup -> unit
(** Replace the policy lookup function.  PR-E-1.7 calls this once at
    startup with [Keeper_admission_registry.lookup registry].  Replaces
    the lookup atomically; last call wins. *)

val set_bucket_lookup : Keeper_admission_router.bucket_lookup -> unit
(** Replace the bucket lookup function.  PR-E-1.7 calls this once at
    startup with a [Hashtbl.find_opt] over the provider table.
    Replaces the lookup atomically; last call wins. *)

(** {1 Read-only access for the heartbeat loop} *)

val policy_lookup : Keeper_admission_glue.policy_lookup
(** Current policy lookup.  Returns [None] for every keeper until
    [set_policy_lookup] is called. *)

val bucket_lookup : Keeper_admission_router.bucket_lookup
(** Current bucket lookup.  Returns [None] for every provider until
    [set_bucket_lookup] is called. *)

(** {1 Shadow-mode observation} *)

val observe : keeper_id:string -> Keeper_admission_glue.outcome
(** Call [Keeper_admission_glue.decide_shadow] with the registered
    lookups and increment [metric_keeper_admission_shadow_outcome]
    with one of four label values: ["legacy"], ["dispatch"], ["wait"],
    ["surface"].

    The caller is expected to *ignore* the returned outcome for now —
    PR-E-1.6 always falls through to the existing
    [Keeper_turn_slot.with_keeper_turn_slot] path.  PR-E-1.7 swaps in
    the real handler.

    Side effects:
    - Prometheus counter increment.
    - Lazy refill of inspected token buckets ([tokens_available]
      mutates [last_refill_at]; does NOT consume tokens).

    No log line per call (heartbeat already prints one INFO/skip per
    turn; doubling the volume is noise). *)

(** {1 Test seam} *)

val reset_for_test : unit -> unit
(** Reset both lookup functions to the default [fun _ -> None] and
    clear the init state.  Tests only — production code never calls
    this. *)
