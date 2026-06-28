(** Keeper profile defaults, persona loading, and path helpers. *)

include module type of Keeper_config
include module type of Keeper_types_profile_sandbox
  with type sandbox_profile = Keeper_types_profile_sandbox.sandbox_profile
   and type network_mode = Keeper_types_profile_sandbox.network_mode
   and type multimodal_policy = Keeper_types_profile_sandbox.multimodal_policy

val keeper_debug : bool

type 'a context =
  { config : Workspace.config
  ; agent_name : string
  ; sw : Eio.Switch.t
  ; clock : 'a Eio.Time.clock
  ; proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option
  ; net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option
  }

type tool_result = Tool_result.result

val tool_result_ok : ?tool_name:string -> string -> tool_result
val tool_result_error :
  ?tool_name:string -> ?class_:Tool_result.tool_failure_class -> string -> tool_result

val tool_result_with_tool_name : tool_name:string -> tool_result -> tool_result
val tool_result_body : tool_result -> string
val tool_result_success : tool_result -> bool

val schemas : Masc_domain.tool_schema list
val short_preview : ?max_len:int -> string -> string
val take : int -> 'a list -> 'a list
val ensure_dir : string -> string
val dedupe_keep_order : 'a list -> 'a list
val normalize_name_list : string list -> string list
val normalize_name_list_opt : string list -> string list option
val lower_string_list_opt : string list -> string list option
val workspace_seq_map_to_json : (string * int) list -> Yojson.Safe.t
val workspace_seq_map_of_json : Yojson.Safe.t -> (string * int) list

include module type of Keeper_types_profile_defaults

type persona_summary =
  { persona_name : string
  ; display_name : string
  ; role : string option
  ; trait : string option
  ; profile_path : string
  ; has_keeper_defaults : bool
  }

val operator_todo_placeholder_marker : string
val string_has_operator_todo_placeholder : string -> bool
val json_has_operator_todo_placeholder : Yojson.Safe.t -> bool
val json_operator_todo_placeholder_paths : Yojson.Safe.t -> string list
val reject_placeholder_persona_profile : label:string -> path:string -> Yojson.Safe.t -> bool
val operator_todo_placeholder_fields : (string * string option) list -> string list
val persona_operator_todo_placeholder_fields : persona_summary -> keeper_profile_defaults -> string list
val keeper_profile_defaults_materializable : keeper_profile_defaults -> bool
val normalize_per_provider_timeout_opt : source:string -> float option -> float option

val per_provider_timeout_of_declared_float_opt :
  source:string ->
  declared:bool ->
  float option ->
  per_provider_timeout_state * float option

val per_provider_timeout_of_toml :
  source:string ->
  Keeper_toml_loader.toml_doc ->
  string ->
  per_provider_timeout_state * float option

val per_provider_timeout_of_json_field :
  source:string ->
  field:string ->
  Yojson.Safe.t ->
  per_provider_timeout_state * float option

val normalize_per_provider_timeout_json_field :
  source:string -> field:string -> Yojson.Safe.t -> float option

val personas_root_opt : unit -> string option
val persona_profile_path_opt : string -> string option

include module type of Keeper_types_profile_oas_env

val profile_defaults_of_toml :
  Keeper_toml_loader.toml_doc -> (keeper_profile_defaults, string) result

val parsed_field_key_names : string list
val canonical_keeper_toml_key_names : string list
val loader_level_keeper_toml_key_names : string list
val detect_unknown_keeper_toml_keys : Keeper_toml_loader.toml_doc -> string list
val unknown_keeper_toml_warning_key_limit : int

val current_unknown_keeper_toml_warning_keys : unit -> string list
(* Snapshot of the bounded WARN-key cache used by
   warn_unknown_keeper_toml_keys_once. Test inspection of the bound. *)

val take_warning_keys : int -> 'a list -> 'a list
val normalize_unknown_keeper_toml_keys : string list -> string list
val warn_unknown_keeper_toml_keys_once : path:string -> string list -> bool
val warn_unknown_keeper_toml_keys : path:string -> Keeper_toml_loader.toml_doc -> unit
val merge_string_list : base:'a list -> 'a list -> 'a list

val merge_keeper_profile_defaults :
  agent_name:string ->
  base:keeper_profile_defaults ->
  overlay:keeper_profile_defaults ->
  keeper_profile_defaults

val load_keeper_toml : string -> (string * keeper_profile_defaults, string) result
val log_toml_skip_once : file:string -> error:string -> bool
val reset_logged_toml_skip_for_test : unit -> unit
val discover_keepers_toml : string -> (string * keeper_profile_defaults) list
val keeper_toml_path_opt : string -> string option
val keeper_toml_path_opt_for_base_path :
  base_path:string -> string -> string option
val load_keeper_profile_defaults_from_persona : string -> keeper_profile_defaults
val load_keeper_profile_defaults_result_for_base_path :
  base_path:string -> string -> (keeper_profile_defaults, string) result
val resolved_persona_name : keeper_name:string -> keeper_profile_defaults -> string
val load_keeper_profile_defaults_result : string -> (keeper_profile_defaults, string) result
val invalidate_keeper_profile_defaults_cache : string -> unit
val classify_toml_failure_reason : string -> string

type keeper_toml_config_error =
  { keeper_name : string
  ; path : string
  ; error : string
  ; reason : string
  }

type keeper_toml_unknown_keys =
  { keeper_name : string
  ; path : string
  ; unknown_keys : string list
  }

val keeper_toml_config_error_to_json : keeper_toml_config_error -> Yojson.Safe.t
val keeper_toml_unknown_keys_to_json : keeper_toml_unknown_keys -> Yojson.Safe.t
val keeper_name_of_toml_path : string -> string
val keeper_toml_unknown_keys_of_path : string -> keeper_toml_unknown_keys option
val keeper_toml_config_error_of_path : string -> keeper_toml_config_error option
val keeper_toml_config_errors_in_dir : string -> keeper_toml_config_error list
val keeper_toml_unknown_keys_in_dir : string -> keeper_toml_unknown_keys list
val keeper_toml_config_errors : unit -> keeper_toml_config_error list
val keeper_toml_unknown_keys : unit -> keeper_toml_unknown_keys list
val keeper_toml_config_errors_json : unit -> Yojson.Safe.t
val keeper_toml_config_error_for_name : string -> keeper_toml_config_error option
val load_keeper_profile_defaults_for_base_path :
  base_path:string -> string -> keeper_profile_defaults
val load_keeper_profile_defaults : string -> keeper_profile_defaults

type keeper_default_source_snapshot =
  { source_kind : string option
  ; defaults : keeper_profile_defaults
  }

val keeper_default_source_snapshot : string -> keeper_default_source_snapshot
val persona_description_max_chars : int
val load_persona_extended : ?max_chars:int -> string -> string option
val load_persona_summary : string -> persona_summary option
val load_persona_summary_from_path : string -> string -> persona_summary option
val list_persona_summaries : unit -> persona_summary list
val keeper_dir : Workspace.config -> string
val keeper_meta_path : Workspace.config -> string -> string
val session_base_dir : Workspace.config -> string
