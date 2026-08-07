(** MCP tool schemas for workspace management operations (core).

    Only schemas dispatched by Tool_workspace remain here.
    Other schemas live in their owning modules. *)

open Masc_domain

(** Issue #8636: hand-mirrored from
    [Tool_workspace.valid_assertion_strings]. Cycle constraint —
    [Tool_schemas_workspace_core] is upstream of [Tool_workspace] (the schema
    library lives in [masc_tool_schemas], the handler is in [masc]).
    [test_assertion_kind_mirror] compares the enum [masc_check] publishes
    against the owner's list, so a kind that grows on one side and not the
    other fails there instead of silently dropping from the JSON Schema. *)
let assertion_kind_enum_strings =
  [ "task_claimed"; "current_task_set" ]

let schemas : tool_schema list = [
  {
    name = "masc_status";
    description = "Get current project status: active agents, task queue, recent broadcasts, and cluster info. \
Use when you need a snapshot of who is online and what tasks are available. \
Call after masc_start to orient yourself. Pair with masc_tasks for detailed backlog.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("if_revision", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional producer revision from the previous snapshot; matching revisions return unchanged.");
        ]);
      ]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_check";
    description = "Assert task preconditions on your agent state (task claimed, current task set, etc). \
Call when you want to confirm prerequisites before starting work; returns pass/fail with fix hints.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("assertions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "string");
            ("enum",
             `List
               (List.map (fun s -> `String s) assertion_kind_enum_strings));
          ]);
          ("description", `String "List of task-state assertions to check. Each returns true/false with a fix hint if false.");
        ]);
      ]);
      ("required", `List [`String "assertions"]);
      ("additionalProperties", `Bool false);
    ];
  };

  {
    name = "masc_heartbeat";
    description = "Publish the caller's heartbeat observation. Heartbeats are \
telemetry only and do not grant another component authority to stop, evict, or \
release the caller's work.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("additionalProperties", `Bool false);
    ];
  };
]
