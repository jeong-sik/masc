(** Typed SSE Observer event and handshake decoder.

    Built over {!Sse_wire} and {!Sse_event}, routing live [lane_addon*] events
    into {!Dataset_lane_addons} while stripping dead legacy MSX and
    skill-activation events into {!Ignored_legacy}. *)

val observer_stream_path : string
val initialize_request_body : client_version:string -> string
val session_header : string
val session_id_of_headers : (string * string) list -> (string, string) result

type handshake_result = {
  handshake : Sse_wire.observer_handshake option;
  identity : Sse_wire.observer_identity option;
  needs_cold_resync : bool;
}

val validate_handshake :
  cursor:Sse_wire.observer_cursor option ->
  headers:(string * string) list ->
  (handshake_result, Sse_wire.observer_validation_error) result
(** Validate observer response headers against the requested replay [cursor]
    using {!Sse_wire.validate_observer_response} and
    {!Sse_wire.decode_observer_identity}. Sets [needs_cold_resync = true] when
    replay experienced a gap ([Resumed_after_gap]) or reset ([Reset]). *)

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
  | Keeper_turn_succeeded of {
      keeper : string;
      elapsed_ms : int;
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
  | Keeper_waiting_inventory_changed of { keeper : string; queue_kind : string }
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

val event_of_json : Yojson.Safe.t -> (event, string) result
val decode_frame : Sse_wire.frame -> delivery

type stream_decoder

val create_stream_decoder : unit -> stream_decoder
val feed_chunk : stream_decoder -> string -> delivery list
(** Feed arbitrary UTF-8 chunk bytes into the {!Sse_wire.decoder} and return
    all complete decoded observer deliveries. *)
