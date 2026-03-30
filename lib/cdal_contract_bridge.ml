(** Cdal_contract_bridge — Canonical bridge from MASC domain objects
    (delivery_contract, keeper_meta) to OAS Risk_contract.t.

    Consolidates contract construction logic previously split between
    contract_composer.ml (delivery) and keeper_cdal_contract.ml (keeper).

    Design rule: all OAS identifiers are fully qualified via [Oas] alias.
    This module is the single truth surface for CDAL contract construction. *)

module Oas = Agent_sdk

(* -------------------------------------------------------------------
   Delivery-contract path (migrated from contract_composer.ml)
   ------------------------------------------------------------------- *)

let is_workspace_mutating name =
  List.mem name
    [ "keeper_fs_edit"; "keeper_edit"; "keeper_write";
      "create_text_file"; "edit_text_file" ]

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

let requested_mode_of_budget budget =
  if budget > 0 then Oas.Execution_mode.Execute
  else Oas.Execution_mode.Draft

let of_delivery_contract
    ~(delivery_contract : Team_session_types.delivery_contract)
    ~(tool_names : string list) : Oas.Risk_contract.t =
  let risk_class =
    Contract_risk.of_delivery_contract ~delivery_contract ~tool_names
  in
  let allowed_mutations =
    List.filter is_workspace_mutating tool_names
  in
  let review_requirement =
    match risk_class with
    | Oas.Risk_class.High | Critical -> Some "human_review"
    | _ -> None
  in
  let runtime_constraints : Oas.Risk_contract.runtime_constraints = {
    requested_execution_mode =
      requested_mode_of_budget delivery_contract.repair_budget;
    risk_class;
    allowed_mutations;
    review_requirement;
  } in
  let eval_criteria = build_eval_criteria delivery_contract in
  { runtime_constraints; eval_criteria }

(* -------------------------------------------------------------------
   Keeper-meta path (migrated from keeper_cdal_contract.ml)
   Uses current main logic: scope_kind-based classification.
   ------------------------------------------------------------------- *)

let infer_risk_class ~(scope_kind : string) : Oas.Risk_class.t =
  match String.lowercase_ascii scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Risk_class.Low
  | "workspace" | "local" -> Oas.Risk_class.Medium
  | "full" | "unrestricted" -> Oas.Risk_class.Medium
  | _ -> Oas.Risk_class.Medium

let infer_execution_mode ~(scope_kind : string) : Oas.Execution_mode.t =
  match String.lowercase_ascii scope_kind with
  | "read_only" | "readonly" | "observe" -> Oas.Execution_mode.Diagnose
  | "workspace" | "local" -> Oas.Execution_mode.Draft
  | _ -> Oas.Execution_mode.Execute

let infer_allowed_mutations ~(execution_scope : string)
    ~(allowed_paths : string list) : string list =
  match String.lowercase_ascii execution_scope with
  | "workspace" | "local" -> ["workspace_only"]
  | _ ->
    if allowed_paths <> [] then ["workspace_only"]
    else []

let of_keeper_meta (meta : Keeper_types.keeper_meta) : Oas.Risk_contract.t =
  let risk_class = infer_risk_class ~scope_kind:meta.scope_kind in
  let mode = infer_execution_mode ~scope_kind:meta.scope_kind in
  let effective_paths = Keeper_alerting_path.effective_allowed_paths ~meta in
  let allowed_mutations =
    infer_allowed_mutations
      ~execution_scope:meta.execution_scope
      ~allowed_paths:effective_paths
  in
  Oas.Risk_contract.{
    runtime_constraints = {
      requested_execution_mode = mode;
      risk_class;
      allowed_mutations;
      review_requirement = None;
    };
    eval_criteria = `Assoc [
      ("keeper_name", `String meta.name);
      ("goal", `String meta.short_goal);
    ];
  }
