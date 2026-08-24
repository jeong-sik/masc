(** The task tools whose declarations moved to
    [config/tools/masc_*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2), read from the binary-embedded config tree.

    One file declares one tool; [schema_of_name] decodes it through
    [Tool_definition_toml] once at module initialization. A missing file or a
    declaration that does not decode refuses the boot instead of advertising a
    partial task surface.

    [masc_add_task], [masc_batch_add_tasks] and [masc_transition] declare
    nested shapes — an object parameter with its own params ([contract],
    [handoff_context]) and an array whose object items declare required
    children. The loader parsed those two shapes with separate key sets that
    did not admit each other, so they could not move at all; it now writes the
    parameter grammar once and recurses. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let task_history = schema_of_name "masc_task_history"
let tasks = schema_of_name "masc_tasks"
let update_priority = schema_of_name "masc_update_priority"
let task_set_goal = schema_of_name "masc_task_set_goal"
let add_task = schema_of_name "masc_add_task"
let batch_add_tasks = schema_of_name "masc_batch_add_tasks"
let transition = schema_of_name "masc_transition"
