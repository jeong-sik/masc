val project_root_from_executable : unit -> string option

val config_root_from_ancestor : string -> string option

val versioned_config_root_candidates : unit -> string list

val copy_file_if_missing : src:string -> dst:string -> unit

val copy_missing_tree : src:string -> dst:string -> unit

val config_bootstrap_mode : unit -> [ `Auto | `Empty | `Skip ]

val ensure_config_root_scaffold : string -> unit

val copy_missing_config_root_seed : src:string -> dst:string -> unit

val bootstrap_base_path_config_root : base_path:string -> unit

val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution
