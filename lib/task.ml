(** Re-export facade: exposes [Masc_task_handlers] sub-modules as the bare
    [Task] namespace in the main [masc] library.

    Kept at the [lib/] root so that [include_subdirs unqualified] callers
    can refer to [Task.Tool.dispatch], [Task.Schemas], etc. without
    qualifying through [Masc_task_handlers].  Do not add logic here;
    this file is a pure forwarding shim plus tool registration side-effects
    that must live in the main library linkage unit. *)

include Masc_task_handlers.Task
module Tool = Masc_task_handlers.Tool_task
module Dispatch = Masc_task_handlers.Task_dispatch
module Schemas = Masc_task_handlers.Tool_task_schemas
module Payloads = Masc_task_handlers.Tool_task_payloads
module No_eligible = Masc_task_handlers.Tool_task_no_eligible
module Handlers = Masc_task_handlers.Tool_task_handlers
module Contract_gate = Masc_task_handlers.Tool_task_contract_gate
module Completion_review = Masc_task_handlers.Tool_task_completion_review
module Args = Masc_task_handlers.Tool_task_args
module Anti_rationalization = Masc_task_handlers.Anti_rationalization
module Planning_eio = Masc_task_handlers.Planning_eio

let tool_spec_read_only = [ "masc_task_history"; "masc_tasks" ]

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
       Tool_spec.register
         (Tool_spec.create
            ~name:s.name
            ~description:s.description
            ~module_tag:Tool_dispatch.Mod_task
            ~input_schema:s.input_schema
            ~handler_binding:Tag_dispatch
            ~is_read_only:(List.mem s.name tool_spec_read_only)
            ()))
    Schemas.schemas
