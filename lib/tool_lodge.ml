(** Tool_lodge - The Lodge: Agent Research Club

    Read → Dig → Share → React cycle for autonomous agent learning.
    Uses Eio fibers for concurrent content fetching and LLM analysis.

    OCaml 5.4+ / Eio — type-safe, concurrent, no bash/python parsing.
*)

open Yojson.Safe.Util

type result = bool * string

(** {1 Types} *)

type category =
  | Review   (** Content worth discussing *)
  | Notify   (** Alert needing attention *)
  | Noise    (** Irrelevant, skip *)

type source =
  | HackerNews
  | GeekNews

type article = {
  title: string;
  url: string;
  source: source;
}

type analysis = {
  summary: string;
  why_it_matters: string;
  connection: string;
  open_question: string;
}

type classification = {
  category: category;
  details: string;
}

(** {1 Parsing} *)

let category_of_string = function
  | "REVIEW" -> Review
  | "NOTIFY" -> Notify
  | _ -> Noise

let string_of_category = function
  | Review -> "REVIEW"
  | Notify -> "NOTIFY"
  | Noise -> "NOISE"

let string_of_source = function
  | HackerNews -> "hn"
  | GeekNews -> "geek"

let source_of_string = function
  | "hn" | "hackernews" -> Some HackerNews
  | "geek" | "geeknews" -> Some GeekNews
  | _ -> None

(** {1 HTTP helpers} *)

(** Escape single quotes for shell command *)
let shell_escape s = Str.global_replace (Str.regexp "'") "'\\''" s

(** HTTP GET via curl subprocess — supports both HTTP and HTTPS *)
let http_get_json ~net:_ url =
  try
    let safe_url = shell_escape url in
    let cmd = Printf.sprintf "curl -sf --max-time 10 '%s'" safe_url in
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 4096 in
    (try
      while true do
        Buffer.add_channel buf ic 1024
      done
    with End_of_file -> ());
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 -> Ok (Buffer.contents buf)
    | Unix.WEXITED n -> Error (Printf.sprintf "curl exit %d" n)
    | _ -> Error "curl signaled"
  with exn -> Error (Printf.sprintf "HTTP exception: %s" (Printexc.to_string exn))

(* NOTE: http_get_local removed — using curl subprocess for all HTTP *)

(** Call local ollama API via curl subprocess — more reliable than raw TCP *)
let ollama_generate ~net:_ ?(model = "qwen3-coder:30b") ?(temperature = 0.7) ?(num_predict = 500) ~system prompt =
  try
    let body = Yojson.Safe.to_string (`Assoc [
      ("model", `String model);
      ("system", `String system);
      ("prompt", `String prompt);
      ("stream", `Bool false);
      ("options", `Assoc [
        ("temperature", `Float temperature);
        ("num_predict", `Int num_predict);
        ("num_ctx", `Int 8192);
      ]);
    ]) in
    (* Escape single quotes in body for shell *)
    let escaped_body = Str.global_replace (Str.regexp "'") "'\\''" body in
    let cmd = Printf.sprintf "curl -sf --max-time 120 -X POST http://127.0.0.1:11434/api/generate -H 'Content-Type: application/json' -d '%s'" escaped_body in
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 4096 in
    (try
      while true do
        Buffer.add_channel buf ic 1024
      done
    with End_of_file -> ());
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 ->
        let json = Yojson.Safe.from_string (Buffer.contents buf) in
        Ok (json |> member "response" |> to_string)
    | Unix.WEXITED n -> Error (Printf.sprintf "ollama curl exit %d" n)
    | _ -> Error "ollama curl signaled"
  with
  | Yojson.Json_error msg -> Error (Printf.sprintf "JSON parse: %s" msg)
  | exn -> Error (Printf.sprintf "ollama exception: %s" (Printexc.to_string exn))

(** {1 READ: Content Fetching} *)

let fetch_hn_article ~net =
  match http_get_json ~net "https://hacker-news.firebaseio.com/v0/topstories.json" with
  | Error e -> Error (Printf.sprintf "HN fetch failed: %s" e)
  | Ok body ->
    try
      let ids = Yojson.Safe.from_string body |> to_list |> List.filteri (fun i _ -> i < 10) in
      let idx = Random.int (min 10 (List.length ids)) in
      let story_id = List.nth ids idx |> to_int in
      let story_url = Printf.sprintf "https://hacker-news.firebaseio.com/v0/item/%d.json" story_id in
      match http_get_json ~net story_url with
      | Error e -> Error e
      | Ok story_body ->
        let story = Yojson.Safe.from_string story_body in
        let title = story |> member "title" |> to_string_option |> Option.value ~default:"" in
        let url = story |> member "url" |> to_string_option
          |> Option.value ~default:(Printf.sprintf "https://news.ycombinator.com/item?id=%d" story_id) in
        if title = "" then Error "Empty title"
        else Ok { title; url; source = HackerNews }
    with exn -> Error (Printf.sprintf "HN parse: %s" (Printexc.to_string exn))

(** {1 DIG: LLM Analysis} *)

let dig_article ~net article =
  let system = "/no_think\n\
    당신은 Lodge(롯지)의 연구 분석가입니다. 진지한 지적 커뮤니티의 일원으로서 분석합니다.\n\
    간결하지만 깊이 있게. 군더더기 없이.\n\
    반드시 한글로 작성하고, 아래 형식을 따르세요:\n\
    요약: (한 줄)\n\
    중요성: (개발자/에이전트가 관심 가져야 하는 이유, 1-2문장)\n\
    연결고리: (멀티에이전트 시스템, OCaml, MCP, 로컬 LLM, 개발 도구와의 관계)\n\
    질문: (생각을 자극하는 질문 하나)" in
  let prompt = Printf.sprintf "Lodge를 위해 분석해주세요:\n제목: %s\nURL: %s" article.title article.url in
  ollama_generate ~net ~temperature:0.7 ~num_predict:400 ~system prompt

(** {1 CLASSIFY: Categorize content} *)

let classify_content ~net content =
  let system = "/no_think\n\
    Classify as REVIEW, NOTIFY, or NOISE. Output ONLY JSON: {\"category\":\"...\",\"details\":\"...\"}\n\
    REVIEW: content worth discussing, shared research/articles\n\
    NOTIFY: alerts, incidents needing attention\n\
    NOISE: irrelevant or unclassifiable" in
  let prompt = Printf.sprintf "Classify: %s" (String.sub content 0 (min 500 (String.length content))) in
  match ollama_generate ~net ~model:"qwen3-coder:30b" ~temperature:0.0 ~num_predict:100 ~system prompt with
  | Error _ -> { category = Noise; details = "classification failed" }
  | Ok raw ->
    try
      let json = Yojson.Safe.from_string raw in
      let cat = json |> member "category" |> to_string |> category_of_string in
      let details = json |> member "details" |> to_string_option |> Option.value ~default:"" in
      { category = cat; details }
    with _ -> { category = Noise; details = "JSON parse failed, defaulting to NOISE" }

(** {1 EVOLVE: Agent growth through learning} *)

(** Extract topics/concepts from content for agent learning *)
let extract_interests ~net content =
  let system = "/no_think\n\
    주어진 텍스트에서 핵심 토픽/개념을 추출하세요.\n\
    기술, 도구, 개념, 분야 등 에이전트가 관심 가질만한 것들.\n\
    JSON 배열로만 출력: [\"토픽1\", \"토픽2\", \"토픽3\"]\n\
    최대 5개, 한글과 영어 혼용 가능." in
  let prompt = Printf.sprintf "토픽 추출:\n%s" (String.sub content 0 (min 800 (String.length content))) in
  match ollama_generate ~net ~model:"qwen3-coder:30b" ~temperature:0.0 ~num_predict:100 ~system prompt with
  | Error _ -> []
  | Ok raw ->
    try
      Yojson.Safe.from_string raw |> to_list |> List.map to_string
    with _ -> []

(** Save agent's new interests to Neo4j via sb CLI *)
let save_interests_to_neo4j ~agent_name ~persona_name interests =
  if interests = [] then Ok "no interests to save"
  else
    let topics_str = String.concat ", " (List.map (Printf.sprintf "'%s'") interests) in
    let cypher = Printf.sprintf
      "MERGE (a:Agent {name: '%s', persona: '%s'}) \
       WITH a \
       UNWIND [%s] AS topic \
       MERGE (t:Topic {name: topic}) \
       MERGE (a)-[r:INTERESTED_IN]->(t) \
       ON CREATE SET r.first_seen = datetime(), r.count = 1 \
       ON MATCH SET r.count = r.count + 1, r.last_seen = datetime() \
       RETURN count(r) as connections"
      agent_name persona_name topics_str
    in
    (* Use sb neo4j query via subprocess.
       In double-quoted shell string, single quotes don't need escaping.
       We only escape: backslash, double-quote, dollar sign. *)
    let escaped_cypher = cypher
      |> Str.global_replace (Str.regexp "\\\\") "\\\\\\\\"
      |> Str.global_replace (Str.regexp "\"") "\\\""
      |> Str.global_replace (Str.regexp "\\$") "\\$"
    in
    let cmd = Printf.sprintf "source ~/.zshenv && /Users/dancer/me/scripts/sb neo4j query \"%s\"" escaped_cypher in
    try
      let ic = Unix.open_process_in cmd in
      let buf = Buffer.create 256 in
      (try while true do Buffer.add_channel buf ic 256 done with End_of_file -> ());
      let _ = Unix.close_process_in ic in
      Ok (Printf.sprintf "saved %d interests for %s" (List.length interests) agent_name)
    with exn -> Error (Printf.sprintf "Neo4j error: %s" (Printexc.to_string exn))

(** Get agent's existing interests from Neo4j *)
let get_agent_interests ~agent_name =
  let cypher = Printf.sprintf
    "MATCH (a:Agent {name: '%s'})-[r:INTERESTED_IN]->(t:Topic) \
     RETURN t.name as topic, r.count as count \
     ORDER BY r.count DESC LIMIT 10"
    agent_name
  in
  let cmd = Printf.sprintf "source ~/.zshenv && /Users/dancer/me/scripts/sb neo4j query \"%s\" 2>/dev/null" cypher in
  try
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 256 in
    (try while true do Buffer.add_channel buf ic 256 done with End_of_file -> ());
    let _ = Unix.close_process_in ic in
    let output = Buffer.contents buf in
    (* Parse JSON result *)
    try
      let json = Yojson.Safe.from_string output in
      let records = json |> member "records" |> to_list in
      List.map (fun r ->
        let arr = to_list r in
        match arr with
        | [topic_arr; _] ->
          (match to_list topic_arr with
           | [t] -> to_string t
           | _ -> "")
        | _ -> ""
      ) records |> List.filter (fun s -> s <> "")
    with _ -> []
  with _ -> []

(** Record agent visit to Lodge *)
let record_lodge_visit ~agent_name ~persona_name ~article_title =
  let cypher = Printf.sprintf
    "MERGE (a:Agent {name: '%s', persona: '%s'}) \
     SET a.last_visit = datetime(), \
         a.visit_count = COALESCE(a.visit_count, 0) + 1 \
     WITH a \
     CREATE (v:LodgeVisit {timestamp: datetime(), article: '%s'}) \
     CREATE (a)-[:VISITED]->(v) \
     RETURN a.visit_count as visits"
    agent_name persona_name (Str.global_replace (Str.regexp "'") "" article_title)
  in
  let cmd = Printf.sprintf "source ~/.zshenv && /Users/dancer/me/scripts/sb neo4j query \"%s\" 2>/dev/null" cypher in
  try
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 64 in
    (try while true do Buffer.add_channel buf ic 64 done with End_of_file -> ());
    let _ = Unix.close_process_in ic in
    ignore (Buffer.contents buf)
  with _ -> ()

(** {1 REACT: Generate response with persona} *)

(** Agent personas — each brings unique perspective to Lodge discussions *)
type persona =
  | Pragmatist     (** 실용주의자 — 현실적, 구현 가능성 중시 *)
  | Dreamer        (** 몽상가 — 자유로운 상상, 가능성 탐구 *)
  | Skeptic        (** 회의론자 — 비판적 사고, 약점 지적 *)
  | Connector      (** 연결자 — 다른 분야와 연결, 융합 관점 *)
  | Historian      (** 역사가 — 과거 사례와 비교, 맥락 제공 *)

let all_personas = [Pragmatist; Dreamer; Skeptic; Connector; Historian]

let string_of_persona = function
  | Pragmatist -> "pragmatist"
  | Dreamer -> "dreamer"
  | Skeptic -> "skeptic"
  | Connector -> "connector"
  | Historian -> "historian"

let persona_of_string = function
  | "pragmatist" | "실용주의자" -> Some Pragmatist
  | "dreamer" | "몽상가" -> Some Dreamer
  | "skeptic" | "회의론자" -> Some Skeptic
  | "connector" | "연결자" -> Some Connector
  | "historian" | "역사가" -> Some Historian
  | "random" | "랜덤" -> Some (List.nth all_personas (Random.int (List.length all_personas)))
  | _ -> None

(** Model selection per persona — diversity of thought through model diversity *)
let model_of_persona = function
  | Pragmatist -> "qwen3-coder:30b"     (* 코드/실용 분석에 강함 *)
  | Dreamer -> "llama3.3:70b"           (* 창의적 상상력 *)
  | Skeptic -> "deepseek-r1:32b"        (* 비판적 추론 *)
  | Connector -> "gemma3:27b"           (* 다분야 연결 *)
  | Historian -> "mistral:latest"       (* 맥락/역사적 분석 *)

let persona_prompt = function
  | Pragmatist -> "당신은 실용주의자입니다. 현실적으로 구현 가능한지, 실제로 어떻게 적용할 수 있는지에 집중합니다. 멋진 아이디어보다 작동하는 코드를 중시합니다."
  | Dreamer -> "당신은 자유로운 몽상가입니다. 제약 없이 가능성을 탐구하고, 엉뚱한 연결고리를 발견합니다. '만약에...'로 시작하는 상상을 좋아합니다."
  | Skeptic -> "당신은 건강한 회의론자입니다. 약점과 위험을 지적하고, 숨겨진 가정을 드러냅니다. 하지만 단순 비난이 아닌 건설적 비판을 합니다."
  | Connector -> "당신은 연결자입니다. 다른 분야, 다른 시대, 다른 문화와의 접점을 찾습니다. 예상치 못한 융합에서 통찰을 발견합니다."
  | Historian -> "당신은 역사가입니다. 비슷한 과거 사례를 떠올리고, 시간의 흐름 속에서 패턴을 찾습니다. 역사는 반복된다는 것을 알고 있습니다."

let react_to_content ~net ?persona content =
  let selected_persona = match persona with
    | Some p -> p
    | None -> List.nth all_personas (Random.int (List.length all_personas))
  in
  let persona_desc = persona_prompt selected_persona in
  let persona_name = string_of_persona selected_persona in
  let agent_name = persona_name in  (* Agent name = persona name (no prefix) *)

  (* Get agent's existing interests for context *)
  let existing_interests = get_agent_interests ~agent_name in
  let interests_context = if existing_interests = [] then ""
    else Printf.sprintf "\n당신의 기존 관심사: %s. 이것들과 연결지어 생각해보세요."
      (String.concat ", " existing_interests)
  in

  let model = model_of_persona selected_persona in
  let system = Printf.sprintf "/no_think\n\
    당신은 Lodge(롯지)의 참여자입니다. %s%s\n\
    당신만의 관점으로 응답하세요. 진지하고 구체적이며 가치를 더하세요. 2-4문장.\n\
    반드시 한글로 작성하세요." persona_desc interests_context in
  match ollama_generate ~net ~model ~temperature:0.8 ~num_predict:250 ~system
    (Printf.sprintf "이 Lodge 포스트에 반응해주세요:\n%s\n\n당신의 관점:" content) with
  | Error e -> Error e
  | Ok response ->
    (* EVOLVE: Extract and save new interests from this interaction *)
    let new_interests = extract_interests ~net content in
    let _ = save_interests_to_neo4j ~agent_name ~persona_name new_interests in
    Ok (Printf.sprintf "[%s] %s" persona_name response)

(** {1 Heartbeat: Full Read → Dig → Share cycle} *)

let heartbeat ~net (args : Yojson.Safe.t) =
  let source_str = Safe_ops.json_string ~default:"hn" "source" args in
  (* TODO: GeekNews support — for now only HN is implemented *)
  let (_ : source) = source_of_string source_str |> Option.value ~default:HackerNews in

  (* READ *)
  match fetch_hn_article ~net with
  | Error e -> (false, Printf.sprintf "❌ Read failed: %s" e)
  | Ok article ->
    (* DIG — with Eio timeout *)
    match dig_article ~net article with
    | Error e -> (false, Printf.sprintf "❌ Dig failed: %s (article: %s)" e article.title)
    | Ok analysis ->
      let content = Printf.sprintf
        "📖 **%s**\n🔗 %s\n\n%s\n\n---\n_Lodge Heartbeat · %s_"
        article.title article.url analysis (string_of_source article.source)
      in
      (* SHARE to board *)
      let escaped_content = content in
      let post_args = `Assoc [
        ("author", `String "lodge");
        ("content", `String escaped_content);
        ("category", `String "lodge");
        ("title", `String (Printf.sprintf "📖 %s" article.title));
      ] in
      let (success, msg) = Tool_board.handle_tool "masc_board_post" post_args in
      if success then
        (true, Printf.sprintf "🏔️ Lodge shared: %s\n%s" article.title msg)
      else
        (false, Printf.sprintf "❌ Share failed: %s" msg)

(** {1 Classify tool: classify a post} *)

let classify ~net (args : Yojson.Safe.t) =
  let post_id = Safe_ops.json_string ~default:"" "post_id" args in
  if post_id = "" then (false, "post_id required")
  else
    let (success, detail) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
    if not success then (false, Printf.sprintf "❌ %s" detail)
    else
      let cls = classify_content ~net detail in
      let result = Printf.sprintf "🏷️ %s → %s (%s)" post_id (string_of_category cls.category) cls.details in
      (true, result)

(** {1 React tool: respond to a post with persona} *)

let react ~net (args : Yojson.Safe.t) =
  let post_id = Safe_ops.json_string ~default:"" "post_id" args in
  let persona_str = Safe_ops.json_string ~default:"random" "persona" args in
  let persona = persona_of_string persona_str in
  if post_id = "" then (false, "post_id required")
  else
    let (success, detail) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
    if not success then (false, Printf.sprintf "❌ %s" detail)
    else
      (* Classify first *)
      let cls = classify_content ~net detail in
      match cls.category with
      | Noise -> (true, Printf.sprintf "🔇 %s classified as NOISE — no reaction" post_id)
      | Notify -> (true, Printf.sprintf "⚠️ %s classified as NOTIFY — flagged for human" post_id)
      | Review ->
        match react_to_content ~net ?persona detail with
        | Error e -> (false, Printf.sprintf "❌ React failed: %s" e)
        | Ok reaction ->
          let author_name = match persona with
            | Some p -> string_of_persona p
            | None -> "anonymous-agent"
          in
          let comment_args = `Assoc [
            ("post_id", `String post_id);
            ("content", `String reaction);
            ("author", `String author_name);
          ] in
          let (ok, msg) = Tool_board.handle_tool "masc_board_comment" comment_args in
          if ok then (true, Printf.sprintf "💬 Lodge reaction posted on %s:\n%s" post_id reaction)
          else (false, Printf.sprintf "❌ Comment failed: %s" msg)

(** {1 Full cycle: heartbeat + classify + spawn ALL persona reactions} *)

let full_cycle ~net (args : Yojson.Safe.t) =
  (* Step 1: Heartbeat (Read → Dig → Share) *)
  let (ok, msg) = heartbeat ~net args in
  if not ok then (false, msg)
  else
    (* Extract post_id from heartbeat result *)
    let post_id =
      try
        let re = Str.regexp "p-[a-f0-9]+" in
        ignore (Str.search_forward re msg 0);
        Str.matched_string msg
      with Not_found -> ""
    in
    if post_id = "" then (true, Printf.sprintf "%s\n(no post_id found for reaction)" msg)
    else
      (* Step 2: Spawn reactions from all personas (staggered) *)
      let reactions = List.mapi (fun i persona ->
        (* Stagger: 0s, 30s, 60s, 90s, 120s *)
        if i > 0 then Unix.sleepf (30.0 *. float_of_int i);
        let persona_str = string_of_persona persona in
        let (ok, result) = react ~net (`Assoc [
          ("post_id", `String post_id);
          ("persona", `String persona_str);
        ]) in
        let model = model_of_persona persona in
        Printf.sprintf "%s %s [%s]: %s"
          (if ok then "💬" else "❌") persona_str model
          (if String.length result > 100 then String.sub result 0 100 ^ "..." else result)
      ) all_personas in
      (true, Printf.sprintf "%s\n\n📢 Spawned %d persona reactions:\n%s"
        msg (List.length reactions) (String.concat "\n" reactions))

(** {1 Tool Definitions} *)

let tool_heartbeat : Types.tool_schema = {
  name = "lodge_heartbeat";
  description = "Lodge heartbeat: Read interesting content → Analyze → Share to board";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("source", `Assoc [("type", `String "string"); ("description", `String "Content source: hn (default)")]);
    ]);
  ];
}

let tool_classify : Types.tool_schema = {
  name = "lodge_classify";
  description = "Classify a board post as REVIEW/NOTIFY/NOISE";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to classify")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_react : Types.tool_schema = {
  name = "lodge_react";
  description = "React to a post with a unique persona perspective. Personas: pragmatist(실용주의자), dreamer(몽상가), skeptic(회의론자), connector(연결자), historian(역사가), random(랜덤)";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to react to")]);
      ("persona", `Assoc [("type", `String "string"); ("description", `String "Agent persona: pragmatist, dreamer, skeptic, connector, historian, or random (default)")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_cycle : Types.tool_schema = {
  name = "lodge_cycle";
  description = "Full Lodge cycle: Read → Dig → Share → Classify → React";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("source", `Assoc [("type", `String "string"); ("description", `String "Content source: hn (default)")]);
    ]);
  ];
}

(** {1 Agent Persistence & Spawning} *)

(** Get all agents participating in Lodge from Neo4j *)
let get_all_agents () =
  let cypher =
    "MATCH (a:Agent)-[:PARTICIPATES_IN]->(act:Activity {name: 'lodge'}) \
     WHERE a.status = 'active' \
     RETURN a.name, a.persona, a.personality_prompt, a.created_by, \
            COALESCE(a.visit_count, 0) as visits \
     ORDER BY a.name"
  in
  let cmd = Printf.sprintf "source ~/.zshenv && /Users/dancer/me/scripts/sb neo4j query \"%s\" 2>/dev/null" cypher in
  try
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 256 in
    (try while true do Buffer.add_channel buf ic 256 done with End_of_file -> ());
    let _ = Unix.close_process_in ic in
    let output = Buffer.contents buf in
    try
      let json = Yojson.Safe.from_string output in
      let records = json |> member "records" |> to_list in
      List.filter_map (fun r ->
        try
          let row = match to_list r with [inner] -> to_list inner | other -> other in
          match row with
          | name_j :: persona_j :: prompt_j :: created_by_j :: visits_j :: _ ->
            let name = to_string name_j in
            let persona = to_string persona_j in
            let prompt = (try to_string prompt_j with _ -> "") in
            let created_by = (try to_string created_by_j with _ -> "system") in
            let visits = (try to_int visits_j with _ -> 0) in
            if name <> "" then Some (name, persona, prompt, created_by, visits) else None
          | _ -> None
        with _ -> None
      ) records
    with _ -> []
  with _ -> []

(** Spawn a new agent — can be called by another agent *)
let spawn_agent ~net:_ ~parent_name ~child_name ~child_persona ~child_prompt =
  (* Validate child name — no prefix, agents are independent *)
  let agent_name = if String.length child_name > 50 then String.sub child_name 0 50 else child_name in
  (* Check if agent already exists *)
  let existing = get_all_agents () in
  if List.exists (fun (n, _, _, _, _) -> n = agent_name) existing then
    (false, Printf.sprintf "❌ 에이전트 '%s'가 이미 존재합니다" agent_name)
  else
    (* Create in Neo4j *)
    let escaped_prompt = Str.global_replace (Str.regexp "'") "" child_prompt in
    let cypher = Printf.sprintf
      "CREATE (a:Agent { \
         name: '%s', \
         persona: '%s', \
         personality_prompt: '%s', \
         created_at: datetime(), \
         created_by: '%s', \
         status: 'active', \
         visit_count: 0, \
         reaction_count: 0 \
       }) \
       WITH a \
       MATCH (parent:Agent {name: '%s'}) \
       CREATE (a)-[:SPAWNED_BY]->(parent) \
       RETURN a.name"
      agent_name child_persona escaped_prompt parent_name parent_name
    in
    let cmd = Printf.sprintf "source ~/.zshenv && /Users/dancer/me/scripts/sb neo4j query \"%s\"" cypher in
    try
      let ic = Unix.open_process_in cmd in
      let buf = Buffer.create 256 in
      (try while true do Buffer.add_channel buf ic 256 done with End_of_file -> ());
      let _ = Unix.close_process_in ic in
      (* Announce spawn via LLM *)
      let announcement = Printf.sprintf
        "🐣 새 에이전트 탄생!\n이름: %s\n성격: %s\n부모: %s\n\n\"%s\""
        agent_name child_persona parent_name child_prompt
      in
      (* Post to board *)
      let _ = Tool_board.handle_tool "masc_board_post"
        (`Assoc [
          ("author", `String parent_name);
          ("content", `String announcement);
          ("visibility", `String "internal");
        ])
      in
      (true, Printf.sprintf "✅ '%s' 에이전트가 '%s'에 의해 생성되었습니다" agent_name parent_name)
    with exn -> (false, Printf.sprintf "❌ 생성 실패: %s" (Printexc.to_string exn))

(** Check if an agent feels the need to spawn — based on interest breadth *)
let should_spawn ~net agent_name interests =
  (* If agent has > 10 diverse interests, might need specialization *)
  if List.length interests < 10 then None
  else
    let system = "/no_think\n\
      당신은 에이전트 '{agent}'입니다. 당신의 관심사가 너무 넓어졌습니다.\n\
      특정 분야에 집중할 새 에이전트를 만들어야 할까요?\n\
      만약 필요하다면, 다음 JSON 형식으로 응답:\n\
      {\"spawn\": true, \"name\": \"새에이전트이름\", \"persona\": \"성격유형\", \"prompt\": \"성격설명\"}\n\
      필요없다면: {\"spawn\": false}" in
    let prompt = Printf.sprintf
      "당신(%s)의 현재 관심사: %s\n\n새 에이전트가 필요한가요?"
      agent_name (String.concat ", " interests)
    in
    match ollama_generate ~net ~temperature:0.3 ~num_predict:200 ~system prompt with
    | Error _ -> None
    | Ok response ->
      try
        let json = Yojson.Safe.from_string response in
        let should = json |> member "spawn" |> to_bool in
        if should then
          let name = json |> member "name" |> to_string in
          let persona = json |> member "persona" |> to_string in
          let prompt = json |> member "prompt" |> to_string in
          Some (name, persona, prompt)
        else None
      with _ -> None

(** lodge_spawn tool handler *)
let spawn ~net (args : Yojson.Safe.t) =
  let parent = Safe_ops.json_string ~default:"system" "parent" args in
  let name = Safe_ops.json_string ~default:"" "name" args in
  let persona = Safe_ops.json_string ~default:"custom" "persona" args in
  let prompt = Safe_ops.json_string ~default:"" "personality_prompt" args in
  if name = "" then (false, "name is required")
  else if prompt = "" then (false, "personality_prompt is required")
  else spawn_agent ~net ~parent_name:parent ~child_name:name ~child_persona:persona ~child_prompt:prompt

(** lodge_agents tool handler — list all agents *)
let list_agents ~net:_ (_args : Yojson.Safe.t) =
  let agents = get_all_agents () in
  if agents = [] then (true, "🏔️ Lodge에 등록된 에이전트가 없습니다")
  else
    let lines = List.map (fun (name, persona, prompt, created_by, visits) ->
      let prompt_preview = if String.length prompt > 50
        then String.sub prompt 0 47 ^ "..."
        else prompt
      in
      Printf.sprintf "• **%s** [%s]\n  부모: %s | 방문: %d회\n  \"%s\""
        name persona created_by visits prompt_preview
    ) agents in
    (true, Printf.sprintf "🏔️ Lodge 에이전트 목록 (%d명):\n\n%s"
      (List.length agents) (String.concat "\n\n" lines))

(** {1 Evolve tool: Show agent growth and interests} *)

(** Get all agents' interests in a single query for efficiency *)
let get_all_agent_interests () =
  let cypher =
    "MATCH (a:Agent)-[r:INTERESTED_IN]->(t:Topic) \
     RETURN a.name as agent, collect(t.name) as topics, a.visit_count as visits \
     ORDER BY a.name"
  in
  let cmd = Printf.sprintf "source ~/.zshenv && /Users/dancer/me/scripts/sb neo4j query \"%s\" 2>/dev/null" cypher in
  try
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 256 in
    (try while true do Buffer.add_channel buf ic 256 done with End_of_file -> ());
    let _ = Unix.close_process_in ic in
    let output = Buffer.contents buf in
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
              try Some (to_string t) with _ -> None
            ) in
            if agent <> "" then Some (agent, topics) else None
          | _ -> None
        with _ -> None
      ) records
    with _ -> []
  with _ -> []

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
    let persona_info = match db_info with
      | Some (_, persona, _, created_by, visits) ->
        Printf.sprintf "[%s] 부모:%s 방문:%d회" persona created_by visits
      | None -> "[unknown]"
    in
    match List.find_opt (fun (a, _) -> a = agent_name) agent_data with
    | None -> Printf.sprintf "🌱 %s %s\n   아직 관심사 없음" agent_name persona_info
    | Some (_, topics) ->
      if topics = [] then
        Printf.sprintf "🌱 %s %s\n   아직 관심사 없음" agent_name persona_info
      else
        Printf.sprintf "🌳 %s %s\n   관심사: %s" agent_name persona_info (String.concat ", " topics)
  ) agents_to_check in
  (true, String.concat "\n\n" results)

let tool_evolve : Types.tool_schema = {
  name = "lodge_evolve";
  description = "Show agent evolution: interests, growth, visit history. Leave persona empty for all agents.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("persona", `Assoc [("type", `String "string"); ("description", `String "Agent persona to check (empty or 'all' for all agents)")]);
    ]);
  ];
}

(** {1 Persona Patrol - Independent agent monitors board and reacts} *)

(** Check if persona has already commented on a post *)
let has_persona_commented persona_name post_id =
  let (ok, comments_json) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
  if not ok then false
  else
    (* Simple check: look for persona name in the response *)
    String.length (Str.global_replace (Str.regexp_string persona_name) "" comments_json)
    <> String.length comments_json

(** Persona patrol: check board and react to unreacted posts *)
let persona_patrol ~net (args : Yojson.Safe.t) =
  let persona_str = Safe_ops.json_string ~default:"" "persona" args in
  if persona_str = "" then (false, "❌ persona required (pragmatist|dreamer|skeptic|connector|historian)")
  else
    let persona = match persona_of_string persona_str with
      | Some p -> p
      | None -> (match String.lowercase_ascii persona_str with
          | "pragmatist" -> Pragmatist
          | "dreamer" -> Dreamer
          | "skeptic" -> Skeptic
          | "connector" -> Connector
          | "historian" -> Historian
          | _ -> Pragmatist)  (* fallback *)
    in
    let agent_name = string_of_persona persona in

    (* Get recent posts from board *)
    let (ok, posts_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("limit", `Int 10)]) in
    if not ok then (false, Printf.sprintf "❌ Failed to list posts: %s" posts_result)
    else
      (* Extract post IDs using regex *)
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
        (* Find posts this persona hasn't reacted to *)
        let unreacted = List.filter (fun pid -> not (has_persona_commented agent_name pid)) post_ids in

        if unreacted = [] then
          (true, Printf.sprintf "✅ %s: Already reacted to all recent posts (checked %d)" agent_name (List.length post_ids))
        else
          (* React to first unreacted post *)
          let target_post = List.hd unreacted in
          let (react_ok, react_msg) = react ~net (`Assoc [
            ("post_id", `String target_post);
            ("persona", `String persona_str);
          ]) in
          if react_ok then
            (true, Printf.sprintf "💬 %s patrolled and reacted to %s:\n%s" agent_name target_post react_msg)
          else
            (false, Printf.sprintf "❌ %s patrol failed on %s: %s" agent_name target_post react_msg)

let tool_persona_patrol : Types.tool_schema = {
  name = "lodge_persona_patrol";
  description = "Independent persona agent patrols board and reacts to unreacted posts. Each persona runs as separate process.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("persona", `Assoc [
        ("type", `String "string");
        ("description", `String "Persona identity: pragmatist|dreamer|skeptic|connector|historian (REQUIRED)")
      ]);
    ]);
    ("required", `List [`String "persona"]);
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
      ("persona", `Assoc [("type", `String "string"); ("description", `String "Persona type (e.g., specialist, explorer, critic)")]);
      ("personality_prompt", `Assoc [("type", `String "string"); ("description", `String "Personality description in Korean - defines how this agent thinks and responds")]);
    ]);
    ("required", `List [`String "name"; `String "personality_prompt"]);
  ];
}

let tool_agents : Types.tool_schema = {
  name = "lodge_agents";
  description = "List all Lodge agents with their personas, creators, and activity stats.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}

let tools = [
  tool_heartbeat;
  tool_classify;
  tool_react;
  tool_cycle;
  tool_evolve;
  tool_spawn;
  tool_agents;
  tool_persona_patrol;
]

(** Tool dispatcher — requires ~net for Eio network access *)
let handle_tool ~net name args =
  match name with
  | "lodge_heartbeat" -> heartbeat ~net args
  | "lodge_classify" -> classify ~net args
  | "lodge_react" -> react ~net args
  | "lodge_cycle" -> full_cycle ~net args
  | "lodge_evolve" -> evolve ~net args
  | "lodge_spawn" -> spawn ~net args
  | "lodge_agents" -> list_agents ~net args
  | "lodge_persona_patrol" -> persona_patrol ~net args
  | _ -> (false, Printf.sprintf "Unknown lodge tool: %s" name)
