(* TEL-OK: this library returns structured [dispatch_result] values and persists
   generic execution records through [Schedule_store]. The server maintenance
   loop owns runtime Log telemetry when it installs a concrete consumer. *)

type signal_kind =
  | Due_candidate

type wake_signal =
  { occurrence_id : Schedule_occurrence_id.t
  ; kind : signal_kind
  ; schedule_id : string
  ; emitted_at : float
  ; due_at : float
  ; payload_digest : string
  ; payload : Yojson.Safe.t
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
  { occurrence_id : Schedule_occurrence_id.t
  ; schedule_id : string
  ; status : dispatch_status
  ; detail : Yojson.Safe.t option
  ; error : string option
  }

type consumer_dispatch_error =
  | Retryable_dispatch_failure of string
  | Terminal_dispatch_rejection of string

type consumer =
  { accepts : Schedule_domain.schedule_request -> (unit, string) result
  ; dispatch :
      Workspace_utils.config ->
      now:float ->
      wake_signal ->
      Schedule_domain.schedule_request ->
      (Yojson.Safe.t, consumer_dispatch_error) result
  }

type runner_error =
  | Service_error of Schedule_service.service_error
  | Signal_store_error of string

let ( let* ) = Result.bind

let runner_error_to_string = function
  | Service_error err -> Schedule_service.service_error_to_string err
  | Signal_store_error msg -> "signal store error: " ^ msg
;;

let signal_kind_to_string = function
  | Due_candidate -> Schedule_occurrence_id.protocol_tag
;;

let signal_kind_of_string value =
  if String.equal value Schedule_occurrence_id.protocol_tag
  then Ok Due_candidate
  else Error ("unknown schedule signal kind: " ^ value)
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
    ; "occurrence_id", `String (Schedule_occurrence_id.to_string signal.occurrence_id)
    ; "schedule_id", `String signal.schedule_id
    ; "emitted_at", `Float signal.emitted_at
    ; "due_at", `Float signal.due_at
    ; "payload_digest", `String signal.payload_digest
    ; "payload", signal.payload
    ]
;;

let wake_signal_of_yojson = function
  | `Assoc fields ->
    let* kind_name = string_field "event_type" fields in
    let* kind = signal_kind_of_string kind_name in
    let* occurrence_id = string_field "occurrence_id" fields in
    let* schedule_id = string_field "schedule_id" fields in
    let* emitted_at = float_field "emitted_at" fields in
    let* due_at = float_field "due_at" fields in
    let* payload_digest = string_field "payload_digest" fields in
    let* payload = assoc_field "payload" fields in
    let* decoded_payload = Schedule_domain.payload_of_yojson payload in
    let actual_payload_digest = Schedule_domain.payload_digest decoded_payload in
    let* () =
      if String.equal payload_digest actual_payload_digest
      then Ok ()
      else Error "payload_digest does not match schedule occurrence payload"
    in
    let expected_occurrence_id =
      Schedule_occurrence_id.make ~schedule_id ~due_at ~payload_digest
    in
    if String.equal occurrence_id (Schedule_occurrence_id.to_string expected_occurrence_id)
    then
      Ok
        { occurrence_id = expected_occurrence_id
        ; kind
        ; schedule_id
        ; emitted_at
        ; due_at
        ; payload_digest
        ; payload
        }
    else Error "occurrence_id does not match schedule occurrence facts"
  | _ -> Error "expected schedule wake_signal object"
;;

let occurrence_id (request : Schedule_domain.schedule_request) =
  let payload_digest = Schedule_domain.payload_digest request.payload in
  Schedule_occurrence_id.make
    ~schedule_id:request.schedule_id
    ~due_at:request.due_at
    ~payload_digest
;;

let make_signal ~now kind (request : Schedule_domain.schedule_request) =
  let payload_digest = Schedule_domain.payload_digest request.payload in
  { occurrence_id = occurrence_id request
  ; kind
  ; schedule_id = request.schedule_id
  ; emitted_at = now
  ; due_at = request.due_at
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
  Workspace_utils.write_json config (signal_seen_path config)
    (`List (List.map (fun key -> `String key) keys))
;;

let append_signal config signal =
  try
    Dated_jsonl.append (signal_store config) (wake_signal_to_yojson signal);
    Ok ()
  with
  | Sys_error msg -> Error msg
  | Unix.Unix_error (err, fn, arg) ->
    Error
      (Printf.sprintf
         "%s failed for %s: %s"
         fn
         arg
         (Unix.error_message err))
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
        write_seen config (List.rev !seen_rev);
        Ok (List.rev !emitted_rev)
      | (signal : wake_signal) :: rest ->
        let occurrence_id = Schedule_occurrence_id.to_string signal.occurrence_id in
        if Hashtbl.mem seen_tbl occurrence_id then loop rest
        else (
          let* () = append_signal config signal in
          Hashtbl.replace seen_tbl occurrence_id ();
          seen_rev := occurrence_id :: !seen_rev;
          emitted_rev := signal :: !emitted_rev;
          loop rest)
    in
    loop candidates)
  |> function
  | Ok emitted -> Ok emitted
  | Error msg -> Error (Signal_store_error msg)
;;

let candidates ~now state =
  Schedule_store.due_execution_candidates state
  |> List.map (fun request -> request, make_signal ~now Due_candidate request)
;;

let dispatch_result ?detail ?error occurrence_id schedule_id status =
  { occurrence_id; schedule_id; status; detail; error }
;;

let finish_terminal_dispatch config ~now ~occurrence_id ~schedule_id error =
  match Schedule_store.fail_running config ~now ~schedule_id ~error with
  | Ok _ -> dispatch_result ~error occurrence_id schedule_id Dispatch_failed
  | Error err ->
    let error =
      Printf.sprintf
        "%s; failed to mark schedule failed: %s"
        error
        (Schedule_store.store_error_to_string err)
    in
    dispatch_result ~error occurrence_id schedule_id Dispatch_failed
;;

let finish_retryable_dispatch config ~now ~occurrence_id ~schedule_id detail =
  let reason = Schedule_store.Retryable_dispatch_failure detail in
  let error = Schedule_store.running_recovery_reason_to_string reason in
  match Schedule_store.retry_running config ~now ~schedule_id ~reason with
  | Ok _ -> dispatch_result ~error occurrence_id schedule_id Dispatch_failed
  | Error err ->
    let error =
      Printf.sprintf
        "%s; failed to return schedule to due: %s"
        error
        (Schedule_store.store_error_to_string err)
    in
    dispatch_result ~error occurrence_id schedule_id Dispatch_failed
;;

let safe_consumer_dispatch config ~now consumer signal request =
  Cancel_safe.protect
    ~on_exn:(fun exn ->
      Error
        (Retryable_dispatch_failure
           ("consumer dispatch raised: " ^ Printexc.to_string exn)))
    (fun () -> consumer.dispatch config ~now signal request)
;;

let dispatch_candidate
      config
      ~now
      consumer
      (signal : wake_signal)
      (request : Schedule_domain.schedule_request)
  =
  let schedule_id = request.Schedule_domain.schedule_id in
  let occurrence_id = signal.occurrence_id in
  match consumer.accepts request with
  | Error reason ->
    (match Schedule_store.fail_due_candidate config ~now ~schedule_id ~error:reason with
     | Ok _ ->
       dispatch_result ~error:reason occurrence_id schedule_id Dispatch_unsupported
     | Error err ->
       let error =
         Printf.sprintf
           "%s; failed to mark schedule failed: %s"
           reason
           (Schedule_store.store_error_to_string err)
       in
       dispatch_result ~error occurrence_id schedule_id Dispatch_unsupported)
  | Ok () ->
    (match Schedule_store.start_due_candidate config ~now ~schedule_id with
     | Error err ->
       dispatch_result ~error:(Schedule_store.store_error_to_string err) occurrence_id
         schedule_id Dispatch_start_rejected
     | Ok running_request ->
       (match safe_consumer_dispatch config ~now consumer signal running_request with
        | Error (Retryable_dispatch_failure detail) ->
          finish_retryable_dispatch config ~now ~occurrence_id ~schedule_id detail
        | Error (Terminal_dispatch_rejection detail) ->
          finish_terminal_dispatch config ~now ~occurrence_id ~schedule_id detail
        | Ok detail ->
          (match Schedule_store.complete_running config ~now ~schedule_id ~detail () with
           | Ok _ ->
             dispatch_result ~detail occurrence_id schedule_id Dispatch_succeeded
           | Error err ->
             dispatch_result ~detail
               ~error:(Schedule_store.store_error_to_string err)
               occurrence_id schedule_id Dispatch_failed)))
;;

let dispatch_candidates config ~now consumer candidates =
  List.map
    (fun (request, signal) ->
       dispatch_candidate config ~now consumer signal request)
    candidates
;;

let read_recent_signals config n =
  let rec decode ordinal acc = function
    | [] -> Ok (List.rev acc)
    | json :: rest ->
      (match wake_signal_of_yojson json with
       | Ok signal -> decode (ordinal + 1) (signal :: acc) rest
       | Error error ->
         Error (Printf.sprintf "schedule signal row %d: %s" ordinal error))
  in
  Dated_jsonl.read_recent (signal_store config) n |> decode 0 []
;;

let tick ?consumer config ~now =
  match Schedule_store.refresh_due config ~now with
  | Error err -> Error (Service_error (Schedule_service.Store_error err))
  | Ok (state, due_changed) ->
    let candidates = candidates ~now state in
    let candidate_signals = List.map snd candidates in
    let* emitted = append_new_signals config candidate_signals in
    (match consumer with
     | Some consumer ->
       let dispatches = dispatch_candidates config ~now consumer candidates in
       Ok { due_changed; emitted; rescheduled = 0; dispatches }
     | None ->
       let schedule_ids =
         List.map (fun (signal : wake_signal) -> signal.schedule_id) candidate_signals
       in
       (match Schedule_store.reschedule_due_recurring config ~now ~schedule_ids with
        | Error err -> Error (Service_error (Schedule_service.Store_error err))
        | Ok (_, rescheduled) -> Ok { due_changed; emitted; rescheduled; dispatches = [] }))
;;
