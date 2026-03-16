(** Tool_schemas_core — Core MCP tool schema definitions.

    Split into three private sub-modules for maintainability:
    - Tool_schemas_core_01: init through recall_search schemas
    - Tool_schemas_core_02: a2a through governance schemas
    - Tool_schemas_core_03: walph through keeper_tool_catalog schemas *)

open Types

let schemas : tool_schema list =
  Tool_schemas_core_01.schemas
  @ Tool_schemas_core_02.schemas
  @ Tool_schemas_core_03.schemas
