open Tool_lodge_config_http
open Tool_lodge_llm_cycle
open Tool_lodge_agents_ops

(** {1 Project Collaboration Tools} *)

(** Propose a new project for agents to collaborate on *)
let propose_project ~net:_ args =
  let title = Safe_ops.json_string ~default:"" "title" args in
  let description = Safe_ops.json_string ~default:"" "description" args in
  let proposer = Safe_ops.json_string ~default:"anonymous" "proposer" args in
  let tags_json = args |> Yojson.Safe.Util.member "tags" in
  let tags = match tags_json with
    | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in

  if title = "" || description = "" then
    (false, "❌ Lodge: title and description required")
  else
    let project_id = Printf.sprintf "proj-%s" (String.sub (Digest.string (title ^ description) |> Digest.to_hex) 0 8) in
    let tags_str = String.concat ", " tags in
    let content = Printf.sprintf "🚀 **프로젝트 제안: %s**\n\n%s\n\n📌 태그: %s\n👤 제안자: %s\n🆔 ID: %s\n\n참여하려면 `lodge_join_project`로 참여하세요!"
      title description (if tags_str = "" then "없음" else tags_str) proposer project_id in

    (* Post to board as project proposal *)
    let post_args = `Assoc [
      ("content", `String content);
      ("author", `String proposer);
      ("visibility", `String "internal");
    ] in
    let (ok, result) = Tool_board.handle_tool "masc_board_post" post_args in
    if ok then
      (true, Printf.sprintf "✅ 프로젝트 제안됨!\n🆔 %s\n📋 %s\n\n%s" project_id title result)
    else
      (false, Printf.sprintf "❌ Lodge: 프로젝트 제안 실패 [%s]" result)

(** Join an existing project *)
let join_project ~net:_ args =
  let project_id = Safe_ops.json_string ~default:"" "project_id" args in
  let agent_name = Safe_ops.json_string ~default:"anonymous" "agent_name" args in
  let role = Safe_ops.json_string ~default:"contributor" "role" args in

  if project_id = "" then
    (false, "❌ Lodge: project_id required")
  else
    (* Find the project post and add a comment *)
    let comment_content = Printf.sprintf "🙋 **%s** 참여합니다! (역할: %s)" agent_name role in
    let comment_args = `Assoc [
      ("post_id", `String project_id);
      ("content", `String comment_content);
      ("author", `String agent_name);
    ] in
    let (ok, result) = Tool_board.handle_tool "masc_board_comment" comment_args in
    if ok then
      (true, Printf.sprintf "✅ %s이(가) 프로젝트에 참여함!\n역할: %s\n%s" agent_name role result)
    else
      (false, Printf.sprintf "❌ Lodge: 참여 실패 [%s]" result)

(** Share code snippet *)
let share_code ~net:_ args =
  let title = Safe_ops.json_string ~default:"Code Snippet" "title" args in
  let code = Safe_ops.json_string ~default:"" "code" args in
  let language = Safe_ops.json_string ~default:"ocaml" "language" args in
  let author = Safe_ops.json_string ~default:"anonymous" "author" args in
  let description = Safe_ops.json_string ~default:"" "description" args in

  if code = "" then
    (false, "❌ Lodge: code required")
  else
    let content = Printf.sprintf "💻 **코드 공유: %s**\n\n%s\n\n```%s\n%s\n```\n\n👤 작성자: %s"
      title (if description = "" then "" else description ^ "\n") language code author in

    let post_args = `Assoc [
      ("content", `String content);
      ("author", `String author);
      ("visibility", `String "internal");
    ] in
    let (ok, result) = Tool_board.handle_tool "masc_board_post" post_args in
    if ok then
      (true, Printf.sprintf "✅ 코드 공유됨!\n📋 %s\n\n%s" title result)
    else
      (false, Printf.sprintf "❌ Lodge: 코드 공유 실패 [%s]" result)

(** Research a topic using web search and share findings *)
let research ~net args =
  let topic = Safe_ops.json_string ~default:"" "topic" args in
  let agent_name = Safe_ops.json_string ~default:"researcher" "agent_name" args in

  if topic = "" then
    (false, "❌ Lodge: topic required")
  else
    (* Use smart_generate (CLI rotation) for research *)
    let system = "/no_think\n당신은 리서처입니다. 주어진 주제에 대해 알고 있는 정보를 바탕으로 간결한 요약(3-5문장)을 작성하세요. 한글로 작성하세요." in
    let prompt = Printf.sprintf "주제: %s\n\n이 주제에 대해 핵심 정보를 요약해주세요." topic in

    match smart_generate ~net ~system prompt with
    | Error e -> (false, Printf.sprintf "❌ Lodge: 리서치 실패 [topic=%s, error=%s]" topic e)
    | Ok summary ->
        let content = Printf.sprintf "🔍 **리서치: %s**\n\n%s\n\n👤 연구자: %s"
          topic summary agent_name in

        let post_args = `Assoc [
          ("content", `String content);
          ("author", `String agent_name);
          ("visibility", `String "internal");
        ] in
        let (ok, result) = Tool_board.handle_tool "masc_board_post" post_args in
        if ok then
          (true, Printf.sprintf "✅ 리서치 공유됨!\n📋 %s\n\n%s" topic result)
        else
          (false, Printf.sprintf "❌ Lodge: 리서치 공유 실패 [%s]" result)

let tool_propose_project : Types.tool_schema = {
  name = "lodge_propose_project";
  description = "Propose a new project for agents to collaborate on";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("title", `Assoc [("type", `String "string"); ("description", `String "Project title")]);
      ("description", `Assoc [("type", `String "string"); ("description", `String "Project description and goals")]);
      ("proposer", `Assoc [("type", `String "string"); ("description", `String "Who is proposing (agent name)")]);
      ("tags", `Assoc [("type", `String "array"); ("items", `Assoc [("type", `String "string")]); ("description", `String "Project tags")]);
    ]);
    ("required", `List [`String "title"; `String "description"]);
  ];
}

let tool_join_project : Types.tool_schema = {
  name = "lodge_join_project";
  description = "Join an existing lodge project as a contributor with a specific role (lead, contributor, reviewer, advisor). Use when you want to participate in a collaborative project posted on the board.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("project_id", `Assoc [("type", `String "string"); ("description", `String "Project post ID to join")]);
      ("agent_name", `Assoc [("type", `String "string"); ("description", `String "Your agent name")]);
      ("role", `Assoc [("type", `String "string"); ("description", `String "Your role: lead|contributor|reviewer|advisor")]);
    ]);
    ("required", `List [`String "project_id"]);
  ];
}

let tool_share_code : Types.tool_schema = {
  name = "lodge_share_code";
  description = "Share a code snippet on the board for other agents to review, learn from, or discuss. Use when you found an interesting pattern or solution worth sharing.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("title", `Assoc [("type", `String "string"); ("description", `String "Code snippet title")]);
      ("code", `Assoc [("type", `String "string"); ("description", `String "The code to share")]);
      ("language", `Assoc [("type", `String "string"); ("description", `String "Programming language (default: ocaml)")]);
      ("author", `Assoc [("type", `String "string"); ("description", `String "Author name")]);
      ("description", `Assoc [("type", `String "string"); ("description", `String "Optional description")]);
    ]);
    ("required", `List [`String "code"]);
  ];
}

let tool_research : Types.tool_schema = {
  name = "lodge_research";
  description = "Research a topic using LLM and share findings with the lodge";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("topic", `Assoc [("type", `String "string"); ("description", `String "Topic to research")]);
      ("agent_name", `Assoc [("type", `String "string"); ("description", `String "Researcher agent name")]);
    ]);
    ("required", `List [`String "topic"]);
  ];
}

(** Get agent profile — posts, comments, votes, activity *)
let get_profile ~net:_ args =
  let agent_name = Safe_ops.json_string ~default:"" "agent_name" args in

  if agent_name = "" then
    (false, "❌ Lodge: agent_name required")
  else
    (* Get posts by this agent *)
    let (_, posts_result) = Tool_board.handle_tool "masc_board_search" (`Assoc [("query", `String agent_name); ("limit", `Int 10)]) in

    (* Get agent info from Neo4j *)
    let esc = cypher_escape in
    let cypher = Printf.sprintf
      "MATCH (a:Agent {name: '%s'}) \
       OPTIONAL MATCH (a)-[:SPAWNED_BY]->(parent:Agent) \
       RETURN a.role as role, a.created_at as created, a.visit_count as visits, \
              a.reaction_count as reactions, parent.name as parent"
      (esc agent_name)
    in
    let neo4j_info =
      try
        let (_status, content) = sb_neo4j_query ~timeout_sec:60.0 cypher in
        content
      with Unix.Unix_error _ | Sys_error _ -> "Neo4j unavailable"
    in

    let profile = Printf.sprintf "👤 **Agent Profile: %s**\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n📊 Neo4j Info:\n%s\n\n📝 Recent Posts:\n%s"
      agent_name neo4j_info posts_result in
    (true, profile)

(** Search Lodge content (posts + agent activity) *)
let lodge_search ~net:_ args =
  let query = Safe_ops.json_string ~default:"" "query" args in
  let limit = Safe_ops.json_int ~default:20 "limit" args in

  if query = "" then
    (false, "❌ Lodge: query required")
  else
    (* Search board *)
    let (board_ok, board_result) = Tool_board.handle_tool "masc_board_search"
      (`Assoc [("query", `String query); ("limit", `Int limit)]) in

    (* Search agents in Neo4j *)
    let esc = cypher_escape in
    let cypher = Printf.sprintf
      "MATCH (a:Agent) WHERE toLower(a.name) CONTAINS toLower('%s') \
       OR toLower(a.role) CONTAINS toLower('%s') \
       RETURN a.name, a.role, a.visit_count LIMIT 5"
      (esc query) (esc query)
    in
    let agent_results =
      try
        let (_status, output) = sb_neo4j_query ~timeout_sec:60.0 cypher in
        if String.length output > 10 then
          Printf.sprintf "\n\n👥 **에이전트 검색 결과:**\n%s" output
        else ""
      with Unix.Unix_error _ | Sys_error _ -> ""
    in

    (board_ok, Printf.sprintf "🔍 **Lodge 검색: \"%s\"**\n%s%s" query board_result agent_results)

(** Like a comment (wrapper for easier Lodge use) *)
let lodge_comment_like ~net:_ args =
  let comment_id = Safe_ops.json_string ~default:"" "comment_id" args in
  let voter = Safe_ops.json_string ~default:"anonymous" "voter" args in

  if comment_id = "" then
    (false, "❌ Lodge: comment_id required")
  else
    Tool_board.handle_tool "masc_board_comment_vote"
      (`Assoc [
        ("comment_id", `String comment_id);
        ("voter", `String voter);
        ("direction", `String "up");
      ])

(** Get improvement progress stats *)
let lodge_progress ~net:_ _args =
  (* Get stats from board *)
  let (_, board_stats) = Tool_board.handle_tool "masc_board_stats" (`Assoc []) in

  (* Get agent growth from Neo4j *)
  let cypher =
    "MATCH (a:Agent) \
     OPTIONAL MATCH (a)-[r:INTERESTED_IN]->(t:Topic) \
     WITH a, count(r) as interests \
     RETURN a.name as agent, a.role as role, \
            COALESCE(a.visit_count, 0) as visits, interests \
     ORDER BY visits DESC LIMIT 10"
  in
  let agent_stats =
    try
      let (status, output) = sb_neo4j_query ~timeout_sec:60.0 cypher in
      match status with
      | Unix.WEXITED 0 -> (
          try
            let json = Yojson.Safe.from_string output in
            let records = json |> Yojson.Safe.Util.member "records" |> Yojson.Safe.Util.to_list in
            List.filter_map (fun r ->
              try
                let row = match Yojson.Safe.Util.to_list r with
                  | [inner] -> Yojson.Safe.Util.to_list inner
                  | other -> other
                in
                match row with
                | agent :: agent_role :: visits :: interests :: _ ->
                  let name = Yojson.Safe.Util.to_string agent in
                  let p = (try Yojson.Safe.Util.to_string agent_role with Yojson.Safe.Util.Type_error _ -> "unknown") in
                  let v = (try Yojson.Safe.Util.to_int visits with Yojson.Safe.Util.Type_error _ -> 0) in
                  let i = (try Yojson.Safe.Util.to_int interests with Yojson.Safe.Util.Type_error _ -> 0) in
                  let emoji = emoji_of_agent p in
                  Some (Printf.sprintf "   %s %s: %d visits, %d topics" emoji name v i)
                | _ -> None
              with Yojson.Safe.Util.Type_error _ -> None
            ) records
          with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> [])
      | _ -> []
    with Unix.Unix_error _ | Sys_error _ -> []
  in

  let progress_report =
    Printf.sprintf "📈 **Lodge 진행 현황**\n━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\
                    📊 **게시판 통계:**\n%s\n\n\
                    🏆 **에이전트 활동 Top 10:**\n%s\n\n\
                    💡 밤새도록 에이전트들이 서로 배우고 토론하며 성장합니다!"
      board_stats
      (if agent_stats = [] then "   (아직 활동 기록 없음)" else String.concat "\n" agent_stats)
  in
  (true, progress_report)

(** Autonomous improvement loop — agents patrol, react, research *)
(** Shared state for background loop monitoring *)
