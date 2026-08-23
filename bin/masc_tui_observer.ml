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
  agent : string;
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
  hb_phase : string;
  hb_in_turn : bool;
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

type event =
  | Agent_core of agent_core
  | Keeper_heartbeat of keeper_heartbeat
  | Keeper_turn_complete of keeper_turn_complete
  | Keeper_composite_changed of { keeper : string; at : float }
  | Keeper_chat_appended of { keeper : string; connector : string option; at : float }
  | Snapshot of string
  | Other of string

type decoded =
  | Event of event
  | Undecodable of string

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
  let* agent = required string_field fields "agent_name" ~event:type_name in
  let* at = required float_field fields "ts_unix" ~event:type_name in
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
  let* hb_phase = required string_field fields "phase" ~event in
  let* hb_in_turn = required bool_field fields "in_turn" ~event in
  let* hb_at = required float_field fields "ts_unix" ~event in
  Ok
    (Keeper_heartbeat
       { hb_keeper
       ; hb_phase
       ; hb_in_turn
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
      | Some "keeper_turn_complete" -> decode_keeper_turn_complete fields
      | Some ("keeper_composite_changed" as event) ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_composite_changed { keeper; at })
      | Some ("keeper_chat_appended" as event) ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_chat_appended
                { keeper; connector = string_field fields "connector"; at })
      | Some
          (("execution_snapshot" | "operator_snapshot" | "project_snapshot") as
           name) ->
          Ok (Snapshot name)
      | Some other -> Ok (Other other))
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "event is not a JSON object"

type t = { pending : Buffer.t }

let create () = { pending = Buffer.create 4096 }

let decoded_of_line raw_line =
  match Projection.classify_sse_line raw_line with
  | Projection.Sse_ignored -> []
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
