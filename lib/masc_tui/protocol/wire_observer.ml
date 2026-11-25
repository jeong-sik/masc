open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let observer_stream_path = "/mcp?sse_kind=observer"

let initialize_request_body ~client_version =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("jsonrpc", `String "2.0");
        ("id", `Int 1);
        ("method", `String "initialize");
        ( "params"
        , `Assoc
            [
              ("protocolVersion", `String "2025-06-18");
              ("capabilities", `Assoc []);
              ( "clientInfo"
              , `Assoc
                  [
                    ("name", `String "masc-tui");
                    ("version", `String client_version);
                  ] );
            ] );
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
  | Some id when not (String.equal id "") -> Ok id
  | Some _ | None ->
      Error "initialize answered without an Mcp-Session-Id header"

type handshake_result = {
  handshake : Sse_wire.observer_handshake option;
  identity : Sse_wire.observer_identity option;
  needs_cold_resync : bool;
}

let validate_handshake ~cursor ~headers =
  match Sse_wire.validate_observer_response ~cursor headers with
  | Error _ as err -> err
  | Ok handshake -> (
      match Sse_wire.decode_observer_identity headers with
      | Error detail -> Error (Sse_wire.Invalid_observer_response detail)
      | Ok identity ->
          let needs_cold_resync =
            match handshake with
            | None -> Option.is_some cursor
            | Some { replay = Fresh | Resumed; _ } -> false
            | Some { replay = Resumed_after_gap _ | Reset _; _ } -> true
          in
          Ok { handshake; identity; needs_cold_resync })

type dataset_invalidation =
  | Dataset_goals
  | Dataset_backlog
  | Dataset_board
  | Dataset_memory_health of string option
  | Dataset_world_memory
  | Dataset_runtime_config
  | Dataset_provider_usage
  | Dataset_provider_standing
  | Dataset_runtime_probe
  | Dataset_tool_metrics
  | Dataset_verification_requests
  | Dataset_scheduled_automation
  | Dataset_wiki
  | Dataset_infra_sandboxes
  | Dataset_candle_ledger
  | Dataset_memory_diff
  | Dataset_logs
  | Dataset_health
  | Dataset_activity
  | Dataset_gate
  | Dataset_keepers
  | Dataset_lane_addons
  | Dataset_other of string

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
  | Agent_input_required of {
      elapsed_s : float;
      request_id : string;
      question : string;
    }
  | Tool_approval_completed
  | Telemetry
  | Relay_subscription_loss of {
      source_id : string;
      sequence : int;
      dropped_count : int;
    }
  | Agent_core_other of string

type agent_core_event = {
  kind : agent_core_kind;
  agent : string option;
  tool : string option;
  task : string option;
  turn : int option;
  tool_use_id : string option;
  at_unix : float;
  run_id : string option;
  execution_id : string option;
}

type approval_event =
  | Approval_queue_changed
  | Approval_rules_changed
  | Gate_mode_changed
  | Tool_approval_waits_changed of { keeper : string }
  | Tool_approval_mode_changed of { keeper : string }
  | Keeper_asks_changed of { keeper : string }

type event =
  | Observation_changed of Sse_event.Types.dashboard_observation_changed_payload
  | Dataset_changed of dataset_invalidation
  | Agent_core of agent_core_event
  | Keeper_heartbeat of {
      keeper : string;
      phase : string option;
      in_turn : bool option;
      in_flight_ms : float option;
      at_unix : float;
    }
  | Keeper_turn_complete of {
      keeper : string;
      turn : int option;
      model : string option;
      input_tokens : int option;
      cache_read_tokens : int option;
      cache_creation_tokens : int option;
      output_tokens : int option;
      cost_usd : float option;
      tool_calls : int option;
      at_unix : float;
    }
  | Keeper_tool_call of {
      keeper : string;
      turn : int option;
      tool : string;
      duration_ms : float option;
      tool_use_id : string option;
      at_unix : float;
    }
  | Keeper_chat_appended of {
      keeper : string;
      connector : string option;
      at_unix : float;
    }
  | Keeper_chat_queue_changed of string
  | Keeper_chat_stream_frame of {
      keeper : string;
      operation_id : string;
      seq : int option;
      frame : string option;
      at_unix : float;
    }
  | Keeper_roster_changed of string option
  | Keeper_turn_changed of { keeper : string; preview_only : bool }
  | Keeper_turn_preview of {
      keeper : string;
      update : Wire_fleet.turn_preview_update;
    }
  | Keeper_memory_journal_appended of { keeper : string; at_unix : float }
  | Board_changed of { post_id : string option }
  | Approval_changed of approval_event
  | Fusion_run_status of { keeper : string; run_id : string; status : string }
  | Gate_connector_changed of { connector : string }
  | Schedule_store_changed
  | Pending_confirms_changed
  | Goal_projection_changed
  | Runtime_config_changed
  | Transport_health_snapshot
  | Ignored_legacy of string
  | Other of string

type decoded =
  | Event of event
  | Undecodable of string

type delivery = {
  cursor : int option;
  decoded : decoded;
}

let is_legacy_stripped_type t =
  String.starts_with ~prefix:"msx_" t
  || String.starts_with ~prefix:"msx:" t
  || String.starts_with ~prefix:"keeper_skill_activation" t
  || String.equal t "skill_catalog_published"
  || String.equal t "installation_asks_changed"

let is_lane_addon_event_type t =
  String.starts_with ~prefix:"lane_addon" t
  || String.starts_with ~prefix:"masc:lane:" t

let dataset_of_wire ~keeper name =
  match String.lowercase_ascii (String.trim name) with
  | "goals" -> Dataset_goals
  | "backlog" | "tasks" -> Dataset_backlog
  | "board" -> Dataset_board
  | "memory_health" | "keeper_memory_health" -> Dataset_memory_health keeper
  | "world_memory" | "workspace_memory" -> Dataset_world_memory
  | "runtime_config" | "runtime_resolved" -> Dataset_runtime_config
  | "provider_usage" -> Dataset_provider_usage
  | "provider_standing" -> Dataset_provider_standing
  | "runtime_probe" -> Dataset_runtime_probe
  | "tool_metrics" -> Dataset_tool_metrics
  | "verification_requests" -> Dataset_verification_requests
  | "scheduled_automation" -> Dataset_scheduled_automation
  | "wiki" -> Dataset_wiki
  | "infra_sandboxes" | "sandboxes" -> Dataset_infra_sandboxes
  | "candle_ledger" | "candle" -> Dataset_candle_ledger
  | "memory_diff" -> Dataset_memory_diff
  | "logs" -> Dataset_logs
  | "health" -> Dataset_health
  | "activity" -> Dataset_activity
  | "gate" -> Dataset_gate
  | "keepers" | "keeper_composite" -> Dataset_keepers
  | "lane_addons" | "lane_addon" | "browser_observation" -> Dataset_lane_addons
  | other -> Dataset_other other

(* Custom agent-core payloads are not typed on the wire: sse_event.atd types
   only native events, and agent-core telemetry arrives as a [ctor, object]
   tuple. A kind that reads payload fields requires an object; the others
   accept any payload. *)
let require_payload_object ~event_type = function
  | Some obj -> Ok obj
  | None -> Error (Printf.sprintf "%s requires an object payload" event_type)

let decode_agent_core_kind ~event_type payload =
  match event_type with
  | "tool_called" -> Ok Tool_called
  | "tool_completed" -> Ok Tool_completed
  | "turn_started" -> Ok Turn_started
  | "turn_ready" -> Ok Turn_ready
  | "turn_completed" -> Ok Turn_completed
  | "agent_started" -> Ok Agent_started
  | "agent_completed" ->
      let* payload = require_payload_object ~event_type payload in
      let* elapsed_s = required_finite_float payload "elapsed_s" in
      Ok (Agent_completed { elapsed_s })
  | "agent_failed" ->
      let* payload = require_payload_object ~event_type payload in
      let* elapsed_s = required_finite_float payload "elapsed_s" in
      let* error_code = required_string_field payload "error_code" in
      let* error = required_string_field payload "error" in
      Ok (Agent_failed { elapsed_s; error_code; error })
  | "agent_yielded" ->
      let* payload = require_payload_object ~event_type payload in
      let* elapsed_s = required_finite_float payload "elapsed_s" in
      Ok (Agent_yielded { elapsed_s })
  | "agent_input_required" ->
      let* payload = require_payload_object ~event_type payload in
      let* elapsed_s = required_finite_float payload "elapsed_s" in
      let* request_id = required_nonblank_string payload "request_id" in
      let* question = required_string_field payload "question" in
      Ok (Agent_input_required { elapsed_s; request_id; question })
  | "tool_approval_completed" -> Ok Tool_approval_completed
  | "telemetry_event" -> Ok Telemetry
  | "relay_subscription_loss" ->
      let* payload = require_payload_object ~event_type payload in
      let* source_id = required_nonblank_string payload "source_id" in
      let* sequence = required_int_field payload "sequence" in
      let* dropped_count = required_int_field payload "dropped_count" in
      if sequence > 0 && dropped_count > 0 then
        Ok (Relay_subscription_loss { source_id; sequence; dropped_count })
      else Error "relay_subscription_loss requires positive sequence and dropped_count"
  | other -> Ok (Agent_core_other other)

let decode_agent_core json =
  let* event_type = required_nonblank_string json "event_type" in
  if is_lane_addon_event_type event_type then
    Ok (Dataset_changed Dataset_lane_addons)
  else if String.starts_with ~prefix:"msx" event_type then
    Ok (Ignored_legacy event_type)
  else
    let* at_unix = required_finite_float json "ts_unix" in
    let* agent = optional_nonblank_string json "agent_name" in
    let* tool = optional_nonblank_string json "tool_name" in
    let* task = optional_nonblank_string json "task_id" in
    let* run_id = optional_nonblank_string json "run_id" in
    let payload =
      match member "payload" json with
      | `Assoc _ as obj -> Some obj
      | `Null | `List _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `String _ ->
          None
    in
    let payload_field read key =
      match payload with Some obj -> read obj key | None -> Ok None
    in
    let* turn = payload_field optional_int_field "turn" in
    let* tool_use_id = payload_field optional_nonblank_string "tool_use_id" in
    let* execution_id = payload_field optional_nonblank_string "execution_id" in
    let* kind = decode_agent_core_kind ~event_type payload in
    Ok
      (Agent_core
         {
           kind;
           agent;
           tool;
           task;
           turn;
           tool_use_id;
           at_unix;
           run_id;
           execution_id;
         })

let decode_typed_event type_name json =
  if is_lane_addon_event_type type_name then
    Ok (Dataset_changed Dataset_lane_addons)
  else if is_legacy_stripped_type type_name then Ok (Ignored_legacy type_name)
  else if String.starts_with ~prefix:"agent_core:" type_name then
    decode_agent_core json
  else
    match type_name with
    | "dashboard_observation_changed" ->
        let payload_json =
          if has_field json "payload" then member "payload" json else json
        in
        let* payload =
          Sse_event.dashboard_observation_changed_payload_of_json payload_json
        in
        Ok (Observation_changed payload)
    | "workspace_dataset_changed" | "tui_v2_dataset_changed" ->
        let* dataset_name = required_nonblank_string json "dataset" in
        let* keeper = optional_nonblank_string json "keeper" in
        Ok (Dataset_changed (dataset_of_wire ~keeper dataset_name))
    | "keeper_heartbeat" ->
        let* keeper = required_nonblank_string json "name" in
        let* at_unix = required_finite_float json "ts_unix" in
        let* phase = optional_nonblank_string json "phase" in
        let* in_turn = optional_bool_field json "in_turn" in
        let* in_flight_ms = optional_finite_float json "in_flight_elapsed_ms" in
        Ok (Keeper_heartbeat { keeper; phase; in_turn; in_flight_ms; at_unix })
    | "keeper_turn_complete" ->
        let* keeper = required_nonblank_string json "name" in
        let* at_unix = required_finite_float json "ts_unix" in
        let* turn = optional_int_field json "turn" in
        let* model = optional_nonblank_string json "model_used" in
        let* input_tokens = optional_int_field json "input_tokens" in
        let* cache_read_tokens = optional_int_field json "cache_read_tokens" in
        let* cache_creation_tokens =
          optional_int_field json "cache_creation_tokens"
        in
        let* output_tokens = optional_int_field json "output_tokens" in
        let* cost_usd = optional_finite_float json "cost_usd" in
        let* tool_calls = optional_int_field json "tool_calls_made" in
        Ok
          (Keeper_turn_complete
             {
               keeper;
               turn;
               model;
               input_tokens;
               cache_read_tokens;
               cache_creation_tokens;
               output_tokens;
               cost_usd;
               tool_calls;
               at_unix;
             })
    | "keeper_tool_call" ->
        let* keeper = required_nonblank_string json "name" in
        let* tool = required_nonblank_string json "tool_name" in
        let* at_unix = required_finite_float json "ts_unix" in
        let* turn = optional_int_field json "turn" in
        let* duration_ms = optional_finite_float json "duration_ms" in
        let* tool_use_id = optional_nonblank_string json "tool_use_id" in
        Ok
          (Keeper_tool_call
             { keeper; turn; tool; duration_ms; tool_use_id; at_unix })
    | "keeper_waiting_inventory_changed" ->
        let* kind = required_nonblank_string json "queue_kind" in
        if String.equal kind "chat_operation" then
          let* keeper = required_nonblank_string json "keeper_name" in
          Ok (Keeper_chat_queue_changed keeper)
        else Ok (Other type_name)
    | "keeper_chat_appended" ->
        let* keeper = required_nonblank_string json "name" in
        let* at_unix = required_finite_float json "ts_unix" in
        let* connector = optional_nonblank_string json "connector" in
        Ok (Keeper_chat_appended { keeper; connector; at_unix })
    | "keeper_chat_operation_event" ->
        let* keeper = required_nonblank_string json "name" in
        let* operation_id = required_nonblank_string json "operation_id" in
        let* at_unix = required_finite_float json "ts_unix" in
        let* seq = optional_int_field json "seq" in
        let* frame =
          match optional_object_field json "ag_ui_event" with
          | Ok (Some inner) -> (
              match
                ( optional_nonblank_string inner "type"
                , optional_nonblank_string inner "name" )
              with
              | Ok (Some k), Ok (Some n) -> Ok (Some (k ^ " " ^ n))
              | Ok (Some k), Ok None -> Ok (Some k)
              | Ok None, _ -> Ok None
              | Error _ as err, _ | _, (Error _ as err) -> err)
          | Ok None -> Ok None
          | Error _ as err -> err
        in
        Ok (Keeper_chat_stream_frame { keeper; operation_id; seq; frame; at_unix })
    | "keeper_row_changed" ->
        let* keeper = required_nonblank_string json "name" in
        Ok (Keeper_roster_changed (Some keeper))
    | "keeper_roster_changed" -> Ok (Keeper_roster_changed None)
    | "keeper_turn_changed" ->
        let* keeper = required_nonblank_string json "name" in
        Ok (Keeper_turn_changed { keeper; preview_only = false })
    | "keeper_turn_preview_changed" ->
        let* keeper = required_nonblank_string json "name" in
        if has_field json "observation" then
          let* observation = required_object_field json "observation" in
          let* update = Wire_fleet.decode_turn_preview_update observation in
          Ok (Keeper_turn_preview { keeper; update })
        else Ok (Keeper_turn_changed { keeper; preview_only = true })
    | "keeper_memory_journal_appended" ->
        let* keeper = required_nonblank_string json "name" in
        let* at_unix = required_finite_float json "ts_unix" in
        Ok (Keeper_memory_journal_appended { keeper; at_unix })
    | "approval:pending" | "approval:resolved" | "approval:summary_updated" ->
        Ok (Approval_changed Approval_queue_changed)
    | "approval_rules_changed" ->
        Ok (Approval_changed Approval_rules_changed)
    | "gate_mode_changed" | "gate_external_mode_changed" ->
        Ok (Approval_changed Gate_mode_changed)
    | "keeper_tool_approval_waits_changed" ->
        let* keeper = required_nonblank_string json "name" in
        Ok (Approval_changed (Tool_approval_waits_changed { keeper }))
    | "keeper_tool_approval_mode_changed" ->
        let* keeper = required_nonblank_string json "name" in
        Ok (Approval_changed (Tool_approval_mode_changed { keeper }))
    | "keeper_asks_changed" ->
        let* keeper = required_nonblank_string json "name" in
        Ok (Approval_changed (Keeper_asks_changed { keeper }))
    | "fusion_run_status" ->
        let* run = required_object_field json "run" in
        let* run_id = required_nonblank_string run "run_id" in
        let* keeper = required_nonblank_string run "keeper" in
        let* status = required_nonblank_string run "status" in
        Ok (Fusion_run_status { keeper; run_id; status })
    | "gate_connector_changed" ->
        let* connector = required_nonblank_string json "connector" in
        Ok (Gate_connector_changed { connector })
    | "schedule_store_changed" | "scheduled_automation_changed" ->
        Ok Schedule_store_changed
    | "pending_confirms_changed" -> Ok Pending_confirms_changed
    | "goal_projection_changed" -> Ok Goal_projection_changed
    | "runtime_config_changed" -> Ok Runtime_config_changed
    | "transport_health_snapshot" -> Ok Transport_health_snapshot
    | other -> Ok (Other other)

let event_of_json json =
  match json with
  | `Assoc _ -> (
      match
        ( optional_nonblank_string json "type"
        , optional_nonblank_string json "method" )
      with
      | Ok (Some type_name), _ -> decode_typed_event type_name json
      | Ok None, Ok (Some "notifications/board") ->
          let* params = required_object_field json "params" in
          let* post_id = optional_nonblank_string params "post_id" in
          Ok (Board_changed { post_id })
      | Ok None, Ok (Some other_method) ->
          if is_legacy_stripped_type other_method then
            Ok (Ignored_legacy other_method)
          else Ok (Other other_method)
      | Ok None, Ok None -> Error "observer event carries neither type nor method"
      | Error _ as err, _ | _, (Error _ as err) -> err)
  | bad -> field_type_error "observer event" "a JSON object" bad

let parse_cursor_id = function
  | None -> Ok None
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some id when id >= 0 -> Ok (Some id)
      | Some _ | None ->
          Error (Printf.sprintf "invalid observer SSE id %S" raw))

let decode_frame (frame : Sse_wire.frame) =
  match parse_cursor_id frame.id with
  | Error reason -> { cursor = None; decoded = Undecodable reason }
  | Ok cursor -> (
      match Yojson.Safe.from_string frame.data with
      | json -> (
          match event_of_json json with
          | Ok ev -> { cursor; decoded = Event ev }
          | Error reason -> { cursor; decoded = Undecodable reason })
      | exception Yojson.Json_error detail ->
          { cursor; decoded = Undecodable ("invalid JSON: " ^ detail) })

type stream_decoder = Sse_wire.decoder

let create_stream_decoder () = Sse_wire.create_decoder ()

let feed_chunk dec chunk =
  Sse_wire.feed dec chunk |> List.map decode_frame
