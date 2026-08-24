(** The operator tools, read from [config/tools/masc_operator_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial operator surface.

    Three tools are not here. masc_operator_snapshot, masc_operator_digest and
    masc_operator_action each carry two descriptions -- one for the local
    operator surface and one for the remote subset -- chosen by a [~remote]
    argument. One file declares one tool under one name, so moving them would
    mean two files claiming the same name. Whether the two surfaces need
    different sentences is a question about the surfaces, not about where the
    text lives. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let quarantine_requeue = schema_of_name "masc_operator_board_attention_quarantine_requeue"
let task_recovery_resolve = schema_of_name "masc_operator_task_recovery_resolve"
let confirm = schema_of_name "masc_operator_confirm"
let judgment_write = schema_of_name "masc_operator_judgment_write"
