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

let current ~base_path =
  match configured ~base_path with
  | (Candle_config.Off | Candle_config.Disabled _) as answer -> answer
  | Candle_config.Enabled policy ->
    (match ensure_recovered ~base_path with
       | Recovered | Locked_by_another_process -> Candle_config.Enabled policy
       | Not_recoverable reason -> Candle_config.Disabled { reason })
;;

let report_at_start ~base_path =
  match current ~base_path with
  | Candle_config.Off -> Log.Misc.info "candle: off (no candle.toml)"
  | Candle_config.Disabled { reason } -> Log.Misc.warn "candle: disabled: %s" reason
  | Candle_config.Enabled _ -> Log.Misc.info "candle: enabled (ledger recovery may await its writer lock)"
