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

(** [true] iff [path] resolves under [root_norm]. *)
val is_within_root_norm : root_norm:string -> string -> bool

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

(** Resolve a write target using objective allowed-root containment.
    Relative inputs are joined to the project root; absolute inputs remain
    exact. Explicit allowed roots may be outside the project root. *)
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

(** Resolve a path for read-only access using the same objective containment
    rule as writes. Existence and I/O errors belong to the leaf operation. *)
val resolve_keeper_read_path :
  config:Workspace.config ->
  allowed_paths:string list ->
  raw_path:string ->
  (string, keeper_path_rejection) result

(** Project the exact [Unix.process_status] to kind/code/signal JSON. *)
val process_status_to_json : Unix.process_status -> Yojson.Safe.t

(** Extract user-role text messages from [ctx_work], dropping
    blanks. *)
val extract_user_messages :
  Keeper_types.working_context -> string list
