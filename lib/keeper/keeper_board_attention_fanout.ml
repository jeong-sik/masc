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

let dispatch ~sw ~clock ~base_path candidates =
  let run () =
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
  in
  match candidates with
  | [] -> ()
  | _ -> Eio.Fiber.fork ~sw run
