module Candidate = Keeper_board_attention_candidate
module Partition = Keeper_board_attention_partition
module Jev = Typesafeai_board_attention

let ( let* ) = Result.bind

let report candidate detail =
  Log.Keeper.warn ~keeper_name:candidate.Candidate.keeper_name
    "board attention event fanout candidate=%s: %s" candidate.candidate_id detail

let wake candidate ~base_path =
  match Keeper_board_attention_worker_wake.request
          ~base_path ~keeper_name:candidate.Candidate.keeper_name with
  | Ok _ -> ()
  | Error detail -> report candidate detail

let claim ~base_path ~worker_epoch candidate =
  let keeper_name = candidate.Candidate.keeper_name in
  let* _ = Partition.ensure_roots ~base_path ~keeper_name [candidate] in
  let* partitions = Partition.load ~base_path ~keeper_name in
  match List.find_opt (fun (p : Partition.t) ->
    String.equal p.candidate_id candidate.candidate_id
    && match p.state with Partition.Ready -> true | _ -> false) partitions with
  | None -> Ok None
  | Some partition ->
    Partition.claim_ready_exact ~now:(Time_compat.now ()) ~worker_epoch
      ~base_path ~keeper_name ~partition_id:partition.partition_id
      ~generation:partition.generation

let confirm_completed ~base_path (transition : Partition.exact_transition) =
  match transition.write_outcome with
  | Partition.Fsync_completed -> Ok transition.partition
  | Partition.Visible_sync_unconfirmed _ ->
    let* confirmed = Partition.confirm_completed ~base_path ~partition:transition.partition in
    match confirmed.write_outcome with
    | Partition.Fsync_completed -> Ok confirmed.partition
    | Partition.Visible_sync_unconfirmed detail -> Error detail

let complete ~base_path ~worker_epoch candidate partition (judged : Jev.judged) verdict =
  let judgment : Candidate.judgment =
    { verdict
    ; slot_id = judged.provenance.answering_model_id
    ; source = Candidate.Vendor_system_one judged.provenance
    ; judged_at = Time_compat.now ()
    }
  in
  let* transition = Partition.complete ~now:(Time_compat.now ()) ~worker_epoch
    ~base_path ~partition ~item:{ candidate_id = candidate.Candidate.candidate_id; judgment } in
  let* completed = confirm_completed ~base_path transition in
  match verdict.Keeper_board_attention_judgment.decision with
  | Keeper_board_attention_judgment.Relevant ->
    ignore (Keeper_registry.wakeup_running ~intent:Keeper_registry.Attention_result
      ~base_path candidate.keeper_name);
    Ok ()
  | Keeper_board_attention_judgment.Not_relevant ->
    let* _ = Candidate.apply_judgment_and_deliver ~base_path
      ~keeper_name:candidate.keeper_name ~candidate_id:candidate.candidate_id ~judgment in
    let* _ = Partition.settle ~now:(Time_compat.now ()) ~base_path ~partition:completed in
    Ok ()

let run ~clock ~base_path ~wake ~admit candidates =
  let worker_epoch = Partition.Worker_epoch.generate () in
  let claimed = ref [] in
  let release () =
    List.iter (fun (candidate, partition) ->
      (match Partition.defer ~worker_epoch ~base_path ~partition with
       | Ok _ -> ()
       | Error detail -> report candidate detail);
      wake candidate ~base_path) !claimed;
    claimed := []
  in
  let finish () =
    let eligible = List.filter_map (fun candidate ->
      match Typesafeai_config.board_attention_destinations ~keeper_id:candidate.Candidate.keeper_name with
      | Error _ -> wake candidate ~base_path; None
      | Ok destinations ->
        match claim ~base_path ~worker_epoch candidate with
        | Ok (Some partition) ->
          claimed := (candidate, partition) :: !claimed;
          Some (candidate, destinations)
        | Ok None -> wake candidate ~base_path; None
        | Error detail -> report candidate detail; wake candidate ~base_path; None) candidates in
    let eligible = List.filter (fun (candidate, _) -> admit candidate) eligible in
    match eligible with
    | [] -> ()
    | (_, destinations) :: _ ->
      let started = Time_compat.now () in
      let answers = Jev.judge_candidates ~clock ~destinations ~candidates:(List.map fst eligible) () in
      Log.Keeper.info "board_attention_event_fanout candidates=%d duration_ms=%.0f outcome=%s"
        (List.length eligible) ((Time_compat.now () -. started) *. 1000.)
        (match answers with Ok _ -> "answered" | Error _ -> "failed");
      (match answers with
       | Error detail -> List.iter (fun (candidate, _) -> report candidate detail) !claimed
       | Ok answers ->
         List.iter (fun (candidate, answer) ->
           match answer with
           | Error detail -> report candidate detail
           | Ok ({ Jev.assessment = Jev.Needs_review _; _ }) -> ()
           | Ok ({ Jev.assessment = Jev.Decided verdict; confidence; _ } as judged) ->
             if Float.compare confidence (Typesafeai_config.board_attention_confidence_floor ()) >= 0 then
               match List.find_opt (fun (c, _) -> String.equal c.Candidate.candidate_id candidate.Candidate.candidate_id) !claimed with
               | None -> ()
               | Some (_, partition) ->
                 (match complete ~base_path ~worker_epoch candidate partition judged verdict with
                  | Error detail ->
                    report candidate detail;
                    (* Completion may already be durable. The owner rechecks
                       the ledger before delivery, including fsync confirmation. *)
                    ignore (Keeper_registry.wakeup_running
                      ~intent:Keeper_registry.Attention_result ~base_path candidate.keeper_name)
                  | Ok () ->
                    claimed := List.filter (fun (c, _) -> not (String.equal c.Candidate.candidate_id candidate.candidate_id)) !claimed)) answers)
  in
  match finish () with
  | () -> release ()
  | exception (Eio.Cancel.Cancelled _ as exn) ->
    Eio.Cancel.protect release;
    raise exn
  | exception exn ->
    List.iter (fun (candidate, _) -> report candidate (Printexc.to_string exn)) !claimed;
    release ()

;;

let dispatch ~sw ~clock ~base_path candidates =
  match candidates with
  | [] -> ()
  | _ -> Eio.Fiber.fork ~sw (fun () -> run ~clock ~base_path ~wake ~admit:(fun _ -> true) candidates)
;;

let enqueue_discoverable_post ~sw ~clock ~(config : Workspace.config) signal =
  Eio.Switch.check sw;
  let base_path = config.base_path in
  let entries = Keeper_registry.all ~base_path ()
    |> List.filter (fun (entry : Keeper_registry.registry_entry) ->
      not (Keeper_state_machine.is_terminal entry.phase)) in
  let candidate_id (entry : Keeper_registry.registry_entry) =
    Candidate.candidate_id_of_signal ~keeper_name:entry.name signal in
  (* Reserving touches only this finite in-memory registry snapshot. No meta
     read or ledger I/O runs under the admission mutex. *)
  let token = Keeper_board_attention_admission.reserve_batch ~base_path
      ~candidate_ids:(List.map candidate_id entries) in
  let initial, established = List.partition (fun (entry : Keeper_registry.registry_entry) ->
      Float.equal entry.board_cursor_ts 0.0) entries in
  let current_entry (entry : Keeper_registry.registry_entry) =
    match Keeper_registry.get ~base_path entry.name with
    | Some current when
        Keeper_lane.Id.equal (Keeper_lane.id current.lane) (Keeper_lane.id entry.lane)
        && not (Keeper_state_machine.is_terminal current.phase) -> Some current
    | Some _ | None -> None in
  let recorded = ref [] in
  let released = Atomic.make false in
  let release_hook = ref Eio.Switch.null_hook in
  let cleanup () =
    if Atomic.compare_and_set released false true then (
      Eio.Switch.remove_hook !release_hook;
      Keeper_board_attention_admission.release token;
      List.iter (fun (entry : Keeper_registry.registry_entry) ->
      let has_current_owner = match Keeper_registry.get ~base_path entry.name with
        | Some current -> not (Keeper_state_machine.is_terminal current.phase)
        | None -> false in
      if Keeper_board_attention_admission.owns token (candidate_id entry)
         && has_current_owner then
        match Keeper_board_attention_worker_wake.request ~base_path ~keeper_name:entry.name with
        | Ok _ -> ()
        | Error detail -> Log.Keeper.warn ~keeper_name:entry.name
            "board event admission wake failed: %s" detail) entries)
  in
  let failure ~keeper_name ~phase =
    Otel_metric_store.inc_counter Keeper_metrics.(to_string KeepaliveSignalFailures)
      ~labels:["keeper", keeper_name; "phase", phase] () in
  let record ~initial entries = List.iter (fun (entry : Keeper_registry.registry_entry) ->
    try
    if Keeper_board_attention_admission.owns token (candidate_id entry)
       && Option.is_some (current_entry entry) then
      match Keeper_meta_store.read_effective_meta config entry.name with
      | Error detail ->
          failure ~keeper_name:entry.name ~phase:"board_meta_read";
          Log.Keeper.warn ~keeper_name:entry.name "board event metadata unavailable: %s" detail
      | Ok None ->
          failure ~keeper_name:entry.name ~phase:"board_meta_missing";
          Log.Keeper.warn ~keeper_name:entry.name "board event metadata missing"
      | Ok (Some meta) ->
        (* Metadata I/O can yield. A same-name replacement or withdrawn lane
           cannot inherit the captured owner's admission. *)
        match current_entry entry with
        | None -> ()
        | Some current ->
        let paused = meta.paused || current.phase = Keeper_state_machine.Paused in
        if initial || not paused then
        match Keeper_board_audience.route_for_keeper
                ~audience:Keeper_board_audience.Discoverable ~meta ~signal with
        | Keeper_world_observation_board_signal.Available Keeper_board_audience.Judge_discoverable ->
          let candidate = Candidate.of_board_signal ~meta ~recorded_at:(Time_compat.now ()) signal in
          let observe persistence = Otel_metric_store.inc_counter
            Keeper_metrics.(to_string BoardSignalAttentionCandidateTotal)
            ~labels:["keeper", meta.name; "kind", "post_created";
                     "audience", "discoverable"; "persistence", persistence] () in
          let include_pending persisted =
            if not paused then
              match Candidate.status_view persisted.Candidate.status with
              | Candidate.Direct_resumable (Candidate.Resumable_pending _)
              | Candidate.Requeued_resumable { resumable = Candidate.Resumable_pending _; _ } ->
                  recorded := persisted :: !recorded
              | Candidate.Direct_resumable (Candidate.Resumable_judged _ | Candidate.Resumable_consumed _)
              | Candidate.Requeued_resumable
                  { resumable = (Candidate.Resumable_judged _ | Candidate.Resumable_consumed _); _ }
              | Candidate.Suspended_quarantine _ -> () in
          (match Candidate.record ~base_path candidate with
           | Candidate.Recorded persisted -> observe "recorded"; include_pending persisted
           | Candidate.Duplicate persisted -> observe "duplicate"; include_pending persisted
           | Candidate.Record_error detail ->
               failure ~keeper_name:entry.name ~phase:"board_attention_candidate_record";
               report candidate detail)
        | Keeper_world_observation_board_signal.Available Keeper_board_audience.Ignore -> ()
        | Keeper_world_observation_board_signal.Available (Keeper_board_audience.Deliver _) ->
            Log.Keeper.error ~keeper_name:entry.name "discoverable admission returned direct delivery"
        | Keeper_world_observation_board_signal.Unavailable unavailable ->
            failure ~keeper_name:entry.name ~phase:"board_signal_read";
            Log.Keeper.warn ~keeper_name:entry.name "board event signal unavailable: %s"
              (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Log.Keeper.warn ~keeper_name:entry.name
        "board event admission failed: %s" (Printexc.to_string exn)) entries
  in
  let judge () =
    (* Stable event identity deduplicates content revisions. Jev requires an
       exact shared state, so only identical returned persisted signals share
       a request; no caller's newer signal overwrites historical evidence. *)
    let candidates = List.filter (fun (candidate : Candidate.candidate) ->
      match List.find_opt (fun (entry : Keeper_registry.registry_entry) ->
        String.equal entry.name candidate.keeper_name) entries with
      | None -> false
      | Some entry ->
          match Keeper_meta_store.read_effective_meta config entry.name with
          | Error detail -> report candidate detail; false
          | Ok None -> false
          | Ok (Some meta) ->
              match current_entry entry with
              | None -> false
              | Some current -> not meta.paused && current.phase <> Keeper_state_machine.Paused) !recorded in
    let groups = List.fold_left (fun groups candidate ->
      let signal = Candidate.signal_to_yojson candidate.Candidate.signal in
      let same, other = List.partition (fun (held, _) -> held = signal) groups in
      let members = match same with [] -> [] | (_, members) :: _ -> members in
      (signal, candidate :: members) :: other) [] candidates in
    let admit (candidate : Candidate.candidate) =
      match List.find_opt (fun (entry : Keeper_registry.registry_entry) ->
        String.equal entry.name candidate.keeper_name) entries with
      | None -> false
      | Some entry -> match current_entry entry with
          | None -> false
          | Some current -> current.phase <> Keeper_state_machine.Paused in
    List.iter (fun (_, candidates) ->
      run ~clock ~base_path ~wake:(fun _ ~base_path:_ -> ()) ~admit candidates) groups
  in
  (* A first owner cursor starts at today's Board head. Keep its previous
     producer fallback durable before returning, including if the fork is
     immediately cancelled; established cursors remain unacknowledged. *)
  try
    release_hook := Eio.Switch.on_release_cancellable sw cleanup;
    record ~initial:true initial;
    Eio.Switch.check sw;
    Eio.Fiber.fork ~sw (fun () ->
      Fun.protect ~finally:(fun () -> Eio.Cancel.protect cleanup)
        (fun () ->
          (* Fork starts the child before resuming the receipt fiber. Yield
             once before fleet storage so established owners stay asynchronous. *)
          Eio.Fiber.yield ();
          (try record ~initial:false established; judge () with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn -> Log.Keeper.warn "board event batch failed: %s" (Printexc.to_string exn))))
  with
  | Eio.Cancel.Cancelled _ as exn -> Eio.Cancel.protect cleanup; raise exn
  | exn -> cleanup (); raise exn
;;
