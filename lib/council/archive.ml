(** Jiphyeon Archive - 실록 (Record System)

    MASC 에이전트 활동 기록 시스템.
    Neo4j 그래프 DB + PostgreSQL 관계형 DB 이중 저장.

    환경변수:
    - RAILWAY_NEO4J_URL: Neo4j Bolt URL (bolt://...)
    - DATABASE_URL: PostgreSQL 연결 문자열

    @since MASC v3.0
*)



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
  Sys.getenv_opt "DATABASE_URL"

(** {1 Neo4j Operations} *)

(** Neo4j HTTP API 응답 *)
type neo4j_response = {
  success: bool;
  error: string option;
}

(** Neo4j HTTP 트랜잭션 엔드포인트 URL 변환
    bolt://host:port -> http://host:7474/db/neo4j/tx/commit *)
let neo4j_http_url bolt_url =
  (* bolt://user:pass@host:port -> http://host:7474 *)
  let uri = Uri.of_string bolt_url in
  let host = Uri.host uri |> Option.value ~default:"localhost" in
  let http_port = 7474 in  (* Neo4j HTTP default *)
  Printf.sprintf "http://%s:%d/db/neo4j/tx/commit" host http_port

(** Neo4j 인증 헤더 추출 *)
let neo4j_auth_header bolt_url =
  let uri = Uri.of_string bolt_url in
  match Uri.user uri, Uri.password uri with
  | Some user, Some pass ->
    let creds = Base64.encode_exn (user ^ ":" ^ pass) in
    Some ("Authorization", "Basic " ^ creds)
  | _ -> None

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

(** PostgreSQL 연결 풀 *)
let pg_pool_ref : (Caqti_eio.connection, Caqti_error.t) Caqti_eio.Pool.t option ref = ref None

let get_pg_pool ~sw ~env =
  match !pg_pool_ref with
  | Some pool -> Ok pool
  | None ->
    match get_postgres_url () with
    | None -> Error "DATABASE_URL not set"
    | Some url ->
      let pool_config = Caqti_pool_config.create ~max_size:3 () in
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
