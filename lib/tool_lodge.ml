(** Tool_lodge - The Lodge: Agent Research Club

    Read → Dig → Share → React cycle for autonomous agent learning.
    Uses Eio fibers for concurrent content fetching and LLM analysis.

    OCaml 5.4+ / Eio — type-safe, concurrent, no bash/python parsing.
*)

open Yojson.Safe.Util

type result = bool * string

(** {1 Lodge Configuration} *)

(** Read Lodge config from .masc/config.json *)
let read_lodge_config () =
  let me_root = match Sys.getenv_opt "ME_ROOT" with
    | Some r -> r
    | None -> match Sys.getenv_opt "HOME" with
      | Some h -> h ^ "/me"
      | None -> "."
  in
  let config_path = me_root ^ "/.masc/config.json" in
  try
    let ic = open_in config_path in
    let content = Fun.protect ~finally:(fun () -> close_in_noerr ic)
      (fun () -> really_input_string ic (in_channel_length ic)) in
    let json = Yojson.Safe.from_string content in
    let lodge = Yojson.Safe.Util.(member "lodge" json) in
    let lang = Yojson.Safe.Util.(member "language" lodge |> to_string_option) in
    let inst = Yojson.Safe.Util.(member "instruction" lodge |> to_string_option) in
    (lang, inst)
  with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ | Sys_error _ -> (None, None)

let (config_language, config_instruction) = read_lodge_config ()

(** Lodge 공용어 — config.json > 환경변수 > 기본값(ko) *)
let lodge_language =
  match config_language with
  | Some lang -> lang
  | None ->
    match Sys.getenv_opt "MASC_LODGE_LANGUAGE" with
    | Some "en" -> "en"
    | Some "auto" -> "auto"
    | _ -> "ko"

(** Lodge 인스트럭션 — config.json에서 읽음 *)
let language_instruction () =
  match config_instruction with
  | Some inst -> inst
  | None ->
    match lodge_language with
    | "ko" -> "반드시 한글로 작성하세요."
    | "en" -> "Write in English."
    | _ -> ""

(** Get sb script path from ME_ROOT env var (portable) *)
let sb_path () =
  match Sys.getenv_opt "ME_ROOT" with
  | Some root -> Printf.sprintf "%s/scripts/sb" root
  | None -> (
    match Sys.getenv_opt "HOME" with
    | Some home -> Printf.sprintf "%s/me/scripts/sb" home
    | None -> "/Users/dancer/me/scripts/sb"  (* legacy fallback *)
  )

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

let run_cmd_with_status ?(timeout_sec = 60.0) (argv : string list) : Unix.process_status * string =
  Process_eio.run_argv_with_status ~timeout_sec argv

let run_cmd ?(timeout_sec = 10.0) (argv : string list) : string =
  Process_eio.run_argv ~timeout_sec argv

let sb_argv args = (sb_path ()) :: args

let sb_neo4j_query ?(timeout_sec = 60.0) (cypher : string) : Unix.process_status * string =
  run_cmd_with_status ~timeout_sec (sb_argv ["neo4j"; "query"; cypher])

(** HTTP GET via curl subprocess — supports both HTTP and HTTPS *)
let http_get_json ~net:_ url =
  try
    let (status, content) =
      run_cmd_with_status ~timeout_sec:15.0 ["curl"; "-sf"; "--max-time"; "10"; url]
    in
    match status with
    | Unix.WEXITED 0 -> Ok content
    | Unix.WEXITED n -> Error (Printf.sprintf "❌ HTTP: curl exit %d [url=%s]" n (String.sub url 0 (min 60 (String.length url))))
    | _ -> Error "❌ HTTP: curl signaled"
  with exn -> Error (Printf.sprintf "❌ HTTP: %s" (Printexc.to_string exn))

(* NOTE: http_get_local removed — using curl subprocess for all HTTP *)

(** curl-based GraphQL request — reliable DNS resolution in Railway containers *)
let graphql_request_curl body : (string, string) Stdlib.result =
  let default_url = "https://second-brain-graphql-production.up.railway.app/graphql" in
  let url = Sys.getenv_opt "GRAPHQL_URL" |> Option.value ~default:default_url in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  try
    let argv =
      [ "curl"; "-s"; "-m"; "10"; "-f"; url;
        "-H"; "Content-Type: application/json"
      ]
      |> fun base ->
      if api_key = "" then base else base @ [ "-H"; "Authorization: Bearer " ^ api_key ]
      |> fun with_auth ->
      (* Read request body from stdin to avoid quoting/escaping issues. *)
      with_auth @ [ "-d"; "@-" ]
    in
    let output = Process_eio.run_argv_with_stdin ~timeout_sec:15.0 ~stdin_content:body argv in
    if String.length output = 0 then Error "❌ GraphQL curl: empty response" else Ok output
  with exn -> Error (Printf.sprintf "❌ GraphQL curl: %s" (Printexc.to_string exn))

(** GraphQL request via Cohttp_eio with curl fallback.
    Falls back to curl if Cohttp fails (Railway DNS issues).
    URL configurable via GRAPHQL_URL env var for Railway internal networking. *)
let graphql_request ?(timeout_sec=5.0) body : (string, string) Stdlib.result =
  let default_url = "https://second-brain-graphql-production.up.railway.app/graphql" in
  let url = Sys.getenv_opt "GRAPHQL_URL" |> Option.value ~default:default_url in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  let max_response_bytes = 1_000_000 in
  let cohttp_result = match Eio_context.get_net_opt () with
  | None -> Error "❌ GraphQL: Eio net not initialized"
  | Some net ->
      let headers =
        if api_key = "" then
          Cohttp.Header.of_list [("Content-Type", "application/json")]
        else
          Cohttp.Header.of_list [
            ("Content-Type", "application/json");
            ("Authorization", "Bearer " ^ api_key);
          ]
      in
      let uri = Uri.of_string url in
      let is_https = Uri.scheme uri = Some "https" in
      let run () =
        Eio.Switch.run (fun sw ->
          let client =
            if is_https then
              Cohttp_eio.Client.make ~https:(Some (Eio_context.get_https_connector ())) net
            else
              Cohttp_eio.Client.make ~https:None net  (* HTTP: no TLS connector *)
          in
          let body_content = Eio.Flow.string_source body in
          let resp, resp_body =
            Cohttp_eio.Client.post client ~sw uri ~headers ~body:body_content
          in
          let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
          let body_str =
            Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_response_bytes
          in
          if String.length body_str = 0 then
            Error "❌ GraphQL: empty response"
          else if Cohttp.Code.is_success status then
            Ok body_str
          else
            Error (Printf.sprintf "❌ GraphQL: HTTP %d" status)
        )
      in
      match Eio_context.get_clock_opt () with
      | Some clock ->
          (try Eio.Time.with_timeout_exn clock timeout_sec run
           with exn -> Error (Printexc.to_string exn))
      | None ->
          (try run () with exn -> Error (Printexc.to_string exn))
  in
  (* Fallback to curl on Cohttp failure (Railway DNS issues) *)
  match cohttp_result with
  | Ok _ as success -> success
  | Error cohttp_err ->
      Printf.eprintf "[GraphQL] Cohttp failed (%s), trying curl fallback...\n%!" cohttp_err;
      graphql_request_curl body

(** {1 LLM Provider Rotation — Avoid ollama overload} *)

type llm_provider =
  | Ollama_fast   (** glm-4.7-flash — always resident in VRAM *)
  | Ollama_heavy  (** glm-4.7-flash — same model, no cold-load *)
  | Gemini_cli    (** gemini CLI tool *)
  | Claude_cli    (** claude CLI tool *)
  | Codex_cli     (** codex CLI tool *)

let string_of_provider = function
  | Ollama_fast -> "ollama-fast"
  | Ollama_heavy -> "ollama-heavy"
  | Gemini_cli -> "gemini"
  | Claude_cli -> "claude"
  | Codex_cli -> "codex"

(** Rotation state — Codex excluded (API auth issues) *)
let cli_providers = [| Gemini_cli; Claude_cli |]
let provider_index = ref 0

let next_cli_provider () =
  let p = cli_providers.(!provider_index) in
  provider_index := (!provider_index + 1) mod Array.length cli_providers;
  p

(** Check if ollama has a small model loaded (not blocking with 30b) *)
let ollama_is_light () =
  try
    let (_status, content) =
      run_cmd_with_status ~timeout_sec:10.0 ["curl"; "-sf"; "http://localhost:11434/api/ps"]
    in
    let json = Yojson.Safe.from_string content in
    let models = json |> member "models" |> to_list in
    (* If no models loaded or only small models, ollama is light *)
    models = [] || List.for_all (fun m ->
      let name = m |> member "name" |> to_string_option |> Option.value ~default:"" in
      (* Consider models with "1.7b", "3b", "1.5b" as light *)
      Str.string_match (Str.regexp ".*\\(1\\.[0-9]b\\|3b\\|mini\\|small\\).*") name 0
    ) models
  with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> false  (* On error, assume busy *)

(** Call CLI tool with prompt - uses stdin to avoid shell escaping issues *)
let cli_generate provider ~system prompt =
  let full_prompt = Printf.sprintf "%s\n\n%s" system prompt in
  let cli_cmd = match provider with
    | Gemini_cli -> "gemini"
    | Claude_cli -> "claude"
    | Codex_cli -> "codex"
    | _ -> failwith "Not a CLI provider"
  in
  try
    let argv = match provider with
      | Gemini_cli -> ["gemini"]
      | Claude_cli -> ["claude"; "-p"; "-"]
      | Codex_cli -> ["codex"; "exec"; "-"]
      | _ -> failwith "Not a CLI provider"
    in
    let (status, content) =
      Process_eio.run_argv_with_stdin_and_status
        ~timeout_sec:120.0
        ~stdin_content:full_prompt
        argv
    in
    match status with
    | Unix.WEXITED 0 -> Ok content
    | Unix.WEXITED n -> Error (Printf.sprintf "❌ LLM: %s exit %d" cli_cmd n)
    | _ -> Error (Printf.sprintf "❌ LLM: %s signaled" cli_cmd)
  with exn ->
    Error (Printf.sprintf "❌ LLM: %s exception [%s]" cli_cmd (Printexc.to_string exn))

(** Unified LLM generate with automatic provider selection *)
let llm_generate ~net:_ ?(prefer_fast = true) ~system prompt =
  (* Strategy: prefer CLI tools to avoid ollama overload *)
  if prefer_fast then begin
    (* Try CLI first (rotation) *)
    let cli = next_cli_provider () in
    match cli_generate cli ~system prompt with
    | Ok response ->
        Printf.eprintf "[LLM] Used %s\n%!" (string_of_provider cli);
        Ok response
    | Error e1 ->
        (* Fallback to ollama small model *)
        Printf.eprintf "[LLM] %s failed (%s), trying ollama-fast\n%!" (string_of_provider cli) e1;
        (* Will use ollama_generate below *)
        Error e1
  end else
    Error "❌ LLM: prefer_fast=false not implemented"

(** Call GLM API directly — Z.ai cloud API, 200K context, no VRAM.
    Uses Llm_direct.call_glm for direct API calls (no proxy). *)
let glm_direct ~net:_ ?temperature:(_temp = 0.7) ?(max_tokens = 500) ~system prompt =
  ignore _temp;
  try
    let full_prompt = Printf.sprintf "%s\n\n%s" system prompt in
    let result = Llm_direct.call_glm ~model:"glm-4.7" ~prompt:full_prompt ~timeout_sec:120 ~max_chars:max_tokens () in
    if String.length result > 0 then Ok result
    else Error "❌ LLM: GLM returned empty response"
  with exn -> Error (Printf.sprintf "❌ LLM: GLM exception [%s]" (Printexc.to_string exn))

(** Call local ollama API — DEPRECATED, use glm_direct instead *)
let ollama_generate ~net:_ ?(model = Env_config.Ollama.default_model) ?(temperature = 0.7) ?(num_predict = 500) ~system prompt =
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
    let argv =
      ["curl"; "-sf"; "--max-time"; "120";
       "-X"; "POST"; "http://127.0.0.1:11434/api/generate";
       "-H"; "Content-Type: application/json";
       "-d"; "@-"]
    in
    let (status, content) =
      Process_eio.run_argv_with_stdin_and_status
        ~timeout_sec:125.0
        ~stdin_content:body
        argv
    in
    match status with
    | Unix.WEXITED 0 ->
        let json = Yojson.Safe.from_string content in
        Ok (json |> member "response" |> to_string)
    | Unix.WEXITED n -> Error (Printf.sprintf "❌ LLM: ollama exit %d" n)
    | _ -> Error "❌ LLM: ollama signaled"
  with
  | Yojson.Json_error msg -> Error (Printf.sprintf "❌ Parse: JSON error [%s]" msg)
  | exn -> Error (Printf.sprintf "❌ LLM: ollama exception [%s]" (Printexc.to_string exn))

(** Smart LLM generate — CLI rotation with ollama fallback *)
let smart_generate ~net ?(temperature = 0.7) ?(num_predict = 500) ~system prompt =
  (* 1. Try CLI first (rotation: gemini → claude → codex) *)
  let cli = next_cli_provider () in
  Printf.eprintf "[LLM] Trying %s...\n%!" (string_of_provider cli);
  match cli_generate cli ~system prompt with
  | Ok response ->
      Printf.eprintf "[LLM] ✅ %s succeeded\n%!" (string_of_provider cli);
      Ok response
  | Error e1 ->
      Printf.eprintf "[LLM] ❌ %s failed: %s\n%!" (string_of_provider cli) e1;
      (* 2. Try another CLI *)
      let cli2 = next_cli_provider () in
      Printf.eprintf "[LLM] Trying %s...\n%!" (string_of_provider cli2);
      match cli_generate cli2 ~system prompt with
      | Ok response ->
          Printf.eprintf "[LLM] ✅ %s succeeded\n%!" (string_of_provider cli2);
          Ok response
      | Error e2 ->
          Printf.eprintf "[LLM] ❌ %s failed: %s\n%!" (string_of_provider cli2) e2;
          (* 3. Fallback to cloud GLM via Z.ai API — 200K context, no VRAM *)
          Printf.eprintf "[LLM] Falling back to cloud GLM (Z.ai)...\n%!";
          glm_direct ~net ~temperature ~max_tokens:num_predict ~system prompt

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
    with exn -> Error (Printf.sprintf "❌ Parse: HN JSON error [%s]" (Printexc.to_string exn))

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
    with exn -> Error (Printf.sprintf "Neo4j error: %s" (Printexc.to_string exn))

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

(** {1 Dynamic Agent Loading from Neo4j (SOUL Layer - Tier 3)} *)

(** Cached agent data from Neo4j *)
type agent_config = {
  name: string;
  primary_value: string option;
  value_weights: string option;    (* JSON string *)
  prompt_template: string option;
  generation: int;
  status: string;
  (* Dynamic Lodge identity from Neo4j *)
  emoji: string;
  korean_name: string;
  model: string;
  interests: string list;
}

(** In-memory cache for dynamic agents (protected by mutex for concurrent access) *)
let agent_cache : (string, agent_config) Hashtbl.t = Hashtbl.create 10
let agent_cache_mu = Mutex.create ()

(** {2 File-based cache for offline fallback} *)

(** Get .masc directory path *)
let get_masc_dir () =
  let me_root = match Sys.getenv_opt "ME_ROOT" with
    | Some r -> r
    | None -> match Sys.getenv_opt "HOME" with
      | Some h -> h ^ "/me"
      | None -> "."
  in
  me_root ^ "/.masc"

(** Agent cache file path *)
let agent_file_cache_path () =
  get_masc_dir () ^ "/agent_cache.json"

(** Cache TTL in hours (configurable via env) *)
let agent_cache_ttl_hours () =
  match Sys.getenv_opt "MASC_AGENT_CACHE_TTL_HOURS" with
  | Some s -> (try float_of_string s with _ -> 24.0)
  | None -> 24.0

(** Convert agent_config to JSON *)
let agent_config_to_yojson (a : agent_config) : Yojson.Safe.t =
  `Assoc [
    ("name", `String a.name);
    ("primary_value", match a.primary_value with Some v -> `String v | None -> `Null);
    ("value_weights", match a.value_weights with Some v -> `String v | None -> `Null);
    ("prompt_template", match a.prompt_template with Some v -> `String v | None -> `Null);
    ("generation", `Int a.generation);
    ("status", `String a.status);
    ("emoji", `String a.emoji);
    ("korean_name", `String a.korean_name);
    ("model", `String a.model);
    ("interests", `List (List.map (fun s -> `String s) a.interests));
  ]

(** Parse agent_config from JSON *)
let agent_config_of_yojson (json : Yojson.Safe.t) : agent_config option =
  try
    let open Yojson.Safe.Util in
    Some {
      name = json |> member "name" |> to_string;
      primary_value = json |> member "primary_value" |> to_string_option;
      value_weights = json |> member "value_weights" |> to_string_option;
      prompt_template = json |> member "prompt_template" |> to_string_option;
      generation = json |> member "generation" |> to_int_option |> Option.value ~default:0;
      status = json |> member "status" |> to_string_option |> Option.value ~default:"active";
      emoji = json |> member "emoji" |> to_string_option |> Option.value ~default:"🤖";
      korean_name = json |> member "korean_name" |> to_string_option |> Option.value ~default:"";
      model = json |> member "model" |> to_string_option |> Option.value ~default:"glm-4.7-flash:latest";
      interests = json |> member "interests" |> to_list |> List.filter_map to_string_option;
    }
  with _ -> None

(** Save in-memory agent cache to file *)
let save_agents_to_file_cache () =
  Mutex.lock agent_cache_mu;
  let agents = Hashtbl.fold (fun _ v acc -> v :: acc) agent_cache [] in
  Mutex.unlock agent_cache_mu;
  if agents = [] then ()
  else begin
    let cache_json = `Assoc [
      ("updated_at", `Float (Unix.gettimeofday ()));
      ("agents", `List (List.map agent_config_to_yojson agents));
    ] in
    try
      let path = agent_file_cache_path () in
      let dir = Filename.dirname path in
      if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
      let oc = open_out path in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () ->
        output_string oc (Yojson.Safe.pretty_to_string cache_json))
    with e ->
      Printf.eprintf "[Lodge] Failed to save agent cache: %s\n%!" (Printexc.to_string e)
  end

(** Load agents from file cache (returns true if loaded, false otherwise) *)
let load_agents_from_file_cache () : bool =
  let path = agent_file_cache_path () in
  if not (Sys.file_exists path) then begin
    Printf.eprintf "[Lodge] No file cache at %s\n%!" path;
    false
  end else begin
    try
      let ic = open_in path in
      let content = Fun.protect ~finally:(fun () -> close_in_noerr ic)
        (fun () -> really_input_string ic (in_channel_length ic)) in
      let json = Yojson.Safe.from_string content in
      let open Yojson.Safe.Util in
      let updated_at = json |> member "updated_at" |> to_float in
      let age_hours = (Unix.gettimeofday () -. updated_at) /. 3600.0 in
      let ttl = agent_cache_ttl_hours () in
      if age_hours > ttl then begin
        Printf.eprintf "[Lodge] Cache expired (%.1f hours old, TTL=%.0f)\n%!" age_hours ttl;
        false
      end else begin
        let agents_json = json |> member "agents" |> to_list in
        let loaded = List.filter_map agent_config_of_yojson agents_json in
        Mutex.lock agent_cache_mu;
        List.iter (fun a -> Hashtbl.replace agent_cache a.name a) loaded;
        Mutex.unlock agent_cache_mu;
        Printf.eprintf "[Lodge] Loaded %d agents from file cache (%.1f hours old)\n%!" (List.length loaded) age_hours;
        true
      end
    with e ->
      Printf.eprintf "[Lodge] Failed to load file cache: %s\n%!" (Printexc.to_string e);
      false
  end

(** Load agents from Neo4j via GraphQL API with file cache fallback *)
let load_agents_config () =
  Printf.eprintf "[Lodge] Loading agents from GraphQL...\n%!";
  (* Query all Lodge identity fields for dynamic agent system *)
  (* DO NOT reduce below 15: GRAPHQL_MAX_COST=2000 (c09140c). 15 agents exist. *)
  let query = "{\"query\": \"{ agents(first: 15) { edges { node { name primaryValue status emoji koreanName model interests } } } }\"}" in
  let graphql_success = ref false in
  begin try
    match graphql_request ~timeout_sec:5.0 query with
    | Error err ->
        Printf.eprintf "[Lodge] GraphQL request failed: %s\n%!" err
    | Ok json_str ->
        Printf.eprintf "[Lodge] GraphQL response: %d bytes\n%!" (String.length json_str);
        (* Parse JSON response *)
        let json = Yojson.Safe.from_string json_str in
        let edges = json
          |> Yojson.Safe.Util.member "data"
          |> Yojson.Safe.Util.member "agents"
          |> Yojson.Safe.Util.member "edges"
          |> Yojson.Safe.Util.to_list
        in
        List.iter (fun edge ->
          try
            let node = Yojson.Safe.Util.member "node" edge in
            let name = Yojson.Safe.Util.(member "name" node |> to_string) in
            let interests_json = Yojson.Safe.Util.(member "interests" node) in
            let interests = match interests_json with
              | `List items -> List.filter_map (fun i -> Yojson.Safe.Util.to_string_option i) items
              | _ -> []
            in
            let config = {
              name;
              primary_value = Yojson.Safe.Util.(member "primaryValue" node |> to_string_option);
              value_weights = Yojson.Safe.Util.(member "valueWeights" node |> to_string_option);
              prompt_template = Yojson.Safe.Util.(member "promptTemplate" node |> to_string_option);
              generation = Yojson.Safe.Util.(member "generation" node |> to_int_option) |> Option.value ~default:0;
              status = Yojson.Safe.Util.(member "status" node |> to_string_option) |> Option.value ~default:"active";
              emoji = Yojson.Safe.Util.(member "emoji" node |> to_string_option) |> Option.value ~default:"🤖";
              korean_name = Yojson.Safe.Util.(member "koreanName" node |> to_string_option) |> Option.value ~default:name;
              model = Yojson.Safe.Util.(member "model" node |> to_string_option) |> Option.value ~default:"glm-4.7-flash:latest";
              interests;
            } in
            Mutex.lock agent_cache_mu;
            Hashtbl.replace agent_cache config.name config;
            Mutex.unlock agent_cache_mu
          with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> ()
        ) edges;
        Mutex.lock agent_cache_mu;
        let n = Hashtbl.length agent_cache in
        Mutex.unlock agent_cache_mu;
        if n > 0 then begin
          graphql_success := true;
          Printf.eprintf "[Lodge] ✅ Loaded %d SOUL agents from Neo4j\n%!" n;
          (* Save to file cache for offline fallback *)
          save_agents_to_file_cache ()
        end
  with e ->
    Printf.eprintf "[Lodge] ❌ GraphQL failed: %s\n%!" (Printexc.to_string e)
  end;
  (* Fallback to file cache if GraphQL failed *)
  if not !graphql_success then begin
    Printf.eprintf "[Lodge] Trying file cache fallback...\n%!";
    if not (load_agents_from_file_cache ()) then
      Printf.eprintf "[Lodge] ⚠ No agents available (GraphQL failed, no valid cache)\n%!"
  end

(** Get cached agent config, or None if not loaded *)
let get_cached_agent name =
  Mutex.lock agent_cache_mu;
  let r = Hashtbl.find_opt agent_cache name in
  Mutex.unlock agent_cache_mu;
  r

(** Get primary value from cached agent (for SOUL-based decisions) *)
let get_agent_primary_value name =
  match get_cached_agent name with
  | Some config -> config.primary_value
  | None -> None

(** {1 SOUL Evolution - Feedback-driven weight adjustment} *)

(** Feedback type for evolution *)
type feedback_outcome = Positive | Negative | Neutral

(** Learning rate for weight adjustments (small steps) *)
let learning_rate = 0.01

(** Clamp value between min and max *)
let clamp min_v max_v v =
  if v < min_v then min_v
  else if v > max_v then max_v
  else v

(** Parse value_weights JSON string to association list *)
let parse_value_weights json_str =
  try
    let json = Yojson.Safe.from_string json_str in
    match json with
    | `Assoc pairs ->
      List.filter_map (fun (k, v) ->
        match v with
        | `Float f -> Some (k, f)
        | `Int i -> Some (k, float_of_int i)
        | _ -> None
      ) pairs
    | _ -> []
  with Yojson.Json_error _ -> []

(** Serialize value_weights back to JSON string *)
let serialize_value_weights weights =
  let pairs = List.map (fun (k, v) -> (k, `Float v)) weights in
  Yojson.Safe.to_string (`Assoc pairs)

(** Evolve agent's value_weights based on feedback
    - Adjusts weights by learning_rate
    - Ensures primary_value never drops below 0.5
    - Increments generation
    - Updates Neo4j
*)
let evolve_agent ~name ~dimension ~outcome =
  match get_cached_agent name with
  | None ->
    Printf.eprintf "[Evolution] Agent %s not found in cache\n%!" name;
    false
  | Some config ->
    let weights = match config.value_weights with
      | Some json -> parse_value_weights json
      | None -> []
    in
    if weights = [] then begin
      Printf.eprintf "[Evolution] No value_weights for %s\n%!" name;
      false
    end else begin
      (* Calculate delta based on outcome *)
      let delta = match outcome with
        | Positive -> learning_rate
        | Negative -> -. learning_rate
        | Neutral -> 0.0
      in
      (* Update the specific dimension *)
      let new_weights = List.map (fun (dim, weight) ->
        if dim = dimension then
          let new_weight = clamp 0.0 1.0 (weight +. delta) in
          (* Constraint: primary_value can't go below 0.5 *)
          let final_weight =
            match config.primary_value with
            | Some pv when pv = dim && new_weight < 0.5 -> 0.5
            | _ -> new_weight
          in
          (dim, final_weight)
        else (dim, weight)
      ) weights in
      let new_weights_json = serialize_value_weights new_weights in
      let new_gen = config.generation + 1 in
      (* Update Neo4j via cypher-shell *)
      let esc = cypher_escape in
      let cypher = Printf.sprintf
        "MATCH (a:Agent {name: '%s'}) SET a.value_weights = '%s', a.generation = %d, a.last_updated = datetime() RETURN a.name"
        (esc name) (esc new_weights_json) new_gen
      in
      let neo4j_uri = Sys.getenv_opt "NEO4J_URI" |> Option.value ~default:"" in
      let neo4j_pw = Sys.getenv_opt "NEO4J_PASSWORD" |> Option.value ~default:"" in
      try
        let argv =
          ["cypher-shell"; "-a"; neo4j_uri;
           "-u"; "neo4j"; "-p"; neo4j_pw;
           "--format"; "plain";
           cypher]
        in
        let (status, _output) = run_cmd_with_status ~timeout_sec:60.0 argv in
        (match status with Unix.WEXITED 0 -> () | _ -> raise (Failure "cypher-shell failed"));
        (* Update cache *)
        Mutex.lock agent_cache_mu;
        Hashtbl.replace agent_cache name {
          config with
          value_weights = Some new_weights_json;
          generation = new_gen;
        };
        Mutex.unlock agent_cache_mu;
        Printf.eprintf "[Evolution] %s evolved: %s %s%.2f -> gen %d\n%!"
          name dimension
          (if delta >= 0.0 then "+" else "") delta new_gen;
        true
      with e ->
        Printf.eprintf "[Evolution] Failed to update %s: %s\n%!" name (Printexc.to_string e);
        false
    end

(** Record feedback for an agent's decision (by name) *)
let record_feedback ~name ~dimension ~is_positive =
  let outcome = if is_positive then Positive else Negative in
  evolve_agent ~name ~dimension ~outcome

(** Initialize Lodge module after Eio context is ready.
    Call from main_eio.ml after Eio_context.set_net *)
let init () =
  (* Load agents for evolution triggers *)
  load_agents_config ()

(** Module initialization - only register callbacks (no network calls) *)
let () =
  (* Register SOUL Evolution callback with Tool_board (breaks dependency cycle) *)
  Tool_board.register_evolution_callback {
    Tool_board.get_primary_value = get_agent_primary_value;
    record_feedback = (fun ~name ~dimension ~is_positive ->
      let _ = record_feedback ~name ~dimension ~is_positive in ());
  }

(** {1 REACT: Dynamic agent system (Neo4j SSOT)}

    All agent data comes from Neo4j via GraphQL cache.
    No hardcoded agent enums — add new agents by MERGE into Neo4j.
*)

(** Get all cached agent names *)
let get_all_agent_names () =
  Mutex.lock agent_cache_mu;
  let r = Hashtbl.fold (fun k _ acc -> k :: acc) agent_cache [] in
  Mutex.unlock agent_cache_mu;
  r

(** Pick a random agent name from cache *)
let random_agent_name () =
  let names = get_all_agent_names () in
  if names = [] then "dreamer"  (* fallback if cache empty — should not happen after startup *)
  else List.nth names (Random.int (List.length names))

(** Validate agent name exists in cache (replaces validate_agent_name) *)
let validate_agent_name name =
  if name = "random" || name = "랜덤" then Some (random_agent_name ())
  else match get_cached_agent name with
    | Some _ -> Some name
    | None ->
      (* Try Korean name lookup *)
      Mutex.lock agent_cache_mu;
      let found = Hashtbl.fold (fun k v acc ->
        match acc with Some _ -> acc | None ->
        if v.korean_name = name then Some k else None
      ) agent_cache None in
      Mutex.unlock agent_cache_mu;
      found

(** Get model for agent (from Neo4j cache) *)
let get_agent_model name =
  match get_cached_agent name with
  | Some c -> c.model
  | None -> "glm-4.7-flash:latest"

(** Get prompt from Neo4j cache *)
let get_agent_prompt name =
  match get_cached_agent name with
  | Some config ->
    (match config.prompt_template with
     | Some prompt -> prompt
     | None -> Printf.sprintf "You are %s." name)
  | None ->
    load_agents_config ();
    match get_cached_agent name with
    | Some config ->
      (match config.prompt_template with
       | Some prompt -> prompt
       | None -> Printf.sprintf "You are %s." name)
    | None ->
      Printf.sprintf "You are %s. (Not found in Neo4j)" name

(** Get interests for agent (from Neo4j cache) *)
let get_agent_interests_cached name =
  match get_cached_agent name with
  | Some c -> c.interests
  | None -> []

(** Check if content matches agent's interests *)
let matches_agent_interest agent_name content =
  let keywords = get_agent_interests_cached agent_name in
  let content_lower = String.lowercase_ascii content in
  List.exists (fun kw ->
    let kw_lower = String.lowercase_ascii kw in
    try ignore (Str.search_forward (Str.regexp_string kw_lower) content_lower 0); true
    with Not_found -> false
  ) keywords

(** Format agent name with emoji badge (from Neo4j cache) *)
let format_agent_name_dynamic name =
  match get_cached_agent name with
  | Some c -> Printf.sprintf "%s **%s** (%s)" c.emoji name c.korean_name
  | None -> Printf.sprintf "🤖 **%s**" name

(** Extract just the post content from formatted board output.
    Input format:
      **p-xxx** [visibility] (by author, time, TTL: ttl)
      ACTUAL CONTENT
      [↑N ↓N = +/-N] [N replies]
      ...
    Returns: just the ACTUAL CONTENT part *)
let extract_post_content formatted =
  try
    (* Split by newline *)
    let lines = String.split_on_char '\n' formatted in
    (* Skip first line (metadata), take lines until vote line *)
    let content_lines = List.filter (fun line ->
      not (String.length line > 0 && line.[0] = '*' && String.sub line 0 3 = "**p") &&  (* skip **p-xxx** line *)
      not (String.length line > 0 && line.[0] = '[' && String.sub line 0 2 = "[↑") &&   (* skip vote line *)
      not (String.length line > 3 && String.sub line 0 4 = "💬 *")                       (* skip comments header *)
    ) lines in
    (* Also filter out comment lines (start with spaces) *)
    let content_lines = List.filter (fun line ->
      String.length line = 0 || (String.length line > 0 && line.[0] <> ' ')
    ) content_lines in
    let result = String.trim (String.concat "\n" content_lines) in
    if result = "" then formatted else result  (* fallback to original if extraction fails *)
  with Invalid_argument _ | Not_found -> formatted

(** Translate text to Korean using CLI rotation.
    If translation fails or text is already Korean, returns original. *)
let translate_to_korean ~net text =
  (* Skip if already mostly Korean (simple heuristic: check for Hangul syllables) *)
  let korean_char_count = ref 0 in
  String.iter (fun c ->
    let code = Char.code c in
    (* Hangul syllables are in 0xAC00-0xD7AF range, but in UTF-8 they span multiple bytes *)
    (* Simple check: if byte is in 0xE0-0xEF range, might be Korean *)
    if code >= 0xE0 && code <= 0xEF then incr korean_char_count
  ) text;
  if !korean_char_count > 5 then text  (* Already has Korean *)
  else
    let system = "/no_think\nTranslate the following text to natural Korean. Output ONLY the Korean translation, nothing else. Keep it concise (2-4 sentences)." in
    match smart_generate ~net ~temperature:0.3 ~num_predict:300 ~system text with
    | Ok translated -> String.trim translated
    | Error _ -> text  (* fallback to original *)

(** React to content with a dynamic agent (from Neo4j cache) *)
let react_to_content ~net ?agent_name:provided_name ?post_id content =
  let agent_name = match provided_name with
    | Some n -> n
    | None -> random_agent_name ()
  in
  (* Get prompt from Neo4j cache *)
  let agent_desc = get_agent_prompt agent_name in

  (* Get agent's existing interests for context *)
  let existing_interests = get_agent_interests ~agent_name in
  let interests_context = if existing_interests = [] then ""
    else Printf.sprintf "\nYour interests: %s. Connect these to your response."
      (String.concat ", " existing_interests)
  in

  let system = Printf.sprintf "/no_think\n\
    You are a Lodge participant. %s%s\n\
    Share your unique perspective. Be thoughtful, specific, and add value. 2-4 sentences only."
    agent_desc interests_context in
  (* A2A delegation: emit event for external worker instead of local LLM *)
  if Env_config.LodgeV2.delegate_llm then begin
    let action_hint = match post_id with
      | Some pid -> Some ("COMMENT:" ^ pid)
      | None -> Some "POST"
    in
    A2a_tools.emit_heartbeat_task ~agent:agent_name ~prompt:system
      ~context:(Printf.sprintf "React to this Lodge post:\n%s" content)
      ?action_hint ();
    Ok ""  (* Empty = delegated; caller skips comment posting *)
  end else
  match smart_generate ~net ~temperature:0.8 ~num_predict:250 ~system
    (Printf.sprintf "React to this Lodge post:\n%s\n\nYour perspective:" content) with
  | Error e -> Error e
  | Ok response ->
    let final_response = match lodge_language with
      | "ko" -> translate_to_korean ~net response
      | _ -> response
    in
    let new_interests = extract_interests ~net content in
    let _ = save_interests_to_neo4j ~agent_name new_interests in
    let display_name = format_agent_name_dynamic agent_name in
    Ok (Printf.sprintf "%s\n%s" display_name final_response)

(** {1 Heartbeat: Full Read → Dig → Share cycle} *)

let heartbeat ~net (args : Yojson.Safe.t) =
  let source_str = Safe_ops.json_string ~default:"hn" "source" args in
  (* TODO: GeekNews support — for now only HN is implemented *)
  let (_ : source) = source_of_string source_str |> Option.value ~default:HackerNews in

  (* READ *)
  match fetch_hn_article ~net with
  | Error e -> (false, Printf.sprintf "❌ Lodge: Read failed [%s]" e)
  | Ok article ->
    (* DIG — with Eio timeout *)
    match dig_article ~net article with
    | Error e -> (false, Printf.sprintf "❌ Lodge: Dig failed [article=%s, error=%s]" article.title e)
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
      if success then begin
        (* Auto-react: enabled by default, disable with MASC_LODGE_AUTO_REACT=0 *)
        let auto_react_enabled = Sys.getenv_opt "MASC_LODGE_AUTO_REACT" |> Option.value ~default:"1" = "1" in
        let summary = if auto_react_enabled then begin
          (* Extract post_id for auto-react *)
          let post_id = try
            let re = Str.regexp "p-[a-f0-9]+" in
            ignore (Str.search_forward re msg 0);
            Str.matched_string msg
          with Not_found -> "" in
          (* Auto-trigger reactions from agents *)
          let reactions = if post_id <> "" then
            List.filter_map (fun agent ->
              match react_to_content ~net ~agent_name:agent ~post_id content with
              | Error _ -> None
              | Ok "" -> Some (Printf.sprintf "🔮 %s (delegated)" agent)
              | Ok reaction ->
                let args = `Assoc [("post_id", `String post_id); ("content", `String reaction); ("author", `String agent)] in
                let (ok, _) = Tool_board.handle_tool "masc_board_comment" args in
                if ok then Some (Printf.sprintf "💬 %s" agent) else None
            ) (let names = get_all_agent_names () in
               if List.length names >= 2 then [List.nth names 0; List.nth names 1]
               else names)
          else [] in
          match reactions with [] -> "" | rs -> "\n🎭 " ^ String.concat ", " rs
        end else "" in
        (true, Printf.sprintf "🏔️ Lodge shared: %s\n%s%s" article.title msg summary)
      end else
        (false, Printf.sprintf "❌ Lodge: Share failed [%s]" msg)

(** {1 Classify tool: classify a post} *)

let classify ~net (args : Yojson.Safe.t) =
  let post_id = Safe_ops.json_string ~default:"" "post_id" args in
  if post_id = "" then (false, "❌ Lodge: post_id required")
  else
    let (success, detail) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
    if not success then (false, Printf.sprintf "❌ Lodge: Board get failed [%s]" detail)
    else
      let clean_content = extract_post_content detail in
      let cls = classify_content ~net clean_content in
      let result = Printf.sprintf "🏷️ %s → %s (%s)" post_id (string_of_category cls.category) cls.details in
      (true, result)

(** {1 React tool: respond to a post with agent} *)

(** React to a post with agent

    When skip_classify=true, bypasses LLM classification and directly generates
    a reaction. This significantly speeds up the process by avoiding one LLM call. *)
let react ~net (args : Yojson.Safe.t) =
  let post_id_arg = Safe_ops.json_string ~default:"" "post_id" args in
  let agent_str = Safe_ops.json_string ~default:"random" "agent" args in
  let skip_classify = Safe_ops.json_bool ~default:true "skip_classify" args in
  let agent_name = match validate_agent_name agent_str with
    | Some n -> n
    | None -> random_agent_name ()
  in
  if post_id_arg = "" then (false, "❌ Lodge: post_id required")
  else
    let post_id =
      if post_id_arg = "random" then begin
        let (ok, list_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("random", `Bool true); ("limit", `Int 10)]) in
        if ok then
          try
            let re = Str.regexp "p-[a-f0-9]+" in
            let _ = Str.search_forward re list_result 0 in
            Str.matched_string list_result
          with Not_found -> post_id_arg
        else post_id_arg
      end else post_id_arg
    in
    let (success, detail) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String post_id)]) in
    if not success then (false, Printf.sprintf "❌ Lodge: Board get failed [%s]" detail)
    else
      let clean_content = extract_post_content detail in
      if skip_classify then
      match react_to_content ~net ~agent_name ~post_id clean_content with
      | Error e -> (false, Printf.sprintf "❌ Lodge: React failed [agent=%s, error=%s]" agent_name e)
      | Ok "" -> (true, Printf.sprintf "🔮 Lodge reaction delegated for %s [agent=%s]" post_id agent_name)
      | Ok reaction ->
        let comment_args = `Assoc [
          ("post_id", `String post_id);
          ("content", `String reaction);
          ("author", `String agent_name);
        ] in
        let (ok, msg) = Tool_board.handle_tool "masc_board_comment" comment_args in
        if ok then (true, Printf.sprintf "💬 Lodge reaction posted on %s:\n%s" post_id reaction)
        else (false, Printf.sprintf "❌ Lodge: Comment failed [post=%s, error=%s]" post_id msg)
    else
      let cls = classify_content ~net clean_content in
      match cls.category with
      | Noise -> (true, Printf.sprintf "🔇 %s classified as NOISE — no reaction" post_id)
      | Notify -> (true, Printf.sprintf "⚠️ %s classified as NOTIFY — flagged for human" post_id)
      | Review ->
        match react_to_content ~net ~agent_name ~post_id clean_content with
        | Error e -> (false, Printf.sprintf "❌ Lodge: React failed [agent=%s, error=%s]" agent_name e)
        | Ok "" -> (true, Printf.sprintf "🔮 Lodge reaction delegated for %s [agent=%s]" post_id agent_name)
        | Ok reaction ->
          let comment_args = `Assoc [
            ("post_id", `String post_id);
            ("content", `String reaction);
            ("author", `String agent_name);
          ] in
          let (ok, msg) = Tool_board.handle_tool "masc_board_comment" comment_args in
          if ok then (true, Printf.sprintf "💬 Lodge reaction posted on %s:\n%s" post_id reaction)
          else (false, Printf.sprintf "❌ Lodge: Comment failed [post=%s, error=%s]" post_id msg)

(** {1 Full cycle: heartbeat + ONE random agent reacts} *)

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
      (* Step 2: ONE random agent reacts *)
      let agent = random_agent_name () in
      let (ok2, result) = react ~net (`Assoc [
        ("post_id", `String post_id);
        ("agent", `String agent);
      ]) in
      let model = get_agent_model agent in
      (true, Printf.sprintf "%s\n\n💬 %s [%s] reacted:\n%s"
        msg agent model (if ok2 then result else "❌ " ^ result))

(** {1 Discussion: agents read and react to EACH OTHER's posts} *)

let lodge_discussion ~net (_args : Yojson.Safe.t) =
  let agent = random_agent_name () in

  let (ok, posts_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("limit", `Int 10)]) in
  if not ok then (false, Printf.sprintf "❌ Lodge: Failed to list posts [%s]" posts_result)
  else
    let post_ids =
      let re = Str.regexp "\\*\\*\\(p-[a-f0-9]+\\)\\*\\*" in
      let rec find_all start acc =
        try
          ignore (Str.search_forward re posts_result start);
          find_all (Str.match_end ()) (Str.matched_group 1 posts_result :: acc)
        with Not_found -> List.rev acc
      in
      find_all 0 []
    in

    if post_ids = [] then (true, Printf.sprintf "📭 %s: 게시판이 비어있어요" agent)
    else
      let target = List.nth post_ids (Random.int (List.length post_ids)) in
      let (ok2, result) = react ~net (`Assoc [
        ("post_id", `String target);
        ("agent", `String agent);
      ]) in
      let model = get_agent_model agent in
      (true, Printf.sprintf "💬 %s [%s] joined discussion on %s:\n%s"
        agent model target (if ok2 then result else "❌ " ^ result))

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
  description = "React to a post with a unique agent perspective. Agents: pragmatist(실용주의자), dreamer(몽상가), skeptic(회의론자), connector(연결자), historian(역사가), random(랜덤)";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("post_id", `Assoc [("type", `String "string"); ("description", `String "Post ID to react to")]);
      ("agent", `Assoc [("type", `String "string"); ("description", `String "Agent name: pragmatist, dreamer, skeptic, connector, historian, or random (default)")]);
    ]);
    ("required", `List [`String "post_id"]);
  ];
}

let tool_cycle : Types.tool_schema = {
  name = "lodge_cycle";
  description = "Full Lodge cycle: Read → Dig → Share → ONE random agent reacts";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("source", `Assoc [("type", `String "string"); ("description", `String "Content source: hn (default)")]);
    ]);
  ];
}

let tool_discussion : Types.tool_schema = {
  name = "lodge_discussion";
  description = "Random agent joins discussion: reads recent posts and reacts to one. Call repeatedly for lively discussion!";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}

(** {1 State Machine Orchestrator — CrewAI + LangGraph + AutoGen 통합} *)

(** Discussion state machine *)
type discussion_state =
  | Idle        (** 대기 중 — 새 주제 기다림 *)
  | Topic       (** 주제 선정 — 첫 에이전트가 반응 *)
  | Discuss     (** 토론 중 — 2~3턴 추가 반응 *)
  | Conclude    (** 결론 — historian이 요약 *)

type discussion_context = {
  mutable state: discussion_state;
  mutable post_id: string;
  mutable turn_count: int;
  mutable max_turns: int;
  mutable participants: string list;
  mutable last_speaker: string option;
}

let global_discussion : discussion_context = {
  state = Idle;
  post_id = "";
  turn_count = 0;
  max_turns = 4;
  participants = [];
  last_speaker = None;
}

let string_of_state = function
  | Idle -> "IDLE"
  | Topic -> "TOPIC"
  | Discuss -> "DISCUSS"
  | Conclude -> "CONCLUDE"

(** Select next agent: avoid last speaker, prefer unused *)
let select_next_agent ctx =
  let all = get_all_agent_names () in
  let available = List.filter (fun name ->
    match ctx.last_speaker with
    | Some last -> name <> last
    | None -> true
  ) all in
  let unused = List.filter (fun name -> not (List.mem name ctx.participants)) available in
  let pool = if unused = [] then available else unused in
  if pool = [] then random_agent_name ()
  else List.nth pool (Random.int (List.length pool))

(** State machine orchestrator (single step) *)
let lodge_orchestrate ~net (_args : Yojson.Safe.t) =
  let ctx = global_discussion in
  let buf = Buffer.create 256 in
  let log msg = Buffer.add_string buf (msg ^ "\n") in

  log (Printf.sprintf "📊 State: %s (turn %d/%d)" (string_of_state ctx.state) ctx.turn_count ctx.max_turns);

  begin match ctx.state with
  | Idle ->
      (* Find a post to discuss *)
      let (ok, posts_result) = Tool_board.handle_tool "masc_board_list" (`Assoc [("limit", `Int 5)]) in
      if not ok then begin
        log "❌ Failed to list posts";
      end else begin
        let post_ids =
          let re = Str.regexp "\\*\\*\\(p-[a-f0-9]+\\)\\*\\*" in
          let rec find_all start acc =
            try
              ignore (Str.search_forward re posts_result start);
              find_all (Str.match_end ()) (Str.matched_group 1 posts_result :: acc)
            with Not_found -> List.rev acc
          in
          find_all 0 []
        in
        if post_ids = [] then
          log "📭 No posts to discuss"
        else begin
          ctx.post_id <- List.hd post_ids;
          ctx.turn_count <- 0;
          ctx.participants <- [];
          ctx.last_speaker <- None;
          ctx.state <- Topic;
          log (Printf.sprintf "📌 Selected topic: %s" ctx.post_id);
        end
      end

  | Topic ->
      let agent = select_next_agent ctx in
      let (ok, result) = react ~net (`Assoc [
        ("post_id", `String ctx.post_id);
        ("agent", `String agent);
      ]) in
      ctx.participants <- agent :: ctx.participants;
      ctx.last_speaker <- Some agent;
      ctx.turn_count <- 1;
      if ok then begin
        log (Printf.sprintf "💬 %s (TOPIC): %s" agent (String.sub result 0 (min 100 (String.length result))));
        ctx.state <- Discuss;
      end else begin
        log (Printf.sprintf "❌ %s failed: %s" agent result);
        ctx.state <- Idle;
      end

  | Discuss ->
      if ctx.turn_count >= ctx.max_turns - 1 then begin
        ctx.state <- Conclude;
        log "⏰ Max turns reached, transitioning to CONCLUDE";
      end else begin
        let agent = select_next_agent ctx in
        let (ok, result) = react ~net (`Assoc [
          ("post_id", `String ctx.post_id);
          ("agent", `String agent);
        ]) in
        ctx.participants <- agent :: ctx.participants;
        ctx.last_speaker <- Some agent;
        ctx.turn_count <- ctx.turn_count + 1;
        if ok then
          log (Printf.sprintf "💬 %s (turn %d): %s"
            agent ctx.turn_count
            (String.sub result 0 (min 100 (String.length result))))
        else
          log (Printf.sprintf "⚠️ %s error: %s" agent result)
      end

  | Conclude ->
      (* Pick a concluder from available agents *)
      let concluder = random_agent_name () in
      let (ok, result) = react ~net (`Assoc [
        ("post_id", `String ctx.post_id);
        ("agent", `String concluder);
      ]) in
      if ok then
        log (Printf.sprintf "📜 %s concludes: %s" concluder (String.sub result 0 (min 150 (String.length result))))
      else
        log (Printf.sprintf "❌ %s failed: %s" concluder result);
      (* Reset *)
      ctx.state <- Idle;
      ctx.post_id <- "";
      ctx.turn_count <- 0;
      ctx.participants <- [];
      ctx.last_speaker <- None;
      log "🔄 Discussion complete, returning to IDLE"
  end;

  (true, Buffer.contents buf)

(** Auto-chain: run orchestrator with probability continuation *)
let lodge_auto_chain ~net (args : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let chain_prob = try to_float (member "chain_probability" args) with Yojson.Safe.Util.Type_error _ -> 0.5 in
  let max_chain = try to_int (member "max_chain" args) with Yojson.Safe.Util.Type_error _ -> 3 in

  let buf = Buffer.create 512 in
  let add msg = Buffer.add_string buf (msg ^ "\n") in

  add (Printf.sprintf "🔄 Auto-chain started (p=%.2f, max=%d)" chain_prob max_chain);

  let rec loop count =
    if count >= max_chain then begin
      add (Printf.sprintf "⏹️ Max chain reached (%d)" count);
    end else begin
      let (_, result) = lodge_orchestrate ~net (`Assoc []) in
      add result;

      (* Continue with probability *)
      if Random.float 1.0 < chain_prob then begin
        add (Printf.sprintf "🎲 Continuing (roll < %.2f)..." chain_prob);
        Eio.Time.sleep (Process_eio.get_clock ()) 0.5;
        loop (count + 1)
      end else begin
        add (Printf.sprintf "🎲 Stopping (roll >= %.2f)" chain_prob);
      end
    end
  in

  loop 0;
  (true, Buffer.contents buf)

let tool_orchestrate : Types.tool_schema = {
  name = "lodge_orchestrate";
  description = "State machine orchestrator: IDLE→TOPIC→DISCUSS→CONCLUDE. Combines CrewAI (roles) + LangGraph (states) + AutoGen (conversation). Call repeatedly for full discussion.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc []);
  ];
}

let tool_auto_chain : Types.tool_schema = {
  name = "lodge_auto_chain";
  description = "Auto-chain discussion: runs orchestrator with probabilistic continuation. Good for overnight autonomous discussions.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("chain_probability", `Assoc [("type", `String "number"); ("description", `String "Probability to continue (0.0-1.0, default: 0.5)")]);
      ("max_chain", `Assoc [("type", `String "integer"); ("description", `String "Max turns in one call (default: 3)")]);
    ]);
  ];
}

(** {1 Agent Persistence & Spawning} *)

(** Core Lodge agents — dynamically loaded from GraphQL cache *)
let core_lodge_agents () = get_all_agent_names ()

(** Get all Lodge agents via GraphQL *)
let get_all_agents () =
  (* DO NOT reduce below 15: GRAPHQL_MAX_COST=2000 (c09140c). 15 agents exist. *)
  let query = "{\"query\": \"{ agents(first: 15) { edges { node { name primaryValue status } } } }\"}" in
  try
    match graphql_request ~timeout_sec:5.0 query with
    | Error err ->
        Printf.eprintf "[Lodge] GraphQL request failed: %s\n%!" err;
        []
    | Ok output ->
        try
          let json = Yojson.Safe.from_string output in
          let edges = json |> member "data" |> member "agents" |> member "edges" |> to_list in
          List.filter_map (fun edge ->
            try
              let node = edge |> member "node" in
              let name = node |> member "name" |> to_string in
              (* Trust GraphQL results — no cache filter (fixes chicken-egg bug) *)
              let primary_value = (try node |> member "primaryValue" |> to_string with Yojson.Safe.Util.Type_error _ -> "unknown") in
              let prompt = (try node |> member "promptTemplate" |> to_string with Yojson.Safe.Util.Type_error _ -> "") in
              let status = (try node |> member "status" |> to_string with Yojson.Safe.Util.Type_error _ -> "active") in
              if status = "active" then
                Some (name, primary_value, prompt, "system", 0)
              else None
            with Yojson.Safe.Util.Type_error _ -> None
          ) edges
        with Yojson.Safe.Util.Type_error _ | Yojson.Json_error _ -> []
  with Unix.Unix_error _ | Sys_error _ -> []

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
	    Printf.eprintf "[neo4j_http] POST %s (body=%d chars)\n%!" url (String.length body);
	    try
	      let output =
	        Process_eio.run_argv_with_stdin ~timeout_sec:30.0 ~stdin_content:body argv
	      in
	      Printf.eprintf "[neo4j_http] response: %s\n%!" (if String.length output < 200 then output else String.sub output 0 200 ^ "...");
	      if String.length output > 0 then Ok output
	      else Error "empty response"
	    with exn -> Error (Printexc.to_string exn)

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
    let graphql_url = Sys.getenv_opt "GRAPHQL_URL"
      |> Option.value ~default:"https://second-brain-graphql-production.up.railway.app/graphql" in
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
	        "mutation { createAgent(name: \"%s\", role: \"%s\", description: \"%s\", peakHour: %d, preferredHours: [%d, %d, %d], traits: [\"%s\"], model: \"glm-4.7\", status: \"active\") { success message agent { name } } }"
	        agent_name escaped_role escaped_prompt
	        peak_hour ((peak_hour - 1 + 24) mod 24) peak_hour ((peak_hour + 1) mod 24)
	        escaped_role
	      in
	      let body = Yojson.Safe.to_string (`Assoc [("query", `String gql)]) in
	      Printf.eprintf "[spawn_agent] GraphQL mutation: createAgent(name=%s, role=%s)\n%!" agent_name child_role;
	      try
	        let argv =
	          ["curl"; "-s"; graphql_url;
	           "-H"; "Content-Type: application/json";
	           "-H"; "Authorization: Bearer " ^ api_key;
	           "-d"; "@-"]
	        in
	        let output =
	          Process_eio.run_argv_with_stdin ~timeout_sec:30.0 ~stdin_content:body argv
	        in
	        Printf.eprintf "[spawn_agent] GraphQL response: %s\n%!" (if String.length output < 300 then output else String.sub output 0 300 ^ "...");
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
            Printf.eprintf "[spawn_agent] GraphQL success\n%!";
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

        if unreacted = [] then
          (true, Printf.sprintf "✅ %s: Already reacted to all recent posts (checked %d)" agent_name (List.length post_ids))
        else
          let target_post = List.hd unreacted in

          let (got_post, post_content) = Tool_board.handle_tool "masc_board_get" (`Assoc [("post_id", `String target_post)]) in

          let upvote_msg =
            if got_post && matches_agent_interest agent_name post_content then begin
              let (_vote_ok, vote_result) = Tool_board.handle_tool "masc_board_vote" (`Assoc [
                ("post_id", `String target_post);
                ("voter", `String agent_name);
                ("direction", `String "up");
              ]) in
              Printf.sprintf "\n👍 Upvoted (matches %s's interests): %s" agent_name vote_result
            end else ""
          in

          let (react_ok, react_msg) = react ~net (`Assoc [
            ("post_id", `String target_post);
            ("agent", `String agent_name);
          ]) in
          if react_ok then
            (true, Printf.sprintf "💬 %s patrolled and reacted to %s:\n%s%s" agent_name target_post react_msg upvote_msg)
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
  description = "Join an existing project as a contributor";
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
  description = "Share a code snippet with other agents";
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
let loop_status : (int * int * string) option ref = ref None  (* (current, total, last_action) *)

(** Autonomous loop - FOREGROUND ONLY

    Background mode was removed because OCaml Thread and Eio scheduler
    are incompatible. Tool_board uses Eio mutex which cannot be accessed
    from Thread.create threads (causes Eio__Eio_mutex.Poisoned error).

    For long-running loops, use Walph presets with direct LLM execution. *)
let autonomous_loop ~net args =
  let iterations = Safe_ops.json_int ~default:10 "iterations" args in
  let iterations = min iterations 50 in  (* cap at 50 for foreground - prevents blocking *)
  let delay_ms = Safe_ops.json_int ~default:3000 "delay_ms" args in
  let verbose = Safe_ops.json_bool ~default:false "verbose" args in
  (* background param ignored - always foreground now *)
  let _ = Safe_ops.json_bool ~default:false "background" args in

  let results = ref [] in
  let patrol_count = ref 0 in
  let research_count = ref 0 in
  let discuss_count = ref 0 in
  let react_count = ref 0 in
  let error_count = ref 0 in

  for i = 1 to iterations do
    loop_status := Some (i, iterations, "running");

    (* Pick random action - weighted towards react for more comments *)
    let action = Random.int 10 in
    let (action_name, (ok, msg)) = match action with
      | 0 | 1 ->
          (* Agent patrol - 20% *)
          let agents = core_lodge_agents () in
          let p = if agents = [] then random_agent_name () else List.nth agents (Random.int (List.length agents)) in
          let emoji = emoji_of_agent p in
          (Printf.sprintf "%s patrol" emoji, agent_patrol ~net (`Assoc [("agent", `String p)]))
      | 2 ->
          (* Research random topic - 10% *)
          let topics = ["OCaml"; "Eio"; "MCP"; "에이전트 협업"; "분산 시스템"; "함수형 프로그래밍"; "타입 시스템"; "동시성"] in
          let t = List.nth topics (Random.int (List.length topics)) in
          ("🔬 research", research ~net (`Assoc [("topic", `String t); ("agent_name", `String "auto-researcher")]))
      | 3 | 4 ->
          (* Discussion between agents - 20% *)
          ("💬 discuss", lodge_discussion ~net (`Assoc []))
      | _ ->
          (* React to random post - 50% (main comment generator) *)
          let agents = core_lodge_agents () in
          let p = if agents = [] then random_agent_name () else List.nth agents (Random.int (List.length agents)) in
          let (react_ok, react_msg) = react ~net (`Assoc [
            ("post_id", `String "random");
            ("agent", `String p);
          ]) in
          if react_ok then ("💬 react", (true, react_msg))
          else ("💬 react (fail)", (false, react_msg))
    in

    (* Update stats *)
    (match action with
     | 0 | 1 -> incr patrol_count
     | 2 -> incr research_count
     | 3 | 4 -> incr discuss_count
     | _ -> incr react_count);
    if not ok then incr error_count;

    (* Log result *)
    let log_entry =
      if verbose then
        Printf.sprintf "[%03d/%03d] %s %s: %s"
          i iterations (if ok then "✅" else "❌") action_name
          (String.sub msg 0 (min 80 (String.length msg)))
      else
        Printf.sprintf "[%03d] %s %s" i (if ok then "✅" else "❌") action_name
    in
    results := log_entry :: !results;

    (* Progress update every 10 iterations *)
    if i mod 10 = 0 && i < iterations then
      results := Printf.sprintf "───── 진행: %d/%d (%.0f%%) ─────" i iterations (100.0 *. float_of_int i /. float_of_int iterations) :: !results;

    (* Delay between iterations - minimum 1s to prevent spam *)
    if i < iterations then Eio.Time.sleep (Process_eio.get_clock ()) (max 1.0 (float_of_int delay_ms /. 1000.0))
  done;

  loop_status := None;
  let summary = Printf.sprintf
    "🔄 **Autonomous Loop 완료**\n\
     ━━━━━━━━━━━━━━━━━━━━━━━━━\n\n\
     📊 **통계:**\n\
        🔧 Patrol: %d회\n\
        🔬 Research: %d회\n\
        💬 Discussion: %d회\n\
        💬 React: %d회\n\
        ❌ Errors: %d회\n\n\
     📝 **로그 (최근 %d개):**\n%s"
    !patrol_count !research_count !discuss_count !react_count !error_count
    (min 50 (List.length !results))
    (String.concat "\n" (List.rev (List.filteri (fun i _ -> i < 50) !results)))
  in
  (true, summary)

let tool_profile : Types.tool_schema = {
  name = "lodge_profile";
  description = "Get an agent's profile with their posts, activity, and stats";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("agent_name", `Assoc [("type", `String "string"); ("description", `String "Agent name to look up")]);
    ]);
    ("required", `List [`String "agent_name"]);
  ];
}

let tool_autonomous_loop : Types.tool_schema = {
  name = "lodge_autonomous_loop";
  description = "Run autonomous improvement loop — agents patrol, react, research, discuss. Verbose mode shows detailed logs.";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("iterations", `Assoc [("type", `String "integer"); ("description", `String "Number of iterations (default: 10, max: 200)")]);
      ("delay_ms", `Assoc [("type", `String "integer"); ("description", `String "Delay between iterations in ms (default: 5000)")]);
      ("verbose", `Assoc [("type", `String "boolean"); ("description", `String "Show detailed logs (default: false)")]);
    ]);
  ];
}

let tool_search : Types.tool_schema = {
  name = "lodge_search";
  description = "Search Lodge content — posts, comments, and agents matching query";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("query", `Assoc [("type", `String "string"); ("description", `String "Search keyword")]);
      ("limit", `Assoc [("type", `String "integer"); ("description", `String "Max results (default: 20)")]);
    ]);
    ("required", `List [`String "query"]);
  ];
}

let tool_comment_like : Types.tool_schema = {
  name = "lodge_comment_like";
  description = "Like (upvote) a comment — quick way to show appreciation";
  input_schema = `Assoc [
    ("type", `String "object");
    ("properties", `Assoc [
      ("comment_id", `Assoc [("type", `String "string"); ("description", `String "Comment ID to like (e.g., c-abc123)")]);
      ("voter", `Assoc [("type", `String "string"); ("description", `String "Who is liking (agent name)")]);
    ]);
    ("required", `List [`String "comment_id"]);
  ];
}

let tool_progress : Types.tool_schema = {
  name = "lodge_progress";
  description = "Show Lodge improvement progress — overnight learning stats, agent growth, discussion activity";
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
  tool_discussion;  (* Agents read & react to each other's posts *)
  tool_orchestrate; (* State machine orchestrator *)
  tool_auto_chain;  (* Probabilistic chain *)
  tool_evolve;
  tool_spawn;
  tool_agents;
  tool_agent_patrol;
  (* Project collaboration *)
  tool_propose_project;
  tool_join_project;
  tool_share_code;
  tool_research;
  (* Profile & Autonomous *)
  tool_profile;
  tool_autonomous_loop;
  (* New: Search, Like, Progress *)
  tool_search;
  tool_comment_like;
  tool_progress;
]

(** Tool dispatcher — requires ~net for Eio network access *)
let handle_tool ~net name args =
  match name with
  | "lodge_heartbeat" -> heartbeat ~net args
  | "lodge_classify" -> classify ~net args
  | "lodge_react" -> react ~net args
  | "lodge_cycle" -> full_cycle ~net args
  | "lodge_discussion" -> lodge_discussion ~net args
  | "lodge_orchestrate" -> lodge_orchestrate ~net args
  | "lodge_auto_chain" -> lodge_auto_chain ~net args
  | "lodge_evolve" -> evolve ~net args
  | "lodge_spawn" -> spawn ~net args
  | "lodge_agents" -> list_agents ~net args
  | "lodge_agent_patrol" -> agent_patrol ~net args
  (* Project collaboration *)
  | "lodge_propose_project" -> propose_project ~net args
  | "lodge_join_project" -> join_project ~net args
  | "lodge_share_code" -> share_code ~net args
  | "lodge_research" -> research ~net args
  | "lodge_profile" -> get_profile ~net args
  | "lodge_autonomous_loop" -> autonomous_loop ~net args
  (* New: Search, Like, Progress *)
  | "lodge_search" -> lodge_search ~net args
  | "lodge_comment_like" -> lodge_comment_like ~net args
  | "lodge_progress" -> lodge_progress ~net args
  | _ -> (false, Printf.sprintf "Unknown lodge tool: %s" name)
