module A = Candle_appraisal
module E = Candle_event
let ( let* ) = Result.bind
type outcome = Settled of string | Superseded of string | Retry_later of { goal_id : string; detail : string } | Rejected of { goal_id : string; detail : string }
let identity (w : Candle_payout.waiting) : A.identity =
  {goal_id=w.goal_id;request_id=w.request_id;verification_run_id=w.verification_run_id}
let candidate_tasks (w : Candle_payout.waiting) events =
  List.find_map (fun (event : E.t) -> match event.body with
    | E.Candidates c when c.goal_id = w.goal_id && c.request_id = w.request_id
        && c.verification_run_id = w.verification_run_id -> Some c.tasks
    | E.Half_life_set _ | E.Candidates _ | E.Snapshot _ | E.Payout_owed _ | E.Unattributed _ | E.Paid _ | E.Equipped _ | E.Purchased _ | E.Payout_failed _ -> None) events
let call ~(appraise : A.runner) ~identity request =
  let* answer = appraise ~identity request in
  let* decision = A.decode request (A.decision_json answer.decision) |> Result.map_error (fun detail -> A.Invalid_response detail) in
  let* trace = A.trace_of_json (A.trace_json answer.trace) |> Result.map_error (fun detail -> A.Invalid_response detail) in
  Ok {A.decision;trace}
let grade ~appraise ~identity goal =
  let* answer = call ~appraise ~identity (A.Grade goal) in
  match answer.decision with
  | A.Grade_decided grade -> Ok (grade, answer.trace)
  | A.Relation_decided _ | A.Weights_decided _ -> Error (A.Invalid_response "appraiser returned the wrong stage")
let relations ~appraise ~identity goal tasks ids =
  let rec loop accumulated = function
    | [] -> Ok (List.rev accumulated)
    | task_id :: rest ->
      (match List.assoc_opt task_id tasks with
       | Some (E.Found task) ->
         let* answer = call ~appraise ~identity (A.Relation {goal;task_title=task.title}) in
         (match answer.decision with
          | A.Relation_decided relation -> loop ({A.task_id;relation;trace=answer.trace} :: accumulated) rest
          | A.Grade_decided _ | A.Weights_decided _ -> Error (A.Invalid_response "appraiser returned the wrong stage"))
       | Some E.Deleted | None -> Error (A.Transport_unavailable ("candidate task is absent: " ^ task_id))) in
  loop [] ids
let related_tasks tasks task_keepers relations =
  List.filter_map (fun (r : A.task_relation) ->
    match r.relation, List.assoc_opt r.task_id tasks, List.assoc_opt r.task_id task_keepers with
    | A.Related, Some (E.Found {title;_}), Some (Some keeper) ->
      Some {A.task_id=r.task_id;title;keeper}
    | A.Unrelated, _, _
    | A.Related, (Some E.Deleted | None), _
    | A.Related, Some (E.Found _), (Some None | None) -> None) relations
let decide ~appraise ~(policy : Candle_config.payout_policy) events (waiting : Candle_payout.waiting) =
  let identity = identity waiting in
  match Candle_payout.pass_of waiting events, Candle_payout.candidates_of waiting events, candidate_tasks waiting events with
  | Some _, Some {candidate_keepers=[];_}, Some _ ->
    Ok (E.Unattributed {goal_id=waiting.goal_id;request_id=waiting.request_id;
      verification_run_id=waiting.verification_run_id;reason=E.No_candidates})
  | Some pass, Some candidates, Some tasks ->
    let hours = match Goal_due.read pass.due_date with
      | Goal_due.Unreadable_due_date raw -> Error raw
      | Goal_due.No_due_date -> Ok 0
      | Goal_due.Due_date d -> Ok (Candle_math.overdue_hours ~due:d.instant ~passed_at:(Candle_time.to_ptime waiting.passed_at)) in
    (match hours with
     | Error due_date ->
       Ok (E.Payout_failed {goal_id=waiting.goal_id;request_id=waiting.request_id;
                           verification_run_id=waiting.verification_run_id;due_date})
     | Ok overdue_hours ->
       let* grade, grade_trace = grade ~appraise ~identity pass.goal in
       let* relations = relations ~appraise ~identity pass.goal tasks candidates.candidate_task_ids in
       let related = related_tasks tasks candidates.candidate_task_keepers relations in
       let attribution = {E.grade;grade_trace;relations} in
       match related with
       | [] ->
         let reason = if List.for_all (fun (r : A.task_relation) -> r.relation = A.Unrelated) relations
           then E.All_unrelated attribution else E.No_related_keepers attribution in
         Ok (E.Unattributed {goal_id=waiting.goal_id;request_id=waiting.request_id;
                            verification_run_id=waiting.verification_run_id;reason})
       | _ :: _ ->
         let keepers = List.sort_uniq String.compare (List.map (fun (t : A.task) -> t.keeper) related) in
         let request = A.Weights {goal=pass.goal;tasks=related;keepers;weight_max=policy.weight_max} in
         let* answer = call ~appraise ~identity request in
         let* weights = match answer.decision with A.Weights_decided weights -> Ok weights
           | A.Grade_decided _ | A.Relation_decided _ -> Error (A.Invalid_response "appraiser returned the wrong stage") in
         let* payment = Candle_payment.make ~identity ~grade
           ~total_milli:(Candle_config.grade_amount_milli policy grade) ~grade_trace ~relations
           ~weights_trace:answer.trace ~weight_max:policy.weight_max ~deduction_rate:policy.deduction_rate
           ~deduction_floor:policy.deduction_floor ~overdue_hours ~weights |> Result.map_error (fun detail -> A.Invalid_response detail) in
         Ok (E.Paid payment))
  | None, _, _ -> Error (A.Transport_unavailable "no Snapshot names the confirmed verifier run")
  | Some _, (None | Some _), None | Some _, None, Some _ -> Error (A.Transport_unavailable "Candidates are not durable yet")
let preparation_error ~at ~events error =
  let invalid error = A.Invalid_response (Candle_balance.error_to_string error) in
  match error with
  | Candle_balance.Clock_reversed _
  | Candle_balance.Decay_failed {error=Candle_decay.Reversed_interval;_} ->
      (* Distinguish a temporarily early wall clock from reversed historical
         ledger facts. Replaying through the latest recorded instant still
         rejects malformed historical order and monetary facts. *)
      let through = List.fold_left (fun latest (event : E.t) ->
        if Candle_time.compare event.at latest > 0 then event.at else latest) at events in
      (match Candle_balance.of_events ~at:through events with
       | Ok _ -> A.Transport_unavailable (Candle_balance.error_to_string error)
       | Error historical -> invalid historical)
  | error -> invalid error

let settle ~now ~appraise ~policy ~base_path events (waiting : Candle_payout.waiting) =
  let* body = decide ~appraise ~policy events waiting in
  Candle_ledger.update ~base_path (fun view ->
    match Candle_payout.state ~goal_id:waiting.goal_id (Candle_ledger.events view) with
    | Candle_payout.Waiting current when current = waiting ->
      (* Preserve the payout arithmetic accepted before the model wait, but
         re-read availability and half-life at publication under this CAS. *)
      (* Read the clock on every CAS attempt, then check availability so a
         yielding or injected clock cannot leave a pre-clock policy authoritative. *)
      let* at = Candle_stamp.at ~now |> Result.map_error (fun detail -> A.Transport_unavailable detail) in
      let* current_policy = match Candle_status.configured ~base_path with
        | Candle_config.Enabled policy -> Ok policy
        | Candle_config.Off -> Error (A.Transport_unavailable "Candle was turned off during appraisal")
        | Candle_config.Disabled {reason} -> Error (A.Transport_unavailable ("Candle disabled during appraisal: " ^ reason)) in
      let events = Candle_ledger.events view in
      let* prepared = Candle_status.prepare ~at ~half_life:current_policy.half_life events
        |> Result.map_error (preparation_error ~at ~events) in
      let* () = Candle_payout.validate_settlement waiting prepared.events body
        |> Result.map_error (fun detail -> A.Invalid_response detail) in
      let credit = match body with
        | E.Paid payment -> Candle_balance.credit prepared.balance ~at payment |> Result.map (fun _ -> ())
        | E.Half_life_set _ | E.Unattributed _ | E.Equipped _ | E.Purchased _ | E.Payout_failed _ | E.Snapshot _ | E.Payout_owed _ | E.Candidates _ -> Ok () in
      (match credit, current_policy.half_life with
       | Ok (), _ -> Ok (prepared.policy_events @ [{E.at;body}], Settled waiting.goal_id)
       | Error (Candle_balance.Balance_overflow _ as error), Candle_decay.Hours _ ->
         (* Commit the authorized policy boundary even when credit must wait:
            switching from Off must actually start decay before the next pulse. *)
         Ok (prepared.policy_events, Retry_later {goal_id=waiting.goal_id;
           detail=Candle_balance.error_to_string error})
       | Error error, _ -> Error (A.Invalid_response (Candle_balance.error_to_string error)))
    | Candle_payout.Waiting _ | Candle_payout.No_obligation | Candle_payout.Failed _ | Candle_payout.Settled -> Ok ([], Superseded waiting.goal_id))
  |> Result.map_error (function
    | Candle_ledger.Refused error -> error
    | Candle_ledger.Event_unwritable detail -> A.Invalid_response detail
    | (Candle_ledger.Read_failed _ | Candle_ledger.Write_failed _ | Candle_ledger.Write_locked _) as error ->
      A.Transport_unavailable (Candle_ledger.update_error_to_string A.error_to_string error))
let pending ~base_path =
  Candle_ledger.read ~base_path |> Result.map (fun view -> Candle_payout.waiting (Candle_ledger.events view))
  |> Result.map_error Candle_ledger.read_error_to_string
let settle_one ~now ~appraise ~base_path (waiting : Candle_payout.waiting) =
  let result () =
    match Candle_status.current ~base_path with
    | Candle_config.Off | Candle_config.Disabled _ -> Ok (Superseded waiting.goal_id)
    | Candle_config.Enabled policy ->
      let* view = Candle_ledger.read ~base_path
        |> Result.map_error (fun e -> A.Transport_unavailable (Candle_ledger.read_error_to_string e)) in
      let events = Candle_ledger.events view in
      match Candle_payout.state ~goal_id:waiting.goal_id events with
      | Candle_payout.Waiting current when current=waiting -> settle ~now ~appraise ~policy:policy.payout ~base_path events waiting
      | Candle_payout.Waiting _ | Candle_payout.Failed _ | Candle_payout.No_obligation | Candle_payout.Settled -> Ok (Superseded waiting.goal_id) in
  match result () with
  | Ok outcome -> outcome
  | Error (A.Invalid_response detail | A.Execution_rejected detail) -> Rejected {goal_id=waiting.goal_id;detail}
  | Error (A.Transport_unavailable detail) -> Retry_later {goal_id=waiting.goal_id;detail}
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Retry_later {goal_id=waiting.goal_id;detail=Printexc.to_string exn}
let drain_once ~now ~appraise ~base_path =
  match Candle_status.current ~base_path with
  | Candle_config.Off | Candle_config.Disabled _ -> Ok []
  | Candle_config.Enabled _ ->
    let* waiting = pending ~base_path in
    Ok (List.map (settle_one ~now ~appraise ~base_path) waiting)
