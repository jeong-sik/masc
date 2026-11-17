
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

type runtime_toml_placement =
  | Embedded_written
      (** No entry was at the path. It now holds the runtime.toml this build
          embeds, readable by its owner only. *)
  | Existing_kept
      (** An entry was at the path: a file, a directory or a link, also a link
          whose target is gone. It is untouched. *)

type runtime_toml_placement_error =
  | Not_published of string
      (** No entry was made at the path, and the directories the call made on
          the way to it are removed. *)
  | Not_synced of string
      (** The path holds its entry, written or kept. The directory of the
          path, or one the call made, could not be synced. *)

val publish_runtime_toml : path:string -> string -> runtime_toml_placement
(** The step of {!place_embedded_runtime_toml} that writes. The content is
    staged beside [path] with mode 0600, synced, and published by a rename
    that replaces nothing: [path] holds the whole file, or the entry of any
    kind that is there by then ([Existing_kept]). The staged file is removed
    either way. The directory of [path] exists. Raises [Unix.Unix_error] or
    [Sys_error] when the staging or the rename fails, and [path] then holds
    what it held. *)

val place_embedded_runtime_toml
  :  path:string
  -> (runtime_toml_placement, runtime_toml_placement_error) result
(** Put the runtime.toml this build embeds at [path] where no entry is, making
    its directory ({!publish_runtime_toml}). An entry that is there is kept
    with no write, so a directory its owner made read-only keeps its file.
    Either way the directory of [path] and the directories the call made are
    synced before [Ok]: a call after one that gave [Not_synced] syncs again.
    The calls block on the file system: a command calls this, not a fiber of
    a server. *)

val bootstrap_base_path_config_root : base_path:string -> unit

type missing_runtime_toml =
  | Written_at_boot
  | Left_missing of string  (** Why boot leaves the file missing. *)

val missing_runtime_toml_at_boot : base_path:string -> missing_runtime_toml
(** Whether {!bootstrap_base_path_config_root} writes runtime.toml into
    [base_path]'s config root when the file is missing. The answer comes from
    the decision the bootstrap acts on, read without writing anything. The
    deployment preflight asks it before it judges a missing file. *)

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
