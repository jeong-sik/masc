(** Keeper alerting — path safety, sandbox bundle paths, and tool
    output projection helpers. *)

(** {1 Included: Keeper_path_rejection} *)
include module type of struct
  include Keeper_path_rejection
end

(** Operator-facing telemetry — increments the path-rejection counter
    with a [kind] label derived from the constructor. *)
val rejection_to_telemetry : keeper_path_rejection -> unit

(** Project a [Workspace.config] to its project root by stripping the
    trailing [.masc] base-path component when present. *)
val project_root_of_config : Workspace.config -> string


(** Re-export of [Env_config_core.strip_trailing_slashes]. *)
val strip_trailing_slashes : string -> string

(** [Fs_compat.realpath] with a fallback that walks up the directory
    tree until an ancestor resolves, then reconstructs the suffix. *)
val normalize_path_for_check : string -> string

(** [normalize_path_for_check] with trailing slashes stripped. *)
val normalize_path_for_check_stripped : string -> string

(** Normalize an allowed-paths entry against [root], returning [None]
    when blank or unresolvable. *)
val normalize_allowed_path_for_check :
  root:string -> string -> string option

(** Split [raw] on '/' and drop empty / "." components. *)
val split_relative_components : string -> string list

(** [true] iff any component is [".."]. *)
val has_parent_component : string list -> bool

val join_path_components : string list -> string

val path_exists : string -> bool

val parent_exists : string -> bool

(** [true] iff [path] resolves under [root_norm]. *)
val is_within_root_norm : root_norm:string -> string -> bool

(** Walk [root] looking for a directory called [anchor]; for each
    match append [suffix_rel] and keep the path when it exists and
    stays within [root]. *)
val find_suffix_matches_under_root :
  root:string ->
  anchor:string ->
  suffix_rel:string ->
  ?max_dirs:int ->
  ?max_matches:int ->
  unit ->
  string list

(** Try to resolve a missing relative read path by searching the
    keeper's sandbox roots for a unique match. *)
val maybe_resolve_missing_relative_read_path :
  roots:string list ->
  raw_path:string ->
  (string option, keeper_path_rejection) result

(** [true] iff a missing-leaf read is allowed (parent exists,
    multi-component, no trailing slash). *)
val allows_missing_leaf_read : raw:string -> candidate:string -> bool

val is_within_allowed_norms :
  target_norm:string -> string list -> bool

(** Project per-keeper allowed_paths to absolute, normalized paths. *)
val absolute_allowed_paths :
  config:Workspace.config -> allowed_paths:string list -> string list

(** Like [absolute_allowed_paths] but errors when normalization
    silently drops every entry. *)
val absolute_allowed_paths_result :
  config:Workspace.config ->
  allowed_paths:string list ->
  (string list, string) result

val playground_root_of_allowed : string list -> string option

val raw_looks_like_playground_subdir : string -> bool

(** Detect relative paths rooted at the workspace [.masc/] internal-state
    directory.  The keeper playground is exempt.  Ordinary repository files
    named [backlog.json] are not internal state. *)
val is_masc_internal_state_path : string -> bool

(** Detect normalized targets that resolve under the workspace-level
    MASC internal state directory.  Call this after resolving traversal
    and symlinks, so raw paths such as [lib/../.masc/config/keepers/x.toml]
    cannot bypass the internal-state guard. *)
val is_masc_internal_state_norm : root_norm:string -> target_norm:string -> bool

(** Resolve a write target path under [allowed_paths] within the
    project root. *)
val resolve_keeper_target_path :
  config:Workspace.config ->
  allowed_paths:string list ->
  raw_path:string ->
  (string, keeper_path_rejection) result

(** {1 Playground / sandbox path SSOT re-exports} *)

(** Re-export of [Playground_paths.sanitize_keeper_name]. *)
val sanitize_keeper_name : string -> string

(** Re-export of [Playground_paths.bundle_root]. *)
val playground_path_of_keeper : string -> string

(** Re-export of [Playground_paths.mind_path]. *)
val playground_mind_path : string -> string

(** Re-export of [Playground_paths.repos_path]. *)
val playground_repos_path : string -> string

(** Re-export of [Playground_paths.bundle_paths]. *)
val playground_bundle_paths : string -> string list

(** Sandbox host root path for [meta]. *)
val sandbox_path_of_meta : meta:Keeper_meta_contract.keeper_meta -> string

(** Sandbox bundle paths (root, mind/, repos/) for [meta]. *)
val sandbox_bundle_paths_of_meta :
  meta:Keeper_meta_contract.keeper_meta -> string list

(** Ensure the playground bundle dirs exist; returns the absolute
    paths created. *)
val ensure_playground_bundle :
  config:Workspace.config -> name:string -> string list

val ensure_sandbox_bundle :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  string list

val ensure_sandbox_bundle_for_profile :
  config:Workspace.config ->
  name:string ->
  sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile ->
  string list

(** Effective READ allowed_paths from keeper meta — sandbox root +
    explicit [allowed_paths]. *)
val effective_allowed_paths :
  meta:Keeper_meta_contract.keeper_meta -> string list

(** Effective WRITE allowed_paths from keeper meta — currently the
    same shape as [effective_allowed_paths]. *)
val effective_write_allowed_paths :
  meta:Keeper_meta_contract.keeper_meta -> string list

(** Resolve a path for read-only access within the keeper's
    effective allowlist; walks roots for missing relative paths. *)
val resolve_keeper_read_path :
  config:Workspace.config ->
  allowed_paths:string list ->
  raw_path:string ->
  (string, keeper_path_rejection) result

(** Project a [Unix.process_status] to a JSON object via
    [Masc_exec.Exit_code.of_process_status] — kind/code/signal +
    label + optional hint. *)
val process_status_to_json : Unix.process_status -> Yojson.Safe.t

(** Extract user-role text messages from [ctx_work], dropping
    blanks. *)
val extract_user_messages :
  Keeper_types.working_context -> string list
