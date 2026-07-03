(** Config directory resolution — SSOT for locating MASC config files.

    Resolution order: [MASC_CONFIG_DIR] env > [$MASC_BASE_PATH/.masc/config] >
    missing. Checked-in repo [config/] may be reported as a bootstrap seed, but
    it is never an active config-root fallback.

    The module caches the result of the first [resolve] call; use [reset] to
    force re-evaluation (e.g. after env var changes in tests). *)

(** {1 Types} *)

type source =
  | Env
  | Local_masc
  | Invalid_env
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
}

(** {1 SSOT filenames}

    Documented in [docs/TOML-RELOAD-MATRIX.md]. *)
val runtime_toml_filename : string

val inputs_from_env : unit -> inputs
(** Snapshot current environment (cwd, executable, env vars). *)

val current_working_dir : unit -> string
(** Current working directory, falling back to an absolute host root when the
    process cwd has been deleted. *)

val base_path_or_cwd : unit -> string
(** [MASC_BASE_PATH] from host config, or {!current_working_dir} when unset. *)

val initial_env_home : string option
(** Process-start [HOME] snapshot after shared env trimming. [None] when unset
    or empty. Use this when path policy must not observe in-process HOME
    mutation. *)

val resolve : unit -> resolution
(** Cached resolution. First call evaluates, subsequent calls return the cache. *)

val resolve_with : inputs -> resolution
(** Uncached resolution from explicit inputs. *)

val reset : unit -> unit
(** Clear cached resolution, forcing re-evaluation on next [resolve] call. *)

(** {1 Path accessors}

    Convenience functions that call [resolve ()] internally. *)

val prompts_dir : unit -> string
val keepers_dir : unit -> string
val personas_dir_opt : unit -> string option
val personas_dirs : unit -> string list
val personas_dirs_with : inputs -> resolution -> string list
val keeper_toml_path_opt : string -> string option
(** [keeper_toml_path_opt name] checks for [keepers/<name>.toml]. *)

val base_path_config_root : cwd:string -> string -> string
(** [base_path_config_root ~cwd base_path] returns
    [<base_path>/.masc/config] after applying the same base-path normalization
    used by resolver internals. This helper does not honor
    [MASC_CONFIG_DIR]; callers that need env override semantics should use
    {!resolve_for_base_path}. *)

val resolve_for_base_path : base_path:string -> resolution
(** Resolve the config root for an explicit workspace [base_path]. Explicit
    [MASC_CONFIG_DIR] and [MASC_PERSONAS_DIR] overrides are still honored, but
    ambient [MASC_BASE_PATH] and process cwd do not replace the caller's
    workspace. *)

val keepers_dir_for_base_path : base_path:string -> string
(** [keepers_dir_for_base_path ~base_path] returns the keepers directory for an
    explicit workspace base path. *)

val keeper_runtime_store_of_dirname : string -> Common.keeper_runtime_store option
(** Base-path-independent resolver for canonical child-store names under
    [Common.keepers_runtime_dirname]. *)

val personas_dirs_for_base_path : base_path:string -> string list
(** Base-path-scoped variant of {!personas_dirs}. *)

val keeper_toml_path_opt_for_base_path :
  base_path:string -> string -> string option
(** Base-path-scoped variant of {!keeper_toml_path_opt}. *)

(** {1 .masc/ root sub-directory accessors (RFC-0121)}

    All non-config artifacts under [<base>/.masc/<sub>/] route through these
    helpers instead of hand-built base_path plus .masc child string-literals
    direct construction. The path layout itself remains the single SSOT for
    where each subsystem keeps state, but the layout decision lives in one
    place (this module) rather than scattered across callers.

    Each takes the caller's already-resolved [base_path] (the result of
    server bootstrap resolution) and returns the canonical child path.
    No filesystem access; directory creation is the caller's responsibility. *)

val masc_root : base_path:string -> string
(** [<base_path>/.masc/]. Equivalent to [Common.masc_dir_from_base_path] but
    re-exported here so callers depend on the resolver SSOT, not on
    [Common]. *)

val auth_dir : base_path:string -> string
(** [<base_path>/.masc/auth/]. Internal keeper token storage. *)

val credentials_dir : base_path:string -> string
(** [<base_path>/.masc/credentials/]. Per-credential file storage. *)

val agent_runtime_dir : base_path:string -> string
(** [<base_path>/.masc/runtime/agent/]. Per-session agent runtime markers. *)

val repos_dir : base_path:string -> string
(** [<base_path>/.masc/repos/]. Managed repository checkouts. *)

val tmp_dir : base_path:string -> string
(** [<base_path>/.masc/tmp/]. Short-lived process artifacts. *)

val locks_dir : base_path:string -> string
(** [<base_path>/.masc/locks/]. Process and build lock files. *)

val data_dir : base_path:string -> string
(** [<base_path>/data/]. Bulk tool data (tool-events, tool-metrics).
    Sibling of [.masc/]; callers historically wrote here without going
    through [.masc/]. Layout preserved for backwards compatibility. *)

(** {2 Config-rooted file accessors} *)

val repositories_toml_path : base_path:string -> string
(** [<base_path>/.masc/config/repositories.toml]. Backwards-compatible
    direct derivation from [base_path]. A future RFC may extend this to
    honour [MASC_CONFIG_DIR] override; until then the location matches
    pre-RFC-0121 caller behaviour. *)

val keeper_repo_mappings_toml_path : base_path:string -> string
(** [<base_path>/.masc/config/keeper_repo_mappings.toml]. Same caveat as
    [repositories_toml_path]. *)

val config_signature_exists : string -> bool
(** [config_signature_exists dir] checks whether [dir] looks like a valid
    MASC config directory (has runtime.toml, prompts/, keepers/, or
    personas/). *)

(** {1 Env introspection}

    Sanitized env var readers that strip inherited test values when running
    under a test executable. [MASC_BASE_PATH] uses
    [MASC_TEST_ALLOW_BASE_PATH_OVERRIDE]; config/persona paths use
    [MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE]. *)

val current_env_base_path_opt : unit -> string option

(** [absolute_path path] returns [path] as an absolute path, resolving
    relative [path] against the process cwd via [current_working_dir]. Prefer
    [absolute_path_from ~cwd] when the caller has an explicit anchor so the
    anchor stays the SSOT. *)
val absolute_path : string -> string

val current_env_config_dir_opt : unit -> string option
val current_env_personas_dir_opt : unit -> string option

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
