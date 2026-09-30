(* See candle_payout_worker.mli. *)

type runtime =
  { config : Workspace_utils_backend_setup.config
  ; wake : Eio.Condition.t
  ; pending : bool Atomic.t
  }

let active : runtime option Atomic.t = Atomic.make None

let request_pass runtime =
  Atomic.set runtime.pending true;
  Eio.Condition.broadcast runtime.wake
;;

let wake () =
  match Atomic.get active with
  | None -> ()
  | Some runtime -> request_pass runtime
;;

let pass runtime =
  try
    match Candle_candidates.drain_once ~now:Time_compat.now runtime.config with
    | Ok (_ : Candle_candidates.outcome list) -> ()
    | Error detail -> Log.Misc.warn "candle: payout pass could not read the ledger: %s" detail
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exn -> Log.Misc.error "candle: payout pass failed: %s" (Printexc.to_string exn)
;;

let run runtime : [ `Stop_daemon ] =
  Eio.Condition.loop_no_mutex runtime.wake (fun () ->
    if Atomic.exchange runtime.pending false
    then (
      pass runtime;
      None)
    else None)
;;

let start ~sw ~(config : Workspace_utils_backend_setup.config) =
  Eio.Switch.check sw;
  let runtime = { config; wake = Eio.Condition.create (); pending = Atomic.make true } in
  let owner = Some runtime in
  if Atomic.compare_and_set active None owner
  then (
    (* fire-and-forget: the swap fails only if a later start already owns [active]. *)
    Eio.Switch.on_release sw (fun () -> ignore (Atomic.compare_and_set active owner None : bool));
    Eio.Fiber.fork_daemon ~sw (fun () -> run runtime))
  else (
    match Atomic.get active with
    | Some running when String.equal running.config.base_path config.base_path ->
      Log.Misc.warn "candle: payout worker already started for base path %s" config.base_path
    | Some running ->
      Log.Misc.error
        "candle: payout worker already owns base path %s; refusing second base path %s"
        running.config.base_path
        config.base_path
    | None -> Log.Misc.error "candle: payout worker start race left no visible owner")
;;
