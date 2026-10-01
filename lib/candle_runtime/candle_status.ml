(* See candle_status.mli. *)

(* Base paths whose ledger this process has already recovered. The mutex guards
   the table only; the recovery itself runs outside it, because it blocks and a
   fiber must not hold a mutex across that. Two first callers may both recover:
   the ledger's own lock makes the second one find nothing to cut. *)
let recovered : (string, unit) Hashtbl.t = Hashtbl.create 4
let recovered_mutex = Stdlib.Mutex.create ()

let already_recovered ~base_path =
  Stdlib.Mutex.protect recovered_mutex (fun () -> Hashtbl.mem recovered base_path)
;;

let remember_recovered ~base_path =
  Stdlib.Mutex.protect recovered_mutex (fun () -> Hashtbl.replace recovered base_path ())
;;

type recovery =
  | Recovered
  | Locked_by_another_process
  | Not_recoverable of string

let ensure_recovered ~base_path =
  if already_recovered ~base_path
  then Recovered
  else (
    match Candle_ledger.recover_at_start ~base_path with
    | Ok (_ : Candle_ledger.view) ->
      remember_recovered ~base_path;
      Recovered
    | Error (Candle_ledger.Locked _) ->
      (* Another process is writing right now. That passes, and disabling Candle
         for it would let a Goal pass with no Snapshot, which no later step can
         undo. Candle stays enabled: the step that follows asks the ledger for
         the same lock and refuses the transition while it is held. Nothing is
         remembered, so the next call recovers. *)
      Locked_by_another_process
    | Error ((Candle_ledger.Store_failed _ | Candle_ledger.Row_rejected _) as error) ->
      Not_recoverable (Candle_ledger.read_error_to_string error))
;;

(* Installed by the server, so this library never depends on lane registry code.
   Uninstalled is an observable disabled state, never implicit permission. *)
let appraiser_check = Atomic.make (fun () -> Error "candle_appraiser availability is not installed")
let install_appraiser_check check = Atomic.set appraiser_check check

let configured ~base_path =
  match Candle_config.load ~base_path with
  | (Candle_config.Off | Candle_config.Disabled _) as answer -> answer
  | Candle_config.Enabled policy ->
    (match (Atomic.get appraiser_check) () with
     | Error reason -> Candle_config.Disabled { reason }
     | Ok () -> Candle_config.Enabled policy)
;;

let ( let* ) = Result.bind

type prepared = {
  events : Candle_event.t list;
  policy_events : Candle_event.t list;
  balance : Candle_balance.t;
}
let prepare ~at ~half_life events =
  let* balance = Candle_balance.of_events ~at events in
  if Candle_balance.half_life balance = Some half_life then
    Ok {events;policy_events=[];balance}
  else
    let* balance = Candle_balance.set_half_life balance ~at half_life in
    let policy_events = [{Candle_event.at;body=Candle_event.Half_life_set half_life}] in
    Ok {events=events @ policy_events;policy_events;balance}

type view = {
  policy : Candle_config.policy;
  at : Candle_time.t;
  events : Candle_event.t list;
  balance : Candle_balance.t;
}
type error =
  | Off
  | Disabled of string
  | Invalid_time of string
  | Invalid_ledger of Candle_balance.error
  | Ledger_unavailable of string
let error_to_string = function
  | Off -> "Candle is off"
  | Disabled reason -> "Candle is disabled: " ^ reason
  | Invalid_time detail | Ledger_unavailable detail -> detail
  | Invalid_ledger error -> Candle_balance.error_to_string error

let enabled ~base_path = match configured ~base_path with
  | Candle_config.Off -> Error Off
  | Candle_config.Disabled {reason} -> Error (Disabled reason)
  | Candle_config.Enabled policy -> Ok policy

let observed_view ~now ~base_path =
  let* policy = enabled ~base_path in
  let* ledger = Candle_ledger.read ~base_path
    |> Result.map_error (fun error -> Ledger_unavailable (Candle_ledger.read_error_to_string error)) in
  let* at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Invalid_time detail) in
  let events = Candle_ledger.events ledger in
  let* balance = Candle_balance.of_events ~at events
    |> Result.map_error (fun error -> Invalid_ledger error) in
  Ok {policy;at;events;balance}

let current_view ~now ~base_path =
  let* (_ : Candle_config.policy) = enabled ~base_path in
  Candle_ledger.update ~base_path (fun ledger ->
    let* policy = enabled ~base_path in
    let* at = Candle_stamp.at ~now |> Result.map_error (fun detail -> Invalid_time detail) in
    let* prepared = prepare ~at ~half_life:policy.half_life (Candle_ledger.events ledger)
      |> Result.map_error (fun error -> Invalid_ledger error) in
    Ok (prepared.policy_events, {policy;at;events=prepared.events;balance=prepared.balance}))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | (Candle_ledger.Read_failed _ | Candle_ledger.Event_unwritable _
      | Candle_ledger.Write_failed _ | Candle_ledger.Write_locked _) as error ->
      Ledger_unavailable (Candle_ledger.update_error_to_string error_to_string error))

let current ~base_path =
  match configured ~base_path with
  | (Candle_config.Off | Candle_config.Disabled _) as answer -> answer
  | Candle_config.Enabled policy ->
    match ensure_recovered ~base_path with
    | Not_recoverable reason -> Candle_config.Disabled {reason}
    | Recovered | Locked_by_another_process -> Candle_config.Enabled policy

let report_at_start ~base_path =
  match current ~base_path with
  | Candle_config.Off -> Log.Misc.info "candle: off (no candle.toml)"
  | Candle_config.Disabled { reason } -> Log.Misc.warn "candle: disabled: %s" reason
  | Candle_config.Enabled _ -> Log.Misc.info "candle: enabled (ledger recovery may await its writer lock)"
