(** Keeper Runtime — keeper reconciliation and supervisor runtime.

    Reconciles persisted keeper meta against on-disk Keeper configuration and
    materialises boot-time defaults; supplies the supervisor sweep used by the
    server-owned Keeper bootstrap. Runtime-only mutable state stays behind
    keeper runtime/execution modules. *)

(** {1 Boot meta materialization} *)

type boot_meta_resolution = {
  meta : Keeper_meta_contract.keeper_meta;
  materialized : bool;
      (** [true] when the meta was synthesised from defaults rather than
          loaded from disk. *)
}
(** Result of [load_or_materialize_boot_meta]. *)

type boot_meta_failure_cause =
  | Missing_meta
  | Meta_read_error
  | Config_invalid
  | Sandbox_profile_required
  | Materialization_failed
(** Structured cause for the last boot/materialization failure.  Labels are
    rendered only at JSON/log boundaries; fleet recovery policy should pattern
    match this type, not parse the human-facing [error] text. *)

val boot_meta_failure_cause_label : boot_meta_failure_cause -> string
(** Stable JSON label for {!boot_meta_failure_cause}. *)

type boot_meta_failure = {
  keeper_name : string;
  base_path : string;
  cause : boot_meta_failure_cause;
  config_error : Keeper_types_profile.keeper_toml_load_error option;
  error : string;
  recorded_at : string;
  recorded_at_unix : float;
}
(** Last boot/materialization failure observed for one keeper in one
    workspace.  Kept in memory so health surfaces the current supervisor
    blocker without scraping logs. *)

val boot_meta_failure_for :
  base_path:string -> name:string -> boot_meta_failure option
(** Lookup the last boot/materialization failure for [name] in [base_path], if
    the current process has observed one.  Cleared when the keeper loads or
    materializes successfully. *)

type autoboot_exclusion_reason =
  | Paused
  | Declarative_autoboot_disabled
  | Autoboot_disabled
  | Shutdown_admission_fence
(** Closed reason why a configured keeper is intentionally absent from
    {!bootable_keeper_names}. [Shutdown_admission_fence] is not derivable
    from keeper config: the autoboot caller holds the boot-scan shutdown
    inventory and stamps it for keepers whose admission a durable shutdown
    operation still owns — previously those keepers were silently dropped
    from both the boot set and the excluded list. *)

val autoboot_exclusion_reason_to_string : autoboot_exclusion_reason -> string
(** Stable JSON/log label for {!autoboot_exclusion_reason}. *)

val autoboot_exclusion_reason_to_yojson : autoboot_exclusion_reason -> Yojson.Safe.t
(** Stable JSON representation for {!autoboot_exclusion_reason}. *)

val autoboot_exclusion_reason_opt_to_yojson :
  autoboot_exclusion_reason option -> Yojson.Safe.t
(** Stable JSON representation for an optional {!autoboot_exclusion_reason}. *)

type autoboot_exclusion = {
  keeper_name : string;
  reason : autoboot_exclusion_reason;
}
(** Why keeper policy intentionally excludes a configured keeper from
    autoboot. Invalid configuration is a separate typed admission failure and
    is not collapsed into this policy type. *)

val bootable_keeper_names : Workspace.config -> string list
(** Names of every valid, autoboot-admitted keeper profile. Invalid configured
    keepers remain visible through configured-name/config-error surfaces and
    are still inspected by bootstrap, but never appear executable here. *)

val autoboot_exclusion_reason : Workspace.config -> string -> autoboot_exclusion_reason option
(** Per-keeper pause/autoboot policy exclusion, or [None] when policy admits
    the keeper. [None] does not assert configuration validity; callers that
    need executable admission use {!bootable_keeper_names}. Single-keeper
    projection of {!autoboot_excluded_keeper_reasons}. *)

val autoboot_excluded_keeper_reasons : Workspace.config -> autoboot_exclusion list
(** Configured keepers skipped by autoboot with operator-facing reason labels. *)

val canonicalize_if_keeper : Workspace.config -> string -> string
(** [canonicalize_if_keeper config name] returns [keeper-<n>-agent]
    when [name] (bare or already canonical) refers to a configured
    keeper, else returns [name] unchanged. Safe to apply at credential
    lookup sites: dashboard / admin / external MCP clients pass through
    untouched, keeper bare names get canonicalized so the bare-stub
    redirect path stops being load-bearing. (PR-3b1, AuthIdentityFSM
    invariant I1 IdentityBindsToken.) *)

val effective_declarative_runtime_id :
  Keeper_types_profile.keeper_profile_defaults ->
  Keeper_meta_contract.keeper_meta -> string
(** Resolve the runtime id for a keeper meta given its profile
    defaults; falls back to the profile default when the meta omits one. *)

val ensure_keeper_meta :
  Workspace.config ->
  string -> (Keeper_meta_contract.keeper_meta, string) result
(** Load the keeper meta for [keeper_name], materialising defaults from
    the profile when the on-disk meta is missing fields. *)

val load_or_materialize_boot_meta :
  [> float Eio.Time.clock_ty ] Keeper_types_profile.context ->
  string -> (boot_meta_resolution, string) result
(** Eio-aware variant of [ensure_keeper_meta] used during server boot;
    surfaces whether the meta was materialised from defaults. *)

(** {1 Supervisor sweep state} *)

val start_supervisor_sweep :
  [> float Eio.Time.clock_ty ] Keeper_types_profile.context -> unit
(** Spawn a supervisor sweep fiber for the keeper bound to [context];
    no-op when one is already running. *)

val supervisor_sweep_age_seconds : base_path:string -> float option
(** Seconds since the supervisor-sweep marker was last touched, or
    [None] when no marker exists. *)

val stop_keepalive : ?base_path:string -> string -> unit
(** Stop the keepalive fiber for [keeper_name]. *)

val reset_test_state : string -> unit
(** Clear in-memory state for [base_path] in tests; not safe in production. *)
