(** Exposes [Masc_task_handlers] sub-modules as the bare
    [Task] namespace in the main [masc] library.

    Kept at the [lib/] root so that [include_subdirs unqualified] callers
    can refer to [Task.Tool.dispatch], [Task.Schemas], etc. without
    qualifying through [Masc_task_handlers]. This is the single namespace
    boundary and also owns tool registration side effects in the main library
    linkage unit. *)

module Tool = Masc_task_handlers.Tool_task
module Goal_assignment = Masc_task_handlers.Task_goal_assignment
module Schemas = Masc_task_handlers.Tool_task_schemas
module Handlers = Masc_task_handlers.Tool_task_handlers
module Completion_review = Masc_task_handlers.Tool_task_completion_review
module Args = Masc_task_handlers.Tool_task_args
module Anti_rationalization = Masc_task_handlers.Anti_rationalization
module Planning_eio = Masc_task_handlers.Planning_eio

let is_read_only = function
  | Tool_name.Task_name.Task_history | Tool_name.Task_name.Tasks -> true
  | Tool_name.Task_name.Add_task
  | Tool_name.Task_name.Batch_add_tasks
  | Tool_name.Task_name.Task_set_goal
  | Tool_name.Task_name.Transition
  | Tool_name.Task_name.Update_priority -> false
;;

(* Registration walks Tool_name.Task_name, the same vocabulary
   [Schemas.schemas] is derived from, so read_only is a match on the
   constructor rather than a membership test over two name strings.

   The registered name still comes from the declaration, not from
   [to_string]: [schema_for] maps a constructor to a pre-loaded value rather
   than looking one up by name, so the two agree today but not by
   construction, and the declaration is what clients are served. *)
let () =
  List.iter
    (fun name ->
       let schema = Schemas.schema_for name in
       Tool_spec.register
         (Tool_spec.create
            ~name:schema.name
            ~description:schema.description
            ~module_tag:Tool_dispatch.Mod_task
            ~input_schema:schema.input_schema
            ~handler_binding:Tag_dispatch
            ~is_read_only:(is_read_only name)
            ()))
    Tool_name.Task_name.all
