(** Contract_composer — Translate MASC delivery_contract to OAS Risk_contract.t.

    Follows the boundary principle: MASC owns session semantics,
    OAS owns per-run enforcement.  This module bridges the gap. *)

(** Classify a tool as workspace-mutating (not external-effect).
    Used to populate allowed_mutations. *)
let is_workspace_mutating name =
  List.mem name
    [ "keeper_fs_edit"; "keeper_edit"; "keeper_write";
      "create_text_file"; "edit_text_file" ]

(** Build the eval_criteria JSON payload from delivery_contract fields.
    eval_criteria is opaque to OAS — consumed by downstream evaluators. *)
let build_eval_criteria (dc : Team_session_types.delivery_contract) :
    Yojson.Safe.t =
  `Assoc [
    ("success_criteria",
     `List (List.map (fun s -> `String s) dc.acceptance_checks));
    ("required_evidence",
     `List (List.map (fun s -> `String s) dc.required_artifacts));
    ("contract_id", `String dc.contract_id);
    ("evaluator_cascade", `String dc.evaluator_cascade);
  ]

(** Determine requested execution mode from repair_budget.
    - budget > 0: agent can mutate (Execute)
    - budget = 0: read-only analysis preferred (Draft)
    The mode may be further downgraded by OAS Mode_resolver
    based on risk_class and tool capabilities. *)
let requested_mode_of_budget budget =
  if budget > 0 then Agent_sdk.Execution_mode.Execute
  else Draft

let compose ~(delivery_contract : Team_session_types.delivery_contract)
    ~(tool_names : string list) : Agent_sdk.Risk_contract.t =
  let risk_class =
    Contract_risk.of_delivery_contract ~delivery_contract ~tool_names
  in
  let allowed_mutations =
    List.filter is_workspace_mutating tool_names
  in
  let review_requirement =
    match risk_class with
    | Agent_sdk.Risk_class.High | Critical -> Some "human_review"
    | _ -> None
  in
  let runtime_constraints : Agent_sdk.Risk_contract.runtime_constraints = {
    requested_execution_mode =
      requested_mode_of_budget delivery_contract.repair_budget;
    risk_class;
    allowed_mutations;
    review_requirement;
  } in
  let eval_criteria = build_eval_criteria delivery_contract in
  { runtime_constraints; eval_criteria }
