(** Keeper Runtime — keeper reconciliation and keepalive bootstrap.

    Reconciles persisted keeper meta against on-disk personality / TOML and
    materialises boot-time defaults; spawns supervisor sweeps and existing
    keepalives during server bootstrap.  Runtime-only mutable state stays
    behind keeper runtime/execution modules. *)

(** {1 Personality compare helpers}

    [String.trim]-based compare alone produced a re-sync storm
    (see #10479): the persisted text exceeds
    [Keeper_config.prompt_render_max_bytes] for some keepers, which the
    read path normalises while [target_will] keeps the raw value.  These
    helpers normalise both sides before diffing so reconcile is
    idempotent. *)

val personality_text_equal : string -> string -> bool
(** [true] when two personality fields compare equal under the same
    byte-cap normalisation the prompt renderer uses. *)

val personality_field_diff_entry :
  string -> string -> string -> string option
(** [(field, current, target)] -> human-readable diff line, or [None]
    when the field already compares equal. *)

val personality_diff_summary : (string * string * string) list -> string list
(** Render a list of [(field, current, target)] tuples as diff lines. *)

val personality_field_diff_summary :
  field:string -> current:string -> target:string -> string option
(** Single-field convenience wrapper around
    [personality_field_diff_entry]. *)

(** {1 Boot meta materialization} *)

type boot_meta_resolution = {
  meta : Keeper_types.keeper_meta;
  materialized : bool;
      (** [true] when the meta was synthesised from defaults rather than
          loaded from disk. *)
}
(** Result of [load_or_materialize_boot_meta]. *)

val bootable_keeper_names : Coord.config -> string list
(** Names of every keeper whose [keepers/<name>/keeper.toml] exists and
    looks bootable on disk. *)

val apply_default : 'a option -> 'a -> 'a
(** [apply_default opt default] returns [v] when [opt = Some v], else
    [default]. *)

val apply_default_opt : 'a option -> 'a option -> 'a option
(** [apply_default_opt primary fallback] returns [primary] when it is
    [Some], else [fallback]. *)

val contains_substring : string -> string -> bool
(** [true] when [haystack] contains [needle] (raw byte search). *)

val invalid_profile_defaults_error : keeper_name:string -> string -> string
(** Render the structured error message for a profile-defaults parse
    failure. *)

val effective_declarative_cascade_name :
  Keeper_types_profile.keeper_profile_defaults ->
  Keeper_types.keeper_meta -> string
(** Resolve the cascade name for a keeper meta given its profile
    defaults; falls back to the profile default when the meta omits one. *)

val resynced_tool_access :
  Keeper_types_profile.keeper_profile_defaults ->
  Keeper_types.keeper_meta -> Keeper_types.tool_access
(** Re-derive the tool-access record after merging profile defaults so
    the meta-level [preset] and per-tool overrides stay consistent. *)

val ensure_keeper_meta :
  Coord.config ->
  string -> (Keeper_types.keeper_meta, string) result
(** Load the keeper meta for [keeper_name], materialising defaults from
    the profile when the on-disk meta is missing fields. *)

val load_or_materialize_boot_meta :
  [> float Eio.Time.clock_ty ] Keeper_types.context ->
  string -> (boot_meta_resolution, string) result
(** Eio-aware variant of [ensure_keeper_meta] used during server boot;
    surfaces whether the meta was materialised from defaults. *)

(** {1 Supervisor sweep state} *)

type keeper_bootstrap_stats = {
  enabled : bool;        (** Is supervisor sweep enabled by config? *)
  scanned : int;         (** Keepers inspected during boot. *)
  started : int;         (** Keepers whose keepalive fiber was spawned. *)
  stale : int;           (** Keepers skipped because last heartbeat is stale. *)
  recovering : int;      (** Keepers re-entering the failing-recovery loop. *)
}
(** Counts emitted by [bootstrap_existing_keepers] for telemetry. *)

val bootstrap_existing_keepers :
  [> float Eio.Time.clock_ty ] Keeper_types.context ->
  keeper_bootstrap_stats
(** Walk every bootable keeper and start/recover its keepalive fiber.
    Returns counts for the boot summary log line. *)

val supervisor_sweeps : (string, Pulse.t) Hashtbl.t
(** Per-keeper supervisor-sweep [Pulse] handle.  Mutated under
    [supervisor_sweeps_mu]; readers use [with_sweeps_ro]. *)

val supervisor_sweeps_mu : Eio.Mutex.t
(** Lock guarding the [supervisor_sweeps] hashtable. *)

val with_sweeps_ro : (unit -> 'a) -> 'a
(** Run [f] with the sweeps lock held in read mode. *)

val with_sweeps_rw : (unit -> 'a) -> 'a
(** Run [f] with the sweeps lock held in write mode. *)

val supervisor_sweep_running : string -> bool
(** [true] when a supervisor sweep is currently registered for the
    keeper. *)

val stop_supervisor_sweep : string -> unit
(** Stop and forget the supervisor sweep for [keeper_name]; idempotent. *)

val update_supervisor_sweep_interval : string -> float -> bool
(** Adjust the sweep interval for an active sweep.  Returns [false] when
    the keeper has no active sweep. *)

val start_supervisor_sweep :
  [> float Eio.Time.clock_ty ] Keeper_types.context -> unit
(** Spawn a supervisor sweep fiber for the keeper bound to [context];
    no-op when one is already running. *)

val supervisor_sweep_age_seconds : base_path:string -> float option
(** Seconds since the supervisor-sweep marker was last touched, or
    [None] when no marker exists. *)

(** {1 Keepalive bootstrap registry} *)

val existing_keepalive_bootstrap_done : (string, unit) Hashtbl.t
(** Set of keeper names whose keepalive fiber has already been
    bootstrapped during this process lifetime; prevents duplicate
    spawns on hot-reload. *)

val has_boot_entries : Coord.config -> bool
(** [true] when at least one bootable keeper exists for [config]. *)

val should_start_supervisor_sweep :
  config:Coord.config -> stats:keeper_bootstrap_stats -> bool
(** Policy gate: should the supervisor sweep run given [config] and the
    bootstrap stats? *)

val maybe_start_supervisor_sweep :
  [> float Eio.Time.clock_ty ] Keeper_types.context ->
  keeper_bootstrap_stats -> unit
(** Start the supervisor sweep when [should_start_supervisor_sweep]
    returns [true]; otherwise no-op. *)

val start_existing_keepalives :
  [> float Eio.Time.clock_ty ] Keeper_types.context -> unit
(** Top-level entry: bootstrap every existing keeper's keepalive plus
    the supervisor sweep when applicable. *)

val stop_keepalive : ?base_path:string -> string -> unit
(** Stop the keepalive fiber for [keeper_name] and clear the
    bootstrap-done marker so a future restart can re-bootstrap. *)

val reset_test_state : string -> unit
(** Clear in-memory state for [keeper_name] in tests; not safe in
    production. *)
