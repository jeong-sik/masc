(** The taskboard tools whose declarations moved to [config/tools/*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2), read from the
    binary-embedded config tree.

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial taskboard surface, so a reader of these values never has to ask
    whether a schema loaded.

    keeper_tasks_list was the last of the seven left in OCaml: its status enum
    comes from [Masc_domain.valid_task_status_strings], and a TOML literal cuts
    that derivation. The condition for moving it was a test pinning the file
    against its owner, and [test_taskboard_tool_toml_parity] now carries one —
    it compares the enum in the declaration against that value, so a new
    task_status constructor fails the suite instead of quietly publishing a
    schema that no longer names every status. The same suite pins all seven
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

let tasks_list = schema_of_name "keeper_tasks_list"
let tasks_audit = schema_of_name "keeper_tasks_audit"
let broadcast = schema_of_name "keeper_broadcast"
let task_claim = schema_of_name "keeper_task_claim"
let task_done = schema_of_name "keeper_task_done"
let task_cancel = schema_of_name "keeper_task_cancel"
let task_release = schema_of_name "keeper_task_release"
let task_create = schema_of_name "keeper_task_create"
