(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Masc_domain

(** Network mode strings exposed only by explicit sandbox-management tools.
    Keeper creation/update no longer accepts sandbox posture knobs. *)
let network_mode_enum_strings =
  Keeper_types_profile_sandbox.valid_network_mode_strings
;;

let schemas : tool_schema list = [
  Keeper_schema_toml.sandbox_start;
  Keeper_schema_toml.sandbox_stop;
  Keeper_schema_toml.audit;

  Keeper_schema_toml.up;

  Keeper_schema_toml.status;

  Keeper_schema_toml.delegate
; Keeper_schema_toml.delegate_status
; Keeper_schema_toml.delegate_cancel
; Keeper_schema_toml.delegate_list;


  Keeper_schema_toml.down;

  Keeper_schema_toml.list;

  Keeper_schema_toml.reset;


  Keeper_schema_toml.msg;

  Keeper_schema_toml.clear;

]
