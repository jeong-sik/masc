(** Lodge Broadcast — Content-Aware Routing for broadcasts.

    Analyzes broadcast content and routes to relevant agents
    using keyword matching + LLM-based semantic analysis.

    Extracted from Lodge_heartbeat to reduce module size.

    @since 2.91.0
*)

(** {1 Agent Specialties} *)

let sb_path () =
  match Env_config.sb_path_opt () with
  | Some path -> path
  | None -> "./scripts/sb"

(** Load agent specialties dynamically from Neo4j *)
let load_agent_specialties_from_neo4j () =
  let query = "MATCH (a:Agent) WHERE a.traits IS NOT NULL RETURN a.name, a.traits, a.description" in
  let sb = sb_path () in
  let json_str = Process_eio.run_argv ~timeout_sec:30.0 [sb; "neo4j"; "query"; query] in
  try
    let json = Yojson.Safe.from_string json_str in
    let records = Yojson.Safe.Util.(json |> member "records" |> to_list) in
    List.filter_map (fun record ->
      try
        let arr = Yojson.Safe.Util.to_list record in
        match arr with
        | inner_node :: _ ->
          let inner = Yojson.Safe.Util.to_list inner_node in
          (match inner with
           | name_json :: traits_json :: description_json :: _ ->
             let name = Yojson.Safe.Util.to_string name_json in
             let traits =
               Yojson.Safe.Util.(traits_json |> to_list |> List.map to_string)
             in
             let description =
               match description_json with
               | `Null -> ""
               | `String s -> s
               | _ -> ""
             in
             let desc_words = description
               |> String.split_on_char ' '
               |> List.filter (fun w -> String.length w > 3)
             in
             Some (name, traits @ desc_words)
           | _ -> None)
        | [] -> None
      with Yojson.Safe.Util.Type_error _ | Failure _ -> None
    ) records
  with
  | Yojson.Json_error msg ->
    Eio.traceln "⚠️ Failed to parse Neo4j specialties JSON: %s" msg;
    []
  | Yojson.Safe.Util.Type_error (msg, _) ->
    Eio.traceln "⚠️ Neo4j specialties structure mismatch: %s" msg;
    []
  | exn ->
    Eio.traceln "⚠️ Failed to load agent specialties: %s" (Printexc.to_string exn);
    []

(** Cached agent specialties - refreshed every 5 minutes *)
let specialties_cache : (string * string list) list ref = ref []
let specialties_cache_time = ref 0.0

let get_agent_specialties () =
  let now = Time_compat.now () in
  if !specialties_cache = [] || now -. !specialties_cache_time > 300.0 then begin
    specialties_cache := load_agent_specialties_from_neo4j ();
    specialties_cache_time := now;
    Eio.traceln "🔄 Loaded %d agent specialties from Neo4j" (List.length !specialties_cache)
  end;
  !specialties_cache

(** {1 Keyword Matching} *)

(** Calculate keyword match score for an agent *)
let keyword_match_score ~agent_name ~content =
  let specialties = get_agent_specialties () in
  match List.assoc_opt agent_name specialties with
  | None -> 0.0
  | Some keywords ->
      let content_lower = String.lowercase_ascii content in
      let matches = List.filter (fun kw ->
        let kw_lower = String.lowercase_ascii kw in
        let rec find_substring s pattern start =
          if start + String.length pattern > String.length s then false
          else if String.sub s start (String.length pattern) = pattern then true
          else find_substring s pattern (start + 1)
        in
        find_substring content_lower kw_lower 0
      ) keywords in
      let match_count = List.length matches in
      let total_keywords = List.length keywords in
      if total_keywords = 0 then 0.0
      else float_of_int match_count /. float_of_int total_keywords

(** {1 LLM Relevance Analysis} *)

(** Analyze broadcast relevance using LLM for deeper understanding *)
let analyze_broadcast_relevance_llm ~content ~available_agents =
  let agents_str = available_agents
    |> List.map (fun name ->
        let keywords = List.assoc_opt name (get_agent_specialties ()) |> Option.value ~default:[] in
        Printf.sprintf "- %s: %s" name (String.concat ", " keywords))
    |> String.concat "\n"
  in
  let prompt = Printf.sprintf
    "다음 브로드캐스트 메시지를 분석하고, 가장 관련 있는 에이전트를 선택하세요.\n\n\
     [메시지]\n%s\n\n\
     [에이전트 목록]\n%s\n\n\
     관련도가 높은 에이전트 이름만 콤마로 구분하여 답변하세요. 관련 없으면 'none'이라고 답변하세요.\n\
     예: dreamer, historian"
    content agents_str
  in
  let response =
    match Lodge_cascade.call ~cascade_name:"lodge_agent_match"
        ~prompt ~temperature:0.1 ~timeout_sec:15 ~max_tokens:200 () with
    | Ok r -> r.response
    | Error _ -> ""
  in
  if String.length response < 3 || response = "none" then []
  else begin
    response
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun name -> List.mem_assoc name (get_agent_specialties ()))
  end

(** {1 Routing Mode} *)

type routing_mode = Heuristic | Llm | Hybrid

let get_routing_mode () =
  match Sys.getenv_opt "MASC_LODGE_ROUTING_MODE" with
  | Some "heuristic" -> Heuristic
  | Some "llm" -> Llm
  | Some "hybrid" -> Hybrid
  | _ -> Llm  (* default: LLM-first *)

(** {1 Agent Routing} *)

(** Find relevant agents for a broadcast message.
    Routing mode controls the strategy:
    - [Llm]: LLM first, keyword fallback (default, higher quality)
    - [Heuristic]: keyword only (fast, no LLM cost)
    - [Hybrid]: LLM first, merge with keyword matches *)
let find_relevant_agents ~content ~threshold =
  let available_agents = List.map fst (get_agent_specialties ()) in
  let keyword_matches () =
    available_agents
    |> List.map (fun name -> (name, keyword_match_score ~agent_name:name ~content))
    |> List.filter (fun (_, score) -> score >= threshold)
    |> List.map fst
  in
  match get_routing_mode () with
  | Heuristic ->
      let matches = keyword_matches () in
      if matches <> [] then
        Eio.traceln "   🔍 Keyword match: [%s]" (String.concat ", " matches);
      matches
  | Llm ->
      let llm_matches = analyze_broadcast_relevance_llm ~content ~available_agents in
      if llm_matches <> [] then begin
        Eio.traceln "   🧠 LLM match: [%s]" (String.concat ", " llm_matches);
        llm_matches
      end else begin
        Eio.traceln "   🔍 LLM returned none, falling back to keyword...";
        keyword_matches ()
      end
  | Hybrid ->
      let llm_matches = analyze_broadcast_relevance_llm ~content ~available_agents in
      let kw_matches = keyword_matches () in
      let merged = List.sort_uniq String.compare (llm_matches @ kw_matches) in
      if merged <> [] then
        Eio.traceln "   🔀 Hybrid match: [%s]" (String.concat ", " merged);
      merged

(** {1 Broadcast Handling} *)

(** Type for content generation function injected from lodge_heartbeat *)
type generate_content_fn =
  agent_name:string ->
  context:string ->
  action_type:[`Post of string | `Comment of string] ->
  string option

(** Handle a broadcast message - route to relevant agents.
    [generate_content] is injected to avoid circular dependency with lodge_heartbeat. *)
let handle_broadcast ~generate_content ~sender ~content =
  Eio.traceln "📢 Handling broadcast from %s: %s" sender
    (String.sub content 0 (min 50 (String.length content)));

  let relevant = find_relevant_agents ~content ~threshold:0.2 in
  let relevant = List.filter (fun name -> name <> sender) relevant in

  if List.length relevant = 0 then begin
    Eio.traceln "   ⏭️ No relevant agents for this broadcast";
    []
  end else begin
    Eio.traceln "   🎯 Routing to: [%s]" (String.concat ", " relevant);
    relevant |> List.filter_map (fun agent_name ->
      match generate_content
        ~agent_name
        ~context:content
        ~action_type:(`Comment (Printf.sprintf "[Broadcast from %s] %s" sender content))
      with
      | None -> None
      | Some response ->
          Eio.traceln "   💬 [%s] Responded: %s" agent_name response;
          let store = Board.global () in
          let reply_content = Printf.sprintf "@%s %s" sender response in
          (match Board.create_post store ~author:agent_name ~content:reply_content ~ttl_hours:168 () with
          | Ok post ->
              Eio.traceln "   📝 [%s] Posted reply: %s" agent_name (Board.Post_id.to_string post.id);
              Some (agent_name, response)
          | Error e ->
              Eio.traceln "   ❌ [%s] Reply failed: %s" agent_name (Board.show_board_error e);
              Some (agent_name, response))
    )
  end

(** Poll for recent broadcasts and handle them.
    [generate_content] is injected from lodge_heartbeat. *)
let poll_and_handle_broadcasts ~generate_content ~since_timestamp =
  let store = Board.global () in
  let recent_posts = Board.list_posts store ~limit:20 () in
  let broadcasts = recent_posts |> List.filter (fun (post : Board.post) ->
    post.created_at > since_timestamp &&
    (String.length post.content >= 2 &&
     (let content = post.content in
      let has_at_all =
        let rec find s pattern start =
          if start + String.length pattern > String.length s then false
          else if String.sub s start (String.length pattern) = pattern then true
          else find s pattern (start + 1)
        in
        find (String.lowercase_ascii content) "@all" 0
      in
      let has_emoji = String.length content >= 4 &&
        String.sub content 0 4 = "\xf0\x9f\x93\xa2"
      in
      has_at_all || has_emoji))
  ) in
  Eio.traceln "🔔 Found %d new broadcasts since %.0f" (List.length broadcasts) since_timestamp;
  broadcasts |> List.iter (fun (post : Board.post) ->
    let sender = Board.Agent_id.to_string post.author in
    (try ignore (handle_broadcast ~generate_content ~sender ~content:post.content)
     with exn -> Log.Lodge.error "handle_broadcast(%s) failed: %s" sender (Printexc.to_string exn))
  );
  Time_compat.now ()
