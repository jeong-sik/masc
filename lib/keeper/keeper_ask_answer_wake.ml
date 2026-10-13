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

let deliver_row ~base_path ~keeper_name ~already_delivered ask resolution =
  let ( let* ) = Result.bind in
  let* stimulus = answered_stimulus ~keeper_name ask resolution in
  let* consumed = already_delivered stimulus
      |> Result.map_error (fun error -> Delivery_evidence_unavailable error) in
  if consumed then Ok Already_delivered
  else
    match Keeper_registry_event_queue.enqueue_stimulus_once_durable_result
        ~base_path keeper_name stimulus with
    | Keeper_registry_event_queue.Stimulus_storage_error detail -> Error (Queue_storage_failed detail)
    | Keeper_registry_event_queue.Stimulus_enqueued ->
        wake_hint ~base_path ~keeper_name ~ask_id:ask.Keeper_ask.ask_id;
        Ok Enqueued
    | Keeper_registry_event_queue.Stimulus_already_present ->
        (* The owner-lock recheck may have observed consumption after our
           snapshot. Check again before sending even a live wake hint. *)
        let* consumed = Keeper_reaction_ledger.event_queue_delivery_seen_for_source_strict_result
            ~not_before:stimulus.arrived_at
            ~base_path ~keeper_name ~post_id:stimulus.post_id
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
          ~not_before:stimulus.Keeper_event_queue.arrived_at
          ~base_path ~keeper_name ~post_id:stimulus.Keeper_event_queue.post_id
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
          if answered = [] then report else
          match Keeper_reaction_ledger.strict_source_delivery_snapshot_result ~base_path ~keeper_name with
          | Error error -> { report with failures = { keeper_name = Some keeper_name;
              ask_id = None; error = Delivery_evidence_unavailable error } :: report.failures }
          | Ok evidence ->
              List.fold_left (fun report (ask_id, (ask, resolution)) ->
                let report = { report with inspected = report.inspected + 1 } in
                match deliver_row ~base_path ~keeper_name ~already_delivered:(fun stimulus ->
                    Keeper_reaction_ledger.source_delivery_seen_in_snapshot evidence
                      ~post_id:stimulus.Keeper_event_queue.post_id
                      ~stimulus_kind:(Keeper_reaction_ledger.stimulus_kind_of_event_queue stimulus)) ask resolution with
                | Ok Enqueued -> { report with enqueued = report.enqueued + 1 }
                | Ok Already_pending -> { report with already_pending = report.already_pending + 1 }
                | Ok Already_delivered -> { report with already_delivered = report.already_delivered + 1 }
                | Error error -> { report with failures = { keeper_name = Some keeper_name;
                    ask_id = Some ask_id; error } :: report.failures }) report answered)
    initial logs in
  Ok { report with failures = List.rev report.failures }
