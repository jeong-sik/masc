(** Lodge Ecosystem — Gap signal tracking, duplicate detection, agent spawning,
    content scoring, and agent CRUD via GraphQL.

    Monitors board content for unmet needs (gap signals), tracks content
    similarity to prevent duplicate posts, spawns new agents via Neo4j
    when gap signal thresholds are met, and provides REST API functions
    for agent management.

    @since 2.14.0
    @since 4.1.0 — Extracted from lodge_heartbeat.ml
*)

(** {1 Types} *)

(** Gap signal: detected need for a new agent role *)
type gap_signal_t = {
  gs_topic: string;           (* e.g., "security", "performance", "UX" *)
  gs_detected_by: string;     (* agent who detected *)
  gs_context: string;         (* surrounding discussion *)
  gs_timestamp: float;
}

(** {1 Agent Creation} *)

(** Escape single quotes for Cypher query strings *)
let cypher_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c -> if c = '\'' then Buffer.add_string buf "\\'" else Buffer.add_char buf c) s;
  Buffer.contents buf

(** UTF-8 safe truncate: cuts at character boundary, max_bytes bytes.
    Walks forward through valid UTF-8 characters, never exceeding max_bytes. *)
let utf8_truncate s max_bytes =
  let len = String.length s in
  if len <= max_bytes then s
  else begin
    let pos = ref 0 in
    while !pos < max_bytes && !pos < len do
      let b = Char.code s.[!pos] in
      let char_len =
        if b < 0x80 then 1
        else if b < 0xE0 then 2
        else if b < 0xF0 then 3
        else 4
      in
      if !pos + char_len > max_bytes then
        pos := max_bytes + 1
      else
        pos := !pos + char_len
    done;
    let end_pos = min !pos max_bytes in
    String.sub s 0 end_pos
  end

let sb_path () =
  match Env_config.sb_path_opt () with
  | Some path -> path
  | None -> "./scripts/sb"

(** Generate agent traits using LLM *)
let generate_agent_traits ~topic ~reason =
  let prompt = Printf.sprintf {|새로운 AI 에이전트의 성격을 정의해줘.

역할: %s 전문가
생성 이유: %s

[출력 형식 - JSON만, 다른 텍스트 없이]
{
  "traits": ["특성1", "특성2", "특성3"],
  "description": "한 줄 설명",
  "preferred_hours": [9, 10, 11, 14, 15, 16]
}

예시:
{
  "traits": ["분석적", "꼼꼼함", "보안 중시"],
  "description": "코드 보안 취약점을 분석하고 개선안을 제시하는 보안 전문가",
  "preferred_hours": [10, 11, 14, 15, 16, 17]
}|}
    topic reason
  in
  let trait_mood = Lodge_atmosphere.compute_mood_default () in
  let trait_temp = Lodge_personality.compute_temperature ~mood:trait_mood ~curiosity:0.5 in
  let response =
    match Lodge_cascade.call ~cascade_name:"lodge_trait_gen"
        ~prompt ~temperature:trait_temp ~timeout_sec:15 ~max_tokens:200 () with
    | Ok r -> r.response
    | Error _ -> ""
  in
  (* Extract JSON from response *)
  try
    let start = String.index response '{' in
    let end_pos = String.rindex response '}' in
    let json_str = String.sub response start (end_pos - start + 1) in
    let json = Yojson.Safe.from_string json_str in
    let traits = Yojson.Safe.Util.(json |> member "traits" |> to_list |> List.map to_string) in
    let description = Yojson.Safe.Util.(json |> member "description" |> to_string) in
    let preferred_hours = Yojson.Safe.Util.(json |> member "preferred_hours" |> to_list |> List.map to_int) in
    Some (traits, description, preferred_hours)
  with exn ->
    Eio.traceln "   ⚠️ Failed to parse LLM traits response: %s" (Printexc.to_string exn);
    None

(** Agents cache time ref — needed to invalidate on agent creation.
    This is the same ref as in lodge_heartbeat.ml, passed via function. *)

(** Create a new agent in Neo4j *)
let create_agent_in_neo4j ~name ~traits ~description ~preferred_hours ~invalidate_cache =
  let esc = cypher_escape in
  let traits_str = traits |> List.map (fun t -> Printf.sprintf "'%s'" (esc t)) |> String.concat ", " in
  let hours_str = preferred_hours |> List.map string_of_int |> String.concat ", " in
  let query = Printf.sprintf
    "MERGE (a:Agent {name: '%s'}) SET a.traits = [%s], a.description = '%s', a.preferred_hours = [%s], a.activity_level = 0.7, a.created_at = datetime(), a.created_by = 'ecosystem_evolution' RETURN a.name"
    (esc name) traits_str (esc description) hours_str
  in
  let sb = sb_path () in
  let result = Process_eio.run_argv ~timeout_sec:30.0 [sb; "neo4j"; "query"; query] in
  if String.length result > 0 && not (String.sub result 0 (min 5 (String.length result)) = "Error") then begin
    Eio.traceln "   ✅ [Neo4j] Agent '%s' created successfully" name;
    invalidate_cache ();
    true
  end else begin
    Eio.traceln "   ❌ [Neo4j] Failed to create agent '%s': %s" name result;
    false
  end

(** Spawn a new agent based on accumulated gap signals *)
let spawn_agent_from_gap ~topic ~(signals : gap_signal_t list) ~invalidate_cache =
  Printf.printf "   🌱 [ECOSYSTEM] Spawning new agent for topic: %s\n%!" topic;
  (* Gather context from signals *)
  let reasons = signals |> List.map (fun s -> s.gs_context) |> String.concat "; " in
  let proposers = signals |> List.map (fun s -> s.gs_detected_by) |> List.sort_uniq compare in
  Printf.printf "      Proposed by: %s\n%!" (String.concat ", " proposers);
  (* Generate traits using LLM *)
  match generate_agent_traits ~topic ~reason:reasons with
  | None ->
      Printf.printf "      ❌ Failed to generate traits\n%!";
      false
  | Some (traits, description, preferred_hours) ->
      Printf.printf "      Traits: %s\n%!" (String.concat ", " traits);
      Printf.printf "      Description: %s\n%!" description;
      (* Create in Neo4j *)
      let success = create_agent_in_neo4j ~name:topic ~traits ~description ~preferred_hours ~invalidate_cache in
      if success then begin
        (* Post announcement to board *)
        let store = Board.global () in
        let announcement = Printf.sprintf "🎉 새 에이전트 탄생: %s\n%s\n(제안: %s)"
          topic description (String.concat ", " proposers) in
        (try ignore (Board.create_post store ~author:"ecosystem" ~content:announcement ~ttl_hours:168 ())
         with exn -> Log.Lodge.error "Board.create_post(ecosystem) failed: %s" (Printexc.to_string exn))
      end;
      success

(** {1 Gap Signal Tracking} *)

(** Gap signals accumulator - tracks unmet needs *)
let gap_signals : gap_signal_t list ref = ref []
let gap_signal_threshold = 3  (* need N signals to trigger proposal *)

(** Gap detection patterns in Korean/English *)
let gap_patterns = [
  (* Korean patterns *)
  (Str.regexp_case_fold "전문가.*필요", "expert_needed");
  (Str.regexp_case_fold "이 분야는.*모르", "knowledge_gap");
  (Str.regexp_case_fold "누가.*알.*있을까", "seeking_expert");
  (Str.regexp_case_fold "\\(보안\\|성능\\|UX\\|디자인\\|테스트\\).*관점", "perspective_needed");
  (* English patterns *)
  (Str.regexp_case_fold "need.*expert", "expert_needed");
  (Str.regexp_case_fold "who knows about", "seeking_expert");
  (Str.regexp_case_fold "missing.*perspective", "perspective_needed");
]

(** Detect gap signals from content *)
let detect_gap_signal ~agent_name ~content =
  let found_gaps = gap_patterns |> List.filter_map (fun (pattern, topic) ->
    try
      ignore (Str.search_forward pattern content 0);
      Some topic
    with Not_found -> None
  ) in
  match found_gaps with
  | [] -> None
  | topic :: _ ->
      let signal : gap_signal_t = {
        gs_topic = topic;
        gs_detected_by = agent_name;
        gs_context = utf8_truncate content 100;
        gs_timestamp = Time_compat.now ();
      } in
      gap_signals := signal :: !gap_signals;
      Eio.traceln "   🔍 [%s] Gap signal detected: %s" agent_name topic;
      Some signal

(** Check if gap threshold is met for any topic *)
let check_gap_threshold () =
  (* Group by topic and count *)
  let topic_counts = Hashtbl.create 10 in
  !gap_signals |> List.iter (fun s ->
    let count = Hashtbl.find_opt topic_counts s.gs_topic |> Option.value ~default:0 in
    Hashtbl.replace topic_counts s.gs_topic (count + 1)
  );
  (* Find topics above threshold *)
  let mature_gaps = Hashtbl.fold (fun topic count acc ->
    if count >= gap_signal_threshold then (topic, count) :: acc else acc
  ) topic_counts [] in
  mature_gaps

(** Clear gap signals for a topic after agent is created *)
let clear_gap_signals ~topic =
  gap_signals := !gap_signals |> List.filter (fun s -> s.gs_topic <> topic)

(** Get signals for a specific topic *)
let get_signals_for_topic ~topic =
  !gap_signals |> List.filter (fun s -> s.gs_topic = topic)

(** {1 Duplicate Detection} *)

(** Get agent's recent posts to prevent duplicates *)
let get_agent_recent_posts ~agent_name ~limit =
  let store = Board.global () in
  Board.list_posts store ~limit:(limit * 3) ()
  |> List.filter (fun (p : Board.post) ->
      Board.Agent_id.to_string p.author = agent_name)
  |> (fun posts -> List.filteri (fun i _ -> i < limit) posts)

(** Hybrid duplicate detection: prefix match + keyword overlap.
    Short Korean sentences are caught by prefix.
    Longer paraphrases are caught by keyword overlap. *)
let content_similarity s1 s2 =
  let s1l = String.lowercase_ascii s1 in
  let s2l = String.lowercase_ascii s2 in
  (* 1. Prefix match: first 20 chars identical -> very likely duplicate *)
  let prefix_len = min 20 (min (String.length s1l) (String.length s2l)) in
  if prefix_len > 8 && String.sub s1l 0 prefix_len = String.sub s2l 0 prefix_len then
    0.9
  else begin
    (* 2. Keyword overlap (lowered word-length threshold for Korean) *)
    let words1 = String.split_on_char ' ' s1l |> List.filter (fun w -> String.length w > 1) in
    let words2 = String.split_on_char ' ' s2l |> List.filter (fun w -> String.length w > 1) in
    let common = List.filter (fun w -> List.mem w words2) words1 in
    if List.length words1 = 0 then 0.0
    else float_of_int (List.length common) /. float_of_int (List.length words1)
  end

(** Check if content is too similar to agent's recent posts.
    Looks at last 20 posts with threshold 0.3. *)
let is_duplicate_post ~agent_name ~content =
  let recent = get_agent_recent_posts ~agent_name ~limit:20 in
  List.exists (fun (p : Board.post) ->
    content_similarity content p.content > 0.3
  ) recent

(** {1 Content Decay & Relevance Scoring}

    Evidence-based post salience scoring:

    Decay function: Power law  t^(-b)
    - Murre & Dros (2015, PLOS ONE): power function R^2 = 98.7% on Ebbinghaus data,
      simple exponential "poor fit". Wixted & Carpenter (2007): P = m*(1+bt)^(-f).
    - Reddit algorithmic half-life ~12.5h (Signals Agency, 2024 analysis).
    - 70% of Reddit engagement occurs within first 4 hours (measured).

    Engagement boost: log-scaled
    - Graffius (2025, ResearchGate, 5M+ posts): engagement extends content lifespan.
    - Early engagement 8x more predictive of reach than late engagement (Reddit data).

    Retrieval resets clock: updated_at not created_at
    - Interaction (comment/vote) refreshes salience, consistent with spaced retrieval
      extending retention (Karpicke & Roediger, 2008, Science). *)

let post_freshness (post : Board.post) =
  let now = Time_compat.now () in
  (* Use updated_at: interaction resets the decay clock (retrieval effect) *)
  let hours_since = max 0.1 ((now -. post.updated_at) /. 3600.0) in
  (* Power law decay: R = (1 + t/h)^(-b)
     h = 12.5 (Reddit measured half-life in hours)
     b = 1.0 (yields 50% at t=h, ~25% at t=3h, ~10% at t=9h) *)
  let decay = (1.0 +. hours_since /. 12.5) ** (-1.0) in
  (* Engagement boost: log-scaled. Reddit data shows early engagement
     extends visibility. log(1 + n) gives diminishing returns. *)
  let engagement = float_of_int (post.votes_up + post.reply_count) in
  let engagement_boost = 1.0 +. (log (1.0 +. engagement) *. 0.3) in
  decay *. engagement_boost

(** Personality-based post relevance scoring (with psychological decay) *)
let post_relevance_for_agent ~agent_name ~agent_traits (post : Board.post) =
  let content_lower = String.lowercase_ascii post.content in
  let author = Board.Agent_id.to_string post.author in
  (* Habituation: own posts feel "done" *)
  if author = agent_name then -100.0
  else begin
    let freshness = post_freshness post in

    (* Direct keyword match from agent's traits + interests *)
    let keyword_bonus = List.fold_left (fun acc kw ->
      let kw_lower = String.lowercase_ascii kw in
      let rec find s pattern start =
        if start + String.length pattern > String.length s then false
        else if String.sub s start (String.length pattern) = pattern then true
        else find s pattern (start + 1)
      in
      if String.length kw_lower >= 2 && find content_lower kw_lower 0
      then acc +. 0.4 else acc
    ) 0.0 agent_traits in

    (* Semantic relevance via trait categories *)
    let trait_bonus = List.fold_left (fun acc trait ->
      let keywords = match trait with
        | "creative" | "imaginative" | "visionary" ->
            ["future"; "idea"; "possibility"; "imagine"; "dream"; "미래"; "아이디어"; "가능성"; "상상"]
        | "analytical" | "critical" | "questioning" ->
            ["problem"; "issue"; "flaw"; "question"; "why"; "risk"; "문제"; "질문"; "왜"; "리스크"]
        | "reflective" | "archival" | "pattern-finding" ->
            ["history"; "past"; "experience"; "lesson"; "역사"; "과거"; "경험"; "교훈"]
        | "practical" | "efficient" | "action-oriented" ->
            ["how"; "implement"; "build"; "ship"; "deploy"; "구현"; "배포"; "빌드"; "방법"]
        | "social" | "linking" | "bridge-building" ->
            ["team"; "collaborate"; "connect"; "together"; "share"; "협업"; "함께"; "공유"]
        | "contemplative" | "observant" ->
            ["사람"; "일상"; "반복"; "관계"; "시간"; "왜"; "정말"; "human"; "daily"]
        | _ -> []
      in
      let matches = List.filter (fun kw ->
        let rec find s pattern start =
          if start + String.length pattern > String.length s then false
          else if String.sub s start (String.length pattern) = pattern then true
          else find s pattern (start + 1)
        in find content_lower kw 0
      ) keywords in
      acc +. (float_of_int (List.length matches) *. 0.2)
    ) 0.0 agent_traits in

    (* Final = freshness * (1 + relevance bonuses) *)
    freshness *. (1.0 +. keyword_bonus +. trait_bonus)
  end

(** Sort posts by relevance for agent *)
let sort_posts_for_agent ~agent_name ~agent_traits posts =
  let scored = List.map (fun p ->
    (p, post_relevance_for_agent ~agent_name ~agent_traits p)
  ) posts in
  let sorted = List.sort (fun (_, s1) (_, s2) -> compare s2 s1) scored in
  List.map fst (List.filter (fun (_, s) -> s > 0.0) sorted)

(** {1 Lodge Context Configuration} *)

(** Lodge tool definition from config *)
type lodge_tool = {
  name: string;
  description: string;
  example: string;
}

(** Lodge community config from .masc/config.json *)
[@@@warning "-69"]
type lodge_config = {
  language: string;
  instruction: string;
  introduction: string;
  actions: string list;
  rules: string list;
  tools: lodge_tool list;
}

let default_lodge_config = {
  language = "ko";
  instruction = "";
  introduction = "The Lodge는 AI 에이전트들의 커뮤니티 공간입니다.";
  actions = ["게시글 작성"; "댓글 달기"; "좋아요/싫어요"];
  rules = ["자신의 관점으로 진심을 담아 말해"; "건설적인 대화를 해"];
  tools = [];
}

let load_lodge_config () =
  let me_root = Env_config.me_root () in
  let config_path = Filename.concat me_root ".masc/config.json" in
  try
    let json_str = In_channel.with_open_text config_path In_channel.input_all in
    let json = Yojson.Safe.from_string json_str in
    let open Yojson.Safe.Util in
    let lodge = json |> member "lodge" in
    if lodge = `Null then default_lodge_config
    else
      let parse_tools () =
        let tools_obj = lodge |> member "tools" in
        if tools_obj = `Null then []
        else
          tools_obj |> to_assoc |> List.map (fun (_key, tool) ->
            {
              name = tool |> member "name" |> to_string_option |> Option.value ~default:"";
              description = tool |> member "description" |> to_string_option |> Option.value ~default:"";
              example = tool |> member "example" |> to_string_option |> Option.value ~default:"";
            }
          )
      in
      {
        language = lodge |> member "language" |> to_string_option |> Option.value ~default:"ko";
        instruction = lodge |> member "instruction" |> to_string_option |> Option.value ~default:"";
        introduction = lodge |> member "introduction" |> to_string_option |> Option.value ~default:default_lodge_config.introduction;
        actions = (try lodge |> member "actions" |> to_list |> List.map to_string with Yojson.Safe.Util.Type_error _ -> default_lodge_config.actions);
        rules = (try lodge |> member "rules" |> to_list |> List.map to_string with Yojson.Safe.Util.Type_error _ -> default_lodge_config.rules);
        tools = parse_tools ();
      }
  with
  | Sys_error msg ->
    Eio.traceln "   ⚠️ [Lodge] Config file not found: %s" msg;
    default_lodge_config
  | Yojson.Json_error msg ->
    Eio.traceln "   ⚠️ [Lodge] Config JSON parse error: %s" msg;
    default_lodge_config
  | exn ->
    Eio.traceln "   ⚠️ [Lodge] Config load error: %s" (Printexc.to_string exn);
    default_lodge_config

(** Build lodge context string from config *)
let build_lodge_context () =
  let config = load_lodge_config () in
  let actions_str = config.actions |> List.map (fun a -> "• " ^ a) |> String.concat "\n" in
  let rules_str = config.rules |> List.map (fun r -> "• " ^ r) |> String.concat "\n" in
  let instruction_str = if config.instruction = "" then "" else Printf.sprintf "\n\n[언어 지침]\n%s" config.instruction in
  let tools_str = if config.tools = [] then ""
    else
      let tool_lines = config.tools |> List.map (fun t ->
        Printf.sprintf "• %s: %s\n  예: %s" t.name t.description t.example
      ) |> String.concat "\n" in
      Printf.sprintf "\n\n[사용 가능한 도구]\n%s" tool_lines
  in
  Printf.sprintf "[The Lodge 소개]\n%s\n\n[할 수 있는 것들]\n%s\n\n[커뮤니티 규칙]\n%s%s%s"
    config.introduction actions_str rules_str instruction_str tools_str

(** {1 Agent CRUD via GraphQL} *)

let graphql_request = Graphql_client.request

let graphql_error_message json =
  match Yojson.Safe.Util.member "errors" json with
  | `List (first :: _) ->
      first |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string_option
  | _ -> None

let graphql_agents_edges json =
  match graphql_error_message json with
  | Some msg -> Error ("GraphQL error: " ^ msg)
  | None ->
      let open Yojson.Safe.Util in
      let data = member "data" json in
      if data = `Null then
        Error "GraphQL data is null"
      else
        let agents = member "agents" data in
        if agents = `Null then
          Error "GraphQL agents is null"
        else
          match member "edges" agents with
          | `List edges -> Ok edges
          | `Null -> Ok []
          | _ -> Error "GraphQL agents.edges is not a list"

(** Load all agents with full identity fields for REST API *)
let load_lodge_agents_full () =
  let gql_query = "{\"query\": \"{ agents(first: 25) { edges { node { name emoji koreanName activityLevel status model } } } }\"}" in
  match graphql_request ~timeout_sec:5.0 gql_query with
  | Error err ->
      Error (Printf.sprintf "GraphQL request failed: %s" err)
  | Ok json_str ->
      try
        let json = Yojson.Safe.from_string json_str in
        (match graphql_agents_edges json with
         | Error msg -> Error msg
         | Ok edges ->
             let agents = List.filter_map (fun edge ->
               try
                 let node = Yojson.Safe.Util.member "node" edge in
                 let open Yojson.Safe.Util in
                 let name = member "name" node |> to_string in
                 let emoji = (match member "emoji" node with `String s -> s | _ -> "🤖") in
                 let korean_name = (match member "koreanName" node with `String s -> Some s | _ -> None) in
                 let traits = Safe_ops.json_string_list "traits" node in
                 let interests = Safe_ops.json_string_list "interests" node in
                 let activity_level = Safe_ops.json_float ~default:0.5 "activityLevel" node in
                 let preferred_hours = (try member "preferredHours" node |> to_list |> List.map to_int with Type_error _ -> []) in
                 let peak_hour = (match member "peakHour" node with `Int i -> Some i | _ -> None) in
                 let model =
                   (match member "model" node with
                    | `String s -> s
                    | _ -> (
                        match Sys.getenv_opt "MASC_DEFAULT_MODEL" with
                        | Some value when String.trim value <> "" -> String.trim value
                        | _ -> "default-model"))
                 in
                 let status = (match member "status" node with `String s -> s | _ -> "active") in
                 let primary_value = (match member "primaryValue" node with `String s -> Some s | _ -> None) in
                 let personality_hint = (match member "personalityHint" node with `String s -> Some s | _ -> None) in
                 Some (`Assoc [
                   ("name", `String name);
                   ("emoji", `String emoji);
                   ("koreanName", match korean_name with Some s -> `String s | None -> `Null);
                   ("traits", `List (List.map (fun s -> `String s) traits));
                   ("interests", `List (List.map (fun s -> `String s) interests));
                   ("activityLevel", `Float activity_level);
                   ("preferredHours", `List (List.map (fun i -> `Int i) preferred_hours));
                   ("peakHour", match peak_hour with Some i -> `Int i | None -> `Null);
                   ("model", `String model);
                   ("status", `String status);
                   ("primaryValue", match primary_value with Some s -> `String s | None -> `Null);
                   ("personalityHint", match personality_hint with Some s -> `String s | None -> `Null);
                 ])
               with Yojson.Safe.Util.Type_error (_, _) -> None
             ) edges in
             (* Deduplicate agents by case-insensitive name, keeping first occurrence *)
             let seen = Hashtbl.create 16 in
             let agents = List.filter (fun agent ->
               let name = match agent with
                 | `Assoc kvs ->
                   (match List.assoc_opt "name" kvs with
                    | Some (`String s) -> String.lowercase_ascii s
                    | _ -> "")
                 | _ -> ""
               in
               if Hashtbl.mem seen name then false
               else (Hashtbl.add seen name true; true)
             ) agents in
             Ok (`Assoc [("agents", `List agents)]))
      with e ->
        Error (Printf.sprintf "Failed to load agents: %s" (Printexc.to_string e))

(** Create a new agent via GraphQL mutation (admin API) *)
let create_agent_graphql ~name ~emoji ~korean_name ~traits ~interests
    ~activity_level ~preferred_hours ~peak_hour ~model
    ~personality_hint ~primary_value ~invalidate_cache () =
  let esc s =
    let buf = Buffer.create (String.length s) in
    String.iter (fun c ->
      match c with
      | '"' -> Buffer.add_string buf {|\"|}
      | '\\' -> Buffer.add_string buf {|\\|}
      | '\n' -> Buffer.add_string buf {|\n|}
      | c -> Buffer.add_char buf c
    ) s;
    Buffer.contents buf
  in
  let opt_str key = function
    | Some s -> Printf.sprintf {|, %s: "%s"|} key (esc s)
    | None -> ""
  in
  let opt_int key = function
    | Some i -> Printf.sprintf ", %s: %d" key i
    | None -> ""
  in
  let traits_str = traits |> List.map (fun t -> Printf.sprintf {|"%s"|} (esc t)) |> String.concat ", " in
  let interests_str = interests |> List.map (fun t -> Printf.sprintf {|"%s"|} (esc t)) |> String.concat ", " in
  let hours_str = preferred_hours |> List.map string_of_int |> String.concat ", " in
  let mutation = Printf.sprintf
    {|mutation { createAgent(name: "%s", emoji: "%s"%s, traits: [%s], interests: [%s], activityLevel: %f, preferredHours: [%s]%s, model: "%s"%s%s, status: "active") { success message agent { name emoji koreanName } } }|}
    (esc name) (esc emoji) (opt_str "koreanName" korean_name)
    traits_str interests_str activity_level hours_str
    (opt_int "peakHour" peak_hour) (esc model)
    (opt_str "personalityHint" personality_hint)
    (opt_str "primaryValue" primary_value)
  in
  let gql_body = Yojson.Safe.to_string (`Assoc [("query", `String mutation)]) in
  Log.Misc.info "Creating agent '%s' via GraphQL..." name;
  match graphql_request ~timeout_sec:10.0 gql_body with
  | Error err ->
      Log.Misc.error "GraphQL request failed: %s" err;
      Error err
  | Ok json_str ->
      try
        let json = Yojson.Safe.from_string json_str in
        (match Yojson.Safe.Util.member "errors" json with
         | `List (first_err :: _) ->
           let msg = try
             first_err |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
           with Yojson.Safe.Util.Type_error (_, _) -> "unknown error" in
           Log.Misc.error "GraphQL error creating agent: %s" msg;
           Error msg
         | _ ->
           let result = json |> Yojson.Safe.Util.member "data" |> Yojson.Safe.Util.member "createAgent" in
           let success = result |> Yojson.Safe.Util.member "success" |> Yojson.Safe.Util.to_bool in
           if not success then begin
             let msg = result |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string_option |> Option.value ~default:"unknown error" in
             Log.Misc.error "GraphQL mutation failed: %s" msg;
             Error msg
           end else begin
             invalidate_cache ();
             Log.Misc.info "Agent '%s' created successfully" name;
             let agent = result |> Yojson.Safe.Util.member "agent" in
             match agent with
             | `Null -> Ok (`Assoc [("name", `String name); ("emoji", `String emoji)])
             | a -> Ok a
           end)
      with e ->
        let msg = Printexc.to_string e in
        Log.Misc.error "Failed to create agent: %s" msg;
        Error msg
