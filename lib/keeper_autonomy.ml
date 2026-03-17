(** Keeper Autonomy — Karpathy Autonomy Slider for Keeper agents.

    5 levels of autonomy control how independently a keeper pursues goals.
    Connects goal_store for objective tracking and eval_gate for safety.

    Key insight (Karpathy): Harness > Model.
    The quality of the harness (trajectory, gates, verification)
    determines reliability more than the model itself.

    @since 2.74.0 *)

open Printf

(* ================================================================ *)
(* Autonomy Level                                                    *)
(* ================================================================ *)

type autonomy_level =
  | L1_Reactive
  | L2_Suggestive
  | L3_Guided
  | L4_Autonomous
  | L5_Independent

let autonomy_level_to_string = function
  | L1_Reactive -> "L1_Reactive"
  | L2_Suggestive -> "L2_Suggestive"
  | L3_Guided -> "L3_Guided"
  | L4_Autonomous -> "L4_Autonomous"
  | L5_Independent -> "L5_Independent"

let autonomy_level_of_string s =
  match String.lowercase_ascii (String.trim s) with
  | "l1_reactive" | "l1" | "reactive" -> Some L1_Reactive
  | "l2_suggestive" | "l2" | "suggestive" -> Some L2_Suggestive
  | "l3_guided" | "l3" | "guided" -> Some L3_Guided
  | "l4_autonomous" | "l4" | "autonomous" -> Some L4_Autonomous
  | "l5_independent" | "l5" | "independent" -> Some L5_Independent
  | _ -> None

let autonomy_level_to_int = function
  | L1_Reactive -> 1
  | L2_Suggestive -> 2
  | L3_Guided -> 3
  | L4_Autonomous -> 4
  | L5_Independent -> 5

(* ================================================================ *)
(* Proposed Action                                                   *)
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

let perpetual_agent_request_to_json (req : perpetual_agent_request) : Yojson.Safe.t =
  `Assoc [
    ("goal_id", `String req.goal_id);
    ("goal_title", `String req.goal_title);
    ("models", `List (List.map (fun m -> `String m) req.models));
    ("coding_mode", `Bool req.coding_mode);
    ("coding_agent", `String req.coding_agent);
  ]

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
(* Goal Evaluation                                                   *)
(* ================================================================ *)

(** Select the highest-priority active goal from a list of goal IDs. *)
let select_top_goal config goal_ids =
  let goals =
    List.filter_map (fun gid ->
      let all = Goal_store.list_goals config () in
      List.find_opt (fun (g : Goal_store.goal) -> g.id = gid && g.status = "active") all
    ) goal_ids
  in
  (* Sort by priority (lower = higher priority), then by horizon urgency *)
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

(** Estimate risk level from goal horizon and priority. *)
let estimate_risk (goal : Goal_store.goal) : [`Safe | `Moderate | `Dangerous] =
  match goal.horizon, goal.priority with
  | "short", p when p <= 2 -> `Safe
  | "short", _ -> `Moderate
  | "mid", p when p <= 2 -> `Moderate
  | "long", _ -> `Dangerous
  | _ -> `Moderate

(** Estimate cost based on goal complexity heuristic. *)
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
            models = Llm_client.default_execution_model_labels ();
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

(* ================================================================ *)
(* Auto-Execution Decision                                           *)
(* ================================================================ *)

let should_auto_execute ~autonomy_level (pa : proposed_action) =
  match autonomy_level with
  | L1_Reactive -> false
  | L2_Suggestive -> false
  | L3_Guided ->
      (match pa.risk_level with
       | `Safe -> true
       | `Moderate -> false
       | `Dangerous -> false)
  | L4_Autonomous ->
      (match pa.risk_level with
       | `Safe -> true
       | `Moderate -> true
       | `Dangerous -> false)
  | L5_Independent -> true

(* ================================================================ *)
(* LLM Action Plan Generation                                       *)
(* ================================================================ *)

let build_plan_prompt (goal : Goal_store.goal) ~keeper_context =
  sprintf
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
    goal.title
    goal.horizon
    goal.priority
    (Option.value ~default:"none" goal.metric)
    (Option.value ~default:"none" goal.target_value)
    (Option.value ~default:"none" goal.due_date)
    (if String.length keeper_context > 500
     then String.sub keeper_context 0 500 ^ "..."
     else keeper_context)

let generate_action_plan ~model ~goal ~keeper_context =
  let prompt = build_plan_prompt goal ~keeper_context in
  let req : Llm_client.completion_request = {
    model;
    messages = [Llm_client.user_msg prompt];
    temperature = 0.3;
    max_tokens = 500;
    tools = [];
    response_format = `Text;
  } in
  match Llm_client.complete req with
  | Ok resp -> Ok (Llm_client.text_of_response resp)
  | Error e -> Error (sprintf "plan generation failed: %s" e)
