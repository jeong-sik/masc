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

(* The two journals a Keeper's runtime fills beside its chat. *)
type runtime_journal = Native_tasks_journal | Child_content_journal

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
  | Relay_subscription_loss of { source_id : string; sequence : int; dropped_count : int }
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
  tc_cache_read_tokens : int option;
  tc_cache_creation_tokens : int option;
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

type approval_change =
  | Approval_queue_changed
  | Approval_rules_changed
  | Gate_mode_changed
  | Gate_keeper_settings_changed of { keeper : string }
  | Tool_approval_waits_changed of { keeper : string }
  | Tool_approval_mode_changed of { keeper : string }
  | Keeper_asks_changed of { keeper : string }
  | Installation_asks_changed of { declaration_id : string }

type roster_change =
  | Keeper_row_changed of { keeper : string }
  | Every_row_changed

type turn_change =
  | Turn_state
  | Turn_preview

(* A workspace store that announces a write with a payload-less server
   push. A reader that shows the store reads it again. *)
type workspace_store =
  | Schedule_store
  (* A schedule ledger write was attempted, a runner tick changed the list,
     or its status passed the staleness deadline. *)
  | Pending_confirms
  (* The Goal store, the verification ledger, the measurement store or the
     verifier's observations. *)
  | Goal_projection
  (* runtime.toml: the server committed a text of it. *)
  | Runtime_config
  (* A workspace skill catalog snapshot was published. *)
  | Skill_catalog
  (* A Lane Add-on's exported tools or their readiness changed. *)
  | Lane_addon_exports

(* A whole-projection push. The TUI re-reads what [Transport_health]
   measures; the others are named for the Acting row only. *)
type projection =
  | Transport_health
  | Unread_projection of string

let projection_name = function
  | Transport_health -> Masc.Dashboard_event_slices.transport_health_snapshot_type
  | Unread_projection name -> name

type event =
  | Agent_core of agent_core
  | Keeper_heartbeat of keeper_heartbeat
  | Keeper_tool_call of keeper_tool_call
  | Keeper_turn_complete of keeper_turn_complete
  | Keeper_turn_observation of keeper_turn_observation
  | Keeper_composite_changed of { keeper : string; at : float }
  | Keeper_metrics_appended of { keeper : string; at : float }
  | Keeper_chat_appended of { keeper : string; connector : string option; at : float }
  | Keeper_memory_journal_appended of { keeper : string; at : float }
  (* A Keeper's native task or child content journal took a record. *)
  | Keeper_runtime_journal_appended of
      { keeper : string; journal : runtime_journal; at : float }
  | Keeper_chat_stream_frame of
      { keeper : string
      ; operation_id : string
      ; seq : int option
      ; frame : string option
      ; at : float
      }
  | Keeper_turn_stream_frame of
      { keeper : string; turn_ref : Ids.Turn_ref.t; seq : int; at : float }
  | Keeper_waiting_inventory_changed of
      { keeper : string; queue_kind : string option; at : float }
  | Keeper_async_requests_changed of { keeper : string }
  | Keeper_skill_activations_changed of { keeper : string }
  (* Server push: a Keeper's roster row, or every row, may have changed. *)
  | Keeper_roster_change of roster_change
  (* Server push: what the turns answer says of a Keeper may have changed. *)
  | Keeper_turn_changed of { keeper : string; change : turn_change }
  (* Server push, not a keeper act: a fusion deliberation changed stage or
     settled. The Fusion surface treats it as a reload trigger the way the
     dashboard does (sse-store: event = trigger, HTTP = SSOT); the payload
     is not the data. Only the three strings the Acting row wants are read
     here -- the run itself is re-fetched, so unlike the keeper events this
     carries no [at]: nothing computes a duration from it. *)
  | Fusion_run_status of
      { keeper : string; run_id : string; status : string }
  (* Server push: the named run registry changed, and a reader that shows
     that registry's runs re-fetches them. *)
  | Internal_agent_runs_changed of Masc.Internal_agent_runs_event.registry
  (* Server push with no payload: the named workspace store was written. *)
  | Workspace_store_changed of workspace_store
  (* Server push: one of the workspace's datasets was written. It carries the
     dataset's name and none of its data. *)
  | Dataset_changed of Masc.Workspace_dataset_event.dataset
  (* Server push: a connector's bindings, recorded names or drawn connection
     state changed. A reader that shows connectors re-fetches them. *)
  | Gate_connector_changed of { connector : string }
  (* Server push: one Keeper's event queue, or the reaction record beside it,
     was written. A reader that shows that Keeper's queue evidence -- the
     schedule rows do -- re-fetches it. *)
  | Keeper_event_queue_changed of { keeper : string }
  (* Server push: a Board write. The Board re-reads on it; [post_id] is the
     post the params name, if any. *)
  | Board_changed of { post_id : string option }
  (* Server push: the Gate, a held tool call or a tool approval mode
     changed. *)
  | Approval_change of approval_change
  (* A Lane Add-on container was acquired, failed to start, was removed, or
     could not be shown removed. It rides the agent-core family on the wire,
     but it is the lane runtime's fact, not an agent's. *)
  | Lane_resource of lane_resource
  | Snapshot of projection
  (* The execution snapshot: a backlog or goal index write, or the server's
     periodic refresh. Readers of the Work surface and the Verification queue
     read again on it. *)
  | Execution_snapshot
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
  | Keeper_composite_changed _ | Keeper_metrics_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let composite_changed_keeper = function
  | Keeper_composite_changed { keeper; _ } -> Some keeper
  | Keeper_metrics_appended _ | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let metrics_appended_keeper = function
  | Keeper_metrics_appended { keeper; _ } -> Some keeper
  | Keeper_composite_changed _ | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let tool_call_keeper = function
  | Keeper_tool_call { kt_keeper; _ } -> Some kt_keeper
  | Keeper_composite_changed _ | Keeper_metrics_appended _ | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _
  | Keeper_turn_observation _ | Agent_core _ | Keeper_heartbeat _
  | Keeper_turn_complete _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let memory_journal_appended_keeper = function
  | Keeper_memory_journal_appended { keeper; _ } -> Some keeper
  | Keeper_runtime_journal_appended _
  | Keeper_chat_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let held_calls_changed = function
  | Approval_change (Tool_approval_waits_changed _) -> true
  | Approval_change
      ( Approval_queue_changed | Approval_rules_changed | Gate_mode_changed
      | Gate_keeper_settings_changed _ | Tool_approval_mode_changed _
      | Keeper_asks_changed _ | Installation_asks_changed _ )
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Lane_resource _
  | Snapshot _ | Execution_snapshot | Other _ ->
      false

let tool_modes_changed = function
  | Approval_change (Tool_approval_mode_changed _ | Gate_keeper_settings_changed _) -> true
  | Approval_change
      ( Approval_queue_changed | Approval_rules_changed | Gate_mode_changed
      | Tool_approval_waits_changed _ | Keeper_asks_changed _ | Installation_asks_changed _ )
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Lane_resource _
  | Snapshot _ | Execution_snapshot | Other _ ->
      false

let async_requests_changed = function
  | Keeper_async_requests_changed _ -> true
  | Keeper_skill_activations_changed _
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      false

let async_requests_keeper = function
  | Keeper_async_requests_changed { keeper } -> Some keeper
  | Keeper_skill_activations_changed _
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let skill_activations_keeper = function
  | Keeper_skill_activations_changed { keeper } -> Some keeper
  | Keeper_async_requests_changed _
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let skill_catalog_published = function
  | Workspace_store_changed Skill_catalog -> true
  | Workspace_store_changed (Schedule_store | Pending_confirms | Goal_projection | Runtime_config | Lane_addon_exports)
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      false

let lane_addon_exports_changed = function
  | Workspace_store_changed Lane_addon_exports -> true
  | Workspace_store_changed (Schedule_store | Pending_confirms | Goal_projection | Runtime_config | Skill_catalog)
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      false

let dataset_owed = function
  | Dataset_changed dataset -> Some dataset
  (* The Verification queue's rows read their review from this registry. *)
  | Internal_agent_runs_changed Masc.Internal_agent_runs_event.Verification ->
      Some Masc.Workspace_dataset_event.Verification_requests
  | Internal_agent_runs_changed
      (Masc.Internal_agent_runs_event.Goal_verification | Masc.Internal_agent_runs_event.Exact_lane)
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Workspace_store_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _
  | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let gate_connector_changed = function
  | Gate_connector_changed _ -> true
  | Workspace_store_changed _
  | Dataset_changed _
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Keeper_event_queue_changed _
  | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      false

let goal_projection_changed = function
  | Workspace_store_changed Goal_projection -> true
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed (Schedule_store | Pending_confirms | Skill_catalog | Runtime_config | Lane_addon_exports) | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _
  | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      false

let transport_health_measured = function
  | Snapshot Transport_health -> true
  | Snapshot (Unread_projection _)
  | Dataset_changed _
  | Internal_agent_runs_changed _
  | Workspace_store_changed _
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Gate_connector_changed _ | Keeper_event_queue_changed _
  | Board_changed _ | Approval_change _
  | Lane_resource _ | Execution_snapshot | Other _ ->
      false

let turn_change = function
  | Keeper_turn_changed { keeper; change } -> Some (keeper, change)
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _
  | Keeper_roster_change _ | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _
  | Approval_change _ | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let runtime_journal_appended = function
  | Keeper_runtime_journal_appended { keeper; journal; _ } -> Some (keeper, journal)
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _
  | Approval_change _ | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let schedules_changed = function
  | Workspace_store_changed Schedule_store -> true
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed (Pending_confirms | Goal_projection | Skill_catalog | Runtime_config | Lane_addon_exports) | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      false

let event_queue_changed = function
  | Keeper_event_queue_changed { keeper } -> Some keeper
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Board_changed _ | Approval_change _
  | Lane_resource _ | Snapshot _ | Execution_snapshot | Other _ ->
      None

let pending_confirms_changed = function
  | Workspace_store_changed Pending_confirms -> true
  | Approval_change
      ( Approval_queue_changed | Approval_rules_changed | Gate_mode_changed
      | Gate_keeper_settings_changed _ | Tool_approval_waits_changed _
      | Tool_approval_mode_changed _ | Keeper_asks_changed _ | Installation_asks_changed _ )
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed (Schedule_store | Goal_projection | Skill_catalog | Runtime_config | Lane_addon_exports) | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Lane_resource _
  | Snapshot _ | Execution_snapshot | Other _ ->
      false

let runtime_config_changed = function
  | Workspace_store_changed Runtime_config -> true
  | Approval_change
      ( Approval_queue_changed | Approval_rules_changed | Gate_mode_changed
      | Gate_keeper_settings_changed _ | Tool_approval_waits_changed _
      | Tool_approval_mode_changed _ | Keeper_asks_changed _ | Installation_asks_changed _ )
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed (Schedule_store | Pending_confirms | Goal_projection | Skill_catalog | Lane_addon_exports) | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Lane_resource _
  | Snapshot _ | Execution_snapshot | Other _ ->
      false

let asks_changed = function
  | Approval_change (Keeper_asks_changed _ | Installation_asks_changed _) -> true
  | Approval_change
      ( Approval_queue_changed | Approval_rules_changed | Gate_mode_changed
      | Gate_keeper_settings_changed _ | Tool_approval_waits_changed _
      | Tool_approval_mode_changed _ )
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Lane_resource _
  | Snapshot _ | Execution_snapshot | Other _ ->
      false

let board_changed_post = function
  | Board_changed { post_id } -> Some post_id
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Approval_change _ | Lane_resource _
  | Snapshot _ | Execution_snapshot | Other _ ->
      None

let gate_snapshot_changed = function
  | Approval_change
      ( Approval_queue_changed | Approval_rules_changed | Gate_mode_changed
      | Gate_keeper_settings_changed _ ) ->
      true
  | Approval_change
      ( Tool_approval_waits_changed _ | Tool_approval_mode_changed _ | Keeper_asks_changed _
      | Installation_asks_changed _ )
  | Keeper_chat_appended _ | Keeper_memory_journal_appended _ | Keeper_runtime_journal_appended _ | Keeper_turn_observation _
  | Agent_core _ | Keeper_heartbeat _ | Keeper_tool_call _
  | Keeper_turn_complete _
  | Keeper_composite_changed _ | Keeper_metrics_appended _
  | Keeper_chat_stream_frame _ | Keeper_turn_stream_frame _ | Keeper_waiting_inventory_changed _ | Keeper_roster_change _ | Keeper_turn_changed _
  | Keeper_async_requests_changed _ | Keeper_skill_activations_changed _
  | Fusion_run_status _ | Internal_agent_runs_changed _ | Workspace_store_changed _ | Dataset_changed _ | Gate_connector_changed _ | Keeper_event_queue_changed _ | Board_changed _ | Lane_resource _
  | Snapshot _ | Execution_snapshot | Other _ ->
      false

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
  if String.equal event_type Masc.Keeper_event_bridge.subscription_loss_event_type then
    match string_field payload "source_id", int_field payload "sequence",
          int_field payload "dropped_count" with
    | Some source_id, Some sequence, Some dropped_count
      when String.trim source_id <> "" && sequence > 0 && dropped_count > 0 ->
        Ok (Relay_subscription_loss { source_id; sequence; dropped_count })
    | _, _, _ ->
        Error "relay subscription loss needs a source, positive sequence and dropped_count"
  else match event_type with
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

open Result.Syntax

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
  let* tc_cache_read_tokens =
    optional_int_field fields "cache_read_tokens" ~event
  in
  let* tc_cache_creation_tokens =
    optional_int_field fields "cache_creation_tokens" ~event
  in
  Ok
    (Keeper_turn_complete
       { tc_keeper
       ; tc_turn = int_field fields "turn"
       ; tc_model = string_field fields "model_used"
       ; tc_input_tokens = int_field fields "input_tokens"
       ; tc_cache_read_tokens
       ; tc_cache_creation_tokens
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

let decode_keeper_turn_stream_event fields =
  let event = "keeper_turn_stream_event" in
  let* keeper = required string_field fields "name" ~event in
  let* raw = required string_field fields "turn_ref" ~event in
  let* turn_ref = match Ids.Turn_ref.of_string raw with
    | Some turn_ref -> Ok turn_ref
    | None -> Error "keeper_turn_stream_event has invalid turn_ref" in
  let* at = required float_field fields "ts_unix" ~event in
  let* seq = optional_int_field fields "seq" ~event in
  match seq with
  | Some seq when seq >= 0 -> Ok (Keeper_turn_stream_frame {keeper; turn_ref; seq; at})
  | Some _ | None -> Error "keeper_turn_stream_event requires a nonnegative seq"

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

(* What an event's type name says before its other members are read. Most
   events are read from their fields; a whole-projection push, the run
   registry's change and a type this decoder does not know carry nothing the
   screen keeps beyond what the name already says. *)
type reading =
  | From_fields of ((string * Yojson.Safe.t) list -> (event, string) result)
  | Named of event

let reading_of_type type_name =
  match type_name with
  | type_name when String.starts_with ~prefix:agent_core_prefix type_name ->
      From_fields
        (fun fields ->
          match
            Option.bind (string_field fields "event_type") lane_resource_lifecycle
          with
          | Some lifecycle -> decode_lane_resource ~type_name ~lifecycle fields
          | None -> decode_agent_core ~type_name fields)
  | "keeper_heartbeat" -> From_fields decode_keeper_heartbeat
  | "keeper_tool_call" -> From_fields decode_keeper_tool_call
  | "keeper_turn_complete" -> From_fields decode_keeper_turn_complete
  | "keeper_turn_observation" -> From_fields decode_keeper_turn_observation
  | "keeper_composite_changed" as event ->
      From_fields
        (fun fields ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_composite_changed { keeper; at }))
  | "keeper_metrics_appended" as event ->
      From_fields
        (fun fields ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_metrics_appended { keeper; at }))
  | "keeper_chat_operation_event" -> From_fields decode_keeper_chat_operation_event
  | "keeper_turn_stream_event" -> From_fields decode_keeper_turn_stream_event
  | "keeper_waiting_inventory_changed" ->
      From_fields decode_keeper_waiting_inventory_changed
  | "fusion_run_status" ->
      From_fields
        (fun fields ->
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
  | type_name when String.equal type_name Masc.Internal_agent_runs_event.event_type ->
      From_fields
        (fun fields ->
          match required string_field fields "registry" ~event:type_name with
          | Error detail -> Error detail
          | Ok wire ->
              (match Masc.Internal_agent_runs_event.registry_of_wire wire with
               | Some registry -> Ok (Internal_agent_runs_changed registry)
               | None -> Error (type_name ^ " names an unknown registry " ^ wire)))
  | type_name when String.equal type_name Masc.Schedule_invalidation_event.event_type ->
      Named (Workspace_store_changed Schedule_store)
  | type_name when String.equal type_name Masc.Pending_confirm_invalidation_event.event_type ->
      Named (Workspace_store_changed Pending_confirms)
  | type_name when String.equal type_name Masc.Goal_projection_broadcast.changed_event ->
      Named (Workspace_store_changed Goal_projection)
  | type_name when String.equal type_name Masc.Runtime_config_changed_event.event_type ->
      Named (Workspace_store_changed Runtime_config)
  | type_name when String.equal type_name Masc.Skill_catalog_published_event.event_type ->
      Named (Workspace_store_changed Skill_catalog)
  | type_name when String.equal type_name Masc.Lane_addon_exports_broadcast.changed_event ->
      Named (Workspace_store_changed Lane_addon_exports)
  | type_name when String.equal type_name Masc.Workspace_dataset_event.event_type ->
      From_fields
        (fun fields ->
           match Masc.Workspace_dataset_event.of_fields fields with
           | Ok dataset -> Ok (Dataset_changed dataset)
           | Error detail -> Error detail)
  | type_name when String.equal type_name Masc.Gate_connector_changed_event.event_type ->
      From_fields
        (fun fields ->
          match required string_field fields "connector" ~event:type_name with
          | Ok connector -> Ok (Gate_connector_changed { connector })
          | Error detail -> Error detail)
  | type_name when String.equal type_name Masc.Keeper_event_queue_changed_event.event_type ->
      From_fields
        (fun fields ->
          match required string_field fields "keeper" ~event:type_name with
          | Ok keeper -> Ok (Keeper_event_queue_changed { keeper })
          | Error detail -> Error detail)
  | "keeper_chat_appended" as event ->
      From_fields
        (fun fields ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_chat_appended
                { keeper; connector = string_field fields "connector"; at }))
  | "approval:pending" | "approval:resolved" | "approval:summary_updated" ->
      Named (Approval_change Approval_queue_changed)
  | "approval_rules_changed" -> Named (Approval_change Approval_rules_changed)
  | "gate_mode_changed" | "gate_external_mode_changed" ->
      Named (Approval_change Gate_mode_changed)
  | ("gate_keeper_mode_changed" | "keeper_exact_lane_preference_changed") as event ->
      From_fields
        (fun fields ->
          match string_field fields "keeper_name" with
          | Some keeper -> Ok (Approval_change (Gate_keeper_settings_changed { keeper }))
          | None -> Error (event ^ " carries no keeper_name"))
  | "keeper_tool_approval_waits_changed" as event ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Approval_change (Tool_approval_waits_changed { keeper }))
          | None -> Error (event ^ " carries no name"))
  | "keeper_tool_approval_mode_changed" as event ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Approval_change (Tool_approval_mode_changed { keeper }))
          | None -> Error (event ^ " carries no name"))
  | event when String.equal event Masc.Keeper_msg_async_broadcast.requests_changed_event ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Keeper_async_requests_changed { keeper })
          | None -> Error (event ^ " carries no name"))
  | event when String.equal event Masc.Keeper_skill_activations_changed_event.event_type ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Keeper_skill_activations_changed { keeper })
          | None -> Error (event ^ " carries no name"))
  | event when String.equal event Masc.Keeper_ask_broadcast.asks_changed_event ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Approval_change (Keeper_asks_changed { keeper }))
          | None -> Error (event ^ " carries no name"))
  | event when String.equal event Masc.Lane_addon_ask_broadcast.asks_changed_event ->
      From_fields
        (fun fields ->
          match string_field fields "declaration_id" with
          | Some declaration_id ->
              Ok (Approval_change (Installation_asks_changed { declaration_id }))
          | None -> Error (event ^ " carries no declaration_id"))
  | event when String.equal event Masc.Keeper_runtime_journal_broadcast.native_tasks_appended_event ->
      From_fields
        (fun fields ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_runtime_journal_appended { keeper; journal = Native_tasks_journal; at }))
  | event when String.equal event Masc.Keeper_runtime_journal_broadcast.child_content_appended_event ->
      From_fields
        (fun fields ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_runtime_journal_appended { keeper; journal = Child_content_journal; at }))
  | "keeper_memory_journal_appended" as event ->
      From_fields
        (fun fields ->
          decode_named_keeper_event ~event fields (fun ~keeper ~at ->
              Keeper_memory_journal_appended { keeper; at }))
  | event when String.equal event Masc.Keeper_row_broadcast.row_changed_event ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Keeper_roster_change (Keeper_row_changed { keeper }))
          | None -> Error (event ^ " carries no name"))
  | event when String.equal event Masc.Keeper_row_broadcast.roster_changed_event ->
      Named (Keeper_roster_change Every_row_changed)
  | event when String.equal event Masc.Keeper_turn_broadcast.changed_event ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Keeper_turn_changed { keeper; change = Turn_state })
          | None -> Error (event ^ " carries no name"))
  | event when String.equal event Masc.Keeper_turn_preview_signal.changed_event ->
      From_fields
        (fun fields ->
          match string_field fields "name" with
          | Some keeper -> Ok (Keeper_turn_changed { keeper; change = Turn_preview })
          | None -> Error (event ^ " carries no name"))
  | event when String.equal event Masc.Dashboard_event_slices.execution_snapshot_type ->
      Named Execution_snapshot
  | event when String.equal event Masc.Dashboard_event_slices.transport_health_snapshot_type ->
      Named (Snapshot Transport_health)
  | other -> (
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
      match Masc.Dashboard_event_slices.carries_whole_projection other with
      | true -> Named (Snapshot (Unread_projection other))
      | false -> Named (Other other))

(* The server sends Board writes as a JSON-RPC notification, so the event
   has a method where the others have a type. *)
let board_notification fields =
  match List.assoc_opt "params" fields with
  | Some (`Assoc params) -> Ok (Board_changed { post_id = string_field params "post_id" })
  | Some _ | None -> Error "notifications/board carries no params object"

let event_of_json (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields -> (
      match string_field fields "type", string_field fields "method" with
      | Some type_name, _ -> (
          match reading_of_type type_name with
          | From_fields decode -> decode fields
          | Named event -> Ok event)
      | None, Some "notifications/board" -> board_notification fields
      | None, (Some _ | None) -> Error "event carries no type")
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
      Error "event is not a JSON object"

type t = {
  lines : Masc_tui_sse_lines.t;
  mutable frame_cursor : (int option, string) result;
  mutable frame_data : string list;
  mutable frame_error : string option;
}

let create () =
  { lines = Masc_tui_sse_lines.create (); frame_cursor = Ok None; frame_data = []; frame_error = None }

(* The event's first member when it is its "type", read without lexing the
   members after it. The server writes the type first. *)
let leading_type payload =
  let state = Yojson.init_lexer () in
  let lexbuf = Lexing.from_string payload in
  match
    Yojson.Safe.read_space state lexbuf;
    Yojson.Safe.read_lcurl state lexbuf;
    Yojson.Safe.read_space state lexbuf;
    Yojson.Safe.read_object_end lexbuf;
    let member = Yojson.Safe.read_ident state lexbuf in
    Yojson.Safe.read_space state lexbuf;
    Yojson.Safe.read_colon state lexbuf;
    Yojson.Safe.read_space state lexbuf;
    (member, Yojson.Safe.read_string state lexbuf)
  with
  | "type", type_name -> Some type_name
  | _, _ -> None
  | exception (Yojson.Json_error _ | Yojson.End_of_object) -> None

(* An event its type name decides is not read past the name: a
   whole-projection push can carry megabytes after its type, and parsing
   it held the screen's only domain for about 10ms to keep the name alone.
   Such a frame is taken as the name says without the rest being checked.
   Every other event is parsed whole. *)
let decode_payload payload =
  match Option.map reading_of_type (leading_type payload) with
  | Some (Named event) -> Event event
  | Some (From_fields _) | None -> (
      match Yojson.Safe.from_string payload with
      | json -> (
          match event_of_json json with
          | Ok event -> Event event
          | Error detail -> Undecodable detail)
      | exception Yojson.Json_error detail ->
          Undecodable ("invalid JSON: " ^ detail))

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
  Masc_tui_sse_lines.feed t.lines chunk |> List.concat_map (feed_line t)
