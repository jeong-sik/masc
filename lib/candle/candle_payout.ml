(* See candle_payout.mli. *)

type waiting =
  { goal_id : string
  ; request_id : string
  ; verification_run_id : string
  ; passed_at : Candle_time.t
  ; confirmed_at : Candle_time.t
  }

type state =
  | No_obligation
  | Waiting of waiting
  | Failed of waiting
  | Settled

type pass =
  { goal_created_at : Candle_time.t
  ; goal : Candle_appraisal.goal
  ; due_date : string option
  ; linked_task_ids : string list
  }

type candidates =
  { candidate_task_ids : string list
  ; candidate_keepers : string list
  }

let is_settled ~goal_id events =
  List.exists
    (fun (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Unattributed unattributed -> String.equal unattributed.goal_id goal_id
       | Candle_event.Paid p -> String.equal p.identity.goal_id goal_id
       | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ | Candle_event.Payout_failed _ -> false
       | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _ ->
         false)
    events
;;

let last_owed ~goal_id events =
  List.fold_left
    (fun last (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Payout_owed owed when String.equal owed.goal_id goal_id ->
         Some
           { goal_id
           ; request_id = owed.request_id
           ; verification_run_id = owed.verification_run_id
           ; passed_at = owed.passed_at
           ; confirmed_at = owed.confirmed_at
           }
       | Candle_event.Payout_owed _
       | Candle_event.Snapshot _
       | Candle_event.Candidates _
       | Candle_event.Unattributed _ | Candle_event.Paid _ | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ | Candle_event.Payout_failed _ -> last)
    None
    events
;;

let failed_run ~goal_id ~request_id ~verification_run_id events =
  List.exists (fun (event : Candle_event.t) -> match event.body with
    | Candle_event.Payout_failed f -> f.goal_id = goal_id && f.request_id = request_id
        && f.verification_run_id = verification_run_id
    | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
    | Candle_event.Unattributed _ | Candle_event.Paid _ | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ -> false) events

let state ~goal_id events =
  if is_settled ~goal_id events
  then Settled
  else (
    match last_owed ~goal_id events with
    | Some owed when failed_run ~goal_id ~request_id:owed.request_id ~verification_run_id:owed.verification_run_id events -> Failed owed
    | Some owed -> Waiting owed
    | None -> No_obligation)
;;

let waiting events =
  let goal_ids =
    List.fold_left
      (fun seen (event : Candle_event.t) ->
         match event.body with
         | Candle_event.Payout_owed owed ->
           if List.mem owed.goal_id seen then seen else owed.goal_id :: seen
         | Candle_event.Snapshot _ | Candle_event.Candidates _ | Candle_event.Unattributed _ | Candle_event.Paid _ | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ | Candle_event.Payout_failed _ ->
           seen)
      []
      events
    |> List.rev
  in
  List.filter_map
    (fun goal_id ->
       match state ~goal_id events with
       | Waiting owed -> Some owed
       | No_obligation | Failed _ | Settled -> None)
    goal_ids
;;

(* The pass a Snapshot fixed for this Goal, request and verifier run. A time
   is evidence about a run, not its identity: distinct runs can share a second. *)
let find_pass ~goal_id ~request_id ~verification_run_id ~passed_at events =
  List.find_map
    (fun (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Snapshot snapshot
         when String.equal snapshot.goal_id goal_id
              && String.equal snapshot.request_id request_id
              && String.equal snapshot.verification_run_id verification_run_id
              && String.equal (Candle_time.to_rfc3339 snapshot.passed_at) passed_at ->
         Some
           ( snapshot.passed_at
           , { goal_created_at = snapshot.goal_created_at
             ; goal = {Candle_appraisal.title = snapshot.title; metric = snapshot.metric; target_value = snapshot.target_value}
             ; due_date = snapshot.due_date
             ; linked_task_ids = snapshot.linked_task_ids
             } )
       | Candle_event.Snapshot _
       | Candle_event.Payout_owed _
       | Candle_event.Candidates _
       | Candle_event.Unattributed _ | Candle_event.Paid _ | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ | Candle_event.Payout_failed _ -> None)
    events
;;

let owed_pass ~goal_id ~request_id ~verification_run_id ~passed_at events =
  match state ~goal_id events with
  | Waiting _ | Settled -> None
  | (No_obligation | Failed _) when failed_run ~goal_id ~request_id ~verification_run_id events -> None
  | No_obligation | Failed _ ->
    Option.map fst (find_pass ~goal_id ~request_id ~verification_run_id ~passed_at events)
;;

let pass_of (waiting : waiting) events =
  Option.map
    snd
    (find_pass
       ~goal_id:waiting.goal_id
       ~request_id:waiting.request_id
       ~verification_run_id:waiting.verification_run_id
       ~passed_at:(Candle_time.to_rfc3339 waiting.passed_at)
       events)
;;

let candidates_of (waiting : waiting) events =
  List.find_map
    (fun (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Candidates c
         when String.equal c.goal_id waiting.goal_id
              && String.equal c.request_id waiting.request_id
              && String.equal c.verification_run_id waiting.verification_run_id ->
         Some
           { candidate_task_ids = c.candidate_task_ids; candidate_keepers = c.candidate_keepers }
       | Candle_event.Candidates _
       | Candle_event.Snapshot _
       | Candle_event.Payout_owed _
       | Candle_event.Unattributed _ | Candle_event.Paid _ | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ | Candle_event.Payout_failed _ -> None)
    events
;;

let is_candidate ~goal_created_at ~confirmed_at = function
  | Candle_event.Found { status = Candle_event.Done { completed_at }; _ } ->
    Candle_time.compare completed_at goal_created_at > 0
    && Candle_time.compare completed_at confirmed_at <= 0
  | Candle_event.Found
      { status =
          ( Candle_event.Todo
          | Candle_event.Claimed
          | Candle_event.In_progress
          | Candle_event.Awaiting_verification
          | Candle_event.Cancelled )
      ; _
      }
  | Candle_event.Deleted -> false
;;

let validate_settlement (waiting : waiting) events body =
  let ( let* ) = Result.bind in
  let* pass = match pass_of waiting events with
    | Some pass -> Ok pass
    | None -> Error "settlement requires the confirmed Snapshot" in
  let matches goal_id request_id verification_run_id =
    goal_id = waiting.goal_id && request_id = waiting.request_id
    && verification_run_id = waiting.verification_run_id in
  let candidates = List.find_map (fun (event : Candle_event.t) -> match event.body with
    | Candle_event.Candidates c when matches c.goal_id c.request_id c.verification_run_id ->
      Some (c.tasks, c.candidate_task_ids, c.candidate_keepers)
    | Candle_event.Candidates _ | Candle_event.Snapshot _ | Candle_event.Payout_owed _
    | Candle_event.Unattributed _ | Candle_event.Paid _ | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ | Candle_event.Payout_failed _ -> None) events in
  let* tasks, ids, keepers = match candidates with
    | None -> Error "settlement requires durable Candidates" | Some c -> Ok c in
  let* () =
    let observed_ids = List.map fst tasks in
    if List.length observed_ids <> List.length (List.sort_uniq String.compare observed_ids)
       || List.sort String.compare observed_ids <> List.sort String.compare pass.linked_task_ids
    then Error "durable task observations must cover every Snapshot-linked task exactly once"
    else
      let eligible_ids = List.filter_map (fun (id, task) ->
        if is_candidate ~goal_created_at:pass.goal_created_at
            ~confirmed_at:waiting.confirmed_at task then Some id else None) tasks in
      if List.sort String.compare ids <> List.sort String.compare eligible_ids
      then Error "durable candidate tasks must equal the complete eligible Snapshot subset"
      else Ok () in
  let recipients relations =
    let actual = List.map (fun (r : Candle_appraisal.task_relation) -> r.task_id) relations in
    if List.length actual <> List.length (List.sort_uniq String.compare actual)
       || List.sort String.compare actual <> List.sort String.compare ids then
      Error "relation decisions must cover each durable candidate task exactly once"
    else if List.exists (fun id -> match List.assoc_opt id tasks with
        | Some (Candle_event.Found _) -> false | Some Candle_event.Deleted | None -> true) ids then
      Error "durable candidate task has no found row"
    else Ok (List.filter_map (fun (r : Candle_appraisal.task_relation) ->
      match r.relation, List.assoc_opt r.task_id tasks with
      | Candle_appraisal.Related, Some (Candle_event.Found {assignee=Some name;_}) when List.mem name keepers -> Some name
      | Candle_appraisal.Related, (Some (Candle_event.Found _) | Some Candle_event.Deleted | None)
      | Candle_appraisal.Unrelated, _ -> None) relations |> List.sort_uniq String.compare) in
  match body with
  | Candle_event.Paid p when matches p.identity.goal_id p.identity.request_id p.identity.verification_run_id ->
    let* eligible = recipients p.relations in
    if eligible = [] then Error "Paid has no related candidate keeper"
    else Candle_appraisal.validate_weights ~keepers:eligible ~weight_max:p.weight_max
      (List.map (fun (a : Candle_payment.allocation) -> a.keeper, a.weight) p.allocations)
  | Candle_event.Unattributed u when matches u.goal_id u.request_id u.verification_run_id ->
    (match u.reason with
     | Candle_event.No_candidates -> if keepers = [] then Ok () else Error "candidate keepers exist"
     | Candle_event.All_unrelated a ->
       let* eligible = recipients a.relations in
       if eligible = [] && List.for_all (fun (r : Candle_appraisal.task_relation) -> r.relation = Candle_appraisal.Unrelated) a.relations
       then Ok () else Error "related tasks cannot close as all_unrelated"
     | Candle_event.No_related_keepers a ->
       let* eligible = recipients a.relations in
       if eligible = [] && List.exists (fun (r : Candle_appraisal.task_relation) -> r.relation = Candle_appraisal.Related) a.relations
       then Ok () else Error "no_related_keepers does not match relation decisions")
  | Candle_event.Payout_failed f when matches f.goal_id f.request_id f.verification_run_id ->
    if pass.due_date = Some f.due_date then Ok ()
    else Error "failed due date differs from the confirmed Snapshot"
  | Candle_event.Paid _ | Candle_event.Unattributed _ | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ | Candle_event.Payout_failed _
  | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _ ->
    Error "settlement does not name the confirmed verifier run"

let validate_record events body =
  let goal_id = match body with
    | Candle_event.Paid p -> Some p.identity.goal_id
    | Candle_event.Unattributed u -> Some u.goal_id
    | Candle_event.Payout_failed f -> Some f.goal_id
    | Candle_event.Snapshot _ | Candle_event.Payout_owed _ | Candle_event.Candidates _
    | Candle_event.Half_life_set _ | Candle_event.Equipped _ | Candle_event.Purchased _ -> None in
  match goal_id with
  | None -> Ok ()
  | Some goal_id ->
    match state ~goal_id events with
    | No_obligation | Failed _ | Settled -> Error "settlement requires an open payout obligation"
    | Waiting waiting -> validate_settlement waiting events body

let keeper_name ~is_keeper = function
  | Candle_event.Found { assignee = Some name; _ } -> if is_keeper name then Some name else None
  | Candle_event.Found { assignee = None; _ } | Candle_event.Deleted -> None
;;

let decide_candidates ~goal_created_at ~confirmed_at ~is_keeper tasks =
  let candidates =
    List.filter (fun (_, lookup) -> is_candidate ~goal_created_at ~confirmed_at lookup) tasks
  in
  { candidate_task_ids = List.map fst candidates
  ; candidate_keepers =
      List.sort_uniq
        String.compare
        (List.filter_map (fun (_, lookup) -> keeper_name ~is_keeper lookup) candidates)
  }
;;
