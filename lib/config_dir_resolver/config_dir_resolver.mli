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
}

type inputs = {
  cwd : string;
  executable_name : string;
  env_base_path : string option;
  env_config_dir : string option;
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

val tools_dir : unit -> string
(** [<config-root>/tools] — runtime home of the managed tool definition
    assets ([Managed_asset_sync.Tools]). Created on demand by the asset
    sync; a fresh config root does not have it yet. *)

val mcp_dir : unit -> string
(** [<config-root>/mcp] — runtime home of the managed MCP surface assets
    ([Managed_asset_sync.Mcp]). Created on demand by the asset sync, like
    {!tools_dir}, and deliberately absent from the diagnostics record for the
    same reason. *)
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
    [MASC_CONFIG_DIR] overrides are still honored, but
    ambient [MASC_BASE_PATH] and process cwd do not replace the caller's
    workspace. *)

val keepers_dir_for_base_path : base_path:string -> string
(** [keepers_dir_for_base_path ~base_path] returns the keepers directory for an
    explicit workspace base path. *)

val runtime_toml_path_for_base_path : base_path:string -> string
(** Canonical [runtime.toml] path for an explicit workspace, honoring the same
    config-root override and base-path rules as {!resolve_for_base_path}. The
    file need not exist. *)

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

val repos_relative_path : id:string -> string
(** [".masc/repos/<id>"], relative to the base path.

    [Repo_manager_types.repository.local_path] is stored relative and resolved
    by [Repo_store.local_path], which concats it onto the base path. A caller
    that needs that default must not use {!repos_dir}: the result would be
    resolved twice. Before this existed the HTTP repository constructor built
    the literal inline, and the RFC-0121 audit did not see it because an
    unanchored allowlist entry suppressed the pattern repo-wide. *)

val tmp_dir : base_path:string -> string
(** [<base_path>/.masc/tmp/]. Short-lived process artifacts. *)

val locks_dir : base_path:string -> string
(** [<base_path>/.masc/locks/]. Process and build lock files. *)

val run_ssh_dir : base_path:string -> string
(** [<base_path>/.masc/run/ssh/]. SSH ControlMaster sockets for the remote
    execution lane. *)

val microvm_shim_dir : base_path:string -> string
(** [<base_path>/.masc/microvm/shim/]. The static [masc-exec-shim] the
    operator installs for Apple [container] guests, and the config the
    runtime writes beside it; mounted read-only into every guest
    (RFC-0400). *)

val data_dir : base_path:string -> string
(** [<base_path>/data/]. Bulk tool data (tool-events).
    Sibling of [.masc/]; callers historically wrote here without going
    through [.masc/]. Layout preserved for backwards compatibility. *)

(** {2 Config-rooted file accessors} *)

(** ["repositories.toml"]. SSOT basename of the repository catalog file, so
    callers that surface *which* config file gated a decision (e.g. the
    playground repo [policy_source] field) label it from one constant instead
    of a scattered literal. [repositories_toml_path] derives from this. *)

val repositories_toml_path : base_path:string -> string
(** [<base_path>/.masc/config/repositories.toml]. Direct derivation from
    [base_path]. *)

(** {1 Env introspection}

    Sanitized env var readers that strip inherited test values when running
    under a test executable. [MASC_BASE_PATH] is stripped unconditionally —
    the only thing an opt-out buys is a test executable writing into a live
    workspace. Config paths still honour
    [MASC_TEST_ALLOW_CONFIG_PATH_OVERRIDE], which decides where settings are
    read from rather than where state is written. *)

val current_env_base_path_opt : unit -> string option

(** [absolute_path path] returns [path] as an absolute path, resolving
    relative [path] against the process cwd via [current_working_dir]. Prefer
    [absolute_path_from ~cwd] when the caller has an explicit anchor so the
    anchor stays the SSOT. *)
val absolute_path : string -> string

type canonical_base_path_error =
  | Empty_after_normalization
  | Could_not_derive_absolute of { input : string }

val canonical_base_path_error_to_string : canonical_base_path_error -> string

val canonical_base_path : string -> (string, canonical_base_path_error) result
(** Canonical identity for a MASC workspace base path. Applies
    {!Env_config_core.normalize_masc_base_path_input}, anchors relative inputs
    at {!current_working_dir}, then normalizes once more. Thus [base_path] and
    [base_path/.masc] resolve to the same absolute identity. Invalid input is a
    typed error; callers must not fall back to the raw string. *)

val current_env_config_dir_opt : unit -> string option

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
val to_json : resolution -> Yojson.Safe.t
