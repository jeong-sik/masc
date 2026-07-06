(** Keeper_alerting -- skill routing, path safety checks, and tool-call
    preparation helpers for keeper execution.

    Includes {!Keeper_skill_routing} and {!Keeper_alerting_path} via
    [include] for backward-compatible access by downstream modules.

    @since v2.200.0 *)

open Keeper_types
open Keeper_meta_contract

(** {1 Included: Keeper_skill_routing types} *)

type selection_mode =
  | Default_route
  | Model_selected of string
  | Model_rejected of string

type keeper_skill_route = {
  primary_skill : string;
  secondary_skill : string option;
  reason : string;
  selection_mode : selection_mode;
}

(** {1 Usage Merging} *)

(** Merge two API usage records by summing all fields. *)
val merge_usage :
  Agent_sdk.Types.api_usage ->
  Agent_sdk.Types.api_usage ->
  Agent_sdk.Types.api_usage

(** {1 Included: Keeper_skill_routing} *)

val keeper_allowed_skills : string list
val is_valid_keeper_skill : string -> bool
val route_keeper_skill : message:string -> keeper_skill_route
val format_skill_route_line : keeper_skill_route -> string
val format_skill_route_reason : keeper_skill_route -> string
val strip_skill_route_lines : string -> string
val parse_skill_route_response :
  string -> fallback_route:keeper_skill_route -> keeper_skill_route
val keeper_skill_routing_instructions :
  fallback_route:keeper_skill_route -> string
val skill_route_context_text :
  fallback_route:keeper_skill_route -> string

(** {1 Included: Keeper_alerting_path} *)

val project_root_of_config : Workspace.config -> string
val normalize_path_for_check : string -> string
val normalize_allowed_path_for_check :
  root:string -> string -> string option
val is_within_root_norm : root_norm:string -> string -> bool
val absolute_allowed_paths :
  config:Workspace.config -> allowed_paths:string list -> string list
val absolute_allowed_paths_result :
  config:Workspace.config -> allowed_paths:string list -> (string list, string) result
val resolve_keeper_target_path :
  config:Workspace.config ->
  allowed_paths:string list ->
  raw_path:string ->
  (string, Keeper_alerting_path.keeper_path_rejection) result
val sanitize_keeper_name : string -> string
val playground_path_of_keeper : string -> string
val playground_mind_path : string -> string
val playground_repos_path : string -> string
val effective_allowed_paths : meta:keeper_meta -> string list
val effective_write_allowed_paths : meta:keeper_meta -> string list
val resolve_keeper_read_path :
  config:Workspace.config ->
  allowed_paths:string list ->
  raw_path:string ->
  (string, Keeper_alerting_path.keeper_path_rejection) result
val process_status_to_json : Unix.process_status -> Yojson.Safe.t
val extract_user_messages : working_context -> string list

(** {1 Re-exported Utilities} *)

val keeper_model_tools : Masc_domain.tool_schema list
