(** Tool_schemas_run — SSOT for run-tracking tool schemas.

    Defines schemas for task execution lifecycle: init, plan, get,
    and list.
*)


let schemas : Masc_domain.tool_schema list =
  [
    Tool_schemas_run_toml.init;
    Tool_schemas_run_toml.plan;
    Tool_schemas_run_toml.get;
    Tool_schemas_run_toml.list;
  ]
