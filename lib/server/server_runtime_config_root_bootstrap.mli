
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
(** Write the config files whose absence stops startup — runtime.toml and the
    model catalog overlay — into an existing config root from the embedded
    assets when they are missing, and return how many were written. Narrower
    than {!seed_missing_from_embedded} on purpose: an existing root is
    operator-owned, and these two are not a preference. *)

val bootstrap_base_path_config_root : base_path:string -> unit

val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution

val seed_missing_builtin_skills : base_path:string -> int
(** Seed complete first-party packages from the binary into [.masc/skills].
    Existing package directories are preserved as a whole, including operator
    resource deletions. Returns the number of newly installed packages. *)

val builtin_skills : unit -> Builtin_skill_package.package list

val refresh_builtin_skills : base_path:string -> int
(** Installer update: seed missing packages and update recorded, unmodified
    packages. Print preserved package revisions for explicit operator review.
    Existing packages without receipts are preserved. *)
