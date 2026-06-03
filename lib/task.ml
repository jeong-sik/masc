include Masc_task_handlers.Task
module Tool = Masc_task_handlers.Tool_task
module Dispatch = Masc_task_handlers.Task_dispatch
module Transition_state = Masc_task_handlers.Task_transition_state
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

let tool_required_permission = function
  | "masc_tasks" | "masc_task_history" -> Some Masc_domain.CanReadState
  | "masc_add_task" | "masc_batch_add_tasks" -> Some Masc_domain.CanAddTask
  | "masc_claim_next" -> Some Masc_domain.CanClaimTask
  | "masc_transition" | "masc_update_priority" -> Some Masc_domain.CanCompleteTask
  | _ -> None

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
            ~is_idempotent:(List.mem s.name tool_spec_read_only)
            ?required_permission:(tool_required_permission s.name)
            ()))
    Schemas.schemas
