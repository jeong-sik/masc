(** Keeper_memory — memory-bank paths, reward-model evaluation,
    state snapshots, recall scoring, and metrics summaries. *)

open Keeper_types

type keeper_reward_candidate = {
  bias: float;
  weights: (string * float) list;
}

type keeper_reward_model = {
  version: string;
  path: string;
  candidates: (string * keeper_reward_candidate) list;
}

type keeper_policy_observation = {
  source_kind: string;
  room_id: string option;
  from_agent: string;
  message: string;
  direct_mention: bool;
  has_question: bool;
  message_chars: int;
  total_turns: int;
  active_goal_count: int;
  joined_room_count: int;
  room_scope: Keeper_contract.room_scope;
  last_turn_ago_s: float;
}

type keeper_policy_candidate_score = {
  action: string;
  bias: float;
  feature_scores: (string * float) list;
  score: float;
  allowed: bool;
}

let empty_keeper_reward_candidate = { bias = 0.0; weights = [] }

let policy_action_order action =
  match action with
  | "noop" -> 0
  | "reply_in_room" -> 1
  | "board_post" -> 2
  | _ -> 9

let keeper_policy_feature_vector (obs : keeper_policy_observation) : (string * float) list =
  let clamp01 value = max 0.0 (min 1.0 value) in
  [
    ("direct_mention", if obs.direct_mention then 1.0 else 0.0);
    ("question_mark", if obs.has_question then 1.0 else 0.0);
    ("message_chars", clamp01 (float_of_int obs.message_chars /. 400.0));
    ("active_goal_count", clamp01 (float_of_int obs.active_goal_count /. 5.0));
    ("joined_room_count", clamp01 (float_of_int obs.joined_room_count /. 5.0));
    ( "room_scope_all",
      if Keeper_contract.room_scope_to_string obs.room_scope = "all" then 1.0 else 0.0 );
    ("idle_seconds", clamp01 (obs.last_turn_ago_s /. 3600.0));
  ]

let float_assoc_to_json (items : (string * float) list) : Yojson.Safe.t =
  `Assoc (List.map (fun (key, value) -> (key, `Float value)) items)

let keeper_policy_observation_to_json (obs : keeper_policy_observation) : Yojson.Safe.t =
  `Assoc
    [
      ("source_kind", `String obs.source_kind);
      ("room_id",
        match obs.room_id with
        | Some room_id -> `String room_id
        | None -> `Null);
      ("from_agent", `String obs.from_agent);
      ("message", `String obs.message);
      ("direct_mention", `Bool obs.direct_mention);
      ("has_question", `Bool obs.has_question);
      ("message_chars", `Int obs.message_chars);
      ("total_turns", `Int obs.total_turns);
      ("active_goal_count", `Int obs.active_goal_count);
      ("joined_room_count", `Int obs.joined_room_count);
      ("room_scope", `String (Keeper_contract.room_scope_to_string obs.room_scope));
      ("last_turn_ago_s", `Float obs.last_turn_ago_s);
    ]

let keeper_policy_candidate_score_to_json
    (candidate : keeper_policy_candidate_score) : Yojson.Safe.t =
  `Assoc
    [
      ("action", `String candidate.action);
      ("bias", `Float candidate.bias);
      ("feature_scores", float_assoc_to_json candidate.feature_scores);
      ("score", `Float candidate.score);
      ("allowed", `Bool candidate.allowed);
    ]

let reward_candidate_of_json (json : Yojson.Safe.t) : keeper_reward_candidate =
  let bias = Safe_ops.json_float ~default:0.0 "bias" json in
  let weights =
    match Yojson.Safe.Util.member "weights" json with
    | `Assoc fields ->
        fields
        |> List.filter_map (fun (feature, value) ->
               match value with
               | `Float weight -> Some (feature, weight)
               | `Int n -> Some (feature, float_of_int n)
               | `Intlit raw ->
                   Some (feature, Safe_ops.float_of_string_with_default ~default:0.0 raw)
               | _ -> None)
    | _ -> []
  in
  { bias; weights }

let load_keeper_reward_model (path : string) : (keeper_reward_model, string) result =
  let path = String.trim path in
  if path = "" then
    Error "reward_model_path is required for learned_offline_v1"
  else
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
        let version = Safe_ops.json_string ~default:"reward-model-v1" "version" json in
        let candidates =
          match Yojson.Safe.Util.member "candidates" json with
          | `Assoc fields ->
              fields |> List.map (fun (name, value) -> (name, reward_candidate_of_json value))
          | _ -> []
        in
        if candidates = [] then
          Error "reward model must define candidates"
        else
          Ok { version; path; candidates }

let score_keeper_policy_candidate
    ~(model : keeper_reward_model)
    ~(features : (string * float) list)
    ~(action : string)
    ~(allowed : bool) : keeper_policy_candidate_score =
  let candidate_model =
    model.candidates
    |> List.find_map (fun (candidate_action, candidate_model) ->
           if candidate_action = action then Some candidate_model else None)
    |> Option.value ~default:empty_keeper_reward_candidate
  in
  let feature_scores =
    candidate_model.weights
    |> List.map (fun (feature_name, weight) ->
           let feature_value =
             features
             |> List.find_map (fun (name, value) ->
                    if name = feature_name then Some value else None)
             |> Option.value ~default:0.0
           in
           (feature_name, weight *. feature_value))
  in
  let score =
    List.fold_left (fun acc (_, value) -> acc +. value) candidate_model.bias feature_scores
  in
  {
    action;
    bias = candidate_model.bias;
    feature_scores;
    score;
    allowed;
  }

let observation_has_question (message : string) =
  String.contains message '?'

let keeper_policy_observation_of_room_message
    ~(meta : keeper_meta)
    ~(room_id : string)
    (msg : Types.message) : keeper_policy_observation =
  let now_ts = Time_compat.now () in
  let mention_targets =
    if meta.mention_targets <> [] then meta.mention_targets else [ meta.name ]
  in
  let last_turn_ago_s =
    if meta.runtime.usage.last_turn_ts <= 0.0 then 0.0 else max 0.0 (now_ts -. meta.runtime.usage.last_turn_ts)
  in
  {
    source_kind = "room_message";
    room_id = Some room_id;
    from_agent = msg.from_agent;
    message = msg.content;
    direct_mention = Mention.any_mentioned ~targets:mention_targets msg.content;
    has_question = observation_has_question msg.content;
    message_chars = String.length msg.content;
    total_turns = meta.runtime.usage.total_turns;
    active_goal_count = List.length meta.active_goal_ids;
    joined_room_count = List.length meta.joined_room_ids;
    room_scope = Keeper_contract.room_scope_of_string meta.room_scope;
    last_turn_ago_s;
  }

let deterministic_policy_baseline_action_typed
    (obs : keeper_policy_observation) : Keeper_deliberation.deliberation_action =
  if obs.direct_mention then
    Keeper_deliberation.ReplyInRoom { room_id = ""; content = "" }
  else
    Keeper_deliberation.Noop "no_trigger"

(** Backward-compatible string interface for existing callers. *)
let deterministic_policy_baseline_action (obs : keeper_policy_observation) : string =
  deterministic_policy_baseline_action_typed obs
  |> Keeper_deliberation.deliberation_action_to_policy_label

let choose_policy_action (candidates : keeper_policy_candidate_score list) :
    keeper_policy_candidate_score option =
  candidates
  |> List.filter (fun candidate -> candidate.allowed)
  |> List.sort (fun a b ->
         let score_cmp = Float.compare b.score a.score in
         if score_cmp <> 0 then score_cmp
         else compare (policy_action_order a.action) (policy_action_order b.action))
  |> function
  | candidate :: _ -> Some candidate
  | [] -> None

type alert_channel_result = {
  channel: string;
  attempted: bool;
  success: bool;
  attempts: int;
  detail: string option;
}

type interesting_alert_result = {
  enabled: bool;
  triggered: bool;
  score: float;
  threshold: float;
  reasons: string list;
  keywords: string list;
  alert_id: string option;
  channels: alert_channel_result list;
  retry_queued: bool;
  deadlettered: bool;
}

let empty_interesting_alert_result = {
  enabled = false;
  triggered = false;
  score = 0.0;
  threshold = 0.0;
  reasons = [];
  keywords = [];
  alert_id = None;
  channels = [];
  retry_queued = false;
  deadlettered = false;
}

let alert_channel_result_to_json (r : alert_channel_result) : Yojson.Safe.t =
  `Assoc [
    ("channel", `String r.channel);
    ("attempted", `Bool r.attempted);
    ("success", `Bool r.success);
    ("attempts", `Int r.attempts);
    ("detail",
      match r.detail with
      | Some d when String.trim d <> "" -> `String d
      | _ -> `Null);
  ]

let interesting_alert_result_to_json (r : interesting_alert_result) : Yojson.Safe.t =
  `Assoc [
    ("enabled", `Bool r.enabled);
    ("triggered", `Bool r.triggered);
    ("score", `Float r.score);
    ("threshold", `Float r.threshold);
    ("reasons", `List (List.map (fun s -> `String s) r.reasons));
    ("keywords", `List (List.map (fun s -> `String s) r.keywords));
    ("alert_id",
      match r.alert_id with
      | Some id when String.trim id <> "" -> `String id
      | _ -> `Null);
    ("channels", `List (List.map alert_channel_result_to_json r.channels));
    ("retry_queued", `Bool r.retry_queued);
    ("deadlettered", `Bool r.deadlettered);
  ]

type keeper_state_snapshot = {
  goal: string option;
  progress: string option;
  next_items: string list;
  decisions: string list;
  open_questions: string list;
  constraints: string list;
}

let empty_keeper_state_snapshot = {
  goal = None;
  progress = None;
  next_items = [];
  decisions = [];
  open_questions = [];
  constraints = [];
}

type keeper_memory_line = {
  kind: string;
  text: string;
  priority: int;
  ts_unix: float;
}

type keeper_memory_summary = {
  total_notes: int;
  last_ts_unix: float;
  top_kind: string option;
  kind_counts: (string * int) list;
  recent_notes: keeper_memory_line list;
}

type memory_bank_compaction = {
  performed: bool;
  reason: string option;
  target_notes: int;
  before_notes: int;
  after_notes: int;
  dropped_notes: int;
  dedup_dropped: int;
  invalid_dropped: int;
}

let no_memory_bank_compaction = {
  performed = false;
  reason = None;
  target_notes = 0;
  before_notes = 0;
  after_notes = 0;
  dropped_notes = 0;
  dedup_dropped = 0;
  invalid_dropped = 0;
}

let trim_nonempty (s : string) : string option =
  let t = String.trim s in
  if t = "" then None else Some t

let split_state_items (s : string) : string list =
  s
  |> String.split_on_char ';'
  |> List.map String.trim
  |> List.filter (fun x -> x <> "")
  |> take 6

let strip_prefix_ci ~(prefix : string) (s : string) : string option =
  let s = String.trim s in
  let plen = String.length prefix in
  if String.length s < plen then None
  else
    let head = String.sub s 0 plen |> String.lowercase_ascii in
    if head = String.lowercase_ascii prefix then
      Some (String.sub s plen (String.length s - plen) |> String.trim)
    else
      None

let find_state_block (reply : string) : string option =
  let start_re = Re.str "[STATE]" |> Re.compile in
  let end_re = Re.str "[/STATE]" |> Re.compile in
  match Re.exec_opt start_re reply with
  | None -> None
  | Some g ->
    let start_idx = Re.Group.start g 0 in
    let body_start = start_idx + String.length "[STATE]" in
    (match Re.exec_opt ~pos:body_start end_re reply with
     | None -> None
     | Some g2 ->
       let end_idx = Re.Group.start g2 0 in
       if end_idx <= body_start then None
       else Some (String.sub reply body_start (end_idx - body_start)))

let parse_state_snapshot_from_reply (reply : string) : keeper_state_snapshot option =
  match find_state_block reply with
  | None -> None
  | Some body ->
      let lines =
        body
        |> String.split_on_char '\n'
        |> List.map String.trim
        |> List.filter (fun line -> line <> "")
      in
      let snapshot =
        List.fold_left
          (fun acc line ->
            match strip_prefix_ci ~prefix:"Goal:" line with
            | Some v -> { acc with goal = trim_nonempty v }
            | None ->
                (match strip_prefix_ci ~prefix:"Progress:" line with
                | Some v -> { acc with progress = trim_nonempty v }
                | None ->
                    (match strip_prefix_ci ~prefix:"Next:" line with
                    | Some v -> { acc with next_items = split_state_items v }
                    | None ->
                        (match strip_prefix_ci ~prefix:"Decisions:" line with
                        | Some v -> { acc with decisions = split_state_items v }
                        | None ->
                            (match strip_prefix_ci ~prefix:"OpenQuestions:" line with
                            | Some v ->
                                { acc with open_questions = split_state_items v }
                            | None ->
                                (match strip_prefix_ci
                                         ~prefix:"Constraints:" line
                                 with
                                | Some v ->
                                    { acc with constraints = split_state_items v }
                                | None -> acc))))))
          empty_keeper_state_snapshot lines
      in
      if snapshot.goal = None
         && snapshot.progress = None
         && snapshot.next_items = []
         && snapshot.decisions = []
         && snapshot.open_questions = []
         && snapshot.constraints = []
      then
        None
      else
        Some snapshot

let keeper_state_snapshot_to_summary_text (snapshot : keeper_state_snapshot) : string =
  let maybe_line match_fn label =
    match match_fn () with
    | None -> None
    | Some value -> Some (Printf.sprintf "%s: %s" label value)
  in
  let lines =
    [
      maybe_line
        (fun () ->
           match snapshot.goal with
           | Some v when String.trim v <> "" -> Some (String.trim v)
           | _ -> None)
        "Goal";
      maybe_line
        (fun () ->
           match snapshot.progress with
           | Some v when String.trim v <> "" -> Some (String.trim v)
           | _ -> None)
        "Progress";
      maybe_line
        (fun () ->
           match snapshot.next_items with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Next";
      maybe_line
        (fun () ->
           match snapshot.decisions with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Decisions";
      maybe_line
        (fun () ->
           match snapshot.open_questions with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "OpenQuestions";
      maybe_line
        (fun () ->
           match snapshot.constraints with
           | [] -> None
           | items -> Some (String.concat "; " (take 3 (List.map String.trim items))))
        "Constraints";
    ]
    |> List.filter_map (fun x -> x)
  in
  if lines = [] then "No continuity snapshot available." else String.concat "\n" lines

let keeper_state_snapshot_to_json (snapshot : keeper_state_snapshot) : Yojson.Safe.t =
  `Assoc [
    ("goal", match snapshot.goal with Some s -> `String s | None -> `Null);
    ("progress", match snapshot.progress with Some s -> `String s | None -> `Null);
    ("next_items", `List (List.map (fun s -> `String s) snapshot.next_items));
    ("decisions", `List (List.map (fun s -> `String s) snapshot.decisions));
    ("open_questions", `List (List.map (fun s -> `String s) snapshot.open_questions));
    ("constraints", `List (List.map (fun s -> `String s) snapshot.constraints));
  ]

let latest_state_snapshot_from_messages (messages : Agent_sdk.Types.message list) :
    keeper_state_snapshot option =
  let rec loop (msgs : Agent_sdk.Types.message list) =
    match msgs with
    | [] -> None
    | msg :: rest ->
      match parse_state_snapshot_from_reply (Agent_sdk.Types.text_of_message msg) with
      | None -> loop rest
      | Some snapshot -> Some snapshot
  in
  loop (List.rev messages)

let append_continuity_context_prompt
    ~(base_prompt : string)
    (snapshot : keeper_state_snapshot option)
    ~(continuity_summary : string) : string =
  let fallback_summary =
    let trimmed = String.trim continuity_summary in
    if trimmed = "" then "No continuity snapshot available." else trimmed
  in
  let summary =
    match snapshot with
    | None -> fallback_summary
    | Some s -> keeper_state_snapshot_to_summary_text s
  in
  if summary = "No continuity snapshot available." then base_prompt
  else
    Printf.sprintf
      "%s\n\nRecent continuity snapshot:\n%s"
      base_prompt
      summary

let priority_for_kind ~soul_profile ~(kind : string) : int =
  match soul_profile, kind with
  | "safety", "constraints" -> 100
  | "safety", "open_question" -> 88
  | "safety", "decision" -> 82
  | "safety", "goal" -> 76
  | "safety", "next" -> 70
  | "safety", "progress" -> 62
  | "delivery", "next" -> 100
  | "delivery", "decision" -> 90
  | "delivery", "goal" -> 80
  | "delivery", "progress" -> 74
  | "delivery", "open_question" -> 68
  | "delivery", "constraints" -> 62
  | "research", "open_question" -> 100
  | "research", "decision" -> 92
  | "research", "progress" -> 84
  | "research", "goal" -> 76
  | "research", "next" -> 70
  | "research", "constraints" -> 62
  | "relationship", "goal" -> 96
  | "relationship", "progress" -> 90
  | "relationship", "constraints" -> 84
  | "relationship", "decision" -> 78
  | "relationship", "open_question" -> 72
  | "relationship", "next" -> 66
  | "minimal", "goal" -> 100
  | "minimal", "next" -> 92
  | "minimal", "decision" -> 80
  | "minimal", "constraints" -> 74
  | "minimal", "open_question" -> 70
  | "minimal", "progress" -> 60
  | _, "constraints" -> 90
  | _, "decision" -> 86
  | _, "next" -> 80
  | _, "open_question" -> 76
  | _, "goal" -> 72
  | _, "progress" -> 66
  | _ -> 60

let contains_any_ci (text : string) (needles : string list) : bool =
  let hay = String.lowercase_ascii text in
  List.exists
    (fun needle ->
      let n = String.lowercase_ascii needle in
      n <> "" && Re.execp (Re.str n |> Re.compile) hay)
    needles

let profile_signal_bonus ~(profile : string) ~(kind : string) ~(text : string) : int =
  let safety_words = [
    "risk"; "danger"; "unsafe"; "security"; "privacy"; "consent"; "guardrail";
    "위험"; "보안"; "개인정보"; "동의"; "안전";
  ] in
  let delivery_words = [
    "blocker"; "deadline"; "ship"; "release"; "next step"; "todo"; "must";
    "막힘"; "차단"; "데드라인"; "배포"; "다음 단계"; "필수";
  ] in
  let research_words = [
    "hypothesis"; "evidence"; "experiment"; "measure"; "benchmark"; "assume";
    "가설"; "근거"; "실험"; "측정"; "벤치";
  ] in
  let relationship_words = [
    "preference"; "style"; "tone"; "boundary"; "expectation"; "trust";
    "선호"; "스타일"; "톤"; "경계"; "기대"; "신뢰";
  ] in
  let uncertainty_words = [
    "unknown"; "unclear"; "maybe"; "tbd"; "later"; "todo"; "unsure";
    "모름"; "불명"; "아마"; "추정"; "미정"; "나중";
  ] in
  let profile_bonus =
    match profile with
    | "safety" when kind = "constraints" || contains_any_ci text safety_words -> 14
    | "delivery" when kind = "next" || kind = "decision" || contains_any_ci text delivery_words ->
        12
    | "research" when kind = "open_question" || contains_any_ci text research_words -> 12
    | "relationship" when kind = "goal" || kind = "progress" || contains_any_ci text relationship_words ->
        12
    | "minimal" when kind = "goal" || kind = "next" -> 6
    | _ -> 0
  in
  let global_bonus =
    if contains_any_ci text ["must"; "required"; "필수"; "중요"; "critical"] then 4 else 0
  in
  let uncertainty_penalty =
    if contains_any_ci text uncertainty_words then -8 else 0
  in
  profile_bonus + global_bonus + uncertainty_penalty

let tuned_priority_for_candidate
    ~(soul_profile : string)
    ~(kind : string)
    ~(text : string) : int =
  let base = priority_for_kind ~soul_profile ~kind in
  let bonus = profile_signal_bonus ~profile:soul_profile ~kind ~text in
  max 1 (min 100 (base + bonus))

let profile_total_cap (profile : string) : int =
  match profile with
  | "minimal" -> 4
  | "safety" -> 10
  | "research" -> 11
  | "relationship" -> 11
  | _ -> 12

let profile_kind_caps (profile : string) : (string * int) list =
  match profile with
  | "safety" ->
      [ ("constraints", 3); ("open_question", 2); ("decision", 2); ("goal", 1); ("next", 1); ("progress", 1) ]
  | "delivery" ->
      [ ("next", 3); ("decision", 3); ("goal", 2); ("progress", 2); ("constraints", 1); ("open_question", 1) ]
  | "research" ->
      [ ("open_question", 3); ("decision", 3); ("progress", 2); ("goal", 1); ("next", 1); ("constraints", 1) ]
  | "relationship" ->
      [ ("goal", 2); ("progress", 3); ("constraints", 2); ("decision", 2); ("open_question", 1); ("next", 1) ]
  | "minimal" ->
      [ ("goal", 1); ("next", 1); ("decision", 1); ("constraints", 1); ("open_question", 0); ("progress", 0) ]
  | _ ->
      [ ("constraints", 2); ("decision", 2); ("next", 2); ("goal", 2); ("progress", 2); ("open_question", 2) ]

let cap_for_kind (caps : (string * int) list) (kind : string) : int =
  List.assoc_opt kind caps |> Option.value ~default:1
