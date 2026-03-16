(** Gardener — Self-Organizing Agent Ecosystem Manager (OAS-integrated).

    Implements autonomous management of the agent ecosystem:
    - Health monitoring with homeostatic balance
    - Spawn decisions based on gap signals and ecosystem needs
    - Retirement decisions for idle/redundant agents
    - Background loop with circuit breaker protection

    Design principles:
    - {b Inverse-U Reward}: Both over- and under-population are penalized
    - {b Safety First}: Hard limits, budgets, cooldowns, circuit breaker
    - {b LLM-Assisted}: Complex decisions can use LLM for nuanced judgment

    OAS integration: exports Agent Card, publishes events via Event_bus,
    uses Pulse for tick scheduling (replaces raw Eio.Time.sleep loop). *)

[@@@warning "-32-69"]

open Gardener_types

(* ââ OAS Agent Card âââââââââââââââââââââââââââââââââââââââââ *)

let agent_card : Agent_card.agent_card = {
  name = "gardener";
  version = "2.95.1";
  description = Some "Self-organizing agent ecosystem manager: spawn, retire, homeostatic balance";
  provider = Some { organization = "MASC"; url = None };
  protocol_versions = ["0.3"];
  capabilities = { streaming = false; push_notifications = false; extended_agent_card = false };
  skills = [
    { id = "health-monitor"; name = "Health Monitor";
      description = Some "Calculate ecosystem health metrics and homeostatic score";
      tags = ["monitoring"]; tool_count = 1;
      input_modes = []; output_modes = ["application/json"] };
    { id = "spawn-decision"; name = "Spawn Decision";
      description = Some "Evaluate and execute agent spawn proposals";
      tags = ["lifecycle"]; tool_count = 2;
      input_modes = ["application/json"]; output_modes = ["application/json"] };
    { id = "retire-decision"; name = "Retire Decision";
      description = Some "Evaluate and execute agent retirement proposals";
      tags = ["lifecycle"]; tool_count = 2;
      input_modes = ["application/json"]; output_modes = ["application/json"] };
  ];
  supported_interfaces = [];
  security_schemes = [];
  default_input_modes = ["application/json"];
  default_output_modes = ["application/json"];
  extensions = [];
  signatures = [];
  icon_url = None;
  documentation_url = None;
  created_at = "2026-03-16T00:00:00Z";
  updated_at = "2026-03-16T00:00:00Z";
}

(* ââ Event_bus + Pulse refs ââââââââââââââââââââââââââââââââââââââ *)

let bus_ref : Agent_sdk.Event_bus.t option ref = ref None
let gardener_pulse_ref : Pulse.t option ref = ref None

let publish_event name payload =
  match !bus_ref with
  | Some bus ->
      Agent_sdk.Event_bus.publish bus
        (Agent_sdk.Event_bus.Custom (name, payload))
  | None -> ()

(** {1 Configuration Loading} *)

let load_config () : gardener_config = {
  enabled = Env_config.Gardener.enabled;
  min_agents = Env_config.Gardener.min_agents;
  max_agents = Env_config.Gardener.max_agents;
  target_agents = Env_config.Gardener.target_agents;
  max_daily_spawns = Env_config.Gardener.max_daily_spawns;
  max_daily_retirements = Env_config.Gardener.max_daily_retirements;
  spawn_cooldown_sec = Env_config.Gardener.spawn_cooldown_sec;
  retirement_cooldown_sec = Env_config.Gardener.retirement_cooldown_sec;
  use_llm_decision = Env_config.Gardener.use_llm_decision;
  gap_maturity_hours = Env_config.Gardener.gap_maturity_hours;
  idle_threshold_hours = Env_config.Gardener.idle_threshold_hours;
  retirement_grace_sec = Env_config.Gardener.retirement_grace_sec;
  max_consecutive_failures = Env_config.Gardener.max_consecutive_failures;
  circuit_cooldown_sec = Env_config.Gardener.circuit_cooldown_sec;
  check_interval_sec = Env_config.Gardener.check_interval_sec;
}

(** {1 Global State}

    State is lazily initialized on first access (single-threaded safe).
    Lock is created in [start] before any concurrent access.
    Lock protects mutable field updates, not initialization.
*)

let gardener_state_ref : gardener_state option ref = ref None
let gardener_lock : Eio.Mutex.t option ref = ref None
let room_config_ref : Room_utils.config option ref = ref None

(** Execute [f] with lock if available, otherwise directly.
    Safe for single-threaded test scenarios (no Eio runtime). *)
let with_lock f =
  match !gardener_lock with
  | Some mutex -> Eio.Mutex.use_rw ~protect:true mutex f
  | None -> f ()  (* Test mode: no concurrent access expected *)

(** Get or create the singleton state.
    Initialization is NOT locked — safe because:
    1. In production, [start] creates lock before forking fibers
    2. In tests, single-threaded access means no race
    3. Worst case: double init creates identical state *)
let get_state () =
  match !gardener_state_ref with
  | Some s -> s
  | None ->
      let s = make_gardener_state () in
      gardener_state_ref := Some s;
      s

let iso_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let json_string_of_float_ts ts =
  if ts > 0.0 then `String (iso_of_unix ts) else `Null

let json_string_of_opt_ts = function
  | Some ts when ts > 0.0 -> `String (iso_of_unix ts)
  | _ -> `Null

let json_string_of_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then `Null else `String trimmed

type decision_snapshot = {
  intervention : intervention;
  source : string;
  reason : string;
  target : string;
  error : string;
}

let intervention_name = function
  | NeedSpawn _ -> "need_spawn"
  | NeedWorker _ -> "need_worker"
  | NeedRetirement _ -> "need_retirement"
  | Balanced -> "balanced"

let intervention_target = function
  | NeedSpawn gap -> gap.topic
  | NeedRetirement stats -> stats.name
  | NeedWorker _ | Balanced -> ""

let mark_tick_start () =
  let now = Time_compat.now () in
  with_lock (fun () ->
      let state = get_state () in
      state.tick_count <- state.tick_count + 1;
      state.last_tick_started_at <- now;
      state.last_error <- "";
      state.last_action <- "none";
      state.last_target <- "";
      state.last_reason <- "";
      state.last_intervention <- "none";
      state.last_decision_source <- "none");
  now

let record_health_summary ~(at : float) (health : ecosystem_health) =
  with_lock (fun () ->
      let state = get_state () in
      state.last_health_check <- at;
      state.last_total_agents <- health.total_agents;
      state.last_active_agents <- health.active_agents;
      state.last_idle_agents <- health.idle_agents;
      state.last_todo_count <- health.task_backlog.todo_count;
      state.last_high_priority_todo <- health.task_backlog.high_priority_todo;
      state.last_orphan_count <- health.task_backlog.orphan_count;
      state.last_homeostatic_score <- health.homeostatic_score;
      state.last_needs_workers <- health.needs_workers)

let record_decision (decision : decision_snapshot) =
  with_lock (fun () ->
      let state = get_state () in
      state.last_intervention <- intervention_name decision.intervention;
      state.last_decision_source <- decision.source;
      state.last_reason <- decision.reason;
      state.last_target <- decision.target;
      if String.trim decision.error <> "" then state.last_error <- decision.error)

let record_action ?target ?reason ?error action =
  with_lock (fun () ->
      let state = get_state () in
      state.last_action <- action;
      (match target with Some value when String.trim value <> "" -> state.last_target <- value | _ -> ());
      (match reason with Some value when String.trim value <> "" -> state.last_reason <- value | _ -> ());
      (match error with Some value when String.trim value <> "" -> state.last_error <- value | _ -> ()))

let record_tick_complete () =
  let now = Time_compat.now () in
  with_lock (fun () ->
      let state = get_state () in
      state.last_tick_completed_at <- now)

(** {1 Circuit Breaker} *)

let is_circuit_open () =
  let state = get_state () in
  match state.circuit_open_until with
  | None -> false
  | Some until -> Time_compat.now () < until

let trip_circuit ~config =
  let state = get_state () in
  state.consecutive_failures <- state.consecutive_failures + 1;
  if state.consecutive_failures >= config.max_consecutive_failures then begin
    let until = Time_compat.now () +. config.circuit_cooldown_sec in
    state.circuit_open_until <- Some until;
    Eio.traceln "[Gardener] Circuit OPEN until %.0f (consecutive failures: %d)"
      until state.consecutive_failures
  end

let reset_circuit () =
  let state = get_state () in
  state.consecutive_failures <- 0;
  state.circuit_open_until <- None

(** {1 Budget Management} *)

let reset_daily_budgets_if_needed () =
  let state = get_state () in
  let now = Time_compat.now () in
  let day_elapsed = now -. state.day_start in
  if day_elapsed > 86400.0 then begin
    state.day_start <- now;
    state.spawns_today <- 0;
    state.retirements_today <- 0;
    Eio.traceln "[Gardener] Daily budgets reset"
  end

let can_spawn ~config =
  reset_daily_budgets_if_needed ();
  let state = get_state () in
  let now = Time_compat.now () in
  let cooldown_ok = (now -. state.last_spawn_attempt) > config.spawn_cooldown_sec in
  let budget_ok = state.spawns_today < config.max_daily_spawns in
  let circuit_ok = not (is_circuit_open ()) in
  cooldown_ok && budget_ok && circuit_ok

let can_retire ~config =
  reset_daily_budgets_if_needed ();
  let state = get_state () in
  let now = Time_compat.now () in
  let cooldown_ok = (now -. state.last_retirement_attempt) > config.retirement_cooldown_sec in
  let budget_ok = state.retirements_today < config.max_daily_retirements in
  let circuit_ok = not (is_circuit_open ()) in
  cooldown_ok && budget_ok && circuit_ok

let record_spawn () =
  let state = get_state () in
  state.spawns_today <- state.spawns_today + 1;
  state.last_spawn_attempt <- Time_compat.now ()

let record_retirement () =
  let state = get_state () in
  state.retirements_today <- state.retirements_today + 1;
  state.last_retirement_attempt <- Time_compat.now ()

(** {1 Agent Statistics Conversion} *)

(** Convert Lodge_selection stats to Gardener stats *)
let convert_stats (ls : Lodge_selection.agent_stats) : agent_stats =
  let now = Time_compat.now () in
  let idle_hours = (now -. ls.last_selected_at) /. 3600.0 in
  {
    name = ls.name;
    posts_24h = ls.posts_created;  (* Approximation — actual 24h needs board query *)
    comments_24h = ls.comments_created;
    votes_received_24h = ls.total_votes_up;
    last_active = ls.last_selected_at;
    idle_hours;
    thompson_alpha = ls.alpha;
    thompson_beta = ls.beta;
  }

(** {1 Health Calculation} *)

(** Calculate Shannon entropy of selection distribution *)
let calculate_entropy (stats_list : Lodge_selection.agent_stats list) : float =
  if List.length stats_list = 0 then 0.0
  else begin
    let total_selections = List.fold_left (fun acc s -> acc + s.Lodge_selection.selections) 0 stats_list in
    if total_selections = 0 then 0.0
    else begin
      let probabilities = List.map (fun s ->
        float_of_int s.Lodge_selection.selections /. float_of_int total_selections
      ) stats_list in
      let entropy = List.fold_left (fun acc p ->
        if p > 0.0 then acc -. (p *. Float.log2 p) else acc
      ) 0.0 probabilities in
      (* Normalize by max entropy (uniform distribution) *)
      let max_entropy = Float.log2 (float_of_int (List.length stats_list)) in
      if max_entropy > 0.0 then entropy /. max_entropy else 0.0
    end
  end

(** Calculate homeostatic score using inverse-U curve *)
let calculate_homeostatic_score ~config ~total_agents : float =
  let target = float_of_int config.target_agents in
  let current = float_of_int total_agents in
  let deviation = Float.abs (current -. target) in
  let max_deviation = Float.max
    (target -. float_of_int config.min_agents)
    (float_of_int config.max_agents -. target) in
  if max_deviation <= 0.0 then 1.0
  else Float.max 0.0 (1.0 -. (deviation /. max_deviation))

(** {1 String Similarity (Levenshtein Distance)} *)

(** Calculate Levenshtein edit distance between two strings.
    Returns the minimum number of single-character edits needed. *)
let levenshtein s1 s2 =
  let len1, len2 = String.length s1, String.length s2 in
  if len1 = 0 then len2
  else if len2 = 0 then len1
  else begin
    let matrix = Array.make_matrix (len1 + 1) (len2 + 1) 0 in
    for i = 0 to len1 do matrix.(i).(0) <- i done;
    for j = 0 to len2 do matrix.(0).(j) <- j done;
    for i = 1 to len1 do
      for j = 1 to len2 do
        let cost = if s1.[i-1] = s2.[j-1] then 0 else 1 in
        matrix.(i).(j) <- min (min
          (matrix.(i-1).(j) + 1)      (* deletion *)
          (matrix.(i).(j-1) + 1))     (* insertion *)
          (matrix.(i-1).(j-1) + cost) (* substitution *)
      done
    done;
    matrix.(len1).(len2)
  end

(** Normalized similarity score (0.0 to 1.0) based on Levenshtein distance *)
let string_similarity s1 s2 =
  let dist = levenshtein (String.lowercase_ascii s1) (String.lowercase_ascii s2) in
  let max_len = max (String.length s1) (String.length s2) in
  if max_len = 0 then 1.0 else 1.0 -. (float_of_int dist /. float_of_int max_len)

(** {1 Topic Extraction} *)

(** Common stop words to filter out *)
let stop_words = [
  "the"; "a"; "an"; "is"; "are"; "was"; "were"; "be"; "been"; "being";
  "have"; "has"; "had"; "do"; "does"; "did"; "will"; "would"; "could"; "should";
  "and"; "or"; "but"; "if"; "then"; "else"; "when"; "where"; "why"; "how";
  "this"; "that"; "these"; "those"; "it"; "its"; "to"; "of"; "in"; "for";
  "on"; "with"; "at"; "by"; "from"; "as"; "into"; "through"; "during";
  "i"; "we"; "you"; "he"; "she"; "they"; "me"; "us"; "him"; "her"; "them";
  "what"; "which"; "who"; "whom"; "whose"; "my"; "your"; "our"; "their";
  (* Korean particles and common words *)
  "은"; "는"; "이"; "가"; "을"; "를"; "의"; "에"; "에서"; "로"; "으로";
  "와"; "과"; "도"; "만"; "부터"; "까지"; "처럼"; "같이"; "보다";
]

(** Extract potential topics from text (simple word frequency) *)
let extract_topics_from_text text =
  (* Split by whitespace and punctuation *)
  let words = String.split_on_char ' ' text
    |> List.concat_map (String.split_on_char '\n')
    |> List.concat_map (String.split_on_char '\t')
    |> List.map String.trim
    |> List.map String.lowercase_ascii
    |> List.filter (fun w -> String.length w > 2)
    |> List.filter (fun w -> not (List.mem w stop_words))
  in
  (* Count frequencies *)
  let counts = Hashtbl.create 50 in
  List.iter (fun w ->
    let c = try Hashtbl.find counts w with Not_found -> 0 in
    Hashtbl.replace counts w (c + 1)
  ) words;
  (* Return sorted by frequency *)
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) counts []
  |> List.sort (fun (_, c1) (_, c2) -> compare c2 c1)

(** Calculate topic coverage from Board posts *)
let calculate_topic_coverage ~posts : (string * float) list =
  if List.length posts = 0 then []
  else begin
    (* Aggregate all post content *)
    let all_text = posts
      |> List.map (fun (p : Board.post) -> p.content)
      |> String.concat " "
    in
    let topics = extract_topics_from_text all_text in
    let total_words = List.fold_left (fun acc (_, c) -> acc + c) 0 topics in
    if total_words = 0 then []
    else
      (* Take top 10 topics, normalize to 0-1 coverage score *)
      topics
      |> (fun l -> List.filteri (fun i _ -> i < 10) l)
      |> List.map (fun (topic, count) ->
          (topic, float_of_int count /. float_of_int total_words *. 10.0))  (* Scale up *)
  end

(** {1 Overload Detection} *)

(** Daily action limit per agent (posts + comments) *)
let daily_action_limit = 20

(** Count overloaded agents (agents exceeding daily action limit) *)
let count_overloaded_agents ~posts ~comments ~now : int =
  (* Build per-agent action counts for last 24h *)
  let agent_actions = Hashtbl.create 20 in
  let day_ago = now -. 86400.0 in

  (* Count posts per agent *)
  List.iter (fun (p : Board.post) ->
    if p.created_at > day_ago then begin
      let author = p.author in
      let c = try Hashtbl.find agent_actions author with Not_found -> 0 in
      Hashtbl.replace agent_actions author (c + 1)
    end
  ) posts;

  (* Count comments per agent *)
  List.iter (fun (cm : Board.comment) ->
    if cm.created_at > day_ago then begin
      let author = cm.author in
      let c = try Hashtbl.find agent_actions author with Not_found -> 0 in
      Hashtbl.replace agent_actions author (c + 1)
    end
  ) comments;

  (* Count agents exceeding limit *)
  Hashtbl.fold (fun _ count acc ->
    if count > daily_action_limit then acc + 1 else acc
  ) agent_actions 0

(** {1 Board Analysis} *)

(** Count unanswered questions from Board — O(n) using Hashtbl *)
let count_unanswered_questions () : int =
  let store = Board.global () in
  let posts = Board.list_posts store ~limit:100 () in
  let all_comments = Board.list_comments store ~limit:1000 () in
  (* Build a set of post_ids that have comments — O(n) insertion *)
  let posts_with_comments = Hashtbl.create (List.length all_comments) in
  List.iter (fun (c : Board.comment) ->
    let pid = Board.Post_id.to_string c.post_id in
    Hashtbl.replace posts_with_comments pid true
  ) all_comments;
  (* Count posts with questions that have no comments — O(1) lookup *)
  List.fold_left (fun count (post : Board.post) ->
    let pid = Board.Post_id.to_string post.id in
    if String.contains post.content '?' && not (Hashtbl.mem posts_with_comments pid)
    then count + 1
    else count
  ) 0 posts

(** Collect task backlog signals from MASC room *)
let collect_task_signals ~(room_config : Room_utils.config) : task_backlog_summary =
  try
    let room_id = Room.current_room_id room_config in
    let tasks = Room.get_tasks_raw_in_room room_config room_id in
    let orphans = Room.audit_orphan_tasks room_config in
    let now = Time_compat.now () in

    let todo_count = ref 0 in
    let claimed_count = ref 0 in
    let in_progress_count = ref 0 in
    let done_count = ref 0 in
    let oldest_todo_age = ref 0.0 in
    let high_priority_todo = ref 0 in

    List.iter (fun (task : Types.task) ->
      match task.task_status with
      | Types.Todo ->
          incr todo_count;
          let age_hours =
            let created = Types.parse_iso8601 task.created_at in
            (now -. created) /. 3600.0
          in
          if age_hours > !oldest_todo_age then oldest_todo_age := age_hours;
          if task.priority <= 2 then incr high_priority_todo
      | Types.Claimed _ -> incr claimed_count
      | Types.InProgress _ -> incr in_progress_count
      | Types.Done _ -> incr done_count
      | Types.Cancelled _ -> ()
    ) tasks;

    {
      total_tasks = List.length tasks;
      todo_count = !todo_count;
      claimed_count = !claimed_count;
      in_progress_count = !in_progress_count;
      done_count = !done_count;
      orphan_count = List.length orphans;
      oldest_todo_age_hours = !oldest_todo_age;
      high_priority_todo = !high_priority_todo;
    }
  with exn ->
    Eio.traceln "[Gardener] collect_task_signals failed: %s" (Printexc.to_string exn);
    empty_task_backlog

(** Calculate comprehensive ecosystem health *)
let calculate_health ~config ~room_config : ecosystem_health =
  (* BUG-002 fix: count agents from Room filesystem (same source as masc_agents)
     to ensure consistency across endpoints *)
  let total_agents = match room_config with
    | Some rc ->
        let room_id = Room.current_room_id rc in
        List.length (Room.get_agents_raw_in_room rc room_id)
    | None ->
        (* Fallback to Lodge when no room_config available *)
        List.length (Lodge_heartbeat.get_agents ())
  in
  let all_stats = Lodge_selection.get_all_stats () in
  let now = Time_compat.now () in
  let idle_threshold_sec = config.idle_threshold_hours *. 3600.0 in

  let active_agents, idle_agents = List.fold_left (fun (active, idle) (s : Lodge_selection.agent_stats) ->
    let time_since = now -. s.last_selected_at in
    if time_since < 86400.0 then (active + 1, idle)
    else if time_since > idle_threshold_sec then (active, idle + 1)
    else (active, idle)
  ) (0, 0) all_stats in

  (* Activity metrics from Board *)
  let store = Board.global () in
  let posts = Board.list_posts store ~limit:50 () in
  let posts_24h = List.fold_left (fun count (p : Board.post) ->
    if now -. p.created_at < 86400.0 then count + 1 else count
  ) 0 posts in

  let all_comments = Board.list_comments store ~limit:1000 () in
  let comments_24h = List.fold_left (fun count (cm : Board.comment) ->
    if now -. cm.created_at < 86400.0 then count + 1 else count
  ) 0 all_comments in

  let unanswered_questions = count_unanswered_questions () in

  (* Calculate metrics *)
  let selection_entropy = calculate_entropy all_stats in
  let homeostatic_score = calculate_homeostatic_score ~config ~total_agents in

  (* Task backlog signals *)
  let task_backlog = match room_config with
    | Some rc -> collect_task_signals ~room_config:rc
    | None -> empty_task_backlog
  in

  (* No heuristic gates — these fields are purely informational summaries.
     All decision-making is delegated to LLM (primary) or rule-based inline (fallback).
     Raw signals (agent counts, task_backlog, Board data) flow directly to the decision layer. *)
  let needs_spawn = false in
  let needs_workers = task_backlog.todo_count > 0 && active_agents < 2 in
  let needs_retirement = false in

  let state = get_state () in
  let last_spawn = if state.last_spawn_attempt > 0.0 then Some state.last_spawn_attempt else None in
  let last_retirement = if state.last_retirement_attempt > 0.0 then Some state.last_retirement_attempt else None in

  (* Calculate overloaded agents and topic coverage *)
  let overloaded_agents = count_overloaded_agents ~posts ~comments:all_comments ~now in
  let topic_coverage = calculate_topic_coverage ~posts in

  {
    total_agents;
    active_agents;
    idle_agents;
    overloaded_agents;
    posts_24h;
    comments_24h;
    unanswered_questions;
    topic_coverage;
    selection_entropy;
    homeostatic_score;
    needs_spawn;
    needs_retirement;
    last_spawn;
    last_retirement;
    spawns_today = state.spawns_today;
    retirements_today = state.retirements_today;
    task_backlog;
    system_error_rate = 0.0;
    needs_workers;
  }

(** {1 Gap Signal Processing} *)

(** Enrich gap signals with context *)
let enrich_gap ~topic ~(signals : Lodge_heartbeat.gap_signal_t list) ~agents : enriched_gap =
  let now = Time_compat.now () in
  let first_detected = List.fold_left (fun min_t s -> Float.min min_t s.Lodge_heartbeat.gs_timestamp) now signals in
  let maturity_hours = (now -. first_detected) /. 3600.0 in

  let proposers = signals
    |> List.map (fun s -> s.Lodge_heartbeat.gs_detected_by)
    |> List.sort_uniq compare in

  let context_snippets = signals
    |> List.map (fun s -> s.Lodge_heartbeat.gs_context)
    |> List.filter (fun s -> String.length s > 0) in

  (* Calculate topic similarity using module-level string_similarity *)
  let topic_similarity = List.fold_left (fun max_sim (agent : Lodge_heartbeat.agent) ->
    (* Check name similarity *)
    let name_sim = string_similarity topic agent.name in
    (* Check trait similarity (best match) *)
    let trait_sim = List.fold_left (fun best t ->
      Float.max best (string_similarity topic t)
    ) 0.0 agent.traits in
    (* Take the best match — traits weighted 0.7 *)
    Float.max max_sim (Float.max name_sim (trait_sim *. 0.7))
  ) 0.0 agents in

  (* Calculate urgency based on signal count and maturity *)
  let signal_factor = Float.min 1.0 (float_of_int (List.length signals) /. 5.0) in
  let maturity_factor = Float.min 1.0 (maturity_hours /. 24.0) in
  let urgency_score = (signal_factor *. 0.6) +. (maturity_factor *. 0.4) in

  {
    topic;
    signal_count = List.length signals;
    proposers;
    context_snippets;
    first_detected;
    maturity_hours;
    topic_similarity;
    urgency_score;
  }

(** {1 Spawn Decision Logic} *)

(** Use LLM to decide on spawn *)
let decide_spawn_with_llm ~config ~health ~gap : spawn_decision =
  let prompt = Printf.sprintf {|에이전트 생태계 관리자로서 새 에이전트 생성 여부를 판단해줘.

현재 생태계 상태:
- 총 에이전트: %d (목표: %d, 최소: %d, 최대: %d)
- 활성 에이전트: %d, 유휴 에이전트: %d
- 미답변 질문: %d개
- 오늘 생성된 에이전트: %d/%d

제안된 새 에이전트:
- 주제: %s
- 신호 횟수: %d회 (제안자: %s)
- 기존 에이전트 유사도: %.1f%%
- 성숙도: %.1f시간

[응답 형식 - JSON만, 다른 텍스트 없이]
{
  "decision": "approve" | "defer" | "reject",
  "reason": "판단 이유",
  "traits": ["특성1", "특성2"],
  "hours": [9, 10, 14, 15]
}|}
    health.total_agents config.target_agents config.min_agents config.max_agents
    health.active_agents health.idle_agents
    health.unanswered_questions
    health.spawns_today config.max_daily_spawns
    gap.topic gap.signal_count (String.concat ", " gap.proposers)
    (gap.topic_similarity *. 100.0)
    gap.maturity_hours
  in

  let response =
    match Lodge_cascade.call ~cascade_name:"gardener_spawn"
        ~prompt ~temperature:0.3 ~timeout_sec:15 ~max_tokens:200 () with
    | Ok r -> r.response
    | Error _ -> ""
  in

  (* Parse LLM response *)
  try
    let start_opt = String.index_opt response '{' in
    let end_opt = String.rindex_opt response '}' in
    match start_opt, end_opt with
    | Some start, Some end_pos when start <= end_pos ->
        let json_str = String.sub response start (end_pos - start + 1) in
        let json = Yojson.Safe.from_string json_str in
        let module U = Yojson.Safe.Util in
        let decision = json |> U.member "decision" |> U.to_string in
        let reason = json |> U.member "reason" |> U.to_string in

        (match decision with
        | "approve" ->
            let traits = json |> U.member "traits" |> U.to_list |> List.map U.to_string in
            let hours = json |> U.member "hours" |> U.to_list |> List.map U.to_int in
            SpawnApproved {
              topic = gap.topic;
              urgency = if gap.urgency_score > 0.7 then High else Medium;
              proposed_traits = traits;
              proposed_hours = hours;
              reason;
            }
        | "defer" ->
            SpawnDeferred {
              topic = gap.topic;
              retry_after_sec = config.spawn_cooldown_sec;
              reason;
            }
        | _ ->
            SpawnRejected {
              topic = gap.topic;
              reason;
            })
    | _ ->
        SpawnDeferred {
          topic = gap.topic;
          retry_after_sec = config.spawn_cooldown_sec;
          reason = "No JSON found in LLM response";
        }
  with
  | Yojson.Json_error msg ->
      Eio.traceln "[Gardener] LLM JSON parse error: %s" msg;
      SpawnDeferred {
        topic = gap.topic;
        retry_after_sec = 1800.0;
        reason = Printf.sprintf "LLM JSON parse error: %s" msg;
      }
  | Not_found ->
      Eio.traceln "[Gardener] LLM response missing JSON braces";
      SpawnDeferred {
        topic = gap.topic;
        retry_after_sec = 1800.0;
        reason = "LLM response missing JSON structure";
      }
  | exn ->
      Eio.traceln "[Gardener] LLM decision error: %s" (Printexc.to_string exn);
      SpawnDeferred {
        topic = gap.topic;
        retry_after_sec = 1800.0;
        reason = Printf.sprintf "LLM decision failed: %s" (Printexc.to_string exn);
      }

(** Rule-based spawn decision (no LLM) *)
let decide_spawn_rule_based ~config ~health ~gap : spawn_decision =
  (* Check hard limits *)
  if health.total_agents >= config.max_agents then
    SpawnRejected {
      topic = gap.topic;
      reason = Printf.sprintf "Population at maximum (%d)" config.max_agents;
    }
  else if gap.topic_similarity > 0.7 then
    SpawnRejected {
      topic = gap.topic;
      reason = Printf.sprintf "Too similar to existing agent (%.0f%%)" (gap.topic_similarity *. 100.0);
    }
  else if gap.maturity_hours < config.gap_maturity_hours then
    SpawnDeferred {
      topic = gap.topic;
      retry_after_sec = (config.gap_maturity_hours -. gap.maturity_hours) *. 3600.0;
      reason = Printf.sprintf "Gap not mature enough (%.1f/%.1f hours)" gap.maturity_hours config.gap_maturity_hours;
    }
  else
    SpawnApproved {
      topic = gap.topic;
      urgency = if gap.urgency_score > 0.7 then High else Medium;
      proposed_traits = ["분석적"; "도움이 됨"];  (* Default traits *)
      proposed_hours = [9; 10; 11; 14; 15; 16];  (* Default working hours *)
      reason = Printf.sprintf "Gap signal threshold met (%d signals)" gap.signal_count;
    }

(** Main spawn decision function *)
let decide_spawn ~config ~health ~gap : spawn_decision =
  (* Check budgets and cooldowns first *)
  if not (can_spawn ~config) then begin
    let state = get_state () in
    let now = Time_compat.now () in
    let cooldown_remaining = config.spawn_cooldown_sec -. (now -. state.last_spawn_attempt) in
    SpawnDeferred {
      topic = gap.topic;
      retry_after_sec = Float.max 60.0 cooldown_remaining;
      reason =
        if is_circuit_open () then "Circuit breaker open"
        else if state.spawns_today >= config.max_daily_spawns then
          Printf.sprintf "Daily spawn budget exhausted (%d/%d)" state.spawns_today config.max_daily_spawns
        else "Spawn cooldown active";
    }
  end
  (* Population cap check *)
  else if health.total_agents >= config.max_agents then
    SpawnRejected {
      topic = gap.topic;
      reason = Printf.sprintf "Population at maximum (%d/%d)" health.total_agents config.max_agents;
    }
  (* Use LLM or rule-based decision *)
  else if config.use_llm_decision then
    decide_spawn_with_llm ~config ~health ~gap
  else
    decide_spawn_rule_based ~config ~health ~gap

let decide_spawn_with_provenance ~config ~health ~gap : spawn_decision * string =
  if not (can_spawn ~config) then
    (decide_spawn ~config ~health ~gap, "fallback")
  else if health.total_agents >= config.max_agents then
    (decide_spawn ~config ~health ~gap, "fallback")
  else if config.use_llm_decision then
    (decide_spawn_with_llm ~config ~health ~gap, "judgment")
  else
    (decide_spawn_rule_based ~config ~health ~gap, "fallback")

(** {1 Retirement Decision Logic} *)

(** Decide retirement for an agent *)
let decide_retire ~config ~health ~(agent_stats : agent_stats) : retirement_decision =
  let now = Time_compat.now () in

  (* Never retire below minimum *)
  if health.total_agents <= config.min_agents then
    RetireRejected {
      agent_name = agent_stats.name;
      reason = Printf.sprintf "Population at minimum (%d)" config.min_agents;
    }
  (* Check budget and cooldown *)
  else if not (can_retire ~config) then begin
    let state = get_state () in
    let cooldown_remaining = config.retirement_cooldown_sec -. (now -. state.last_retirement_attempt) in
    RetireDeferred {
      agent_name = agent_stats.name;
      retry_after_sec = Float.max 60.0 cooldown_remaining;
      reason = "Retirement cooldown active";
    }
  end
  (* Check idle threshold *)
  else if agent_stats.idle_hours < config.idle_threshold_hours then
    RetireRejected {
      agent_name = agent_stats.name;
      reason = Printf.sprintf "Not idle enough (%.1f/%.1f hours)" agent_stats.idle_hours config.idle_threshold_hours;
    }
  (* Zero contribution in 24h + long idle = retire *)
  else if agent_stats.posts_24h = 0 && agent_stats.comments_24h = 0 && agent_stats.idle_hours > config.idle_threshold_hours then
    RetireApproved {
      agent_name = agent_stats.name;
      reason = "Zero contribution and idle beyond threshold";
      grace_period_sec = config.retirement_grace_sec;
    }
  else
    RetireRejected {
      agent_name = agent_stats.name;
      reason = "Agent still contributing";
    }

(** {1 Spawn Execution} *)

(** Execute an approved spawn *)
let execute_spawn ~(decision : spawn_decision) : (string, string) result =
  match decision with
  | SpawnApproved { topic; proposed_traits; proposed_hours; reason; _ } ->
      Eio.traceln "[Gardener] Executing spawn: %s (reason: %s)" topic reason;
      let signals = Lodge_heartbeat.get_signals_for_topic ~topic in
      let success = Lodge_heartbeat.spawn_agent_from_gap ~topic ~signals in
      if success then begin
        record_spawn ();
        reset_circuit ();
        Lodge_heartbeat.clear_gap_signals ~topic;
        (* Post announcement *)
        let store = Board.global () in
        let announcement = Printf.sprintf
          "🌱 [Gardener] 새 에이전트 생성: %s\n특성: %s\n근무시간: %s"
          topic
          (String.concat ", " proposed_traits)
          (String.concat ", " (List.map string_of_int proposed_hours))
        in
        (try ignore (Board.create_post store ~author:"gardener" ~content:announcement ~ttl_hours:168 ())
         with exn -> Log.Spawn.error "Board.create_post(announcement) failed: %s" (Printexc.to_string exn));
        Ok topic
      end else begin
        let config = load_config () in
        trip_circuit ~config;
        Error "spawn_agent_from_gap failed"
      end
  | SpawnDeferred { topic = _; reason; _ } ->
      Error (Printf.sprintf "Spawn deferred: %s" reason)
  | SpawnRejected { topic; reason } ->
      Error (Printf.sprintf "Spawn rejected for %s: %s" topic reason)

(** {1 Retirement Execution} *)

(** Execute an approved retirement (mark for removal) *)
let execute_retire ~(decision : retirement_decision) : (string, string) result =
  match decision with
  | RetireApproved { agent_name; reason; grace_period_sec } ->
      Eio.traceln "[Gardener] Executing retirement: %s (grace: %.0fs, reason: %s)"
        agent_name grace_period_sec reason;
      (* For now, just post warning. Actual deletion requires Neo4j mutation. *)
      let store = Board.global () in
      let warning = Printf.sprintf
        "⚠️ [Gardener] 에이전트 은퇴 예정: %s\n이유: %s\n유예 기간: %.0f초\n활동을 재개하면 은퇴가 취소됩니다."
        agent_name reason grace_period_sec
      in
      (try ignore (Board.create_post store ~author:"gardener" ~content:warning ~ttl_hours:24 ())
       with exn -> Log.Spawn.error "Board.create_post(warning) failed: %s" (Printexc.to_string exn));
      record_retirement ();
      reset_circuit ();
      Ok agent_name
  | RetireDeferred { agent_name = _; reason; _ } ->
      Error (Printf.sprintf "Retirement deferred: %s" reason)
  | RetireRejected { agent_name; reason } ->
      Error (Printf.sprintf "Retirement rejected for %s: %s" agent_name reason)

(** {1 Intervention Detection} *)

(** Rule-based intervention detection (task-aware fallback) *)
let detect_intervention_rule_based ~config ~health : decision_snapshot =
  let backlog = health.task_backlog in

  (* Task pressure takes priority over Board gaps *)
  if backlog.todo_count > 0 && backlog.high_priority_todo > 0 && health.active_agents < 2 then
    {
      intervention = NeedWorker backlog;
      source = "fallback";
      reason = "high-priority backlog exceeds active worker capacity";
      target = "";
      error = "";
    }
  else if backlog.orphan_count > 0 then
    {
      intervention = NeedWorker backlog;
      source = "fallback";
      reason = "orphan tasks detected in backlog";
      target = "";
      error = "";
    }
  else begin
    (* Board gap detection — existing logic *)
    let mature_gaps = Lodge_heartbeat.check_gap_threshold () in
    let agents = Lodge_heartbeat.get_agents () in

    match mature_gaps with
    | (topic, _count) :: _ when health.total_agents < config.target_agents ->
        let signals = Lodge_heartbeat.get_signals_for_topic ~topic in
        let gap = enrich_gap ~topic ~signals ~agents in
        if gap.maturity_hours >= config.gap_maturity_hours then
          {
            intervention = NeedSpawn gap;
            source = "fallback";
            reason =
              Printf.sprintf "mature gap '%s' reached %.1fh with %d signals"
                gap.topic gap.maturity_hours gap.signal_count;
            target = gap.topic;
            error = "";
          }
        else
          {
            intervention = Balanced;
            source = "fallback";
            reason =
              Printf.sprintf "gap '%s' not mature enough yet (%.1fh < %.1fh)"
                gap.topic gap.maturity_hours config.gap_maturity_hours;
            target = gap.topic;
            error = "";
          }
    | _ ->
        (* Check for retirement candidates — inline condition, no pre-computed boolean *)
        if health.total_agents > config.target_agents && health.idle_agents > 0 then begin
          let all_stats = Lodge_selection.get_all_stats () in
          let idle_candidates = all_stats
            |> List.filter (fun s ->
                let idle_hours = (Time_compat.now () -. s.Lodge_selection.last_selected_at) /. 3600.0 in
                idle_hours > config.idle_threshold_hours)
            |> List.sort (fun a b ->
                compare b.Lodge_selection.last_selected_at a.Lodge_selection.last_selected_at) in
          match idle_candidates with
          | candidate :: _ ->
              let stats = convert_stats candidate in
              {
                intervention = NeedRetirement stats;
                source = "fallback";
                reason =
                  Printf.sprintf "agent '%s' idle for %.1fh over threshold"
                    stats.name stats.idle_hours;
                target = stats.name;
                error = "";
              }
          | [] ->
              {
                intervention = Balanced;
                source = "fallback";
                reason = "no retirement candidate exceeded idle threshold";
                target = "";
                error = "";
              }
        end else
          {
            intervention = Balanced;
            source = "fallback";
            reason = "no worker pressure, no mature gap, no retirement candidate";
            target = "";
            error = "";
          }
  end

(** Use LLM to decide ecosystem intervention (primary decision path) *)
let decide_intervention_with_llm ~config ~health : decision_snapshot =
  let backlog = health.task_backlog in
  let prompt = Printf.sprintf
    {|에이전트 생태계 관리자로서 모든 시그널을 종합 분석하고 개입 여부를 판단해줘.

== 에이전트 ==
총: %d/%d, 활성: %d, 유휴: %d

== 보드 ==
24h 게시물: %d, 미답변: %d

== 태스크 백로그 ==
미할당 TODO: %d개 (최대 대기: %.1f시간)
고우선순위(P1-P2): %d개
고아 태스크: %d개
진행중: %d개

== 시스템 ==
에러율: %.1f%%, 오늘 spawn: %d/%d

[응답 형식 - JSON만, 다른 텍스트 없이]
{ "action": "spawn_worker" | "spawn_agent" | "retire" | "none", "reason": "판단 이유", "urgency": "low" | "medium" | "high" | "critical" }|}
    health.total_agents config.target_agents health.active_agents health.idle_agents
    health.posts_24h health.unanswered_questions
    backlog.todo_count backlog.oldest_todo_age_hours
    backlog.high_priority_todo backlog.orphan_count backlog.in_progress_count
    (health.system_error_rate *. 100.0) health.spawns_today config.max_daily_spawns
  in

  let model_specs = Lodge_cascade.get_cascade ~cascade_name:"gardener_spawn" () in
  let response =
    match
      Llm_client.run_prompt_cascade ~temperature:0.3
        ~timeout_sec:Env_config.Llm.gardener_spawn_timeout_seconds
        ~model_specs ~max_tokens:300 ~prompt () with
    | Ok resp -> Ok resp.content
    | Error err -> Error ("llm intervention failed: " ^ err)
  in

  (* Parse LLM response *)
  let parsed_response =
    match response with
    | Error err -> Error err
    | Ok body ->
        try
          let start_opt = String.index_opt body '{' in
          let end_opt = String.rindex_opt body '}' in
          match start_opt, end_opt with
          | Some start, Some end_pos when start <= end_pos ->
              let json_str = String.sub body start (end_pos - start + 1) in
              let json = Yojson.Safe.from_string json_str in
              let module U = Yojson.Safe.Util in
              let action = json |> U.member "action" |> U.to_string in
              let reason =
                match json |> U.member "reason" with
                | `String value -> String.trim value
                | _ -> ""
              in
              Ok (action, reason)
          | _ -> Error "No JSON brackets found in LLM response"
        with exn ->
          let message =
            Printf.sprintf "llm intervention JSON parse failed: %s"
              (Printexc.to_string exn)
          in
          Eio.traceln "[Gardener] %s" message;
          Error message
  in
  match parsed_response with
  | Error err ->
      let fallback = detect_intervention_rule_based ~config ~health in
      { fallback with source = "fallback"; error = err }
  | Ok (action, llm_reason) ->
      (match action with
       | "spawn_worker" when backlog.todo_count > 0 ->
           {
             intervention = NeedWorker backlog;
             source = "llm";
             reason =
               if llm_reason <> "" then llm_reason
               else "llm requested worker allocation";
             target = "";
             error = "";
           }
       | "spawn_worker" | "spawn_agent" ->
           let mature_gaps = Lodge_heartbeat.check_gap_threshold () in
           let agents = Lodge_heartbeat.get_agents () in
           (match mature_gaps with
            | (topic, _) :: _ ->
                let signals = Lodge_heartbeat.get_signals_for_topic ~topic in
                let gap = enrich_gap ~topic ~signals ~agents in
                {
                  intervention = NeedSpawn gap;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else Printf.sprintf "llm selected spawn for gap '%s'" gap.topic;
                  target = gap.topic;
                  error = "";
                }
            | [] ->
                {
                  intervention = Balanced;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else "llm requested spawn but no mature gap was available";
                  target = "";
                  error = "";
                })
       | "retire" ->
           let all_stats = Lodge_selection.get_all_stats () in
           let idle_candidates =
             all_stats
             |> List.filter (fun s ->
                    let idle_hours =
                      (Time_compat.now () -. s.Lodge_selection.last_selected_at) /. 3600.0
                    in
                    idle_hours > config.idle_threshold_hours)
             |> List.sort (fun a b ->
                    compare b.Lodge_selection.last_selected_at
                      a.Lodge_selection.last_selected_at)
           in
           (match idle_candidates with
            | candidate :: _ ->
                let stats = convert_stats candidate in
                {
                  intervention = NeedRetirement stats;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else Printf.sprintf "llm selected retirement for '%s'" stats.name;
                  target = stats.name;
                  error = "";
                }
            | [] ->
                {
                  intervention = Balanced;
                  source = "llm";
                  reason =
                    if llm_reason <> "" then llm_reason
                    else "llm requested retirement but no idle candidate was available";
                  target = "";
                  error = "";
                })
       | _ ->
           {
             intervention = Balanced;
             source = "llm";
             reason = if llm_reason <> "" then llm_reason else "llm returned no intervention";
             target = "";
             error = "";
           })

(** Detect what intervention is needed with internal decision metadata. *)
let detect_intervention_detail ~config ~health : decision_snapshot =
  if config.use_llm_decision then
    decide_intervention_with_llm ~config ~health
  else
    detect_intervention_rule_based ~config ~health

(** Detect what intervention is needed *)
let detect_intervention ~config ~health : intervention =
  (detect_intervention_detail ~config ~health).intervention

let status_json () : Yojson.Safe.t =
  let config = load_config () in
  with_lock (fun () ->
      let state = get_state () in
      let tick_in_progress =
        state.last_tick_started_at > 0.0
        && state.last_tick_started_at > state.last_tick_completed_at
      in
      let alive =
        config.enabled
        && (state.last_tick_started_at > 0.0 || state.last_tick_completed_at > 0.0)
      in
      let next_tick_due_at =
        if state.last_tick_completed_at > 0.0 && config.check_interval_sec > 0.0 then
          `String (iso_of_unix (state.last_tick_completed_at +. config.check_interval_sec))
        else
          `Null
      in
      let status =
        if not config.enabled then "disabled"
        else if tick_in_progress then "running"
        else if alive then "idle"
        else "starting"
      in
      `Assoc
        [
          ("enabled", `Bool config.enabled);
          ("alive", `Bool alive);
          ("status", `String status);
          ("tick_in_progress", `Bool tick_in_progress);
          ("tick_count", `Int state.tick_count);
          ("check_interval_sec", `Float config.check_interval_sec);
          ("last_tick_started_at", json_string_of_float_ts state.last_tick_started_at);
          ("last_tick_completed_at", json_string_of_float_ts state.last_tick_completed_at);
          ("next_tick_due_at", next_tick_due_at);
          ("last_health_check_at", json_string_of_float_ts state.last_health_check);
          ("last_intervention", `String state.last_intervention);
          ("last_decision_source", `String state.last_decision_source);
          ("last_action", `String state.last_action);
          ("last_target", json_string_of_nonempty state.last_target);
          ("last_reason", json_string_of_nonempty state.last_reason);
          ("last_error", json_string_of_nonempty state.last_error);
          ("circuit_open", `Bool (is_circuit_open ()));
          ("circuit_open_until", json_string_of_opt_ts state.circuit_open_until);
          ("can_spawn", `Bool (can_spawn ~config));
          ("can_retire", `Bool (can_retire ~config));
          ("last_spawn_attempt_at", json_string_of_float_ts state.last_spawn_attempt);
          ("last_retirement_attempt_at", json_string_of_float_ts state.last_retirement_attempt);
          ("spawns_today", `Int state.spawns_today);
          ("retirements_today", `Int state.retirements_today);
          ( "health_summary",
            `Assoc
              [
                ("total_agents", `Int state.last_total_agents);
                ("active_agents", `Int state.last_active_agents);
                ("idle_agents", `Int state.last_idle_agents);
                ("todo_count", `Int state.last_todo_count);
                ("high_priority_todo", `Int state.last_high_priority_todo);
                ("orphan_count", `Int state.last_orphan_count);
                ("homeostatic_score", `Float state.last_homeostatic_score);
                ("needs_workers", `Bool state.last_needs_workers);
                ("data_source", `String "room_filesystem");
                ("staleness_warning", `String
                  (if state.last_health_check > 0.0 then
                    let age = Time_compat.now () -. state.last_health_check in
                    if age > 600.0 then Printf.sprintf "stale (%.0fs ago)" age
                    else "fresh"
                   else "no_data"));
              ] );
        ])

let backlog_goal_prefix = "[Gardener] Backlog triage"

let backlog_objective room_id (backlog : task_backlog_summary) =
  Printf.sprintf
    "%s · room=%s · todo=%d · high=%d · orphan=%d"
    backlog_goal_prefix room_id backlog.todo_count backlog.high_priority_todo
    backlog.orphan_count

let backlog_triage_session_agents ~(room_config : Room_utils.config) ~(room_id : string) =
  let agents = Room.get_agents_raw_in_room room_config room_id in
  let active_agents =
    agents
    |> List.filter_map (fun (agent : Types.agent) ->
           match agent.status with
           | Types.Active | Types.Busy | Types.Listening -> Some agent.name
           | Types.Inactive -> None)
    |> Team_session_types.dedup_strings
    |> List.sort String.compare
  in
  if active_agents <> [] then
    active_agents
  else
    agents
    |> List.map (fun (agent : Types.agent) -> agent.name)
    |> Team_session_types.dedup_strings
    |> List.sort String.compare

let existing_backlog_session ~(room_config : Room_utils.config) ~(room_id : string) =
  Team_session_store.list_sessions room_config
  |> List.find_opt (fun (session : Team_session_types.session) ->
         String.equal session.created_by "gardener"
         && String.equal session.room_id room_id
         &&
         List.mem session.status
           [ Team_session_types.Running; Team_session_types.Paused ]
         && String.starts_with ~prefix:backlog_goal_prefix session.goal)

let top_todo_tasks ~(room_config : Room_utils.config) ~(room_id : string) ~(limit : int) =
  Room.get_tasks_raw_in_room room_config room_id
  |> List.filter (fun (task : Types.task) ->
         match task.task_status with
         | Types.Todo -> true
         | _ -> false)
  |> List.sort (fun (left : Types.task) (right : Types.task) ->
         let by_priority = Int.compare left.priority right.priority in
         if by_priority <> 0 then by_priority
         else String.compare left.created_at right.created_at)
  |> List.filteri (fun idx _ -> idx < limit)

let backlog_summary_lines backlog orphan_tasks todo_tasks =
  let orphan_refs =
    orphan_tasks
    |> List.map (fun ((task : Types.task), assignee) ->
           Printf.sprintf "%s(%s→%s)" task.id assignee task.title)
  in
  let todo_refs =
    todo_tasks
    |> List.map (fun (task : Types.task) ->
           Printf.sprintf "%s[P%d] %s" task.id task.priority task.title)
  in
  Team_session_types.dedup_strings
    ([
       Printf.sprintf "TODO %d / high-priority %d / orphan %d / oldest %.1fh"
         backlog.todo_count backlog.high_priority_todo backlog.orphan_count
         backlog.oldest_todo_age_hours;
     ]
    @
    if orphan_refs = [] then [] else [ "Orphans: " ^ String.concat ", " orphan_refs ]
    @
    if todo_refs = [] then [] else [ "Top TODOs: " ^ String.concat ", " todo_refs ])

let inject_backlog_tasks ~(room_config : Room_utils.config) ~(session_id : string)
    ~(backlog : task_backlog_summary) ~(orphan_tasks : (Types.task * string) list)
    ~(todo_tasks : Types.task list) =
  let record ~turn_kind ?message ?task_title ?task_description ~task_priority () =
    ignore
      (Team_session_engine_eio.record_turn ~config:room_config ~session_id
         ~actor:"gardener" ~turn_kind ~message ~target_agent:None ~task_title
         ~task_description ~task_priority)
  in
  let summary_lines = backlog_summary_lines backlog orphan_tasks todo_tasks in
  record ~turn_kind:Team_session_types.Turn_note
    ~message:(String.concat " | " summary_lines) ~task_priority:3 ();
  let mentions =
    Team_session_store.load_session room_config session_id
    |> Option.map Team_session_types.planned_participant_names
    |> Option.value ~default:[]
    |> List.map (fun name -> "@" ^ name)
    |> String.concat " "
  in
  record ~turn_kind:Team_session_types.Turn_broadcast
    ~message:
      (String.trim
         (Printf.sprintf
            "%s backlog triage session started. Reclaim orphaned tasks, claim top TODOs, and leave progress in this session."
            mentions))
    ~task_priority:3 ();
  if backlog.orphan_count > 0 then
    let orphan_desc =
      orphan_tasks
      |> List.map (fun ((task : Types.task), assignee) ->
             Printf.sprintf "%s claimed by %s: %s" task.id assignee task.title)
      |> String.concat "\n"
    in
    record ~turn_kind:Team_session_types.Turn_task
      ~task_title:(Printf.sprintf "[Gardener] Reassign %d orphan task(s)" backlog.orphan_count)
      ~task_description:
        (Printf.sprintf
           "Audit and reassign orphaned work in the current room.\n%s"
           orphan_desc)
      ~task_priority:1 ();
  if backlog.high_priority_todo > 0 then
    let todo_desc =
      todo_tasks
      |> List.filter (fun (task : Types.task) -> task.priority <= 2)
      |> List.map (fun (task : Types.task) ->
             Printf.sprintf "%s [P%d] %s" task.id task.priority task.title)
      |> String.concat "\n"
    in
    record ~turn_kind:Team_session_types.Turn_task
      ~task_title:(Printf.sprintf "[Gardener] Claim %d high-priority TODO(s)" backlog.high_priority_todo)
      ~task_description:
        (Printf.sprintf
           "Claim or delegate the highest-priority unassigned backlog items.\n%s"
           todo_desc)
      ~task_priority:1 ();
  if backlog.todo_count > backlog.high_priority_todo then
    record ~turn_kind:Team_session_types.Turn_task
      ~task_title:(Printf.sprintf "[Gardener] Triage remaining TODO backlog (%d)" backlog.todo_count)
      ~task_description:
        "Review remaining unclaimed tasks, group related work, and leave a checkpoint in the session."
      ~task_priority:2 ()

let start_backlog_triage_session ~sw ~clock ~(room_config : Room_utils.config)
    ~(backlog : task_backlog_summary) =
  let room_id = Room.current_room_id room_config in
  let start_session ~agents ~operation_id =
    Team_session_engine_eio.start_session ~sw ~clock ~config:room_config
      ~created_by:"gardener"
      ~goal:(backlog_objective room_id backlog)
      ~duration_seconds:1800
      ~execution_scope:Team_session_types.Observe_only
      ~checkpoint_interval_sec:60 ~min_agents:1
      ~scale_profile:Team_session_types.Scale_standard
      ~control_profile:Team_session_types.Control_flat
      ~orchestration_mode:Team_session_types.Assist
      ~communication_mode:Team_session_types.Comm_broadcast
      ~model_cascade:[]
      ~fallback_policy:Team_session_types.Fallback_cascade_then_task
      ~instruction_profile:Team_session_types.Profile_standard
      ~alert_channel:Team_session_types.Alert_both ~auto_resume:true
      ~report_formats:[ Team_session_types.Markdown; Team_session_types.Json ]
      ~agent_names:agents ~operation_id
  in
  let session_id_of_result ~orphan_tasks ~todo_tasks = function
    | Ok (`Assoc _ as json) -> (
        match Yojson.Safe.Util.member "session_id" json with
        | `String session_id ->
            inject_backlog_tasks ~room_config ~session_id ~backlog
              ~orphan_tasks ~todo_tasks;
            Ok session_id
        | _ -> Error "backlog triage session missing session_id")
    | Ok _ -> Error "unexpected backlog triage session response"
    | Error err -> Error err
  in
  match existing_backlog_session ~room_config ~room_id with
  | Some session ->
      Eio.traceln "[Gardener] Reusing backlog triage session %s" session.session_id;
      Ok session.session_id
  | None ->
      let agents = backlog_triage_session_agents ~room_config ~room_id in
      if agents = [] then
        Error "no joined room agents available for backlog triage"
      else
        let orphan_tasks = Room.audit_orphan_tasks room_config in
        let todo_tasks = top_todo_tasks ~room_config ~room_id ~limit:5 in
        let operation_json =
          `Assoc
            [
              ("assigned_unit_id", `String "company-runtime");
              ("objective", `String (backlog_objective room_id backlog));
              ("workload_profile", `String "coding_task");
              ("stage", `String "decompose");
              ("search_strategy", `String "best_first_v1");
              ("note", `String "gardener_backlog_triage");
              ("artifact_scope", `List []);
            ]
        in
        match Command_plane_v2.start_operation room_config ~actor:"gardener" operation_json with
        | Error err ->
            Eio.traceln
              "[Gardener] Backlog triage falling back to session without operation attachment: %s"
              err;
            session_id_of_result ~orphan_tasks ~todo_tasks
              (start_session ~agents ~operation_id:None)
        | Ok operation -> (
            match start_session ~agents ~operation_id:(Some operation.operation_id)
            with
            | Error err -> (
                Eio.traceln
                  "[Gardener] Backlog triage falling back to session without operation attachment: %s"
                  err;
                session_id_of_result ~orphan_tasks ~todo_tasks
                  (start_session ~agents ~operation_id:None))
            | Ok (`Assoc _ as json) ->
                session_id_of_result ~orphan_tasks ~todo_tasks (Ok json)
            | Ok _ -> Error "unexpected backlog triage session response")

(** {1 Background Loop} *)

(** Main gardener loop iteration *)
let tick ~sw ~clock ~config ~room_config : unit =
  let tick_started_at = mark_tick_start () in
  if is_circuit_open () then begin
    record_decision
      {
        intervention = Balanced;
        source = "none";
        reason = "circuit open; tick skipped";
        target = "";
        error = "";
      };
    record_tick_complete ();
    Eio.traceln "[Gardener] Circuit open, skipping tick"
  end else begin
    let health = calculate_health ~config ~room_config:(Some room_config) in
    record_health_summary ~at:tick_started_at health;
    let backlog = health.task_backlog in
    Eio.traceln
      "[Gardener] Health: agents=%d/%d active=%d idle=%d score=%.2f task_backlog: todo=%d high_pri=%d orphans=%d"
      health.total_agents config.target_agents health.active_agents
      health.idle_agents health.homeostatic_score backlog.todo_count
      backlog.high_priority_todo backlog.orphan_count;

    let decision = detect_intervention_detail ~config ~health in
    record_decision decision;
    match decision.intervention with
    | NeedSpawn gap ->
        Eio.traceln "[Gardener] Intervention needed: spawn %s" gap.topic;
        let spawn_decision = decide_spawn ~config ~health ~gap in
        (match execute_spawn ~decision:spawn_decision with
         | Ok name ->
             record_action "spawned" ~target:name
               ~reason:(Printf.sprintf "spawned from gap '%s'" gap.topic);
             Eio.traceln "[Gardener] Spawned: %s" name
         | Error e ->
             record_action "none" ~target:gap.topic
               ~reason:"spawn decision did not execute"
               ~error:e;
             Eio.traceln "[Gardener] Spawn failed: %s" e)
    | NeedWorker backlog ->
        Eio.traceln "[Gardener] Task pressure: %d TODO, %d high-pri, %d orphans"
          backlog.todo_count backlog.high_priority_todo backlog.orphan_count;
        (match start_backlog_triage_session ~sw ~clock ~room_config ~backlog with
         | Ok session_id ->
             record_action "worker_session_started" ~target:session_id
               ~reason:"started backlog triage session";
             Eio.traceln "[Gardener] Started backlog triage session: %s" session_id;
             Sse.broadcast
               (`Assoc
                 [
                   ("type", `String "gardener_need_worker");
                   ("session_id", `String session_id);
                   ("todo_count", `Int backlog.todo_count);
                   ("high_priority_todo", `Int backlog.high_priority_todo);
                   ("orphan_count", `Int backlog.orphan_count);
                 ])
         | Error err ->
             record_action "worker_request_posted"
               ~reason:"backlog triage session failed; posted worker request"
               ~error:err;
             Eio.traceln "[Gardener] Backlog triage start failed: %s" err;
             let store = Board.global () in
             let msg =
               Printf.sprintf
                 "[Gardener] %d unclaimed tasks (P1-P2: %d, oldest: %.1fh). Worker needed. Session start failed: %s"
                 backlog.todo_count backlog.high_priority_todo
                 backlog.oldest_todo_age_hours err
             in
             (try
                ignore
                  (Board.create_post store ~author:"gardener" ~content:msg
                     ~ttl_hours:24 ())
              with exn ->
                Eio.traceln "[Gardener] Board post failed: %s"
                  (Printexc.to_string exn));
             Sse.broadcast
               (`Assoc
                 [
                   ("type", `String "gardener_need_worker");
                   ("error", `String err);
                   ("todo_count", `Int backlog.todo_count);
                   ("high_priority_todo", `Int backlog.high_priority_todo);
                   ("orphan_count", `Int backlog.orphan_count);
                 ]))
    | NeedRetirement stats ->
        Eio.traceln "[Gardener] Intervention needed: retire %s" stats.name;
        let retirement_decision = decide_retire ~config ~health ~agent_stats:stats in
        (match execute_retire ~decision:retirement_decision with
         | Ok name ->
             record_action "retirement_initiated" ~target:name
               ~reason:"retirement grace period initiated";
             Eio.traceln "[Gardener] Retirement initiated: %s" name
         | Error e ->
             record_action "none" ~target:stats.name
               ~reason:"retirement decision did not execute"
               ~error:e;
             Eio.traceln "[Gardener] Retirement failed: %s" e)
    | Balanced ->
        record_action "none" ~reason:decision.reason;
        Eio.traceln "[Gardener] Ecosystem balanced";
    record_tick_complete ()
  end

(** Pulse consumer wrapping the existing [tick] function.
    The loop mechanism changes; tick logic stays identical. *)
let make_gardener_consumer ~sw ~clock ~config ~room_config : (module Pulse.Consumer) =
  (module struct
    let name = "gardener-tick"
    let should_act _beat = not (is_circuit_open ())
    let on_beat _beat =
      (try
        tick ~sw ~clock ~config ~room_config;
        publish_event "masc:gardener:tick"
          (`Assoc [
            ("agent_name", `String "gardener");
            ("circuit_open", `Bool false);
            ("timestamp", `Float (Time_compat.now ()));
          ]);
        Ok ()
      with exn ->
        let msg = Printf.sprintf "gardener tick failed: %s" (Printexc.to_string exn) in
        Eio.traceln "[Gardener] %s" msg;
        Error msg)
  end)

(** Sentinel event reactor: subscribes to sentinel task_hygiene events
    and nudges Pulse for immediate reaction. *)
let setup_sentinel_reactor ~(sub : Agent_sdk.Event_bus.subscription) =
  match !gardener_pulse_ref with
  | Some pulse ->
      let events = Agent_sdk.Event_bus.drain sub in
      List.iter (fun ev ->
        match ev with
        | Agent_sdk.Event_bus.Custom ("masc:sentinel:task_hygiene", _payload) ->
            Pulse.nudge pulse ~reason:"sentinel task_hygiene event"
        | _ -> ()
      ) events
  | None -> ()

(** Background fiber: periodically drains sentinel events and nudges Gardener pulse. *)
let start_sentinel_reactor_fiber ~sw ~clock ~sub =
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep clock 10.0;
      setup_sentinel_reactor ~sub;
      loop ()
    in
    loop ())

(** Start the gardener (called from main server init).
    Uses Pulse for tick scheduling (replaces raw Eio.Time.sleep loop).
    Optionally subscribes to Sentinel events via Event_bus. *)
let start ?bus ~sw ~clock ~room_config () =
  let config = load_config () in
  room_config_ref := Some room_config;
  bus_ref := bus;
  if config.enabled then begin
    gardener_lock := Some (Eio.Mutex.create ());
    Eio.traceln
      "[Gardener] Starting with config: min=%d target=%d max=%d interval=%.0fs"
      config.min_agents config.target_agents config.max_agents
      config.check_interval_sec;
    let pulse = Pulse.create
      ~clock
      ~rhythm:{ Pulse.base_s = config.check_interval_sec;
                min_s = 60.0;
                max_s = config.check_interval_sec *. 2.0;
                quiet = (3, 7) }
      ~lifecycle:Perpetual
      ~consumers:[make_gardener_consumer ~sw ~clock ~config ~room_config]
    in
    gardener_pulse_ref := Some pulse;
    (match bus with
     | Some b ->
         let sub = Agent_sdk.Event_bus.subscribe b
           ~filter:(function
             | Agent_sdk.Event_bus.Custom (name, _) ->
                 String.length name >= 14 &&
                 String.sub name 0 14 = "masc:sentinel:"
             | _ -> false)
         in
         start_sentinel_reactor_fiber ~sw ~clock ~sub
     | None -> ());
    Pulse.run ~sw pulse
  end else
    Eio.traceln "[Gardener] Disabled (set MASC_GARDENER_ENABLED=true to enable)"

(** {1 Public API for Tools} *)

(** Get current ecosystem health (for MCP tool) *)
let get_health () : ecosystem_health =
  let config = load_config () in
  calculate_health ~config ~room_config:!room_config_ref

(** Propose a spawn (for MCP tool) *)
let propose_spawn ~topic ~reason ~urgency : spawn_decision =
  let config = load_config () in
  let health = calculate_health ~config ~room_config:!room_config_ref in
  let now = Time_compat.now () in
  let gap =
    {
      topic;
      signal_count = 1;
      proposers = [ "manual" ];
      context_snippets = [ reason ];
      first_detected = now;
      maturity_hours = config.gap_maturity_hours;
      topic_similarity = 0.0;
      urgency_score =
        (match urgency with
        | Critical -> 1.0
        | High -> 0.8
        | Medium -> 0.5
        | Low -> 0.3);
    }
  in
  decide_spawn ~config ~health ~gap

let propose_spawn_with_provenance ~topic ~reason ~urgency :
    spawn_decision * string =
  let config = load_config () in
  let health = calculate_health ~config ~room_config:!room_config_ref in
  let now = Time_compat.now () in
  let gap =
    {
      topic;
      signal_count = 1;
      proposers = [ "manual" ];
      context_snippets = [ reason ];
      first_detected = now;
      maturity_hours = config.gap_maturity_hours;
      topic_similarity = 0.0;
      urgency_score =
        (match urgency with
        | Critical -> 1.0
        | High -> 0.8
        | Medium -> 0.5
        | Low -> 0.3);
    }
  in
  decide_spawn_with_provenance ~config ~health ~gap

(** Propose a retirement (for MCP tool) *)
let propose_retire ~agent_name : retirement_decision =
  let config = load_config () in
  let health = calculate_health ~config ~room_config:!room_config_ref in

  (* Get stats for the agent *)
  let ls = Lodge_selection.get_stats agent_name in
  let stats = convert_stats ls in

  decide_retire ~config ~health ~agent_stats:stats

(** Get configuration (for MCP tool) *)
let get_config () : gardener_config =
  load_config ()
