module Oas = Agent_sdk

let workspace_mutating_tools =
  [
    "keeper_fs_edit";
    "keeper_edit";
    "keeper_write";
    "create_text_file";
    "edit_text_file";
  ]

let is_workspace_mutating name =
  List.mem name workspace_mutating_tools

let dedup_strings = Team_session_types.dedup_strings

let allowed_mutations_of_tool_names tool_names =
  tool_names
  |> List.filter is_workspace_mutating
  |> dedup_strings

let review_requirement_of_risk_class = function
  | Oas.Risk_class.High | Oas.Risk_class.Critical -> Some "human_review"
  | _ -> None

let build_delivery_eval_criteria
    (dc : Team_session_types.delivery_contract) : Yojson.Safe.t =
  `Assoc
    [
      ( "success_criteria",
        `List (List.map (fun item -> `String item) dc.acceptance_checks) );
      ( "required_evidence",
        `List (List.map (fun item -> `String item) dc.required_artifacts) );
      ("contract_id", `String dc.contract_id);
      ("evaluator_cascade", `String dc.evaluator_cascade);
    ]

let requested_mode_of_repair_budget repair_budget =
  if repair_budget > 0 then Oas.Execution_mode.Execute
  else Oas.Execution_mode.Draft

let of_delivery_contract
    ~(delivery_contract : Team_session_types.delivery_contract)
    ~(tool_names : string list) : Oas.Risk_contract.t =
  let risk_class =
    Contract_risk.of_delivery_contract ~delivery_contract ~tool_names
  in
  {
    Oas.Risk_contract.runtime_constraints =
      {
        requested_execution_mode =
          requested_mode_of_repair_budget delivery_contract.repair_budget;
        risk_class;
        allowed_mutations = allowed_mutations_of_tool_names tool_names;
        review_requirement = review_requirement_of_risk_class risk_class;
      };
    eval_criteria = build_delivery_eval_criteria delivery_contract;
  }

let infer_keeper_risk_class ~(scope_kind : string) : Oas.Risk_class.t =
  match String.lowercase_ascii scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Risk_class.Low
  | "workspace" | "local" -> Oas.Risk_class.Medium
  | "full" | "unrestricted" -> Oas.Risk_class.Medium
  | _ -> Oas.Risk_class.Medium

let infer_keeper_execution_mode ~(scope_kind : string) : Oas.Execution_mode.t =
  match String.lowercase_ascii scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Execution_mode.Diagnose
  | "workspace" | "local" -> Oas.Execution_mode.Draft
  | _ -> Oas.Execution_mode.Execute

let infer_keeper_allowed_mutations ~(execution_scope : string)
    ~(allowed_paths : string list) =
  match String.lowercase_ascii execution_scope with
  | "workspace" | "local" -> [ "workspace_only" ]
  | _ ->
      if allowed_paths <> [] then [ "workspace_only" ] else []

let build_keeper_eval_criteria ~keeper_name ~(goal : string) =
  `Assoc [ ("keeper_name", `String keeper_name); ("goal", `String goal) ]

let of_keeper
    ~(keeper_name : string)
    ~(goal : string)
    ~(scope_kind : string)
    ~(execution_scope : string)
    ~(allowed_paths : string list) : Oas.Risk_contract.t =
  {
    Oas.Risk_contract.runtime_constraints =
      {
        requested_execution_mode =
          infer_keeper_execution_mode ~scope_kind;
        risk_class = infer_keeper_risk_class ~scope_kind;
        allowed_mutations =
          infer_keeper_allowed_mutations ~execution_scope ~allowed_paths;
        review_requirement = None;
      };
    eval_criteria = build_keeper_eval_criteria ~keeper_name ~goal;
  }

let of_keeper_meta (meta : Keeper_types.keeper_meta) : Oas.Risk_contract.t =
  of_keeper ~keeper_name:meta.name ~goal:meta.short_goal
    ~scope_kind:meta.scope_kind ~execution_scope:meta.execution_scope
    ~allowed_paths:(Keeper_alerting_path.effective_allowed_paths ~meta)
