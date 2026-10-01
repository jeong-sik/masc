(* One in-flight appraisal per Goal. Durable obligations/candidates remain in
   the ledger; these owners only coordinate scheduling inside this process. *)
type wake_reason = Event | Pulse
type owner = {
  waiting : Candle_payout.waiting;
  mutable in_flight : bool;
  mutable rejected : bool;
  mutable event_queued : bool;
}
type runtime = {
  config : Workspace_utils_backend_setup.config;
  appraise : Candle_appraisal.runner;
  wake : Eio.Condition.t;
  pending : bool Atomic.t;
  event : bool Atomic.t;
  mutable scanning : bool;
  owners : (string, owner) Hashtbl.t;
}
let active : runtime option Atomic.t = Atomic.make None
let request_pass runtime reason =
  (match reason with Event -> Atomic.set runtime.event true | Pulse -> ());
  Atomic.set runtime.pending true;
  Eio.Condition.broadcast runtime.wake
let request reason = match Atomic.get active with None -> () | Some runtime -> request_pass runtime reason
let wake () = request Event
let pulse () = request Pulse
let report = function
  | Candle_appraise.Settled goal_id -> Log.Misc.info "candle: payout settled goal_id=%s" goal_id
  | Candle_appraise.Superseded _ -> ()
  | Candle_appraise.Rejected {goal_id;detail} -> Log.Misc.warn "candle: appraisal rejected, awaiting payout event goal_id=%s: %s" goal_id detail
  | Candle_appraise.Retry_later {goal_id;detail} -> Log.Misc.warn "candle: appraisal pending goal_id=%s: %s" goal_id detail
let launch ~sw runtime owner =
  owner.in_flight <- true;
  owner.event_queued <- false;
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Fun.protect ~finally:(fun () -> owner.in_flight <- false) (fun () ->
      let outcome = Candle_appraise.settle_one ~now:Time_compat.now ~appraise:runtime.appraise
        ~base_path:runtime.config.base_path owner.waiting in
      report outcome;
      (match outcome with
       | Candle_appraise.Settled _ ->
         Hashtbl.remove runtime.owners owner.waiting.goal_id;
         request_pass runtime Event
       | Candle_appraise.Superseded _ -> Hashtbl.remove runtime.owners owner.waiting.goal_id
       | Candle_appraise.Rejected _ -> owner.rejected <- true
       | Candle_appraise.Retry_later _ -> owner.rejected <- false);
      (* Only an event can release semantic or execution rejection. A pulse received during
         the call cannot turn a later rejection into an immediate retry loop. *)
      if owner.event_queued then request_pass runtime Event);
    `Stop_daemon)
let pass ~sw runtime reason =
  match Candle_status.current ~base_path:runtime.config.base_path with
  | Candle_config.Off | Candle_config.Disabled _ -> ()
  | Candle_config.Enabled _ ->
    let reason = match Candle_candidates.drain_once ~now:Time_compat.now runtime.config with
      | Error detail -> Log.Misc.warn "candle: preparation could not read ledger: %s" detail; reason
      | Ok outcomes -> if List.exists (function Candle_candidates.Wrote_unattributed _ -> true
          | Candle_candidates.Wrote_candidates _ | Candle_candidates.Already_prepared _
          | Candle_candidates.Superseded _ | Candle_candidates.Retry_later _ -> false) outcomes
        then Event else reason in
    match Candle_appraise.pending ~base_path:runtime.config.base_path with
    | Error detail -> Log.Misc.warn "candle: payout pass could not read ledger: %s" detail
    | Ok waiting ->
      let ids = List.map (fun (w : Candle_payout.waiting) -> w.goal_id) waiting in
      Hashtbl.filter_map_inplace (fun goal_id owner ->
        if owner.in_flight || List.mem goal_id ids then Some owner else None) runtime.owners;
      List.iter (fun (w : Candle_payout.waiting) ->
        let owner = match Hashtbl.find_opt runtime.owners w.goal_id with
          | Some owner when owner.in_flight || owner.waiting=w -> owner
          | Some _ | None ->
            let owner = {waiting=w;in_flight=false;rejected=false;event_queued=false} in
            Hashtbl.replace runtime.owners w.goal_id owner; owner in
        if owner.in_flight then (match reason with Event -> owner.event_queued <- true | Pulse -> ())
        else (
          (match reason with Event -> owner.rejected <- false | Pulse -> ());
          if not owner.rejected then launch ~sw runtime owner)) waiting
let run ~sw runtime : [ `Stop_daemon ] =
  Eio.Condition.loop_no_mutex runtime.wake (fun () ->
    if Atomic.exchange runtime.pending false then (
      let reason = if Atomic.exchange runtime.event false then Event else Pulse in
      runtime.scanning <- true;
      Fun.protect ~finally:(fun () -> runtime.scanning <- false) (fun () ->
        try pass ~sw runtime reason with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Log.Misc.error "candle: payout scheduling failed: %s" (Printexc.to_string exn)));
    None)
let start ~sw ~appraise ~(config : Workspace_utils_backend_setup.config) =
  Eio.Switch.check sw;
  let runtime = {config;appraise;wake=Eio.Condition.create ();pending=Atomic.make true;
    event=Atomic.make true;scanning=false;owners=Hashtbl.create 16} in
  let owner = Some runtime in
  if Atomic.compare_and_set active None owner then (
    Eio.Switch.on_release sw (fun () -> ignore (Atomic.compare_and_set active owner None : bool));
    Eio.Fiber.fork_daemon ~sw (fun () -> run ~sw runtime))
  else match Atomic.get active with
    | Some running -> Log.Misc.error "candle: payout worker already owns %s; refusing %s" running.config.base_path config.base_path
    | None -> Log.Misc.error "candle: payout worker start race left no owner"
module For_testing = struct
  let idle () = match Atomic.get active with
    | None -> true
    | Some runtime -> not runtime.scanning && not (Atomic.get runtime.pending)
      && not (Hashtbl.fold (fun _ owner any -> any || owner.in_flight) runtime.owners false)
end
