open Types
open Tool_command_plane_support

let schemas : tool_schema list = [
    {
      name = "masc_observe_operations";
      description =
        "Read operations and detachments together in a single view for operator triage. \
Use when you need a combined operations + detachments snapshot for quick assessment. \
Pair with masc_observe_alerts for derived alerts on problematic units.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_swarm";
      description =
        "Read the swarm-live projection for a run or operation with pass/fail summary, hot-slot proof, and runtime blockers. \
Use when monitoring a swarm-live execution or diagnosing why slots are blocked. \
Pair with masc_observe_alerts for a full picture.";
      input_schema =
        object_schema
          [
            ("run_id", string_prop "Swarm-live run id.");
            ("operation_id", string_prop "Optional managed operation id.");
          ];
    };
    {
      name = "masc_observe_alerts";
      description =
        "Read derived alerts: leader loss, over-capacity units, quiet detachments, and orphaned operations. \
Use when scanning for problems across the command plane that need attention. \
Pair with masc_dispatch_escalate or masc_dispatch_rebalance to address issues.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_capacity";
      description =
        "Read per-unit capacity envelopes, live roster counts, and operation utilization. \
Use when checking which units have available capacity or are overloaded. \
Pair with masc_dispatch_rebalance to redistribute work from overloaded units.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_traces";
      description =
        "Read recent trace events for a single operation or the entire command plane. \
Use when auditing what happened during an operation or reviewing system-wide activity. \
Pair with masc_operation_status for the operation's current state.";
      input_schema =
        object_schema
          [
            ("operation_id", string_prop "Operation id.");
            ("limit", integer_prop ~default:25 "Maximum events to return.");
          ];
    };
    {
      name = "masc_intent_create";
      description =
        "Create a strategic intent that groups related operations under a shared objective and workload profile. \
Use when planning multi-operation campaigns before issuing individual operations. \
Pair with masc_operation_start (intent_id param) to bind operations to this intent.";
      input_schema =
        object_schema ~required:[ "title" ]
          [
            ("title", string_prop "Human-readable intent title.");
            ("owner", string_prop "Owner agent id. Defaults to caller.");
            ("workload_profile", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "coding_task"; `String "generic"; `String "research_pipeline" ]); ("description", `String "Workload profile for search fabric routing. Default: coding_task. generic is a deprecated alias for coding_task.") ]);
            ("success_metric", `Assoc [ ("type", `String "object"); ("description", `String "Optional JSON object describing the measurable success criteria.") ]);
            ("invariants", string_array_prop "Invariant constraints that must hold across all bound operations.");
            ("artifact_priors", string_array_prop "Known artifact paths or references relevant to this intent.");
            ("state", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "adopted"; `String "active"; `String "paused"; `String "completed"; `String "abandoned" ]); ("description", `String "Initial intent state. Default: adopted.") ]);
            ("current_focus", `Assoc [ ("type", `String "object"); ("description", `String "Optional focus object with file_path, symbol, and note fields.") ]);
            ("checkpoint_ref", string_prop "Optional initial checkpoint reference.");
          ];
    };
    {
      name = "masc_intent_status";
      description =
        "List intents with their state, workload profile, and bound operations. \
Use when reviewing strategic planning or checking which intents are active. \
Pair with masc_intent_forecast for completion predictions.";
      input_schema =
        object_schema
          [
            ("intent_id", string_prop "Optional intent id to filter a single intent.");
          ];
    };
    {
      name = "masc_intent_update";
      description =
        "Update an existing intent's title, state, focus, or workload profile. \
Use when refining strategy mid-execution or transitioning intent state. \
Pair with masc_intent_status to verify the update took effect.";
      input_schema =
        object_schema ~required:[ "intent_id" ]
          [
            ("intent_id", string_prop "Intent id to update.");
            ("title", string_prop "New title.");
            ("owner", string_prop "New owner agent id.");
            ("workload_profile", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "coding_task"; `String "generic"; `String "research_pipeline" ]); ("description", `String "Workload profile for search fabric routing. coding_task is canonical; generic remains accepted only as a deprecated alias.") ]);
            ("success_metric", `Assoc [ ("type", `String "object"); ("description", `String "Updated success criteria.") ]);
            ("invariants", string_array_prop "Replacement invariant list.");
            ("artifact_priors", string_array_prop "Replacement artifact prior list.");
            ("state", `Assoc [ ("type", `String "string"); ("enum", `List [ `String "adopted"; `String "active"; `String "paused"; `String "completed"; `String "abandoned" ]) ]);
            ("current_focus", `Assoc [ ("type", `String "object"); ("description", `String "Updated focus object.") ]);
            ("checkpoint_ref", string_prop "Updated checkpoint reference.");
          ];
    };
    {
      name = "masc_intent_forecast";
      description =
        "Forecast completion likelihood for an intent based on its bound operations' progress and search fabric scoring. \
Use when assessing whether an intent is on track or needs intervention. \
Pair with masc_observe_operations for detailed operation-level status.";
      input_schema =
        object_schema ~required:[ "intent_id" ]
          [
            ("intent_id", string_prop "Intent id to forecast.");
            ("limit", integer_prop ~default:3 "Maximum forecast entries to return.");
          ];
    };
]
