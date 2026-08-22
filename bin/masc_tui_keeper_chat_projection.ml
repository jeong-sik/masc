(** Exact request and terminal projection for the TUI Keeper chat surface. *)

module Keeper_turn_outcome = Masc.Keeper_turn_outcome

type request = {
  request_id : string;
  keeper_name : string;
  message : string;
}

type acceptance_state =
  | Queued
  | Running
  | Succeeded
  | Failed
  | Cancelled

type acceptance = {
  state : acceptance_state;
  queued_count : int;
}

type turn_outcome = Masc.Keeper_turn_outcome.t =
  | Visible_reply
  | Continuation_checkpoint
  | External_effect_completed
  | External_effect_pending
  | No_visible_reply

type completed_turn = {
  acceptance : acceptance;
  reply : string;
  turn_outcome : turn_outcome;
  turn_ref : string;
}

type response =
  | Turn_completed of completed_turn
  | Replayed_succeeded of acceptance

type operation_reconciliation =
  | Operation_pending of acceptance_state
  | Operation_succeeded of { outcome_ref : string }
  | Operation_failed of {
      failure_kind : string;
      detail : string;
      outcome_ref : string option;
    }
  | Operation_cancelled

type stream_error =
  | Malformed_event of string
  | Request_id_mismatch of {
      expected : string;
      received : string;
    }
  | Duplicate_acceptance
  | Duplicate_reply_details
  | Duplicate_terminal
  | Event_before_acceptance of string
  | Event_identity_mismatch of {
      field : string;
      expected : string;
      received : string;
    }
  | Unknown_event_type of string
  | Unknown_custom_event of string
  | Duplicate_run_start
  | Missing_run_start of string
  | Missing_acceptance
  | Stream_interrupted of { accepted : bool }
  | Missing_reply_details
  | Missing_text_end
  | Run_failed of {
      accepted : bool;
      message : string;
      code : string option;
    }
  | Replayed_failed
  | Replayed_cancelled

type protocol_error = {
  stream_error : stream_error;
  acceptance_observed : bool;
}

type error =
  | Transport_error of string
  | Http_error of {
      status : int;
      body : string;
    }
  | Protocol_error of protocol_error

type error_certainty =
  | Verified_rejected
  | Verified_failed
  | Outcome_unverified

let ( let* ) = Result.bind

let create_request ~keeper_name ~message =
  {
    request_id = "tui-" ^ Random_id.uuid_v7 ();
    keeper_name;
    message;
  }

let request_to_yojson request =
  `Assoc
    [ "request_id", `String request.request_id
    ; "name", `String request.keeper_name
    ; "message", `String request.message
    ]

let request_body request = Yojson.Safe.to_string (request_to_yojson request)

let same_request_identity left right =
  String.equal left.request_id right.request_id
  && String.equal left.keeper_name right.keeper_name
  && String.equal left.message right.message

let request_operation_input request =
  Masc.Keeper_chat_operation_payload.input_to_json
    ~message:(String.trim request.message)
    ~user_blocks:[]
    ~turn_instructions:None
    ~surface_context:None
    ~attachments:[]

let request_execution_digest request =
  Keeper_chat_operation.execution_digest (request_operation_input request)

let compact_request_id value =
  let length = String.length value in
  if length <= 14 then value
  else String.sub value 0 4 ^ ".." ^ String.sub value (length - 8) 8

let terminal_safe_text ?(preserve_newlines = false) text =
  let text = Safe_ops.sanitize_text_utf8 text in
  let output = Buffer.create (String.length text) in
  let rec loop offset =
    if offset < String.length text then begin
      let decoded = String.get_utf_8_uchar text offset in
      let length = Uchar.utf_decode_length decoded in
      let scalar = Uchar.utf_decode_uchar decoded in
      let code = Uchar.to_int scalar in
      if code = 0x0a && preserve_newlines then Buffer.add_char output '\n'
      else if code < 0x20 || (code >= 0x7f && code <= 0x9f) then
        Buffer.add_char output ' '
      else Buffer.add_utf_8_uchar output scalar;
      loop (offset + length)
    end
  in
  loop 0;
  Buffer.contents output

let bounded value =
  if String.length value <= 240 then value
  else String.sub value 0 240 ^ "..."

let stream_error_to_string = function
  | Malformed_event detail -> "invalid Keeper chat stream: " ^ detail
  | Request_id_mismatch { expected; received } ->
      Printf.sprintf
        "Keeper chat acceptance id mismatch: expected %S, received %S"
        expected received
  | Duplicate_acceptance -> "Keeper chat stream repeated its acceptance event"
  | Duplicate_reply_details -> "Keeper chat stream repeated its reply details"
  | Duplicate_terminal -> "Keeper chat stream emitted more than one terminal event"
  | Event_before_acceptance event_type ->
      Printf.sprintf "Keeper chat event %S arrived before acceptance" event_type
  | Event_identity_mismatch { field; expected; received } ->
      Printf.sprintf "Keeper chat %s mismatch: expected %S, received %S" field
        expected received
  | Unknown_event_type event_type ->
      Printf.sprintf "Keeper chat emitted unknown event type %S" event_type
  | Unknown_custom_event name ->
      Printf.sprintf "Keeper chat emitted unknown custom event %S" name
  | Duplicate_run_start -> "Keeper chat stream repeated RUN_STARTED"
  | Missing_run_start event_type ->
      Printf.sprintf "Keeper chat event %S arrived before RUN_STARTED" event_type
  | Missing_acceptance -> "Keeper chat stream ended without request acceptance"
  | Stream_interrupted { accepted = true } ->
      "Keeper chat stream ended after acceptance but before a terminal event"
  | Stream_interrupted { accepted = false } ->
      "Keeper chat stream ended before acceptance"
  | Missing_reply_details ->
      "Keeper chat run finished without canonical reply details"
  | Missing_text_end ->
      "Keeper chat run finished without the current text-message terminal"
  | Run_failed { accepted; message; code } ->
      let phase = if accepted then "accepted Keeper turn failed" else "Keeper chat rejected" in
      let code = Option.fold ~none:"" ~some:(Printf.sprintf " (%s)") code in
      Printf.sprintf "%s%s: %s" phase code message
  | Replayed_failed -> "Keeper chat request already has a failed terminal operation"
  | Replayed_cancelled ->
      "Keeper chat request already has a cancelled terminal operation"

let error_to_string = function
  | Transport_error detail ->
      "Keeper chat transport ended with an unverified operation outcome: "
      ^ detail
  | Http_error { status; body } ->
      Printf.sprintf "Keeper chat HTTP %d: %s" status (bounded (String.trim body))
  | Protocol_error { stream_error; _ } -> stream_error_to_string stream_error

let stream_error_acceptance_observed = function
  | Stream_interrupted { accepted }
  | Run_failed { accepted; _ } -> accepted
  | Duplicate_acceptance | Duplicate_reply_details | Unknown_custom_event _
  | Duplicate_run_start | Missing_run_start _ | Missing_reply_details
  | Missing_text_end | Replayed_failed | Replayed_cancelled -> true
  | Malformed_event _ | Request_id_mismatch _ | Duplicate_terminal
  | Event_before_acceptance _ | Event_identity_mismatch _
  | Unknown_event_type _ | Missing_acceptance -> false

let protocol_error ?(acceptance_observed = false) stream_error =
  Protocol_error
    { stream_error
    ; acceptance_observed =
        acceptance_observed || stream_error_acceptance_observed stream_error
    }

let error_acceptance_observed = function
  | Protocol_error { acceptance_observed; _ } -> acceptance_observed
  | Transport_error _ | Http_error _ -> false

let verified_pre_handler_http_rejection = function
  | 400 | 401 | 403 | 404 -> true
  | _ -> false

let error_certainty ?(was_unverified = false) error =
  let certainty =
    match error with
    | Transport_error _ -> Outcome_unverified
    | Http_error { status; _ } ->
        if verified_pre_handler_http_rejection status
        then Verified_rejected
        else Outcome_unverified
    | Protocol_error
        { stream_error =
            Run_failed
          { accepted = false
          ; code = Some ("invalid_input" | "owner_stopping" | "unknown_operation" | "not_queued")
          ; _
          }
        ; _
        } ->
        Verified_rejected
    | Protocol_error
        { stream_error = Run_failed { accepted = false; _ }; _ } ->
        Outcome_unverified
    | Protocol_error
        { stream_error =
            (Run_failed { accepted = true; _ }
            | Replayed_failed
            | Replayed_cancelled)
        ; _
        } ->
        Verified_failed
    | Protocol_error
        { stream_error =
            (Malformed_event _ | Request_id_mismatch _ | Duplicate_acceptance
            | Duplicate_reply_details | Duplicate_terminal
            | Event_before_acceptance _ | Event_identity_mismatch _
            | Unknown_event_type _ | Unknown_custom_event _ | Duplicate_run_start
            | Missing_run_start _ | Missing_acceptance | Stream_interrupted _
            | Missing_reply_details | Missing_text_end)
        ; _
        } ->
        Outcome_unverified
  in
  match was_unverified, certainty with
  | true, Verified_rejected -> Outcome_unverified
  | false, _ | true, (Verified_failed | Outcome_unverified) -> certainty

let unique_object_fields ~surface = function
  | `Assoc fields ->
      let allowed = List.map fst fields |> List.sort_uniq String.compare in
      let* () = Json_util.reject_unknown_fields ~surface ~allowed fields in
      Ok fields
  | other ->
      Error
        (Printf.sprintf "%s must be an object (received %s)" surface
           (Json_util.kind_name other))

let exact_object_fields ~surface ~allowed json =
  let* fields = unique_object_fields ~surface json in
  let* () = Json_util.reject_unknown_fields ~surface ~allowed fields in
  Ok fields

let required_string ?(allow_blank = false) ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`String value) when allow_blank || String.trim value <> "" -> Ok value
  | Some (`String _) ->
      Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some other ->
      Error
        (Printf.sprintf "%s.%s must be a string (received %s)" surface field
           (Json_util.kind_name other))
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)

let optional_string ~surface field fields =
  match List.assoc_opt field fields with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) ->
      Error (Printf.sprintf "%s.%s must be non-blank when present" surface field)
  | Some other ->
      Error
        (Printf.sprintf "%s.%s must be a string (received %s)" surface field
           (Json_util.kind_name other))

let required_nonnegative_int ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Int value) when value >= 0 -> Ok value
  | Some _ ->
      Error (Printf.sprintf "%s.%s must be a nonnegative integer" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)

let required_finite_nonnegative_number ~surface field fields =
  let valid value = Float.is_finite value && value >= 0.0 in
  match List.assoc_opt field fields with
  | Some (`Float value) when valid value -> Ok ()
  | Some (`Int value) when value >= 0 -> Ok ()
  | Some _ ->
      Error
        (Printf.sprintf "%s.%s must be a finite nonnegative number" surface
           field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)

let expected_thread_id request = "keeper:" ^ request.keeper_name
let expected_run_id request = "keeper-operation-run-" ^ request.request_id

let expected_message_id request =
  "keeper-operation-message-" ^ request.request_id

let validate_expected_string ~surface ~field ~expected fields =
  let* received =
    required_string ~surface field fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  if String.equal received expected then Ok ()
  else Error (Event_identity_mismatch { field; expected; received })

let validate_timestamp ~surface fields =
  required_finite_nonnegative_number ~surface "timestamp" fields
  |> Result.map_error (fun detail -> Malformed_event detail)

let validate_exact_fields ~surface ~allowed fields =
  Json_util.reject_unknown_fields ~surface ~allowed fields
  |> Result.map_error (fun detail -> Malformed_event detail)

let validate_thread ~surface ~expected fields =
  validate_expected_string ~surface ~field:"threadId" ~expected fields

let acceptance_state_of_string = function
  | "Queued" -> Ok Queued
  | "Running" -> Ok Running
  | "Succeeded" -> Ok Succeeded
  | "Failed" -> Ok Failed
  | "Cancelled" -> Ok Cancelled
  | value -> Error (Printf.sprintf "unknown Keeper chat operation state %S" value)

let decode_acceptance ~expected_request_id json =
  let surface = "KEEPER_CHAT_OPERATION_ACCEPTED.value" in
  let* fields =
    exact_object_fields ~surface
      ~allowed:[ "operation_id"; "state"; "queued_count" ] json
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* operation_id =
    required_string ~surface "operation_id" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* state_raw =
    required_string ~surface "state" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* state =
    acceptance_state_of_string state_raw
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* queued_count =
    required_nonnegative_int ~surface "queued_count" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  if not (String.equal operation_id expected_request_id) then
    Error (Request_id_mismatch { expected = expected_request_id; received = operation_id })
  else Ok { state; queued_count }

type reply_details = {
  reply : string;
  turn_outcome : turn_outcome;
  turn_ref : string;
}

let decode_reply_details json =
  let surface = "KEEPER_REPLY_DETAILS.value" in
  let* fields =
    exact_object_fields ~surface
      ~allowed:[ "reply"; "turn_outcome"; "turn_ref" ] json
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* reply =
    required_string ~allow_blank:true ~surface "reply" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* outcome_raw =
    required_string ~surface "turn_outcome" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* turn_outcome =
    match Keeper_turn_outcome.of_label outcome_raw with
    | Some outcome -> Ok outcome
    | None ->
        Error
          (Malformed_event
             (Printf.sprintf "%s.turn_outcome is unknown: %S" surface
                outcome_raw))
  in
  let* turn_ref =
    required_string ~surface "turn_ref" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* () =
    match Ids.Turn_ref.of_string turn_ref with
    | Some _ -> Ok ()
    | None -> Error (Malformed_event (surface ^ ".turn_ref is invalid"))
  in
  Ok { reply; turn_outcome; turn_ref }

type terminal =
  | Run_finished
  | Run_error of {
      message : string;
      code : string option;
    }

type decode_state = {
  acceptance : acceptance option;
  reply_details : reply_details option;
  terminal : terminal option;
  run_started : bool;
  text_started : bool;
  text_ended : bool;
}

let initial_decode_state =
  { acceptance = None;
    reply_details = None;
    terminal = None;
    run_started = false;
    text_started = false;
    text_ended = false;
  }

let require_acceptance state event_type =
  match state.acceptance with
  | Some _ -> Ok ()
  | None -> Error (Event_before_acceptance event_type)

let validate_run_identity request ~surface state fields =
  let* () = require_acceptance state surface in
  let accepted_running =
    match state.acceptance with
    | Some { state = (Running | Succeeded | Failed | Cancelled); _ } -> true
    | Some { state = Queued; _ } | None -> false
  in
  let* () =
    if state.run_started || accepted_running then Ok ()
    else Error (Missing_run_start surface)
  in
  let* () =
    validate_thread ~surface ~expected:(expected_thread_id request) fields
  in
  validate_expected_string ~surface ~field:"runId"
    ~expected:(expected_run_id request) fields

let current_custom_names =
  [ "KEEPER_CONNECTED"; "KEEPER_STREAM_MESSAGE_START"
  ; "KEEPER_STREAM_MESSAGE_DELTA"; "KEEPER_STREAM_MESSAGE_STOP"
  ; "KEEPER_STREAM_PING"; "KEEPER_CONTENT_BLOCK_START"
  ; "KEEPER_CONTENT_BLOCK_STOP"; "KEEPER_THINKING_DELTA"
  ; "KEEPER_THINKING_SIGNATURE_DELTA"; "KEEPER_MEDIA_DELTA"
  ; "KEEPER_STREAM_PROTOCOL_ERROR"; "KEEPER_CONTINUATION_CHECKPOINT"
  ; "KEEPER_EXTERNAL_EFFECT_COMPLETED"; "KEEPER_TOOL_RESULT_READY"
  ]

let validate_current_custom_name name =
  if List.mem name current_custom_names then Ok ()
  else Error (Unknown_custom_event name)

let validate_running_fields request state ~surface ~allowed fields =
  let* () = validate_exact_fields ~surface ~allowed fields in
  let* () = validate_timestamp ~surface fields in
  let* () = validate_run_identity request ~surface state fields in
  Ok fields

let validate_message_identity request ~surface fields =
  validate_expected_string ~surface ~field:"messageId"
    ~expected:(expected_message_id request) fields

let decode_custom_event ~request state fields =
  let surface = "Keeper chat CUSTOM event" in
  let* name =
    required_string ~surface "name" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* value =
    match List.assoc_opt "value" fields with
    | Some value -> Ok value
    | None -> Error (Malformed_event (surface ^ ".value is required"))
  in
  if String.equal name "KEEPER_CHAT_OPERATION_ACCEPTED" then
    let* () =
      validate_exact_fields ~surface
        ~allowed:[ "type"; "threadId"; "timestamp"; "name"; "value" ]
        fields
    in
    let* () = validate_timestamp ~surface fields in
    let* () = validate_thread ~surface ~expected:"default" fields in
    (match state.acceptance with
     | Some _ -> Error Duplicate_acceptance
     | None ->
         let* acceptance =
           decode_acceptance ~expected_request_id:request.request_id value
         in
         Ok { state with acceptance = Some acceptance })
  else
    let* fields =
      validate_running_fields request state ~surface
        ~allowed:
          [ "type"; "threadId"; "timestamp"; "runId"; "name"; "value" ]
        fields
    in
    if String.equal name "KEEPER_REPLY_DETAILS" then
      match state.reply_details with
      | Some _ -> Error Duplicate_reply_details
      | None ->
          let* reply_details = decode_reply_details value in
          Ok { state with reply_details = Some reply_details }
    else
      let* () = validate_current_custom_name name in
      Ok state

let decode_data_event ~request state json =
  let* fields =
    unique_object_fields ~surface:"Keeper chat event" json
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* event_type =
    required_string ~surface:"Keeper chat event" "type" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  match state.terminal with
  | Some _ -> Error Duplicate_terminal
  | None -> (
      match event_type with
      | "CUSTOM" -> decode_custom_event ~request state fields
      | "RUN_STARTED" ->
          let surface = "Keeper chat RUN_STARTED" in
          let* () = require_acceptance state event_type in
          let* () =
            validate_exact_fields ~surface
              ~allowed:[ "type"; "threadId"; "timestamp"; "runId" ]
              fields
          in
          let* () = validate_timestamp ~surface fields in
          let* () =
            validate_thread ~surface ~expected:(expected_thread_id request)
              fields
          in
          let* () =
            validate_expected_string ~surface ~field:"runId"
              ~expected:(expected_run_id request) fields
          in
          if state.run_started then Error Duplicate_run_start
          else Ok { state with run_started = true }
      | "RUN_ERROR" ->
          let surface = "Keeper chat RUN_ERROR" in
          let* () =
            match state.acceptance with
            | None ->
                let* () =
                  validate_exact_fields ~surface
                    ~allowed:
                      [ "type"; "threadId"; "timestamp"; "message"; "code" ]
                    fields
                in
                let* () = validate_timestamp ~surface fields in
                validate_thread ~surface
                  ~expected:(expected_thread_id request) fields
            | Some _ ->
                let* () =
                  validate_exact_fields ~surface
                    ~allowed:
                      [ "type"; "threadId"; "timestamp"; "runId"; "message"
                      ; "code"
                      ]
                    fields
                in
                let* () = validate_timestamp ~surface fields in
                let* () =
                  validate_thread ~surface
                    ~expected:(expected_thread_id request) fields
                in
                validate_expected_string ~surface ~field:"runId"
                  ~expected:(expected_run_id request) fields
          in
          let* message =
            required_string ~surface "message" fields
            |> Result.map_error (fun detail -> Malformed_event detail)
          in
          let* code =
            optional_string ~surface "code" fields
            |> Result.map_error (fun detail -> Malformed_event detail)
          in
          Ok { state with terminal = Some (Run_error { message; code }) }
      | "RUN_FINISHED" ->
          let surface = "Keeper chat RUN_FINISHED" in
          let* _ =
            validate_running_fields request state ~surface
              ~allowed:[ "type"; "threadId"; "timestamp"; "runId" ]
              fields
          in
          Ok { state with terminal = Some Run_finished }
      | "TEXT_MESSAGE_START" ->
          let surface = "Keeper chat TEXT_MESSAGE_START" in
          let* fields =
            validate_running_fields request state ~surface
              ~allowed:
                [ "type"; "threadId"; "timestamp"; "runId"; "messageId"
                ; "role"
                ]
              fields
          in
          let* () = validate_message_identity request ~surface fields in
          let* () =
            validate_expected_string ~surface ~field:"role"
              ~expected:"assistant" fields
          in
          if state.text_started && not state.text_ended then
            Error (Malformed_event "Keeper chat repeated TEXT_MESSAGE_START")
          else Ok { state with text_started = true; text_ended = false }
      | "TEXT_MESSAGE_CONTENT" ->
          let surface = "Keeper chat TEXT_MESSAGE_CONTENT" in
          let* fields =
            validate_running_fields request state ~surface
              ~allowed:
                [ "type"; "threadId"; "timestamp"; "runId"; "messageId"
                ; "delta"
                ]
              fields
          in
          let* () = validate_message_identity request ~surface fields in
          let accepted_running =
            match state.acceptance with
            | Some
                { state = (Running | Succeeded | Failed | Cancelled); _ } ->
                true
            | Some { state = Queued; _ } | None -> false
          in
          let* () =
            if state.text_started || accepted_running then Ok ()
            else
              Error
                (Malformed_event
                   "Keeper chat content arrived before TEXT_MESSAGE_START")
          in
          let* _delta =
            required_string ~allow_blank:true
              ~surface "delta" fields
            |> Result.map_error (fun detail -> Malformed_event detail)
          in
          Ok state
      | "TEXT_MESSAGE_END" ->
          let surface = "Keeper chat TEXT_MESSAGE_END" in
          let* fields =
            validate_running_fields request state ~surface
              ~allowed:
                [ "type"; "threadId"; "timestamp"; "runId"; "messageId" ]
              fields
          in
          let* () = validate_message_identity request ~surface fields in
          let accepted_running =
            match state.acceptance with
            | Some
                { state = (Running | Succeeded | Failed | Cancelled); _ } ->
                true
            | Some { state = Queued; _ } | None -> false
          in
          if state.text_started || accepted_running then
            Ok { state with text_ended = true }
          else
            Error
              (Malformed_event
                 "Keeper chat text ended before TEXT_MESSAGE_START")
      | "TOOL_CALL_START" ->
          let surface = "Keeper chat TOOL_CALL_START" in
          let* fields =
            validate_running_fields request state ~surface
              ~allowed:
                [ "type"; "threadId"; "timestamp"; "runId"; "toolCallId"
                ; "toolCallName"
                ]
              fields
          in
          let* _ =
            required_string ~surface "toolCallId" fields
            |> Result.map_error (fun detail -> Malformed_event detail)
          in
          let* _ =
            required_string ~surface "toolCallName" fields
            |> Result.map_error (fun detail -> Malformed_event detail)
          in
          Ok state
      | "TOOL_CALL_ARGS" ->
          let surface = "Keeper chat TOOL_CALL_ARGS" in
          let* fields =
            validate_running_fields request state ~surface
              ~allowed:
                [ "type"; "threadId"; "timestamp"; "runId"; "toolCallId"
                ; "delta"; "snapshot"
                ]
              fields
          in
          let* _ =
            required_string ~surface "toolCallId" fields
            |> Result.map_error (fun detail -> Malformed_event detail)
          in
          (match List.assoc_opt "delta" fields, List.assoc_opt "snapshot" fields with
           | Some (`String _), None | None, Some (`String _) -> Ok state
           | Some _, None ->
               Error (Malformed_event (surface ^ ".delta must be a string"))
           | None, Some _ ->
               Error (Malformed_event (surface ^ ".snapshot must be a string"))
           | Some _, Some _ | None, None ->
               Error
                 (Malformed_event
                    (surface ^ " requires exactly one of delta or snapshot")))
      | "TOOL_CALL_END" ->
          let surface = "Keeper chat TOOL_CALL_END" in
          let* fields =
            validate_running_fields request state ~surface
              ~allowed:
                [ "type"; "threadId"; "timestamp"; "runId"; "toolCallId" ]
              fields
          in
          let* _ =
            required_string ~surface "toolCallId" fields
            |> Result.map_error (fun detail -> Malformed_event detail)
          in
          Ok state
      | unknown -> Error (Unknown_event_type unknown))

let protocol_failure state stream_error =
  { stream_error
  ; acceptance_observed =
      Option.is_some state.acceptance
      || stream_error_acceptance_observed stream_error
  }

let decode_sse_with_provenance ~request body =
  let rec loop line_no state = function
    | [] -> Ok state
    | raw_line :: rest ->
        let line = String.trim raw_line in
        if line = "" || String.starts_with ~prefix:"retry:" line
           || String.starts_with ~prefix:"id:" line
           || String.starts_with ~prefix:":" line
        then loop (line_no + 1) state rest
        else if String.starts_with ~prefix:"data: " line then
          let payload =
            String.sub line 6 (String.length line - 6) |> String.trim
          in
          let* json =
            try Ok (Yojson.Safe.from_string payload)
            with Yojson.Json_error detail ->
              Error
                (protocol_failure state
                   (Malformed_event
                      (Printf.sprintf "line %d has invalid JSON: %s" line_no
                         detail)))
          in
          let* state =
            decode_data_event ~request state json
            |> Result.map_error (protocol_failure state)
          in
          loop (line_no + 1) state rest
        else if String.starts_with ~prefix:"data:" line then
          Error
            (protocol_failure state
               (Malformed_event
                  (Printf.sprintf "line %d has a non-canonical data field"
                     line_no)))
        else loop (line_no + 1) state rest
  in
  loop 1 initial_decode_state (String.split_on_char '\n' body)

let finalize state =
  match state.acceptance, state.terminal with
  | None, Some (Run_error { message; code }) ->
      Error (Run_failed { accepted = false; message; code })
  | None, Some Run_finished | None, None -> Error Missing_acceptance
  | Some acceptance, Some Run_finished -> (
      match state.reply_details, state.text_ended, acceptance.state with
      | Some details, true, _ ->
          Ok
            (Turn_completed
               {
                 acceptance;
                 reply = details.reply;
                 turn_outcome = details.turn_outcome;
                 turn_ref = details.turn_ref;
               })
      | _, _, Succeeded -> Ok (Replayed_succeeded acceptance)
      | _, _, Failed -> Error Replayed_failed
      | _, _, Cancelled -> Error Replayed_cancelled
      | None, _, (Queued | Running) -> Error Missing_reply_details
      | Some _, false, (Queued | Running) -> Error Missing_text_end)
  | Some acceptance, Some (Run_error { message; code }) -> (
      match acceptance.state with
      | Failed -> Error Replayed_failed
      | Cancelled -> Error Replayed_cancelled
      | Succeeded ->
          Error
            (Malformed_event
               "succeeded Keeper chat replay also emitted RUN_ERROR")
      | Queued | Running ->
          Error (Run_failed { accepted = true; message; code }))
  | Some acceptance, None -> (
      match acceptance.state with
      | Succeeded -> Ok (Replayed_succeeded acceptance)
      | Failed -> Error Replayed_failed
      | Cancelled -> Error Replayed_cancelled
      | Queued | Running -> Error (Stream_interrupted { accepted = true }))

let decode_response_with_provenance ~request body =
  let* state = decode_sse_with_provenance ~request body in
  finalize state |> Result.map_error (protocol_failure state)

let decode_response ~request body =
  decode_response_with_provenance ~request body
  |> Result.map_error (fun failure -> failure.stream_error)

let decode_operation_reconciliation ~request json =
  let surface = "Keeper chat operation" in
  let* fields =
    unique_object_fields ~surface json
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* state =
    required_string ~surface "state" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let state_fields =
    match state with
    | "Queued" -> Ok []
    | "Running" -> Ok [ "started_at" ]
    | "Succeeded" -> Ok [ "completed_at"; "outcome_ref" ]
    | "Failed" ->
        Ok [ "completed_at"; "failure_kind"; "failure_detail"; "outcome_ref" ]
    | "Cancelled" -> Ok [ "completed_at" ]
    | unknown ->
        Error
          (Malformed_event
             (Printf.sprintf "%s.state is unknown: %S" surface unknown))
  in
  let* state_fields = state_fields in
  let* () =
    validate_exact_fields ~surface
      ~allowed:
        ([ "schema"; "operation_id"; "sequence"; "created_at"
         ; "execution_digest"; "source"; "input"; "state"
         ]
         @ state_fields)
      fields
  in
  let* () =
    validate_expected_string ~surface ~field:"schema"
      ~expected:"masc.keeper_chat_operation.v1" fields
  in
  let* () =
    validate_expected_string ~surface ~field:"operation_id"
      ~expected:request.request_id fields
  in
  let* sequence =
    required_string ~surface "sequence" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* () =
    match Int64.of_string_opt sequence with
    | Some value when Int64.compare value 0L >= 0 -> Ok ()
    | Some _ | None ->
        Error (Malformed_event (surface ^ ".sequence must be a nonnegative int64"))
  in
  let* () =
    required_finite_nonnegative_number ~surface "created_at" fields
    |> Result.map_error (fun detail -> Malformed_event detail)
  in
  let* expected_execution_digest =
    request_execution_digest request
    |> Result.map_error (fun detail ->
      Malformed_event (surface ^ ".expected input is not canonical: " ^ detail))
  in
  let* () =
    validate_expected_string ~surface ~field:"execution_digest"
      ~expected:expected_execution_digest fields
  in
  let* () =
    match List.assoc_opt "source" fields with
    | Some (`Assoc _) -> Ok ()
    | Some other ->
        Error
          (Malformed_event
             (Printf.sprintf "%s.source must be an object (received %s)" surface
                (Json_util.kind_name other)))
    | None -> Error (Malformed_event (surface ^ ".source is required"))
  in
  let* () =
    match List.assoc_opt "input" fields with
    | Some `Null -> Ok ()
    | Some (`Assoc _ as input) ->
        let* observed_execution_digest =
          Keeper_chat_operation.execution_digest input
          |> Result.map_error (fun detail ->
            Malformed_event (surface ^ ".input is not canonical: " ^ detail))
        in
        if String.equal observed_execution_digest expected_execution_digest
        then Ok ()
        else
          Error
            (Event_identity_mismatch
               { field = "input"
               ; expected = expected_execution_digest
               ; received = observed_execution_digest
               })
    | Some other ->
        Error
          (Malformed_event
             (Printf.sprintf "%s.input must be an object or null (received %s)"
                surface (Json_util.kind_name other)))
    | None -> Error (Malformed_event (surface ^ ".input is required"))
  in
  match state with
  | "Queued" -> Ok (Operation_pending Queued)
  | "Running" ->
      let* () =
        required_finite_nonnegative_number ~surface "started_at" fields
        |> Result.map_error (fun detail -> Malformed_event detail)
      in
      Ok (Operation_pending Running)
  | "Succeeded" ->
      let* () =
        required_finite_nonnegative_number ~surface "completed_at" fields
        |> Result.map_error (fun detail -> Malformed_event detail)
      in
      let* outcome_ref =
        required_string ~surface "outcome_ref" fields
        |> Result.map_error (fun detail -> Malformed_event detail)
      in
      Ok (Operation_succeeded { outcome_ref })
  | "Failed" ->
      let* () =
        required_finite_nonnegative_number ~surface "completed_at" fields
        |> Result.map_error (fun detail -> Malformed_event detail)
      in
      let* failure_kind =
        required_string ~surface "failure_kind" fields
        |> Result.map_error (fun detail -> Malformed_event detail)
      in
      let* detail =
        required_string ~surface "failure_detail" fields
        |> Result.map_error (fun detail -> Malformed_event detail)
      in
      let* outcome_ref =
        match List.assoc_opt "outcome_ref" fields with
        | Some `Null -> Ok None
        | Some (`String value) when String.trim value <> "" -> Ok (Some value)
        | Some _ ->
            Error
              (Malformed_event
                 (surface ^ ".outcome_ref must be a nonblank string or null"))
        | None -> Error (Malformed_event (surface ^ ".outcome_ref is required"))
      in
      Ok (Operation_failed { failure_kind; detail; outcome_ref })
  | "Cancelled" ->
      let* () =
        required_finite_nonnegative_number ~surface "completed_at" fields
        |> Result.map_error (fun detail -> Malformed_event detail)
      in
      Ok Operation_cancelled
  | _ -> assert false
