(** MCP tool schemas for workspace management operations (core).

    Only schemas dispatched by Tool_workspace remain here.
    Other schemas have been moved to their owning modules:
      Mcp_tool_runtime (via Tool_schemas_inline) *)

open Masc_domain

(** Issue #8636: hand-mirrored from
    [Tool_workspace.valid_assertion_strings]. Cycle constraint —
    [Tool_schemas_workspace_core] is upstream of [Tool_workspace] (the schema
    library lives in [masc_tool_schemas], the handler is in [masc]).
    The test [test_types.ml :: assertion_kind_ssot] asserts this mirror
    stays in sync with the SSOT so adding a 6th assertion kind fails
    compilation in [assertion_kind_to_string] AND fails the test here,
    instead of silently dropping from the JSON Schema. *)
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
      ("properties", `Assoc []);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_reset";
    description = "DESTRUCTIVE: Reset the active MASC project completely. Deletes ALL data in .masc/ folder. \
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
    description = "Update your heartbeat timestamp to prove you are still active. \
Call every few minutes during long tasks; agents silent for 5+ min become zombie candidates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
      ("additionalProperties", `Bool false);
    ];
  };
]
