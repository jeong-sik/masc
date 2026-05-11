(** Config directory resolution — SSOT for locating MASC config files.

    Resolution order: [MASC_CONFIG_DIR] env > [$MASC_BASE_PATH/.masc/config] >
    [$HOME/.masc/config] > repo fallback (opt-in) > missing.

    The module caches the result of the first [resolve] call; use [reset] to
    force re-evaluation (e.g. after env var changes in tests). *)

(** {1 Types} *)

type source =
  | Env
  | Local_masc
  | Home_masc
  | Invalid_env
  | Exe_relative
  | Cwd
  | Missing

type status =
  | Ready
  | Warn
  | Invalid_env_status
  | Missing_status

type path_item = {
  path : string;
  exists : bool;
  source : source;
}

type resolution = {
  status : status;
  warnings : string list;
  config_root : path_item;
  cascade_authoring : path_item;
  cascade : path_item;
  prompts : path_item;
  keepers : path_item;
  personas : path_item;
}

type inputs = {
  cwd : string;
  executable_name : string;
  env_base_path : string option;
  env_config_dir : string option;
  env_personas_dir : string option;
  env_home : string option;
}

(** {1 SSOT filenames}

    Documented in [docs/TOML-RELOAD-MATRIX.md]. *)
val cascade_json_filename : string
val cascade_toml_filename : string
val tool_policy_toml_filename : string
val keeper_runtime_toml_filename : string

(** {1 Resolution} *)

val inputs_from_env : unit -> inputs
(** Snapshot current environment (cwd, executable, env vars). *)

val resolve : unit -> resolution
(** Cached resolution. First call evaluates, subsequent calls return the cache. *)

val resolve_with : inputs -> resolution
(** Uncached resolution from explicit inputs. *)

val reset : unit -> unit
(** Clear cached resolution, forcing re-evaluation on next [resolve] call. *)

(** {1 Path accessors}

    Convenience functions that call [resolve ()] internally. *)

(** Path to the on-disk cascade source ([cascade.toml]) when the config
    root resolves to a usable directory and the file exists. Returns
    [None] when the resolver state is [Invalid_env]/[Missing] or the
    file is absent. *)
val cascade_path_opt : unit -> string option

(** Candidate path to the on-disk cascade source ([cascade.toml]),
    independent of whether the file exists. Useful for diagnostics that
    want to surface the expected path. *)
val cascade_path_candidate : unit -> string
val prompts_dir : unit -> string
val keepers_dir : unit -> string
val personas_dir_opt : unit -> string option
val personas_dirs : unit -> string list
val personas_dirs_with : inputs -> resolution -> string list
val keeper_toml_path_opt : string -> string option
(** [keeper_toml_path_opt name] checks for [keepers/<name>.toml]. *)

val config_signature_exists : string -> bool
(** [config_signature_exists dir] checks whether [dir] looks like a valid
    MASC config directory (has cascade.json, prompts/, keepers/, or personas/). *)

(** {1 Env introspection}

    Sanitized env var readers that strip inherited test values when running
    under a test executable. [MASC_BASE_PATH] uses
    [MASC_TEST_ALLOW_BASE_PATH_OVERRIDE]; config/persona paths and [HOME]
    use [MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE]. *)

val current_env_base_path_opt : unit -> string option
val current_env_config_dir_opt : unit -> string option
val current_env_base_path_opt : unit -> string option
val current_env_personas_dir_opt : unit -> string option
val current_env_home_opt : unit -> string option

(** Sanitize inherited test environment values.
    Strips env vars captured at process start when running under a test
    executable without [MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE]. *)
val sanitize_inherited_test_env_opt :
  running_under_test_executable:bool ->
  allow_inherited:bool ->
  initial:string option ->
  current:string option ->
  string option

(** Base-path-specific test env sanitization. Same captured test values are
    stripped only when they resolve under the process HOME; temp roots supplied
    at process start stay usable. *)
val sanitize_inherited_test_base_path_opt :
  running_under_test_executable:bool ->
  allow_inherited:bool ->
  initial:string option ->
  current:string option ->
  home:string option ->
  string option

val path_from_executable : cwd:string -> string -> string option

val path_from_cwd : string -> string option

val repo_config_fallback_enabled : unit -> bool

(** {1 Warnings and logging} *)

val warnings : unit -> string list
val log_warnings : ?context:string -> unit -> unit
(** Emit warnings via [Log.warn] if any. Idempotent per signature. *)

val log_resolution : ?context:string -> unit -> unit
(** Emit a single info line with the resolved config root source and path.
    Notes [MASC_CONFIG_DIR] shadowing of local_masc overlays. *)

(** {1 Serialization} *)

val source_to_string : source -> string
val status_to_string : status -> string
val item_to_json : path_item -> Yojson.Safe.t
val to_json : resolution -> Yojson.Safe.t

(** {1 Utility} *)

val dedupe_paths : string list -> string list
