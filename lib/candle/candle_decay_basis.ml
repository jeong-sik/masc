type keeper = { since : Candle_time.t; amount_milli : int }

type decay =
  | No_decaying_balance
  | Decaying of { half_life : Candle_decay.half_life; keepers : (string * keeper) list }

type t = { issued_milli : Z.t; burned_milli : Z.t; decay : decay }

open Result.Syntax

let of_events events =
  let* replayed = Candle_balance.replay events in
  let supply = Candle_balance.supply replayed in
  let keepers =
    List.map (fun (name, since, amount_milli) -> (name, { since; amount_milli }))
      (Candle_balance.decaying_balances replayed)
  in
  let* decay =
    match keepers, Candle_balance.half_life replayed with
    | [], (None | Some _) -> Ok No_decaying_balance
    | _ :: _, Some half_life -> Ok (Decaying { half_life; keepers })
    | _ :: _, None -> Error Candle_balance.Missing_half_life
  in
  Ok
    { issued_milli = Z.of_string supply.issued_milli
    ; burned_milli = Z.of_string supply.burned_milli
    ; decay
    }

let balance_at t ~keeper ~at =
  match t.decay with
  | No_decaying_balance -> Ok 0
  | Decaying { half_life; keepers } -> (
      match List.assoc_opt keeper keepers with
      | None -> Ok 0
      | Some { since; amount_milli } -> Candle_decay.remaining ~half_life ~since ~at ~amount_milli)

let supply_at t ~at =
  let* lost =
    match t.decay with
    | No_decaying_balance -> Ok Z.zero
    | Decaying { half_life; keepers } ->
        List.fold_left
          (fun lost (_, { since; amount_milli }) ->
            let* lost = lost in
            let* remaining = Candle_decay.remaining ~half_life ~since ~at ~amount_milli in
            Ok (Z.add lost (Z.of_int (amount_milli - remaining))))
          (Ok Z.zero) keepers
  in
  let burned = Z.add t.burned_milli lost in
  Ok
    { Candle_balance.issued_milli = Z.to_string t.issued_milli
    ; burned_milli = Z.to_string burned
    ; circulating_milli = Z.to_string (Z.sub t.issued_milli burned)
    }

let half_life_to_json = function
  | Candle_decay.Off -> `String "off"
  | Candle_decay.Hours hours -> `Int hours

let half_life_of_json = function
  | `String "off" -> Ok Candle_decay.Off
  | `Int hours -> Candle_decay.half_life_of_hours hours
  | _ -> Error "Candle half-life must be \"off\" or a positive number of hours"

let keeper_to_json (name, { since; amount_milli }) =
  `Assoc
    [ "name", `String name
    ; "since", Candle_time.to_yojson since
    ; "amount_milli", `String (string_of_int amount_milli)
    ]

let amount_of_json json =
  let* amount = Candle_observation.amount_of_json json in
  Ok (Z.of_string amount)

let int_amount_of_json json =
  let* amount = Candle_observation.amount_of_json json in
  match int_of_string_opt amount with
  | Some amount -> Ok amount
  | None -> Error "Candle balance does not fit a machine integer"

let keeper_of_json json =
  let context = "Candle decay basis Keeper" in
  let* fields = Candle_json.object_fields ~context json in
  let* name, fields = Candle_json.field ~context "name" Candle_json.as_non_blank fields in
  let* since, fields = Candle_json.field ~context "since" Candle_time.of_yojson fields in
  let* amount_milli, fields = Candle_json.field ~context "amount_milli" int_amount_of_json fields in
  let* () = Candle_json.finish ~context fields in
  Ok (name, { since; amount_milli })

let to_json t =
  let half_life, keepers =
    match t.decay with
    | No_decaying_balance -> `Null, []
    | Decaying { half_life; keepers } -> half_life_to_json half_life, keepers
  in
  `Assoc
    [ "issued_milli", `String (Z.to_string t.issued_milli)
    ; "burned_milli", `String (Z.to_string t.burned_milli)
    ; "half_life", half_life
    ; "keepers", `List (List.map keeper_to_json keepers)
    ]

let of_json json =
  let context = "Candle decay basis" in
  let* fields = Candle_json.object_fields ~context json in
  let* issued_milli, fields = Candle_json.field ~context "issued_milli" amount_of_json fields in
  let* burned_milli, fields = Candle_json.field ~context "burned_milli" amount_of_json fields in
  let* half_life, fields =
    Candle_json.field ~context "half_life" (Candle_json.as_nullable half_life_of_json) fields
  in
  let* keepers, fields = Candle_json.field ~context "keepers" (Candle_json.as_list keeper_of_json) fields in
  let* () = Candle_json.finish ~context fields in
  let names = List.map fst keepers in
  let* () =
    if List.equal String.equal (List.sort_uniq String.compare names) names then Ok ()
    else Error "Candle decay basis Keepers must be in name order without repeats"
  in
  let* decay =
    match half_life, keepers with
    | None, [] -> Ok No_decaying_balance
    | Some half_life, _ :: _ -> Ok (Decaying { half_life; keepers })
    | None, _ :: _ -> Error "Candle decay basis has balances without a half-life"
    | Some _, [] -> Error "Candle decay basis has a half-life without balances"
  in
  let held =
    match decay with
    | No_decaying_balance -> Z.zero
    | Decaying { keepers; _ } ->
        List.fold_left (fun held (_, { amount_milli; _ }) -> Z.add held (Z.of_int amount_milli))
          Z.zero keepers
  in
  if Z.equal (Z.sub issued_milli burned_milli) held then Ok { issued_milli; burned_milli; decay }
  else Error "Candle decay basis wallets do not hold what was issued less what was burned"
