include module type of struct
  include Masc_task_handlers.Task
end
module Tool : module type of Masc_task_handlers.Tool_task
module Anti_rationalization : module type of Masc_task_handlers.Anti_rationalization
module Dispatch : module type of Masc_task_handlers.Task_dispatch
module Schemas : module type of Masc_task_handlers.Tool_task_schemas
module Payloads : module type of Masc_task_handlers.Tool_task_payloads
module No_eligible : module type of Masc_task_handlers.Tool_task_no_eligible
module Handlers : module type of Masc_task_handlers.Tool_task_handlers
module Contract_gate : module type of Masc_task_handlers.Tool_task_contract_gate
module Completion_review : module type of Masc_task_handlers.Tool_task_completion_review
module Args : module type of Masc_task_handlers.Tool_task_args
module Planning_eio : module type of Masc_task_handlers.Planning_eio
