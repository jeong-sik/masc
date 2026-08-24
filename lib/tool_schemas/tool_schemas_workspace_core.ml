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
  Tool_schemas_workspace_core_toml.status;
  Tool_schemas_workspace_core_toml.check;

  Tool_schemas_workspace_core_toml.heartbeat;
]
