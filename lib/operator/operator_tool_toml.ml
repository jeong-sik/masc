(** The operator tools, read from [config/tools/masc_operator_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial operator surface.

    Three of the tools -- masc_operator_snapshot, masc_operator_digest and
    masc_operator_action -- are published on two surfaces: the full local
    catalog and the operator-remote subset. Each file's top-level
    [description] is the local sentence and its
    [operator_remote_description] the remote one; [dual_of_name] pairs the
    two schemas and refuses the boot when such a file omits the remote
    sentence. *)

type dual_schemas =
  { local : Masc_domain.tool_schema
  ; remote : Masc_domain.tool_schema
  }

let load_of_name name : Tool_definition_toml.loaded =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok loaded -> loaded
     | Error message -> failwith message)
;;

let schema_of_name name = (load_of_name name).Tool_definition_toml.schema

let dual_of_name name =
  let loaded = load_of_name name in
  match loaded.Tool_definition_toml.operator_remote_description with
  | Some remote_description ->
    let schema = loaded.Tool_definition_toml.schema in
    { local = schema
    ; remote = { schema with Masc_domain.description = remote_description }
    }
  | None ->
    failwith
      (Printf.sprintf
         "%s is a dual-surface operator tool but declares no operator_remote_description"
         name)
;;

let snapshot = dual_of_name "masc_operator_snapshot"
let digest = dual_of_name "masc_operator_digest"
let action = dual_of_name "masc_operator_action"
let quarantine_requeue = schema_of_name "masc_operator_board_attention_quarantine_requeue"
let task_recovery_resolve = schema_of_name "masc_operator_task_recovery_resolve"
let confirm = schema_of_name "masc_operator_confirm"
let judgment_write = schema_of_name "masc_operator_judgment_write"
