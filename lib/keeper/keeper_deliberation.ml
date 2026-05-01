(** Keeper_deliberation — typed action space, deliberation triggers,
    world observation builder, triage logic, and MODEL-driven deliberation
    for the keeper deliberation engine.

    Phase 1: Pure heuristic triage (no MODEL calls).
    Phase 2: MODEL-driven deliberation (L1 Reactive) — when triage detects
    triggers, call an MODEL to decide what action to take.

    @since 2.90.0 *)

(* ---------- Deliberation trigger: why the keeper might act ---------- *)

type deliberation_trigger =
  | DirectMention
  | NewUnclaimedTask
  | FailedTask
  | AgentJoinedOrLeft
  | GoalDeadline
  | BoardActivity of string
  | IdleTimeout
  | MetricsAnomaly of string
  | StrategicReview
  | SelfDirectedExplore

let deliberation_trigger_to_string = function
  | DirectMention -> "direct_mention"
  | NewUnclaimedTask -> "new_unclaimed_task"
  | FailedTask -> "failed_task"
  | AgentJoinedOrLeft -> "agent_joined_or_left"
  | GoalDeadline -> "goal_deadline"
  | BoardActivity detail -> "board_activity:" ^ detail
  | IdleTimeout -> "idle_timeout"
  | MetricsAnomaly detail -> "metrics_anomaly:" ^ detail
  | StrategicReview -> "strategic_review"
  | SelfDirectedExplore -> "self_directed_explore"

let deliberation_trigger_to_json trigger =
  `String (deliberation_trigger_to_string trigger)

(* ---------- Deliberation action: what the keeper can do ---------- *)

type deliberation_action =
  | Noop of string
  | ReplyInRoom of { room_id: string; content: string }
  | BoardPost of { content: string; hearth: string option }
  | BoardComment of { post_id: string; content: string }
  | BoardVote of { post_id: string; direction: string }
  | TaskClaim of { task_id: string; reason: string }
  | Broadcast of { message: string }
  | ProposeSpawn of { topic: string; reason: string }
  | StartDiscussion of { topic: string; context: string }
  | ShareFinding of { finding: string; source: string }
  | MultiStep of deliberation_action list

let rec deliberation_action_to_string = function
  | Noop reason -> "noop:" ^ reason
  | ReplyInRoom _ -> "reply_in_room"
  | BoardPost _ -> "board_post"
  | BoardComment _ -> "board_comment"
  | BoardVote _ -> "board_vote"
  | TaskClaim _ -> "task_claim"
  | Broadcast _ -> "broadcast"
  | ProposeSpawn _ -> "propose_spawn"
  | StartDiscussion { topic; _ } -> "start_discussion:" ^ topic
  | ShareFinding { finding; _ } -> "share_finding:" ^ finding
  | MultiStep actions ->
      "multi_step:["
      ^ String.concat "," (List.map deliberation_action_to_string actions)
      ^ "]"

(** Map typed action to stable policy labels used by policy logging and reward models. *)
let deliberation_action_to_policy_label = function
  | Noop _ -> "noop"
  | ReplyInRoom _ -> "reply_in_room"
  | BoardPost _ -> "board_post"
  | BoardComment _ -> "board_comment"
  | BoardVote _ -> "board_vote"
  | TaskClaim _ -> "task_claim"
  | Broadcast _ -> "broadcast"
  | ProposeSpawn _ -> "propose_spawn"
  | StartDiscussion _ -> "start_discussion"
  | ShareFinding _ -> "share_finding"
  | MultiStep _ -> "multi_step"

let rec deliberation_action_to_json = function
  | Noop reason ->
      `Assoc [ ("type", `String "noop"); ("reason", `String reason) ]
  | ReplyInRoom { room_id; content } ->
      `Assoc
        [
          ("type", `String "reply_in_room");
          ("room_id", `String room_id);
          ("content", `String content);
        ]
  | BoardPost { content; hearth } ->
      `Assoc
        [
          ("type", `String "board_post");
          ("content", `String content);
          ( "hearth",
            match hearth with
            | Some h -> `String h
            | None -> `Null );
        ]
  | BoardComment { post_id; content } ->
      `Assoc
        [
          ("type", `String "board_comment");
          ("post_id", `String post_id);
          ("content", `String content);
        ]
  | BoardVote { post_id; direction } ->
      `Assoc
        [
          ("type", `String "board_vote");
          ("post_id", `String post_id);
          ("direction", `String direction);
        ]
  | TaskClaim { task_id; reason } ->
      `Assoc
        [
          ("type", `String "task_claim");
          ("task_id", `String task_id);
          ("reason", `String reason);
        ]
  | Broadcast { message } ->
      `Assoc [ ("type", `String "broadcast"); ("message", `String message) ]
  | ProposeSpawn { topic; reason } ->
      `Assoc
        [
          ("type", `String "propose_spawn");
          ("topic", `String topic);
          ("reason", `String reason);
        ]
  | StartDiscussion { topic; context } ->
      `Assoc
        [
          ("type", `String "start_discussion");
          ("topic", `String topic);
          ("context", `String context);
        ]
  | ShareFinding { finding; source } ->
      `Assoc
        [
          ("type", `String "share_finding");
          ("finding", `String finding);
          ("source", `String source);
        ]
  | MultiStep actions ->
      `Assoc
        [
          ("type", `String "multi_step");
          ("steps", `List (List.map deliberation_action_to_json actions));
        ]

(* ---------- World observation: enriched snapshot for triage ---------- *)

type world_observation = {
  keeper_name: string;
  direct_mention: bool;
  has_question: bool;
  message_content: string;
  unclaimed_task_count: int;
  failed_task_count: int;
  active_agent_count: int;
  agent_count_changed: bool;
  active_goal_count: int;
  idle_seconds: int;
  idle_gate: int;
  board_new_post_count: int;
  board_mention_count: int;
}

let empty_world_observation ~keeper_name =
  {
    keeper_name;
    direct_mention = false;
    has_question = false;
    message_content = "";
    unclaimed_task_count = 0;
    failed_task_count = 0;
    active_agent_count = 0;
    agent_count_changed = false;
    active_goal_count = 0;
    idle_seconds = 0;
    idle_gate = 300;
    board_new_post_count = 0;
    board_mention_count = 0;
  }

let world_observation_to_json (obs : world_observation) : Yojson.Safe.t =
  `Assoc
    [
      ("keeper_name", `String obs.keeper_name);
      ("direct_mention", `Bool obs.direct_mention);
      ("has_question", `Bool obs.has_question);
      ("message_content_len", `Int (String.length obs.message_content));
      ("unclaimed_task_count", `Int obs.unclaimed_task_count);
      ("failed_task_count", `Int obs.failed_task_count);
      ("active_agent_count", `Int obs.active_agent_count);
      ("agent_count_changed", `Bool obs.agent_count_changed);
      ("active_goal_count", `Int obs.active_goal_count);
      ("idle_seconds", `Int obs.idle_seconds);
      ("idle_gate", `Int obs.idle_gate);
      ("board_new_post_count", `Int obs.board_new_post_count);
      ("board_mention_count", `Int obs.board_mention_count);
    ]

(* ---------- Triage result ---------- *)

type triage_result =
  | Skip of string
  | Triggered of deliberation_trigger list

let triage_result_to_json = function
  | Skip reason ->
      `Assoc [ ("decision", `String "skip"); ("reason", `String reason) ]
  | Triggered triggers ->
      `Assoc
        [
          ("decision", `String "triggered");
          ( "triggers",
            `List (List.map deliberation_trigger_to_json triggers) );
        ]

(* ---------- Triage function: cheap gate before deliberation ---------- *)

(** Evaluate a world observation and return triggers that warrant action.
    Returns [Skip _] when nothing interesting happened,
    [Triggered triggers] when the keeper should evaluate further. *)
let triage (obs : world_observation) : triage_result =
  let triggers = ref [] in
  let add t = triggers := t :: !triggers in

  (* L1 Reactive triggers *)
  if obs.direct_mention then add DirectMention;
  if obs.unclaimed_task_count > 0 then add NewUnclaimedTask;
  if obs.failed_task_count > 0 then add FailedTask;
  if obs.agent_count_changed then add AgentJoinedOrLeft;

  (* L2 Proactive triggers — goal-directed *)
  if obs.board_mention_count > 0 then
    add (BoardActivity "mentioned_in_post");
  if obs.idle_seconds > obs.idle_gate && obs.active_goal_count > 0 then
    add IdleTimeout;
  if obs.active_goal_count > 0
     && obs.idle_seconds > obs.idle_gate * 2 then
    add GoalDeadline;
  if obs.idle_seconds > obs.idle_gate * 5
     && obs.active_goal_count > 0 then
    add StrategicReview;

  (* L3 Self-directed triggers — no goal requirement.
     Deterministic gates with longer cooldowns to prevent noise.

     Board-reactive: engage with new posts after idle_gate/2 cooldown.
     Enables community participation without requiring @mention.
     Gate: idle_seconds >= idle_gate/2 prevents every heartbeat from triggering.

     Self-directed explore: keepers without explicit goals can still act.
     4x idle_gate (~20min) provides generous cooldown.
     Allows curiosity-driven behavior: board posts, discussions, findings.
     Ref: Deepset "spectrum" — self-directed at the autonomy end. *)
  if obs.board_new_post_count > 0 && obs.idle_seconds >= obs.idle_gate / 2
     && obs.board_mention_count = 0 then
    add (BoardActivity "new_posts");
  if obs.active_goal_count = 0
     && obs.idle_seconds > obs.idle_gate * 4 then
    add SelfDirectedExplore;

  match List.rev !triggers with
  | [] -> Skip "no triggers detected"
  | ts -> Triggered ts

(* ---------- Deliberation meta: tracking fields for keeper_meta ---------- *)

type deliberation_meta = {
  deliberation_count: int;
  deliberation_cost_total_usd: float;
  last_deliberation_ts: float;
  last_triage_triggers: string;
}

let default_deliberation_meta =
  {
    deliberation_count = 0;
    deliberation_cost_total_usd = 0.0;
    last_deliberation_ts = 0.0;
    last_triage_triggers = "";
  }

let deliberation_meta_to_json (dm : deliberation_meta) : (string * Yojson.Safe.t) list =
  [
    ("deliberation_count", `Int dm.deliberation_count);
    ("deliberation_cost_total_usd", `Float dm.deliberation_cost_total_usd);
    ("last_deliberation_ts", `Float dm.last_deliberation_ts);
    ("last_triage_triggers", `String dm.last_triage_triggers);
  ]

let deliberation_meta_of_json (json : Yojson.Safe.t) : deliberation_meta =
  {
    deliberation_count =
      Safe_ops.json_int ~default:0 "deliberation_count" json;
    deliberation_cost_total_usd =
      Safe_ops.json_float ~default:0.0 "deliberation_cost_total_usd" json;
    last_deliberation_ts =
      Safe_ops.json_float ~default:0.0 "last_deliberation_ts" json;
    last_triage_triggers =
      Safe_ops.json_string ~default:"" "last_triage_triggers" json;
  }

(* ---------- Baseline action: typed replacement for the 2-line heuristic ---------- *)

(** Deterministic baseline using the typed action space.
    Equivalent to the old [if direct_mention then "reply_in_room" else "noop"]. *)
let deterministic_baseline_action (obs : world_observation) : deliberation_action =
  if obs.direct_mention then
    ReplyInRoom { room_id = ""; content = "" }
  else
    Noop "no_trigger"

(* ================================================================ *)
(* Phase 2: Deliberation Evaluation (L1 Reactive)                    *)
(* ================================================================ *)

(* ---------- Budget check ---------- *)

(** Current daily budget from keeper runtime config. *)
let daily_budget_usd () : float =
  Env_config.KeeperRuntime.deliberation_daily_budget_usd ()

(** Check whether the keeper has remaining budget for another deliberation call.
    Returns [true] if [cost_today_usd < daily_budget_usd]. *)
let deliberation_budget_check ~daily_budget_usd ~cost_today_usd : bool =
  cost_today_usd < daily_budget_usd

(* ---------- Prompt builder ---------- *)

let triggers_to_prompt_list (triggers : deliberation_trigger list) : string =
  triggers
  |> List.mapi (fun i t ->
         Printf.sprintf "  %d. %s" (i + 1) (deliberation_trigger_to_string t))
  |> String.concat "\n"

let world_observation_to_prompt_section (obs : world_observation) : string =
  Printf.sprintf
    "World state:\n\
    \  - Unclaimed tasks: %d\n\
    \  - Failed tasks: %d\n\
    \  - Active agents: %d\n\
    \  - Agent count changed: %b\n\
    \  - Active goals: %d\n\
    \  - Idle seconds: %d (gate: %d)\n\
    \  - Board new posts: %d\n\
    \  - Board mentions: %d\n\
    \  - Direct mention: %b\n\
    \  - Has question: %b"
    obs.unclaimed_task_count
    obs.failed_task_count
    obs.active_agent_count
    obs.agent_count_changed
    obs.active_goal_count
    obs.idle_seconds obs.idle_gate
    obs.board_new_post_count
    obs.board_mention_count
    obs.direct_mention
    obs.has_question

(** Build a prompt for the MODEL to decide the keeper's next action.
    The prompt describes the keeper's identity, current state, detected triggers,
    and available actions. The MODEL is asked to respond with JSON. *)
let build_deliberation_prompt
    ~keeper_name  ~goal
    ~(triggers : deliberation_trigger list)
    (obs : world_observation) : string =
  let multi_step_line =
    "\n- multi_step: Execute multiple actions sequentially (max 5). \
     Requires steps array of action objects."
  in
  let multi_step_example =
    {|
{"action":"multi_step","params":{"steps":[{"action":"task_claim","params":{"task_id":"task-1","reason":"urgent"}},{"action":"broadcast","params":{"message":"Claimed task-1"}}]},"reasoning":"Claim and announce","confidence":0.7}|}
  in
  match
    Prompt_registry.render_prompt_template Keeper_prompt_names.deliberation
      [
        ("keeper_name", keeper_name);
        ("goal", goal);
        ("triggers", triggers_to_prompt_list triggers);
        ("world_state", world_observation_to_prompt_section obs);
        ("multi_step_line", multi_step_line);
        ("multi_step_example", multi_step_example);
      ]
  with
  | Ok value -> value
  | Error _ -> Prompt_registry.get_prompt Keeper_prompt_names.deliberation

type structured_result = {
  action: deliberation_action;
  reasoning: string;
  confidence: float;
}

type action_source =
  | Baseline
  | Structured_model
  | Fallback_after_validation_failure

let action_source_to_string = function
  | Baseline -> "baseline"
  | Structured_model -> "structured_model"
  | Fallback_after_validation_failure -> "fallback_after_validation_failure"

let action_source_to_json source =
  `String (action_source_to_string source)

type legality_verdict =
  | Legal
  | Illegal of string

type execution_result = {
  proposed_action: deliberation_action;
  selected_action: deliberation_action;
  action_source: action_source;
  fallback_used: bool;
  fallback_reason: string option;
  policy_labels: string list;
  reasoning: string;
  confidence: float;
}

let rec policy_labels_of_action = function
  | MultiStep actions ->
      List.concat_map policy_labels_of_action actions
  | action ->
      [ deliberation_action_to_policy_label action ]

let has_board_signal (obs : world_observation) =
  obs.board_new_post_count > 0 || obs.board_mention_count > 0

let has_room_signal (obs : world_observation) =
  obs.direct_mention || obs.has_question

let has_operational_signal (obs : world_observation) =
  has_room_signal obs
  || obs.failed_task_count > 0
  || obs.unclaimed_task_count > 0
  || obs.agent_count_changed
  || has_board_signal obs

(** Self-directed context: keeper is idle with no goals.
    Deterministic predicate — same conditions as the L3 SelfDirectedExplore
    trigger in [triage]. Used in [legality_error] to relax action gates
    for keepers exploring autonomously.
    Ref: CSA autonomy Level 2-3 — human monitors, agent acts. *)
let is_self_directed (obs : world_observation) =
  obs.active_goal_count = 0 && obs.idle_seconds > obs.idle_gate * 4

let rec legality_error (obs : world_observation) = function
  | Noop _ -> None
  | ReplyInRoom _ ->
      if has_room_signal obs then None
      else Some "reply_in_room requires direct mention or a question"
  | BoardPost _ ->
      if has_board_signal obs || obs.active_goal_count > 0
         || is_self_directed obs then None
      else Some "board_post requires board activity, active goals, or self-directed context"
  | BoardComment _ ->
      if has_board_signal obs then None
      else Some "board_comment requires board activity"
  | BoardVote _ ->
      if has_board_signal obs then None
      else Some "board_vote requires board activity"
  | TaskClaim _ ->
      if obs.unclaimed_task_count > 0 then None
      else Some "task_claim requires unclaimed tasks"
  | Broadcast _ ->
      if has_operational_signal obs then None
      else Some "broadcast requires an operational signal"
  | ProposeSpawn _ ->
      if obs.failed_task_count > 0 || obs.unclaimed_task_count > 0
         || obs.active_goal_count > 0 then None
      else Some "propose_spawn requires failed tasks, unclaimed tasks, or active goals"
  | StartDiscussion _ ->
      if has_board_signal obs || obs.active_goal_count > 0
         || is_self_directed obs then None
      else Some "start_discussion requires board activity, active goals, or self-directed context"
  | ShareFinding _ ->
      if has_board_signal obs || obs.active_goal_count > 0
         || is_self_directed obs then None
      else Some "share_finding requires board activity, active goals, or self-directed context"
  | MultiStep actions -> (
      match actions with
      | [] -> Some "multi_step requires non-empty steps"
      | _ ->
          let rec loop index = function
            | [] -> None
            | MultiStep _ :: _ ->
                Some
                  (Printf.sprintf
                     "multi_step step %d cannot contain nested multi_step"
                     index)
            | action :: rest -> (
                match legality_error obs action with
                | Some msg ->
                    Some
                      (Printf.sprintf "multi_step step %d illegal: %s" index
                         msg)
                | None -> loop (index + 1) rest)
          in
          loop 0 actions)

let legality_verdict obs action =
  match legality_error obs action with
  | None -> Legal
  | Some reason -> Illegal reason

let baseline_execution_result (obs : world_observation) : execution_result =
  let action = deterministic_baseline_action obs in
  {
    proposed_action = action;
    selected_action = action;
    action_source = Baseline;
    fallback_used = false;
    fallback_reason = None;
    policy_labels = policy_labels_of_action action;
    reasoning = "deterministic_baseline";
    confidence = 1.0;
  }

let action_source_of_execution_result (result : execution_result) =
  result.action_source

let execution_result_to_json (result : execution_result) : Yojson.Safe.t =
  `Assoc
    [
      ("proposed_action", deliberation_action_to_json result.proposed_action);
      ("selected_action", deliberation_action_to_json result.selected_action);
      ("action_source", action_source_to_json result.action_source);
      ("fallback_used", `Bool result.fallback_used);
      ( "fallback_reason",
        match result.fallback_reason with
        | Some reason -> `String reason
        | None -> `Null );
      ("policy_labels", `List (List.map (fun label -> `String label) result.policy_labels));
      ("reasoning", `String result.reasoning);
      ("confidence", `Float result.confidence);
    ]

let execute_structured_result (obs : world_observation)
    (result : structured_result) : execution_result =
  match legality_verdict obs result.action with
  | Legal ->
      {
        proposed_action = result.action;
        selected_action = result.action;
        action_source = Structured_model;
        fallback_used = false;
        fallback_reason = None;
        policy_labels = policy_labels_of_action result.action;
        reasoning = result.reasoning;
        confidence = result.confidence;
      }
  | Illegal reason ->
      let baseline = baseline_execution_result obs in
      {
        proposed_action = result.action;
        selected_action = baseline.selected_action;
        action_source = Fallback_after_validation_failure;
        fallback_used = true;
        fallback_reason = Some reason;
        policy_labels = baseline.policy_labels;
        reasoning = result.reasoning;
        confidence = result.confidence;
      }

(* ---------- Response parser ---------- *)

let clamp_confidence raw_conf =
  max 0.0 (min 1.0 raw_conf)

let json_of_response (raw : string) : (Yojson.Safe.t, string) result =
  let trimmed = String.trim raw in
  if trimmed = "" then
    Error "empty response"
  else
    match Yojson.Safe.from_string trimmed with
    | json -> Ok json
    | exception Yojson.Json_error msg ->
        Error (Printf.sprintf "strict JSON parse failed: %s" msg)

(** Parse a deliberation action from the "action" and "params" fields of the
    MODEL response JSON. Returns the typed action or an error string. *)
let rec parse_action_from_json (json : Yojson.Safe.t)
    : (deliberation_action, string) result =
  let action_str = Safe_ops.json_string ~default:"" "action" json in
  let params =
    match json with
    | `Assoc fields -> (
        match List.assoc_opt "params" fields with
        | Some p -> p
        | None -> `Assoc [])
    | _ -> `Assoc []
  in
  match action_str with
  | "noop" ->
      let reason = Safe_ops.json_string ~default:"no reason" "reason" params in
      Ok (Noop reason)
  | "reply_in_room" ->
      let room_id = Safe_ops.json_string ~default:"default" "room_id" params in
      let content = Safe_ops.json_string ~default:"" "content" params in
      if content = "" then Error "reply_in_room requires non-empty content"
      else Ok (ReplyInRoom { room_id; content })
  | "task_claim" ->
      let task_id = Safe_ops.json_string ~default:"" "task_id" params in
      let reason = Safe_ops.json_string ~default:"" "reason" params in
      if task_id = "" then Error "task_claim requires non-empty task_id"
      else Ok (TaskClaim { task_id; reason })
  | "broadcast" ->
      let message = Safe_ops.json_string ~default:"" "message" params in
      if message = "" then Error "broadcast requires non-empty message"
      else Ok (Broadcast { message })
  | "board_post" ->
      let content = Safe_ops.json_string ~default:"" "content" params in
      let hearth = Safe_ops.json_string_opt "hearth" params in
      if content = "" then Error "board_post requires non-empty content"
      else Ok (BoardPost { content; hearth })
  | "board_comment" ->
      let post_id = Safe_ops.json_string ~default:"" "post_id" params in
      let content = Safe_ops.json_string ~default:"" "content" params in
      if post_id = "" || content = "" then
        Error "board_comment requires non-empty post_id and content"
      else Ok (BoardComment { post_id; content })
  | "board_vote" ->
      let post_id = Safe_ops.json_string ~default:"" "post_id" params in
      let direction = Safe_ops.json_string ~default:"" "direction" params in
      if post_id = "" || direction = "" then
        Error "board_vote requires non-empty post_id and direction"
      else Ok (BoardVote { post_id; direction })
  | "propose_spawn" ->
      let topic = Safe_ops.json_string ~default:"" "topic" params in
      let reason = Safe_ops.json_string ~default:"" "reason" params in
      if topic = "" then Error "propose_spawn requires non-empty topic"
      else Ok (ProposeSpawn { topic; reason })
  | "multi_step" -> (
      let steps_json =
        match params with
        | `Assoc fields -> (
            match List.assoc_opt "steps" fields with
            | Some (`List items) -> items
            | _ -> [])
        | _ -> []
      in
      match steps_json with
      | [] -> Error "multi_step requires non-empty steps array"
      | items ->
          let max_steps = 5 in
          let truncated =
            if List.length items > max_steps then
              let rec take n acc = function
                | _ when n <= 0 -> List.rev acc
                | [] -> List.rev acc
                | x :: xs -> take (n - 1) (x :: acc) xs
              in
              take max_steps [] items
            else items
          in
          let results =
            List.map
              (fun step_json ->
                parse_action_from_json step_json)
              truncated
          in
          let errors =
            List.filter_map
              (function Error e -> Some e | Ok _ -> None)
              results
          in
          if errors <> [] then
            Error
              (Printf.sprintf "multi_step contains invalid actions: %s"
                 (String.concat "; " errors))
          else
            let actions =
              List.filter_map
                (function Ok a -> Some a | Error _ -> None)
                results
            in
            (* Reject nested multi_step *)
            let has_nested =
              List.exists
                (function MultiStep _ -> true | _ -> false)
                actions
            in
            if has_nested then
              Error "multi_step cannot contain nested multi_step actions"
            else Ok (MultiStep actions))
  | "" -> Error "missing 'action' field in MODEL response"
  | unknown -> Error (Printf.sprintf "unknown action type: %s" unknown)

let structured_result_of_json (json : Yojson.Safe.t)
    : (structured_result, string) result =
  match parse_action_from_json json with
  | Error msg -> Error msg
  | Ok action ->
      let reasoning =
        Safe_ops.json_string ~default:"" "reasoning" json
      in
      let confidence =
        clamp_confidence (Safe_ops.json_float ~default:0.5 "confidence" json)
      in
      Ok { action; reasoning; confidence }

let structured_result_schema : structured_result Agent_sdk.Structured.schema =
  {
    Agent_sdk.Structured.name = "keeper_deliberation_decision";
    description =
      "Choose exactly one typed keeper deliberation action and return only the tool input object.";
    params =
      [
        {
          Agent_sdk.Types.name = "action";
          description = "One of: noop, reply_in_room, task_claim, broadcast, board_post, board_comment, board_vote, propose_spawn, start_discussion, share_finding, multi_step.";
          param_type = Agent_sdk.Types.String;
          required = true;
        };
        {
          Agent_sdk.Types.name = "params";
          description = "Action-specific parameters.";
          param_type = Agent_sdk.Types.Object;
          required = true;
        };
        {
          Agent_sdk.Types.name = "reasoning";
          description = "Optional short explanation for the chosen action.";
          param_type = Agent_sdk.Types.String;
          required = false;
        };
        {
          Agent_sdk.Types.name = "confidence";
          description = "Confidence score from 0.0 to 1.0.";
          param_type = Agent_sdk.Types.Number;
          required = false;
        };
      ];
    parse = structured_result_of_json;
  }

(** Parse the MODEL's JSON response into a deliberation_action with reasoning
    and confidence. Returns [(action, reasoning, confidence)] or an error string. *)
let parse_deliberation_response (raw : string)
    : (deliberation_action * string * float, string) result =
  match json_of_response raw with
  | Error msg -> Error msg
  | Ok json ->
      structured_result_of_json json
      |> Result.map (fun result ->
             (result.action, result.reasoning, result.confidence))
