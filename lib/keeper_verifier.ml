(** Keeper Verifier — Generator-Verifier loop for autonomous keeper actions.

    After the keeper generates an action plan via keeper_autonomy,
    a cheap verification model confirms the plan before execution.
    This implements Karpathy's Generator-Verifier pattern:
    "generate with capable model, verify with cheap model."

    Verdict outcomes:
    - PASS → proceed with execution
    - WARN → execute but log concern to trajectory
    - FAIL → skip action, notify via broadcast

    Budget: max 200 output tokens per verification (~0.01 cents).

    @since 2.74.0 *)

open Printf

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type keeper_verification_request = {
  keeper_name : string;
  proposed_action : Keeper_autonomy.proposed_action;
  action_plan : string;  (** LLM-generated plan text *)
  keeper_context : string;
}

type keeper_verdict =
  | Proceed
  | ProceedWithCaution of string
  | Block of string

(* ================================================================ *)
(* Verdict Conversion                                               *)
(* ================================================================ *)

let keeper_verdict_to_string = function
  | Proceed -> "PROCEED"
  | ProceedWithCaution reason -> sprintf "CAUTION: %s" reason
  | Block reason -> sprintf "BLOCKED: %s" reason

let keeper_verdict_to_json = function
  | Proceed ->
      `Assoc [("verdict", `String "proceed")]
  | ProceedWithCaution reason ->
      `Assoc [("verdict", `String "caution"); ("reason", `String reason)]
  | Block reason ->
      `Assoc [("verdict", `String "block"); ("reason", `String reason)]

(** Map the underlying verifier verdict to keeper-specific verdict. *)
let of_verifier_verdict = function
  | Verifier_oas.Pass -> Proceed
  | Verifier_oas.Warn reason -> ProceedWithCaution reason
  | Verifier_oas.Fail reason -> Block reason

(* ================================================================ *)
(* Cost Guard                                                       *)
(* ================================================================ *)

(** Maximum estimated cost (USD) for auto-execution without extra review. *)
let max_auto_cost_usd = 0.10

(** Block actions that exceed cost threshold at lower autonomy levels. *)
let cost_guard ~(autonomy_level : Keeper_autonomy.autonomy_level)
    (pa : Keeper_autonomy.proposed_action) =
  match autonomy_level with
  | L5_Independent -> None  (* no cost guard at max autonomy *)
  | _ ->
      if pa.estimated_cost_usd > max_auto_cost_usd then
        Some (sprintf "estimated cost $%.2f exceeds $%.2f threshold"
                pa.estimated_cost_usd max_auto_cost_usd)
      else
        None

(* ================================================================ *)
(* Risk Guard                                                       *)
(* ================================================================ *)

(** Block dangerous actions unless autonomy is L4+ *)
let risk_guard ~(autonomy_level : Keeper_autonomy.autonomy_level)
    (pa : Keeper_autonomy.proposed_action) =
  match pa.risk_level, autonomy_level with
  | `Dangerous, (L1_Reactive | L2_Suggestive | L3_Guided) ->
      Some "dangerous action requires L4+ autonomy"
  | `Moderate, (L1_Reactive | L2_Suggestive) ->
      Some "moderate-risk action requires L3+ autonomy"
  | _ -> None

(* ================================================================ *)
(* Core: verify_action                                              *)
(* ================================================================ *)

(** Verify a proposed keeper action through multi-layer checks.

    Layer 1: Cost guard (fast, no LLM)
    Layer 2: Risk guard (fast, no LLM)
    Layer 3: LLM verification via verifier.ml (cheap model, 200 tokens) *)
let verify_action
    ~(model : Llm.model_spec)
    ~(autonomy_level : Keeper_autonomy.autonomy_level)
    (req : keeper_verification_request) : keeper_verdict =
  (* Layer 1: Cost guard *)
  match cost_guard ~autonomy_level req.proposed_action with
  | Some reason -> Block reason
  | None ->
  (* Layer 2: Risk guard *)
  match risk_guard ~autonomy_level req.proposed_action with
  | Some reason -> Block reason
  | None ->
  (* Layer 3: LLM verification *)
  let verifier_req : Verifier_oas.verification_request = {
    action_description = req.proposed_action.action_description;
    action_result = req.action_plan;
    goal = sprintf "%s (goal_id=%s)"
             req.proposed_action.goal_title
             req.proposed_action.goal_id;
    context_summary =
      if String.length req.keeper_context > 300 then
        String.sub req.keeper_context 0 300 ^ "..."
      else
        req.keeper_context;
  } in
  let verdict = Verifier_oas.verify ~model verifier_req in
  of_verifier_verdict verdict

(* ================================================================ *)
(* Full Pipeline: evaluate → verify → decide                        *)
(* ================================================================ *)

type pipeline_result =
  | NothingToDo of string  (** reason *)
  | Approved of Keeper_autonomy.proposed_action * string  (** action + plan *)
  | Cautioned of Keeper_autonomy.proposed_action * string * string  (** action + plan + warning *)
  | Rejected of Keeper_autonomy.proposed_action * string  (** action + reason *)
  | PerpetualRequested of Keeper_autonomy.perpetual_agent_request

let pipeline_result_to_json = function
  | NothingToDo reason ->
      `Assoc [("result", `String "nothing_to_do"); ("reason", `String reason)]
  | Approved (pa, plan) ->
      `Assoc [
        ("result", `String "approved");
        ("action", Keeper_autonomy.proposed_action_to_json pa);
        ("plan", `String plan);
      ]
  | Cautioned (pa, plan, warning) ->
      `Assoc [
        ("result", `String "cautioned");
        ("action", Keeper_autonomy.proposed_action_to_json pa);
        ("plan", `String plan);
        ("warning", `String warning);
      ]
  | Rejected (pa, reason) ->
      `Assoc [
        ("result", `String "rejected");
        ("action", Keeper_autonomy.proposed_action_to_json pa);
        ("reason", `String reason);
      ]
  | PerpetualRequested req ->
      `Assoc [
        ("result", `String "perpetual_requested");
        ("request", Keeper_autonomy.perpetual_agent_request_to_json req);
      ]

(** Full pipeline: evaluate next action → generate plan → verify → decide.

    Returns the final decision for the keeper's proactive turn. *)
let run_pipeline
    ~(config : Room.config)
    ~(goal_ids : string list)
    ~(keeper_name : string)
    ~(keeper_context : string)
    ~(plan_model : Llm.model_spec)
    ~(verify_model : Llm.model_spec)
    ~(autonomy_level : Keeper_autonomy.autonomy_level)
    : pipeline_result =
  (* Step 1: Evaluate next action *)
  match Keeper_autonomy.evaluate_next_action ~config ~goal_ids ~keeper_name with
  | NoGoals -> NothingToDo "no active goals"
  | NoActionNeeded -> NothingToDo "no action needed for current goals"
  | Skip reason -> NothingToDo reason
  | StartPerpetualAgent req -> PerpetualRequested req
  | Propose pa ->
      (* Step 2: Check if autonomy level allows auto-execution *)
      if not (Keeper_autonomy.should_auto_execute ~autonomy_level pa) then
        NothingToDo (sprintf "autonomy level %s does not allow auto-execution for this risk"
                       (Keeper_autonomy.autonomy_level_to_string autonomy_level))
      else
        (* Step 3: Generate action plan *)
        match Keeper_autonomy.generate_action_plan
                ~model:plan_model ~goal:{ id = pa.goal_id; horizon = "short";
                  title = pa.goal_title; metric = None; target_value = None;
                  due_date = None; priority = 3; status = "active";
                  parent_goal_id = None; last_review_note = None;
                  last_review_at = None; created_at = ""; updated_at = "" }
                ~keeper_context with
        | Error e ->
            Rejected (pa, sprintf "plan generation failed: %s" e)
        | Ok plan ->
            (* Step 4: Verify the plan *)
            let req = {
              keeper_name;
              proposed_action = pa;
              action_plan = plan;
              keeper_context;
            } in
            match verify_action ~model:verify_model ~autonomy_level req with
            | Proceed -> Approved (pa, plan)
            | ProceedWithCaution warning -> Cautioned (pa, plan, warning)
            | Block reason -> Rejected (pa, reason)
