let workspace_mutating_tools =
  Tool_catalog_surfaces.workspace_mutating_tool_names

let workspace_mutating_tools_for_scope = function
  | Some Team_session_types.Observe_only ->
      List.filter (fun name -> not (String.equal name "file_write"))
        workspace_mutating_tools
  | _ -> workspace_mutating_tools

let is_workspace_mutating ~execution_scope name =
  List.mem name (workspace_mutating_tools_for_scope execution_scope)

let allowed_mutations_of_tool_names ~execution_scope tool_names =
  List.filter (is_workspace_mutating ~execution_scope) tool_names

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
    ~execution_scope
    ~(delivery_contract : Team_session_types.delivery_contract)
    ~(tool_names : string list) : Oas.Risk_contract.t =
  let risk_class =
    Contract_risk.of_delivery_contract ~execution_scope ~delivery_contract
      ~tool_names
  in
  {
    Oas.Risk_contract.runtime_constraints =
      {
        requested_execution_mode =
          requested_mode_of_repair_budget delivery_contract.repair_budget;
        risk_class;
        allowed_mutations =
          allowed_mutations_of_tool_names ~execution_scope tool_names;
        review_requirement = review_requirement_of_risk_class risk_class;
      };
    eval_criteria = build_delivery_eval_criteria delivery_contract;
  }

let infer_keeper_risk_class ~(scope_kind : string) : Oas.Risk_class.t =
  match String.lowercase_ascii scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Risk_class.Low
  | "workspace" | "local" -> Oas.Risk_class.Medium
  | "full" | "unrestricted" -> Oas.Risk_class.Medium
  | unknown ->
    Log.Misc.warn "infer_keeper_risk_class: unknown scope_kind %S, defaulting to Medium" unknown;
    Oas.Risk_class.Medium

let infer_keeper_execution_mode ~(scope_kind : string) : Oas.Execution_mode.t =
  match String.lowercase_ascii scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Execution_mode.Diagnose
  | "workspace" | "local" | "full" | "unrestricted" -> Oas.Execution_mode.Execute
  | unknown ->
    Log.Misc.warn "infer_keeper_execution_mode: unknown scope_kind %S, defaulting to Diagnose" unknown;
    Oas.Execution_mode.Diagnose

let infer_keeper_allowed_mutations ~(execution_scope : string) =
  match String.lowercase_ascii execution_scope with
  | "observe_only" ->
    (* observe_only keepers should not mutate — preserve CDAL enforcement. *)
    [ "workspace_only" ]
  | _ ->
    (* Standard keepers handle their own tool access control via
       keeper_hooks_oas.ml deny list and keeper_exec_tools.ml
       allowlist/denylist.  "workspace_only" here caused mode_enforcer
       to block keeper_*/masc_* tools misclassified as External_Effect. *)
    []

let build_keeper_eval_criteria ~keeper_name ~(goal : string) =
  `Assoc [ ("keeper_name", `String keeper_name); ("goal", `String goal) ]

let of_keeper
    ~(keeper_name : string)
    ~(goal : string)
    ~(scope_kind : string)
    ~(execution_scope : string) : Oas.Risk_contract.t =
  let exec_mode = infer_keeper_execution_mode ~scope_kind in
  let risk = infer_keeper_risk_class ~scope_kind in
  let mutations = infer_keeper_allowed_mutations ~execution_scope in
  if Keeper_types_profile.keeper_debug then
    Log.Keeper.debug
      "cdal contract for %s: mode=%s risk=%s mutations=[%s] scope_kind=%s exec_scope=%s"
      keeper_name
      (Oas.Execution_mode.to_string exec_mode)
      (Oas.Risk_class.to_string risk)
      (String.concat "," mutations)
      scope_kind execution_scope;
  {
    Oas.Risk_contract.runtime_constraints =
      {
        requested_execution_mode = exec_mode;
        risk_class = risk;
        allowed_mutations = mutations;
        review_requirement = None;
      };
    eval_criteria = build_keeper_eval_criteria ~keeper_name ~goal;
  }

let of_keeper_meta (meta : Keeper_types.keeper_meta) : Oas.Risk_contract.t =
  of_keeper ~keeper_name:meta.name ~goal:meta.short_goal
    ~scope_kind:meta.scope_kind ~execution_scope:meta.execution_scope
