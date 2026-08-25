(** The keeper tools whose declarations moved to
    [config/tools/masc_keeper_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2), read from the
    binary-embedded config tree.

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial keeper surface, so a reader of these values never has to ask
    whether a schema loaded.

    Twelve of the fifteen tools [Keeper_schema] publishes are here. The other
    three build values from an owner module rather than literals --
    masc_keeper_status from [Keeper_status_options_defaults],
    masc_keeper_sandbox_stop from [Keeper_sandbox_control_contract], and the
    network-mode enum from [Keeper_types_profile_sandbox] -- and a TOML literal
    would cut that derivation. They move when each has a test pinning the file
    against its owner. [test_keeper_schema_toml_parity] pins all fifteen
    against what the list published before any of this moved. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let sandbox_start = schema_of_name "masc_keeper_sandbox_start"
let sandbox_stop = schema_of_name "masc_keeper_sandbox_stop"
let status = schema_of_name "masc_keeper_status"
let audit = schema_of_name "masc_keeper_audit"
let up = schema_of_name "masc_keeper_up"
let delegate = schema_of_name "masc_keeper_delegate"
let delegate_status = schema_of_name "masc_keeper_delegate_status"
let delegate_cancel = schema_of_name "masc_keeper_delegate_cancel"
let delegate_list = schema_of_name "masc_keeper_delegate_list"
let down = schema_of_name "masc_keeper_down"
let list = schema_of_name "masc_keeper_list"
let reset = schema_of_name "masc_keeper_reset"
let compact = schema_of_name "masc_keeper_compact"
let msg = schema_of_name "masc_keeper_msg"
let clear = schema_of_name "masc_keeper_clear"
