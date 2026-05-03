(** Keeper_turn_up -- keeper start/reconfigure handler.

    Orchestrates the "masc_keeper_up" tool by delegating to:
    - {!Keeper_turn_up_args}: argument parsing and validation
    - {!Keeper_turn_up_create}: new keeper creation
    - {!Keeper_turn_up_update}: existing keeper reconfiguration *)

open Keeper_types

type tool_result = Keeper_types.tool_result

let handle_keeper_up ctx args : tool_result =
  match Keeper_turn_up_args.parse ctx args with
  | Error (ok, msg) -> (ok, Printf.sprintf "%s" msg)
  | Ok p ->
    match read_meta ctx.config p.name with
    | Error e -> (false, Printf.sprintf "%s" e)
    | Ok None ->
      let (ok, msg) = Keeper_turn_up_create.create_keeper ctx p in
      if ok then (ok, msg)
      else (ok, Printf.sprintf "%s" msg)
    | Ok (Some old) ->
      let (ok, msg) = Keeper_turn_up_update.update_keeper ctx p old in
      if ok then (ok, msg)
      else (ok, Printf.sprintf "%s" msg)
