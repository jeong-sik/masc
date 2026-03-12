open Types
open Tool_command_plane_support

let schemas : tool_schema list = [
    {
      name = "masc_observe_operations";
      description =
        "Read operations and detachments together for operator triage.";
      input_schema = object_schema [];
    };
    {
      name = "masc_observe_swarm";
      description =
        "Read the swarm-live projection for a run or operation, including pass/fail summary, hot-slot proof, runtime blocker, and next tool guidance.";
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
    {
      name = "masc_swarm_live_run";
      description =
        "Preflight and optionally execute the deterministic swarm-live harness. The tool always writes runtime doctor and summary artifacts under .masc/control-plane/swarm-live/<run_id>/. By default, synchronous self-execution is disabled to avoid MCP server reentrancy hangs, so callers should treat this as a preflight-first orchestration surface that may return structured runtime blockers instead of an inline full run.";
      input_schema =
        object_schema
          [
            ("run_id", string_prop "Run identifier (default: swarm-live).");
            ( "worker_count",
              integer_prop ~default:12
                "Number of swarm workers to spawn (default: 12)." );
          ];
    };
]
