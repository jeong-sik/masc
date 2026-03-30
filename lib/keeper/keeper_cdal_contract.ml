module Oas = Agent_sdk

let infer_risk_class (meta : Keeper_types.keeper_meta) : Oas.Risk_class.t =
  match String.lowercase_ascii meta.scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Risk_class.Low
  | "workspace" | "local" -> Oas.Risk_class.Medium
  | "full" | "unrestricted" -> Oas.Risk_class.Medium
  | _ -> Oas.Risk_class.Medium

let infer_execution_mode (meta : Keeper_types.keeper_meta) : Oas.Execution_mode.t =
  match String.lowercase_ascii meta.scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Execution_mode.Diagnose
  | "workspace" | "local" -> Oas.Execution_mode.Draft
  | _ -> Oas.Execution_mode.Execute

let infer_allowed_mutations (meta : Keeper_types.keeper_meta) : string list =
  let effective = Keeper_alerting_path.effective_allowed_paths ~meta in
  match String.lowercase_ascii meta.execution_scope with
  | "workspace" | "local" -> ["workspace_only"]
  | _ ->
    if effective <> [] then ["workspace_only"]
    else []

let of_keeper_meta (meta : Keeper_types.keeper_meta)
    : Oas.Risk_contract.t option =
  let risk_class = infer_risk_class meta in
  let mode = infer_execution_mode meta in
  let allowed_mutations = infer_allowed_mutations meta in
  Some Oas.Risk_contract.{
    runtime_constraints = {
      requested_execution_mode = mode;
      risk_class;
      allowed_mutations;
      review_requirement = None;
    };
    eval_criteria = `Assoc [
      "keeper_name", `String meta.name;
      "goal", `String meta.short_goal;
    ];
  }
