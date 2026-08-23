module Projection = Masc_tui_keeper_chat_projection

type args_fragment =
  | Args_delta of string
  | Args_snapshot of string

type delta =
  | Run_started
  | Text of string
  | Thinking of string
  | Tool_started of
      { call_id : string
      ; tool_name : string
      }
  | Tool_args of
      { call_id : string
      ; fragment : args_fragment
      }
  | Tool_ended of { call_id : string }
  | Tool_result of { call_id : string }
  | Approval_requested of
      { call_id : string
      ; tool_name : string
      ; args : string
      ; question : string
      }
  | Approval_settled of
      { call_id : string
      ; outcome : string
      }
  | Checkpoint
  | External_effect_completed
  | Run_failed of { message : string }
  | Run_finished
  | Undecodable of string

type t = { pending : Buffer.t }

let create () = { pending = Buffer.create 4096 }

let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let object_field fields name =
  match List.assoc_opt name fields with
  | Some (`Assoc value) -> Some value
  | Some _ | None -> None

(* [required] reads one string field and names the event in the failure, so an
   Undecodable row says which event was short of what. *)
let required ~event ~field fields build =
  match string_field fields field with
  | Some value -> [ build value ]
  | None -> [ Undecodable (Printf.sprintf "%s has no %s" event field) ]

let tool_args_deltas fields =
  match string_field fields "toolCallId" with
  | None -> [ Undecodable "TOOL_CALL_ARGS has no toolCallId" ]
  | Some call_id -> (
      match string_field fields "delta", string_field fields "snapshot" with
      | Some delta, None -> [ Tool_args { call_id; fragment = Args_delta delta } ]
      | None, Some snapshot ->
          [ Tool_args { call_id; fragment = Args_snapshot snapshot } ]
      | Some _, Some _ ->
          [ Undecodable "TOOL_CALL_ARGS carries both delta and snapshot" ]
      | None, None ->
          [ Undecodable "TOOL_CALL_ARGS carries neither delta nor snapshot" ])

let tool_start_deltas fields =
  match string_field fields "toolCallId", string_field fields "toolCallName" with
  | Some call_id, Some tool_name -> [ Tool_started { call_id; tool_name } ]
  | None, _ -> [ Undecodable "TOOL_CALL_START has no toolCallId" ]
  | Some _, None -> [ Undecodable "TOOL_CALL_START has no toolCallName" ]

(* Custom event names the live pane draws something for. The rest are on the
   strict decoder's allowlist and validated there; they carry nothing this
   view shows, so they produce no delta. *)
let custom_deltas fields =
  match string_field fields "name" with
  | None -> [ Undecodable "CUSTOM has no name" ]
  | Some "KEEPER_THINKING_DELTA" -> (
      match object_field fields "value" with
      | None -> [ Undecodable "KEEPER_THINKING_DELTA value is not an object" ]
      | Some value ->
          required ~event:"KEEPER_THINKING_DELTA" ~field:"delta" value
            (fun delta -> Thinking delta))
  | Some "KEEPER_TOOL_RESULT_READY" -> (
      match object_field fields "value" with
      | None -> [ Undecodable "KEEPER_TOOL_RESULT_READY value is not an object" ]
      | Some value ->
          required ~event:"KEEPER_TOOL_RESULT_READY" ~field:"tool_call_id" value
            (fun call_id -> Tool_result { call_id }))
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
  | Some _ -> []

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
          required ~event:"TOOL_CALL_END" ~field:"toolCallId" fields
            (fun call_id -> Tool_ended { call_id })
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

let line_deltas raw_line =
  match Projection.classify_sse_line raw_line with
  | Projection.Sse_ignored -> []
  | Projection.Sse_noncanonical_data ->
      [ Undecodable "non-canonical data field" ]
  | Projection.Sse_data payload -> (
      match Yojson.Safe.from_string payload with
      | json -> event_deltas json
      | exception Yojson.Json_error detail ->
          [ Undecodable ("invalid JSON: " ^ detail) ])

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
      String.split_on_char '\n' complete |> List.concat_map line_deltas
