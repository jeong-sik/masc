let ( let* ) = Result.bind

let reader ~base_path () =
  match Candle_status.configured ~base_path with
  | Candle_config.Off -> (fun ~keeper -> Ok (Keeper_portrait_look.equipment_of_name keeper))
  | Candle_config.Disabled {reason} -> (fun ~keeper:_ -> Error ("Candle is disabled: " ^ reason))
  | Candle_config.Enabled _ ->
    let snapshot =
      let* view = Candle_ledger.read ~base_path |> Result.map_error Candle_ledger.read_error_to_string in
      Candle_balance.of_events (Candle_ledger.events view) |> Result.map_error Candle_balance.error_to_string in
    (fun ~keeper -> Result.map (fun state -> Candle_balance.equipment state ~keeper) snapshot)

let current ~base_path ~keeper = reader ~base_path () ~keeper

type receipt = { equipment : Keeper_portrait_look.equipment; changed : bool }

type error = Unavailable of string | Invalid_ledger of Candle_balance.error | Refused of Candle_balance.error
let error_to_string = function
  | Unavailable reason -> reason
  | Invalid_ledger error -> "Invalid Candle ledger: " ^ Candle_balance.error_to_string error
  | Refused error -> Candle_balance.error_to_string error

let equip ~now ~base_path ~keeper ~slot ~choice =
  let* () = match Candle_status.configured ~base_path with
    | Candle_config.Off -> Error (Unavailable "Candle is off")
    | Candle_config.Disabled {reason} -> Error (Unavailable ("Candle is disabled: " ^ reason))
    | Candle_config.Enabled _ -> Ok () in
  let* at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Unavailable detail) in
  let keeper = Keeper_id.Keeper_name.to_string keeper in
  Candle_ledger.update ~base_path (fun view ->
    let* state = Candle_balance.of_events (Candle_ledger.events view)
      |> Result.map_error (fun error -> Invalid_ledger error) in
    let* selected = Candle_balance.equip state ~keeper ~slot ~choice
      |> Result.map_error (fun error -> Refused error) in
    let changed = Candle_balance.selection state ~keeper ~slot <> choice in
    let events = if changed then [{Candle_event.at; body=Candle_event.Equipped {keeper;slot;choice}}] else [] in
    Ok (events, {equipment=Candle_balance.equipment selected ~keeper;changed}))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | (Candle_ledger.Read_failed _ | Candle_ledger.Event_unwritable _ | Candle_ledger.Write_failed _ | Candle_ledger.Write_locked _) as error ->
      Unavailable (Candle_ledger.update_error_to_string error_to_string error))
