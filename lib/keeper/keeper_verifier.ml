(** Keeper Verifier — Generator-Verifier loop for autonomous keeper actions.

    Contains shared goal evaluation types (formerly in keeper_autonomy.ml)
    and the verification pipeline.

    Verdict outcomes:
    - PASS -> proceed with execution
    - WARN -> execute but log concern to trajectory
    - FAIL -> skip action, notify via broadcast

    Budget: max 200 output tokens per verification (~0.01 cents).

    autonomy_level dispatch removed; uses flat cost/risk guards. *)

open Printf

(* ================================================================ *)
(* Goal evaluation types (moved from keeper_autonomy.ml)            *)
(* ================================================================ *)

type proposed_action = {
  goal_id : string;
  goal_title : string;
  action_description : string;
  risk_level : [`Safe | `Moderate | `Dangerous];
  estimated_cost_usd : float;
}

type perpetual_agent_request = {
  goal_id : string;
  goal_title : string;
  models : string list;
  coding_mode : bool;
  coding_agent : string;
}

type next_action =
  | NoGoals
  | NoActionNeeded
  | Propose of proposed_action
  | Skip of string
  | StartPerpetualAgent of perpetual_agent_request

let risk_level_to_string = function
  | `Safe -> "safe"
  | `Moderate -> "moderate"
  | `Dangerous -> "dangerous"

let proposed_action_to_json (pa : proposed_action) : Yojson.Safe.t =
  `Assoc [
    ("goal_id", `String pa.goal_id);
    ("goal_title", `String pa.goal_title);
    ("action_description", `String pa.action_description);
    ("risk_level", `String (risk_level_to_string pa.risk_level));
    ("estimated_cost_usd", `Float pa.estimated_cost_usd);
  ]

let perpetual_agent_request_to_json (req : perpetual_agent_request) : Yojson.Safe.t =
  `Assoc [
    ("goal_id", `String req.goal_id);
    ("goal_title", `String req.goal_title);
    ("models", `List (List.map (fun m -> `String m) req.models));
    ("coding_mode", `Bool req.coding_mode);
    ("coding_agent", `String req.coding_agent);
  ]

let next_action_to_json = function
  | NoGoals -> `Assoc [("action", `String "no_goals")]
  | NoActionNeeded -> `Assoc [("action", `String "no_action_needed")]
  | Propose pa ->
      `Assoc [
        ("action", `String "propose");
        ("proposal", proposed_action_to_json pa);
      ]
  | Skip reason ->
      `Assoc [
        ("action", `String "skip");
        ("reason", `String reason);
      ]
  | StartPerpetualAgent req ->
      `Assoc [
        ("action", `String "start_perpetual_agent");
        ("request", perpetual_agent_request_to_json req);
      ]

(* ================================================================ *)
(* Goal evaluation (moved from keeper_autonomy.ml)                  *)
(* ================================================================ *)

let select_top_goal config goal_ids =
  let goals =
    List.filter_map (fun gid ->
      let all = Goal_store.list_goals config () in
      List.find_opt (fun (g : Goal_store.goal) -> g.id = gid && g.status = "active") all
    ) goal_ids
  in
  let sorted = List.sort (fun (a : Goal_store.goal) (b : Goal_store.goal) ->
    let by_prio = compare a.priority b.priority in
    if by_prio <> 0 then by_prio
    else
      let horizon_rank = function
        | "short" -> 0 | "mid" -> 1 | "long" -> 2 | _ -> 3
      in
      compare (horizon_rank a.horizon) (horizon_rank b.horizon)
  ) goals in
  match sorted with
  | [] -> None
  | top :: _ -> Some top

let estimate_risk (goal : Goal_store.goal) : [`Safe | `Moderate | `Dangerous] =
  match goal.horizon, goal.priority with
  | "short", p when p <= 2 -> `Safe
  | "short", _ -> `Moderate
  | "mid", p when p <= 2 -> `Moderate
  | "long", _ -> `Dangerous
  | _ -> `Moderate

let estimate_cost (goal : Goal_store.goal) : float =
  match goal.horizon with
  | "short" -> 0.01
  | "mid" -> 0.05
  | "long" -> 0.10
  | _ -> 0.05

let evaluate_next_action ~config ~goal_ids ~keeper_name:_ =
  if goal_ids = [] then NoGoals
  else
    match select_top_goal config goal_ids with
    | None -> NoActionNeeded
    | Some goal ->
        if goal.horizon = "long" then
          StartPerpetualAgent {
            goal_id = goal.id;
            goal_title = goal.title;
            models = Provider_adapter.preferred_execution_model_labels ();
            coding_mode = true;
            coding_agent = "claude";
          }
        else
          let risk = estimate_risk goal in
          let cost = estimate_cost goal in
          Propose {
            goal_id = goal.id;
            goal_title = goal.title;
            action_description =
              sprintf "Work toward: %s (horizon=%s, priority=%d)"
                goal.title goal.horizon goal.priority;
            risk_level = risk;
            estimated_cost_usd = cost;
          }

let generate_action_plan ~goal ~keeper_context =
  let prompt = sprintf
{|You are a planning agent. Generate a concrete action plan for this goal.

Goal: %s
Horizon: %s
Priority: %d
Metric: %s
Target: %s
Due date: %s

Keeper context:
%s

Respond with a numbered list of 1-5 concrete steps.
Each step should be a specific, actionable command or tool call.
Keep it concise — max 3 sentences per step.|}
    goal.Goal_store.title
    goal.horizon
    goal.priority
    (Option.value ~default:"none" goal.metric)
    (Option.value ~default:"none" goal.target_value)
    (Option.value ~default:"none" goal.due_date)
    (if String.length keeper_context > 500
     then String.sub keeper_context 0 500 ^ "..."
     else keeper_context)
  in
  match
    Oas_worker.run_named ~cascade_name:"keeper_autonomy"
      ~goal:prompt
      ~max_turns:1 ~temperature:0.3 ~max_tokens:500 ()
  with
  | Ok result ->
    Ok (Agent_sdk.Types.text_of_content result.Oas_worker.response.content)
  | Error e -> Error (sprintf "plan generation failed: %s" e)

(* ================================================================ *)
(* Verification types                                               *)
(* ================================================================ *)

type keeper_verification_request = {
  keeper_name : string;
  proposed_action : proposed_action;
  action_plan : string;  (** MODEL-generated plan text *)
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

let max_auto_cost_usd = 0.10

let cost_guard (pa : proposed_action) =
  if pa.estimated_cost_usd > max_auto_cost_usd then
    Some (sprintf "estimated cost $%.2f exceeds $%.2f threshold"
            pa.estimated_cost_usd max_auto_cost_usd)
  else
    None

(* ================================================================ *)
(* Risk Guard                                                       *)
(* ================================================================ *)

let risk_guard (pa : proposed_action) =
  match pa.risk_level with
  | `Dangerous ->
      Some "dangerous action blocked by default risk guard"
  | _ -> None

(* ================================================================ *)
(* Core: verify_action                                              *)
(* ================================================================ *)

let verify_action
    (req : keeper_verification_request) : keeper_verdict =
  match cost_guard req.proposed_action with
  | Some reason -> Block reason
  | None ->
  match risk_guard req.proposed_action with
  | Some reason -> Block reason
  | None ->
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
  let verdict = Verifier_oas.verify verifier_req in
  of_verifier_verdict verdict

(* ================================================================ *)
(* Full Pipeline: evaluate -> verify -> decide                      *)
(* ================================================================ *)

type pipeline_result =
  | NothingToDo of string
  | Approved of proposed_action * string
  | Cautioned of proposed_action * string * string
  | Rejected of proposed_action * string
  | PerpetualRequested of perpetual_agent_request

let pipeline_result_to_json = function
  | NothingToDo reason ->
      `Assoc [("result", `String "nothing_to_do"); ("reason", `String reason)]
  | Approved (pa, plan) ->
      `Assoc [
        ("result", `String "approved");
        ("action", proposed_action_to_json pa);
        ("plan", `String plan);
      ]
  | Cautioned (pa, plan, warning) ->
      `Assoc [
        ("result", `String "cautioned");
        ("action", proposed_action_to_json pa);
        ("plan", `String plan);
        ("warning", `String warning);
      ]
  | Rejected (pa, reason) ->
      `Assoc [
        ("result", `String "rejected");
        ("action", proposed_action_to_json pa);
        ("reason", `String reason);
      ]
  | PerpetualRequested req ->
      `Assoc [
        ("result", `String "perpetual_requested");
        ("request", perpetual_agent_request_to_json req);
      ]

let run_pipeline
    ~(config : Room.config)
    ~(goal_ids : string list)
    ~(keeper_name : string)
    ~(keeper_context : string)
    : pipeline_result =
  match evaluate_next_action ~config ~goal_ids ~keeper_name with
  | NoGoals -> NothingToDo "no active goals"
  | NoActionNeeded -> NothingToDo "no action needed for current goals"
  | Skip reason -> NothingToDo reason
  | StartPerpetualAgent req -> PerpetualRequested req
  | Propose pa ->
      (match generate_action_plan
              ~goal:{ id = pa.goal_id; horizon = "short";
                title = pa.goal_title; metric = None; target_value = None;
                due_date = None; priority = 3; status = "active";
                parent_goal_id = None; last_review_note = None;
                last_review_at = None; created_at = ""; updated_at = "" }
              ~keeper_context with
      | Error e ->
          Rejected (pa, sprintf "plan generation failed: %s" e)
      | Ok plan ->
          let req = {
            keeper_name;
            proposed_action = pa;
            action_plan = plan;
            keeper_context;
          } in
          match verify_action req with
          | Proceed -> Approved (pa, plan)
          | ProceedWithCaution warning -> Cautioned (pa, plan, warning)
          | Block reason -> Rejected (pa, reason))
