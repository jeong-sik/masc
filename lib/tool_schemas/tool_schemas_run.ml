(** Tool_schemas_run — SSOT for run-tracking tool schemas.

    Defines schemas for task execution lifecycle: init, plan, get,
    and list.
*)


type operation =
  | Run_init
  | Run_plan
  | Run_get
  | Run_list
[@@deriving enumerate]

let operations = all_of_operation

let schema = function
  | Run_init -> Tool_schemas_run_toml.init
  | Run_plan -> Tool_schemas_run_toml.plan
  | Run_get -> Tool_schemas_run_toml.get
  | Run_list -> Tool_schemas_run_toml.list
;;

let operation_of_tool_name value =
  List.find_opt
    (fun operation -> String.equal value (schema operation).Masc_domain.name)
    operations
;;

let schemas : Masc_domain.tool_schema list = List.map schema operations
