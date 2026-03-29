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

(* ---------- Triage function: cheap gate before MODEL deliberation ---------- *)

(** Evaluate a world observation and return triggers that warrant deliberation.
    This is a pure heuristic — no MODEL calls, no I/O.
    Returns [Skip _] when nothing interesting happened,
    [Triggered triggers] when the keeper should deliberate. *)
let triage (obs : world_observation) : triage_result =
  let triggers = ref [] in
  let add t = triggers := t :: !triggers in

  (* L1 Reactive triggers *)
  if obs.direct_mention then add DirectMention;
  if obs.unclaimed_task_count > 0 then add NewUnclaimedTask;
  if obs.failed_task_count > 0 then add FailedTask;
  if obs.agent_count_changed then add AgentJoinedOrLeft;

  (* L2 Proactive triggers *)
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
(* Phase 2: MODEL-Driven Deliberation (L1 Reactive)                  *)
(* ================================================================ *)

(* ---------- Budget check ---------- *)

(** Read the daily budget from env, returning the default if absent or invalid. *)
let daily_budget_usd_from_env () : float =
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
    ~keeper_name ~soul_profile ~goal
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
    Prompt_registry.render_prompt_template "keeper.deliberation"
      [
        ("keeper_name", keeper_name);
        ("soul_profile", soul_profile);
        ("goal", goal);
        ("triggers", triggers_to_prompt_list triggers);
        ("world_state", world_observation_to_prompt_section obs);
        ("multi_step_line", multi_step_line);
        ("multi_step_example", multi_step_example);
      ]
  with
  | Ok value -> value
  | Error _ -> Prompt_registry.get_prompt "keeper.deliberation"

(* ---------- Response parser ---------- *)

(** Extract a JSON object from a raw MODEL response string.
    Handles cases where the MODEL wraps JSON in markdown code fences or
    adds extra text before/after the JSON. *)
let extract_json_from_response (raw : string) : (Yojson.Safe.t, string) result =
  let trimmed = String.trim raw in
  (* Try direct parse first *)
  match Yojson.Safe.from_string trimmed with
  | json -> Ok json
  | exception Yojson.Json_error _ ->
      (* Try to find JSON between code fences *)
      let re_fenced = Re.Pcre.re {|```(json)?\n?(.*)\n?```|} |> Re.compile in
      (match Re.exec_opt re_fenced trimmed with
      | Some g ->
        let inner = Re.Group.get g 2 in
        (match Yojson.Safe.from_string (String.trim inner) with
        | json -> Ok json
        | exception Yojson.Json_error _ -> Error "JSON parse failed after fence extraction")
      | None ->
        (* Try to find first { ... } substring *)
        let len = String.length trimmed in
        let rec find_brace i =
          if i >= len then Error "no JSON object found in response"
          else if trimmed.[i] = '{' then
            (* Find matching closing brace *)
            let depth = ref 0 in
            let in_string = ref false in
            let escape = ref false in
            let j = ref i in
            let found = ref false in
            while !j < len && not !found do
              let c = trimmed.[!j] in
              if !escape then escape := false
              else if c = '\\' && !in_string then escape := true
              else if c = '"' then in_string := not !in_string
              else if not !in_string then (
                if c = '{' then incr depth
                else if c = '}' then (
                  decr depth;
                  if !depth = 0 then found := true));
              if not !found then incr j
            done;
            if !found then
              let substr = String.sub trimmed i (!j - i + 1) in
              match Yojson.Safe.from_string substr with
              | json -> Ok json
              | exception Yojson.Json_error msg ->
                  Error (Printf.sprintf "extracted JSON parse failed: %s" msg)
            else Error "unmatched braces in response"
          else find_brace (i + 1)
        in
        find_brace 0)

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

(** Parse the MODEL's JSON response into a deliberation_action with reasoning
    and confidence. Returns [(action, reasoning, confidence)] or an error string. *)
let parse_deliberation_response (raw : string)
    : (deliberation_action * string * float, string) result =
  match extract_json_from_response raw with
  | Error msg -> Error (Printf.sprintf "json extraction failed: %s" msg)
  | Ok json -> (
      match parse_action_from_json json with
      | Error msg -> Error msg
      | Ok action ->
          let reasoning =
            Safe_ops.json_string ~default:"" "reasoning" json
          in
          let confidence =
            let raw_conf = Safe_ops.json_float ~default:0.5 "confidence" json in
            max 0.0 (min 1.0 raw_conf)
          in
          Ok (action, reasoning, confidence))
