module Names = Map.Make (String)
module Goals = Set.Make (String)

type t =
  { balances : int Names.t
  ; paid_goals : Goals.t
  ; owned : Keeper_portrait_item.t list Names.t
  ; selections : (Keeper_portrait_item.slot * Candle_event.equipment_choice) list Names.t
  }

type error =
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

let empty = { balances = Names.empty; paid_goals = Goals.empty; owned = Names.empty; selections = Names.empty }

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

let credit state (payment : Candle_payment.t) =
  let goal = payment.identity.goal_id in
  if Goals.mem goal state.paid_goals
  then Error (Duplicate_payment goal)
  else (
    let rec add balances = function
      | [] -> Ok { state with balances; paid_goals = Goals.add goal state.paid_goals }
      | (allocation : Candle_payment.allocation) :: rest ->
        let current =
          match Names.find_opt allocation.keeper balances with
          | Some amount -> amount
          | None -> 0
        in
        if allocation.amount_milli > max_int - current
        then Error (Balance_overflow allocation.keeper)
        else
          add
            (Names.add allocation.keeper (current + allocation.amount_milli) balances)
            rest
    in
    add state.balances payment.allocations)
;;

let purchase state ~keeper ~item ~amount_milli =
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

let of_events events =
  List.fold_left
    (fun result (event : Candle_event.t) ->
       Result.bind result (fun state ->
         match event.body with
         | Candle_event.Paid payment -> credit state payment
         | Candle_event.Equipped e -> equip state ~keeper:e.keeper ~slot:e.slot ~choice:e.choice
         | Candle_event.Purchased p ->
           purchase state ~keeper:p.keeper ~item:p.item ~amount_milli:p.amount_milli
         | Candle_event.Snapshot _
         | Candle_event.Payout_owed _
         | Candle_event.Candidates _
         | Candle_event.Unattributed _
         | Candle_event.Payout_failed _ -> Ok state))
    (Ok empty)
    events
;;
