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
  | Agent_completed of { elapsed_s : float }
  | Agent_failed of { elapsed_s : float; error_code : string; error : string }
  | Agent_yielded of { elapsed_s : float }
  | Agent_input_required of { elapsed_s : float; request_id : string; question : string }
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
  event_id : string option;
  run_id : string option;
  caused_by : string option;
  execution_id : string option;
}

type lane_resource = {
  lr_lifecycle : Masc.Lane_addon_resource_events.lifecycle;
  lr_package : string;
  lr_instance : string;
  lr_detail : string option;
  lr_at : float;
}

type keeper_heartbeat = {
  hb_keeper : string;
  hb_phase : string option;
  hb_in_turn : bool option;
  hb_in_flight_ms : float option;
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

type keeper_turn_observation = {
  to_keeper : string;
  to_session_turn : int option;
  to_total_turns : int option;
  to_at : float;
}

type keeper_tool_call = {
  kt_keeper : string;
  kt_turn : int option;
  kt_tool : string;
  kt_duration_ms : float option;
  kt_disposition : (Masc.Tui_decode.keeper_call_disposition, string) result option;
  kt_at : float;
  kt_tool_use_id : string option;
  kt_schedule : (Agent_core.Tool_contract.schedule, string) result option;
  kt_tool_args : Yojson.Safe.t option;
  kt_tool_result : Yojson.Safe.t option;
  kt_tool_args_preview : string option;
  kt_tool_output_preview : string option;
}

type event =
  | Agent_core of agent_core
  | Keeper_heartbeat of keeper_heartbeat
  | Keeper_tool_call of keeper_tool_call
  | Keeper_turn_complete of keeper_turn_complete
  | Keeper_turn_observation of keeper_turn_observation
  | Keeper_composite_changed of { keeper : string; at : float }
  | Keeper_chat_appended of { keeper : string; connector : string option; at : float }
  | Keeper_chat_stream_frame of
      { keeper : string
      ; operation_id : string
      ; seq : int option
      ; frame : string option
      ; at : float
      }
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
  (* Server push with no payload: a run registry changed, and a reader that
     shows internal runs re-fetches them. *)
  | Internal_agent_runs_changed
  (* A Lane Add-on container was acquired, failed to start, was removed, or
     could not be shown removed. It rides the agent-core family on the wire,
     but it is the lane runtime's fact, not an agent's. *)
  | Lane_resource of lane_resource
  | Snapshot of string
  | Other of string

type decoded =
  | Event of event
  | Undecodable of string

type delivery = {
  cursor : int option;
  decoded : decoded;
}

(* The keeper whose chat just gained a turn, when the event says so.
   The chat pane reloads its history on this and on nothing else, so
   the arms are spelled out: a new variant has to decide here whether
   it means the transcript changed, instead of being swallowed by a
   wildcard. *)
let chat_appended_keeper = function
  | Keeper_chat_appended { keeper; _ } -> Some keeper
  (* A turn observation numbers a provider call inside a keeper turn; it
     carries no transcript. Even the turn's own settle does not reload the
     chat, so a frame from mid-turn does not either. *)
  | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _
  | Keeper_chat_stream_frame _ | Keeper_waiting_inventory_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed | Lane_resource _
  | Snapshot _ | Other _ ->
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

let optional_string_field fields name ~event =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "%s carries a non-string %s" event name)

(* Absent is a fact the frame states ([None]); a value of the wrong shape is
   a frame this build cannot read, and is said so rather than read as
   absent. *)
let optional_int_field fields name ~event =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "%s carries a non-integer %s" event name)

(* A lifecycle payload read with the generated reader of the contract the
   bridge wrote it with. A payload that does not satisfy it is a frame this
   build cannot read, and is said so rather than drawn without its numbers. *)
let read_payload ~event_type reader payload =
  match reader (Yojson.Safe.to_string (`Assoc payload)) with
  | value -> Ok value
  | exception (Atdgen_runtime.Oj_run.Error detail | Yojson.Json_error detail) ->
      Error (Printf.sprintf "%s payload: %s" event_type detail)

let agent_core_kind ~event_type payload =
  match event_type with
  | "tool_called" -> Ok Tool_called
  | "tool_completed" -> Ok Tool_completed
  | "turn_started" -> Ok Turn_started
  | "turn_ready" -> Ok Turn_ready
  | "turn_completed" -> Ok Turn_completed
  | "agent_started" -> Ok Agent_started
  | "agent_completed" ->
      Result.map
        (fun (p : Sse_event.Types.agent_completed_payload) ->
          Agent_completed { elapsed_s = p.elapsed_s })
        (read_payload ~event_type Sse_event.Json.agent_completed_payload_of_string
           payload)
  | "agent_failed" ->
      Result.map
        (fun (p : Sse_event.Types.agent_failed_payload) ->
          Agent_failed
            { elapsed_s = p.elapsed_s; error_code = p.error_code; error = p.error })
        (read_payload ~event_type Sse_event.Json.agent_failed_payload_of_string payload)
  | "agent_yielded" ->
      Result.map
        (fun (p : Sse_event.Types.agent_yielded_payload) ->
          Agent_yielded { elapsed_s = p.elapsed_s })
        (read_payload ~event_type Sse_event.Json.agent_yielded_payload_of_string
           payload)
  | "agent_input_required" ->
      Result.map
        (fun (p : Sse_event.Types.agent_input_required_payload) ->
          Agent_input_required
            { elapsed_s = p.elapsed_s; request_id = p.request_id; question = p.question })
        (read_payload ~event_type
           Sse_event.Json.agent_input_required_payload_of_string payload)
  | "tool_approval_completed" -> Ok Tool_approval_completed
  | "telemetry_event" -> Ok Telemetry
  | other -> Ok (Agent_core_other other)

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
  let* event_id = optional_string_field fields "event_id" ~event:type_name in
  let* run_id = optional_string_field fields "run_id" ~event:type_name in
  let* caused_by = optional_string_field fields "caused_by" ~event:type_name in
  let* execution_id = optional_string_field payload "execution_id" ~event:type_name in
  let batch =
    match (int_field payload "batch_index", int_field payload "batch_size") with
    | Some index, Some size -> Some (index, size)
    | _, _ -> None
  in
  let* kind = agent_core_kind ~event_type payload in
  Ok
    (Agent_core
       { kind
       ; agent
       ; tool = string_field fields "tool_name"
       ; task = string_field fields "task_id"
       ; turn = int_field payload "turn"
       ; tool_use_id = string_field payload "tool_use_id"
       ; batch
       ; at
       ; correlation = string_field fields "correlation_id"
       ; parent = string_field fields "parent_event_id"
       ; event_id
       ; run_id
       ; caused_by
       ; execution_id
       })

(* A Lane Add-on lifecycle is recognised by walking the producer's own list
   through the producer's name and the bridge's public spelling of it, so the
   four names are not copied here. *)
let lane_resource_lifecycle event_type =
  List.find_opt
    (fun lifecycle ->
      String.equal event_type
        (Masc.Keeper_event_bridge.public_custom_event_type
           (Masc.Lane_addon_resource_events.wire_name lifecycle)))
    Masc.Lane_addon_resource_events.all

let decode_lane_resource ~type_name ~lifecycle fields =
  let* at = required float_field fields "ts_unix" ~event:type_name in
  let* payload =
    match assoc_field fields "payload" with
    | Some payload -> Ok payload
    | None -> Error (type_name ^ " carries no payload object")
  in
  let* package = required string_field payload "package_id" ~event:type_name in
  let* instance = required string_field payload "instance_id" ~event:type_name in
  let* detail = optional_string_field payload "detail" ~event:type_name in
  Ok
    (Lane_resource
       { lr_lifecycle = lifecycle
       ; lr_package = package
       ; lr_instance = instance
       ; lr_detail = detail
       ; lr_at = at
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

let keeper_schedule fields =
  let fields =
    List.filter
      (fun (key, _) ->
        match key with
        | "planned_index" | "batch_index" | "batch_size" | "execution_mode" -> true
        | _ -> false)
      fields
  in
  match fields with
  | [] -> None
  | _ -> Some (Agent_core.Execution_tool_schedule.of_yojson (`Assoc fields))

let decode_keeper_tool_call fields =
  let event = "keeper_tool_call" in
  let* kt_keeper = required string_field fields "name" ~event in
  let* kt_tool = required string_field fields "tool_name" ~event in
  let* kt_at = required float_field fields "ts_unix" ~event in
  let* kt_tool_use_id = optional_string_field fields "tool_use_id" ~event in
  let* kt_tool_args_preview = optional_string_field fields "tool_args_preview" ~event in
  let* kt_tool_output_preview = optional_string_field fields "tool_output_preview" ~event in
  let kt_tool_args = List.assoc_opt "tool_args" fields in
  let kt_tool_result = List.assoc_opt "tool_result" fields in
  Ok
    (Keeper_tool_call
       { kt_keeper
       ; kt_turn = int_field fields "turn"
       ; kt_tool
       ; kt_duration_ms = float_field fields "duration_ms"
       ; kt_disposition =
           (* Blank is no word, as the call log decoder reads it, so the two
              planes agree on what an absent disposition is. *)
           (match string_field fields "disposition" with
            | Some word when String.trim word <> "" ->
                Some (Masc.Tui_decode.keeper_call_disposition_of_string word)
            | Some _ | None -> None)
       ; kt_at
       ; kt_tool_use_id
       ; kt_schedule = keeper_schedule fields
       ; kt_tool_args
       ; kt_tool_result
       ; kt_tool_args_preview
       ; kt_tool_output_preview
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
  let* operation_id = required string_field fields "operation_id" ~event in
  let* at = required float_field fields "ts_unix" ~event in
  let frame = Option.bind (assoc_field fields "ag_ui_event") stream_frame_label in
  (* The journal seq of the event this frame projects
     ([Keeper_chat_broadcast.operation_event]); the wire terminal a settle
     synthesises carries none. *)
  let* seq = optional_int_field fields "seq" ~event in
  Ok (Keeper_chat_stream_frame { keeper; operation_id; seq; frame; at })

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

(* The hook's per-call report: [turn] is the agent session's ordinal for
   the call and [total_turns] the keeper turns completed before it. *)
let decode_keeper_turn_observation fields =
  let event = "keeper_turn_observation" in
  let* to_keeper = required string_field fields "name" ~event in
  let* to_at = required float_field fields "ts_unix" ~event in
  Ok
    (Keeper_turn_observation
       { to_keeper
       ; to_session_turn = int_field fields "turn"
       ; to_total_turns = int_field fields "total_turns"
       ; to_at
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
        -> (
          match
            Option.bind (string_field fields "event_type") lane_resource_lifecycle
          with
          | Some lifecycle -> decode_lane_resource ~type_name ~lifecycle fields
          | None -> decode_agent_core ~type_name fields)
      | Some "keeper_heartbeat" -> decode_keeper_heartbeat fields
      | Some "keeper_tool_call" -> decode_keeper_tool_call fields
      | Some "keeper_turn_complete" -> decode_keeper_turn_complete fields
      | Some "keeper_turn_observation" -> decode_keeper_turn_observation fields
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
      | Some type_name
        when String.equal type_name Masc.Internal_agent_runs_event.event_type ->
          Ok Internal_agent_runs_changed
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

type t = {
  pending : Buffer.t;
  mutable frame_cursor : (int option, string) result;
  mutable frame_data : string list;
  mutable frame_error : string option;
}

let create () =
  { pending = Buffer.create 4096; frame_cursor = Ok None; frame_data = []; frame_error = None }

let decode_payload payload =
  match Yojson.Safe.from_string payload with
  | json -> (
      match event_of_json json with
      | Ok event -> Event event
      | Error detail -> Undecodable detail)
  | exception Yojson.Json_error detail ->
      Undecodable ("invalid JSON: " ^ detail)

let finish_frame t =
  let decoded =
    match t.frame_error, t.frame_data with
    | Some reason, _ -> Some (Undecodable reason)
    | None, [] -> None
    | None, lines -> Some (decode_payload (String.concat "\n" (List.rev lines)))
  in
  let delivery =
    Option.map
      (fun decoded ->
        match t.frame_cursor with
        | Ok cursor -> { cursor; decoded }
        | Error reason -> { cursor = None; decoded = Undecodable reason })
      decoded
  in
  t.frame_cursor <- Ok None;
  t.frame_data <- [];
  t.frame_error <- None;
  Option.to_list delivery

let feed_line t raw_line =
  match Projection.classify_sse_line raw_line with
  | Projection.Sse_frame_end -> finish_frame t
  | Projection.Sse_ignored -> []
  | Projection.Sse_id cursor ->
      t.frame_cursor <-
        (if cursor >= 0 then Ok (Some cursor)
         else Error "observer replay ID must be non-negative");
      []
  | Projection.Sse_noncanonical_data ->
      t.frame_error <- Some "data line without the canonical \"data: \" prefix";
      []
  | Projection.Sse_data payload ->
      t.frame_data <- payload :: t.frame_data;
      []

(* A cursor is committed with its frame, not when an id/data line happens to
   end a network chunk. A disconnect before the blank line must replay it. *)
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
      String.split_on_char '\n' complete |> List.concat_map (feed_line t)
