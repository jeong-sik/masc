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

type tick_result =
  { due_changed : int
  ; emitted : wake_signal list
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
  | Due_candidate -> "schedule.due_candidate"
  | Due_blocked_approval -> "schedule.due_blocked_approval"
;;

let signal_kind_of_string = function
  | "schedule.due_candidate" -> Ok Due_candidate
  | "schedule.due_blocked_approval" -> Ok Due_blocked_approval
  | other -> Error ("unknown schedule signal kind: " ^ other)
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
    request.status = Pending_approval
    && request.due_at <= now
    && Schedule_domain.requires_separate_human_grant request)
  |> List.map (make_signal ~now Due_blocked_approval)
;;

let read_recent_signals config n =
  Dated_jsonl.read_recent (signal_store config) n
  |> List.filter_map (fun json ->
    match wake_signal_of_yojson json with
    | Ok signal -> Some signal
    | Error _ -> None)
;;

let tick config ~now =
  match Schedule_store.refresh_due config ~now with
  | Error err -> Error (Service_error (Schedule_service.Store_error err))
  | Ok (state, due_changed) ->
    let signals =
      candidate_signals ~now state @ blocked_approval_signals ~now state
    in
    let* emitted = append_new_signals config signals in
    Ok { due_changed; emitted }
;;
