(** Gardener — Self-Organizing Agent Ecosystem Manager

    Implements autonomous management of the agent ecosystem:
    - Health monitoring with homeostatic balance
    - Spawn decisions based on gap signals and ecosystem needs
    - Retirement decisions for idle/redundant agents
    - Background loop with circuit breaker protection

    Design principles:
    - {b Inverse-U Reward}: Both over- and under-population are penalized
    - {b Safety First}: Hard limits, budgets, cooldowns, circuit breaker
    - {b LLM-Assisted}: Complex decisions can use LLM for nuanced judgment
*)

[@@@warning "-32-69"]

open Gardener_types

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

(** Calculate comprehensive ecosystem health *)
let calculate_health ~config : ecosystem_health =
  let agents = Lodge_heartbeat.get_agents () in
  let all_stats = Lodge_selection.get_all_stats () in
  let now = Time_compat.now () in

  (* Agent counts *)
  let total_agents = List.length agents in
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

  (* Determine needs *)
  let needs_spawn =
    total_agents < config.target_agents &&
    (unanswered_questions > 5 || active_agents < 3) in

  let needs_retirement =
    total_agents > config.target_agents &&
    idle_agents > (total_agents / 3) in

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

  let response = Llm_direct.call_glm ~model:"glm-4.7" ~prompt ~timeout_sec:15 ~max_chars:500 () in

  (* Parse LLM response *)
  try
    let start = String.index response '{' in
    let end_pos = String.rindex response '}' in
    let json_str = String.sub response start (end_pos - start + 1) in
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let decision = json |> member "decision" |> to_string in
    let reason = json |> member "reason" |> to_string in

    match decision with
    | "approve" ->
        let traits = json |> member "traits" |> to_list |> List.map to_string in
        let hours = json |> member "hours" |> to_list |> List.map to_int in
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
        ignore (Board.create_post store ~author:"gardener" ~content:announcement ~ttl_hours:168 ());
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
      ignore (Board.create_post store ~author:"gardener" ~content:warning ~ttl_hours:24 ());
      record_retirement ();
      reset_circuit ();
      Ok agent_name
  | RetireDeferred { agent_name = _; reason; _ } ->
      Error (Printf.sprintf "Retirement deferred: %s" reason)
  | RetireRejected { agent_name; reason } ->
      Error (Printf.sprintf "Retirement rejected for %s: %s" agent_name reason)

(** {1 Intervention Detection} *)

(** Detect what intervention is needed *)
let detect_intervention ~config ~health : intervention =
  (* Check for mature gaps first *)
  let mature_gaps = Lodge_heartbeat.check_gap_threshold () in
  let agents = Lodge_heartbeat.get_agents () in

  match mature_gaps with
  | (topic, _count) :: _ when health.needs_spawn ->
      let signals = Lodge_heartbeat.get_signals_for_topic ~topic in
      let gap = enrich_gap ~topic ~signals ~agents in
      if gap.maturity_hours >= config.gap_maturity_hours then
        NeedSpawn gap
      else
        Balanced
  | _ ->
      (* Check for retirement candidates *)
      if health.needs_retirement then begin
        let all_stats = Lodge_selection.get_all_stats () in
        let idle_candidates = all_stats
          |> List.filter (fun s ->
              let idle_hours = (Time_compat.now () -. s.Lodge_selection.last_selected_at) /. 3600.0 in
              idle_hours > config.idle_threshold_hours)
          |> List.sort (fun a b ->
              compare b.Lodge_selection.last_selected_at a.Lodge_selection.last_selected_at) in
        match idle_candidates with
        | candidate :: _ -> NeedRetirement (convert_stats candidate)
        | [] -> Balanced
      end else
        Balanced

(** {1 Background Loop} *)

(** Main gardener loop iteration *)
let tick ~config ~room_config:_ : unit =
  if is_circuit_open () then
    Eio.traceln "[Gardener] Circuit open, skipping tick"
  else begin
    let health = calculate_health ~config in
    Eio.traceln "[Gardener] Health: agents=%d/%d active=%d idle=%d score=%.2f"
      health.total_agents config.target_agents health.active_agents
      health.idle_agents health.homeostatic_score;

    match detect_intervention ~config ~health with
    | NeedSpawn gap ->
        Eio.traceln "[Gardener] Intervention needed: spawn %s" gap.topic;
        let decision = decide_spawn ~config ~health ~gap in
        (match execute_spawn ~decision with
         | Ok name -> Eio.traceln "[Gardener] Spawned: %s" name
         | Error e -> Eio.traceln "[Gardener] Spawn failed: %s" e)

    | NeedRetirement stats ->
        Eio.traceln "[Gardener] Intervention needed: retire %s" stats.name;
        let decision = decide_retire ~config ~health ~agent_stats:stats in
        (match execute_retire ~decision with
         | Ok name -> Eio.traceln "[Gardener] Retirement initiated: %s" name
         | Error e -> Eio.traceln "[Gardener] Retirement failed: %s" e)

    | Balanced ->
        Eio.traceln "[Gardener] Ecosystem balanced"
  end

(** Run the gardener background loop (no switch needed — loop is self-contained) *)
let rec run_loop ~clock ~config ~room_config () =
  tick ~config ~room_config;
  Eio.Time.sleep clock config.check_interval_sec;
  run_loop ~clock ~config ~room_config ()

(** Start the gardener (called from main server init) *)
let start ~sw ~clock ~room_config =
  let config = load_config () in
  if config.enabled then begin
    (* Initialize lock for thread safety before any concurrent access *)
    gardener_lock := Some (Eio.Mutex.create ());
    Eio.traceln "[Gardener] Starting with config: min=%d target=%d max=%d interval=%.0fs"
      config.min_agents config.target_agents config.max_agents config.check_interval_sec;
    Eio.Fiber.fork ~sw (fun () ->
      run_loop ~clock ~config ~room_config ()
    )
  end else
    Eio.traceln "[Gardener] Disabled (set MASC_GARDENER_ENABLED=true to enable)"

(** {1 Public API for Tools} *)

(** Get current ecosystem health (for MCP tool) *)
let get_health () : ecosystem_health =
  let config = load_config () in
  calculate_health ~config

(** Propose a spawn (for MCP tool) *)
let propose_spawn ~topic ~reason ~urgency : spawn_decision =
  let config = load_config () in
  let health = calculate_health ~config in
  let now = Time_compat.now () in

  (* Create a synthetic enriched gap *)
  let gap = {
    topic;
    signal_count = 1;
    proposers = ["manual"];
    context_snippets = [reason];
    first_detected = now;
    maturity_hours = config.gap_maturity_hours;  (* Bypass maturity check for manual *)
    topic_similarity = 0.0;  (* Assume no overlap for manual *)
    urgency_score = (match urgency with Critical -> 1.0 | High -> 0.8 | Medium -> 0.5 | Low -> 0.3);
  } in

  decide_spawn ~config ~health ~gap

(** Propose a retirement (for MCP tool) *)
let propose_retire ~agent_name : retirement_decision =
  let config = load_config () in
  let health = calculate_health ~config in

  (* Get stats for the agent *)
  let ls = Lodge_selection.get_stats agent_name in
  let stats = convert_stats ls in

  decide_retire ~config ~health ~agent_stats:stats

(** Get configuration (for MCP tool) *)
let get_config () : gardener_config =
  load_config ()
