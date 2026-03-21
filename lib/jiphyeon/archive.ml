(** Jiphyeon Archive - 실록 (Record System)

    MASC 에이전트 활동 기록 시스템.
    Neo4j 그래프 DB + PostgreSQL 관계형 DB 이중 저장.

    환경변수:
    - RAILWAY_NEO4J_URL: Neo4j Bolt URL (bolt://...)
    - DATABASE_URL: PostgreSQL 연결 문자열

    @since MASC v3.0
*)

(* Eio used for async operations in store functions *)

(** {1 Types} *)

(** 기록 타입 *)
type record_type =
  | Debate    (** 토론 기록 *)
  | Vote      (** 투표 기록 *)
  | Decision  (** 의사결정 기록 *)
  | Post      (** 게시글 기록 *)
[@@deriving show { with_path = false }]

let record_type_to_string = function
  | Debate   -> "debate"
  | Vote     -> "vote"
  | Decision -> "decision"
  | Post     -> "post"

let record_type_of_string = function
  | "debate"   -> Ok Debate
  | "vote"     -> Ok Vote
  | "decision" -> Ok Decision
  | "post"     -> Ok Post
  | s          -> Error (Printf.sprintf "Unknown record_type: %s" s)

(** 기록 레코드 *)
type record = {
  id: string;                    (** UUID *)
  type_: record_type;            (** 기록 타입 *)
  content: string;               (** 본문 *)
  agents: string list;           (** 참여 에이전트들 *)
  timestamp: string;             (** ISO8601 타임스탬프 *)
  metadata: (string * string) list;  (** 키-값 메타데이터 *)
}
[@@deriving show { with_path = false }]

(** {2 JSON Serialization} *)

let record_to_yojson r =
  `Assoc [
    ("id", `String r.id);
    ("type", `String (record_type_to_string r.type_));
    ("content", `String r.content);
    ("agents", `List (List.map (fun a -> `String a) r.agents));
    ("timestamp", `String r.timestamp);
    ("metadata", `Assoc (List.map (fun (k, v) -> (k, `String v)) r.metadata));
  ]

let record_of_yojson json =
  let open Yojson.Safe.Util in
  try
    let id = json |> member "id" |> to_string in
    let type_str = json |> member "type" |> to_string in
    let type_ = match record_type_of_string type_str with
      | Ok t -> t
      | Error _ -> Debate  (* default *)
    in
    let content = json |> member "content" |> to_string in
    let agents = json |> member "agents" |> to_list |> List.map to_string in
    let timestamp = json |> member "timestamp" |> to_string in
    let metadata = json |> member "metadata" |> to_assoc
      |> List.map (fun (k, v) -> (k, to_string v)) in
    Ok { id; type_; content; agents; timestamp; metadata }
  with e ->
    Error (Printf.sprintf "JSON parse error: %s" (Printexc.to_string e))

(** {1 Utilities} *)

let generate_id () =
  Uuidm.(to_string (v4_gen (Random.State.make_self_init ()) ()))

let now_iso () =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** 환경변수에서 URL 읽기 *)
let get_neo4j_url () =
  Sys.getenv_opt "RAILWAY_NEO4J_URL"

let get_postgres_url () =
  (* Try multiple env vars: DATABASE_URL, SUPABASE_DB_URL, SB_PG_URL *)
  match Sys.getenv_opt "DATABASE_URL" with
  | Some url -> Some url
  | None -> match Sys.getenv_opt "SUPABASE_DB_URL" with
    | Some url -> Some url
    | None -> Sys.getenv_opt "SB_PG_URL"

(** {1 Neo4j Operations} *)

(** Neo4j HTTP API 응답 *)
type neo4j_response = {
  success: bool;
  error: string option;
}

(** Neo4j HTTP 트랜잭션 엔드포인트 URL 변환
    bolt://host:port -> http://host:port/db/neo4j/tx/commit
    Railway Neo4j: same port for HTTP API via proxy *)
let neo4j_http_url bolt_url =
  (* Parse: bolt://user:pass@host:port OR host:port *)
  let url = if String.sub bolt_url 0 4 = "bolt" then bolt_url else "bolt://" ^ bolt_url in
  let uri = Uri.of_string url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let port = Uri.port uri |> Option.value ~default:7687 in
  (* Railway uses HTTP on same port via proxy *)
  Printf.sprintf "http://%s:%d/db/neo4j/tx/commit" host port

(** Neo4j 인증 헤더 추출 - fallback to env vars *)
let neo4j_auth_header bolt_url =
  let url = if String.sub bolt_url 0 4 = "bolt" then bolt_url else "bolt://" ^ bolt_url in
  let uri = Uri.of_string url in
  (* Try URL credentials first, then env vars *)
  let user, pass = match Uri.user uri, Uri.password uri with
    | Some u, Some p -> (u, p)
    | _ ->
      let env_user = Sys.getenv_opt "NEO4J_USER" |> Option.value ~default:"neo4j" in
      let env_pass = Sys.getenv_opt "NEO4J_PASSWORD" |> Option.value ~default:"" in
      (env_user, env_pass)
  in
  if pass = "" then None
  else
    let creds = Base64.encode_exn (user ^ ":" ^ pass) in
    Some ("Authorization", "Basic " ^ creds)

(** Cypher 쿼리 실행 (HTTP API) *)
let execute_cypher ~sw ~env bolt_url query params =
  let http_url = neo4j_http_url bolt_url in
  let body = Yojson.Safe.to_string (`Assoc [
    ("statements", `List [
      `Assoc [
        ("statement", `String query);
        ("parameters", params);
      ]
    ])
  ]) in
  let headers = [("Content-Type", "application/json")] in
  let headers = match neo4j_auth_header bolt_url with
    | Some h -> h :: headers
    | None -> headers
  in
  try
    let client = Cohttp_eio.Client.make ~https:None env#net in
    let uri = Uri.of_string http_url in
    let body_content = Eio.Flow.string_source body in
    let resp, resp_body = Cohttp_eio.Client.post client ~sw uri
      ~headers:(Cohttp.Header.of_list headers)
      ~body:body_content
    in
    let status = Cohttp.Response.status resp in
    let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_int in
    if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
      Ok body_str
    else
      Error (Printf.sprintf "Neo4j HTTP error: %s" body_str)
  with e ->
    Error (Printf.sprintf "Neo4j connection error: %s" (Printexc.to_string e))

(** Neo4j에 레코드 저장 (MERGE) *)
let save_to_neo4j ~sw ~env (r : record) : (unit, string) result =
  match get_neo4j_url () with
  | None -> Error "RAILWAY_NEO4J_URL not set"
  | Some bolt_url ->
    let query = {|
      MERGE (rec:Record {id: $id})
      SET rec.type = $type,
          rec.content = $content,
          rec.timestamp = $timestamp,
          rec.metadata = $metadata
      WITH rec
      UNWIND $agents AS agent_name
      MERGE (a:Agent {name: agent_name})
      MERGE (a)-[:PARTICIPATED_IN]->(rec)
      RETURN rec.id
    |} in
    let params = `Assoc [
      ("id", `String r.id);
      ("type", `String (record_type_to_string r.type_));
      ("content", `String r.content);
      ("timestamp", `String r.timestamp);
      ("metadata", `String (Yojson.Safe.to_string
        (`Assoc (List.map (fun (k, v) -> (k, `String v)) r.metadata))));
      ("agents", `List (List.map (fun a -> `String a) r.agents));
    ] in
    match execute_cypher ~sw ~env bolt_url query params with
    | Ok _ -> Ok ()
    | Error e -> Error e

(** {1 PostgreSQL Operations} *)

(** Caqti 쿼리 정의 *)
module Q = struct
  open Caqti_request.Infix
  open Caqti_type

  (** 테이블 생성 *)
  let create_table =
    (unit ->. unit) {|
      CREATE TABLE IF NOT EXISTS jiphyeon_records (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        content TEXT NOT NULL,
        agents TEXT[] NOT NULL,
        timestamp TIMESTAMPTZ NOT NULL,
        metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
        created_at TIMESTAMPTZ DEFAULT NOW()
      )
    |}

  (** 레코드 삽입/업데이트 *)
  let upsert_record =
    (t2 (t3 string string string) (t3 string string string) ->. unit) {|
      INSERT INTO jiphyeon_records (id, type, content, agents, timestamp, metadata)
      VALUES ($1, $2, $3, string_to_array($4, ','), $5::timestamptz, $6::jsonb)
      ON CONFLICT (id) DO UPDATE SET
        type = EXCLUDED.type,
        content = EXCLUDED.content,
        agents = EXCLUDED.agents,
        timestamp = EXCLUDED.timestamp,
        metadata = EXCLUDED.metadata
    |}

  (** 키워드 검색 *)
  let search_by_content =
    (string ->* t5 string string string string string)
    "SELECT id, type, content, array_to_string(agents, ','), timestamp::text \
     FROM jiphyeon_records WHERE content ILIKE '%' || $1 || '%' ORDER BY timestamp DESC LIMIT 100"

  (** 타입별 검색 *)
  let search_by_type =
    (string ->* t5 string string string string string)
    "SELECT id, type, content, array_to_string(agents, ','), timestamp::text \
     FROM jiphyeon_records WHERE type = $1 ORDER BY timestamp DESC LIMIT 100"

  (** 에이전트 히스토리 *)
  let get_agent_history =
    (string ->* t5 string string string string string)
    "SELECT id, type, content, array_to_string(agents, ','), timestamp::text \
     FROM jiphyeon_records WHERE $1 = ANY(agents) ORDER BY timestamp DESC LIMIT 100"
end

(** PostgreSQL 연결 풀 — shared pool 주입 우선, fallback으로 자체 생성 *)
let pg_pool_ref : (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t option ref = ref None
let shared_pool_ref : (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t option ref = ref None

let set_shared_pool pool =
  shared_pool_ref := Some pool

let has_shared_pool () = Option.is_some !shared_pool_ref

let get_pg_pool ~sw ~env =
  match !shared_pool_ref with
  | Some pool -> Ok pool
  | None ->
  match !pg_pool_ref with
  | Some pool -> Ok pool
  | None ->
    match get_postgres_url () with
    | None -> Error "DATABASE_URL not set"
    | Some url ->
      let pool_config = Caqti_pool_config.create ~max_size:10 () in
      match Caqti_eio_unix.connect_pool ~sw ~pool_config (Uri.of_string url) ~stdenv:env with
      | Ok pool ->
        pg_pool_ref := Some pool;
        Ok pool
      | Error e -> Error (Caqti_error.show e)

(** PostgreSQL에 레코드 저장 *)
let save_to_postgres ~sw ~env (r : record) : (unit, string) result =
  match get_pg_pool ~sw ~env with
  | Error e -> Error e
  | Ok pool ->
    let use_conn (module C : Caqti_eio.CONNECTION) =
      let agents_str = String.concat "," r.agents in
      let metadata_json = Yojson.Safe.to_string
        (`Assoc (List.map (fun (k, v) -> (k, `String v)) r.metadata)) in
      C.exec Q.upsert_record
        ((r.id, record_type_to_string r.type_, r.content), (agents_str, r.timestamp, metadata_json))
    in
    match Caqti_eio.Pool.use use_conn pool with
    | Ok () -> Ok ()
    | Error e -> Error (Caqti_error.show e)

(** 테이블 초기화 (마이그레이션) *)
let init_postgres ~sw ~env : (unit, string) result =
  match get_pg_pool ~sw ~env with
  | Error e -> Error e
  | Ok pool ->
    let use_conn (module C : Caqti_eio.CONNECTION) =
      C.exec Q.create_table ()
    in
    match Caqti_eio.Pool.use use_conn pool with
    | Ok () -> Ok ()
    | Error e -> Error (Caqti_error.show e)

(** {1 Search Operations} *)

(** 검색 옵션 *)
type search_filter =
  | ByContent of string   (** 본문 검색 *)
  | ByType of record_type (** 타입 필터 *)
  | ByAgent of string     (** 에이전트 필터 *)

(** 레코드 검색 *)
let search_records ~sw ~env (filter : search_filter) : (record list, string) result =
  match get_pg_pool ~sw ~env with
  | Error e -> Error e
  | Ok pool ->
    let use_conn (module C : Caqti_eio.CONNECTION) =
      let query_result = match filter with
        | ByContent q -> C.collect_list Q.search_by_content q
        | ByType t -> C.collect_list Q.search_by_type (record_type_to_string t)
        | ByAgent a -> C.collect_list Q.get_agent_history a
      in
      match query_result with
      | Ok rows ->
        Ok (List.map (fun (id, type_str, content, agents_str, ts) ->
          let type_ = match record_type_of_string type_str with
            | Ok t -> t | Error _ -> Debate in
          let agents = String.split_on_char ',' agents_str in
          { id; type_; content; agents; timestamp = ts; metadata = [] }
        ) rows)
      | Error e -> Error e
    in
    match Caqti_eio.Pool.use use_conn pool with
    | Ok records -> Ok records
    | Error e -> Error (Caqti_error.show e)

(** 에이전트 히스토리 조회 *)
let get_agent_history ~sw ~env (agent_name : string) : (record list, string) result =
  search_records ~sw ~env (ByAgent agent_name)

(** {1 Convenience Functions} *)

(** 새 레코드 생성 *)
let create_record ~type_ ~content ~agents ?(metadata=[]) () =
  {
    id = generate_id ();
    type_;
    content;
    agents;
    timestamp = now_iso ();
    metadata;
  }

(** 양쪽 DB에 저장 *)
let save ~sw ~env (r : record) : (unit, string) result =
  (* PostgreSQL 먼저 (주 저장소) *)
  match save_to_postgres ~sw ~env r with
  | Error e -> Error (Printf.sprintf "PostgreSQL: %s" e)
  | Ok () ->
    (* Neo4j는 best-effort *)
    match save_to_neo4j ~sw ~env r with
    | Ok () -> Ok ()
    | Error e ->
      (* Neo4j 실패해도 PostgreSQL 성공이면 경고만 *)
      Printf.eprintf "[WARN] Neo4j save failed: %s\n%!" e;
      Ok ()

(** {1 Episode Storage - Agent Being Protocol}

    에이전트를 "도구"가 아닌 "생명체"로 다루기 위한 Episode 저장.
    Stanford Generative Agents (2023)의 Memory Stream 패턴 구현.

    Episode는 에이전트의 경험 단위로, 세대 간 기억 계승의 핵심입니다.
*)

(** Episode 타입 - 에이전트 경험 단위 *)
type episode = {
  ep_id: string;                (** UUID *)
  session_id: string;           (** 세션 ID *)
  agent_name: string;           (** 에이전트 이름 *)
  generation: int;              (** 세대 번호 *)
  parent_episode: string option;(** 부모 에피소드 (계보) *)
  event_type: string;           (** 이벤트 타입: handoff, mitosis, task, reflection *)
  summary: string;              (** 경험 요약 *)
  dna: string option;           (** 압축된 컨텍스트 DNA *)
  outcome: [`Success | `Failure | `Partial];
  learnings: string list;       (** 학습 내용 *)
  context: (string * string) list; (** 추가 컨텍스트 *)
  timestamp: string;            (** ISO8601 *)
}

let outcome_to_str = function
  | `Success -> "success"
  | `Failure -> "failure"
  | `Partial -> "partial"

let outcome_of_str = function
  | "success" -> `Success
  | "failure" -> `Failure
  | _ -> `Partial

let episode_to_yojson e =
  `Assoc [
    ("ep_id", `String e.ep_id);
    ("session_id", `String e.session_id);
    ("agent_name", `String e.agent_name);
    ("generation", `Int e.generation);
    ("parent_episode", match e.parent_episode with Some p -> `String p | None -> `Null);
    ("event_type", `String e.event_type);
    ("summary", `String e.summary);
    ("dna", match e.dna with Some d -> `String d | None -> `Null);
    ("outcome", `String (outcome_to_str e.outcome));
    ("learnings", `List (List.map (fun l -> `String l) e.learnings));
    ("context", `Assoc (List.map (fun (k, v) -> (k, `String v)) e.context));
    ("timestamp", `String e.timestamp);
  ]

(** {2 PostgreSQL Episode Storage} *)

module EpisodeQ = struct
  open Caqti_request.Infix
  open Caqti_type

  let create_table =
    (unit ->. unit) {|
      CREATE TABLE IF NOT EXISTS masc_episodes (
        ep_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        agent_name TEXT NOT NULL,
        generation INT NOT NULL DEFAULT 0,
        parent_episode TEXT,
        event_type TEXT NOT NULL,
        summary TEXT NOT NULL,
        dna TEXT,
        outcome TEXT NOT NULL DEFAULT 'partial',
        learnings TEXT[] NOT NULL DEFAULT '{}',
        context JSONB NOT NULL DEFAULT '{}'::jsonb,
        timestamp TIMESTAMPTZ NOT NULL,
        created_at TIMESTAMPTZ DEFAULT NOW(),
        CONSTRAINT fk_parent FOREIGN KEY (parent_episode) REFERENCES masc_episodes(ep_id) ON DELETE SET NULL
      )
    |}

  let create_indexes =
    (unit ->. unit) {|
      CREATE INDEX IF NOT EXISTS idx_episodes_agent ON masc_episodes(agent_name);
      CREATE INDEX IF NOT EXISTS idx_episodes_session ON masc_episodes(session_id);
      CREATE INDEX IF NOT EXISTS idx_episodes_generation ON masc_episodes(generation);
      CREATE INDEX IF NOT EXISTS idx_episodes_timestamp ON masc_episodes(timestamp DESC);
    |}

  let upsert_episode =
    (t2
      (t4 string string string int)      (* ep_id, session_id, agent_name, generation *)
      (t4 string string string string)   (* parent_episode, event_type, summary, dna *)
    ->. unit) {|
      INSERT INTO masc_episodes
        (ep_id, session_id, agent_name, generation, parent_episode, event_type, summary, dna, outcome, learnings, context, timestamp)
      VALUES
        ($1, $2, $3, $4, NULLIF($5, ''), $6, $7, NULLIF($8, ''), 'partial', '{}', '{}'::jsonb, NOW())
      ON CONFLICT (ep_id) DO UPDATE SET
        summary = EXCLUDED.summary,
        dna = EXCLUDED.dna
    |}

  let get_lineage =
    (string ->* t4 string string int string)
    {|
      WITH RECURSIVE lineage AS (
        SELECT ep_id, agent_name, generation, summary, parent_episode
        FROM masc_episodes WHERE ep_id = $1
        UNION ALL
        SELECT e.ep_id, e.agent_name, e.generation, e.summary, e.parent_episode
        FROM masc_episodes e
        INNER JOIN lineage l ON e.ep_id = l.parent_episode
      )
      SELECT ep_id, agent_name, generation, summary FROM lineage ORDER BY generation ASC
    |}

  let get_recent_by_agent =
    (t2 string int ->* t4 string string int string)
    "SELECT ep_id, event_type, generation, summary FROM masc_episodes \
     WHERE agent_name = $1 ORDER BY timestamp DESC LIMIT $2"
end

(** Episode PostgreSQL 저장 *)
let save_episode_to_postgres ~sw ~env (ep : episode) : (unit, string) result =
  match get_pg_pool ~sw ~env with
  | Error e -> Error e
  | Ok pool ->
    let use_conn (module C : Caqti_eio.CONNECTION) =
      let parent = Option.value ep.parent_episode ~default:"" in
      let dna = Option.value ep.dna ~default:"" in
      C.exec EpisodeQ.upsert_episode
        ((ep.ep_id, ep.session_id, ep.agent_name, ep.generation),
         (parent, ep.event_type, ep.summary, dna))
    in
    match Caqti_eio.Pool.use use_conn pool with
    | Ok () -> Ok ()
    | Error e -> Error (Caqti_error.show e)

(** {2 Neo4j Episode Storage} *)

(** Neo4j Episode 노드 생성 - 그래프 관계 포함 *)
let save_episode_to_neo4j ~sw ~env (ep : episode) : (unit, string) result =
  match get_neo4j_url () with
  | None -> Error "RAILWAY_NEO4J_URL not set"
  | Some bolt_url ->
    (* Episode 노드 생성 + Agent 관계 + 부모-자식 관계 *)
    let query = {|
      // 1. Episode 노드 생성
      MERGE (e:Episode {id: $ep_id})
      SET e.session_id = $session_id,
          e.agent_name = $agent_name,
          e.generation = $generation,
          e.event_type = $event_type,
          e.summary = $summary,
          e.outcome = $outcome,
          e.timestamp = $timestamp,
          e.dna_size = $dna_size

      // 2. Agent 노드 연결
      MERGE (a:Agent {name: $agent_name})
      MERGE (a)-[:EXPERIENCED]->(e)

      // 3. 부모 Episode 관계 (있는 경우)
      WITH e
      OPTIONAL MATCH (parent:Episode {id: $parent_episode})
      FOREACH (_ IN CASE WHEN parent IS NOT NULL THEN [1] ELSE [] END |
        MERGE (e)-[:BORN_FROM]->(parent)
      )

      RETURN e.id
    |} in
    let dna_size = match ep.dna with Some d -> String.length d | None -> 0 in
    let params = `Assoc [
      ("ep_id", `String ep.ep_id);
      ("session_id", `String ep.session_id);
      ("agent_name", `String ep.agent_name);
      ("generation", `Int ep.generation);
      ("parent_episode", match ep.parent_episode with Some p -> `String p | None -> `Null);
      ("event_type", `String ep.event_type);
      ("summary", `String ep.summary);
      ("outcome", `String (outcome_to_str ep.outcome));
      ("timestamp", `String ep.timestamp);
      ("dna_size", `Int dna_size);
    ] in
    match execute_cypher ~sw ~env bolt_url query params with
    | Ok _ -> Ok ()
    | Error e -> Error e

(** {2 Episode Dual Storage} *)

(** Episode 이중 저장 (PostgreSQL 주, Neo4j 부) *)
let save_episode ~sw ~env (ep : episode) : (unit, string) result =
  (* PostgreSQL 먼저 (주 저장소, 실패 시 전체 실패) *)
  match save_episode_to_postgres ~sw ~env ep with
  | Error e -> Error (Printf.sprintf "PostgreSQL episode save failed: %s" e)
  | Ok () ->
    (* Neo4j는 best-effort (실패해도 경고만) *)
    match save_episode_to_neo4j ~sw ~env ep with
    | Ok () ->
      Printf.printf "[EPISODE] Saved episode %s (gen %d) to PG+Neo4j\n%!" ep.ep_id ep.generation;
      Ok ()
    | Error e ->
      Printf.eprintf "[WARN] Neo4j episode save failed (PG succeeded): %s\n%!" e;
      Ok ()

(** Episode 생성 헬퍼 *)
let create_episode
    ~session_id ~agent_name ~generation
    ?parent_episode ~event_type ~summary ?dna
    ?(outcome=`Partial) ?(learnings=[]) ?(context=[]) () =
  {
    ep_id = generate_id ();
    session_id;
    agent_name;
    generation;
    parent_episode;
    event_type;
    summary;
    dna;
    outcome;
    learnings;
    context;
    timestamp = now_iso ();
  }

(** Episode 테이블 초기화 *)
let init_episode_table ~sw ~env : (unit, string) result =
  match get_pg_pool ~sw ~env with
  | Error e -> Error e
  | Ok pool ->
    let use_conn (module C : Caqti_eio.CONNECTION) =
      match C.exec EpisodeQ.create_table () with
      | Error e -> Error e
      | Ok () -> C.exec EpisodeQ.create_indexes ()
    in
    match Caqti_eio.Pool.use use_conn pool with
    | Ok () -> Ok ()
    | Error e -> Error (Caqti_error.show e)

(** 에이전트 계보 조회 *)
let get_agent_lineage ~sw ~env (ep_id : string) : ((string * string * int * string) list, string) result =
  match get_pg_pool ~sw ~env with
  | Error e -> Error e
  | Ok pool ->
    let use_conn (module C : Caqti_eio.CONNECTION) =
      C.collect_list EpisodeQ.get_lineage ep_id
    in
    match Caqti_eio.Pool.use use_conn pool with
    | Ok lineage -> Ok lineage
    | Error e -> Error (Caqti_error.show e)

(** 에이전트의 최근 에피소드 조회 - Agent Being Protocol Phase 2 *)
let get_agent_episodes ~sw ~env (agent_name : string) (limit : int) : ((string * string * int * string) list, string) result =
  match get_pg_pool ~sw ~env with
  | Error e -> Error e
  | Ok pool ->
    let use_conn (module C : Caqti_eio.CONNECTION) =
      C.collect_list EpisodeQ.get_recent_by_agent (agent_name, limit)
    in
    match Caqti_eio.Pool.use use_conn pool with
    | Ok episodes -> Ok episodes
    | Error e -> Error (Caqti_error.show e)
