
val config_bootstrap_mode : unit -> [ `Auto | `Empty | `Skip ]

val copy_missing_config_root_seed : src:string -> dst:string -> unit

val seed_missing_from_embedded : dst:string -> int
(** Write every distribution config asset the binary embeds that [dst] does not
    already hold, and return how many were written. Used when no filesystem
    [config/] source exists — a release install away from its repo — so a fresh
    base path still gets a runtime.toml instead of failing startup. Keeper
    manifests are excluded ({!Common.seeds_into_fresh_config_root}) and an
    existing file is never overwritten. *)

val backfill_startup_required_from_embedded : config_root:string -> int
(** Write the config files whose absence stops startup — runtime.toml and the
    model catalog overlay — into an existing config root from the embedded
    assets when they are missing, and return how many were written. Narrower
    than {!seed_missing_from_embedded} on purpose: an existing root is
    operator-owned, and these two are not a preference. *)

val bootstrap_base_path_config_root : base_path:string -> unit

val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution
