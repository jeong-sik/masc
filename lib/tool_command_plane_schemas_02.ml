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
      visibility = Public;
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
      visibility = Public;
    };
    {
      name = "masc_observe_alerts";
      description =
        "Read derived alerts: leader loss, over-capacity units, quiet detachments, and orphaned operations. \
Use when scanning for problems across the command plane that need attention. \
Pair with masc_dispatch_escalate or masc_dispatch_rebalance to address issues.";
      input_schema = object_schema [];
      visibility = Public;
    };
    {
      name = "masc_observe_capacity";
      description =
        "Read per-unit capacity envelopes, live roster counts, and operation utilization. \
Use when checking which units have available capacity or are overloaded. \
Pair with masc_dispatch_rebalance to redistribute work from overloaded units.";
      input_schema = object_schema [];
      visibility = Public;
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
      visibility = Public;
    };
]
