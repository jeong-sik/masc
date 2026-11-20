(** The keeper tools whose declarations moved to
    [config/tools/masc_keeper_*.toml], read from the binary-embedded config
    tree.

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial keeper surface, so a reader of these values never has to ask
    whether a schema loaded.

    Every tool [Keeper_schema] publishes is here. Three of them repeat values
    an owner module defines, as TOML literals --
    masc_keeper_status from [Keeper_status_options_defaults],
    masc_keeper_sandbox_stop from [Keeper_sandbox_control_contract], and the
    network-mode enum from [Keeper_types_profile_sandbox] -- and a test pins
    each file against its owner. [test_keeper_schema_toml_parity] pins the
    order the list is published in. *)

let schema_of_name = Tool_definition_embedded.schema

let sandbox_start = schema_of_name Keeper_tool_name.(to_string Keeper_sandbox_start)
let sandbox_stop = schema_of_name Keeper_tool_name.(to_string Keeper_sandbox_stop)
let status = schema_of_name Keeper_tool_name.(to_string Keeper_status)
let audit = schema_of_name Keeper_tool_name.(to_string Keeper_audit)
let up = schema_of_name Keeper_tool_name.(to_string Keeper_up)
let delegate = schema_of_name Keeper_tool_name.(to_string Keeper_delegate)
let delegate_status = schema_of_name Keeper_tool_name.(to_string Keeper_delegate_status)
let delegate_status_many = schema_of_name Keeper_tool_name.(to_string Keeper_delegate_status_many)
let delegate_cancel = schema_of_name Keeper_tool_name.(to_string Keeper_delegate_cancel)
let delegate_list = schema_of_name Keeper_tool_name.(to_string Keeper_delegate_list)
let delegate_targets = schema_of_name Keeper_tool_name.(to_string Keeper_delegate_targets)
let down = schema_of_name Keeper_tool_name.(to_string Keeper_down)
let list = schema_of_name Keeper_tool_name.(to_string Keeper_list)
let reset = schema_of_name Keeper_tool_name.(to_string Keeper_reset)
let msg = schema_of_name Keeper_tool_name.(to_string Keeper_msg)
let clear = schema_of_name Keeper_tool_name.(to_string Keeper_clear)
