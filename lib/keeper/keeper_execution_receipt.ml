type tool_surface =
  { turn_lane : string
  ; visible_tool_count : int
  ; tool_gate_enabled : bool
  ; tool_surface_fallback_used : bool
  }

type t =
  { keeper_name : string
  ; agent_name : string
  ; trace_id : string
  ; generation : int
  ; turn_count : int option
  ; current_task_id : string option
  ; goal_ids : string list
  ; outcome : string
  ; terminal_reason_code : string
  ; response_text_present : bool
  ; model_used : string option
  ; requested_tools : string list
  ; reported_tools : string list
  ; observed_tools : string list
  ; canonical_tools : string list
  ; unexpected_tools : string list
  ; tools_used : string list
  ; tool_contract_result : string
  ; tool_surface : tool_surface
  ; sandbox_configured_kind : string
  ; sandbox_effective_kind : string
  ; sandbox_root : string option
  ; network_mode : string
  ; approval_profile : string option
  ; approval_profile_derived : bool
  ; cascade_name : string
  ; cascade_selected_model : string option
  ; cascade_attempt_count : int
  ; cascade_fallback_applied : bool
  ; cascade_outcome : string
  ; stop_reason : string option
  ; error_kind : string option
  ; error_message : string option
  ; started_at : string
  ; ended_at : string
  }

let stop_reason_to_string = function
  | Oas_worker.Completed -> "completed"
  | Oas_worker.TurnBudgetExhausted { turns_used; limit } ->
    Printf.sprintf "turn_budget_exhausted:%d/%d" turns_used limit
  | Oas_worker.MutationBoundaryReached { turns_used; tool_name } ->
    (match tool_name with
     | Some tool ->
       Printf.sprintf "mutation_boundary:%s:%d" tool turns_used
     | None ->
       Printf.sprintf "mutation_boundary:%d" turns_used)

let effective_sandbox_kind_of_meta (meta : Keeper_types.keeper_meta) =
  match meta.sandbox_profile with
  | Keeper_types.Docker -> "docker"
  | Keeper_types.Local -> "local"

let list_json values =
  `List (List.map (fun value -> `String value) values)

let to_json (receipt : t) =
  let error_json =
    match receipt.error_kind, receipt.error_message with
    | None, None -> `Null
    | error_kind, error_message ->
      `Assoc
        [
          ( "kind",
            match error_kind with
            | Some value -> `String value
            | None -> `Null );
          ( "message",
            match error_message with
            | Some value -> `String value
            | None -> `Null );
        ]
  in
  `Assoc
    [
      ("schema", `String "keeper.execution_receipt.v1");
      ("recorded_at", `String receipt.ended_at);
      ("keeper_name", `String receipt.keeper_name);
      ("agent_name", `String receipt.agent_name);
      ("trace_id", `String receipt.trace_id);
      ("generation", `Int receipt.generation);
      ( "turn_count",
        match receipt.turn_count with
        | Some value -> `Int value
        | None -> `Null );
      ( "current_task_id",
        match receipt.current_task_id with
        | Some value -> `String value
        | None -> `Null );
      ("goal_ids", list_json receipt.goal_ids);
      ("outcome", `String receipt.outcome);
      ("terminal_reason_code", `String receipt.terminal_reason_code);
      ("response_text_present", `Bool receipt.response_text_present);
      ( "model_used",
        match receipt.model_used with
        | Some value -> `String value
        | None -> `Null );
      ("requested_tools", list_json receipt.requested_tools);
      ("reported_tools", list_json receipt.reported_tools);
      ("observed_tools", list_json receipt.observed_tools);
      ("canonical_tools", list_json receipt.canonical_tools);
      ("unexpected_tools", list_json receipt.unexpected_tools);
      ("tools_used", list_json receipt.tools_used);
      ("tool_contract_result", `String receipt.tool_contract_result);
      ( "tool_surface",
        `Assoc
          [
            ("turn_lane", `String receipt.tool_surface.turn_lane);
            ("visible_tool_count", `Int receipt.tool_surface.visible_tool_count);
            ("tool_gate_enabled", `Bool receipt.tool_surface.tool_gate_enabled);
            ( "tool_surface_fallback_used",
              `Bool receipt.tool_surface.tool_surface_fallback_used );
          ] );
      ( "sandbox",
        `Assoc
          [
            ("configured_kind", `String receipt.sandbox_configured_kind);
            ("effective_kind", `String receipt.sandbox_effective_kind);
            ( "sandbox_root",
              match receipt.sandbox_root with
              | Some value -> `String value
              | None -> `Null );
            ("network_mode", `String receipt.network_mode);
          ] );
      ( "approval",
        `Assoc
          [
            ( "profile",
              match receipt.approval_profile with
              | Some value -> `String value
              | None -> `Null );
            ("derived", `Bool receipt.approval_profile_derived);
          ] );
      ( "cascade",
        `Assoc
          [
            ("name", `String receipt.cascade_name);
            ( "selected_model",
              match receipt.cascade_selected_model with
              | Some value -> `String value
              | None -> `Null );
            ("attempt_count", `Int receipt.cascade_attempt_count);
            ("fallback_applied", `Bool receipt.cascade_fallback_applied);
            ("outcome", `String receipt.cascade_outcome);
          ] );
      ( "stop_reason",
        match receipt.stop_reason with
        | Some value -> `String value
        | None -> `Null );
      ("error", error_json);
      ("started_at", `String receipt.started_at);
      ("ended_at", `String receipt.ended_at);
    ]

let append (config : Coord.config) (receipt : t) =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config
      receipt.keeper_name
  in
  Dated_jsonl.append store (to_json receipt)

let latest_json (config : Coord.config) keeper_name =
  let store =
    Keeper_types_support.keeper_execution_receipt_store config keeper_name
  in
  match Dated_jsonl.read_recent store 1 with
  | [ json ] -> Some json
  | _ -> None

let latest_json_by_keeper (config : Coord.config) keeper_names =
  keeper_names
  |> List.filter_map (fun keeper_name ->
         match latest_json config keeper_name with
         | Some json -> Some (keeper_name, json)
         | None -> None)
