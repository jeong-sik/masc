(** Keeper_alerting — path safety checks for keeper execution.

    Includes {!Keeper_alerting_path} for the objective filesystem boundary.

    The alert fanout layer (board/Slack/Slack-DM/GitHub senders,
    retry+dedup machinery) was removed here — see the .ml header
    comment and masc issue #54.

    @since v2.200.0 *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_memory

(** {1 Usage Merging} *)

(** Merge two API usage records by summing all fields. *)
val merge_usage :
  Agent_sdk.Types.api_usage ->
  Agent_sdk.Types.api_usage ->
  Agent_sdk.Types.api_usage

(** {1 Included: Keeper_alerting_path} *)

val project_root_of_config : Workspace.config -> string
val normalize_path_for_check : string -> string
val normalize_allowed_path_for_check :
  root:string -> string -> string option
val is_within_root_norm : root_norm:string -> string -> bool
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
