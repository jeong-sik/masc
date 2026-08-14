(** RFC-0379 monitor runner. *)

let sweep_interval_sec = 1.0
let probe_timeout_sec = 1.0
let unmet_probe_interval_sec = 2.0
let met_probe_interval_sec = 10.0

type baseline =
  { observation : Monitor_domain.observation
  ; next_probe_at : float
  }

let observe_reachability ~net ~clock ~host ~port =
  match
    Eio.Time.with_timeout clock probe_timeout_sec (fun () ->
      Eio.Switch.run
      @@ fun sw ->
      match Eio.Net.getaddrinfo_stream net host ~service:(string_of_int port) with
      | [] -> Error `Timeout
      | addr :: _ ->
        let flow = Eio.Net.connect ~sw net addr in
        Eio.Flow.close flow;
        Ok ())
  with
  | Ok () -> Monitor_domain.Reachable
  | Error `Timeout -> Monitor_domain.Unreachable
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    let bt = Printexc.get_raw_backtrace () in
    Printexc.raise_with_backtrace exn bt
  | exception _ -> Monitor_domain.Unreachable
;;

let observe_file ~path =
  match Unix.stat path with
  | stat ->
    Some
      (Monitor_domain.File_snapshot
         { mtime = stat.Unix.st_mtime; inode = stat.Unix.st_ino })
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Some Monitor_domain.File_absent
  | exception Unix.Unix_error (code, _, _) ->
    Log.Server.warn
      "monitor_runner: stat %s failed (%s); skipping this probe"
      path
      (Unix.error_message code);
    None
;;

let observe ~net ~clock (trigger : Monitor_domain.trigger) =
  match trigger with
  | Monitor_domain.Port_up { host; port } | Monitor_domain.Port_down { host; port }
    -> Some (observe_reachability ~net ~clock ~host ~port)
  | Monitor_domain.File_changed { path } -> observe_file ~path
;;

(* Resting means the watched edge cannot be the next transition: a Port_up
   monitor that already sees the port up has nothing to wait for except a
   later drop, so it probes slowly. Files have no resting state. *)
let probe_interval ~trigger ~(observation : Monitor_domain.observation) =
  match trigger, observation with
  | Monitor_domain.Port_up _, Monitor_domain.Reachable
  | Monitor_domain.Port_down _, Monitor_domain.Unreachable ->
    met_probe_interval_sec
  | Monitor_domain.Port_up _, _
  | Monitor_domain.Port_down _, _
  | Monitor_domain.File_changed _, _ -> unmet_probe_interval_sec
;;

let fire ~base_path (record : Monitor_domain.t) ~from_ ~to_ ~now =
  let wake =
    { Keeper_event_queue.mw_monitor_id = record.id
    ; mw_from = from_
    ; mw_to = to_
    ; mw_observed_at = now
    ; mw_payload = record.payload
    }
  in
  let stimulus =
    { Keeper_event_queue.post_id = Keeper_event_queue.monitor_fired_post_id wake
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = now
    ; payload = Keeper_event_queue.Monitor_fired wake
    }
  in
  match
    try
      Keeper_registry_event_queue.enqueue_durable_result
        ~base_path
        record.keeper
        stimulus
    with
    | Eio.Cancel.Cancelled _ as exn ->
      let bt = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace exn bt
    | exn -> Error (Printexc.to_string exn)
  with
  | Error reason ->
    (* Baseline stays uncommitted upstream, so the next sweep observes the
       same edge and retries; the queue's identity projection collapses the
       repeat into one pending wake. *)
    Log.Server.error
      "monitor_runner: wake enqueue failed monitor_id=%s keeper=%s: %s"
      record.id
      record.keeper
      reason;
    false
  | Ok () ->
    (match Keeper_monitor_store.record_fire ~base_path ~id:record.id with
     | Ok Keeper_monitor_store.Fire_recorded_removed ->
       Log.Server.info
         "monitor_runner: fired and consumed monitor_id=%s keeper=%s %s->%s"
         record.id
         record.keeper
         (Monitor_domain.observation_label from_)
         (Monitor_domain.observation_label to_)
     | Ok Keeper_monitor_store.Fire_recorded_retained ->
       Log.Server.info
         "monitor_runner: fired monitor_id=%s keeper=%s %s->%s (%d/%d)"
         record.id
         record.keeper
         (Monitor_domain.observation_label from_)
         (Monitor_domain.observation_label to_)
         (record.fired_count + 1)
         record.max_fires
     | Error reason ->
       Log.Server.warn
         "monitor_runner: fire recorded in queue but not in store monitor_id=%s: %s"
         record.id
         reason);
    true
;;

let sweep ~net ~clock ~base_path ~(baselines : (string, baseline) Hashtbl.t) ~now =
  match Keeper_monitor_store.remove_expired ~base_path ~now with
  | Error reason -> Log.Server.warn "monitor_runner: expiry sweep failed: %s" reason
  | Ok expired ->
    List.iter
      (fun id ->
         Hashtbl.remove baselines id;
         Log.Server.info "monitor_runner: expired monitor_id=%s" id)
      expired;
    (match Keeper_monitor_store.load ~base_path with
     | Error reason -> Log.Server.warn "monitor_runner: store load failed: %s" reason
     | Ok records ->
       let live_ids = List.map (fun (r : Monitor_domain.t) -> r.id) records in
       Hashtbl.iter
         (fun id _ ->
            if not (List.mem id live_ids) then Hashtbl.remove baselines id)
         (Hashtbl.copy baselines);
       List.iter
         (fun (record : Monitor_domain.t) ->
            let due =
              match Hashtbl.find_opt baselines record.id with
              | None -> true
              | Some { next_probe_at; _ } -> Float.compare now next_probe_at >= 0
            in
            if due
            then (
              match observe ~net ~clock record.trigger with
              | None -> ()
              | Some current ->
                let prev =
                  Option.map
                    (fun { observation; _ } -> observation)
                    (Hashtbl.find_opt baselines record.id)
                in
                let commit () =
                  Hashtbl.replace
                    baselines
                    record.id
                    { observation = current
                    ; next_probe_at =
                        now +. probe_interval ~trigger:record.trigger ~observation:current
                    }
                in
                (match Monitor_domain.decide record.trigger ~prev ~current with
                 | Monitor_domain.Hold -> commit ()
                 | Monitor_domain.Fire { from_; to_ } ->
                   if fire ~base_path record ~from_ ~to_ ~now then commit ())))
         records)
;;

let run ~net ~clock ~base_path () =
  let baselines : (string, baseline) Hashtbl.t = Hashtbl.create 16 in
  let rec loop () =
    (try sweep ~net ~clock ~base_path ~baselines ~now:(Time_compat.now ()) with
     | Eio.Cancel.Cancelled _ as exn ->
       let bt = Printexc.get_raw_backtrace () in
       Printexc.raise_with_backtrace exn bt
     | exn ->
       Log.Server.warn "monitor_runner: sweep crashed: %s" (Printexc.to_string exn));
    Eio.Time.sleep clock sweep_interval_sec;
    loop ()
  in
  loop ()
;;
