let ( let* ) = Result.bind

type kind =
  | Money of { amount_milli : int; reason : string }
  | Item of Keeper_portrait_item.t

type receipt =
  { from_keeper : string
  ; to_keeper : string
  ; kind : kind
  ; from_balance_milli : int
  ; to_balance_milli : int
  ; gifted_at : Candle_time.t
  }

type error =
  | Off
  | Disabled of string
  | Invalid_gift of string
  | Account_invalid of Candle_balance.error
  | Gift_refused of Candle_balance.error
  | Ledger_unavailable of string
  | Invalid_time of string

let error_to_string = function
  | Off -> "Candle is off"
  | Disabled detail -> "Candle is disabled: " ^ detail
  | Invalid_gift detail -> detail
  | Account_invalid error ->
    "Candle ledger account is invalid: " ^ Candle_balance.error_to_string error
  | Gift_refused error -> Candle_balance.error_to_string error
  | Ledger_unavailable detail -> detail
  | Invalid_time detail -> detail
;;

let policy ~base_path =
  match Candle_status.configured ~base_path with
  | Candle_config.Off -> Error Off
  | Candle_config.Disabled { reason } -> Error (Disabled reason)
  | Candle_config.Enabled policy -> Ok policy
;;

let gift ~now ~base_path ~from_keeper ~to_keeper ~kind =
  let* (_ : Candle_config.policy) = policy ~base_path in
  let from_keeper = Keeper_id.Keeper_name.to_string from_keeper in
  let to_keeper = Keeper_id.Keeper_name.to_string to_keeper in
  (* The duplicate key is the stored reason, so surrounding whitespace is
     trimmed once here: "thanks" and " thanks " name one occasion. *)
  let kind =
    match kind with
    | Money { amount_milli; reason } -> Money { amount_milli; reason = String.trim reason }
    | Item _ as kind -> kind
  in
  let* () =
    if String.equal from_keeper to_keeper
    then Error (Invalid_gift "a gift needs two keepers")
    else (
      match kind with
      | Money { amount_milli; _ } when amount_milli <= 0 ->
        Error
          (Invalid_gift
             (Printf.sprintf "gift amount must be positive, got %d" amount_milli))
      | Money { reason; _ } when String.equal reason "" ->
        Error (Invalid_gift "gift reason must not be blank")
      | Money _ | Item _ -> Ok ())
  in
  Candle_ledger.update ~base_path (fun view ->
    let* current_policy = policy ~base_path in
    let* gifted_at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Invalid_time detail) in
    let* prepared =
      Candle_status.prepare ~at:gifted_at ~half_life:current_policy.half_life (Candle_ledger.events view)
      |> Result.map_error (fun error -> Account_invalid error)
    in
    let* balance, body =
      match kind with
      | Money { amount_milli; reason } ->
        let* balance =
          Candle_balance.gift prepared.balance ~at:gifted_at ~from_keeper ~to_keeper ~amount_milli
            ~reason
          |> Result.map_error (fun error -> Gift_refused error)
        in
        Ok
          ( balance
          , Candle_event.Gifted { from_keeper; to_keeper; amount_milli; reason } )
      | Item item ->
        let* balance =
          Candle_balance.gift_item prepared.balance ~at:gifted_at ~from_keeper ~to_keeper ~item
          |> Result.map_error (fun error -> Gift_refused error)
        in
        Ok (balance, Candle_event.Gifted_item { from_keeper; to_keeper; item })
    in
    let event = { Candle_event.at = gifted_at; body } in
    Ok
      ( prepared.policy_events @ [ event ]
      , { from_keeper
        ; to_keeper
        ; kind
        ; from_balance_milli = Candle_balance.balance balance ~keeper:from_keeper
        ; to_balance_milli = Candle_balance.balance balance ~keeper:to_keeper
        ; gifted_at
        } ))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | ( Candle_ledger.Read_failed _
      | Candle_ledger.Event_unwritable _
      | Candle_ledger.Write_failed _
      | Candle_ledger.Write_locked _ ) as error ->
      Ledger_unavailable (Candle_ledger.update_error_to_string error_to_string error))
;;
