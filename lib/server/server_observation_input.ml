type keeper_change =
  | Phase of { previous : Keeper_state_machine.phase; current : Keeper_state_machine.phase }
  | Composite | Row | Turn | Turn_preview | Chat | Native_tasks | Child_content
  | Memory_journal | Async_requests | Asks | Tool_approval_waits
  | Tool_approval_mode | Gate_settings | Event_queue
  | Waiting_inventory of Keeper_waiting_inventory_broadcast.source

type store_change =
  | Schedule | Pending_confirms | Goals | Runtime_config | Skill_catalog | Lane_addon_exports | Tools

type gate_change = Approvals | Rules | Mode | External_mode | Installation_asks of string

type agent_core_change =
  | Started | Completed | Failed | Yielded | Input_required | Tool_called
  | Tool_completed | Turn_completed

type t =
  | Dataset of Workspace_dataset_event.dataset
  | Keeper of { keeper : string; change : keeper_change }
  | Every_keeper_row
  | Chat_operation of { keeper : string; operation_id : string }
  | Gate of gate_change
  | Connector of string
  | Store of store_change
  | Board
  | Execution_invalidated
  | Agent_core of { keeper : string option; change : agent_core_change }
  | Telemetry_sample
  | Telemetry_gap of {
      source : Telemetry_unified_source.source option;
      keeper : string option;
    }
  | Keeper_tool_call of { keeper : string }
  | Keeper_approval_audit of { keeper : string; event : Keeper_approval.Audit.event }

let ( let* ) = Option.bind
let field fields name = List.assoc_opt name fields
let text fields name = match field fields name with
  | Some (`String value) when not (String.equal (String.trim value) "") -> Some value
  | Some _ | None -> None
let finite = function
  | `Float value -> Float.is_finite value
  | `Int _ -> true
  | `Null | `Bool _ | `Intlit _ | `String _ | `List _ | `Assoc _ -> false
let timestamp fields = Option.exists finite (field fields "ts_unix")
let timestamp_if_present fields = match field fields "ts_unix" with
  | None -> true | Some value -> finite value
let object_ fields name = match field fields name with
  | Some (`Assoc value) -> Some value | Some _ | None -> None
let number fields name = match field fields name with
  | Some (`Float value) when Float.is_finite value -> Some value
  | Some (`Int value) -> Some (Float.of_int value)
  | Some _ | None -> None
let integer = function `Int _ -> true | _ -> false
let boolean = function `Bool _ -> true | _ -> false
let nullable predicate = function `Null -> true | value -> predicate value
let has fields name predicate = Option.exists predicate (field fields name)
let unique_fields fields =
  let keys = List.map fst fields in
  List.length keys = List.length (List.sort_uniq String.compare keys)
;;
let named ?(key = "name") fields change =
  let* keeper = text fields key in
  if timestamp_if_present fields then Some (Keeper { keeper; change }) else None

let dataset fields =
  match Workspace_dataset_event.of_fields fields with
  | Error _ | Ok (Workspace_dataset_event.Dashboard_observation _) -> None
  | Ok (Workspace_dataset_event.(
      (Repositories | Verification_requests | Harness_verdicts | Goals
      | Runtime_config | Connectors | Keeper_metrics _ | Skill_activations _
      | Skill_catalog | Clients | Account_emails | Provider_usage | Provider_standing
      | Keeper_costs | Workspace_health | Runtime_probe | Runtime_metrics | Lanes
      | Machine_live _ | Play_room _ | Lane_addons _ | Browser_observation _
      | Keeper_oauth_attempts _ | Memory_health _ | World_memory | Play_seats) as value)) ->
      Some (Dataset value)
;;

let valid_payload reader payload =
  match reader (Yojson.Safe.to_string payload) with
  | _ -> true
  | exception (Atdgen_runtime.Oj_run.Error _ | Yojson.Json_error _) -> false
;;

let agent_core fields wire change valid =
  let* actual = text fields "event_type" in
  let* payload = field fields "payload" in
  if not (String.equal actual wire && timestamp fields && valid payload) then None
  else
    let keeper = text fields "agent_name" in
    match keeper with
    | Some _ -> Some (Agent_core { keeper; change })
    | None -> None
;;

let telemetry_sample fields =
  let* provider = text fields "provider_id" in
  let* model = text fields "model_id" in
  let* at = number fields "ts_unix" in
  let* entry = object_ fields "payload" in
  let* recorded_at = number entry "recorded_at" in
  let* sample = object_ entry "sample" in
  let* provider_in_sample = text sample "provider_id" in
  let* model_in_sample = text sample "model_id" in
  let status_valid = match object_ sample "status" with
    | None -> false
    | Some status ->
      unique_fields status && (match text status "kind" with
       | Some "success" -> true
       | Some "error" -> has status "transient" boolean
       | Some "cancelled" -> has status "reason" (function `String _ -> true | _ -> false)
       | Some _ | None -> false) in
  if unique_fields entry && unique_fields sample && Float.equal at recorded_at
     && String.equal provider provider_in_sample && String.equal model model_in_sample
     && List.for_all (fun name -> has sample name finite)
          ["ttfb_ms"; "total_duration_ms"; "serialization_ms"]
     && has sample "usage_reported" boolean
     && has sample "input_tokens" (nullable integer)
     && has sample "output_tokens" (nullable integer)
     && has sample "throughput_tokens_per_s" (nullable finite)
     && has sample "cost_usd" (nullable finite)
     && has sample "cache_hit" (nullable boolean)
     && has sample "retry_count" integer && status_valid
  then Some Telemetry_sample else None
;;

let of_fields fields =
  let* kind = text fields "type" in
  match kind with
  | value when String.equal value Workspace_dataset_event.event_type -> dataset fields
  | value when String.equal value Schedule_invalidation_event.event_type -> Some (Store Schedule)
  | value when String.equal value Pending_confirm_invalidation_event.event_type -> Some (Store Pending_confirms)
  | value when String.equal value Goal_projection_broadcast.changed_event -> Some (Store Goals)
  | value when String.equal value Runtime_config_changed_event.event_type -> Some (Store Runtime_config)
  | value when String.equal value Skill_catalog_published_event.event_type -> Some (Store Skill_catalog)
  | value when String.equal value Lane_addon_exports_broadcast.changed_event -> Some (Store Lane_addon_exports)
  | value when String.equal value Gate_connector_changed_event.event_type ->
      Option.map (fun connector -> Connector connector) (text fields "connector")
  | "keeper_phase_changed" ->
      let* previous = Option.bind (text fields "prev_phase") Keeper_state_machine.phase_of_string in
      let* current = Option.bind (text fields "new_phase") Keeper_state_machine.phase_of_string in
      if timestamp fields then named fields (Phase { previous; current }) else None
  | "keeper_composite_changed" -> if timestamp fields then named fields Composite else None
  | value when String.equal value Keeper_row_broadcast.row_changed_event -> named fields Row
  | value when String.equal value Keeper_row_broadcast.roster_changed_event -> Some Every_keeper_row
  | value when String.equal value Keeper_turn_broadcast.changed_event -> named fields Turn
  | value when String.equal value Keeper_turn_preview_signal.changed_event -> named fields Turn_preview
  | "keeper_chat_appended" -> named fields Chat
  | value when String.equal value Keeper_runtime_journal_broadcast.native_tasks_appended_event -> named fields Native_tasks
  | value when String.equal value Keeper_runtime_journal_broadcast.child_content_appended_event -> named fields Child_content
  | "keeper_memory_journal_appended" -> named fields Memory_journal
  | value when String.equal value Keeper_msg_async_broadcast.requests_changed_event -> named fields Async_requests
  | value when String.equal value Keeper_ask_broadcast.asks_changed_event -> named fields Asks
  | value when String.equal value Keeper_tool_approval_broadcast.waits_changed_event -> named fields Tool_approval_waits
  | value when String.equal value Keeper_tool_approval_broadcast.mode_changed_event -> named fields Tool_approval_mode
  | "gate_keeper_mode_changed" | "keeper_exact_lane_preference_changed" ->
      named ~key:"keeper_name" fields Gate_settings
  | value when String.equal value Keeper_event_queue_changed_event.event_type -> named ~key:"keeper" fields Event_queue
  | "keeper_waiting_inventory_changed" ->
      let* source = text fields "queue_kind" in
      let* change = match source with
        | "chat_operation" -> Some Keeper_waiting_inventory_broadcast.Chat_operation
        | "event_queue" -> Some Keeper_waiting_inventory_broadcast.Event_queue
        | "approval_count" -> Some Keeper_waiting_inventory_broadcast.Approval_count
        | "approval_detail" -> Some Keeper_waiting_inventory_broadcast.Approval_detail
        | _ -> None in
      named ~key:"keeper_name" fields (Waiting_inventory change)
  | "keeper_chat_operation_event" ->
      let* keeper = text fields "name" in
      let* operation_id = text fields "operation_id" in
      if timestamp fields then Some (Chat_operation { keeper; operation_id }) else None
  | "approval:pending" | "approval:resolved" | "approval:summary_updated" -> Some (Gate Approvals)
  | value when String.equal value Keeper_gate_broadcast.approval_rules_changed_event -> Some (Gate Rules)
  | "gate_mode_changed" -> Some (Gate Mode)
  | "gate_external_mode_changed" -> Some (Gate External_mode)
  | value when String.equal value Lane_addon_ask_broadcast.asks_changed_event ->
      Option.map (fun declaration -> Gate (Installation_asks declaration)) (text fields "declaration_id")
  | "board_changed" | "post_created" | "comment_added" | "post_voted"
  | "comment_voted" | "reaction_changed" | "post_changed" -> Some Board
  | value when String.equal value Dashboard_event_slices.execution_snapshot_type ->
      (match field fields "execution_invalidated", text fields "execution_publication_epoch",
             field fields "execution_publication_generation" with
       | Some (`Bool true), Some _, Some (`Int generation) when generation >= 0 -> Some Execution_invalidated
       | _, _, _ -> None)
  | "agent_core:agent_started" ->
      agent_core fields "agent_started" Started (valid_payload Sse_event.Json.agent_started_payload_of_string)
  | "agent_core:agent_completed" ->
      agent_core fields "agent_completed" Completed (valid_payload Sse_event.Json.agent_completed_payload_of_string)
  | "agent_core:agent_failed" ->
      agent_core fields "agent_failed" Failed (valid_payload Sse_event.Json.agent_failed_payload_of_string)
  | "agent_core:agent_yielded" ->
      agent_core fields "agent_yielded" Yielded (valid_payload Sse_event.Json.agent_yielded_payload_of_string)
  | "agent_core:agent_input_required" ->
      agent_core fields "agent_input_required" Input_required (valid_payload Sse_event.Json.agent_input_required_payload_of_string)
  | "agent_core:tool_called" ->
      agent_core fields "tool_called" Tool_called (valid_payload Sse_event.Json.tool_called_payload_of_string)
  | "agent_core:tool_completed" ->
      agent_core fields "tool_completed" Tool_completed (valid_payload Sse_event.Json.tool_completed_payload_of_string)
  | "agent_core:turn_completed" ->
      agent_core fields "turn_completed" Turn_completed (valid_payload Sse_event.Json.turn_completed_payload_of_string)
  | "agent_core_telemetry_sample" -> telemetry_sample fields
  | _ -> None
;;

let of_notification fields =
  if List.exists (fun (key, _) -> not (List.mem key ["jsonrpc"; "method"; "params"])) fields
  then None
  else match field fields "jsonrpc", text fields "method", field fields "params" with
    | Some (`String "2.0"), Some "notifications/board", Some (`Assoc params)
      when unique_fields params ->
        let decoded = of_fields params in
        if decoded = Some Board then decoded else None
    | Some (`String "2.0"), Some "notifications/tools/list_changed", None -> Some (Store Tools)
    | _, _, _ -> None
;;

let of_event (event : Sse.external_event) =
  match event.ext_payload with
  | `Assoc fields ->
      if not (unique_fields fields) then None
      else if List.mem_assoc "jsonrpc" fields then of_notification fields
      else of_fields fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let subscribe ~sw ~base_path ?observer_instance_id notify =
  let runtime_authority = Sse.runtime_authority_exn ~base_path in
  let canonical_masc_root =
    Fs_compat.realpath_lenient (Common.masc_dir_from_base_path ~base_path) in
  let unsubscribe = Sse.subscribe_publication_inputs ~runtime_authority
      ?observer_instance_id (fun event -> Option.iter notify (of_event event)) in
  let unsubscribe_gaps = Telemetry_coverage_gap.subscribe_changed (fun change ->
    if String.equal canonical_masc_root change.canonical_masc_root then
      notify (Telemetry_gap {
        source = Telemetry_unified_source.source_of_string change.source;
        keeper = change.keeper_name })) in
  let unsubscribe_tools = Keeper_tool_call_log.subscribe_written (fun change ->
    if String.equal canonical_masc_root change.canonical_masc_root then
      notify (Keeper_tool_call {keeper = change.keeper_name})) in
  let unsubscribe_audits = Keeper_approval.Audit.subscribe_written (fun change ->
    if String.equal canonical_masc_root change.canonical_masc_root then
      notify (Keeper_approval_audit {keeper = change.keeper_name; event = change.event_type})) in
  Eio.Switch.on_release sw (fun () ->
    unsubscribe (); unsubscribe_gaps (); unsubscribe_tools (); unsubscribe_audits ())
;;
