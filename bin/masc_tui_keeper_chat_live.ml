module Projection = Masc_tui_keeper_chat_projection

type args_fragment =
  | Args_delta of string
  | Args_snapshot of string

type admission =
  | Queued
  | Running
  | Settled

type tool_occurrence =
  { stream_scope : int
  ; block_index : int
  ; provider_message_id : string option
  ; tool_call_id : string option
  }

type delta =
  | Run_started
  | Runtime_attempt_started
  | Text of string
  | Thinking of string
  | Tool_started of
      { occurrence : tool_occurrence
      ; tool_name : string
      }
  | Tool_args of
      { occurrence : tool_occurrence
      ; fragment : args_fragment
      }
  | Tool_ended of { occurrence : tool_occurrence }
  | Tool_result of
      { occurrence : tool_occurrence
      ; execution_id : string
      }
  | Stream_protocol_error of
      { quarantined_occurrence : tool_occurrence option
      ; detail : string
      }
  | Approval_requested of
      { call_id : string
      ; tool_name : string
      ; args : string
      ; question : string
      ; (* Why this call was held at all. The approval list screen shows it
           (#30518); without it here, the same reader answering from the chat
           pane decides without the reason. Emitted since #30518, so it is
           read with a default rather than required: an event without it is
           still a prompt that has to be answered. *)
        because : string
      }
  | Approval_settled of
      { call_id : string
      ; outcome : string
      }
  | Accepted of
      { admission : admission
      ; queue_length : int
      }
  | Checkpoint
  | External_effect_completed
  | Reply_details of
      { reply : string
      ; turn_outcome : Masc.Keeper_turn_outcome.t
      ; turn_ref : string
      }
  | Run_failed of { message : string }
  | Run_finished
  | Undecodable of string

type t =
  { pending : Buffer.t
  ; mutable pending_seq : int option
        (* The [id:] of the frame being read, held until the frame's end;
           every [data:] line of the frame is tagged with it. It lives on [t],
           not in one [feed], because a chunk may end between the two lines.
           Cleared at the frame end so a later frame without an id
           (acceptance, the settle-time run_error) cannot inherit it. *)
  }

let create () = { pending = Buffer.create 4096; pending_seq = None }

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let object_field fields name =
  match List.assoc_opt name fields with
  | Some (`Assoc value) -> Some value
  | Some _ | None -> None

let nonnegative_int_field fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) when value >= 0 -> Some value
  | Some _ | None -> None

let optional_nonblank_string fields name =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some _ -> Error (name ^ " must be a nonblank string when present")

let tool_occurrence ~event fields =
  match
    nonnegative_int_field fields "toolStreamScope",
    nonnegative_int_field fields "toolCallBlockIndex"
  with
  | Some stream_scope, Some block_index ->
    (match
       optional_nonblank_string fields "providerMessageId",
       optional_nonblank_string fields "toolCallId"
     with
     | Ok provider_message_id, Ok tool_call_id ->
       Ok { stream_scope; block_index; provider_message_id; tool_call_id }
     | Error detail, _ | _, Error detail -> Error (event ^ " " ^ detail))
  | None, _ -> Error (event ^ " has no nonnegative toolStreamScope")
  | _, None -> Error (event ^ " has no nonnegative toolCallBlockIndex")

(* [required] reads one string field and names the event in the failure, so an
   Undecodable row says which event was short of what. *)
let required ~event ~field fields build =
  match string_field fields field with
  | Some value -> [ build value ]
  | None -> [ Undecodable (Printf.sprintf "%s has no %s" event field) ]

let tool_args_deltas fields =
  match tool_occurrence ~event:"TOOL_CALL_ARGS" fields with
  | Error detail -> [ Undecodable detail ]
  | Ok occurrence -> (
      match string_field fields "delta", string_field fields "snapshot" with
      | Some delta, None -> [ Tool_args { occurrence; fragment = Args_delta delta } ]
      | None, Some snapshot ->
          [ Tool_args { occurrence; fragment = Args_snapshot snapshot } ]
      | Some _, Some _ ->
          [ Undecodable "TOOL_CALL_ARGS carries both delta and snapshot" ]
      | None, None ->
          [ Undecodable "TOOL_CALL_ARGS carries neither delta nor snapshot" ])

let tool_start_deltas fields =
  match tool_occurrence ~event:"TOOL_CALL_START" fields with
  | Error detail -> [ Undecodable detail ]
  | Ok occurrence ->
    (match string_field fields "toolCallName" with
     | Some tool_name when String.trim tool_name <> "" ->
       [ Tool_started { occurrence; tool_name } ]
     | Some _ | None -> [ Undecodable "TOOL_CALL_START has no nonblank toolCallName" ])

(* Custom event names the live pane draws something for. The rest are on the
   strict decoder's allowlist and validated there; they carry nothing this
   view shows, so they produce no delta. *)
let custom_deltas_unvalidated fields =
  match string_field fields "name" with
  | None -> [ Undecodable "CUSTOM has no name" ]
  | Some "KEEPER_THINKING_DELTA" -> (
      match object_field fields "value" with
      | None -> [ Undecodable "KEEPER_THINKING_DELTA value is not an object" ]
      | Some value ->
          required ~event:"KEEPER_THINKING_DELTA" ~field:"delta" value
            (fun delta -> Thinking delta))
  | Some "KEEPER_CHAT_OPERATION_ACCEPTED" -> (
      let event = "KEEPER_CHAT_OPERATION_ACCEPTED" in
      match List.assoc_opt "value" fields with
      | None -> [ Undecodable (event ^ " value is required") ]
      | Some value -> (
          match Projection.decode_acceptance value with
          | Error (Projection.Malformed_event detail) -> [ Undecodable detail ]
          | Error error ->
              [ Undecodable (Projection.stream_error_to_string error) ]
          | Ok acceptance ->
              let admission =
                match acceptance.Projection.state with
                | Projection.Queued -> Queued
                | Projection.Running -> Running
                | Projection.Succeeded | Projection.Failed
                | Projection.Cancelled -> Settled
              in
              [ Accepted
                  { admission; queue_length = acceptance.Projection.queued_count }
              ]))
  | Some "KEEPER_RUNTIME_ATTEMPT_STARTED" ->
    (match List.assoc_opt "value" fields with
     | Some `Null -> [ Runtime_attempt_started ]
     | Some _ | None ->
       [ Undecodable "KEEPER_RUNTIME_ATTEMPT_STARTED value must be null" ])
  | Some "KEEPER_TOOL_RESULT_READY" -> (
      match object_field fields "value" with
      | None -> [ Undecodable "KEEPER_TOOL_RESULT_READY value is not an object" ]
      | Some value -> (
          match tool_occurrence ~event:"KEEPER_TOOL_RESULT_READY" value with
          | Error detail -> [ Undecodable detail ]
          | Ok occurrence ->
            (match string_field value "executionId" with
             | Some execution_id when String.trim execution_id <> "" ->
               [ Tool_result { occurrence; execution_id } ]
             | Some _ | None ->
               [ Undecodable
                   "KEEPER_TOOL_RESULT_READY has no nonblank executionId"
               ])))
  | Some "KEEPER_STREAM_PROTOCOL_ERROR" -> (
      match object_field fields "value" with
      | None ->
          [ Undecodable "KEEPER_STREAM_PROTOCOL_ERROR value is not an object" ]
      | Some value -> (
          match string_field value "kind" with
          | Some kind
            when Option.is_some
                   (Masc.Keeper_chat_events.stream_protocol_error_kind_of_string
                      kind) ->
            let detail =
              match string_field value "reason" with
              | Some reason when String.trim reason <> "" -> kind ^ ": " ^ reason
              | Some _ | None -> kind
            in
            (match List.assoc_opt "quarantined_occurrence" value with
             | None ->
               [ Stream_protocol_error
                   { quarantined_occurrence = None; detail }
               ]
             | Some (`Assoc occurrence_fields) ->
               (match
                  tool_occurrence ~event:"KEEPER_STREAM_PROTOCOL_ERROR"
                    occurrence_fields
                with
                | Ok occurrence ->
                  [ Stream_protocol_error
                      { quarantined_occurrence = Some occurrence; detail }
                  ]
                | Error detail -> [ Undecodable detail ])
             | Some _ ->
               [ Undecodable
                   "KEEPER_STREAM_PROTOCOL_ERROR quarantined_occurrence is not an object"
               ])
          | Some _ | None ->
            [ Undecodable "KEEPER_STREAM_PROTOCOL_ERROR has no known kind" ]))
  | Some "KEEPER_TOOL_APPROVAL_REQUESTED" -> (
      match object_field fields "value" with
      | None ->
          [ Undecodable "KEEPER_TOOL_APPROVAL_REQUESTED value is not an object" ]
      | Some value -> (
          match
            ( string_field value "tool_call_id"
            , string_field value "tool_call_name"
            , string_field value "question" )
          with
          | Some call_id, Some tool_name, Some question ->
              [ Approval_requested
                  { call_id
                  ; tool_name
                  ; (* Absent arguments are drawn as none rather than dropping
                       the prompt: a reader still has to answer, and the tool
                       name plus the question is enough to. *)
                    args = Option.value ~default:"" (string_field value "args")
                  ; question
                  ; (* Same posture as args: a missing because is an older
                       emitter, not a reason to drop the ask. *)
                    because =
                      Option.value ~default:"" (string_field value "because")
                  }
              ]
          | _ ->
              [ Undecodable
                  "KEEPER_TOOL_APPROVAL_REQUESTED needs tool_call_id, \
                   tool_call_name and question"
              ]))
  | Some "KEEPER_TOOL_APPROVAL_SETTLED" -> (
      match object_field fields "value" with
      | None ->
          [ Undecodable "KEEPER_TOOL_APPROVAL_SETTLED value is not an object" ]
      | Some value -> (
          match
            (string_field value "tool_call_id", string_field value "outcome")
          with
          | Some call_id, Some outcome -> [ Approval_settled { call_id; outcome } ]
          | _ ->
              [ Undecodable
                  "KEEPER_TOOL_APPROVAL_SETTLED needs tool_call_id and outcome"
              ]))
  | Some "KEEPER_CONTINUATION_CHECKPOINT" -> [ Checkpoint ]
  | Some "KEEPER_EXTERNAL_EFFECT_COMPLETED" -> [ External_effect_completed ]
  | Some "KEEPER_REPLY_DETAILS" -> (
      (* The same three fields the strict decoder requires
         (decode_reply_details); read leniently here, as every other event. *)
      match object_field fields "value" with
      | None -> [ Undecodable "KEEPER_REPLY_DETAILS value is not an object" ]
      | Some value -> (
          match
            ( string_field value "reply"
            , Option.bind (string_field value "turn_outcome")
                Masc.Keeper_turn_outcome.of_label
            , string_field value "turn_ref" )
          with
          | Some reply, Some turn_outcome, Some turn_ref
            when String.trim turn_ref <> "" ->
              [ Reply_details { reply; turn_outcome; turn_ref } ]
          | _ ->
              [ Undecodable
                  "KEEPER_REPLY_DETAILS needs reply, a known turn_outcome and \
                   a nonblank turn_ref"
              ]))
  | Some name when List.mem name Projection.known_custom_names -> []
  | Some name -> [ Undecodable ("unknown CUSTOM event name: " ^ name) ]

let custom_deltas fields =
  match string_field fields "name", List.assoc_opt "value" fields with
  | Some name, Some value ->
    (match Projection.validate_custom_value ~name value with
     | Ok () -> custom_deltas_unvalidated fields
     | Error (Projection.Malformed_event detail) -> [ Undecodable detail ]
     | Error error ->
       [ Undecodable (Projection.stream_error_to_string error) ])
  | None, _ | Some _, None -> custom_deltas_unvalidated fields

(* Annotated rather than inferred. Without it the parameter widens to an open
   variant, every tag listed below is accepted whether or not Yojson has it,
   and the exhaustiveness this match is written for stops being checked
   against anything. That is how the two arms removed here -- `Tuple and
   `Variant, dropped by yojson 3 -- read as covered cases while being
   unreachable. *)
let event_deltas (event : Yojson.Safe.t) =
  match event with
  | `Assoc fields -> (
      match string_field fields "type" with
      | None -> [ Undecodable "event has no type" ]
      | Some "RUN_STARTED" -> [ Run_started ]
      | Some "RUN_FINISHED" -> [ Run_finished ]
      | Some "RUN_ERROR" ->
          (* A run error with no message is still a failed run, so this reports
             the failure rather than an Undecodable line about the field. *)
          [ Run_failed
              { message =
                  Option.value ~default:"" (string_field fields "message")
              }
          ]
      | Some "TEXT_MESSAGE_CONTENT" ->
          required ~event:"TEXT_MESSAGE_CONTENT" ~field:"delta" fields
            (fun delta -> Text delta)
      | Some "TOOL_CALL_START" -> tool_start_deltas fields
      | Some "TOOL_CALL_ARGS" -> tool_args_deltas fields
      | Some "TOOL_CALL_END" ->
          (match tool_occurrence ~event:"TOOL_CALL_END" fields with
           | Ok occurrence -> [ Tool_ended { occurrence } ]
           | Error detail -> [ Undecodable detail ])
      | Some "CUSTOM" -> custom_deltas fields
      (* Accepted by the strict decode, nothing for this view to draw. *)
      | Some
          ( "TEXT_MESSAGE_START" | "TEXT_MESSAGE_END" | "STEP_STARTED"
          | "STEP_FINISHED" | "STATE_SNAPSHOT" | "STATE_DELTA" ) ->
          []
      | Some unknown ->
          [ Undecodable (Printf.sprintf "unknown event type %s" unknown) ])
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      (* Spelled out rather than left to a catch-all so a new Yojson variant
         stops the build instead of landing here. *)
      [ Undecodable "event is not a JSON object" ]

let line_deltas t raw_line =
  let tagged deltas = List.map (fun delta -> (t.pending_seq, delta)) deltas in
  match Projection.classify_sse_line raw_line with
  | Projection.Sse_ignored -> []
  | Projection.Sse_id seq ->
      t.pending_seq <- Some seq;
      []
  | Projection.Sse_frame_end ->
      t.pending_seq <- None;
      []
  | Projection.Sse_noncanonical_data ->
      tagged [ Undecodable "non-canonical data field" ]
  | Projection.Sse_data payload -> (
      match Yojson.Safe.from_string payload with
      | json -> tagged (event_deltas json)
      | exception Yojson.Json_error detail ->
          tagged [ Undecodable ("invalid JSON: " ^ detail) ])

let feed t chunk =
  Buffer.add_string t.pending chunk;
  let buffered = Buffer.contents t.pending in
  match String.rindex_opt buffered '\n' with
  | None ->
      (* No line has ended yet. Holding the bytes is the whole point: half a
         line parses as invalid JSON, and reporting that would be wrong. *)
      []
  | Some last_newline ->
      let complete = String.sub buffered 0 last_newline in
      let remainder =
        String.sub buffered (last_newline + 1)
          (String.length buffered - last_newline - 1)
      in
      Buffer.clear t.pending;
      Buffer.add_string t.pending remainder;
      (* [concat_map] visits lines in order, which the [pending_seq] state
         depends on: an id line must be seen before the data line it tags. *)
      String.split_on_char '\n' complete |> List.concat_map (line_deltas t)
