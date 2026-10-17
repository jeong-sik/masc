type delivery = Enqueued | Already_pending | Already_delivered

type error =
  | Ask_store_unavailable of Keeper_ask_store.read_error
  | Ask_missing of string
  | Ask_not_answered of string
  | Invalid_answered_record of string
  | Delivery_evidence_unavailable of Keeper_reaction_ledger.strict_delivery_evidence_error
  | Queue_storage_failed of string

let error_to_string = function
  | Ask_store_unavailable error -> Keeper_ask_store.read_error_to_string error
  | Ask_missing ask_id -> "canonical ask is missing: " ^ ask_id
  | Ask_not_answered ask_id -> "canonical ask is not answered: " ^ ask_id
  | Invalid_answered_record detail -> "canonical answer is invalid: " ^ detail
  | Delivery_evidence_unavailable error ->
      Keeper_reaction_ledger.strict_delivery_evidence_error_to_string error
  | Queue_storage_failed detail -> "answer wake storage failed: " ^ detail

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

let answered_stimulus ~keeper_name (ask : Keeper_ask.ask) resolution =
  if not (String.equal keeper_name ask.keeper_name) then
    Error (Invalid_answered_record "ask belongs to a different Keeper")
  else match resolution with
  | Keeper_ask.Open | Keeper_ask.Withdrawn_because _ -> Error (Ask_not_answered ask.ask_id)
  | Keeper_ask.Answered_by { answers; answered_at; responder = _ } ->
      if not (Float.is_finite answered_at) then
        Error (Invalid_answered_record "answer timestamp is not finite")
      else
        let submissions = List.map (fun (answer : Keeper_ask.answer) ->
            answer.question_id, answer.response) answers in
        (match Keeper_ask.parse_answers ~ask ~submissions with
         | Error errors -> Error (Invalid_answered_record
             (String.concat "; " (List.map Keeper_ask.invalid_answer_to_string errors)))
         | Ok _ ->
             let payload = { Keeper_event_queue.ask_id = ask.ask_id; channel = ask.continuation } in
             Ok { Keeper_event_queue.post_id = Keeper_event_queue.ask_answered_post_id payload
                ; urgency = Keeper_event_queue.Normal
                ; arrived_at = answered_at
                ; payload = Keeper_event_queue.Ask_answered payload })

type tool_action = {
  execution_id : string;
  trace_id : string;
  keeper_turn_id : int;
  tool_name : string;
  recorded_at : float;
}

type tool_actions = {
  observed_count : int;
  first_recorded_at : float option;
  latest : tool_action option;
}

let observe_tool_actions ~base_path ~keeper_name ~source_id =
  let ( let* ) = Result.bind in
  match Keeper_tool_call_log.configured_masc_root (), Keeper_tool_call_log.store () with
  | Some root, Some store when String.equal root (Common.masc_dir_from_base_path ~base_path) ->
      let* summary, _ = Keeper_tool_call_index.fold_by_answer_source ~store ~keeper_name ~source_id
        ~init:({observed_count=0;first_recorded_at=None;latest=None}, Set_util.StringSet.empty)
        ~f:(fun (summary, seen) row ->
          let field key = match row with
            | `Assoc fields -> (match List.filter (fun (name,_) -> name=key) fields with
                | [_,value] -> Ok value | _ -> Error ("Tool observation has missing/duplicate " ^ key))
            | _ -> Error "Tool observation is not an object" in
          let string key = let* value = field key in match value with
            | `String value when value<>"" -> Ok value
            | _ -> Error ("Tool observation has invalid " ^ key) in
          let* kind = string "record_kind" in
          let* () = match Keeper_tool_call_log.record_kind_of_string kind with
            | Some Tool_call -> Ok ()
            | Some (Composition_run | Lifecycle_event) | None -> Error "answer Tool row is not a physical Tool result" in
          let* execution_id = string "execution_id" in
          if Set_util.StringSet.mem execution_id seen then Error "ambiguous answer Tool execution identity" else
          let* trace_id = string "trace_id" in
          let* tool_name = string "tool" in
          let* turn = field "keeper_turn_id" in
          let* keeper_turn_id = match turn with
            | `Int value when value>0 -> Ok value | _ -> Error "Tool turn identity is invalid" in
          let* clock = field "ts" in
          let* recorded_at = match clock with
            | `Float value when Float.is_finite value -> Ok value
            | `Int value -> Ok (float_of_int value) | _ -> Error "Tool observation clock is invalid" in
          let action = {execution_id;trace_id;keeper_turn_id;tool_name;recorded_at} in
          let first_recorded_at = Some (match summary.first_recorded_at with
            | None -> recorded_at | Some prior -> Float.min prior recorded_at) in
          let latest = match summary.latest with
            | Some prior when prior.recorded_at > recorded_at -> Some prior
            | Some _ | None -> Some action in
          Ok ({observed_count=summary.observed_count+1;first_recorded_at;latest},
              Set_util.StringSet.add execution_id seen)) in
      Ok summary
  | Some _, Some _ | None, _ | _, None -> Error "Tool ledger workspace is unavailable or different"

type followup = {
  answered_at : float;
  stimulus_id : string;
  reactions : Keeper_reaction_ledger.event_queue_reaction_evidence_outcome;
  tool_actions : (tool_actions, string) result;
}

let observe_followup ~base_path ~keeper_name ~ask ~resolution =
  let ( let* ) = Result.bind in
  let* stimulus = answered_stimulus ~keeper_name ask resolution
      |> Result.map_error error_to_string in
  let stimulus_id = Keeper_reaction_ledger.stimulus_id_of_event_queue stimulus in
  let* reactions = Keeper_reaction_ledger.event_queue_reaction_evidence_result
      ~base_path ~keeper_name ~stimulus_id
      |> Result.map_error Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string in
  let tool_actions = match Keeper_ask.answer_source_id ~ask_id:ask.ask_id ~answered_at:stimulus.arrived_at with
    | None -> Error "canonical answer input identity is invalid"
    | Some source_id -> observe_tool_actions ~base_path ~keeper_name ~source_id in
  Ok {answered_at=stimulus.arrived_at; stimulus_id; reactions; tool_actions}

let followup_to_json followup =
  let evidence, complete, quarantine_fields = match followup.reactions with
    | Keeper_reaction_ledger.Evidence_complete evidence -> evidence, true, []
    | Keeper_reaction_ledger.Evidence_quarantined {evidence; first_reason} ->
        evidence, false,
        ["quarantine_reason",
         `String (Keeper_reaction_ledger.row_quarantine_reason_to_string first_reason)] in
  let clock = function None -> `Null | Some at -> `Float at in
  let tool_actions = match followup.tool_actions with
    | Error _ -> `Assoc ["state", `String "unavailable"]
    | Ok actions -> `Assoc ["state", `String "observed";
        "observed_count", `Int actions.observed_count;
        "first_recorded_at", clock actions.first_recorded_at;
        "latest", (match actions.latest with
          | None -> `Null
          | Some action -> `Assoc ["execution_id", `String action.execution_id;
              "trace_id", `String action.trace_id; "keeper_turn_id", `Int action.keeper_turn_id;
              "tool", `String action.tool_name; "recorded_at", `Float action.recorded_at])] in
  `Assoc (["state", `String "observed";
    "answered_at", `Float followup.answered_at;
    "stimulus_id", `String followup.stimulus_id;
    "turn_started_at", clock evidence.turn_started_recorded_at;
    "turn_finished_at", clock evidence.turn_finished_recorded_at;
    "queue_settled_at", clock evidence.event_queue_ack_recorded_at;
    "queue_cancelled_at", clock evidence.event_queue_cancelled_recorded_at;
    "evidence_complete", `Bool complete;
    "tool_actions", tool_actions] @ quarantine_fields)

let deliver_row ~base_path ~keeper_name ~already_delivered ask resolution =
  let ( let* ) = Result.bind in
  let* stimulus = answered_stimulus ~keeper_name ask resolution in
  let* consumed = already_delivered stimulus
      |> Result.map_error (fun error -> Delivery_evidence_unavailable error) in
  if consumed then Ok Already_delivered
  else
    (* Delivery evidence cannot predate the answer it delivers: bound every
       evidence read by the canonical answer time so a torn write from
       before the answer cannot reject this delivery. *)
    let evidence_since = stimulus.Keeper_event_queue.arrived_at in
    match Keeper_registry_event_queue.enqueue_stimulus_once_durable_result
        ~not_before:evidence_since ~base_path keeper_name stimulus with
    | Keeper_registry_event_queue.Stimulus_storage_error detail -> Error (Queue_storage_failed detail)
    | Keeper_registry_event_queue.Stimulus_enqueued ->
        wake_hint ~base_path ~keeper_name ~ask_id:ask.Keeper_ask.ask_id;
        Ok Enqueued
    | Keeper_registry_event_queue.Stimulus_already_present ->
        (* The owner-lock recheck may have observed consumption after our
           snapshot. Check again before sending even a live wake hint. *)
        let* consumed = Keeper_reaction_ledger.event_queue_delivery_seen_for_source_strict_result
            ~base_path ~keeper_name ~not_before:evidence_since ~post_id:stimulus.post_id
            ~stimulus_kind:(Keeper_reaction_ledger.stimulus_kind_of_event_queue stimulus)
            |> Result.map_error (fun error -> Delivery_evidence_unavailable error) in
        if consumed then Ok Already_delivered
        else (
          wake_hint ~base_path ~keeper_name ~ask_id:ask.Keeper_ask.ask_id;
          Ok Already_pending)

let deliver ~base_path ~keeper_name ~ask_id =
  let ( let* ) = Result.bind in
  let* snapshot = Keeper_ask_store.rows_result ~base_path ~keeper_name
      |> Result.map_error (fun error -> Ask_store_unavailable error) in
  let rows = match snapshot with Keeper_ask_store.Missing_log -> [] | Stored_rows rows -> rows in
  match List.assoc_opt ask_id rows with
  | None -> Error (Ask_missing ask_id)
  | Some (ask, resolution) ->
      deliver_row ~base_path ~keeper_name ~already_delivered:(fun stimulus ->
        Keeper_reaction_ledger.event_queue_delivery_seen_for_source_strict_result
          ~base_path ~keeper_name ~not_before:stimulus.Keeper_event_queue.arrived_at
          ~post_id:stimulus.Keeper_event_queue.post_id
          ~stimulus_kind:(Keeper_reaction_ledger.stimulus_kind_of_event_queue stimulus)) ask resolution

type failure = { keeper_name : string option; ask_id : string option; error : error }
type report =
  { inspected : int
  ; enqueued : int
  ; already_pending : int
  ; already_delivered : int
  ; failures : failure list
  }

let reconcile ~base_path =
  let ( let* ) = Result.bind in
  let* logs = Keeper_ask_store.discover_rows_result ~base_path in
  let initial = { inspected = 0; enqueued = 0; already_pending = 0; already_delivered = 0; failures = [] } in
  let report = List.fold_left (fun report log ->
      match log with
      | Keeper_ask_store.Unreadable_log error ->
          { report with failures = { keeper_name = None; ask_id = None;
              error = Ask_store_unavailable error } :: report.failures }
      | Keeper_ask_store.Canonical_rows { keeper_name; rows } ->
          let answered = List.filter (fun (_, (_, resolution)) ->
            match resolution with Keeper_ask.Answered_by _ -> true
            | Keeper_ask.Open | Keeper_ask.Withdrawn_because _ -> false) rows in
          List.fold_left (fun report (ask_id, (ask, resolution)) ->
            let report = { report with inspected = report.inspected + 1 } in
            match deliver_row ~base_path ~keeper_name ~already_delivered:(fun stimulus ->
                Keeper_reaction_ledger.event_queue_delivery_seen_for_source_strict_result
                  ~base_path ~keeper_name ~not_before:stimulus.Keeper_event_queue.arrived_at
                  ~post_id:stimulus.Keeper_event_queue.post_id
                  ~stimulus_kind:(Keeper_reaction_ledger.stimulus_kind_of_event_queue stimulus))
                ask resolution with
            | Ok Enqueued -> { report with enqueued = report.enqueued + 1 }
            | Ok Already_pending -> { report with already_pending = report.already_pending + 1 }
            | Ok Already_delivered -> { report with already_delivered = report.already_delivered + 1 }
            | Error error -> { report with failures = { keeper_name = Some keeper_name;
                ask_id = Some ask_id; error } :: report.failures }) report answered)
    initial logs in
  Ok { report with failures = List.rev report.failures }
