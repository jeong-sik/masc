(** Keeper_turn_up -- keeper start/reconfigure handler.

    Orchestrates the "masc_keeper_up" tool by delegating to:
    - {!Keeper_turn_up_args}: argument parsing and validation
    - {!Keeper_turn_up_create}: new keeper creation
    - {!Keeper_turn_up_update}: existing keeper reconfiguration *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

type tool_result = Keeper_types_profile.tool_result

let handle_keeper_up ctx args : tool_result =
  match Keeper_turn_up_args.parse ctx args with
  | Error result -> result
  | Ok p ->
    (match
       Keeper_turn_up_config_persistence.with_current_revision
         ~config:ctx.config
         ~keeper_name:p.name
         (fun revision -> revision, read_meta ctx.config p.name)
     with
     | Error e ->
       tool_result_error ~class_:Tool_result.Runtime_failure (Printf.sprintf "%s" e)
     | Ok { value = _, Error e; _ } ->
       tool_result_error ~class_:Tool_result.Runtime_failure (Printf.sprintf "%s" e)
     | Ok { value = _, Ok None; _ } -> Keeper_turn_up_create.create_keeper ctx p
     | Ok { value = revision, Ok (Some old); _ } ->
       Keeper_turn_up_update.update_keeper
         ~expected_manifest_revision:revision
         ctx
         p
         old)
