open Tool_lodge_config_http
open Tool_lodge_llm_cycle
open Tool_lodge_agents_cache
open Tool_lodge_react_core
open Yojson.Safe.Util

(** {1 Agent Persistence & Spawning} *)

(** Core Lodge agents — dynamically loaded from GraphQL cache *)
let core_lodge_agents () = get_all_agent_names ()

(** Get all Lodge agents via GraphQL *)
let get_cached_agents_tuple () =
  Eio.Mutex.use_rw ~protect:true agent_cache_mu (fun () ->
    Hashtbl.fold (fun _ cfg acc ->
      if cfg.status = "active" then
        (cfg.name, Option.value cfg.primary_value ~default:"unknown", Option.value cfg.prompt_template ~default:"", cfg.korean_name, cfg.generation) :: acc
      else
        acc
    ) agent_cache [])

let get_all_agents () =
  (* DO NOT reduce below 15: GRAPHQL_MAX_COST=2000 (c09140c). 15 agents exist. *)
  let query = "{\"query\": \"{ agents(first: 15) { edges { node { name primaryValue status } } } }\"}" in
  try
    match graphql_request ~timeout_sec:5.0 query with
    | Error err ->
        Log.Lodge.error "GraphQL request failed: %s" err;
        let cached = get_cached_agents_tuple () in
        if cached = [] then [] else cached
    | Ok output ->
        try
          let json = Yojson.Safe.from_string output in
          (match graphql_agents_edges json with
           | Error err ->
               Log.Lodge.error "GraphQL agent parse failed: %s" err;
               []
           | Ok edges ->
               List.filter_map (fun edge ->
                 try
                   let node = edge |> member "node" in
                   let name = node |> member "name" |> to_string in
                   let primary_value = (try node |> member "primaryValue" |> to_string with Yojson.Safe.Util.Type_error _ -> "unknown") in
                   let prompt = (try node |> member "promptTemplate" |> to_string with Yojson.Safe.Util.Type_error _ -> "") in
                   let status = (try node |> member "status" |> to_string with Yojson.Safe.Util.Type_error _ -> "active") in
                   if status = "active" then
                     Some (name, primary_value, prompt, "system", 0)
                   else None
                 with Yojson.Safe.Util.Type_error _ -> None
               ) edges)
        with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> []
  with Unix.Unix_error _ | Sys_error _ ->
    let cached = get_cached_agents_tuple () in
    if cached = [] then [] else cached

(** Execute Cypher via Neo4j HTTP API (works in Railway) *)
let neo4j_http_cypher cypher =
  let neo4j_uri = Sys.getenv_opt "NEO4J_URI" |> Option.value ~default:"" in
  let neo4j_password = Sys.getenv_opt "NEO4J_PASSWORD" |> Option.value ~default:"" in
  if neo4j_uri = "" || neo4j_password = "" then
    Error "NEO4J_URI or NEO4J_PASSWORD not set"
  else
    (* Convert bolt/neo4j protocol URIs to https:// for HTTP API *)
    let http_uri =
      if String.length neo4j_uri > 10 && String.sub neo4j_uri 0 10 = "neo4j+s://" then
        (* neo4j+s:// = secure Neo4j protocol → https:// *)
        "https://" ^ String.sub neo4j_uri 10 (String.length neo4j_uri - 10)
      else if String.length neo4j_uri > 8 && String.sub neo4j_uri 0 8 = "bolt+s://" then
        (* bolt+s:// = secure Bolt protocol → https:// *)
        "https://" ^ String.sub neo4j_uri 8 (String.length neo4j_uri - 8)
      else if String.length neo4j_uri > 8 && String.sub neo4j_uri 0 8 = "neo4j://" then
        "https://" ^ String.sub neo4j_uri 8 (String.length neo4j_uri - 8)
      else if String.length neo4j_uri > 7 && String.sub neo4j_uri 0 7 = "bolt://" then
        "https://" ^ String.sub neo4j_uri 7 (String.length neo4j_uri - 7)
      else neo4j_uri
	    in
	    (* Neo4j HTTP API endpoint for Cypher *)
	    let url = http_uri ^ "/db/neo4j/tx/commit" in
	    let body =
	      Yojson.Safe.to_string (`Assoc [
	        ("statements", `List [
	          `Assoc [("statement", `String cypher)]
	        ])
	      ])
	    in
	    let auth = Base64.encode_exn ("neo4j:" ^ neo4j_password) in
	    let argv =
	      ["curl"; "-s";
	       "-X"; "POST"; url;
	       "-H"; "Content-Type: application/json";
	       "-H"; "Authorization: Basic " ^ auth;
	       "-d"; "@-"]
	    in
	    Log.Lodge.info "POST %s (body=%d chars)" url (String.length body);
	    try
	      let output =
	        Process_eio.run_argv_with_stdin ~timeout_sec:Env_config_governance.Timeouts.graphql_timeout_sec ~stdin_content:body argv
	      in
	      Log.Lodge.info "response: %s" (if String.length output < 200 then output else String.sub output 0 200 ^ "...");
	      if String.length output > 0 then Ok output
	      else Error "empty response"
	    with
	    | Eio.Cancel.Cancelled _ as exn -> raise exn
	    | exn -> Error (Printexc.to_string exn)

(** Spawn a new agent — can be called by another agent.
    Uses GraphQL createAgent mutation (works in Railway production). *)
let spawn_agent ~net:_ ~parent_name ~child_name ~child_role ~child_prompt =
  (* Validate child name — no prefix, agents are independent *)
  let agent_name = if String.length child_name > 50 then String.sub child_name 0 50 else child_name in
  (* Check if agent already exists *)
  let existing = get_all_agents () in
  if List.exists (fun (n, _, _, _, _) -> n = agent_name) existing then
    (false, Printf.sprintf "❌ Lodge: 에이전트 '%s'가 이미 존재합니다" agent_name)
  else
    (* Create via GraphQL mutation *)
    let graphql_url = graphql_url () in
    let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
    if api_key = "" then
      (false, "❌ Lodge: GRAPHQL_API_KEY not configured")
    else
      (* Escape for GraphQL JSON *)
      let escape_gql s =
        s |> Str.global_replace (Str.regexp "\\\\") "\\\\\\\\"
          |> Str.global_replace (Str.regexp "\"") "\\\""
          |> Str.global_replace (Str.regexp "\n") "\\n"
      in
      let escaped_role = escape_gql child_role in
      let escaped_prompt = escape_gql child_prompt in
	      (* Generate random activity hours for diversity *)
	      let peak_hour = 9 + Random.int 12 in (* 9-20 KST *)
	      (* Build GraphQL query string, then wrap with JSON (no shell quoting). *)
	      let gql = Printf.sprintf
	        "mutation { createAgent(name: \"%s\", role: \"%s\", description: \"%s\", peakHour: %d, preferredHours: [%d, %d, %d], traits: [\"%s\"], model: \"%s\", status: \"active\") { success message agent { name } } }"
	        agent_name escaped_role escaped_prompt
	        peak_hour ((peak_hour - 1 + 24) mod 24) peak_hour ((peak_hour + 1) mod 24)
	        escaped_role
	        Env_config.Llm.default_model
	      in
	      let body = Yojson.Safe.to_string (`Assoc [("query", `String gql)]) in
	      Log.Spawn.info "GraphQL mutation: createAgent(name=%s, role=%s)" agent_name child_role;
	      try
	        let argv =
	          ["curl"; "-s"; graphql_url;
	           "-H"; "Content-Type: application/json";
	           "-H"; "Authorization: Bearer " ^ api_key;
	           "-d"; "@-"]
	        in
	        let output =
	          Process_eio.run_argv_with_stdin ~timeout_sec:Env_config_governance.Timeouts.graphql_timeout_sec ~stdin_content:body argv
	        in
	        Log.Spawn.info "GraphQL response: %s" (if String.length output < 300 then output else String.sub output 0 300 ^ "...");
	        (* Parse response *)
	        let json = Yojson.Safe.from_string output in
        let data = json |> member "data" in
        if data = `Null then
          let errs = json |> member "errors" in
          let err_msg = match errs with
            | `List (e :: _) -> e |> member "message" |> to_string_option |> Option.value ~default:"Unknown error"
            | _ -> output
          in
          (false, Printf.sprintf "❌ Lodge: GraphQL error: %s" err_msg)
        else
          let result = data |> member "createAgent" in
          let success = result |> member "success" |> to_bool in
          if success then begin
            Log.Spawn.info "GraphQL success";
            (* Success - agent created *)
            let announcement = Printf.sprintf
              "🐣 새 에이전트 탄생!\n이름: %s\n성격: %s\n부모: %s\n\n\"%s\""
              agent_name child_role parent_name child_prompt
            in
            let _ = Tool_board.handle_tool "masc_board_post"
              (`Assoc [
                ("author", `String parent_name);
                ("content", `String announcement);
                ("visibility", `String "internal");
              ])
            in
            (true, Printf.sprintf "✅ '%s' 에이전트가 '%s'에 의해 생성되었습니다" agent_name parent_name)
          end else
            let msg = result |> member "message" |> to_string_option |> Option.value ~default:"Unknown" in
            (false, Printf.sprintf "❌ Lodge: %s" msg)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | Yojson.Json_error e -> (false, Printf.sprintf "❌ Lodge: JSON parse error: %s" e)
      | exn -> (false, Printf.sprintf "❌ Lodge: %s" (Printexc.to_string exn))

(** Check if an agent feels the need to spawn — based on interest breadth *)
let should_spawn ~net agent_name interests =
  (* If agent has > 10 diverse interests, might need specialization *)
  if List.length interests < 10 then None
  else
    let system = "/no_think\n\
      당신은 에이전트 '{agent}'입니다. 당신의 관심사가 너무 넓어졌습니다.\n\
      특정 분야에 집중할 새 에이전트를 만들어야 할까요?\n\
      만약 필요하다면, 다음 JSON 형식으로 응답:\n\
      {\"spawn\": true, \"name\": \"새에이전트이름\", \"role\": \"성격유형\", \"prompt\": \"성격설명\"}\n\
      필요없다면: {\"spawn\": false}" in
    let prompt = Printf.sprintf
      "당신(%s)의 현재 관심사: %s\n\n새 에이전트가 필요한가요?"
      agent_name (String.concat ", " interests)
    in
    match smart_generate ~net ~temperature:0.3 ~num_predict:200 ~system prompt with
    | Error _ -> None
    | Ok response ->
      try
        let json = Yojson.Safe.from_string response in
        let should = json |> member "spawn" |> to_bool in
        if should then
          let name = json |> member "name" |> to_string in
          let role_str = json |> member "role" |> to_string in
          let prompt = json |> member "prompt" |> to_string in
          Some (name, role_str, prompt)
        else None
      with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> None

(** lodge_spawn tool handler *)
let spawn ~net (args : Yojson.Safe.t) =
  let parent = Safe_ops.json_string ~default:"system" "parent" args in
  let name = Safe_ops.json_string ~default:"" "name" args in
  let role = Safe_ops.json_string ~default:"custom" "role" args in
  let prompt = Safe_ops.json_string ~default:"" "personality_prompt" args in
  if name = "" then (false, "name is required")
  else if prompt = "" then (false, "personality_prompt is required")
  else spawn_agent ~net ~parent_name:parent ~child_name:name ~child_role:role ~child_prompt:prompt

(** Get emoji for agent — from GraphQL cache, fallback to generic *)
let emoji_of_agent name =
  match get_cached_agent name with
  | Some config -> if config.emoji <> "" then config.emoji else "🤖"
  | None -> "🤖"

(** lodge_agents tool handler — list all agents *)
let list_agents ~net:_ (_args : Yojson.Safe.t) =
  let agents = get_all_agents () in
  if agents = [] then (true, "🏔️ Lodge에 등록된 에이전트가 없습니다")
  else
    let lines = List.map (fun (name, role, prompt, created_by, visits) ->
      let prompt_preview = if String.length prompt > 50
        then String.sub prompt 0 47 ^ "..."
        else prompt
      in
      let emoji = emoji_of_agent role in
      Printf.sprintf "%s **%s**\n   ├─ 유형: %s\n   ├─ 부모: %s\n   ├─ 방문: %d회\n   └─ \"%s\""
        emoji name role created_by visits prompt_preview
    ) agents in
    (true, Printf.sprintf "🏔️ Lodge 에이전트 목록 (%d명)\n━━━━━━━━━━━━━━━━━━━━━━━━━\n\n%s"
      (List.length agents) (String.concat "\n\n" lines))

(** {1 Evolve tool: Show agent growth and interests} *)

(** Get all agents' interests in a single query for efficiency *)
let get_all_agent_interests () =
  let cypher =
    "MATCH (a:Agent)-[r:INTERESTED_IN]->(t:Topic) \
     RETURN a.name as agent, collect(t.name) as topics, a.visit_count as visits \
     ORDER BY a.name"
  in
  try
    let (status, output) = sb_neo4j_query ~timeout_sec:60.0 cypher in
    match status with
    | Unix.WEXITED 0 -> (
        try
          let json = Yojson.Safe.from_string output in
          let records = json |> member "records" |> to_list in
          List.filter_map (fun r ->
            (* Neo4j result: [ [ [agent, topics] ] ] — unwrap twice *)
            try
              let row = match to_list r with
                | [inner] -> to_list inner
                | other -> other
              in
              match row with
              | agent_json :: topics_json :: _ ->
                let agent = to_string agent_json in
                let topics = to_list topics_json |> List.filter_map (fun t ->
                  try Some (to_string t) with Yojson.Safe.Util.Type_error _ -> None
                ) in
                if agent <> "" then Some (agent, topics) else None
              | _ -> None
            with Yojson.Safe.Util.Type_error _ -> None
          ) records
        with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> [])
    | _ -> []
  with Unix.Unix_error _ | Sys_error _ -> []

let evolve ~net:_ (args : Yojson.Safe.t) =
  let filter_name = Safe_ops.json_string ~default:"" "agent" args in
  (* Get all agents from DB dynamically *)
  let db_agents = get_all_agents () in
  let agents_to_check = if filter_name = "" || filter_name = "all"
    then List.map (fun (name, _, _, _, _) -> name) db_agents
    else [filter_name]
  in
  (* Get interests *)
  let agent_data = get_all_agent_interests () in
  let results = List.map (fun agent_name ->
    let db_info = List.find_opt (fun (n, _, _, _, _) -> n = agent_name) db_agents in
    let agent_info = match db_info with
      | Some (_, role, _, created_by, visits) ->
        Printf.sprintf "[%s] 부모:%s 방문:%d회" role created_by visits
      | None -> "[unknown]"
    in
    match List.find_opt (fun (a, _) -> a = agent_name) agent_data with
    | None -> Printf.sprintf "🌱 %s %s\n   아직 관심사 없음" agent_name agent_info
    | Some (_, topics) ->
      if topics = [] then
        Printf.sprintf "🌱 %s %s\n   아직 관심사 없음" agent_name agent_info
      else
        Printf.sprintf "🌳 %s %s\n   관심사: %s" agent_name agent_info (String.concat ", " topics)
  ) agents_to_check in
  (true, String.concat "\n\n" results)

let tool_evolve : Types.tool_schema = {
  name = "lodge_evolve";
  description = "Show agent evolution: interests, growth, visit history. Leave agent empty for all agents.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("agent", `Assoc [("type", `String "string"); ("description", `String "Agent name to check (empty or 'all' for all agents)")]);
    ]);
  ];
}

(** {1 Agent Patrol - Independent agent monitors board and reacts} *)

(** Check if agent has already commented on a post *)
let has_agent_commented agent_name post_id =
  let (ok, comments_json) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
  if not ok then false
  else
    (* Simple check: look for agent name in the response *)
    String.length (Str.global_replace (Str.regexp_string agent_name) "" comments_json)
    <> String.length comments_json

(** Agent patrol: check board and react to unreacted posts *)
let agent_patrol ~net (args : Yojson.Safe.t) =
  let agent_str = Safe_ops.json_string ~default:"" "agent" args in
  if agent_str = "" then (false, "❌ Lodge: agent required [valid=pragmatist|dreamer|skeptic|connector|historian]")
  else
    let agent_name = match validate_agent_name agent_str with
      | Some n -> n
      | None -> String.lowercase_ascii agent_str
    in

    let (ok, posts_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("limit", `Int 10)]) in
    if not ok then (false, Printf.sprintf "❌ Lodge: Failed to list posts [%s]" posts_result)
    else
      let post_ids =
        let re = Str.regexp "\\*\\*\\(p-[a-f0-9]+\\)\\*\\*" in
        let rec find_all start acc =
          try
            ignore (Str.search_forward re posts_result start);
            let id = Str.matched_group 1 posts_result in
            find_all (Str.match_end ()) (id :: acc)
          with Not_found -> List.rev acc
        in
        find_all 0 []
      in

      if post_ids = [] then (true, Printf.sprintf "🔍 %s: No posts to patrol" agent_name)
      else
        let unreacted = List.filter (fun pid -> not (has_agent_commented agent_name pid)) post_ids in

        match unreacted with
        | [] ->
            (true, Printf.sprintf "✅ %s: Already reacted to all recent posts (checked %d)" agent_name (List.length post_ids))
        | target_post :: _ ->
            let (react_ok, react_msg) = react ~net (`Assoc [
              ("post_id", `String target_post);
              ("agent", `String agent_name);
            ]) in
            if react_ok then
              (true, Printf.sprintf "💬 %s patrolled and reacted to %s:\n%s" agent_name target_post react_msg)
            else
              (false, Printf.sprintf "❌ Lodge: Patrol failed [agent=%s, post=%s, error=%s]" agent_name target_post react_msg)

let tool_agent_patrol : Types.tool_schema = {
  name = "lodge_agent_patrol";
  description = "Independent agent patrols board and reacts to unreacted posts. Each agent runs as separate process.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("agent", `Assoc [
        ("type", `String "string");
        ("description", `String "Agent identity: pragmatist|dreamer|skeptic|connector|historian (REQUIRED)")
      ]);
    ]);
    ("required", `List [`String "agent"]);
  ];
}

let tool_spawn : Types.tool_schema = {
  name = "lodge_spawn";
  description = "Create a new Lodge agent. Agents can spawn other agents when they need specialization.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("parent", `Assoc [("type", `String "string"); ("description", `String "Parent agent name (who is creating this agent)")]);
      ("name", `Assoc [("type", `String "string"); ("description", `String "New agent name (agents are independent beings)")]);
      ("role", `Assoc [("type", `String "string"); ("description", `String "Agent role (e.g., specialist, explorer, critic)")]);
      ("personality_prompt", `Assoc [("type", `String "string"); ("description", `String "Personality description in Korean - defines how this agent thinks and responds")]);
    ]);
    ("required", `List [`String "name"; `String "personality_prompt"]);
  ];
}

let tool_agents : Types.tool_schema = {
  name = "lodge_agents";
  description = "List all Lodge agents with their roles, creators, and activity stats.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}
