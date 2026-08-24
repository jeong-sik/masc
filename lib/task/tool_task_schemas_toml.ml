(** The task tools whose declarations moved to
    [config/tools/masc_*.toml] (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2), read from the binary-embedded config tree.

    One file declares one tool; [schema_of_name] decodes it through
    [Tool_definition_toml] once at module initialization. A missing file or a
    declaration that does not decode refuses the boot instead of advertising a
    partial task surface.

    Three siblings — [masc_add_task], [masc_batch_add_tasks] and
    [masc_transition] — are still OCaml literals in [tool_task_schemas.ml].
    Their shapes exceed what the loader accepts today: a top-level object
    parameter with its own [properties] ([contract], [handoff_context]) and an
    array with [maxItems] whose items carry [required]. Moving them is a loader
    change, so it is a separate step rather than a wider version of this one. *)

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
