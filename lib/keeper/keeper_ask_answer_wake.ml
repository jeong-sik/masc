let wake_hint ~base_path ~keeper_name ~ask_id =
  try
    match Keeper_registry.wakeup_running ~intent:Keeper_registry.Reactive_signal
        ~base_path keeper_name with
    | Keeper_registry.Signaled -> ()
    | Keeper_registry.Deferred_not_running _
    | Keeper_registry.Deferred_lifecycle _
    | Keeper_registry.Deferred_unregistered ->
        Log.Keeper.info ~keeper_name "answer wake durably pending; live hint deferred ask_id=%s" ask_id
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Log.Keeper.warn ~keeper_name "answer wake hint failed after commit ask_id=%s: %s"
      ask_id (Printexc.to_string exn)

(* The pointer the answer route admits: the canonical answer time is its
   arrival time, so the followup's source identity is the queued pointer's. *)
let ask_pointer ~now (ask : Keeper_ask.ask) =
  let payload = { Keeper_event_queue.ask_id = ask.ask_id; channel = ask.continuation } in
  { Keeper_event_queue.post_id = Keeper_event_queue.ask_answered_post_id payload
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = now
  ; payload = Keeper_event_queue.Ask_answered payload }

let answered_stimulus ~keeper_name (ask : Keeper_ask.ask) resolution =
  if not (String.equal keeper_name ask.keeper_name) then
    Error "canonical answer is invalid: ask belongs to a different Keeper"
  else match resolution with
  | Keeper_ask.Open | Keeper_ask.Withdrawn_because _ ->
      Error ("canonical ask is not answered: " ^ ask.ask_id)
  | Keeper_ask.Answered_by { answers; answered_at; responder = _ } ->
      if not (Float.is_finite answered_at) then
        Error "canonical answer is invalid: answer timestamp is not finite"
      else
        let submissions = List.map (fun (answer : Keeper_ask.answer) ->
            answer.question_id, answer.response) answers in
        (match Keeper_ask.parse_answers ~ask ~submissions with
         | Error errors -> Error ("canonical answer is invalid: "
             ^ String.concat "; " (List.map Keeper_ask.invalid_answer_to_string errors))
         | Ok _ -> Ok (ask_pointer ~now:answered_at ask))

type tool_action = {
  execution_id : string;
  physical_execution_id : string;
  trace_id : string;
  keeper_turn_id : int;
  tool_name : string;
  recorded_at : float;
  outcome : Tool_result.recorded_call_outcome;
}

type tool_outcomes = {
  succeeded : int; deferred : int; failed : int; unsettled : int; malformed : int;
}
type tool_actions = {
  observed_count : int;
  outcomes : tool_outcomes;
  first_recorded_at : float option;
  latest : tool_action option;
}

let observe_tool_actions ~base_path ~keeper_name ~source_id =
  let open Result.Syntax in
  match Keeper_tool_call_log.configured_masc_root (), Keeper_tool_call_log.store () with
  | Some root, Some store when String.equal root (Common.masc_dir_from_base_path ~base_path) ->
      let* summary, _ = Keeper_tool_call_index.fold_by_answer_source ~store ~keeper_name ~source_id
        ~init:({observed_count=0;
          outcomes={succeeded=0;deferred=0;failed=0;unsettled=0;malformed=0};
          first_recorded_at=None;latest=None}, Set_util.StringSet.empty)
        ~f:(fun (summary, seen) row ->
          let field key = match row with
            | `Assoc fields -> (match List.filter (fun (name,_) -> name=key) fields with
                | [_,value] -> Ok value | _ -> Error ("Tool observation has missing/duplicate " ^ key))
            | _ -> Error "Tool observation is not an object" in
          let string key = let* value = field key in match value with
            | `String value when value<>"" -> Ok value
            | _ -> Error ("Tool observation has invalid " ^ key) in
          let* physical_execution_id = match row with
            | `Assoc fields ->
                (match List.filter (fun (name,_) -> name="physical_execution_id") fields with
                 | [] -> Ok None
                 | [_,`String value] when value<>"" -> Ok (Some value)
                 | _ -> Error "Tool observation has invalid/duplicate physical_execution_id")
            | _ -> Error "Tool observation is not an object" in
          match physical_execution_id with
          | None -> Ok (summary, seen)
          | Some physical_execution_id ->
            let* kind = string "record_kind" in
            let* () = match Keeper_tool_call_log.record_kind_of_string kind with
              | Some Tool_call -> Ok ()
              | Some (Composition_run | Lifecycle_event) | None -> Error "answer Tool row is not a physical Tool result" in
            let* execution_id = string "execution_id" in
            if Set_util.StringSet.mem physical_execution_id seen then Error "ambiguous answer Tool execution identity" else
            let* trace_id = string "trace_id" in
            let* tool_name = string "tool" in
            let* turn = field "keeper_turn_id" in
            let* keeper_turn_id = match turn with
              | `Int value when value>=0 -> Ok value | _ -> Error "Tool turn identity is invalid" in
            let* clock = field "ts" in
            let* recorded_at = match clock with
              | `Float value when Float.is_finite value -> Ok value
              | `Int value -> Ok (float_of_int value) | _ -> Error "Tool observation clock is invalid" in
            let outcome = Tool_result.recorded_call_outcome row in
            let old = summary.outcomes in
            let outcomes = match outcome with
              | Tool_result.Recorded_succeeded -> {old with succeeded=old.succeeded+1}
              | Recorded_deferred -> {old with deferred=old.deferred+1}
              | Recorded_failed -> {old with failed=old.failed+1}
              | Recorded_unsettled -> {old with unsettled=old.unsettled+1}
              | Recorded_malformed -> {old with malformed=old.malformed+1} in
            let action = {execution_id;physical_execution_id;trace_id;keeper_turn_id;tool_name;recorded_at;outcome} in
            let first_recorded_at = Some (match summary.first_recorded_at with
              | None -> recorded_at | Some prior -> Float.min prior recorded_at) in
            let latest = match summary.latest with
              | Some prior when prior.recorded_at > recorded_at -> Some prior
              | Some _ | None -> Some action in
            Ok ({observed_count=summary.observed_count+1;outcomes;first_recorded_at;latest},
                Set_util.StringSet.add physical_execution_id seen)) in
      Ok summary
  | Some _, Some _ | None, _ | _, None -> Error "Tool ledger workspace is unavailable or different"

type linked_task =
  | Task_unlinked
  | Task_missing of string
  | Task_unavailable of { task_id : string; detail : string }
  | Task_observed of {
      task_id : string;
      location : Workspace_query.task_status_location;
      status : Masc_domain.task_status;
      observed_at : float;
    }

let observe_linked_task ~base_path (ask : Keeper_ask.ask) =
  match ask.task_id with
  | None -> Task_unlinked
  | Some task_id ->
      let reading =
        try
          let config = Workspace_core.default_config base_path in
          Eio_guard.with_named_switch "ask-linked-task-status" (fun () ->
          Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__
            (fun () -> Workspace_query.read_task_status_r config ~task_id))
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (Printexc.to_string exn) in
      match reading with
      | Error detail ->
          Log.Keeper.warn ~keeper_name:ask.keeper_name
            "ask followup linked task status unavailable ask_id=%s task_id=%s: %s"
            ask.ask_id task_id detail;
          Task_unavailable { task_id; detail }
      | Ok None -> Task_missing task_id
      | Ok (Some reading) -> Task_observed
          { task_id; location = reading.location; status = reading.status;
            observed_at = Time_compat.now () }

type followup = {
  answered_at : float;
  stimulus_id : string;
  reactions : (Keeper_reaction_ledger.event_queue_reaction_evidence_outcome, string) result;
  tool_actions : (tool_actions, string) result;
  linked_task : linked_task;
}

type followup_identity = { answered_at : float; stimulus_id : string }
type followup_source =
  | Reaction_evidence of (Keeper_reaction_ledger.event_queue_reaction_evidence_outcome, string) result
  | Tool_results of (tool_actions, string) result
  | Linked_task of linked_task

let observe_followup ?on_started ?on_source ~base_path ~keeper_name ~ask ~resolution () =
  let open Result.Syntax in
  let* stimulus = answered_stimulus ~keeper_name ask resolution in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  let identity : followup_identity = {answered_at=stimulus.arrived_at; stimulus_id} in
  Option.iter (fun started -> started identity) on_started;
  let publish source value =
    Option.iter (fun observe -> observe identity (source value)) on_source;
    value in
  let read_observation ~source read =
    let result = try read () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn) in
    (match result with
     | Ok _ -> ()
     | Error _ -> Log.Keeper.warn ~keeper_name
         "ask followup source unavailable ask_id=%s source=%s" ask.ask_id source);
    result in
  let read_reactions () = read_observation ~source:"wake_turn" (fun () ->
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Keeper_reaction_ledger.event_queue_reaction_evidence_result
        ~base_path ~keeper_name ~stimulus_id
      |> Result.map_error Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string)) in
  let read_actions () = read_observation ~source:"tool_results" (fun () ->
    match Keeper_ask.answer_source_id ~ask_id:ask.ask_id ~answered_at:stimulus.arrived_at with
    | None -> Error "canonical answer input identity is invalid"
    | Some source_id -> Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        observe_tool_actions ~base_path ~keeper_name ~source_id)) in
  let read_task () = observe_linked_task ~base_path ask in
  let read_reactions () = publish (fun value -> Reaction_evidence value) (read_reactions ()) in
  let read_actions () = publish (fun value -> Tool_results value) (read_actions ()) in
  let read_task () = publish (fun value -> Linked_task value) (read_task ()) in
  let reactions, (tool_actions, linked_task) = match Eio_guard.execution_context () with
    | Eio_fiber -> Eio.Fiber.pair read_reactions (fun () -> Eio.Fiber.pair read_actions read_task)
    | Non_eio ->
        let reactions = read_reactions () in
        let actions = read_actions () in
        reactions, (actions, read_task ()) in
  Ok {answered_at=stimulus.arrived_at; stimulus_id; reactions; tool_actions; linked_task}

let reaction_evidence_to_json reactions =
  let clock = function None -> `Null | Some at -> `Float at in
  match reactions with
    | Error _ -> `Assoc ["state", `String "unavailable"]
    | Ok outcome ->
      let evidence, complete, quarantine_fields = match outcome with
        | Keeper_reaction_ledger.Evidence_complete evidence -> evidence, true, []
        | Keeper_reaction_ledger.Evidence_quarantined {evidence; first_reason} ->
          evidence, false, ["quarantine_reason",
            `String (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)] in
      `Assoc (["state", `String "observed";
        "turn_started_at", clock evidence.turn_started_recorded_at;
        "turn_finished_at", clock evidence.turn_finished_recorded_at;
        "queue_settled_at", clock evidence.event_queue_ack_recorded_at;
        "queue_cancelled_at", clock evidence.event_queue_cancelled_recorded_at;
        "evidence_complete", `Bool complete] @ quarantine_fields)

let tool_actions_to_json actions =
  let clock = function None -> `Null | Some at -> `Float at in
  match actions with
    | Error _ -> `Assoc ["state", `String "unavailable"]
    | Ok actions -> `Assoc ["state", `String "observed";
        "observed_count", `Int actions.observed_count;
        "outcomes", `Assoc ["succeeded", `Int actions.outcomes.succeeded;
          "deferred", `Int actions.outcomes.deferred; "failed", `Int actions.outcomes.failed;
          "unsettled", `Int actions.outcomes.unsettled; "malformed", `Int actions.outcomes.malformed];
        "first_recorded_at", clock actions.first_recorded_at;
        "latest", (match actions.latest with
          | None -> `Null
          | Some action -> `Assoc ["execution_id", `String action.execution_id;
              "physical_execution_id", `String action.physical_execution_id;
              "trace_id", `String action.trace_id; "keeper_turn_id", `Int action.keeper_turn_id;
              "tool", `String action.tool_name; "recorded_at", `Float action.recorded_at;
              "outcome", `String (Tool_result.recorded_call_outcome_to_string action.outcome)])]

let linked_task_to_json task =
  match task with
    | Task_unlinked -> `Assoc ["state", `String "unlinked"]
    | Task_missing task_id -> `Assoc ["state", `String "missing"; "task_id", `String task_id]
    | Task_unavailable {task_id; detail = _} ->
        `Assoc ["state", `String "unavailable"; "task_id", `String task_id]
    | Task_observed {task_id; location; status; observed_at} ->
        `Assoc ["state", `String "observed"; "task_id", `String task_id;
          "location", `String (match location with Workspace_query.Task_backlog -> "backlog" | Task_archive -> "archive");
          "observed_at", `Float observed_at;
          "status", Task_status_observation.to_yojson status]

let followup_source_to_json = function
  | Reaction_evidence evidence -> "reaction_evidence", reaction_evidence_to_json evidence
  | Tool_results actions -> "tool_actions", tool_actions_to_json actions
  | Linked_task task -> "linked_task", linked_task_to_json task

let followup_to_json (followup : followup) =
  `Assoc (["state", `String "observed";
    "answered_at", `Float followup.answered_at;
    "stimulus_id", `String followup.stimulus_id;
    "reaction_evidence", reaction_evidence_to_json followup.reactions;
    "tool_actions", tool_actions_to_json followup.tool_actions;
    "linked_task", linked_task_to_json followup.linked_task])

type answer_failure =
  | Answer_refused of Keeper_ask_store.answer_failure
  | Keeper_intake_held of Keeper_shutdown_types.Operation_id.t
  | Keeper_queue_unavailable of string

(* The pointer becomes durable before the answer is appended, and both happen
   inside the Keeper's queue owner lock: an answer never exists without its
   pointer, and no ACK of that pointer lands between them. *)
let answer ~base_path ~keeper_name ~ask_id ~submissions ~responder ~now =
  let admitted =
    Keeper_registry_event_queue.with_stimulus_admission ~base_path keeper_name (fun admit ->
      Keeper_ask_store.answer ~base_path ~keeper_name ~ask_id ~submissions ~responder ~now
        ~admit:(fun ask ->
          admit (ask_pointer ~now ask)
          |> Result.map (fun (_ : Keeper_event_queue_persistence.enqueue_stimulus_result) -> ())))
  in
  match admitted with
  | Keeper_registry_event_queue.Admission_shutdown_reserved operation_id ->
      Error (Keeper_intake_held operation_id)
  | Keeper_registry_event_queue.Admission_storage_error detail ->
      Error (Keeper_queue_unavailable detail)
  | Keeper_registry_event_queue.Admission_completed (Error failure) -> Error (Answer_refused failure)
  | Keeper_registry_event_queue.Admission_completed (Ok answers) ->
      wake_hint ~base_path ~keeper_name ~ask_id;
      Ok answers
