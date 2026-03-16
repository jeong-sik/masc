(** Gardener_health — health calculation, stats conversion, topic analysis,
    gap enrichment, and board analysis utilities. *)

[@@@warning "-32-69"]

open Gardener_types

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
