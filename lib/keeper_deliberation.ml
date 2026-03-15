(** Keeper_deliberation — typed action space, deliberation triggers,
    world observation builder, and triage logic for the deliberation engine.

    Phase 1: Pure heuristic triage (no LLM calls).
    Phase 2 will add LLM-driven deliberation behind the triage gate.

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
  | MultiStep actions ->
      "multi_step:["
      ^ String.concat "," (List.map deliberation_action_to_string actions)
      ^ "]"

(** Backward-compatible: map typed action to the legacy string labels
    used by policy logging and reward models. *)
let deliberation_action_to_legacy_string = function
  | Noop _ -> "noop"
  | ReplyInRoom _ -> "reply_in_room"
  | BoardPost _ -> "board_post"
  | BoardComment _ -> "board_comment"
  | BoardVote _ -> "board_vote"
  | TaskClaim _ -> "task_claim"
  | Broadcast _ -> "broadcast"
  | ProposeSpawn _ -> "propose_spawn"
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

(* ---------- Triage function: cheap gate before LLM deliberation ---------- *)

(** Evaluate a world observation and return triggers that warrant deliberation.
    This is a pure heuristic — no LLM calls, no I/O.
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
