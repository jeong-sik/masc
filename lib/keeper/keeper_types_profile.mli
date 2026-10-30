(** Keeper config and prompt loading. *)

include module type of Keeper_config
include module type of Keeper_types_profile_sandbox
  with type sandbox_profile = Keeper_types_profile_sandbox.sandbox_profile
   and type network_mode = Keeper_types_profile_sandbox.network_mode

type 'a context =
  { config : Workspace.config
  ; agent_name : string
  ; sw : Eio.Switch.t
  ; clock : 'a Eio.Time.clock
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option
  ; publication_recovery_provider :
      Keeper_publication_recovery_availability.provider
  }

type tool_result = Tool_result.result

val tool_result_ok : ?tool_name:string -> string -> tool_result
val tool_result_ok_data : ?tool_name:string -> Yojson.Safe.t -> tool_result
(** [class_] is required on purpose. It defaulted to [Runtime_failure] until
    2026-08-26, so 80 of 83 call sites labelled every refusal a crash without
    deciding: argument validation, not-found, and genuine faults all arrived
    the same. [Tool_bridge] lowers a fault to [Unknown] instead of
    [Deterministic], so an agent retried calls that could never succeed. The
    layer below ([Tool_result.error]) already requires the class; a default
    here took that back. *)
val tool_result_error :
  ?tool_name:string -> class_:Tool_result.tool_failure_class -> string -> tool_result
val tool_result_error_data :
  ?tool_name:string ->
  ?effect_disposition:Tool_result.failure_effect_disposition ->
  class_:Tool_result.tool_failure_class ->
  Yojson.Safe.t ->
  tool_result

val tool_result_with_tool_name : tool_name:string -> tool_result -> tool_result
val tool_result_body : tool_result -> string
val tool_result_success : tool_result -> bool

val short_preview : ?max_len:int -> string -> string
val take : int -> 'a list -> 'a list
val ensure_dir : string -> string
val dedupe_keep_order : 'a list -> 'a list
val normalize_name_list : string list -> string list
include module type of Keeper_types_profile_defaults

val keeper_profile_defaults_materializable_for_name :
  base_path:string -> string -> bool

include module type of Keeper_types_profile_agent_core_env

val profile_defaults_of_toml :
  Keeper_toml_loader.toml_doc -> (keeper_profile_defaults, string) result

val detect_unknown_keeper_toml_keys : Keeper_toml_loader.toml_doc -> string list

val merge_keeper_profile_defaults :
  base:keeper_profile_defaults ->
  overlay:keeper_profile_defaults ->
  keeper_profile_defaults

type keeper_toml_error_kind =
  Keeper_types_profile_toml.keeper_toml_error_kind =
  | Read_error
  | Parse_error
  | Profile_error
  | Invalid_name
  | Declaration_not_found of string
  | Unknown_deny_tool of string list

type keeper_toml_load_error =
  Keeper_types_profile_toml.keeper_toml_load_error =
  { keeper_path : string
  ; failing_path : string
  ; kind : keeper_toml_error_kind
  ; detail : string
  }

val keeper_toml_load_error_to_string : keeper_toml_load_error -> string

val unknown_deny_tools : string list -> string list
(** The subset of a [keeper.tools.deny] list that names no model-visible
    descriptor. Every load path refuses a profile for which this is
    non-empty, so a reader past the load may only assert on it. *)

val load_keeper_toml :
  string -> (string * keeper_profile_defaults, keeper_toml_load_error) result

type keeper_toml_discovery =
  Keeper_types_profile_toml.keeper_toml_discovery =
  | Loaded of
      { keeper_name : string
      ; defaults : keeper_profile_defaults
      }
  | Invalid of
      { keeper_name : string
      ; error : keeper_toml_load_error
      }

val keeper_toml_discovery_name : keeper_toml_discovery -> string
val discover_keepers_toml : string -> keeper_toml_discovery list
val keeper_toml_path_opt_for_base_path :
  base_path:string -> string -> string option
val load_keeper_profile_defaults_result_for_base_path :
  base_path:string ->
  string ->
  (keeper_profile_defaults, keeper_toml_load_error) result
(** A keeper with no [keepers/<name>.toml] is [Error] with kind
    [Declaration_not_found name] and the expected path as [failing_path];
    it never loads as empty defaults. A file whose [keeper.name] differs
    from [<name>] is refused with kind [Invalid_name], matching
    {!snapshot_profile_defaults}. *)

(** One projection's immutable declaration reads. Capture a new snapshot for
    each projection so edits, additions, removals, and parse/instruction errors
    are observed without a freshness interval. A capture lists the keepers
    directory and reads each listed file once. When the ordered paths and exact
    bytes equal the previous capture's for the same base path and keepers
    directory, that capture is returned without parsing. Otherwise the captured
    bytes are inspected without reopening the files. Successful per-file parses
    can be reused for the same path and complete captured content. Read failures
    are returned but not held; errors determined by readable bytes are held. Same-size edits,
    replacements with preserved mtime, and newly unreadable files are observed
    on the next capture. The files are read individually, so a capture is not
    an atomic transaction across the directory. In-process writers can still
    drop every held capture with {!invalidate_keeper_profile_snapshots}.
    A declaration is indexed by its file name and, when [keeper.name] differs,
    by that name too, refused under both. *)
type keeper_profile_snapshot
val read_keeper_profile_snapshot : base_path:string -> keeper_profile_snapshot
val snapshot_configured_keeper_names : keeper_profile_snapshot -> string list
val snapshot_profile_defaults :
  keeper_profile_snapshot -> string ->
  (keeper_profile_defaults, keeper_toml_load_error) result
(** A name the snapshot holds no declaration for is [Error] with kind
    [Declaration_not_found name]. *)

type declarative_manifest_snapshot =
  | Declarative_manifest_missing
  | Declarative_manifest_present of
      { path : string
      ; sha256 : string
      }

type declarative_materialization_defaults =
  { profile_defaults : keeper_profile_defaults
  ; manifest_snapshot : declarative_manifest_snapshot
  }

(** Validate the complete materialization contract from already captured bytes,
    without re-reading the manifest or mutating workspace state. *)
val materialization_defaults_of_content :
  path:string -> string -> (keeper_profile_defaults, keeper_toml_load_error) result

val load_declarative_materialization_defaults :
  base_path:string ->
  string ->
  (declarative_materialization_defaults, keeper_toml_load_error) result

(** The keeper-TOML keys one update call patches. [None] leaves the file's
    value alone; [Some None] removes the key. *)
type toml_field_patch =
  { instructions : string option
  ; sandbox_profile : sandbox_profile option
  ; network_mode : network_mode option
  ; mention_targets : string list option
  ; board_interests : string list option
  ; input_policy : Keeper_input_policy.t option
  ; activation_mode : Keeper_activation_mode.t option
  ; sandbox_image : string option option
  ; microvm_backend : Keeper_microvm_backend.t option option
  ; remote_endpoint_present : bool
  ; remote_endpoint : string option
  ; max_context_override_present : bool
  ; max_context_override : int option
  ; skill_names_present : bool
  ; skill_names : string list option
  ; native_tool_posture_present : bool
  ; native_tool_posture : Runtime_native_tools.posture option
  }

(** The staged writer's edits for a patch. Single source of truth shared by
    the commit path and pre-write assessment, so the two can never disagree
    on which keys a call touches. *)
val toml_edits_of_patch :
  toml_field_patch -> (string * Keeper_toml_loader.toml_edit) list

(** Like {!load_declarative_materialization_defaults}, but a file the strict
    load refuses is repaired before it is reported: the call's field edits
    are applied to the current bytes and the merged content is validated
    with the same strict reader. A merged file that validates proceeds with
    its defaults; one that does not is refused with the merged error, which
    names a defect in the proposed end state rather than a stale defect the
    patch already repairs. When no merged content can be formed (unreadable
    or uneditable file), the original load error stands. The snapshot always
    hashes the bytes on disk. *)
val load_declarative_materialization_defaults_or_merged :
  base_path:string -> name:string ->
  toml_edits:(string * Keeper_toml_loader.toml_edit) list ->
  (declarative_materialization_defaults, keeper_toml_load_error) result

val invalidate_keeper_profile_snapshots : unit -> unit
(** Drops every held directory snapshot. Per-file parses remain eligible for
    exact-byte reuse; each capture still lists and rereads every declaration. *)

type keeper_toml_config_error =
  { keeper_name : string
  ; keeper_path : string
  ; failing_path : string
  ; kind : keeper_toml_error_kind
  ; detail : string
  }

type keeper_config_probe_error_kind =
  | Directory_resolution_error
  | Not_a_directory
  | Directory_read_error

type keeper_config_probe_error =
  { directory_path : string option
  ; kind : keeper_config_probe_error_kind
  ; detail : string
  }

type keeper_toml_unknown_keys =
  { keeper_name : string
  ; path : string
  ; unknown_keys : string list
  }

val keeper_toml_config_error_to_json : keeper_toml_config_error -> Yojson.Safe.t
val keeper_config_probe_error_to_json : keeper_config_probe_error -> Yojson.Safe.t
val keeper_toml_config_error_of_load_error :
  keeper_name:string -> keeper_toml_load_error -> keeper_toml_config_error
val keeper_toml_unknown_keys_to_json : keeper_toml_unknown_keys -> Yojson.Safe.t
val keeper_toml_config_errors_in_dir_result :
  string -> (keeper_toml_config_error list, keeper_config_probe_error) result
val keeper_toml_unknown_keys_in_dir : string -> keeper_toml_unknown_keys list
val keeper_toml_config_errors_result :
  unit -> (keeper_toml_config_error list, keeper_config_probe_error) result
val keeper_toml_unknown_keys : unit -> keeper_toml_unknown_keys list

type keeper_default_source_snapshot =
  { source_kind : string option
  ; defaults : keeper_profile_defaults
  ; config_error : keeper_toml_load_error option
  }

val keeper_default_source_snapshot :
  base_path:string -> string -> keeper_default_source_snapshot
val keeper_dir : Workspace.config -> string
val keeper_meta_path : Workspace.config -> string -> string
val session_base_dir : Workspace.config -> string
