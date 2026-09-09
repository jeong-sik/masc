(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Masc_domain

(** Network mode strings exposed only by explicit sandbox-management tools.
    Keeper creation/update no longer accepts sandbox posture knobs. *)
let network_mode_enum_strings =
  Keeper_types_profile_sandbox.valid_network_mode_strings
;;

(* One schema per Tool_name.Keeper_name constructor. The list used to be
   written out by hand next to two dispatchers that matched the same names as
   strings, so the three were kept in step by hand. *)
let schema_for : Keeper_tool_name.t -> tool_schema = function
  | Keeper_tool_name.Keeper_audit -> Keeper_schema_toml.audit
  | Keeper_tool_name.Keeper_clear -> Keeper_schema_toml.clear
  | Keeper_tool_name.Keeper_delegate -> Keeper_schema_toml.delegate
  | Keeper_tool_name.Keeper_delegate_cancel -> Keeper_schema_toml.delegate_cancel
  | Keeper_tool_name.Keeper_delegate_list -> Keeper_schema_toml.delegate_list
  | Keeper_tool_name.Keeper_delegate_status -> Keeper_schema_toml.delegate_status
  | Keeper_tool_name.Keeper_down -> Keeper_schema_toml.down
  | Keeper_tool_name.Keeper_list -> Keeper_schema_toml.list
  | Keeper_tool_name.Keeper_msg -> Keeper_schema_toml.msg
  | Keeper_tool_name.Keeper_reset -> Keeper_schema_toml.reset
  | Keeper_tool_name.Keeper_sandbox_start -> Keeper_schema_toml.sandbox_start
  | Keeper_tool_name.Keeper_sandbox_stop -> Keeper_schema_toml.sandbox_stop
  | Keeper_tool_name.Keeper_status -> Keeper_schema_toml.status
  | Keeper_tool_name.Keeper_up -> Keeper_schema_toml.up
;;

let schemas : tool_schema list =
  List.map schema_for Keeper_tool_name.all
;;
