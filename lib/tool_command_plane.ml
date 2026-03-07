open Types

type context = {
  config : Room.config;
  agent_name : string;
}

type result = bool * string

let get_string_opt args key =
  match Yojson.Safe.Util.member key args with
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let json_result = function
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error message -> (false, json_error message)

let handle_unit_define (ctx : context) args : result =
  try
    match Command_plane_v2.upsert_unit ctx.config ~actor:ctx.agent_name args with
    | Ok unit ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.unit_to_json unit);
              ("topology", Command_plane_v2.topology_json ctx.config);
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_unit_list (ctx : context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_units_json ctx.config))

let handle_operation_start (ctx : context) args : result =
  try
    match Command_plane_v2.start_operation ctx.config ~actor:ctx.agent_name args with
    | Ok operation ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.operation_to_json operation);
              ("operations", Command_plane_v2.operation_status_json ctx.config ());
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_operation_status (ctx : context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.operation_status_json ctx.config ?operation_id ()) )

let handle_operation_checkpoint (ctx : context) args : result =
  try
    match Command_plane_v2.checkpoint_operation ctx.config ~actor:ctx.agent_name args with
    | Ok operation ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.operation_to_json operation);
              ("traces", Command_plane_v2.list_traces_json ctx.config ~operation_id:operation.operation_id ());
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_observe_topology (ctx : context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.topology_json ctx.config))

let handle_observe_alerts (ctx : context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_alerts_json ctx.config))

let handle_observe_operations (ctx : context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_operations_json ctx.config))

let handle_observe_capacity (ctx : context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.observe_capacity_json ctx.config))

let handle_observe_traces (ctx : context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  let limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int value -> value
    | _ -> 25
  in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.list_traces_json ctx.config ?operation_id ~limit ()))

let handle_unit_update (ctx : context) args : result =
  json_result (Command_plane_v2.unit_update_json ctx.config ~actor:ctx.agent_name args)

let handle_unit_reparent (ctx : context) args : result =
  json_result (Command_plane_v2.unit_reparent_json ctx.config ~actor:ctx.agent_name args)

let handle_unit_reassign (ctx : context) args : result =
  json_result (Command_plane_v2.unit_reassign_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_pause (ctx : context) args : result =
  json_result (Command_plane_v2.pause_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_resume (ctx : context) args : result =
  json_result (Command_plane_v2.resume_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_stop (ctx : context) args : result =
  json_result (Command_plane_v2.stop_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_operation_finalize (ctx : context) args : result =
  json_result (Command_plane_v2.finalize_operation_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_plan (ctx : context) args : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.dispatch_plan_json ctx.config args))

let handle_dispatch_route (ctx : context) args : result =
  handle_dispatch_plan ctx args

let handle_dispatch_assign (ctx : context) args : result =
  json_result (Command_plane_v2.dispatch_assign_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_rebalance (ctx : context) args : result =
  json_result
    (Command_plane_v2.dispatch_rebalance_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_escalate (ctx : context) args : result =
  json_result
    (Command_plane_v2.dispatch_escalate_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_recall (ctx : context) args : result =
  json_result (Command_plane_v2.dispatch_recall_json ctx.config ~actor:ctx.agent_name args)

let handle_dispatch_tick (ctx : context) args : result =
  json_result (Command_plane_v2.dispatch_tick_json ctx.config ~actor:ctx.agent_name args)

let handle_detachment_list (ctx : context) args : result =
  let operation_id = get_string_opt args "operation_id" in
  let detachment_id = get_string_opt args "detachment_id" in
  ( true,
    Yojson.Safe.to_string
      (Command_plane_v2.list_detachments_json ctx.config ?operation_id
         ?detachment_id) )

let handle_detachment_status (ctx : context) args : result =
  json_result (Command_plane_v2.detachment_status_json ctx.config args)

let handle_policy_status (ctx : context) : result =
  (true, Yojson.Safe.to_string (Command_plane_v2.policy_status_json ctx.config))

let handle_policy_approve (ctx : context) args : result =
  json_result (Command_plane_v2.policy_approve_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_deny (ctx : context) args : result =
  json_result (Command_plane_v2.policy_deny_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_update (ctx : context) args : result =
  json_result (Command_plane_v2.policy_update_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_freeze_unit (ctx : context) args : result =
  json_result
    (Command_plane_v2.policy_freeze_unit_json ctx.config ~actor:ctx.agent_name args)

let handle_policy_kill_switch (ctx : context) args : result =
  json_result
    (Command_plane_v2.policy_kill_switch_json ctx.config ~actor:ctx.agent_name args)

let dispatch (ctx : context) ~name ~args : result option =
  match name with
  | "masc_unit_define" -> Some (handle_unit_define ctx args)
  | "masc_unit_update" -> Some (handle_unit_update ctx args)
  | "masc_unit_list" -> Some (handle_unit_list ctx)
  | "masc_unit_reparent" -> Some (handle_unit_reparent ctx args)
  | "masc_unit_reassign" -> Some (handle_unit_reassign ctx args)
  | "masc_operation_start" -> Some (handle_operation_start ctx args)
  | "masc_operation_status" -> Some (handle_operation_status ctx args)
  | "masc_operation_checkpoint" -> Some (handle_operation_checkpoint ctx args)
  | "masc_operation_pause" -> Some (handle_operation_pause ctx args)
  | "masc_operation_resume" -> Some (handle_operation_resume ctx args)
  | "masc_operation_stop" -> Some (handle_operation_stop ctx args)
  | "masc_operation_finalize" -> Some (handle_operation_finalize ctx args)
  | "masc_dispatch_plan" -> Some (handle_dispatch_plan ctx args)
  | "masc_dispatch_route" -> Some (handle_dispatch_route ctx args)
  | "masc_dispatch_assign" -> Some (handle_dispatch_assign ctx args)
  | "masc_dispatch_rebalance" -> Some (handle_dispatch_rebalance ctx args)
  | "masc_dispatch_escalate" -> Some (handle_dispatch_escalate ctx args)
  | "masc_dispatch_recall" -> Some (handle_dispatch_recall ctx args)
  | "masc_dispatch_tick" -> Some (handle_dispatch_tick ctx args)
  | "masc_detachment_list" -> Some (handle_detachment_list ctx args)
  | "masc_detachment_status" -> Some (handle_detachment_status ctx args)
  | "masc_policy_status" -> Some (handle_policy_status ctx)
  | "masc_policy_approve" -> Some (handle_policy_approve ctx args)
  | "masc_policy_deny" -> Some (handle_policy_deny ctx args)
  | "masc_policy_update" -> Some (handle_policy_update ctx args)
  | "masc_policy_freeze_unit" -> Some (handle_policy_freeze_unit ctx args)
  | "masc_policy_kill_switch" -> Some (handle_policy_kill_switch ctx args)
  | "masc_observe_topology" -> Some (handle_observe_topology ctx)
  | "masc_observe_alerts" -> Some (handle_observe_alerts ctx)
  | "masc_observe_operations" -> Some (handle_observe_operations ctx)
  | "masc_observe_capacity" -> Some (handle_observe_capacity ctx)
  | "masc_observe_traces" -> Some (handle_observe_traces ctx args)
  | _ -> None

let object_schema ?(required = []) properties =
  `Assoc
    [
      ("type", `String "object");
      ("properties", `Assoc properties);
      ("required", `List (List.map (fun key -> `String key) required));
    ]

let string_prop description =
  `Assoc [ ("type", `String "string"); ("description", `String description) ]

let integer_prop ?default description =
  `Assoc
    ([
       ("type", `String "integer");
       ("description", `String description);
     ]
    @
    match default with
    | Some value -> [ ("default", `Int value) ]
    | None -> [])

let boolean_prop ?default description =
  `Assoc
    ([
       ("type", `String "boolean");
       ("description", `String description);
     ]
    @
    match default with
    | Some value -> [ ("default", `Bool value) ]
    | None -> [])

let string_array_prop description =
  `Assoc
    [
      ("type", `String "array");
      ("description", `String description);
      ("items", `Assoc [ ("type", `String "string") ]);
    ]

let schemas : tool_schema list =
  [
    {
      name = "masc_unit_define";
      description =
        "CPv2 benchmark step 1. Create or update a managed company/platoon/squad/agent unit before starting operations.";
      input_schema =
        object_schema ~required:[ "kind"; "label" ]
          [
            ("unit_id", string_prop "Stable unit identifier. Omit to derive from kind + label.");
            ("label", string_prop "Human-readable unit label.");
            ("kind", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "company"; `String "platoon"; `String "squad"; `String "agent" ]) ]);
            ("parent_unit_id", string_prop "Parent unit id. Required for non-company units.");
            ("leader_id", string_prop "Leader agent id for this unit.");
            ("roster", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("capability_profile", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("policy", `Assoc [ ("type", `String "object") ]);
            ("budget", `Assoc [ ("type", `String "object") ]);
          ];
    };
    {
      name = "masc_unit_list";
      description =
        "Read managed and effective Command Plane V2 units, including auto-generated topology for unassigned agents.";
      input_schema = object_schema [];
    };
    {
      name = "masc_unit_update";
      description =
        "Alias for masc_unit_define. Create or update a managed unit with explicit policy and budget envelope.";
      input_schema =
        object_schema ~required:[ "unit_id"; "kind"; "label" ]
          [
            ("unit_id", string_prop "Stable unit identifier.");
            ("label", string_prop "Human-readable unit label.");
            ("kind", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "company"; `String "platoon"; `String "squad"; `String "agent" ]) ]);
            ("parent_unit_id", string_prop "Parent unit id.");
            ("leader_id", string_prop "Leader agent id.");
            ("roster", string_array_prop "Explicit roster for this unit.");
            ("capability_profile", string_array_prop "Capability labels.");
            ("policy", `Assoc [ ("type", `String "object") ]);
            ("budget", `Assoc [ ("type", `String "object") ]);
          ];
    };
    {
      name = "masc_unit_reparent";
      description =
        "Move a unit under a new parent unit while preserving its policy and budget envelopes.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("parent_unit_id", string_prop "New parent unit id. Omit only for company roots.");
          ];
    };
    {
      name = "masc_unit_reassign";
      description =
        "Update a unit's leader or explicit roster. Use this to rotate squad leaders or replace a detachment roster.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("leader_id", string_prop "New leader agent id.");
            ("roster", string_array_prop "Replacement roster.");
          ];
    };
    {
      name = "masc_operation_start";
      description =
        "CPv2 benchmark step 2. Start a managed operation on a ready unit after leadership, live-roster, and capacity checks pass.";
      input_schema =
        object_schema ~required:[ "assigned_unit_id"; "objective" ]
          [
            ("assigned_unit_id", string_prop "Target unit id.");
            ("objective", string_prop "Operation objective.");
            ("autonomy_level", string_prop "Autonomy level such as L3_Guided or L4_Autonomous.");
            ("policy_class", string_prop "Policy class name.");
            ("budget_class", string_prop "Budget class name.");
            ("detachment_session_id", string_prop "Optional backing team-session id.");
            ("checkpoint_ref", string_prop "Optional initial checkpoint reference.");
            ("active_goal_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("note", string_prop "Optional operator note.");
            ("status", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "planned"; `String "active"; `String "paused" ]) ]);
          ];
    };
    {
      name = "masc_operation_status";
      description =
        "Read Command Plane V2 operations. Use this after operation_start or later during CPv2 benchmark triage.";
      input_schema =
        object_schema
          [ ("operation_id", string_prop "Operation id to filter."); ];
    };
    {
      name = "masc_operation_checkpoint";
      description =
        "Attach or update a checkpoint reference for a managed Command Plane V2 operation and append a trace event.";
      input_schema =
        object_schema ~required:[ "operation_id"; "checkpoint_ref" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("checkpoint_ref", string_prop "Checkpoint reference or durable resume pointer.");
            ("note", string_prop "Optional checkpoint note.");
          ];
    };
    {
      name = "masc_operation_pause";
      description = "Pause a managed operation and sync its managed detachment status.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional pause note.");
          ];
    };
    {
      name = "masc_operation_resume";
      description = "Resume a paused managed operation.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional resume note.");
          ];
    };
    {
      name = "masc_operation_stop";
      description = "Cancel a managed operation and mark its detachment stopped.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional stop reason.");
          ];
    };
    {
      name = "masc_operation_finalize";
      description = "Finalize a managed operation as completed.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional completion note.");
          ];
    };
    {
      name = "masc_dispatch_plan";
      description =
        "Recommend the best target units for an operation based on platoon locality, roster liveness, and capacity.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation id to route.");
            ("assigned_unit_id", string_prop "Optional current unit id when planning a new operation.");
          ];
    };
    {
      name = "masc_dispatch_route";
      description =
        "Alias for masc_dispatch_plan. Return recommended route candidates for large-scale hierarchy dispatch.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation id to route.");
            ("assigned_unit_id", string_prop "Optional current unit id.");
          ];
    };
    {
      name = "masc_dispatch_assign";
      description =
        "Assign or move an operation to a new unit. Cross-platoon or strict-policy moves become pending approvals.";
      input_schema =
        object_schema ~required:[ "operation_id"; "target_unit_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("target_unit_id", string_prop "Target unit id.");
            ("note", string_prop "Optional assignment note.");
          ];
    };
    {
      name = "masc_dispatch_rebalance";
      description =
        "Rebalance an operation to another unit using the same approval semantics as dispatch_assign.";
      input_schema =
        object_schema ~required:[ "operation_id"; "target_unit_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("target_unit_id", string_prop "Target unit id.");
            ("note", string_prop "Optional rebalance note.");
          ];
    };
    {
      name = "masc_dispatch_escalate";
      description =
        "Escalate an operation toward a parent unit or explicit target unit. Cross-platoon moves require approval.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("target_unit_id", string_prop "Optional explicit target unit id.");
            ("note", string_prop "Optional escalation note.");
          ];
    };
    {
      name = "masc_dispatch_recall";
      description =
        "Recall an operation by pausing it without deleting its checkpoint or trace lineage.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional recall note.");
          ];
    };
    {
      name = "masc_dispatch_tick";
      description =
        "CPv2 benchmark step 3. Run one deterministic reconcile tick to materialize or repair detachments, failover, approvals, alerts, and traces.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation filter.");
            ("detachment_id", string_prop "Optional detachment filter.");
          ];
    };
    {
      name = "masc_detachment_list";
      description =
        "CPv2 benchmark observe step. List managed and projected detachments after dispatch/tick to confirm runtime materialization.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation or trace filter.");
            ("detachment_id", string_prop "Optional detachment id filter.");
          ];
    };
    {
      name = "masc_detachment_status";
      description =
        "CPv2 benchmark observe step. Inspect one detachment with runtime, heartbeat, failover, and approval context.";
      input_schema =
        object_schema ~required:[ "detachment_id" ]
          [
            ("detachment_id", string_prop "Managed detachment id.");
          ];
    };
    {
      name = "masc_policy_status";
      description =
        "CPv2 benchmark approval step. Read policy decisions, approval queue, capacity overlays, and topology state before strict actions.";
      input_schema = object_schema [];
    };
    {
      name = "masc_policy_approve";
      description =
        "Approve a pending managed policy decision and apply its queued action.";
      input_schema =
        object_schema ~required:[ "decision_id" ]
          [
            ("decision_id", string_prop "Managed decision id.");
            ("reason", string_prop "Optional approval note.");
          ];
    };
    {
      name = "masc_policy_deny";
      description =
        "Deny a pending managed policy decision.";
      input_schema =
        object_schema ~required:[ "decision_id" ]
          [
            ("decision_id", string_prop "Managed decision id.");
            ("reason", string_prop "Optional denial note.");
          ];
    };
    {
      name = "masc_policy_update";
      description =
        "Replace a unit's explicit policy and budget envelope.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("policy", `Assoc [ ("type", `String "object") ]);
            ("budget", `Assoc [ ("type", `String "object") ]);
          ];
    };
    {
      name = "masc_policy_freeze_unit";
      description =
        "Toggle a unit's frozen state. Frozen units reject new dispatch assignments.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("enabled", boolean_prop ~default:true "Set true to freeze, false to unfreeze.");
          ];
    };
    {
      name = "masc_policy_kill_switch";
      description =
        "Toggle a unit kill-switch. Kill-switched units reject all new assignments.";
      input_schema =
        object_schema ~required:[ "unit_id" ]
          [
            ("unit_id", string_prop "Managed unit id.");
            ("enabled", boolean_prop ~default:true "Set true to enable, false to clear.");
          ];
    };
    {
      name = "masc_observe_topology";
      description =
        "CPv2 benchmark observe step. Read company/platoon/squad/agent topology with live roster health and active operation counts.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_operations";
      description =
        "Read operations and detachments together for operator triage.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_alerts";
      description =
        "CPv2 benchmark observe step. Read derived alerts such as leader loss, over-capacity units, quiet detachments, and orphaned operations.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_capacity";
      description =
        "CPv2 benchmark observe step. Read per-unit capacity envelopes, live roster counts, and operation utilization.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_traces";
      description =
        "CPv2 benchmark observe step. Read recent trace events for a single operation or the whole command plane.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Operation id.");
            ("limit", integer_prop ~default:25 "Maximum events to return.");
          ];
    };
  ]
