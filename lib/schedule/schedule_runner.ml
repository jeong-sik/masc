(* TEL-OK: this library returns structured [dispatch_result] values and persists
   generic execution records through [Schedule_store]. The server maintenance
   loop owns runtime Log telemetry when it installs a concrete consumer. *)

type signal_kind =
  | Due_candidate
  | Due_blocked_approval

type wake_signal =
  { signal_id : string
  ; kind : signal_kind
  ; schedule_id : string
  ; emitted_at : float
  ; due_at : float
  ; risk_class : Schedule_domain.risk_class
  ; payload_digest : string
  ; payload : Yojson.Safe.t
  }

type wake_signal_read_error_kind =
  | Wake_signal_json_parse_error
  | Wake_signal_schema_decode_error

type wake_signal_read_error =
  { ordinal : int
  ; kind : wake_signal_read_error_kind
  ; error : string
  }

type wake_signal_read_result =
  { signals : wake_signal list
  ; errors : wake_signal_read_error list
  }

type tick_result =
  { due_changed : int
  ; emitted : wake_signal list
  ; rescheduled : int
  ; dispatches : dispatch_result list
  }

and dispatch_status =
  | Dispatch_succeeded
  | Dispatch_failed
  | Dispatch_unsupported
  | Dispatch_start_rejected

and dispatch_result =
  { schedule_id : string
  ; status : dispatch_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  ; duration_sec : float
  }

type consumer =
  { accepts : Schedule_domain.schedule_request -> (unit, string) result
  ; dispatch : Schedule_domain.schedule_request -> (Yojson.Safe.t, string) result
  }

type dispatch_wrapper =
  Schedule_domain.schedule_request -> (unit -> dispatch_result) -> dispatch_result

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

let ( let* ) = Result.bind

let runner_error_to_string = function
  | Service_error err -> Schedule_service.service_error_to_string err
  | Signal_store_error msg -> "signal store error: " ^ msg
;;

let signal_kind_to_string = function
  | Due_candidate -> "schedule.due_candidate"
  | Due_blocked_approval -> "schedule.due_blocked_approval"
;;

let signal_kind_of_string = function
  | "schedule.due_candidate" -> Ok Due_candidate
  | "schedule.due_blocked_approval" -> Ok Due_blocked_approval
  | other -> Error ("unknown schedule signal kind: " ^ other)
;;

let wake_signal_read_error_kind_to_string = function
  | Wake_signal_json_parse_error -> "json_parse"
  | Wake_signal_schema_decode_error -> "schema_decode"
;;

let dispatch_status_to_string = function
  | Dispatch_succeeded -> "succeeded"
  | Dispatch_failed -> "failed"
  | Dispatch_unsupported -> "unsupported"
  | Dispatch_start_rejected -> "start_rejected"
;;

let schedules_dir config =
  Filename.concat (Workspace_utils.masc_dir config) "schedules"
;;

let signals_dir config = Filename.concat (schedules_dir config) "signals"

let signal_seen_path config =
  Filename.concat (schedules_dir config) "signal_keys.json"
;;

let signal_store config = Dated_jsonl.create ~base_dir:(signals_dir config) ()

let string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error ("expected string field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let float_field name fields =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | Some _ -> Error ("expected float field: " ^ name)
  | None -> Error ("missing field: " ^ name)
;;

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let wake_signal_to_yojson signal =
  `Assoc
    [ "event_type", `String (signal_kind_to_string signal.kind)
    ; "signal_id", `String signal.signal_id
    ; "schedule_id", `String signal.schedule_id
    ; "emitted_at", `Float signal.emitted_at
    ; "due_at", `Float signal.due_at
    ; "risk_class", `String (Schedule_domain.risk_class_to_string signal.risk_class)
    ; "payload_digest", `String signal.payload_digest
    ; "payload", signal.payload
    ]
;;

let wake_signal_of_yojson = function
  | `Assoc fields ->
    let* kind_name = string_field "event_type" fields in
    let* kind = signal_kind_of_string kind_name in
    let* signal_id = string_field "signal_id" fields in
    let* schedule_id = string_field "schedule_id" fields in
    let* emitted_at = float_field "emitted_at" fields in
    let* due_at = float_field "due_at" fields in
    let* risk_name = string_field "risk_class" fields in
    let* risk_class = Schedule_domain.risk_class_of_string risk_name in
    let* payload_digest = string_field "payload_digest" fields in
    let* payload = assoc_field "payload" fields in
    Ok { signal_id; kind; schedule_id; emitted_at; due_at; risk_class; payload_digest; payload }
  | _ -> Error "expected schedule wake_signal object"
;;

let sha256_string value =
  Digestif.SHA256.(digest_string value |> to_hex)
;;

let stable_float value = Printf.sprintf "%.17g" value

let signal_id kind (request : Schedule_domain.schedule_request) =
  let payload_digest = Schedule_domain.payload_digest request.payload in
  String.concat
    "|"
    [ signal_kind_to_string kind
    ; request.schedule_id
    ; stable_float request.due_at
    ; payload_digest
    ]
  |> sha256_string
;;

let make_signal ~now kind (request : Schedule_domain.schedule_request) =
  let payload_digest = Schedule_domain.payload_digest request.payload in
  { signal_id = signal_id kind request
  ; kind
  ; schedule_id = request.schedule_id
  ; emitted_at = now
  ; due_at = request.due_at
  ; risk_class = request.risk_class
  ; payload_digest
  ; payload = Schedule_domain.payload_to_yojson request.payload
  }
;;

let read_seen config =
  let path = signal_seen_path config in
  if not (Workspace_utils.path_exists config path) then Ok []
  else
    match Workspace_utils.read_json_result config path with
    | Error msg -> Error msg
    | Ok (`List rows) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | `String key :: rest -> loop (key :: acc) rest
        | _ :: _ -> Error "signal_keys.json must be a string list"
      in
      loop [] rows
    | Ok _ -> Error "signal_keys.json must be a JSON list"
;;

let write_seen config keys =
  Workspace_utils.mkdir_p (schedules_dir config);
  Workspace_utils.write_json_result config (signal_seen_path config)
    (`List (List.map (fun key -> `String key) keys))
;;

module For_testing = struct
  let write_seen = write_seen
end

let append_signal config signal =
  Dated_jsonl.append_result (signal_store config) (wake_signal_to_yojson signal)
;;

let append_new_signals config candidates =
  Workspace_utils.mkdir_p (schedules_dir config);
  Workspace_utils.with_file_lock config (signal_seen_path config) (fun () ->
    let* seen = read_seen config in
    let seen_tbl = Hashtbl.create (List.length seen + List.length candidates) in
    List.iter (fun key -> Hashtbl.replace seen_tbl key ()) seen;
    let emitted_rev = ref [] in
    let seen_rev = ref (List.rev seen) in
    let rec loop = function
      | [] ->
        let* () = write_seen config (List.rev !seen_rev) in
        Ok (List.rev !emitted_rev)
      | signal :: rest ->
        if Hashtbl.mem seen_tbl signal.signal_id then loop rest
        else (
          let* () = append_signal config signal in
          Hashtbl.replace seen_tbl signal.signal_id ();
          seen_rev := signal.signal_id :: !seen_rev;
          emitted_rev := signal :: !emitted_rev;
          loop rest)
    in
    loop candidates)
  |> function
  | Ok emitted -> Ok emitted
  | Error msg -> Error (Signal_store_error msg)
;;

let candidate_signals ~now state =
  Schedule_store.due_execution_candidates state
  |> List.map (make_signal ~now Due_candidate)
;;

let blocked_approval_signals ~now (state : Schedule_store.state) =
  state.schedules
  |> List.filter (fun (request : Schedule_domain.schedule_request) ->
    request.due_at <= now
    && Schedule_domain.requires_separate_human_grant request
    &&
    match request.status with
    | Pending_approval -> true
    | Due -> not (Schedule_store.has_current_approved_grant state request)
    | Scheduled | Running | Succeeded | Failed | Rejected | Cancelled | Expired -> false)
  |> List.map (make_signal ~now Due_blocked_approval)
;;

let dispatch_result ?detail ?error ?(duration_sec = 0.0) schedule_id status =
  { schedule_id; status; detail; error; duration_sec }
;;

let finish_failed_dispatch config ~now ~schedule_id error =
  match Schedule_store.fail_running config ~now ~schedule_id ~error with
  | Ok _ -> dispatch_result ~error schedule_id Dispatch_failed
  | Error err ->
    let error =
      Printf.sprintf
        "%s; failed to mark schedule failed: %s"
        error
        (Schedule_store.store_error_to_string err)
    in
    dispatch_result ~error schedule_id Dispatch_failed
;;

let safe_consumer_dispatch consumer request =
  try consumer.dispatch request with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)
;;

let default_dispatch_wrapper _request run = run ()

let dispatch_candidate
      ?(dispatch_wrapper = default_dispatch_wrapper)
      config
      ~now
      consumer
      (request : Schedule_domain.schedule_request)
  =
  let started_at = Unix.gettimeofday () in
  let schedule_id = request.Schedule_domain.schedule_id in
  let run () =
    match consumer.accepts request with
    | Error reason ->
      (match Schedule_store.fail_due_candidate config ~now ~schedule_id ~error:reason with
       | Ok _ -> dispatch_result ~error:reason schedule_id Dispatch_unsupported
       | Error err ->
         let error =
           Printf.sprintf
             "%s; failed to mark schedule failed: %s"
             reason
             (Schedule_store.store_error_to_string err)
         in
         dispatch_result ~error schedule_id Dispatch_unsupported)
    | Ok () ->
      (match Schedule_store.start_due_candidate config ~now ~schedule_id with
       | Error err ->
         dispatch_result ~error:(Schedule_store.store_error_to_string err) schedule_id
           Dispatch_start_rejected
       | Ok running_request ->
         (match safe_consumer_dispatch consumer running_request with
          | Error error -> finish_failed_dispatch config ~now ~schedule_id error
          | Ok detail ->
            (match Schedule_store.complete_running config ~now ~schedule_id ~detail () with
             | Ok _ -> dispatch_result ~detail schedule_id Dispatch_succeeded
             | Error err ->
               dispatch_result
                 ~detail
                 ~error:(Schedule_store.store_error_to_string err)
                 schedule_id
                 Dispatch_failed)))
  in
  let result = dispatch_wrapper request run in
  { result with duration_sec = max 0.0 (Unix.gettimeofday () -. started_at) }
;;

let dispatch_candidates ?dispatch_wrapper config ~now consumer state =
  Schedule_store.due_execution_candidates state
  |> List.map (dispatch_candidate ?dispatch_wrapper config ~now consumer)
;;

let read_recent_signals_with_errors config n =
  let rec loop ordinal signals_rev errors_rev = function
    | [] -> { signals = List.rev signals_rev; errors = List.rev errors_rev }
    | line :: rest ->
      let next_ordinal = ordinal + 1 in
      let decoded =
        match Yojson.Safe.from_string line with
        | exception Yojson.Json_error msg ->
          Error
            { ordinal
            ; kind = Wake_signal_json_parse_error
            ; error = "json parse failed: " ^ msg
            }
        | json ->
          (match wake_signal_of_yojson json with
           | Ok signal -> Ok signal
           | Error error ->
             Error { ordinal; kind = Wake_signal_schema_decode_error; error })
      in
      (match decoded with
       | Ok signal -> loop next_ordinal (signal :: signals_rev) errors_rev rest
       | Error error -> loop next_ordinal signals_rev (error :: errors_rev) rest)
  in
  loop 0 [] [] (Dated_jsonl.read_recent_lines (signal_store config) n)
;;

let record_wake_signal_read_error error =
  let kind = wake_signal_read_error_kind_to_string error.kind in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_schedule_signal_read_error_total
    ~labels:[ "kind", kind ]
    ();
  Log.Misc.warn
    "schedule_runner.read_recent_signals dropped wake signal row ordinal=%d \
     kind=%s: %s"
    error.ordinal
    kind
    error.error
;;

let read_recent_signals config n =
  let read = read_recent_signals_with_errors config n in
  List.iter record_wake_signal_read_error read.errors;
  read.signals
;;

let tick ?dispatch_wrapper ?consumer config ~now =
  match Schedule_store.refresh_due config ~now with
  | Error err -> Error (Service_error (Schedule_service.Store_error err))
  | Ok (state, due_changed) ->
    let candidate_signals = candidate_signals ~now state in
    let signals = candidate_signals @ blocked_approval_signals ~now state in
    let* emitted = append_new_signals config signals in
    (match consumer with
     | Some consumer ->
       let dispatches = dispatch_candidates ?dispatch_wrapper config ~now consumer state in
       Ok { due_changed; emitted; rescheduled = 0; dispatches }
     | None ->
       let schedule_ids =
         List.map (fun (signal : wake_signal) -> signal.schedule_id) candidate_signals
       in
       (match Schedule_store.reschedule_due_recurring config ~now ~schedule_ids with
        | Error err -> Error (Service_error (Schedule_service.Store_error err))
        | Ok (_, rescheduled) -> Ok { due_changed; emitted; rescheduled; dispatches = [] }))
;;
