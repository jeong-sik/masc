let ( let* ) = Result.bind

type receipt =
  { keeper : string
  ; balance_milli : int
  ; amount_milli : int
  ; reason : string
  ; granted_at : Candle_time.t
  }

type error =
  | Off
  | Disabled of string
  | Invalid_grant of string
  | Account_invalid of Candle_balance.error
  | Grant_refused of Candle_balance.error
  | Ledger_unavailable of string
  | Invalid_time of string

let error_to_string = function
  | Off -> "Candle is off"
  | Disabled detail -> "Candle is disabled: " ^ detail
  | Invalid_grant detail -> detail
  | Account_invalid error ->
    "Candle ledger account is invalid: " ^ Candle_balance.error_to_string error
  | Grant_refused error -> Candle_balance.error_to_string error
  | Ledger_unavailable detail -> detail
  | Invalid_time detail -> detail
;;

(* Grants read through [for_recording] instead of the appraiser-gated
   [configured] the purchase surface uses: the operator CLI runs outside
   the server, where no lane registry installs an appraiser check, and a
   gift needs no appraisal. The minted money stays durable and accounted
   while settlement still waits for its lane. *)
let policy ~base_path =
  match Candle_status.for_recording ~base_path with
  | Candle_config.Off -> Error Off
  | Candle_config.Disabled { reason } -> Error (Disabled reason)
  | Candle_config.Enabled policy -> Ok policy
;;

let grant ~now ~base_path ~keeper ~amount_milli ~reason =
  let* (_ : Candle_config.policy) = policy ~base_path in
  let keeper = Keeper_id.Keeper_name.to_string keeper in
  (* The duplicate key is the stored reason, so surrounding whitespace is
     trimmed once here: "gift" and " gift " name one occasion. *)
  let reason = String.trim reason in
  let* () =
    if amount_milli <= 0
    then Error (Invalid_grant (Printf.sprintf "grant amount must be positive, got %d" amount_milli))
    else if String.equal reason ""
    then Error (Invalid_grant "grant reason must not be blank")
    else Ok () in
  Candle_ledger.update ~base_path (fun view ->
    let* current_policy = policy ~base_path in
    let* granted_at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Invalid_time detail) in
    let* prepared = Candle_status.prepare ~at:granted_at ~half_life:current_policy.half_life (Candle_ledger.events view)
      |> Result.map_error (fun error -> Account_invalid error) in
    let* balance =
      Candle_balance.grant prepared.balance ~at:granted_at ~keeper ~amount_milli ~reason
      |> Result.map_error (fun error -> Grant_refused error)
    in
    let event =
      { Candle_event.at = granted_at
      ; body = Candle_event.Granted { keeper; amount_milli; reason }
      }
    in
    Ok
      ( prepared.policy_events @ [ event ]
      , { keeper
        ; balance_milli = Candle_balance.balance balance ~keeper
        ; amount_milli
        ; reason
        ; granted_at
        } ))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | ( Candle_ledger.Read_failed _
      | Candle_ledger.Event_unwritable _
      | Candle_ledger.Write_failed _
      | Candle_ledger.Write_locked _ ) as error ->
      Ledger_unavailable (Candle_ledger.update_error_to_string error_to_string error))
;;
