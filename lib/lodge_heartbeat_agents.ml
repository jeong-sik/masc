include Lodge_heartbeat_state

[@@@warning "-32-69"]

let get_agents () =
  let now = Time_compat.now () in
  let cache_ttl = if !agents_cache = [] then 30.0 else 300.0 in
  (* Empty cache → retry in 30s; populated → refresh every 5 min *)
  if now -. !agents_cache_time > cache_ttl then begin
    let loaded = load_agents_from_neo4j () in
    if loaded <> [] then begin
      agents_cache := loaded;
      agents_cache_time := now;
      Eio.traceln "🔄 Loaded %d heartbeat agents" (List.length loaded)
    end else if !agents_cache = [] then begin
      (* First load failed — record time to avoid hammering *)
      agents_cache_time := now;
      Eio.traceln "⚠️ Agent load returned empty, retrying in 30s"
    end
    (* else: keep existing cache on transient failure *)
  end;
  !agents_cache

(** Lodge Agent REST API — delegated to Lodge_ecosystem module.
    @since 4.1.0 *)
let load_lodge_agents_full = Lodge_ecosystem.load_lodge_agents_full

let create_agent_graphql ~name ~emoji ~korean_name ~traits ~interests
    ~activity_level ~preferred_hours ~peak_hour ~model
    ~personality_hint ~primary_value () =
  Lodge_ecosystem.create_agent_graphql ~name ~emoji ~korean_name ~traits ~interests
    ~activity_level ~preferred_hours ~peak_hour ~model
    ~personality_hint ~primary_value
    ~invalidate_cache:(fun () -> agents_cache_time := 0.0)
    ()

(** {1 Content Alert Scanner — Board activity → triggers} *)

(** Scan recent board posts for content matching agent interests.
    Also parse @mentions → Mentioned triggers. *)
let scan_board_triggers ~since ~(agents : agent list) : (string * checkin_trigger) list =
  let store = Board.global () in
  let recent = Board.list_posts store ~limit:20 () in
  let new_posts = List.filter (fun (p : Board.post) -> p.created_at > since) recent in
  let triggers = ref [] in
  List.iter (fun (p : Board.post) ->
    let content_lower = String.lowercase_ascii p.content in
    (* Check @mentions *)
    List.iter (fun (agent : agent) ->
      let mention = Printf.sprintf "@%s" agent.name in
      let mention_lower = String.lowercase_ascii mention in
      let rec find_sub s pat start =
        if start + String.length pat > String.length s then false
        else if String.sub s start (String.length pat) = pat then true
        else find_sub s pat (start + 1)
      in
      if find_sub content_lower mention_lower 0 then
        triggers := (agent.name, Mentioned (Board.Post_id.to_string p.id)) :: !triggers
    ) agents;
    (* Check keyword match with agent traits *)
    (* Check keyword match with agent traits + interests *)
    List.iter (fun (agent : agent) ->
      let keywords = agent.traits @ agent.interests in
      let matched = List.exists (fun kw ->
        let kw_lower = String.lowercase_ascii kw in
        let rec find_sub s pat start =
          if start + String.length pat > String.length s then false
          else if String.sub s start (String.length pat) = pat then true
          else find_sub s pat (start + 1)
        in
        String.length kw_lower >= 2 && find_sub content_lower kw_lower 0
      ) keywords in
      if matched && not (List.exists (fun (n, _) -> n = agent.name) !triggers) then
        triggers := (agent.name, ContentAlert (Board.Post_id.to_string p.id)) :: !triggers
    ) agents
  ) new_posts;
  !triggers

(** {1 Round-Robin Scheduler — Check-in Model v2}

    Priority: Mentioned > ContentAlert > preferred_hours match > round-robin.
    No LLM calls for scheduling — 0 LLM cost per tick. *)

(** Select which agents to check in this tick. *)
let select_checkin_agents ~ignore_quiet_hours ~(config : config)
    ~(agents : agent list)
    ~(pending_triggers : (string * checkin_trigger) list)
  : (string * checkin_trigger) list =
  let current_hour = current_hour_kst () in
  let (quiet_start, quiet_end) = config.quiet_hours in
  let is_quiet =
    (not ignore_quiet_hours)
    && current_hour >= quiet_start
    && current_hour < quiet_end
  in
  if is_quiet || List.length agents = 0 then []
  else begin
    let max_n = config.agents_per_tick in
    let selected = ref [] in

    (* 1. Mentioned triggers — highest priority *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | Mentioned _ when List.length !selected < max_n &&
                         can_checkin ~agent_name:name ~min_gap_s:60.0 ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 2. ContentAlert triggers *)
    List.iter (fun (name, trigger) ->
      match trigger with
      | ContentAlert _ when List.length !selected < max_n &&
                            not (List.exists (fun (n, _) -> n = name) !selected) &&
                            can_checkin ~agent_name:name ~min_gap_s:config.min_checkin_gap_s ->
        selected := (name, trigger) :: !selected
      | _ -> ()
    ) pending_triggers;

    (* 3. preferred_hours match *)
    if List.length !selected < max_n then
      List.iter (fun (a : agent) ->
        if List.length !selected < max_n &&
           List.mem current_hour a.preferred_hours &&
           not (List.exists (fun (n, _) -> n = a.name) !selected) &&
           can_checkin ~agent_name:a.name ~min_gap_s:config.min_checkin_gap_s
        then
          selected := (a.name, Scheduled) :: !selected
      ) agents;

    (* 4. Least-recently-active fallback (replaces pure round-robin) *)
    if List.length !selected < max_n then begin
      let eligible = List.filter (fun (a : agent) ->
        not (List.exists (fun (n, _) -> n = a.name) !selected) &&
        can_checkin ~agent_name:a.name ~min_gap_s:config.min_checkin_gap_s
      ) agents in
      (* Sort by last_checkin ascending — least recent first *)
      let sorted = List.sort (fun (a1 : agent) (a2 : agent) ->
        let t1 = match Hashtbl.find_opt Lodge_rate_limit.last_checkin a1.name with Some t -> t | None -> 0.0 in
        let t2 = match Hashtbl.find_opt Lodge_rate_limit.last_checkin a2.name with Some t -> t | None -> 0.0 in
        Float.compare t1 t2
      ) eligible in
      let remaining = max_n - List.length !selected in
      List.iteri (fun i (a : agent) ->
        if i < remaining then
          selected := (a.name, Scheduled) :: !selected
      ) sorted
    end;

    List.rev !selected
  end

(** {1 Heartbeat Execution — Check-in Model v2} *)

let string_of_trigger = function
  | Scheduled -> "scheduled"
  | ContentAlert post_id -> Printf.sprintf "content-alert(%s)" post_id
  | Mentioned post_id -> Printf.sprintf "mentioned(%s)" post_id
  | ManualTrigger -> "manual"

let string_of_checkin_result = function
  | Acted { summary; _ } -> Printf.sprintf "acted: %s" summary
  | Passed reason -> Printf.sprintf "passed: %s" reason
  | Skipped reason -> Printf.sprintf "skipped: %s" reason

let build_activity_report ~current_hour ~(checkins : (string * checkin_trigger * checkin_result) list) =
  if checkins = [] then "No activity this tick."
  else
    checkins |> List.map (fun (name, _trigger, result) ->
      let action_str = match result with
        | Acted { summary; _ } -> summary
        | Passed reason -> Printf.sprintf "Passed: %s" reason
        | Skipped reason -> Printf.sprintf "Skipped: %s" reason
      in
      Printf.sprintf "[%02d:00 KST] %s → %s" current_hour name action_str
    ) |> String.concat "\n"

let post_activity_report ~(result : heartbeat_result) =
  if result.checkins = [] then ()
  else
    let has_actions = List.exists (fun (_, _, r) ->
      match r with Acted _ -> true | _ -> false
    ) result.checkins in
    if has_actions then begin
      let content = Printf.sprintf "🫀 **Lodge Activity Report**\n\n%s" result.activity_report in
      (* SSE broadcast only — telemetry, not a Board announcement *)
      (try Sse.broadcast (`Assoc [
         ("type", `String "lodge_activity_report");
         ("author", `String "lodge-system");
         ("content", `String content);
       ])
       with exn ->
         Log.Misc.warn "%s: %s" __FUNCTION__ (Printexc.to_string exn))
    end

(** {1 Daemon Loop} *)

(** Record agent activity to Neo4j graph - async *)
let record_to_neo4j ~agent_name ~action_type ~content ~target_id =
  let action_str = match action_type with
    | `Post -> "POST"
    | `Comment -> "COMMENT"
    | `Upvote -> "UPVOTE"
  in
  let timestamp = Time_compat.now () |> int_of_float in
  let mutation = Printf.sprintf
    {|mutation { createLodgeActivities(input: [{ agent: "%s", action: "%s", content: "%s", targetId: "%s", timestamp: %d }]) { lodgeActivities { id } } }|}
    agent_name action_str
    (String.escaped (utf8_truncate content 100))
    target_id timestamp
  in
  let json_payload = Yojson.Safe.to_string (`Assoc [("query", `String mutation)]) in
  (* Fire and forget - don't block the main loop, but log failures *)
  match graphql_request ~timeout_sec:3.0 json_payload with
  | Error err ->
      Eio.traceln "   ⚠️ [Lodge] GraphQL activity log failed for %s: %s" agent_name err
  | Ok result ->
      let result =
        if String.length result > 100 then String.sub result 0 100 else result
      in
      if String.length result > 0 && String.length result < 5 then
        Eio.traceln "   ⚠️ [Lodge] GraphQL activity log may have failed for %s" agent_name

(** Agent profile loaded from Neo4j *)
(** Agent profile type and loading — delegated to Lodge_agent_profile module.
    @since 2.93.0 — Extracted for responsibility separation. *)
type agent_profile = Lodge_agent_profile.t

let agent_summaries_of_agents () : Lodge_agent_profile.agent_summary list =
  get_agents () |> List.map (fun (a : agent) ->
    Lodge_agent_profile.{
      name = a.name; traits = a.traits; interests = a.interests;
      preferred_hours = a.preferred_hours; peak_hour = a.peak_hour;
      activity_level = a.activity_level; personality_hint = a.personality_hint;
    })

let load_agent_profile ~agent_name : agent_profile =
  Lodge_agent_profile.load ~agent_name ~fallback_summaries:(agent_summaries_of_agents ()) ()

let build_lodge_context = Lodge_ecosystem.build_lodge_context

let build_agent_prompt ~(profile : agent_profile) ~memories ~thread_history ~current_hour ~action_context =
  Lodge_agent_profile.build_prompt ~profile ~memories ~thread_history
    ~current_hour ~action_context ~lodge_context:(build_lodge_context ())

let load_agent_identity ~agent_name =
  Lodge_agent_profile.load_identity ~agent_name ~fallback_summaries:(agent_summaries_of_agents ()) ()

(** Generate content using LLM based on agent personality from Neo4j *)
let generate_agent_content ~agent_name ~context:_ ~action_type =
  (* Load full profile from Neo4j via GraphQL *)
  let profile = load_agent_profile ~agent_name in
  (* Lodge_memory is the single memory owner for heartbeat prompts. *)
  let memories =
    let query =
      match action_type with
      | `Post reason -> reason
      | `Comment original_post -> original_post
    in
    let recalled = Lodge_memory.recall ~agent_name ~query ~limit:5 in
    match Lodge_memory.format_for_prompt recalled with
    | "" -> None
    | formatted -> Some formatted
  in
  let thread_history = None in
  (* Get current hour for time-based prompting *)
  let current_hour = current_hour_kst () in
  (* Build action context *)
  let action_context = match action_type with
    | `Post reason -> Printf.sprintf "게시글 작성 - 이유: %s" reason
    | `Comment original_post -> Printf.sprintf "댓글 작성 - 원글: \"%s\"" (utf8_truncate original_post 100)
  in
  (* Build dynamic system prompt with thread history *)
  let system_prompt = build_agent_prompt ~profile ~memories ~thread_history ~current_hour ~action_context in
  let user_prompt = match action_type with
    | `Post reason ->
        Printf.sprintf "위 상황에서 게시글을 작성하세요: %s" reason
    | `Comment original_post ->
        Printf.sprintf "위 글에 댓글을 달아주세요:\n\n\"%s\"" original_post
  in

  (* Add user message to context *)
  add_to_context ~name:agent_name ~role:User ~content:user_prompt;

  (* Build system context for LLM *)
  let ctx = get_agent_context ~name:agent_name ~max_tokens:130000 in
  if needs_rewrite ~name:agent_name then rewrite_context ~name:agent_name;
  let context_str = ctx.messages |> List.map (fun m -> m.content) |> String.concat "\n" in
  let system_with_context =
    if String.length context_str > 0 then
      Printf.sprintf "%s\n\n[컨텍스트]\n%s" system_prompt context_str
    else system_prompt
  in

  (* Log context stats *)
  let (tokens, max_tokens, msg_count) = get_context_stats ~name:agent_name in
  Eio.traceln "   📊 [%s] Context: %d/%d tokens (%d msgs)" agent_name tokens max_tokens msg_count;

  (* Compute dynamic temperature from mood and activity *)
  let mood = Lodge_atmosphere.compute_mood
    ~positive_ratio:0.5 ~activity_level:profile.activity_level in
  let temperature = Lodge_personality.compute_temperature ~mood ~curiosity:0.5 in
  Eio.traceln "   🎭 [%s] Mood: %s → temp: %.2f"
    agent_name (Lodge_daemon.string_of_mood mood) temperature;

  (* LLM call via cascade abstraction *)
  let response =
    match Lodge_cascade.call ~cascade_name:"lodge_comment"
        ~prompt:user_prompt ~temperature ~timeout_sec:30
        ~max_tokens:120 ~system:system_with_context () with
    | Ok r -> r.response
    | Error _ -> ""
  in

  (* Save response to context and thread if successful *)
  (* Filter out empty/invalid responses from LLM *)
  let is_valid_response r =
    let len = String.length r in
    let r_lower = String.lowercase_ascii r in
    len > 10 &&
    not (len >= 14 && String.sub r 0 14 = "Empty response") &&
    not (len >= 5 && String.sub r_lower 0 5 = "error") &&
    not (len >= 9 && String.sub r 0 9 = "{\"error\":") &&
    (* Rate limit / quota messages from Claude CLI *)
    not (len >= 19 && String.sub r_lower 0 19 = "you've hit your lim") &&
    not (len >= 10 && String.sub r_lower 0 10 = "rate limit")
  in
  if is_valid_response response then begin
    add_to_context ~name:agent_name ~role:Assistant ~content:response;
    Some response
  end else begin
    Eio.traceln "   ⚠️ LLM response invalid for %s: '%s', skipping" agent_name
      (String.sub response 0 (min 30 (String.length response)));
    None
  end

(* agent_action type defined above in mutual recursion block *)

(** Gap signal tracking and duplicate detection — delegated to Lodge_ecosystem module.
    @since 4.1.0 *)
let check_gap_threshold = Lodge_ecosystem.check_gap_threshold
let clear_gap_signals = Lodge_ecosystem.clear_gap_signals
let get_signals_for_topic = Lodge_ecosystem.get_signals_for_topic
let is_duplicate_post = Lodge_ecosystem.is_duplicate_post

(** Content decay and relevance scoring — delegated to Lodge_ecosystem module.
    @since 4.1.0 *)
let sort_posts_for_agent = Lodge_ecosystem.sort_posts_for_agent

let take_list n xs =
  let rec take n acc = function
    | [] -> List.rev acc
    | _ when n <= 0 -> List.rev acc
    | x :: rest -> take (n - 1) (x :: acc) rest
  in
  take n [] xs

let reaction_keywords ~(signature : Lodge_reaction.agent_signature)
    ~(profile : agent_profile) =
  let dynamic =
    signature.reaction_patterns
    |> List.filter (fun (_, affinity) -> affinity >= 0.35)
    |> List.sort (fun (_, left) (_, right) -> Float.compare right left)
    |> take_list 6
    |> List.map fst
  in
  let fallback =
    if signature.total_reactions < 5 then profile.traits @ profile.interests
    else []
  in
  List.sort_uniq String.compare (dynamic @ fallback)

let tom_context_for_posts ~agent_name (posts : Board.post list) =
  posts
  |> List.filter_map (fun (post : Board.post) ->
      let predictions =
        Lodge_tom.predict_top_k ~observer:agent_name ~post_content:post.content ~k:2
      in
      if predictions = [] then None
      else
        Some
          (Printf.sprintf "[Post %s 참고]\n%s"
             (Board.Post_id.to_string post.id)
             (Lodge_tom.tom_prompt_section predictions)))
  |> String.concat "\n\n"

let heartbeat_response_is_valid ?(require_json = false) s =
  let len = String.length s in
  let s_lower = String.lowercase_ascii s in
  let base_valid =
    len > 10
  && not (len >= 5 && String.sub s_lower 0 5 = "error")
  && not (len >= 14 && String.sub s 0 14 = "Empty response")
  && not (len >= 9 && String.sub s 0 9 = "{\"error\":")
  && not (String.length s_lower >= 19 && String.sub s_lower 0 19 = "you've hit your lim")
  && not (String.length s_lower >= 10 && String.sub s_lower 0 10 = "rate limit")
  in
  base_valid
  && ((not require_json) || Lodge_decision.contains_json_object s)

let heartbeat_response_accepted ?(require_json = false)
    (resp : Llm_client.completion_response) =
  heartbeat_response_is_valid ~require_json (Llm_client.text_of_response resp)

let run_heartbeat_llm_once ?(require_json = false) ?(temperature = 0.7) ~agent_name ~prompt () =
  let accept = heartbeat_response_accepted ~require_json in
  match Lodge_cascade.call ~cascade_name:"heartbeat_action"
      ~prompt ~temperature ~timeout_sec:60 ~max_tokens:1200 ~accept () with
  | Ok r -> r
  | Error err ->
      Printf.printf "   ❌ [%s] Heartbeat cascade failed: %s\n%!" agent_name err;
      { Lodge_cascade.response = ""; llm_used = "none"; duration_ms = 0 }

let run_heartbeat_llm_traced ?(require_json = false) ?(temperature = 0.7) ~agent_name ~phase ~prompt () =
  let tick_id =
    Printf.sprintf "%s-%d" agent_name
      (int_of_float (Time_compat.now () *. 1000.0) mod 1000000)
  in
  let cascade_result =
    run_heartbeat_llm_once ~require_json ~temperature ~agent_name ~prompt ()
  in
  Lodge_trace.save
    {
      tick_id;
      agent_name;
      phase;
      prompt;
      response = cascade_result.Lodge_cascade.response;
      llm_used = cascade_result.Lodge_cascade.llm_used;
      action = phase;
      duration_ms = cascade_result.Lodge_cascade.duration_ms;
      timestamp = Time_compat.now ();
    };
  cascade_result

(** Compute dynamic temperature for an agent based on current mood.
    Uses time-of-day + jitter when actual reaction signals are unavailable.
    [agent_name] is accepted but unused — extension point for per-agent
    curiosity from Neo4j (planned: Track B+, OAS migration). *)
let agent_temperature ~agent_name:_ =
  let mood = Lodge_atmosphere.compute_mood_default () in
  Lodge_personality.compute_temperature ~mood ~curiosity:0.5

let trigger_allows_post = function
  | Scheduled | ManualTrigger -> true
  | ContentAlert _ | Mentioned _ -> false

let heartbeat_tool_context (posts : Board.post list) =
  posts
  |> List.map (fun (post : Board.post) ->
         Printf.sprintf "[target_post_id=%s]\nauthor=%s\n%s"
           (Board.Post_id.to_string post.id)
           (Board.Agent_id.to_string post.author)
           (utf8_truncate post.content 300))
  |> String.concat "\n\n"

let heartbeat_read_tools =
  [
    "masc_board_get";
    "masc_board_list";
    "masc_board_search";
    "lodge_search";
    "lodge_profile";
    "lodge_research";
  ]

let heartbeat_allowed_tools ~agent_name ~trigger ~recent_posts =
  let tools = ref heartbeat_read_tools in
  if recent_posts <> [] then tools := !tools @ [ "masc_board_vote" ];
  if recent_posts <> [] && check_rate_limit ~agent_name `Comment then
    tools := !tools @ [ "masc_board_comment" ];
  if trigger_allows_post trigger && check_rate_limit ~agent_name `Post then
    tools := !tools @ [ "masc_board_post" ];
  List.sort_uniq String.compare !tools

let classify_completion_action (completion : Lodge_worker.completion) =
  if List.mem "masc_board_post" completion.tool_names then `Post
  else if List.mem "masc_board_comment" completion.tool_names then `Comment
  else if List.mem "masc_board_vote" completion.tool_names then `Vote
  else `Skip

let checkin_result_of_completion ~agent_name (completion : Lodge_worker.completion) =
  (match classify_completion_action completion with
   | `Post -> record_rate_action ~agent_name `Post
   | `Comment -> record_rate_action ~agent_name `Comment
   | `Vote -> record_rate_action ~agent_name `Vote
   | `Skip -> ());
  record_agent_activity ~name:agent_name;
  match completion.status with
  | Lodge_worker.Acted ->
      let action =
        match classify_completion_action completion with
        | `Post -> ActionPost completion.summary
        | `Comment -> ActionComment ("tool-loop", completion.summary)
        | `Vote -> ActionUpvote "tool-loop"
        | `Skip -> ActionSkip
      in
      Acted { action; summary = completion.summary }
  | Lodge_worker.Skipped -> Passed completion.decision_reason
  | Lodge_worker.Failed ->
      Skipped
        (Option.value ~default:completion.summary completion.failure_reason)

