(** Contract_risk — Derive OAS execution risk_class from MASC delivery_contract.

    Three-axis model: blast_radius x irreversibility x recovery_cost.
    Maps delivery_contract fields + tool set into the OAS 4-level taxonomy. *)

type blast_radius = Small | Medium | Large
type irreversibility = Reversible | Partial | Irreversible
type recovery_cost = Rc_low | Rc_medium | Rc_high

type risk_axes = {
  blast_radius : blast_radius;
  irreversibility : irreversibility;
  recovery_cost : recovery_cost;
}

(* Tools that can cause external side effects. Aligned with
   Mode_enforcer.classify_tool External_effect in OAS. *)
let external_effect_tools =
  [ "keeper_bash"; "keeper_github"; "masc_broadcast";
    "masc_spawn"; "masc_execute"; "shell_exec" ]

(* Tools that mutate workspace but have no external effect. *)
let workspace_mutating_tools =
  [ "keeper_fs_edit"; "keeper_edit"; "keeper_write";
    "create_text_file"; "edit_text_file"; "file_write" ]

let has_any tools patterns =
  List.exists (fun t -> List.mem t patterns) tools

let external_effect_tools_for_scope = function
  | Some Team_session_types.Observe_only ->
      (* observe_only shell_exec is routed through the readonly allowlist,
         so it should not be treated like unrestricted bash here. *)
      List.filter (fun name -> not (String.equal name "shell_exec"))
        external_effect_tools
  | _ -> external_effect_tools

let workspace_mutating_tools_for_scope = function
  | Some Team_session_types.Observe_only ->
      (* observe_only file_write is denied before dispatch, so it should not
         inflate contract risk when callers preserve the original tool list. *)
      List.filter (fun name -> not (String.equal name "file_write"))
        workspace_mutating_tools
  | _ -> workspace_mutating_tools

(** Blast radius: how many things could break.
    - Large: external-effect tools or 5+ required artifacts
    - Medium: workspace-mutating tools or 2-4 artifacts
    - Small: read-only tools and 0-1 artifacts *)
let assess_blast_radius ~(dc : Team_session_types.delivery_contract)
    ~execution_scope ~tool_names =
  let artifact_count = List.length dc.required_artifacts in
  if has_any tool_names (external_effect_tools_for_scope execution_scope)
     || artifact_count >= 5
  then
    Large
  else if has_any tool_names (workspace_mutating_tools_for_scope execution_scope)
            || artifact_count >= 2
  then
    Medium
  else Small

(** Irreversibility: how hard to undo.
    - Irreversible: external-effect tools (git push, bash commands)
    - Partial: workspace-mutating tools (files can be reverted)
    - Reversible: read-only tools *)
let assess_irreversibility ~execution_scope ~tool_names =
  if has_any tool_names (external_effect_tools_for_scope execution_scope) then
    Irreversible
  else if has_any tool_names (workspace_mutating_tools_for_scope execution_scope)
  then
    Partial
  else Reversible

(** Recovery cost: effort to fix if things go wrong.
    Derived from repair_budget:
    - 0 budget = no margin for error = high cost
    - 1-2 budget = some room = medium
    - 3+ budget = generous margin = low *)
let assess_recovery_cost ~(dc : Team_session_types.delivery_contract) =
  if dc.repair_budget <= 0 then Rc_high
  else if dc.repair_budget <= 2 then Rc_medium
  else Rc_low

let assess ~execution_scope ~(delivery_contract : Team_session_types.delivery_contract)
    ~(tool_names : string list) =
  { blast_radius =
      assess_blast_radius ~dc:delivery_contract ~execution_scope ~tool_names;
    irreversibility = assess_irreversibility ~execution_scope ~tool_names;
    recovery_cost = assess_recovery_cost ~dc:delivery_contract;
  }

(** Map axes to OAS Risk_class.t.

    Scoring: each axis at maximum level = 1 point.
    - 0 maximum axes → Low
    - 1 mid-level axis → Medium
    - 1 maximum axis → High
    - 2+ maximum axes → Critical *)
let to_risk_class axes =
  let max_count =
    (if axes.blast_radius = Large then 1 else 0)
    + (if axes.irreversibility = Irreversible then 1 else 0)
    + (if axes.recovery_cost = Rc_high then 1 else 0)
  in
  let mid_count =
    (if axes.blast_radius = Medium then 1 else 0)
    + (if axes.irreversibility = Partial then 1 else 0)
    + (if axes.recovery_cost = Rc_medium then 1 else 0)
  in
  if max_count >= 2 then Agent_sdk.Risk_class.Critical
  else if max_count >= 1 then High
  else if mid_count >= 1 then Medium
  else Low

let of_delivery_contract ~execution_scope ~delivery_contract ~tool_names =
  to_risk_class (assess ~execution_scope ~delivery_contract ~tool_names)
