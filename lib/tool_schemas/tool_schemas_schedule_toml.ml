(** The schedule tools, read from [config/tools/masc_schedule_*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial schedule surface, so a reader of these values never has to ask
    whether a schema loaded.

    The enum arrays are literals here: nothing in TOML reads an OCaml variant.
    [Schedule_contract_values] stays the owner, and [test_enum_mirror_sync]
    compares each of the six advertised vocabularies against it, so a
    constructor added on one side without editing the file fails there instead
    of shipping a schema that never offers the value.
    [test_schedule_tool_toml_parity] pins the four migrated declarations
    against what the list published before the move and separately checks
    that the later update declaration shares the create field set. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let create = schema_of_name "masc_schedule_create"
let update = schema_of_name "masc_schedule_update"
let list = schema_of_name "masc_schedule_list"
let get = schema_of_name "masc_schedule_get"
let cancel = schema_of_name "masc_schedule_cancel"
