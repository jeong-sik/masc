(** Tool_schemas_workspace_core — MCP tool schemas for workspace management
    (core subset).

    Only schemas dispatched by {!Tool_workspace} live here. Other
    schemas have been moved to their owning modules
    ({!Task.Tool}, {!Tool_control}, {!Tool_plan},

    Issue #8636: [assertion_kind_enum_strings] hand-mirrors
    {!Tool_workspace.valid_assertion_strings}; the sync regression test
    [test_assertion_kind_mirror] catches drift. *)

type operation =
  | Status
  | Check
  | Heartbeat
[@@deriving enumerate]
(** Closed vocabulary of the core workspace tools [Tool_workspace] routes
    outside the goal family. *)

val operations : operation list
(** Exhaustive stable-order projection of the core workspace operations. *)

val schema : operation -> Masc_domain.tool_schema
(** Declaration for a core workspace operation. *)

val tool_name : operation -> string
(** Canonical wire name, taken from the declaration rather than restated. *)

val operation_of_tool_name : string -> operation option
(** Parse a canonical core workspace wire name at the dispatch boundary. *)

(** Tool schemas: [masc_status], [masc_check], [masc_heartbeat]. *)
val schemas : Masc_domain.tool_schema list
