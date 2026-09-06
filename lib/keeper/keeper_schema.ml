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
let schema_for : Tool_name.Keeper_name.t -> tool_schema = function
  | Tool_name.Keeper_name.Keeper_audit -> Keeper_schema_toml.audit
  | Tool_name.Keeper_name.Keeper_clear -> Keeper_schema_toml.clear
  | Tool_name.Keeper_name.Keeper_delegate -> Keeper_schema_toml.delegate
  | Tool_name.Keeper_name.Keeper_delegate_cancel -> Keeper_schema_toml.delegate_cancel
  | Tool_name.Keeper_name.Keeper_delegate_list -> Keeper_schema_toml.delegate_list
  | Tool_name.Keeper_name.Keeper_delegate_status -> Keeper_schema_toml.delegate_status
  | Tool_name.Keeper_name.Keeper_down -> Keeper_schema_toml.down
  | Tool_name.Keeper_name.Keeper_list -> Keeper_schema_toml.list
  | Tool_name.Keeper_name.Keeper_msg -> Keeper_schema_toml.msg
  | Tool_name.Keeper_name.Keeper_reset -> Keeper_schema_toml.reset
  | Tool_name.Keeper_name.Keeper_sandbox_start -> Keeper_schema_toml.sandbox_start
  | Tool_name.Keeper_name.Keeper_sandbox_stop -> Keeper_schema_toml.sandbox_stop
  | Tool_name.Keeper_name.Keeper_status -> Keeper_schema_toml.status
  | Tool_name.Keeper_name.Keeper_up -> Keeper_schema_toml.up
;;

let schemas : tool_schema list =
  List.map schema_for Tool_name.Keeper_name.all
;;
