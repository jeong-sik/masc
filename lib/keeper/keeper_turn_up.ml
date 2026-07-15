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

let handle_keeper_up ?shutdown_supersession_authority ctx args : tool_result =
  match Keeper_turn_up_args.parse ctx args with
  | Error result -> result
  | Ok p ->
    match read_meta ctx.config p.name with
    | Error e -> tool_result_error (Printf.sprintf "%s" e)
    | Ok None -> Keeper_turn_up_create.create_keeper ctx p
    | Ok (Some old) ->
      Keeper_turn_up_update.update_keeper
        ?shutdown_supersession_authority
        ctx
        p
        old
