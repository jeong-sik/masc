let ( let* ) = Result.bind

let reader ~now ~base_path () =
  Candle_observe.equipment (Candle_observe.read ~now ~base_path)

let current ~now ~base_path ~keeper = reader ~now ~base_path () ~keeper

(* Portrait browsing needs recorded ownership, not payout availability or a
   newly appended policy fact. Replay only the immutable ledger read. *)
let read_persisted ~now ~base_path ~keeper =
  let* ledger = Candle_ledger.read ~base_path
    |> Result.map_error Candle_ledger.read_error_to_string in
  let* at = Candle_stamp.at ~now in
  let* balance = Candle_balance.of_events ~at (Candle_ledger.events ledger)
    |> Result.map_error Candle_balance.error_to_string in
  Ok (Candle_balance.equipment balance ~keeper)

type receipt = { equipment : Keeper_portrait_look.equipment; changed : bool }

type error = Unavailable of string | Invalid_ledger of Candle_balance.error | Refused of Candle_balance.error
let error_to_string = function
  | Unavailable reason -> reason
  | Invalid_ledger error -> "Invalid Candle ledger: " ^ Candle_balance.error_to_string error
  | Refused error -> Candle_balance.error_to_string error

let equip ~now ~base_path ~keeper ~slot ~choice =
  let keeper = Keeper_id.Keeper_name.to_string keeper in
  Candle_ledger.update ~base_path (fun view ->
    let* policy = match Candle_status.configured ~base_path with
      | Candle_config.Off -> Error (Unavailable "Candle is off")
      | Candle_config.Disabled {reason} -> Error (Unavailable ("Candle is disabled: " ^ reason))
      | Candle_config.Enabled policy -> Ok policy in
    let* at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Unavailable detail) in
    let* prepared = Candle_status.prepare ~at ~half_life:policy.half_life (Candle_ledger.events view)
      |> Result.map_error (fun error -> Invalid_ledger error) in
    let state = prepared.balance in
    let* selected = Candle_balance.equip state ~keeper ~slot ~choice
      |> Result.map_error (fun error -> Refused error) in
    let changed = Candle_balance.selection state ~keeper ~slot <> choice in
    let events = if changed then [{Candle_event.at; body=Candle_event.Equipped {keeper;slot;choice}}] else [] in
    Ok (prepared.policy_events @ events, {equipment=Candle_balance.equipment selected ~keeper;changed}))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | (Candle_ledger.Read_failed _ | Candle_ledger.Event_unwritable _ | Candle_ledger.Write_failed _ | Candle_ledger.Write_locked _) as error ->
      Unavailable (Candle_ledger.update_error_to_string error_to_string error))
