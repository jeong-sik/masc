(** Tool_schemas_run — SSOT for run-tracking tool schemas.

    Defines schemas for task execution lifecycle: init, plan, get,
    and list. *)

type operation =
  | Run_init
  | Run_plan
  | Run_get
  | Run_list
[@@deriving enumerate]

let operations = all_of_operation

let init_schema = Tool_definition_embedded.schema "masc_run_init"
let plan_schema = Tool_definition_embedded.schema "masc_run_plan"
let get_schema = Tool_definition_embedded.schema "masc_run_get"
let list_schema = Tool_definition_embedded.schema "masc_run_list"

let schema = function
  | Run_init -> init_schema
  | Run_plan -> plan_schema
  | Run_get -> get_schema
  | Run_list -> list_schema
;;

let operation_of_tool_name value =
  List.find_opt
    (fun operation -> String.equal value (schema operation).Masc_domain.name)
    operations
;;

let schemas : Masc_domain.tool_schema list = List.map schema operations
