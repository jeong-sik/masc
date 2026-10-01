module Names = Map.Make (String)
module Goals = Set.Make (String)

type t =
  { balances : int Names.t
  ; last_at : Candle_time.t Names.t
  ; half_life : Candle_decay.half_life option
  ; through_at : Candle_time.t option
  ; issued : Z.t
  ; burned : Z.t
  ; paid_goals : Goals.t
  ; owned : Keeper_portrait_item.t list Names.t
  ; selections : (Keeper_portrait_item.slot * Candle_event.equipment_choice) list Names.t
  }

type error =
  | Missing_half_life
  | Clock_reversed of {previous : Candle_time.t; actual : Candle_time.t}
  | Invalid_half_life of Candle_decay.error
  | Decay_failed of {keeper : string; error : Candle_decay.error}
  | Duplicate_payment of string
  | Balance_overflow of string
  | Negative_purchase of string
  | Unowned_equipment of {keeper : string; item : Keeper_portrait_item.t}
  | Wrong_equipment_slot of Keeper_portrait_item.t
  | Already_owned of
      { keeper : string
      ; item : Keeper_portrait_item.t
      }
  | Insufficient_balance of
      { keeper : string
      ; available_milli : int
      ; required_milli : int
      }

let error_to_string = function
  | Missing_half_life -> "Candle money requires an explicit half-life record"
  | Clock_reversed {previous;actual} ->
    Printf.sprintf "Candle money clock moved backwards from %s to %s"
      (Candle_time.to_rfc3339 previous) (Candle_time.to_rfc3339 actual)
  | Invalid_half_life error -> Candle_decay.error_to_string error
  | Decay_failed {keeper;error} ->
    Printf.sprintf "Candle interval for %s is invalid: %s" keeper (Candle_decay.error_to_string error)
  | Duplicate_payment goal -> "duplicate payment for Goal " ^ goal
  | Balance_overflow keeper -> "cumulative Candle balance overflows for " ^ keeper
  | Unowned_equipment {keeper;item} -> keeper ^ " does not own " ^ Keeper_portrait_item.id item
  | Wrong_equipment_slot item -> "wrong equipment slot for " ^ Keeper_portrait_item.id item
  | Negative_purchase keeper -> "negative purchase amount for " ^ keeper
  | Already_owned { keeper; item } ->
    Printf.sprintf "%s already owns %s" keeper (Keeper_portrait_item.id item)
  | Insufficient_balance { keeper; available_milli; required_milli } ->
    Printf.sprintf
      "%s has %d milli-Candle; this item costs %d"
      keeper
      available_milli
      required_milli
;;

let empty = { balances = Names.empty; last_at = Names.empty; half_life = None; through_at = None;
  issued = Z.zero; burned = Z.zero; paid_goals = Goals.empty; owned = Names.empty; selections = Names.empty }

let half_life state = state.half_life

type supply =
  { issued_milli : string
  ; burned_milli : string
  ; circulating_milli : string
  }

let supply state =
  { issued_milli = Z.to_string state.issued
  ; burned_milli = Z.to_string state.burned
  ; circulating_milli = Z.to_string (Z.sub state.issued state.burned)
  }

let balance state ~keeper =
  match Names.find_opt keeper state.balances with
  | Some amount -> amount
  | None -> 0
;;

let owned state ~keeper =
  let items =
    match Names.find_opt keeper state.owned with
    | Some items -> items
    | None -> []
  in
  List.filter (fun item -> List.mem item items) Keeper_portrait_item.all
;;

let ( let* ) = Result.bind

let stamp state ~at =
  match state.through_at with
  | Some previous when Candle_time.compare at previous < 0 ->
    Error (Clock_reversed {previous;actual=at})
  | Some _ | None -> Ok {state with through_at=Some at}
;;

let advance_keeper state ~at ~keeper =
  match Names.find_opt keeper state.last_at with
  | None -> Ok state
  | Some since ->
    let* half_life = match state.half_life with
      | None -> Error Missing_half_life | Some half_life -> Ok half_life in
    let previous = balance state ~keeper in
    let* remaining = Candle_decay.remaining ~half_life ~since ~at ~amount_milli:previous
      |> Result.map_error (fun error -> Decay_failed {keeper;error}) in
    Ok {state with
      balances = Names.add keeper remaining state.balances;
      last_at = Names.add keeper at state.last_at;
      burned = Z.add state.burned (Z.of_int (previous - remaining))}
;;

let advance_all state ~at =
  Names.fold (fun keeper _ result ->
    let* state = result in
    advance_keeper state ~at ~keeper) state.balances (Ok state)
;;

let set_half_life state ~at half_life =
  let* (_ : int) = Candle_decay.remaining ~half_life ~since:at ~at ~amount_milli:0
    |> Result.map_error (fun error -> Invalid_half_life error) in
  let* state = stamp state ~at in
  if state.half_life = Some half_life then Ok state
  else
    let* state = advance_all state ~at in
    Ok {state with half_life=Some half_life}
;;

let credit state ~at (payment : Candle_payment.t) =
  let* () = match state.half_life with None -> Error Missing_half_life | Some _ -> Ok () in
  let* state = stamp state ~at in
  let goal = payment.identity.goal_id in
  if Goals.mem goal state.paid_goals
  then Error (Duplicate_payment goal)
  else (
    let rec add state = function
      | [] -> Ok { state with paid_goals = Goals.add goal state.paid_goals }
      | (allocation : Candle_payment.allocation) :: rest ->
        let* state = advance_keeper state ~at ~keeper:allocation.keeper in
        let current = balance state ~keeper:allocation.keeper in
        if allocation.amount_milli > max_int - current
        then Error (Balance_overflow allocation.keeper)
        else
          add {state with
            balances=Names.add allocation.keeper (current + allocation.amount_milli) state.balances;
            last_at=Names.add allocation.keeper at state.last_at;
            issued=Z.add state.issued (Z.of_int allocation.amount_milli)} rest
    in
    add state payment.allocations)
;;

let purchase state ~at ~keeper ~item ~amount_milli =
  let* () = match state.half_life with None -> Error Missing_half_life | Some _ -> Ok () in
  let* state = stamp state ~at in
  let* state = advance_keeper state ~at ~keeper in
  let items = owned state ~keeper in
  let available_milli = balance state ~keeper in
  if amount_milli < 0
  then Error (Negative_purchase keeper)
  else if List.mem item items
  then Error (Already_owned { keeper; item })
  else if amount_milli > available_milli
  then
    Error
      (Insufficient_balance { keeper; available_milli; required_milli = amount_milli })
  else
    Ok
      { state with
        balances = Names.add keeper (available_milli - amount_milli) state.balances
      ; last_at = Names.add keeper at state.last_at
      ; burned = Z.add state.burned (Z.of_int amount_milli)
      ; owned = Names.add keeper (item :: items) state.owned
      }
;;

let choices state ~keeper =
  match Names.find_opt keeper state.selections with Some choices -> choices | None -> []

let selection state ~keeper ~slot =
  match List.assoc_opt slot (choices state ~keeper) with Some choice -> choice | None -> Candle_event.Default

let equipment state ~keeper =
  List.fold_left (fun equipment (_, choice) -> match choice with
    | Candle_event.Default -> equipment
    | Candle_event.Item item -> Keeper_portrait_item.preview item equipment)
    (Keeper_portrait_look.equipment_of_name keeper) (choices state ~keeper)

let equip state ~keeper ~slot ~choice =
  let ( let* ) = Result.bind in
  let* () = match choice with
    | Candle_event.Default -> Ok ()
    | Candle_event.Item item when Keeper_portrait_item.slot item <> slot -> Error (Wrong_equipment_slot item)
    | Candle_event.Item item when not (List.mem item (owned state ~keeper)) -> Error (Unowned_equipment {keeper;item})
    | Candle_event.Item _ -> Ok () in
  let remaining = List.remove_assoc slot (choices state ~keeper) in
  let choices = match choice with
    | Candle_event.Default -> remaining
    | Candle_event.Item _ -> (slot, choice) :: remaining in
  Ok {state with selections = Names.add keeper choices state.selections}

let of_events ~at events =
  let* state = List.fold_left
    (fun result (event : Candle_event.t) ->
       Result.bind result (fun state ->
         match event.body with
         | Candle_event.Half_life_set half_life -> set_half_life state ~at:event.at half_life
         | Candle_event.Paid payment -> credit state ~at:event.at payment
         | Candle_event.Equipped e -> equip state ~keeper:e.keeper ~slot:e.slot ~choice:e.choice
         | Candle_event.Purchased p ->
           purchase state ~at:event.at ~keeper:p.keeper ~item:p.item ~amount_milli:p.amount_milli
         | Candle_event.Snapshot _
         | Candle_event.Payout_owed _
         | Candle_event.Candidates _
         | Candle_event.Unattributed _
         | Candle_event.Payout_failed _ -> Ok state))
    (Ok empty)
    events in
  let* state = stamp state ~at in
  advance_all state ~at
;;
