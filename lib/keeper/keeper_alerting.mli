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

(** {1 Included: Keeper_alerting_path} *)

val project_root_of_config : Workspace.config -> string
val sandbox_roots : meta:keeper_meta -> string list
val resolve_keeper_read_path :
  config:Workspace.config ->
  sandbox_roots:string list ->
  raw_path:string ->
  (string, Keeper_alerting_path.keeper_path_rejection) result
