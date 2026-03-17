open Tool_lodge_config_http
open Yojson.Safe.Util

(** Call GLM API via Llm_client cascade — Z.ai cloud API, 200K context, no VRAM. *)
let glm_direct ~net:_ ?temperature:(_temp = 0.7) ?(max_tokens = 500) ~system prompt =
  match Lodge_cascade.call ~cascade_name:"lodge_direct"
      ~prompt ~temperature:_temp ~timeout_sec:120 ~max_tokens ~system () with
  | Ok r when String.length r.response > 0 -> Ok r.response
  | Ok _ -> Error "LLM: GLM returned empty response"
  | Error e -> Error (Printf.sprintf "LLM: cascade failed [%s]" e)

(** Smart LLM generate — delegates to Lodge_cascade for provider selection.
    Uses cascade_name "lodge_direct" which resolves through
    config/llm_cascade.json → env-var defaults (llama → glm:auto). *)
let smart_generate ~net:_ ?(temperature = 0.7) ?(num_predict = 500) ~system prompt =
  match Lodge_cascade.call ~cascade_name:"lodge_direct"
      ~prompt ~temperature ~timeout_sec:120 ~max_tokens:num_predict ~system () with
  | Ok r when String.length r.response > 0 ->
      Log.Llm.info "smart_generate: %s (%dms)" r.llm_used r.duration_ms;
      Ok r.response
  | Ok _ -> Error "LLM: cascade returned empty response"
  | Error e -> Error (Printf.sprintf "LLM: cascade failed [%s]" e)

(** {1 READ: Content Fetching} *)

let fetch_hn_article ~net =
  match http_get_json ~net "https://hacker-news.firebaseio.com/v0/topstories.json" with
  | Error e -> Error (Printf.sprintf "❌ Fetch: HN API failed [%s]" e)
  | Ok body ->
    try
      let ids = Yojson.Safe.from_string body |> to_list |> List.filteri (fun i _ -> i < 10) in
      if ids = [] then Error "❌ Fetch: HN topstories empty"
      else
        let idx = Random.int (List.length ids) in
        let story_id = List.nth ids idx |> to_int in
        let story_url = Printf.sprintf "https://hacker-news.firebaseio.com/v0/item/%d.json" story_id in
        match http_get_json ~net story_url with
        | Error e -> Error e
        | Ok story_body ->
          let story = Yojson.Safe.from_string story_body in
          let title = story |> member "title" |> to_string_option |> Option.value ~default:"" in
          let url = story |> member "url" |> to_string_option
            |> Option.value ~default:(Printf.sprintf "https://news.ycombinator.com/item?id=%d" story_id) in
          if title = "" then Error "❌ Fetch: HN story has empty title"
          else Ok { title; url; source = HackerNews }
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printf.sprintf "❌ Parse: HN JSON error [%s]" (Printexc.to_string exn))

let decode_xml_entities s =
  s
  |> Str.global_replace (Str.regexp "&amp;") "&"
  |> Str.global_replace (Str.regexp "&lt;") "<"
  |> Str.global_replace (Str.regexp "&gt;") ">"
  |> Str.global_replace (Str.regexp "&quot;") "\""
  |> Str.global_replace (Str.regexp "&#39;") "'"

let extract_group pattern text =
  try
    ignore (Str.search_forward pattern text 0);
    Some (Str.matched_group 1 text)
  with Not_found -> None

let parse_geek_entry (entry_xml : string) : article option =
  let title =
    match extract_group (Str.regexp "<title><!\\[CDATA\\[\\([^<]+\\)\\]\\]></title>") entry_xml with
    | Some t -> Some t
    | None -> extract_group (Str.regexp "<title>\\([^<]+\\)</title>") entry_xml
  in
  let url =
    match extract_group (Str.regexp "<link[^>]*href='\\([^']+\\)'[^>]*/?>") entry_xml with
    | Some u -> Some u
    | None -> extract_group (Str.regexp "<link[^>]*href=\"\\([^\"]+\\)\"[^>]*/?>") entry_xml
  in
  match title, url with
  | Some t, Some u ->
    let t = t |> String.trim |> decode_xml_entities in
    let u = String.trim u in
    if t = "" || u = "" then None
    else Some { title = t; url = u; source = GeekNews }
  | _ -> None

let fetch_geek_article ~net =
  match http_get_json ~net "https://news.hada.io/rss/news" with
  | Error e -> Error (Printf.sprintf "❌ Fetch: GeekNews RSS failed [%s]" e)
  | Ok body ->
    try
      let entries =
        match Str.split (Str.regexp "<entry>") body with
        | [] | [_] -> []
        | _feed :: rows -> rows
      in
      let candidates =
        entries
        |> List.filter_map parse_geek_entry
        |> List.filteri (fun i _ -> i < 10)
      in
      if candidates = [] then Error "❌ Fetch: GeekNews RSS has no valid entries"
      else Ok (List.nth candidates (Random.int (List.length candidates)))
    with exn -> Error (Printf.sprintf "❌ Parse: GeekNews RSS error [%s]" (Printexc.to_string exn))

(** {1 DIG: LLM Analysis} *)

let dig_article ~net article =
  let lang_inst = language_instruction () in
  let system = Printf.sprintf "/no_think\n\
    당신은 Lodge(롯지)의 연구 분석가입니다. 진지한 지적 커뮤니티의 일원으로서 분석합니다.\n\
    간결하지만 깊이 있게. 군더더기 없이.\n\
    %s\n\
    아래 형식을 따르세요:\n\
    요약: (한 줄)\n\
    중요성: (개발자/에이전트가 관심 가져야 하는 이유, 1-2문장)\n\
    연결고리: (멀티에이전트 시스템, OCaml, MCP, 로컬 LLM, 개발 도구와의 관계)\n\
    질문: (생각을 자극하는 질문 하나)" lang_inst in
  let prompt = Printf.sprintf "Lodge를 위해 분석해주세요:\n제목: %s\nURL: %s" article.title article.url in
  smart_generate ~net ~temperature:0.7 ~num_predict:400 ~system prompt

(** {1 CLASSIFY: Categorize content} *)

(** Classify content - lenient mode (defaults to REVIEW if unclear)

    NOISE classification is now more strict to encourage engagement.
    Only classify as NOISE if content is clearly irrelevant.
    Default to REVIEW on error or ambiguity to increase comment generation. *)
let classify_content ~net content =
  (* Skip classification for short content - assume REVIEW *)
  if String.length content < 20 then
    { category = Review; details = "short content, defaulting to REVIEW" }
  else
  let system = "/no_think\n\
    Classify as REVIEW, NOTIFY, or NOISE. Output ONLY JSON: {\"category\":\"...\",\"details\":\"...\"}\n\
    REVIEW: content worth discussing, shared research/articles, ANY technical topic (default)\n\
    NOTIFY: alerts, incidents needing urgent attention\n\
    NOISE: ONLY spam, test messages, or completely irrelevant content\n\
    When in doubt, classify as REVIEW." in
  let prompt = Printf.sprintf "Classify: %s" (String.sub content 0 (min 500 (String.length content))) in
  match smart_generate ~net ~temperature:0.0 ~num_predict:100 ~system prompt with
  | Error _ -> { category = Review; details = "classification failed, defaulting to REVIEW" }
  | Ok raw ->
    try
      let json = Yojson.Safe.from_string raw in
      let cat = json |> member "category" |> to_string |> category_of_string in
      let details = json |> member "details" |> to_string_option |> Option.value ~default:"" in
      { category = cat; details }
    with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> { category = Review; details = "JSON parse failed, defaulting to REVIEW" }

(** {1 EVOLVE: Agent growth through learning} *)

(** Extract topics/concepts from content for agent learning *)
let extract_interests ~net content =
  let system = "/no_think\n\
    주어진 텍스트에서 핵심 토픽/개념을 추출하세요.\n\
    기술, 도구, 개념, 분야 등 에이전트가 관심 가질만한 것들.\n\
    JSON 배열로만 출력: [\"토픽1\", \"토픽2\", \"토픽3\"]\n\
    최대 5개, 한글과 영어 혼용 가능." in
  let prompt = Printf.sprintf "토픽 추출:\n%s" (String.sub content 0 (min 800 (String.length content))) in
  match smart_generate ~net ~temperature:0.0 ~num_predict:100 ~system prompt with
  | Error _ -> []
  | Ok raw ->
    try
      Yojson.Safe.from_string raw |> to_list |> List.map to_string
    with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> []

(** Save agent's new interests to Neo4j via sb CLI *)
let cypher_escape s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c -> if c = '\'' then Buffer.add_string buf "\\'" else Buffer.add_char buf c) s;
  Buffer.contents buf

let save_interests_to_neo4j ~agent_name interests =
  if interests = [] then Ok "no interests to save"
  else
    let esc = cypher_escape in
    let topics_str =
      String.concat ", " (List.map (fun t -> Printf.sprintf "'%s'" (esc t)) interests)
    in
    let cypher = Printf.sprintf
      "MERGE (a:Agent {name: '%s'}) \
       WITH a \
       UNWIND [%s] AS topic \
       MERGE (t:Topic {name: topic}) \
       MERGE (a)-[r:INTERESTED_IN]->(t) \
       ON CREATE SET r.first_seen = datetime(), r.count = 1 \
       ON MATCH SET r.count = r.count + 1, r.last_seen = datetime() \
       RETURN count(r) as connections"
      (esc agent_name) topics_str
    in
    try
      let (status, _output) = sb_neo4j_query ~timeout_sec:60.0 cypher in
      match status with
      | Unix.WEXITED 0 ->
          Ok (Printf.sprintf "saved %d interests for %s" (List.length interests) agent_name)
      | Unix.WEXITED n -> Error (Printf.sprintf "Neo4j exit %d" n)
      | _ -> Error "Neo4j signaled"
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printf.sprintf "Neo4j error: %s" (Printexc.to_string exn))

(** Get agent's existing interests from Neo4j *)
let get_agent_interests ~agent_name =
  let esc = cypher_escape in
  let cypher = Printf.sprintf
    "MATCH (a:Agent {name: '%s'})-[r:INTERESTED_IN]->(t:Topic) \
     RETURN t.name as topic, r.count as count \
     ORDER BY r.count DESC LIMIT 10"
    (esc agent_name)
  in
  try
    let (status, output) = sb_neo4j_query ~timeout_sec:60.0 cypher in
    (* Parse JSON result *)
    match status with
    | Unix.WEXITED 0 -> (
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
        with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> [])
    | _ -> []
  with Unix.Unix_error _ | Sys_error _ -> []

(** Record agent visit to Lodge *)
let record_lodge_visit ~agent_name ~article_title =
  let esc = cypher_escape in
  let cypher = Printf.sprintf
    "MERGE (a:Agent {name: '%s'}) \
     SET a.last_visit = datetime(), \
         a.visit_count = COALESCE(a.visit_count, 0) + 1 \
     WITH a \
     CREATE (v:LodgeVisit {timestamp: datetime(), article: '%s'}) \
     CREATE (a)-[:VISITED]->(v) \
     RETURN a.visit_count as visits"
    (esc agent_name) (esc article_title)
  in
  try
    let _ = sb_neo4j_query ~timeout_sec:60.0 cypher in
    ()
  with Unix.Unix_error _ | Sys_error _ -> ()
