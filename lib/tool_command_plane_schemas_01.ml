open Types
open Tool_command_plane_support

let schemas : tool_schema list = [
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
]
