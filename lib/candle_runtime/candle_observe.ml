type t =
  | Off
  | Disabled of string
  | Ready of { policy : Candle_config.policy; balance : Candle_balance.t; events : Candle_event.t list }

let read ~now ~base_path =
  match Candle_status.observed_view ~now ~base_path with
  | Ok view -> Ready {policy=view.policy;balance=view.balance;events=view.events}
  | Error Candle_status.Off -> Off
  | Error (Candle_status.Disabled reason) -> Disabled reason
  | Error ((Candle_status.Invalid_time _ | Candle_status.Invalid_ledger _
      | Candle_status.Ledger_unavailable _) as error) ->
      Disabled (Candle_status.error_to_string error)

let summary = function
  | Off -> Candle_observation.Off
  | Disabled reason -> Candle_observation.Disabled {reason}
  | Ready { balance; _ } -> Candle_observation.Ready (Candle_balance.supply balance)

let balance observation ~keeper = match observation with
  | Off | Disabled _ -> None
  | Ready { balance; _ } -> Some (string_of_int (Candle_balance.balance balance ~keeper))

let equipment observation ~keeper = match observation with
  | Off -> Ok (Keeper_portrait_look.equipment_of_name keeper)
  | Disabled reason -> Error ("Candle is disabled: " ^ reason)
  | Ready { balance; _ } -> Ok (Candle_balance.equipment balance ~keeper)

let disabled_account_revision reason =
  Agent_core_sha256.(digest_string ("disabled\000" ^ reason) |> to_hex)

let event_may_affect_account_revision (event : Candle_event.t) =
  match event.body with
  | Candle_event.Half_life_set _
  | Candle_event.Paid _
  | Candle_event.Purchased _
  | Candle_event.Granted _
  | Candle_event.Gifted _
  | Candle_event.Gifted_item _
  | Candle_event.Equipped _ -> true
  | Candle_event.Snapshot _
  | Candle_event.Payout_owed _
  | Candle_event.Candidates _
  | Candle_event.Unattributed _
  | Candle_event.Payout_failed _ -> false

let event_is_relevant_to_keeper ~keeper (event : Candle_event.t) =
  match event.body with
  | Candle_event.Half_life_set _ -> true
  | Candle_event.Paid payment ->
      List.exists
        (fun (allocation : Candle_payment.allocation) ->
           String.equal allocation.keeper keeper)
        payment.allocations
  | Candle_event.Purchased purchase -> String.equal purchase.keeper keeper
  | Candle_event.Granted granted -> String.equal granted.keeper keeper
  | Candle_event.Gifted gift ->
      String.equal gift.from_keeper keeper || String.equal gift.to_keeper keeper
  | Candle_event.Gifted_item gift ->
      String.equal gift.from_keeper keeper || String.equal gift.to_keeper keeper
  | Candle_event.Equipped choice -> String.equal choice.keeper keeper
  | Candle_event.Snapshot _
  | Candle_event.Payout_owed _
  | Candle_event.Candidates _
  | Candle_event.Unattributed _
  | Candle_event.Payout_failed _ -> false

let ready_account_revision_reader ~events ~policy ~balance =
  let encoded_events =
    events
    |> List.filter_map (fun event ->
         if event_may_affect_account_revision event
         then Some (event, Candle_event.to_yojson event)
         else None)
  in
  let half_life = match policy.Candle_config.half_life with
    | Candle_decay.Off -> `String "off"
    | Candle_decay.Hours hours -> `Int hours in
  let pricing_tail = match policy.Candle_config.pricing with
    | Candle_config.Fixed -> []
    | Candle_config.Supply_scaled p ->
      [ `Assoc
          [ "mode", `String "supply_scaled"
          ; "target_per_keeper_milli", `Int p.target_per_keeper_milli
          ; "min_permille", `Int p.min_permille
          ; "max_permille", `Int p.max_permille
          ; ( "rounding"
            , `String
                (match p.rounding with
                 | Candle_math.Floor -> "down"
                 | Candle_math.Ceil -> "up") )
          ] ] in
  let min_active_balance_milli =
    Candle_config.min_active_balance_milli policy.Candle_config.pricing
  in
  let summary =
    Candle_balance.supply_summary ~min_active_balance_milli balance
  in
  let catalog = Keeper_portrait_item.all |> List.map (fun item ->
    let price =
      match
        Candle_config.effective_price
          policy
          ~total_supply_milli:summary.total_supply_milli
          ~active_keepers:summary.active_keepers
          item
      with
      | Candle_config.Unpriced -> `Null
      | Candle_config.Priced amount -> `String (string_of_int amount)
    in
    `List [`String (Keeper_portrait_item.id item); price]) in
  fun ~keeper ->
    let facts =
      List.filter_map
        (fun (event, json) ->
           if event_is_relevant_to_keeper ~keeper event then Some json else None)
        encoded_events
    in
    let owned =
      Candle_balance.owned balance ~keeper
      |> List.map (fun item -> `String (Keeper_portrait_item.id item))
    in
    let account =
      `List ([ half_life; `List facts; `List owned; `List catalog ] @ pricing_tail)
    in
    Agent_core_sha256.(digest_string ("ready\000" ^ Yojson.Safe.to_string account) |> to_hex)

let ready_account_revision ~events ~policy ~balance ~keeper =
  ready_account_revision_reader ~events ~policy ~balance ~keeper

let account_revision_reader = function
  | Off -> (fun ~keeper:_ -> None)
  | Disabled reason ->
      let rev = Some (disabled_account_revision reason) in
      (fun ~keeper:_ -> rev)
  | Ready { policy; balance; events } ->
      let reader = ready_account_revision_reader ~events ~policy ~balance in
      (fun ~keeper -> Some (reader ~keeper))

let account_revision observation ~keeper =
  account_revision_reader observation ~keeper
