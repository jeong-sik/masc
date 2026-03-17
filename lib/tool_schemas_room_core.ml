(** MCP tool schemas for room management operations (core).

    Only schemas dispatched by Tool_room remain here.
    Other schemas have been moved to their owning modules:
    - Tool_task, Tool_control, Tool_suspend, Tool_plan, Tool_portal,
      Tool_inline_dispatch (via Tool_schemas_inline) *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_status";
    description = "Get current room/cluster status: active agents with capabilities, task queue, recent broadcasts, and cluster info. Shows cluster name (from MASC_CLUSTER_NAME or basename of ME_ROOT) and storage backend (fs or postgres).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_reset";
    description = "DESTRUCTIVE: Reset MASC room completely. Deletes ALL data in .masc/ folder. \
Removes: tasks, messages, agents, locks, cache, telemetry. Cannot be undone. \
Use only for: fresh start, corrupted state recovery, testing. \
Requires confirm=true to execute. Example: masc_reset({confirm: true})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("confirm", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Set to true to confirm reset");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
]
