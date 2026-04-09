open Types
open Tool_command_plane_support

let schemas : tool_schema list = [
    {
      name = "masc_unit_define";
      description =
        "Create or update a managed unit (company/platoon/squad/agent) in the managed-operation hierarchy. \
Use when setting up organizational structure before starting managed operations. \
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
        "Read managed and effective units including auto-generated topology for unassigned agents. \
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
      name = "masc_operation_start";
      description =
        "Start a managed operation on a unit after leadership, roster, and capacity checks pass. \
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
            ("workload_profile", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "coding_task"; `String "generic"; `String "research_pipeline" ]); ("description", `String "Workload profile used by managed-operation search fabric. Default: coding_task. generic is a deprecated alias for coding_task.") ]);
            ("stage", string_prop "Optional stage label. coding_task: decompose, inspect, implement, verify, review. research_pipeline: normalize, verify, curate, rank, audit.");
            ("artifact_scope", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]); ("description", `String "Optional file or directory scope inherited across coding-task stages.") ]);
            ("depends_on_operation_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]); ("description", `String "Optional upstream operation ids that must complete or checkpoint before this operation can issue.") ]);
            ("search_strategy", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "legacy"; `String "best_first_v1" ]); ("description", `String "Optional managed-operation routing strategy. Default: best_first_v1. legacy remains available as an explicit opt-out.") ]);
            ("detachment_session_id", string_prop "Optional backing session id from the existing masc_team_session_* runtime. Current ids still use the established ts-* format; this field was not renamed.");
            ("checkpoint_ref", string_prop "Optional initial checkpoint reference.");
            ("active_goal_ids", `Assoc [ ("type", `String "array"); ("items", `Assoc [ ("type", `String "string") ]) ]);
            ("note", string_prop "Optional operator note.");
            ("status", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "planned"; `String "active"; `String "paused" ]) ]);
          ];
    };
    {
      name = "masc_operation_status";
      description =
        "Read managed operations with their current state, detachments, and trace lineage. \
Use when triaging operations after start or monitoring progress during execution. \
After masc_operation_start; pair with masc_observe_operations for a combined view.";
      input_schema =
        object_schema
          [ ("operation_id", string_prop "Operation id to filter."); ];
    };
    {
      name = "masc_operation_checkpoint";
      description =
        "Attach or update a checkpoint reference for a managed operation, appending a trace event. \
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
        "Run one deterministic reconcile tick to materialize detachments, process failovers, approvals, alerts, and traces. \
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
