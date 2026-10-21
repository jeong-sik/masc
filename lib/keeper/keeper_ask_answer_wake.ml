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

let wake_hint ~log_deferred ~base_path ~keeper_name ~ask_id =
  try
    match Keeper_registry.wakeup_running ~intent:Keeper_registry.Reactive_signal
        ~base_path keeper_name with
    | Keeper_registry.Signaled -> ()
    | Keeper_registry.Deferred_not_running _
    | Keeper_registry.Deferred_lifecycle _
    | Keeper_registry.Deferred_unregistered ->
        if log_deferred then
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
  let ( let* ) = Result.bind in
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
          Domain_pool_ref.submit_io_or_inline
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
  let ( let* ) = Result.bind in
  let* stimulus = answered_stimulus ~keeper_name ask resolution
      |> Result.map_error error_to_string in
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
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_reaction_ledger.event_queue_reaction_evidence_result
        ~base_path ~keeper_name ~stimulus_id
      |> Result.map_error Keeper_reaction_ledger.event_queue_reaction_evidence_error_to_string)) in
  let read_actions () = read_observation ~source:"tool_results" (fun () ->
    match Keeper_ask.answer_source_id ~ask_id:ask.ask_id ~answered_at:stimulus.arrived_at with
    | None -> Error "canonical answer input identity is invalid"
    | Some source_id -> Domain_pool_ref.submit_io_or_inline (fun () ->
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

let deliver_row ~base_path ~keeper_name ~already_delivered ask resolution =
  let ( let* ) = Result.bind in
  let* stimulus = answered_stimulus ~keeper_name ask resolution in
  let* consumed = already_delivered stimulus in
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
        wake_hint ~log_deferred:true ~base_path ~keeper_name ~ask_id:ask.Keeper_ask.ask_id;
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
          wake_hint ~log_deferred:false ~base_path ~keeper_name ~ask_id:ask.Keeper_ask.ask_id;
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
            ~stimulus_kind:(Keeper_reaction_ledger.stimulus_kind_of_event_queue stimulus)
        |> Result.map_error (fun error -> Delivery_evidence_unavailable error)) ask resolution

type failure = { keeper_name : string option; ask_id : string option; error : error }
type report =
  { inspected : int
  ; evidence_window_reads : int
  ; enqueued : int
  ; already_pending : int
  ; already_delivered : int
  ; failures : failure list
  }

type delivery_window = Whole_store | Answer_day of string
type window_demand = One_source | Multiple_sources
module Delivery_windows = Map.Make (struct
  type t = delivery_window
  let compare = Stdlib.compare
end)

let delivery_window since =
  if since <= 0. then Ok Whole_store
  else
    match Jsonl_writer.day_key ~ts:since with
    | day -> Ok (Answer_day day)
    | exception ((Unix.Unix_error _ | Invalid_argument _) as exn) ->
        Error (Invalid_answered_record
          ("answer timestamp has no UTC calendar day: " ^ Printexc.to_string exn))

let empty_report =
  { inspected=0; evidence_window_reads=0; enqueued=0;
    already_pending=0; already_delivered=0; failures=[] }

let reconcile_rows ~base_path ~keeper_name report rows =
  let ( let* ) = Result.bind in
  let answered, demands = List.fold_left (fun (answered, demands) row ->
    let _, (_, resolution) = row in
    match resolution with
    | Keeper_ask.Open | Keeper_ask.Withdrawn_because _ -> answered, demands
    | Keeper_ask.Answered_by { answered_at; _ } ->
        let demands = if not (Float.is_finite answered_at) then demands
          else
            match delivery_window answered_at with
            | Error _ -> demands
            | Ok window ->
                let demand = match Delivery_windows.find_opt window demands with
                  | None -> One_source
                  | Some (One_source | Multiple_sources) -> Multiple_sources in
                Delivery_windows.add window demand demands in
        row :: answered, demands) ([], Delivery_windows.empty) rows in
  let answered = List.rev answered in
  (* A pass owns these immutable reads. Keeper and UTC-day boundaries
     remain distinct; a failed earlier window cannot taint a later one.
     Demand the first read in row order, rather than preparing a barrier
     before the first ready answer can reach the queue owner. *)
  let windows = ref Delivery_windows.empty in
  let window_reads = ref 0 in
  let already_delivered (stimulus : Keeper_event_queue.stimulus) =
    let since = stimulus.arrived_at in
    let* window = delivery_window since in
    let snapshot = match Delivery_windows.find_opt window !windows with
      | Some snapshot -> snapshot
      | None ->
          incr window_reads;
          let snapshot = Keeper_reaction_ledger.strict_source_delivery_snapshot_result
              ~base_path ~keeper_name ~since in
          (* A single-use window is not retained alongside the shared
             ones. All-distinct dates keep no large proof snapshots. *)
          (match Delivery_windows.find_opt window demands with
           | Some Multiple_sources ->
               windows := Delivery_windows.add window snapshot !windows
           | Some One_source | None -> ());
          snapshot in
    Result.bind snapshot (fun snapshot ->
      Keeper_reaction_ledger.source_delivery_seen_in_snapshot snapshot
        ~post_id:stimulus.post_id
        ~stimulus_kind:(Keeper_reaction_ledger.stimulus_kind_of_event_queue stimulus))
    |> Result.map_error (fun error -> Delivery_evidence_unavailable error) in
  let report = List.fold_left (fun report (ask_id, (ask, resolution)) ->
    let report = { report with inspected = report.inspected + 1 } in
    match deliver_row ~base_path ~keeper_name ~already_delivered ask resolution with
    | Ok Enqueued -> { report with enqueued = report.enqueued + 1 }
    | Ok Already_pending -> { report with already_pending = report.already_pending + 1 }
    | Ok Already_delivered -> { report with already_delivered = report.already_delivered + 1 }
    | Error error -> { report with failures = { keeper_name = Some keeper_name;
        ask_id = Some ask_id; error } :: report.failures }) report answered in
  { report with evidence_window_reads =
      report.evidence_window_reads + !window_reads }

let reconcile ~base_path =
  let ( let* ) = Result.bind in
  let* logs = Keeper_ask_store.discover_rows_result ~base_path in
  let report = List.fold_left (fun report log ->
      match log with
      | Keeper_ask_store.Unreadable_log error ->
          { report with failures = { keeper_name = None; ask_id = None;
              error = Ask_store_unavailable error } :: report.failures }
      | Keeper_ask_store.Canonical_rows { keeper_name; rows } ->
          reconcile_rows ~base_path ~keeper_name report rows)
    empty_report logs in
  Ok {report with failures=List.rev report.failures}

type recovery_phase = Reserved | Started | Settled of report | Interrupted | Raised

let observe_recovery ~base_path ~keeper_name ~started_ns phase =
  let emit () = try Log.Server.routine_lazy (fun () ->
      let phase, detail = match phase with
        | Reserved -> "reserved", ""
        | Started -> "started", ""
        | Interrupted -> "interrupted", ""
        | Raised -> "raised", ""
        | Settled report -> "settled", Printf.sprintf
            " inspected=%d evidence_windows=%d enqueued=%d pending=%d already_delivered=%d failures=%d"
            report.inspected report.evidence_window_reads report.enqueued
            report.already_pending report.already_delivered (List.length report.failures) in
      Printf.sprintf "ask_recovery_owner keeper=%s started_ns=%Ld phase=%s at_ns=%Ld%s base_path=%S"
        keeper_name started_ns phase (Mtime_clock.elapsed_ns ()) detail base_path)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let log_report ~base_path ~keeper_name report =
  List.iter (fun (failure : failure) ->
    Log.Server.warn "ask answer recovery retained keeper=%s ask_id=%s error=%s base_path=%S"
      keeper_name
      (match failure.ask_id with Some ask_id -> ask_id | None -> "<store>")
      (error_to_string failure.error) base_path) report.failures;
  if report.enqueued > 0 then Log.Server.info
    "ask answer recovery keeper=%s inspected=%d evidence_windows=%d enqueued=%d pending=%d already_delivered=%d failures=%d base_path=%S"
    keeper_name report.inspected report.evidence_window_reads report.enqueued
    report.already_pending report.already_delivered (List.length report.failures) base_path

let log_discovery ~base_path = function
  | Ok () -> ()
  | Error error -> Log.Server.warn "ask answer recovery discovery unavailable: %s base_path=%S"
      (Keeper_ask_store.read_error_to_string error) base_path

type t =
  { base_path : string
  ; on_report : keeper_name:string -> report -> unit
  ; on_discovery : base_path:string -> (unit, Keeper_ask_store.read_error) result -> unit
  ; mutable active : Set_util.StringSet.t
  ; mutable discovery_active : bool }

let create ~base_path ?(on_report=log_report ~base_path) ?(on_discovery=log_discovery) () =
  {base_path;on_report;on_discovery;active=Set_util.StringSet.empty;discovery_active=false}

let discover_and_schedule ~sw supervisor =
  let ( let* ) = Result.bind in
  Eio.Switch.check sw;
  let* logs = Keeper_ask_store.discover_rows_result ~base_path:supervisor.base_path in
  List.iter (function
    | Keeper_ask_store.Unreadable_log error ->
        Log.Server.warn "ask answer recovery discovery retained error=%s base_path=%S"
          (Keeper_ask_store.read_error_to_string error) supervisor.base_path
    | Keeper_ask_store.Canonical_rows {keeper_name; rows} ->
        if not (Set_util.StringSet.mem keeper_name supervisor.active)
           && List.exists (fun (_, (_, resolution)) -> match resolution with
          | Keeper_ask.Answered_by _ -> true
          | Keeper_ask.Open | Keeper_ask.Withdrawn_because _ -> false) rows then (
          Eio.Switch.check sw;
          let started_ns = Mtime_clock.elapsed_ns () in
          supervisor.active <- Set_util.StringSet.add keeper_name supervisor.active;
          let release () =
            supervisor.active <- Set_util.StringSet.remove keeper_name supervisor.active in
          try
            observe_recovery ~base_path:supervisor.base_path ~keeper_name ~started_ns Reserved;
            Eio.Switch.check sw;
            Eio.Fiber.fork ~sw (fun () ->
              Fun.protect ~finally:release (fun () ->
                try
                  (* Reserve all independent owners without joining their queues,
                     even when the configured filesystem completes inline. *)
                  Eio.Fiber.yield ();
                  observe_recovery ~base_path:supervisor.base_path ~keeper_name ~started_ns Started;
                  let report = reconcile_rows ~base_path:supervisor.base_path
                      ~keeper_name empty_report rows in
                  let report = {report with failures=List.rev report.failures} in
                  observe_recovery ~base_path:supervisor.base_path ~keeper_name ~started_ns (Settled report);
                  (try supervisor.on_report ~keeper_name report with
                   | Eio.Cancel.Cancelled _ as exn -> raise exn
                   | exn -> Log.Server.warn "ask answer recovery observer failed keeper=%s: %s base_path=%S"
                       keeper_name (Printexc.to_string exn) supervisor.base_path)
                with
                | Eio.Cancel.Cancelled _ as exn ->
                    observe_recovery ~base_path:supervisor.base_path ~keeper_name ~started_ns Interrupted;
                    raise exn
                | exn ->
                    observe_recovery ~base_path:supervisor.base_path ~keeper_name ~started_ns Raised;
                    Log.Server.warn "ask answer recovery worker retained keeper=%s: %s base_path=%S"
                      keeper_name (Printexc.to_string exn) supervisor.base_path))
          with exn ->
            let bt = Printexc.get_raw_backtrace () in
            release ();
            Printexc.raise_with_backtrace exn bt)) logs;
  Ok ()

type discovery_phase =
  | Discovery_reserved | Discovery_started
  | Discovery_settled of (unit, Keeper_ask_store.read_error) result
  | Discovery_interrupted | Discovery_raised

let observe_discovery ~base_path ~reserved_ns phase =
  let emit () = try Log.Server.routine_lazy (fun () ->
      let phase, detail = match phase with
        | Discovery_reserved -> "reserved", ""
        | Discovery_started -> "started", ""
        | Discovery_settled result -> "settled",
            (match result with Ok () -> " outcome=returned" | Error _ -> " outcome=failed")
        | Discovery_interrupted -> "interrupted", ""
        | Discovery_raised -> "raised", "" in
      Printf.sprintf "ask_recovery_discovery reserved_ns=%Ld phase=%s at_ns=%Ld%s base_path=%S"
        reserved_ns phase (Mtime_clock.elapsed_ns ()) detail base_path)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> () in
  Eio.Cancel.protect emit

let pulse ~sw supervisor =
  Eio.Switch.check sw;
  if not supervisor.discovery_active then (
    let reserved_ns = Mtime_clock.elapsed_ns () in
    let observe = observe_discovery ~base_path:supervisor.base_path ~reserved_ns in
    supervisor.discovery_active <- true;
    let release () = supervisor.discovery_active <- false in
    try
      observe Discovery_reserved;
      Eio.Switch.check sw;
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect ~finally:release (fun () ->
          try
            Eio.Fiber.yield ();
            observe Discovery_started;
            let result = discover_and_schedule ~sw supervisor in
            observe (Discovery_settled result);
            (try supervisor.on_discovery ~base_path:supervisor.base_path result with
             | Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Log.Server.warn "ask discovery observer failed: %s base_path=%S"
                 (Printexc.to_string exn) supervisor.base_path)
          with
          | Eio.Cancel.Cancelled _ as exn -> observe Discovery_interrupted; raise exn
          | exn ->
              observe Discovery_raised;
              Log.Server.warn "ask discovery worker retained: %s base_path=%S" (Printexc.to_string exn) supervisor.base_path))
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      release ();
      Printexc.raise_with_backtrace exn bt)
