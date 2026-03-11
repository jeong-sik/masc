(** Keeper_memory — memory-bank paths, reward-model evaluation,
    state snapshots, recall scoring, and metrics summaries. *)

include Keeper_types

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
  room_scope: string;
  trigger_mode: string;
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

let keeper_policy_mode_is_learned (meta : keeper_meta) =
  canonical_policy_mode meta.policy_mode = "learned_offline_v1"

let keeper_policy_feature_vector (obs : keeper_policy_observation) : (string * float) list =
  let clamp01 value = max 0.0 (min 1.0 value) in
  [
    ("direct_mention", if obs.direct_mention then 1.0 else 0.0);
    ("question_mark", if obs.has_question then 1.0 else 0.0);
    ("message_chars", clamp01 (float_of_int obs.message_chars /. 400.0));
    ("active_goal_count", clamp01 (float_of_int obs.active_goal_count /. 5.0));
    ("joined_room_count", clamp01 (float_of_int obs.joined_room_count /. 5.0));
    ("room_scope_all", if obs.room_scope = "all" then 1.0 else 0.0);
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
      ("room_scope", `String obs.room_scope);
      ("trigger_mode", `String obs.trigger_mode);
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
  let last_turn_ago_s =
    if meta.last_turn_ts <= 0.0 then 0.0 else max 0.0 (now_ts -. meta.last_turn_ts)
  in
  {
    source_kind = "room_message";
    room_id = Some room_id;
    from_agent = msg.from_agent;
    message = msg.content;
    direct_mention = true;
    has_question = observation_has_question msg.content;
    message_chars = String.length msg.content;
    total_turns = meta.total_turns;
    active_goal_count = List.length meta.active_goal_ids;
    joined_room_count = List.length meta.joined_room_ids;
    room_scope = meta.room_scope;
    trigger_mode = meta.trigger_mode;
    last_turn_ago_s;
  }

let deterministic_policy_baseline_action (obs : keeper_policy_observation) : string =
  if obs.direct_mention then "reply_in_room" else "noop"

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
  try
    let start_idx = Str.search_forward (Str.regexp_string "[STATE]") reply 0 in
    let body_start = start_idx + String.length "[STATE]" in
    let end_idx =
      Str.search_forward (Str.regexp_string "[/STATE]") reply body_start
    in
    if end_idx <= body_start then None
    else Some (String.sub reply body_start (end_idx - body_start))
  with Not_found ->
    None

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

let latest_state_snapshot_from_messages (messages : Llm_client.message list) :
    keeper_state_snapshot option =
  let rec loop (msgs : Llm_client.message list) =
    match msgs with
    | [] -> None
    | msg :: rest ->
      match parse_state_snapshot_from_reply msg.content with
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
      n <> ""
      &&
      try
        let _ = Str.search_forward (Str.regexp_string n) hay 0 in
        true
      with Not_found -> false)
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
  match List.assoc_opt kind caps with
  | Some v -> v
  | None -> 1

let select_memory_candidates_by_profile
    ~(profile : string)
    (rows : (string * string * int) list) : (string * string * int) list =
  let total_cap = profile_total_cap profile in
  let kind_caps = profile_kind_caps profile in
  let used_by_kind : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let rec go acc = function
    | [] -> List.rev acc
    | _ when List.length acc >= total_cap -> List.rev acc
    | (kind, text, pr) :: rest ->
        let cap = cap_for_kind kind_caps kind in
        let used = Option.value ~default:0 (Hashtbl.find_opt used_by_kind kind) in
        if cap <= 0 || used >= cap then
          go acc rest
        else begin
          Hashtbl.replace used_by_kind kind (used + 1);
          go ((kind, text, pr) :: acc) rest
        end
  in
  go [] rows

let dedup_memory_candidates
    (items : (string * string * int) list) : (string * string * int) list =
  let seen : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.filter
    (fun (kind, text, _) ->
      let key =
        String.lowercase_ascii
          (String.trim kind ^ ":" ^ String.trim text)
      in
      if key = "" || Hashtbl.mem seen key then
        false
      else (
        Hashtbl.add seen key ();
        true))
    items

let normalize_memory_text_key (s : string) : string =
  s
  |> String.trim
  |> String.lowercase_ascii
  |> Str.global_replace (Str.regexp "[[:space:][:punct:]]+") ""

let is_meaningful_memory_text (s : string) : bool =
  let key = normalize_memory_text_key s in
  let placeholders = [
    "";
    "none";
    "null";
    "na";
    "nil";
    "없음";
    "없다";
    "없어요";
    "해당없음";
    "무";
    "미정";
  ] in
  not (List.mem key placeholders)

let memory_candidates_from_snapshot
    ~(soul_profile : string)
    (snapshot : keeper_state_snapshot) : (string * string * int) list =
  let profile =
    canonical_soul_profile soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let add_opt kind value acc =
    match value with
    | None -> acc
    | Some text ->
        let text = String.trim text in
        if text = "" || not (is_meaningful_memory_text text) then acc
        else
          ( kind,
            text,
            tuned_priority_for_candidate
              ~soul_profile:profile
              ~kind
              ~text )
          :: acc
  in
  let add_list kind values acc =
    List.fold_left
      (fun acc item ->
        let item = String.trim item in
        if item = "" || not (is_meaningful_memory_text item) then acc
        else
          ( kind,
            item,
            tuned_priority_for_candidate
              ~soul_profile:profile
              ~kind
              ~text:item )
          :: acc)
      acc values
  in
  let raw =
    []
    |> add_opt "goal" snapshot.goal
    |> add_opt "progress" snapshot.progress
    |> add_list "next" snapshot.next_items
    |> add_list "decision" snapshot.decisions
    |> add_list "open_question" snapshot.open_questions
    |> add_list "constraints" snapshot.constraints
    |> dedup_memory_candidates
    |> List.sort (fun (_, ta, pa) (_, tb, pb) ->
         let c = compare pb pa in
         if c <> 0 then c else String.compare ta tb)
  in
  select_memory_candidates_by_profile ~profile raw

type keeper_memory_row_raw = {
  json: Yojson.Safe.t;
  kind: string;
  text: string;
  priority: int;
  ts_unix: float;
}

let parse_memory_bank_row (line : string) : keeper_memory_row_raw option =
  try
    let j = Yojson.Safe.from_string line in
    let kind = Safe_ops.json_string ~default:"" "kind" j |> String.trim in
    let text = Safe_ops.json_string ~default:"" "text" j |> String.trim in
    let priority = Safe_ops.json_int ~default:0 "priority" j in
    let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
    if kind = "" || text = "" || not (is_meaningful_memory_text text) then
      None
    else
      Some { json = j; kind; text; priority; ts_unix }
  with Yojson.Json_error _ ->
    None

let memory_compaction_target_notes ~(profile : string) : int =
  let default_target =
    match profile with
    | "minimal" -> 80
    | "safety" -> 180
    | "delivery" -> 220
    | "research" -> 260
    | "relationship" -> 240
    | _ -> 220
  in
  let raw =
    Safe_ops.get_env_int_logged
      "MASC_KEEPER_MEMORY_MAX_NOTES"
      ~default:default_target
  in
  max 40 (min 4000 raw)

let memory_compaction_trigger_bytes ~(target_notes : int) : int =
  let default_trigger = max 120000 (target_notes * 360) in
  let raw =
    Safe_ops.get_env_int_logged
      "MASC_KEEPER_MEMORY_COMPACT_TRIGGER_BYTES"
      ~default:default_trigger
  in
  max 60000 (min 20000000 raw)

let memory_kind_caps_for_compaction
    ~(profile : string)
    ~(target_notes : int) : (string, int) Hashtbl.t =
  let tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let base_total = max 1 (profile_total_cap profile) in
  let scale = max 6 (target_notes / base_total) in
  List.iter
    (fun (kind, base_cap) ->
      let cap = max 8 ((base_cap * scale) + (scale / 3)) in
      Hashtbl.replace tbl kind cap)
    (profile_kind_caps profile);
  tbl

let memory_row_key (row : keeper_memory_row_raw) : string =
  String.lowercase_ascii (String.trim row.kind)
  ^ ":"
  ^ normalize_memory_text_key row.text

let write_memory_bank_rows
    (path : string)
    (rows : keeper_memory_row_raw list) : (unit, string) result =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    Common.protect
      ~module_name:"tool_keeper"
      ~finally_label:"close_out"
      ~finally:(fun () -> close_out_noerr oc)
      (fun () ->
        List.iter
          (fun (row : keeper_memory_row_raw) ->
            output_string oc (utf8_repair_string (Yojson.Safe.to_string row.json));
            output_char oc '\n')
          rows);
    Sys.rename tmp path;
    Ok ()
  with exn ->
    Safe_ops.remove_file_logged ~context:"memory_compaction" tmp;
    Error (Printf.sprintf "failed to rewrite memory bank: %s" (Printexc.to_string exn))

let compact_memory_bank_if_needed
    (config : Room.config)
    (meta : keeper_meta) : memory_bank_compaction =
  let profile =
    canonical_soul_profile meta.soul_profile
    |> Option.value ~default:default_soul_profile
  in
  let target_notes = memory_compaction_target_notes ~profile in
  let path = keeper_memory_bank_path config meta.name in
  if not (Sys.file_exists path) then
    { no_memory_bank_compaction with
      target_notes;
      reason = Some "missing_file";
    }
  else
    let size_bytes =
      try (Unix.stat path).st_size
      with Unix.Unix_error _ -> 0
    in
    let trigger_bytes = memory_compaction_trigger_bytes ~target_notes in
    if size_bytes < trigger_bytes then
      { no_memory_bank_compaction with
        target_notes;
        reason = Some "under_trigger_bytes";
      }
    else
      match Safe_ops.read_file_safe path with
      | Error _ ->
          { no_memory_bank_compaction with
            target_notes;
            reason = Some "read_failed";
          }
      | Ok content ->
          let lines =
            content
            |> String.split_on_char '\n'
            |> List.filter (fun s -> String.trim s <> "")
          in
          let parsed_rev = ref [] in
          let invalid = ref 0 in
          List.iter
            (fun line ->
              match parse_memory_bank_row line with
              | Some row -> parsed_rev := row :: !parsed_rev
              | None -> incr invalid)
            lines;
          let parsed = List.rev !parsed_rev in
          let before_notes = List.length parsed in
          if before_notes <= target_notes && !invalid = 0 then
            { no_memory_bank_compaction with
              target_notes;
              before_notes;
              after_notes = before_notes;
              reason = Some "under_target";
            }
          else
            let by_recency =
              List.sort
                (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                  let c = compare b.ts_unix a.ts_unix in
                  if c <> 0 then c else compare b.priority a.priority)
                parsed
            in
            let dedup_keys : (string, unit) Hashtbl.t = Hashtbl.create 1024 in
            let dedup_rev = ref [] in
            List.iter
              (fun (row : keeper_memory_row_raw) ->
                let key = memory_row_key row in
                if key <> "" && not (Hashtbl.mem dedup_keys key) then begin
                  Hashtbl.add dedup_keys key ();
                  dedup_rev := row :: !dedup_rev
                end)
              by_recency;
            let deduped = List.rev !dedup_rev in
            let dedup_dropped = max 0 (before_notes - List.length deduped) in
            if List.length deduped <= target_notes && dedup_dropped = 0 && !invalid = 0 then
              { no_memory_bank_compaction with
                target_notes;
                before_notes;
                after_notes = before_notes;
                reason = Some "already_compact";
              }
            else
              let kind_caps =
                memory_kind_caps_for_compaction ~profile ~target_notes
              in
              let kind_used : (string, int) Hashtbl.t = Hashtbl.create 16 in
              let selected_keys : (string, unit) Hashtbl.t = Hashtbl.create 1024 in
              let selected_rev = ref [] in
              let selected_count = ref 0 in
              let fallback_kind_cap = max 8 (target_notes / 8) in
              let add_row ~ignore_kind_cap (row : keeper_memory_row_raw) =
                if !selected_count >= target_notes then
                  ()
                else
                  let key = memory_row_key row in
                  if key = "" || Hashtbl.mem selected_keys key then
                    ()
                  else
                    let used =
                      Option.value ~default:0 (Hashtbl.find_opt kind_used row.kind)
                    in
                    let cap =
                      Option.value ~default:fallback_kind_cap
                        (Hashtbl.find_opt kind_caps row.kind)
                    in
                    if ignore_kind_cap || used < cap then begin
                      Hashtbl.add selected_keys key ();
                      Hashtbl.replace kind_used row.kind (used + 1);
                      selected_rev := row :: !selected_rev;
                      incr selected_count
                    end
              in
              let recent_floor = max 16 (min 64 (target_notes / 5)) in
              by_recency
              |> take recent_floor
              |> List.iter (fun row -> add_row ~ignore_kind_cap:false row);
              let by_priority =
                List.sort
                  (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                    let c = compare b.priority a.priority in
                    if c <> 0 then c else compare b.ts_unix a.ts_unix)
                  deduped
              in
              List.iter (fun row -> add_row ~ignore_kind_cap:false row) by_priority;
              if !selected_count < target_notes then
                List.iter (fun row -> add_row ~ignore_kind_cap:true row) by_recency;
              let selected =
                !selected_rev
                |> List.rev
                |> List.sort
                     (fun (a : keeper_memory_row_raw) (b : keeper_memory_row_raw) ->
                       let c = compare a.ts_unix b.ts_unix in
                       if c <> 0 then c else compare a.priority b.priority)
              in
              let after_notes = List.length selected in
              let dropped_notes = max 0 (before_notes - after_notes) in
              if dropped_notes = 0 && !invalid = 0 then
                { no_memory_bank_compaction with
                  target_notes;
                  before_notes;
                  after_notes;
                  dedup_dropped;
                  reason = Some "no_reduction";
                }
              else
                match write_memory_bank_rows path selected with
                | Error _ ->
                    { no_memory_bank_compaction with
                      target_notes;
                      before_notes;
                      after_notes = before_notes;
                      dedup_dropped;
                      invalid_dropped = !invalid;
                      reason = Some "write_failed";
                    }
                | Ok () ->
                    {
                      performed = true;
                      reason = Some "compacted";
                      target_notes;
                      before_notes;
                      after_notes;
                      dropped_notes;
                      dedup_dropped;
                      invalid_dropped = !invalid;
                    }

let append_memory_notes_from_reply
    (config : Room.config)
    (meta : keeper_meta)
    ~(turn : int)
    ~(reply : string) : (int * string list) =
  match parse_state_snapshot_from_reply reply with
  | None -> (0, [])
  | Some snapshot ->
      let notes =
        memory_candidates_from_snapshot
          ~soul_profile:meta.soul_profile snapshot
      in
      if notes = [] then
        (0, [])
      else
        let now_ts = Time_compat.now () in
        let path = keeper_memory_bank_path config meta.name in
        let kinds_acc = ref [] in
        let seen_kinds : (string, unit) Hashtbl.t = Hashtbl.create 8 in
        List.iter
          (fun (kind, text, priority) ->
            if not (Hashtbl.mem seen_kinds kind) then begin
              Hashtbl.add seen_kinds kind ();
              kinds_acc := kind :: !kinds_acc
            end;
            append_jsonl_line path
              (`Assoc
                [
                  ("ts", `String (now_iso ()));
                  ("ts_unix", `Float now_ts);
                  ("name", `String meta.name);
                  ("trace_id", `String meta.trace_id);
                  ("generation", `Int meta.generation);
                  ("turn", `Int turn);
                  ("soul_profile", `String meta.soul_profile);
                  ("kind", `String kind);
                  ("priority", `Int priority);
                  ("text", `String text);
                ]))
          notes;
        (List.length notes, List.rev !kinds_acc)

let summarize_memory_bank_lines
    (lines : string list)
    ~(recent_limit : int) : keeper_memory_summary =
  let parsed =
    lines
    |> List.filter_map (fun line ->
         try
           let j = Yojson.Safe.from_string line in
           let kind = Safe_ops.json_string ~default:"" "kind" j in
           let text = Safe_ops.json_string ~default:"" "text" j in
           let priority = Safe_ops.json_int ~default:0 "priority" j in
           let ts_unix = Safe_ops.json_float ~default:0.0 "ts_unix" j in
           let kind = String.trim kind in
           let text = String.trim text in
           if kind = "" || text = "" then None
           else Some { kind; text; priority; ts_unix }
         with Yojson.Json_error _ -> None)
  in
  let total_notes = List.length parsed in
  let last_ts_unix =
    parsed
    |> List.fold_left (fun acc (row : keeper_memory_line) ->
         max acc row.ts_unix)
         0.0
  in
  let kind_counts_tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let kind_priority_tbl : (string, int) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (row : keeper_memory_line) ->
      let cur = Option.value ~default:0 (Hashtbl.find_opt kind_counts_tbl row.kind) in
      Hashtbl.replace kind_counts_tbl row.kind (cur + 1);
      let pri_cur =
        Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl row.kind)
      in
      Hashtbl.replace kind_priority_tbl row.kind (max pri_cur row.priority))
    parsed;
  let kind_counts =
    kind_counts_tbl
    |> Hashtbl.to_seq
    |> List.of_seq
    |> List.sort (fun (ka, va) (kb, vb) ->
         let c = compare vb va in
         if c <> 0 then c
         else
           let pa =
             Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl ka)
           in
           let pb =
             Option.value ~default:min_int (Hashtbl.find_opt kind_priority_tbl kb)
           in
           let cp = compare pb pa in
           if cp <> 0 then cp else String.compare ka kb)
  in
  let top_kind =
    match kind_counts with
    | (kind, _) :: _ -> Some kind
    | [] -> None
  in
  let recent_notes =
    parsed
    |> List.rev
    |> take (max 0 recent_limit)
  in
  {
    total_notes;
    last_ts_unix;
    top_kind;
    kind_counts;
    recent_notes;
  }

let memory_summary_to_json (summary : keeper_memory_summary) : Yojson.Safe.t =
  `Assoc
    [
      ("total_notes", `Int summary.total_notes);
      ("last_ts_unix", `Float summary.last_ts_unix);
      ( "top_kind",
        match summary.top_kind with Some kind -> `String kind | None -> `Null );
      ( "kind_counts",
        `List
          (List.map
             (fun (kind, count) ->
               `Assoc [ ("kind", `String kind); ("count", `Int count) ])
             summary.kind_counts) );
      ( "recent_notes",
        `List
          (List.map
             (fun (row : keeper_memory_line) ->
               `Assoc
                 [
                   ("kind", `String row.kind);
                   ("text", `String row.text);
                   ("priority", `Int row.priority);
                   ("ts_unix", `Float row.ts_unix);
                 ])
             summary.recent_notes) );
    ]

let cost_usd_of_usage (usage : Llm_client.token_usage) (model : Llm_client.model_spec) : float =
  let input_cost = float_of_int usage.input_tokens *. model.cost_per_1k_input /. 1000.0 in
  let output_cost = float_of_int usage.output_tokens *. model.cost_per_1k_output /. 1000.0 in
  input_cost +. output_cost

let model_spec_for_used (specs : Llm_client.model_spec list) (model_used : string) :
  Llm_client.model_spec option =
  let used =
    if String.ends_with ~suffix:":latest" model_used then
      String.sub model_used 0 (String.length model_used - String.length ":latest")
    else
      model_used
  in
  List.find_opt (fun (m : Llm_client.model_spec) ->
    m.model_id = model_used || m.model_id = used
  ) specs

let read_file_tail_lines path ~max_bytes ~max_lines : string list =
  if max_lines <= 0 || max_bytes <= 0 then []
  else if not (Sys.file_exists path) then []
  else
    try
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let len = in_channel_length ic in
        let start = max 0 (len - max_bytes) in
        let starts_mid_line =
          if start <= 0 then false
          else (
            seek_in ic (start - 1);
            input_char ic <> '\n')
        in
        seek_in ic start;
        let remaining = len - start in
        let buf = Bytes.create remaining in
        really_input ic buf 0 remaining;
        let chunk = Bytes.to_string buf in
        let lines =
          chunk
          |> String.split_on_char '\n'
          |> List.filter (fun s -> String.trim s <> "")
        in
        let lines =
          match starts_mid_line, lines with
          | true, _ :: rest -> rest
          | _ -> lines
        in
        let n = List.length lines in
        let drop = max 0 (n - max_lines) in
        lines |> List.mapi (fun i s -> (i, s)) |> List.filter (fun (i, _) -> i >= drop) |> List.map snd
      )
    with Sys_error _ | End_of_file ->
      []

let read_keeper_memory_summary
    (config : Room.config)
    ~(name : string)
    ~(max_bytes : int)
    ~(max_lines : int)
    ~(recent_limit : int) : keeper_memory_summary =
  let lines =
    read_file_tail_lines
      (keeper_memory_bank_path config name)
      ~max_bytes
      ~max_lines
  in
  summarize_memory_bank_lines lines ~recent_limit

let is_memory_recall_query (s : string) : bool =
  let q = String.lowercase_ascii s in
  let needles = [
    "what did i ask";
    "first question";
    "before";
    "remember";
    "remembered";
    "do you remember";
    "memory";
    "기억";
    "기억해";
    "기억안나";
    "기억 안나";
    "기억나";
    "기억 나";
    "전에 뭐";
    "이전에";
    "첫 질문";
    "처음 물어";
    "뭐라고 물어봤";
  ] in
  List.exists (fun n ->
    try
      let _ = Str.search_forward (Str.regexp_string n) q 0 in
      true
    with Not_found -> false
  ) needles

let expected_topic_hint (s : string) : string option =
  let q = String.lowercase_ascii s in
  let has_ko needle =
    try let _ = Str.search_forward (Str.regexp_string needle) s 0 in true with Not_found -> false
  in
  let has_en needle =
    try let _ = Str.search_forward (Str.regexp_string needle) q 0 in true with Not_found -> false
  in
  if (try let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in true with Not_found -> false)
     || (try let _ = Str.search_forward (Str.regexp_string "weather") q 0 in true with Not_found -> false)
  then
    Some "weather"
  else if has_ko "첫 질문"
       || has_en "first question"
       || has_en "very first"
       || has_en "earliest"
       || ((has_ko "처음" || has_ko "첫" || has_en "first")
           && (has_ko "질문" || has_ko "물어" || has_en "question" || has_en "ask"))
  then
    Some "first_question"
  else
    None

let normalize_for_similarity (s : string) : string list =
  let s = String.lowercase_ascii s in
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let code = Char.code c in
    let keep =
      (c >= 'a' && c <= 'z') ||
      (c >= '0' && c <= '9') ||
      code >= 128
    in
    if not keep then Bytes.set b i ' '
  done;
  let words =
    Bytes.to_string b
    |> String.split_on_char ' '
    |> List.filter (fun w -> String.length w >= 2)
  in
  let tbl : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  List.filter (fun w ->
    if Hashtbl.mem tbl w then false
    else (Hashtbl.add tbl w (); true)
  ) words

let jaccard_similarity (a : string) (b : string) : float =
  let ta = normalize_for_similarity a in
  let tb = normalize_for_similarity b in
  if ta = [] && tb = [] then 1.0
  else if ta = [] || tb = [] then 0.0
  else
    let h : (string, bool) Hashtbl.t = Hashtbl.create 64 in
    List.iter (fun w -> Hashtbl.replace h w false) ta;
    let inter = ref 0 in
    let uniq_b = ref 0 in
    List.iter (fun w ->
      if Hashtbl.mem h w then begin
        if not (Hashtbl.find h w) then begin
          incr inter;
          Hashtbl.replace h w true
        end
      end else
        incr uniq_b
    ) tb;
    let union = (List.length ta) + !uniq_b in
    if union = 0 then 0.0 else float_of_int !inter /. float_of_int union

let latest_message_content_by_role
    ~(role : Llm_client.role)
    (messages : Llm_client.message list) : string option =
  match
    messages
    |> List.rev
    |> List.find_opt (fun (m : Llm_client.message) -> m.role = role)
  with
  | None -> None
  | Some m -> trim_nonempty (String.trim m.content)

let previous_assistant_message_content
    (messages : Llm_client.message list) : string option =
  let assistants =
    messages
    |> List.rev
    |> List.filter_map (fun (m : Llm_client.message) ->
         if m.role = Llm_client.Assistant then trim_nonempty m.content else None)
  in
  match assistants with
  | _latest :: previous :: _ -> Some previous
  | _ -> None

let goal_horizon_candidates (meta : keeper_meta) : string list =
  [meta.short_goal; meta.mid_goal; meta.long_goal; meta.goal]
  |> List.filter_map (fun raw ->
       raw
       |> normalize_goal_horizon_text
       |> trim_nonempty)
  |> List.fold_left
       (fun acc goal ->
         let key = normalize_memory_text_key goal in
         if List.exists (fun existing -> normalize_memory_text_key existing = key) acc then
           acc
         else
           goal :: acc)
       []
  |> List.rev

let best_goal_similarity ~(text : string) ~(goals : string list) : float =
  if goals = [] then 0.0
  else
    let candidate = String.trim text in
    if candidate = "" then 0.0
    else
      goals
      |> List.fold_left
           (fun best goal -> max best (jaccard_similarity candidate goal))
           0.0

let goal_alignment_score
    ~(meta : keeper_meta)
    ~(user_message : string option)
    ~(assistant_reply : string option) : float =
  let goals = goal_horizon_candidates meta in
  if goals = [] then 0.0
  else
    let user_score =
      match user_message with
      | None -> None
      | Some text -> Some (best_goal_similarity ~text ~goals)
    in
    let reply_score =
      match assistant_reply with
      | None -> None
      | Some text -> Some (best_goal_similarity ~text ~goals)
    in
    match user_score, reply_score with
    | None, None -> 0.0
    | Some s, None | None, Some s -> s
    | Some u, Some r -> (u +. r) /. 2.0

let repetition_risk_score
    ~(messages : Llm_client.message list)
    ~(candidate_reply : string option) : float =
  match candidate_reply with
  | Some reply -> (
      match latest_message_content_by_role ~role:Llm_client.Assistant messages with
      | Some prev -> jaccard_similarity reply prev
      | None -> 0.0)
  | None -> (
      match
        previous_assistant_message_content messages,
        latest_message_content_by_role ~role:Llm_client.Assistant messages
      with
      | Some prev, Some latest -> jaccard_similarity latest prev
      | _ -> 0.0)

type keeper_auto_rule_eval = {
  repetition_risk: float;
  goal_alignment: float;
  response_alignment: float;
  goal_drift: float;
  reflect: bool;
  plan: bool;
  compact: bool;
  handoff: bool;
  guardrail_stop: bool;
  guardrail_reason: string option;
  reasons: string list;
}

let keeper_auto_rule_eval_to_json (e : keeper_auto_rule_eval) : Yojson.Safe.t =
  `Assoc [
    ("repetition_risk", `Float e.repetition_risk);
    ("goal_alignment", `Float e.goal_alignment);
    ("response_alignment", `Float e.response_alignment);
    ("goal_drift", `Float e.goal_drift);
    ("reflect", `Bool e.reflect);
    ("plan", `Bool e.plan);
    ("compact", `Bool e.compact);
    ("handoff", `Bool e.handoff);
    ("guardrail_stop", `Bool e.guardrail_stop);
    ("guardrail_reason",
      match e.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("reasons", `List (List.map (fun reason -> `String reason) e.reasons));
  ]

let keeper_reflection_payload_of_auto_rules (e : keeper_auto_rule_eval) : Yojson.Safe.t =
  let actions_rev = [] in
  let actions_rev =
    if e.reflect then `String "reflect" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.plan then `String "plan" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.compact then `String "compact" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.handoff then `String "handoff" :: actions_rev else actions_rev
  in
  let actions_rev =
    if e.guardrail_stop then `String "guardrail_stop" :: actions_rev else actions_rev
  in
  let has_action = actions_rev <> [] in
  `Assoc [
    ("triggered", `Bool has_action);
    ("actions", `List (List.rev actions_rev));
    ("guardrail_stop", `Bool e.guardrail_stop);
    ("guardrail_reason",
      match e.guardrail_reason with
      | Some reason -> `String reason
      | None -> `Null);
    ("goal_drift", `Float e.goal_drift);
    ("repetition_risk", `Float e.repetition_risk);
    ("goal_alignment", `Float e.goal_alignment);
    ("response_alignment", `Float e.response_alignment);
    ("reasons", `List (List.map (fun reason -> `String reason) e.reasons));
  ]

let evaluate_keeper_auto_rules
    ~(meta : keeper_meta)
    ~(context_ratio : float)
    ~(message_count : int)
    ~(token_count : int)
    ~(repetition_risk : float)
    ~(goal_alignment : float)
    ~(response_alignment : float) : keeper_auto_rule_eval =
  let ratio_gate = meta.compaction_ratio_gate in
  let message_gate = meta.compaction_message_gate in
  let token_gate = meta.compaction_token_gate in
  let reflect_threshold = keeper_rule_reflect_repetition_threshold () in
  let plan_goal_alignment_threshold = keeper_rule_plan_goal_alignment_threshold () in
  let plan_response_alignment_threshold = keeper_rule_plan_response_alignment_threshold () in
  let guardrail_repetition_threshold = keeper_rule_guardrail_repetition_threshold () in
  let guardrail_goal_alignment_threshold = keeper_rule_guardrail_goal_alignment_threshold () in
  let guardrail_response_alignment_threshold = keeper_rule_guardrail_response_alignment_threshold () in
  let guardrail_context_threshold =
    max ratio_gate (keeper_rule_guardrail_context_threshold ())
  in
  let goal_drift =
    1.0 -. max 0.0 (min 1.0 (max goal_alignment response_alignment))
    |> max 0.0
    |> min 1.0
  in
  let reflect = repetition_risk >= reflect_threshold in
  let plan =
    goal_alignment <= plan_goal_alignment_threshold
    && response_alignment <= plan_response_alignment_threshold
  in
  let compact =
    context_ratio >= ratio_gate
    || (message_gate > 0 && message_count >= message_gate)
    || (token_gate > 0 && token_count >= token_gate)
  in
  let handoff = meta.auto_handoff && context_ratio >= meta.handoff_threshold in
  let guardrail_stop =
    repetition_risk >= guardrail_repetition_threshold
    && goal_alignment <= guardrail_goal_alignment_threshold
    && response_alignment <= guardrail_response_alignment_threshold
    && context_ratio >= guardrail_context_threshold
  in
  let guardrail_reason =
    if guardrail_stop then
      Some
        (Printf.sprintf
           "guardrail_stop(rep=%.3f>=%.3f,goal=%.3f<=%.3f,response=%.3f<=%.3f,ctx=%.3f>=%.3f)"
           repetition_risk
           guardrail_repetition_threshold
           goal_alignment
           guardrail_goal_alignment_threshold
           response_alignment
           guardrail_response_alignment_threshold
           context_ratio
           guardrail_context_threshold)
    else
      None
  in
  let reasons = [] in
  let reasons =
    if reflect then
      (Printf.sprintf
         "reflect(repetition_risk=%.3f>=%.3f)"
         repetition_risk
         reflect_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if plan then
      (Printf.sprintf
         "plan(goal_alignment=%.3f<=%.3f,response_alignment=%.3f<=%.3f)"
         goal_alignment
         plan_goal_alignment_threshold
         response_alignment
         plan_response_alignment_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    if compact then
      (Printf.sprintf
         "compact(ctx=%.3f,msg=%d,tokens=%d)"
         context_ratio
         message_count
         token_count)
      :: reasons
    else reasons
  in
  let reasons =
    if handoff then
      (Printf.sprintf
         "handoff(ctx=%.3f>=%.3f)"
         context_ratio
         meta.handoff_threshold)
      :: reasons
    else reasons
  in
  let reasons =
    match guardrail_reason with
    | Some reason -> reason :: reasons
    | None -> reasons
  in
  {
    repetition_risk;
    goal_alignment;
    response_alignment;
    goal_drift;
    reflect;
    plan;
    compact;
    handoff;
    guardrail_stop;
    guardrail_reason;
    reasons = List.rev reasons;
  }

let learned_policy_auto_rules
    ~(meta : keeper_meta)
    ~(context_ratio : float)
    ~(message_count : int)
    ~(token_count : int)
    ~(repetition_risk : float)
    ~(goal_alignment : float)
    ~(response_alignment : float) : keeper_auto_rule_eval =
  let ratio_gate = meta.compaction_ratio_gate in
  let message_gate = meta.compaction_message_gate in
  let token_gate = meta.compaction_token_gate in
  let goal_drift =
    1.0 -. max 0.0 (min 1.0 (max goal_alignment response_alignment))
    |> max 0.0
    |> min 1.0
  in
  let compact =
    context_ratio >= ratio_gate
    || (message_gate > 0 && message_count >= message_gate)
    || (token_gate > 0 && token_count >= token_gate)
  in
  let handoff = meta.auto_handoff && context_ratio >= meta.handoff_threshold in
  {
    repetition_risk;
    goal_alignment;
    response_alignment;
    goal_drift;
    reflect = false;
    plan = false;
    compact;
    handoff;
    guardrail_stop = false;
    guardrail_reason = None;
    reasons =
      [
        "policy_mode=learned_offline_v1";
        (if compact then "compact_safety_gate=true" else "compact_safety_gate=false");
        (if handoff then "handoff_safety_gate=true" else "handoff_safety_gate=false");
      ];
  }

let recent_user_messages (msgs : Llm_client.message list) ~(max_n : int) : string list =
  msgs
  |> List.rev
  |> List.filter_map (fun (m : Llm_client.message) ->
       if m.role = Llm_client.User then
         let c = String.trim m.content in
         if c = "" then None else Some c
       else None)
  |> take max_n

type memory_recall_eval = {
  performed: bool;
  query_kind: string;
  expected_topic: string option;
  candidate_count: int;
  initial_score: float;
  final_score: float;
  threshold: float;
  passed: bool;
  best_match: string option;
}

let evaluate_memory_recall
    ~(user_message : string)
    ~(assistant_reply : string)
    ~(candidates : string list) : memory_recall_eval =
  let recall = is_memory_recall_query user_message in
  let expected_topic = expected_topic_hint user_message in
  let has_weather_word (s : string) =
    let q = String.lowercase_ascii s in
    (try let _ = Str.search_forward (Str.regexp_string "날씨") s 0 in true with Not_found -> false)
    || (try let _ = Str.search_forward (Str.regexp_string "weather") q 0 in true with Not_found -> false)
  in
  let threshold =
    match expected_topic with
    | Some "weather" -> 0.15
    | _ -> 0.18
  in
  if not recall then
    {
      performed = false;
      query_kind = "none";
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = true;
      best_match = None;
    }
  else if candidates = [] then
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = 0;
      initial_score = 0.0;
      final_score = 0.0;
      threshold;
      passed = false;
      best_match = None;
    }
  else
    let weather_candidates = List.filter has_weather_word candidates in
    let candidates_for_general =
      match expected_topic with
      | Some "weather" when weather_candidates <> [] -> weather_candidates
      | _ -> candidates
    in
    let oldest_candidate =
      match List.rev candidates with
      | c :: _ -> Some c
      | [] -> None
    in
    let (best_msg, best_score) =
      match expected_topic, oldest_candidate with
      | Some "first_question", Some target ->
          (Some target, jaccard_similarity assistant_reply target)
      | _ ->
          List.fold_left (fun (best_m, best_s) cand ->
            let score = jaccard_similarity assistant_reply cand in
            if score > best_s then (Some cand, score) else (best_m, best_s)
          ) (None, 0.0) candidates_for_general
    in
    let topic_bonus =
      match expected_topic with
      | Some "weather" ->
          let has_weather_reply = has_weather_word assistant_reply in
          if has_weather_reply then 0.08 else -.0.08
      | Some "first_question" ->
          let has_first =
            (try let _ = Str.search_forward (Str.regexp_string "첫") assistant_reply 0 in true with Not_found -> false)
            || (try let _ = Str.search_forward (Str.regexp_string "first") (String.lowercase_ascii assistant_reply) 0 in true with Not_found -> false)
          in
          if has_first then 0.05 else -.0.05
      | _ -> 0.0
    in
    let final_score = max 0.0 (min 1.0 (best_score +. topic_bonus)) in
    {
      performed = true;
      query_kind = Option.value ~default:"recall" expected_topic;
      expected_topic;
      candidate_count = List.length candidates;
      initial_score = best_score;
      final_score;
      threshold;
      passed = final_score >= threshold;
      best_match = best_msg;
    }

let memory_eval_to_json
    (e : memory_recall_eval)
    ~(correction_applied : bool)
    ~(correction_success : bool)
    ~(correction_skipped_budget : bool)
    ~(prompt_fallback_applied : bool)
    ~(prompt_fallback_success : bool)
    ~(prompt_fallback_skipped_budget : bool)
    ~(postpass_budget_ms : int)
    ~(postpass_budget_remaining_ms : int)
    ~(recall_fallback_applied : bool) : Yojson.Safe.t =
  `Assoc [
    ("performed", `Bool e.performed);
    ("query_kind", `String e.query_kind);
    ("expected_topic", match e.expected_topic with Some t -> `String t | None -> `Null);
    ("candidate_count", `Int e.candidate_count);
    ("initial_score", `Float e.initial_score);
    ("final_score", `Float e.final_score);
    ("threshold", `Float e.threshold);
    ("passed", `Bool e.passed);
    ("best_match", match e.best_match with Some m -> `String m | None -> `Null);
    ("correction_applied", `Bool correction_applied);
    ("correction_success", `Bool correction_success);
    ("correction_skipped_budget", `Bool correction_skipped_budget);
    ("prompt_fallback_applied", `Bool prompt_fallback_applied);
    ("prompt_fallback_success", `Bool prompt_fallback_success);
    ("prompt_fallback_skipped_budget", `Bool prompt_fallback_skipped_budget);
    ("postpass_budget_ms", `Int postpass_budget_ms);
    ("postpass_budget_remaining_ms", `Int postpass_budget_remaining_ms);
    ("deterministic_fallback_applied", `Bool recall_fallback_applied);
    ("recall_fallback_applied", `Bool recall_fallback_applied);
  ]

let work_kind_of_eval (e : memory_recall_eval) : string =
  if e.performed then
    if e.query_kind <> "" && e.query_kind <> "none" then
      e.query_kind
    else
      "memory_recall"
  else
    match e.expected_topic with
    | Some "weather" -> "weather_answer"
    | Some "first_question" -> "first_question_answer"
    | Some topic when topic <> "" -> topic
    | _ -> "general_chat"

(* Tool definitions moved to Tool_shard for dynamic composition.
   This alias maintains backward compatibility. *)
