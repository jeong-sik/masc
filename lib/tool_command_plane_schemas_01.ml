open Types
open Tool_command_plane_support

let schemas : tool_schema list = [
    {
      name = "masc_unit_define";
      description =
        "Create or update a managed unit (company/platoon/squad/agent) in the Command Plane V2 hierarchy. \
Use when setting up organizational structure before starting operations (CPv2 benchmark step 1). \
Pair with masc_operation_start to run operations on defined units.";
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
        "Read managed and effective CPv2 units including auto-generated topology for unassigned agents. \
Use when inspecting the organizational hierarchy or verifying unit definitions. \
Pair with masc_observe_topology for a richer view with health and operation counts.";
      input_schema = object_schema [];
    };
    {
      name = "masc_unit_reparent";
      description =
        "Move a unit under a new parent unit while preserving its policy and budget envelopes. \
Use when restructuring the organizational hierarchy without losing existing configurations. \
Pair with masc_unit_list to verify the new topology after reparenting.";
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
        "Update a unit's leader or explicit roster for leader rotation or roster replacement. \
Use when rotating squad leaders or adjusting the team composition of a unit. \
Pair with masc_observe_topology to verify roster changes took effect.";
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
        "Create a managed intent that sits above goals/tasks/operations, holding invariants, artifact priors, and success metrics. \
Use when starting a new workstream that needs lifecycle tracking across multiple operations. \
Pair with masc_operation_start to attach operations under this intent.";
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
        "Read managed intents and their current focus, lifecycle state, and linked operations. \
Use when checking which intents are active and what they are focused on. \
Pair with masc_intent_update to change focus or state, or masc_intent_forecast for predictions.";
      input_schema =
        object_schema
          [
            ("intent_id", string_prop "Intent id to filter.");
          ];
    };
    {
      name = "masc_intent_update";
      description =
        "Update an intent's title, state, focus, invariants, artifact priors, or success metric. \
Use when an intent's direction changes or a milestone is reached. \
After masc_intent_status to review current state; pair with masc_intent_forecast to predict next steps.";
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
        "Predict the next likely focus states for an intent based on linked operations and current progress. \
Use when planning ahead or deciding which operation to start next under an intent. \
After masc_intent_status; pair with masc_operation_start to act on the forecast.";
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
        "Start a managed operation on a unit after leadership, roster, and capacity checks pass (CPv2 benchmark step 2). \
Use when launching work on a defined unit with budget and policy controls. \
After masc_unit_define; follow with masc_dispatch_tick to materialize detachments.";
      input_schema =
        object_schema ~required:[ "assigned_unit_id"; "objective" ]
          [
            ("assigned_unit_id", string_prop "Target unit id.");
            ("objective", string_prop "Operation objective.");
            ("intent_id", string_prop "Optional parent intent id.");
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
          ];
    };
    {
      name = "masc_operation_status";
      description =
        "Read CPv2 operations with their current state, detachments, and trace lineage. \
Use when triaging operations after start or monitoring progress during execution. \
After masc_operation_start; pair with masc_observe_operations for a combined view.";
      input_schema =
        object_schema
          [ ("operation_id", string_prop "Operation id to filter."); ];
    };
    {
      name = "masc_operation_checkpoint";
      description =
        "Attach or update a checkpoint reference for a managed CPv2 operation, appending a trace event. \
Use when saving durable resume pointers at key milestones during an operation. \
Pair with masc_operation_resume to restart from the saved checkpoint.";
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
      description = "Pause a managed operation and sync its detachment status to paused. \
Use when the operation needs to be temporarily halted without losing progress. \
Pair with masc_operation_resume to continue or masc_operation_stop to cancel.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional pause note.");
          ];
    };
    {
      name = "masc_operation_resume";
      description = "Resume a paused managed operation from its last checkpoint. \
Use when a previously paused operation is ready to continue. \
After masc_operation_pause; pair with masc_dispatch_tick to re-materialize detachments.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional resume note.");
          ];
    };
    {
      name = "masc_operation_stop";
      description = "Cancel a managed operation and mark its detachment as stopped. \
Use when an operation is no longer needed or has failed beyond recovery. \
Pair with masc_operation_status to verify the cancellation took effect.";
      input_schema =
        object_schema ~required:[ "operation_id" ]
          [
            ("operation_id", string_prop "Managed operation id.");
            ("note", string_prop "Optional stop reason.");
          ];
    };
    {
      name = "masc_operation_finalize";
      description = "Finalize a managed operation as completed, marking it done in the trace lineage. \
Use when all operation objectives are met and work is finished. \
After the operation's detachments report completion; pair with masc_observe_traces to review the full trail.";
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
        "Recommend the best target units for an operation with score breakdown and routing reasons. \
Use when deciding which unit should handle a new operation or when rebalancing. \
Before masc_dispatch_assign to act on the recommendation.";
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
        "Assign or move an operation to a new unit (cross-platoon moves become pending approvals). \
Use when routing an operation to a specific unit based on dispatch plan results. \
After masc_dispatch_plan; follow with masc_dispatch_tick to materialize.";
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
        "Rebalance an operation to another unit using the same approval semantics as dispatch_assign. \
Use when load is uneven across units and work needs redistribution. \
After masc_observe_capacity identifies overloaded units.";
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
        "Escalate an operation toward a parent unit or explicit target (cross-platoon moves require approval). \
Use when a unit lacks capacity or expertise and the operation needs higher-level handling. \
Pair with masc_policy_approve if the escalation requires approval.";
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
        "Recall an operation by pausing it while preserving its checkpoint and trace lineage. \
Use when an operation needs to be pulled back temporarily without data loss. \
Pair with masc_operation_resume to re-activate when ready.";
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
        "Run one deterministic reconcile tick to materialize detachments, process failovers, approvals, alerts, and traces (CPv2 step 3). \
Use when operations need their detachments materialized or the control plane needs reconciliation. \
After masc_operation_start or masc_dispatch_assign; run repeatedly until stable.";
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
        "List managed and projected detachments after dispatch/tick to confirm runtime materialization. \
Use when verifying that dispatch_tick created the expected detachments. \
After masc_dispatch_tick; pair with masc_detachment_status for per-detachment details.";
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
        "Inspect a single detachment with runtime, heartbeat, failover, and approval context. \
Use when debugging a specific detachment or verifying its runtime state. \
After masc_detachment_list identifies the detachment_id.";
      input_schema =
        object_schema ~required:[ "detachment_id" ]
          [
            ("detachment_id", string_prop "Managed detachment id.");
          ];
    };
    {
      name = "masc_policy_status";
      description =
        "Read policy decisions, approval queue, capacity overlays, and topology state. \
Use when checking pending approvals or reviewing policy state before strict actions. \
Pair with masc_policy_approve or masc_policy_deny to process pending decisions.";
      input_schema = object_schema [];
    };
    {
      name = "masc_policy_approve";
      description =
        "Approve a pending managed policy decision and apply its queued action. \
Use when a cross-platoon move, escalation, or policy change needs human/admin approval. \
After masc_policy_status shows pending decisions.";
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
        "Deny a pending managed policy decision, preventing its queued action. \
Use when a proposed move or policy change should not proceed. \
After masc_policy_status shows pending decisions.";
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
        "Replace a unit's explicit policy and budget envelope. \
Use when adjusting a unit's capacity limits, spending controls, or operational constraints. \
Pair with masc_policy_status to review the updated configuration.";
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
        "Toggle a unit's frozen state so it rejects new dispatch assignments when frozen. \
Use when a unit needs maintenance or should temporarily stop accepting new work. \
Pair with masc_observe_capacity to check unit workload before/after freezing.";
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
        "Toggle a unit kill-switch that rejects all new assignments when enabled. \
Use when a unit must be fully isolated from receiving any work. \
Pair with masc_policy_status to verify the kill-switch state.";
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
        "Read the full company/platoon/squad/agent topology with live roster health and active operation counts. \
Use when getting a birds-eye view of the organizational structure and its operational load. \
Pair with masc_observe_capacity for per-unit budget utilization details.";
      input_schema = object_schema [];
    };
]
