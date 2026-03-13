open Types
open Tool_command_plane_support

let schemas : tool_schema list = [
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
      name = "masc_intent_create";
      description =
        "Create a managed intent above goals/tasks/operations. Intents hold invariants, artifact priors, and success metrics for lifecycle control.";
      input_schema =
        object_schema ~required:[ "title" ]
          [
            ("title", string_prop "Human-readable intent title.");
            ("owner", string_prop "Optional explicit owner. Defaults to caller.");
            ("workload_profile", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "coding_task"; `String "research_pipeline" ]) ]);
            ("success_metric", `Assoc [ ("type", `String "object") ]);
            ("invariants", string_array_prop "Invariant strings that must remain true.");
            ("artifact_priors", string_array_prop "Preferred artifact scopes or prefixes.");
            ("state", string_prop "Optional initial state. Defaults to adopted.");
            ("current_focus", `Assoc [ ("type", `String "object") ]);
            ("checkpoint_ref", string_prop "Optional checkpoint reference.");
          ];
    };
    {
      name = "masc_intent_status";
      description =
        "Read managed intents and their current focus/lifecycle summary.";
      input_schema =
        object_schema
          [
            ("intent_id", string_prop "Intent id to filter.");
          ];
    };
    {
      name = "masc_intent_update";
      description =
        "Update an intent's title, state, focus, invariants, artifact priors, or success metric.";
      input_schema =
        object_schema ~required:[ "intent_id" ]
          [
            ("intent_id", string_prop "Managed intent id.");
            ("title", string_prop "Optional new title.");
            ("owner", string_prop "Optional owner override.");
            ("workload_profile", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "coding_task"; `String "research_pipeline" ]) ]);
            ("success_metric", `Assoc [ ("type", `String "object") ]);
            ("invariants", string_array_prop "Replacement invariants.");
            ("artifact_priors", string_array_prop "Replacement artifact priors.");
            ("state", string_prop "Optional lifecycle state override.");
            ("current_focus", `Assoc [ ("type", `String "object") ]);
            ("checkpoint_ref", string_prop "Optional checkpoint reference.");
          ];
    };
    {
      name = "masc_intent_forecast";
      description =
        "Predict the next likely focus states for an intent using linked operations and current focus.";
      input_schema =
        object_schema ~required:[ "intent_id" ]
          [
            ("intent_id", string_prop "Managed intent id.");
            ("limit", integer_prop ~default:3 "Maximum candidate next states.");
          ];
    };
    {
      name = "masc_operation_start";
      description =
        "CPv2 benchmark step 2. Start a managed operation on a ready unit after leadership, live-roster, and capacity checks pass. Set orchestration_kind=chain_dsl to attach native chain-plane execution.";
      input_schema =
        object_schema ~required:[ "assigned_unit_id"; "objective" ]
          [
            ("assigned_unit_id", string_prop "Target unit id.");
            ("objective", string_prop "Operation objective.");
            ("intent_id", string_prop "Optional parent intent id.");
            ("autonomy_level", string_prop "Autonomy level such as L3_Guided or L4_Autonomous.");
            ("policy_class", string_prop "Policy class name.");
            ("budget_class", string_prop "Budget class name.");
            ("workload_template", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "coding_team"; `String "research_team"; `String "ops_governance_team" ]); ("description", `String "Optional high-level team template. Defaults: coding_team -> coding_task/decompose, research_team -> research_pipeline/normalize, ops_governance_team -> research_pipeline/audit. If workload_profile is also provided, it must match the template family.") ]);
            ("workload_profile", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "coding_task"; `String "generic"; `String "research_pipeline" ]); ("description", `String "Workload profile used by CPv2 search fabric. Default: coding_task. generic is a deprecated alias for coding_task.") ]);
            ("stage", string_prop "Optional stage label. coding_task: decompose, inspect, implement, verify, review. research_pipeline: normalize, verify, curate, rank, audit.");
            ("artifact_scope", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]); ("description", `String "Optional file or directory scope inherited across coding-task stages.") ]);
            ("depends_on_operation_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]); ("description", `String "Optional upstream operation ids that must complete or checkpoint before this operation can issue.") ]);
            ("search_strategy", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "legacy"; `String "best_first_v1" ]); ("description", `String "Optional CPv2 routing strategy. Default: best_first_v1. legacy remains available as an explicit opt-out.") ]);
            ("detachment_session_id", string_prop "Optional backing team-session id.");
            ("checkpoint_ref", string_prop "Optional initial checkpoint reference.");
            ("active_goal_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("note", string_prop "Optional operator note.");
            ("status", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "planned"; `String "active"; `String "paused" ]) ]);
            ("orchestration_kind", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "native"; `String "chain_dsl" ]); ("description", `String "native (default) or chain_dsl") ]);
            ("chain_id", string_prop "Preset native chain id. Mutually exclusive with chain_goal.");
            ("chain_goal", string_prop "Goal string for native chain orchestration. Mutually exclusive with chain_id.");
            ("chain_input", `Assoc [ ("type", `String "object"); ("description", `String "Optional JSON input forwarded to chain.run input.") ]);
            ("chain_checkpoint_enabled", boolean_prop ~default:true "Enable native checkpoint capture for chain.run.");
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
      name = "masc_chain_snapshot";
      description =
        "Summarize native chain runtime and history, linked back to CPv2 managed operations.";
      input_schema = object_schema [];
    };
    {
      name = "masc_chain_run_get";
      description =
        "Fetch native chain run-store details for a completed chain run by run_id.";
      input_schema =
        object_schema ~required:[ "run_id" ]
          [
            ("run_id", string_prop "Native chain run id from a chain-backed operation.");
          ];
    };
    {
      name = "masc_dispatch_plan";
      description =
        "Recommend the best target units for an operation. best_first_v1 plans include score breakdown, routing reason, and dependency blockers.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Optional operation id to route.");
            ("assigned_unit_id", string_prop "Optional current unit id when planning a new operation.");
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
]
