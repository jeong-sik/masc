(** Environment and config-root bootstrap helpers for server startup. *)

val force_jsonl_fallback_env : unit -> unit
val requested_backend_mode : unit -> string

val storage_enforcement_fallback_reason :
  requested:string -> effective:string -> string option

val note_storage_enforcement_fallback :
  requested:string -> effective:string -> unit

val ensure_default_oas_cascade_timeout_env : unit -> unit
val config_bootstrap_mode : unit -> [> `Auto | `Empty | `Skip ]
val bootstrap_base_path_config_root : base_path:string -> unit
val startup_config_resolution : base_path:string -> Config_dir_resolver.resolution
