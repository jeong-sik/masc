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

type confined_path
(** A path projected to one concrete allowed root. The constructor is hidden so
    callers cannot manufacture an absolute or parent-relative capability path. *)

type confined_path_endpoint =
  | Lexical_entry
  | Follow_referent
(** Objective endpoint semantics used for containment. [Lexical_entry]
    canonicalises the parent and retains the final directory-entry name;
    [Follow_referent] canonicalises the final referent as well. *)

type path_effect_operation =
  | Atomic_replace_entry
  | Patch_then_atomic_replace_entry
  | Append_pinned_resource
  | Create_entry_exclusive
(** Concrete filesystem semantics evaluated by Gate. These constructors name
    what the I/O primitive actually does; they are not risk levels. In
    particular, atomic replacement addresses the lexical directory entry and
    does not follow a symlink in the leaf position. *)

type path_effect
(** Typed Gate projection of one confined filesystem operation. The locator is
    the allowed-root capability plus its lexical relative path. Operations on
    an already-open file additionally carry that resource's device/inode
    identity, so a post-Gate path lookup cannot redirect the effect. *)

type path_effect_parent_scope
(** A parent directory capability pinned before Gate evaluation, plus the
    exact lexical directory segments that do not exist yet and may therefore
    be created only after Gate allows the composite operation. *)

val confined_root : confined_path -> string
val confined_anchor_root : confined_path -> string
val confined_root_relative_path : confined_path -> string
val confined_relative_path : confined_path -> string
val confined_host_path : confined_path -> string
val confined_containment_path : confined_path -> string
(** Canonical containment projection computed exactly once by the resolver
    using the requested endpoint semantics. *)
val confined_endpoint_relative_path : confined_path -> string
(** The same endpoint projection relative to [confined_root], suitable for
    opening the already-confined referent through the root capability. *)

val verify_confined_root_capability :
  confined_path -> _ Eio.Path.t -> (unit, string) result
(** Compare the root directory opened through Eio with the device/inode
    identity captured during resolution. A missing identity or a changed root
    is an explicit error; there is no string-path fallback. *)

val path_effect_parent_scope :
  relative_path:string ->
  resource:Eio.File.Stat.t ->
  create_missing_parents:string list ->
  created_directory_permissions:int ->
  (path_effect_parent_scope, string) result
(** Build a checked parent scope. [relative_path] is relative to the selected
    root capability. [create_missing_parents] contains individual lexical
    child names, in creation order; absolute paths, separators, [.], and [..]
    are rejected. [created_directory_permissions] is the exact mode applied to
    every listed directory and included in the Gate projection. *)

val atomic_replace_effect :
  parent:path_effect_parent_scope ->
  result_file_permissions:int ->
  confined_path ->
  (path_effect, string) result
val patch_then_atomic_replace_effect :
  parent:path_effect_parent_scope ->
  source_relative_path:string ->
  source_resource:Eio.File.Stat.t ->
  result_file_permissions:int ->
  confined_path ->
  (path_effect, string) result
val create_entry_exclusive_effect :
  parent:path_effect_parent_scope ->
  result_file_permissions:int ->
  confined_path ->
  (path_effect, string) result
(** Describe operations whose destination is the lexical directory entry.
    [result_file_permissions] is the exact mode applied to the replacement
    resource before it is renamed. A replaced symlink or missing entry becomes
    a regular file with the supplied mode; an existing regular file caller can
    preserve its pre-Gate mode by supplying that value. *)

val append_pinned_resource_effect :
  confined_path -> Eio.File.Stat.t -> (path_effect, string) result
(** Describe append on the already-open file resource represented by the
    supplied stat. This is deliberately the only constructor for a pinned
    effect, so append cannot accidentally degrade to a post-Gate path lookup. *)

val path_effect_to_yojson : path_effect -> Yojson.Safe.t
(** Stable, complete Gate input projection. *)

val resolve_keeper_confined_path :
  config:Workspace.config ->
  allowed_paths:string list ->
  endpoint:confined_path_endpoint ->
  raw_path:string ->
  (confined_path, keeper_path_rejection) result
(** Resolve a Keeper path to an allowed root plus a path relative to that root.
    The string projection selects the capability and is not the I/O boundary;
    callers must open [confined_anchor_root], descend through
    [confined_root_relative_path] with [Eio.Path.open_dir], and perform all
    filesystem operations on [confined_relative_path]. [endpoint] makes final
    leaf containment explicit: atomic replacement uses [Lexical_entry], while
    operations that read or mutate an existing referent use [Follow_referent].
    After opening the root, callers must run
    [verify_confined_root_capability] before Gate evaluation.

    For roots inside the project, the project root is the anchor. The project
    root's parent is an operator-owned trust boundary and must not be writable
    by the Keeper. Explicit roots outside the project carry the same parent
    trust requirement. *)

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
