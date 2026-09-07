module Projection = Masc_tui_keeper_chat_projection

let initialize_request_body ~client_version =
  Yojson.Safe.to_string
    (`Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", `Int 1)
      ; ("method", `String "initialize")
      ; ( "params"
        , `Assoc
            [ ("protocolVersion", `String "2025-06-18")
            ; ("capabilities", `Assoc [])
            ; ( "clientInfo"
              , `Assoc
                  [ ("name", `String "masc-tui")
                  ; ("version", `String client_version)
                  ] )
            ] )
      ])

let session_header = "mcp-session-id"

let session_id_of_headers headers =
  match
    List.find_map
      (fun (name, value) ->
        if String.equal (String.lowercase_ascii name) session_header then
          Some (String.trim value)
        else None)
      headers
  with
  | Some id when id <> "" -> Ok id
  | Some _ | None ->
      Error "initialize answered without an Mcp-Session-Id header"

type agent_core_kind =
  | Tool_called
  | Tool_completed
  | Turn_started
  | Turn_ready
  | Turn_completed
  | Agent_started
  | Agent_completed
  | Agent_failed
  | Agent_yielded
  | Tool_approval_completed
  | Telemetry
  | Agent_core_other of string

type agent_core = {
  kind : agent_core_kind;
  agent : string option;
  tool : string option;
  task : string option;
  turn : int option;
  tool_use_id : string option;
  batch : (int * int) option;
  at : float;
  correlation : string option;
  parent : string option;
}

type keeper_heartbeat = {
  hb_keeper : string;
  hb_phase : string option;
  hb_in_turn : bool option;
  hb_in_flight_ms : float option;
  hb_since_progress_ms : float option;
  hb_at : float;
}

type keeper_turn_complete = {
  tc_keeper : string;
  tc_turn : int option;
  tc_model : string option;
  tc_input_tokens : int option;
  tc_output_tokens : int option;
  tc_cost_usd : float option;
  tc_tool_calls : int option;
  tc_at : float;
}

type keeper_tool_call = {
  kt_keeper : string;
  kt_turn : int option;
  kt_tool : string;
  kt_duration_ms : float option;
  kt_disposition : string option;
  kt_at : float;
}

type event =
  | Agent_core of agent_core
  | Keeper_heartbeat of keeper_heartbeat
  | Keeper_tool_call of keeper_tool_call
  | Keeper_turn_complete of keeper_turn_complete
  | Keeper_composite_changed of { keeper : string; at : float }
  | Keeper_chat_appended of { keeper : string; connector : string option; at : float }
  | Keeper_chat_stream_frame of
      { keeper : string; frame : string option; at : float }
  | Keeper_waiting_inventory_changed of
      { keeper : string; queue_kind : string option; at : float }
  (* Server push, not a keeper act: a fusion deliberation changed stage or
     settled. The Fusion surface treats it as a reload trigger the way the
     dashboard does (sse-store: event = trigger, HTTP = SSOT); the payload
     is not the data. Only the three strings the Acting row wants are read
     here -- the run itself is re-fetched, so unlike the keeper events this
     carries no [at]: nothing computes a duration from it. *)
  | Fusion_run_status of
      { keeper : string; run_id : string; status : string }
  | Snapshot of string
  | Other of string

type decoded =
  | Event of event
  | Undecodable of string

(* The keeper whose chat just gained a turn, when the event says so.
   The chat pane reloads its history on this and on nothing else, so
   the arms are spelled out: a new variant has to decide here whether
   it means the transcript changed, instead of being swallowed by a
   wildcard. *)
let chat_appended_keeper = function
  | Keeper_chat_appended { keeper; _ } -> Some keeper
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _ | Keeper_composite_changed _
  | Keeper_chat_stream_frame _ | Keeper_waiting_inventory_changed _
  | Fusion_run_status _ | Snapshot _ | Other _ ->
      None

(* Field readers over one object's assoc list. Each answers [None] for an
   absent field and for one of the wrong shape; the required readers below
   turn that into the error the caller reports. *)
let string_field fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None

let float_field fields name =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Some value
  | Some (`Int value) -> Some (float_of_int value)
  | Some _ | None -> None

let int_field fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | Some _ | None -> None

let bool_field fields name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Some value
  | Some _ | None -> None

let assoc_field fields name =
  match List.assoc_opt name fields with
  | Some (`Assoc inner) -> Some inner
  | Some _ | None -> None

let required reader fields name ~event =
  match reader fields name with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s carries no %s" event name)

let agent_core_kind_of_event_type = function
  | "tool_called" -> Tool_called
  | "tool_completed" -> Tool_completed
  | "turn_started" -> Turn_started
  | "turn_ready" -> Turn_ready
  | "turn_completed" -> Turn_completed
  | "agent_started" -> Agent_started
  | "agent_completed" -> Agent_completed
  | "agent_failed" -> Agent_failed
  | "agent_yielded" -> Agent_yielded
  | "tool_approval_completed" -> Tool_approval_completed
  | "telemetry_event" -> Telemetry
  | other -> Agent_core_other other

let ( let* ) = Result.bind

let agent_core_prefix = "agent_core:"

(* The family is recognised by its [type] prefix; the kind inside it by
   [event_type], which the server writes beside the type on every row. *)
let decode_agent_core ~type_name fields =
  let* event_type = required string_field fields "event_type" ~event:type_name in
  let* at = required float_field fields "ts_unix" ~event:type_name in
  (* Provider streaming telemetry rides this family with a null agent and a
     list payload; it is still an event of the family, with no agent. *)
  let agent = string_field fields "agent_name" in
  let payload = Option.value ~default:[] (assoc_field fields "payload") in
  let batch =
    match (int_field payload "batch_index", int_field payload "batch_size") with
    | Some index, Some size -> Some (index, size)
    | _, _ -> None
  in
  Ok
    (Agent_core
       { kind = agent_core_kind_of_event_type event_type
       ; agent
       ; tool = string_field fields "tool_name"
       ; task = string_field fields "task_id"
       ; turn = int_field payload "turn"
       ; tool_use_id = string_field payload "tool_use_id"
       ; batch
       ; at
       ; correlation = string_field fields "correlation_id"
       ; parent = string_field fields "parent_event_id"
       })

let decode_keeper_heartbeat fields =
  let event = "keeper_heartbeat" in
  let* hb_keeper = required string_field fields "name" ~event in
  let* hb_at = required float_field fields "ts_unix" ~event in
  (* The bare beat carries only name and time; the in-turn beat adds phase
     and progress. Both are heartbeats. *)
  Ok
    (Keeper_heartbeat
       { hb_keeper
       ; hb_phase = string_field fields "phase"
       ; hb_in_turn = bool_field fields "in_turn"
       ; hb_in_flight_ms = float_field fields "in_flight_elapsed_ms"
       ; hb_since_progress_ms = float_field fields "since_last_progress_ms"
       ; hb_at
       })

let decode_keeper_turn_complete fields =
  let event = "keeper_turn_complete" in
  let* tc_keeper = required string_field fields "name" ~event in
  let* tc_at = required float_field fields "ts_unix" ~event in
  Ok
    (Keeper_turn_complete
       { tc_keeper
       ; tc_turn = int_field fields "turn"
       ; tc_model = string_field fields "model_used"
       ; tc_input_tokens = int_field fields "input_tokens"
       ; tc_output_tokens = int_field fields "output_tokens"
       ; tc_cost_usd = float_field fields "cost_usd"
       ; tc_tool_calls = int_field fields "tool_calls_made"
       ; tc_at
       })

let decode_keeper_tool_call fields =
  let event = "keeper_tool_call" in
  let* kt_keeper = required string_field fields "name" ~event in
  let* kt_tool = required string_field fields "tool_name" ~event in
  let* kt_at = required float_field fields "ts_unix" ~event in
  Ok
    (Keeper_tool_call
       { kt_keeper
       ; kt_turn = int_field fields "turn"
       ; kt_tool
       ; kt_duration_ms = float_field fields "duration_ms"
       ; kt_disposition = string_field fields "disposition"
       ; kt_at
       })

(* The [ag_ui_event] frame names itself in [type]; only CUSTOM adds a [name],
   so pairing the two labels the frame without matching on any literal. *)
let stream_frame_label inner =
  match string_field inner "type", string_field inner "name" with
  | Some kind, Some name -> Some (kind ^ " " ^ name)
  | Some kind, None -> Some kind
  | None, (Some _ | None) -> None

(* A live chat stream frame. The dashboard reads these to draw the keeper's
   reply as it arrives, so the server is right to broadcast them; the TUI was
   simply never taught the type and drew every one as an unnamed row with no
   time and no keeper -- the fields were in the frame all along. *)
let decode_keeper_chat_operation_event fields =
  let event = "keeper_chat_operation_event" in
  let* keeper = required string_field fields "name" ~event in
  let* at = required float_field fields "ts_unix" ~event in
  let frame = Option.bind (assoc_field fields "ag_ui_event") stream_frame_label in
  Ok (Keeper_chat_stream_frame { keeper; frame; at })

(* Names the keeper in [keeper_name] rather than [name] -- the one broadcast
   in this family that does. Reading the field it actually sends is why this
   needs its own decoder instead of [decode_named_keeper_event]. *)
let decode_keeper_waiting_inventory_changed fields =
  let event = "keeper_waiting_inventory_changed" in
  let* keeper = required string_field fields "keeper_name" ~event in
  let* at = required float_field fields "ts_unix" ~event in
  Ok
    (Keeper_waiting_inventory_changed
       { keeper; queue_kind = string_field fields "queue_kind"; at })

let decode_named_keeper_event ~event fields make =
  let* keeper = required string_field fields "name" ~event in
  let* at = required float_field fields "ts_unix" ~event in
  Ok (make ~keeper ~at)

let event_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> (
      match string_field fields "type" with
      | None -> Error "event carries no type"
      | Some type_name when String.starts_with ~prefix:agent_core_prefix type_name
        ->
          decode_agent_core ~type_name fields
      | Some "keeper_heartbeat" -> decode_keeper_heartbeat fields
      | Some "keeper_tool_call" -> decode_keeper_tool_call fields
      | Some "keeper_turn_complete" -> decode_keeper_turn_complete fields
      | Some ("keeper_composite_changed" as event) ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_composite_changed { keeper; at })
      | Some "keeper_chat_operation_event" ->
          decode_keeper_chat_operation_event fields
      | Some "keeper_waiting_inventory_changed" ->
          decode_keeper_waiting_inventory_changed fields
      | Some "fusion_run_status" -> (
          (* The frame carries no [ts_unix]; reception time is the timestamp
             the Acting row wants. The run object is the same shape the HTTP
             list serves, but only its identity strings are read -- the Fusion
             surface re-fetches on this trigger instead of trusting the
             payload as data. *)
          match assoc_field fields "run" with
          | Some run_fields -> (
              match
                ( required string_field run_fields "run_id"
                    ~event:"fusion_run_status"
                , required string_field run_fields "keeper"
                    ~event:"fusion_run_status"
                , required string_field run_fields "status"
                    ~event:"fusion_run_status" )
              with
              | Ok run_id, Ok keeper, Ok status ->
                  Ok (Fusion_run_status { keeper; run_id; status })
              | Error detail, _, _ | _, Error detail, _ | _, _, Error detail ->
                  Error detail)
          | None -> Error "fusion_run_status carries no run object")
      | Some ("keeper_chat_appended" as event) ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_chat_appended
                { keeper; connector = string_field fields "connector"; at })
      | Some other -> (
          (* Which event types are whole-projection pushes is the wire's
             business, not this decoder's. Three were named here and the
             server routes five: the two that were missing --
             [operator_digest] and [transport_health_snapshot] -- arrived as
             untaught types, and an untaught type counts as an action, so the
             Acting filter that exists to show what a keeper did filled with
             server pushes instead. Both were on screen when this was found.

             [Dashboard_event_slices] is that table, read here and by the
             server that routes with it. The table says which types replace a
             projection outright, so a delta is not mistaken for one -- and
             the keeper events, including the one delta with a slice, are
             matched above and never reach here anyway. *)
          match
            Masc.Dashboard_event_slices.carries_whole_projection other
          with
          | true -> Ok (Snapshot other)
          | false -> Ok (Other other)))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "event is not a JSON object"

type t = { pending : Buffer.t }

let create () = { pending = Buffer.create 4096 }

let decoded_of_line raw_line =
  match Projection.classify_sse_line raw_line with
  | Projection.Sse_ignored | Projection.Sse_id _ | Projection.Sse_frame_end -> []
  | Projection.Sse_noncanonical_data ->
      [ Undecodable "data line without the canonical \"data: \" prefix" ]
  | Projection.Sse_data payload -> (
      match Yojson.Safe.from_string payload with
      | json -> (
          match event_of_json json with
          | Ok event -> [ Event event ]
          | Error detail -> [ Undecodable detail ])
      | exception Yojson.Json_error detail ->
          [ Undecodable ("invalid JSON: " ^ detail) ])

(* Same cut as the live chat reader: everything up to the last newline is
   complete, the rest is held. The server writes one event per data line,
   so a line is a frame here. *)
let feed t chunk =
  Buffer.add_string t.pending chunk;
  let buffered = Buffer.contents t.pending in
  match String.rindex_opt buffered '\n' with
  | None -> []
  | Some last_newline ->
      let complete = String.sub buffered 0 last_newline in
      let remainder =
        String.sub buffered (last_newline + 1)
          (String.length buffered - last_newline - 1)
      in
      Buffer.clear t.pending;
      Buffer.add_string t.pending remainder;
      String.split_on_char '\n' complete |> List.concat_map decoded_of_line
