
val config_bootstrap_mode : unit -> [ `Auto | `Empty | `Skip ]

val copy_missing_config_root_seed : src:string -> dst:string -> unit

val seed_missing_from_embedded : dst:string -> int
(** Write every distribution config asset the binary embeds that [dst] does not
    already hold, and return how many were written. Used when no filesystem
    [config/] source exists — a release install away from its repo — so a fresh
    base path still gets a runtime.toml instead of failing startup. The repo's
    own [keepers/] is excluded ({!Common.seeds_into_fresh_config_root}); the
    [keepers-default/] roster lands under [keepers/] instead
    ({!Common.fresh_config_root_keeper_seed_target}), and an existing file is
    never overwritten. *)

val backfill_startup_required_from_embedded : config_root:string -> int
(** Write [runtime.toml] into an existing config root from the embedded assets
    when it is missing, and return how many files were written. Narrower than
    {!seed_missing_from_embedded} on purpose: an existing root is operator-owned,
    while the runtime configuration is required for startup. *)

val bootstrap_base_path_config_root : base_path:string -> unit

val bootstrap_initial_config_root : base_path:string -> created:bool -> unit
(** Called under the runtime configuration lock after atomic directory creation.
    Preserve full fresh-root seeding only when this caller created the directory
    and no configuration entries have appeared since. Existing roots retain
    their normal backfill-only behavior. *)

val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution

val builtin_skills : unit -> Builtin_skill_package.package list

val install_builtin_skills :
  on_wait:(string -> unit) ->
  base_path:string ->
  (Builtin_skill_package.report list, Builtin_skill_package.error) result
(** {!Builtin_skill_package.install} with every package this binary embeds.
    [masc init] calls it. Server startup instead runs
    {!Builtin_skill_package.reconcile_at_startup} from
    {!bootstrap_initial_config_root}, which never changes an installed tree,
    and logs every report instead of failing. *)
