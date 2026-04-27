type storage_backend =
  | Memory of Backend.Memory.t
  | FileSystem of Backend.FileSystem.t

type config = {
  base_path : string;
  workspace_path : string;
  lock_expiry_minutes : int;
  backend_config : Backend_types.config;
  backend : storage_backend;
}

val domain_local_pg_backend_diagnostics_json : unit -> Yojson.Safe.t
val with_domain_local_pg_backend : sw:Eio.Switch.t -> net:'a -> clock:Eio.Time.clock -> mono_clock:Eio.Time.Mono.t -> config -> config option
val read_git_file : string -> string option
val parse_gitdir_to_main_root : string -> string option
val find_git_root : string -> string option
val normalize_base_path : string -> string
val running_under_test_executable : unit -> bool
val test_base_path_override_env : string
val test_base_path_override_enabled : unit -> bool
val sync_test_base_path_env : string -> unit
val resolve_requested_base_path : string -> string
val resolve_masc_base_path : string -> string
val resolve_server_default_base_path : string -> string
val is_unresolved_template : string -> bool
val env_opt : string -> string option
val auto_detect_backend : unit -> string
val storage_type_from_env : unit -> string
val sanitize_namespace_segment : string -> string
val backend_config_for : string -> Backend_types.config
val create_backend : Backend_types.config -> (storage_backend, Backend_types.error) result
val create_backend_eio : sw:Eio.Switch.t -> Backend_types.config -> (storage_backend, Backend_types.error) result
val reset_default_config_cache : unit -> unit
val build_default_config : string -> config
val default_config : string -> config
val default_config_eio : sw:Eio.Switch.t -> ?on_backend_ready:(storage_backend -> unit) -> string -> config
