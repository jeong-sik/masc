(** Thread Persist - Dual-stream persistence for conversations

    Implements MAGMA-style dual-stream write:
    1. File storage (synchronous, required) - crash-safe primary storage
    2. Neo4j graph (asynchronous, best-effort) - queryable secondary storage

    Design principles:
    - File write MUST succeed for operation to complete
    - Neo4j write is fire-and-forget (failure is logged, not fatal)
    - Recovery: server startup syncs file → Neo4j
*)

open Result_syntax

(** {1 Types} *)

type persist_result = {
  file_ok: bool;
  neo4j_ok: bool;
  error: string option;
}

(** {1 Timestamp utilities (local copy to avoid circular dep)} *)

let now_iso () =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let float_to_iso (t : float) =
  let open Unix in
  let tm = gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

(** {1 Neo4j Schema}

    CREATE INDEX thread_id IF NOT EXISTS FOR (t:Thread) ON (t.id);
    CREATE INDEX thread_room IF NOT EXISTS FOR (t:Thread) ON (t.room);
    CREATE INDEX turn_id IF NOT EXISTS FOR (n:Turn) ON (n.id);

    (:Thread {
      id: STRING,
      topic: STRING,
      room: STRING,
      status: STRING,
      started_at: DATETIME,
      concluded_at: DATETIME,
      conclusion: STRING,
      max_turns: INT,
      current_turn: INT,
      floor_holder: STRING,
      source_post_id: STRING
    })

    (:Turn {
      id: STRING,
      seq: INT,
      speaker: STRING,
      content: STRING,
      turn_type: STRING,
      created_at: DATETIME,
      confidence: FLOAT
    })

    (:Turn)-[:BELONGS_TO]->(:Thread)
    (:Turn)-[:REPLIED_TO]->(:Turn)
    (:Turn)-[:MENTIONS]->(:Agent)
    (:Agent)-[:PARTICIPATED_IN {role: STRING, joined_at: DATETIME}]->(:Thread)
*)

(** {1 Cypher Helpers} *)

(** Escape a string for safe inclusion in Cypher queries.
    Handles single quotes and backslashes. *)
let cypher_escape s =
  s
  |> String.split_on_char '\\'
  |> String.concat "\\\\"
  |> String.split_on_char '\''
  |> String.concat "\\'"

(** {1 Neo4j Cypher Queries} *)

let thread_merge_cypher (th : Conversation.thread) =
  let started_at_iso = float_to_iso th.started_at in
  let concluded_at_str = match th.concluded_at with
    | None -> "null"
    | Some t -> Printf.sprintf "datetime('%s')" (float_to_iso t)
  in
  let conclusion_str = match th.conclusion with
    | None -> "null"
    | Some c -> Printf.sprintf "'%s'" (cypher_escape c)
  in
  let floor_str = match th.floor_holder with
    | None -> "null"
    | Some f -> Printf.sprintf "'%s'" (cypher_escape f)
  in
  let source_post_str = match th.source_post_id with
    | None -> "null"
    | Some pid -> Printf.sprintf "'%s'" (cypher_escape pid)
  in
  Printf.sprintf {|
    MERGE (t:Thread {id: '%s'})
    SET t.topic = '%s',
        t.room = '%s',
        t.status = '%s',
        t.started_at = datetime('%s'),
        t.concluded_at = %s,
        t.conclusion = %s,
        t.max_turns = %d,
        t.current_turn = %d,
        t.floor_holder = %s,
        t.source_post_id = %s
    RETURN t.id as id
  |}
    (cypher_escape th.id)
    (cypher_escape th.topic)
    (cypher_escape th.room)
    (Conversation.thread_status_to_string th.status)
    started_at_iso
    concluded_at_str
    conclusion_str
    th.max_turns
    th.current_turn
    floor_str
    source_post_str

let turn_merge_cypher ~thread_id (turn : Conversation.turn) =
  let created_at_iso = float_to_iso turn.created_at in
  let confidence_str = match turn.confidence with
    | None -> "null"
    | Some c -> Printf.sprintf "%f" c
  in
  let reply_to_str = match turn.reply_to with
    | None -> ""
    | Some r -> Printf.sprintf {|
      WITH t, turn
      MATCH (replied:Turn {id: '%s'})
      MERGE (turn)-[:REPLIED_TO]->(replied)
    |} (cypher_escape r)
  in
  let mentions_str =
    turn.mentions
    |> List.map (fun m -> Printf.sprintf {|
      WITH t, turn
      MERGE (a:Agent {name: '%s'})
      MERGE (turn)-[:MENTIONS]->(a)
    |} (cypher_escape m))
    |> String.concat "\n"
  in
  Printf.sprintf {|
    MATCH (t:Thread {id: '%s'})
    MERGE (turn:Turn {id: '%s'})
    SET turn.seq = %d,
        turn.speaker = '%s',
        turn.content = '%s',
        turn.turn_type = '%s',
        turn.created_at = datetime('%s'),
        turn.confidence = %s
    MERGE (turn)-[:BELONGS_TO]->(t)
    %s
    %s
    RETURN turn.id as id
  |}
    (cypher_escape thread_id)
    (cypher_escape turn.id)
    turn.seq
    (cypher_escape turn.speaker)
    (cypher_escape turn.content)
    (Conversation.turn_type_to_string turn.turn_type)
    created_at_iso
    confidence_str
    reply_to_str
    mentions_str

let participant_merge_cypher ~thread_id ~participant ~role =
  Printf.sprintf {|
    MATCH (t:Thread {id: '%s'})
    MERGE (a:Agent {name: '%s'})
    MERGE (a)-[r:PARTICIPATED_IN]->(t)
    SET r.role = '%s',
        r.joined_at = datetime()
    RETURN a.name as agent
  |}
    (cypher_escape thread_id)
    (cypher_escape participant)
    (cypher_escape role)

(** {1 Neo4j HTTP Client} *)

type eio_net = [`Generic] Eio.Net.ty Eio.Resource.t
type eio_clock = float Eio.Time.clock_ty Eio.Resource.t

type https_connector =
  | Https_connector :
      (Uri.t ->
       [ `Generic ] Eio.Net.stream_socket_ty Eio.Resource.t ->
       [> Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
      -> https_connector

type eio_context = {
  net : eio_net;
  clock : eio_clock option;
  https_connector : https_connector option;
}

let current_eio_context : eio_context option ref = ref None

let set_eio_context ?clock ?https_connector (net : _ Eio.Net.t) =
  current_eio_context :=
    Some
      {
        net = (net :> eio_net);
        clock;
        https_connector =
          Option.map (fun connector -> Https_connector connector)
            https_connector;
      }

let clear_eio_context () =
  current_eio_context := None

let truncate_for_log s =
  let max_len = 500 in
  if String.length s <= max_len then s else String.sub s 0 max_len ^ "..."

(** Check if host refers to the local machine. Covers 127.0.0.0/8, not just 127.0.0.1. *)
let looks_like_localhost host =
  host = "localhost"
  || host = "::1"
  || String.length host >= 4 && String.sub host 0 4 = "127."

let neo4j_http_base_uri () : (Uri.t, string) result =
  (* Prefer explicit HTTP URI if provided to avoid bolt/http port mismatches. *)
  match Sys.getenv_opt "NEO4J_HTTP_URI" with
  | Some uri_str when String.trim uri_str <> "" ->
      Ok (Uri.of_string uri_str)
  | _ ->
      let uri_str =
        Sys.getenv_opt "NEO4J_URI" |> Option.value ~default:"http://localhost:7474"
      in
      let uri = Uri.of_string uri_str in
      match Uri.scheme uri with
      | Some ("http" | "https") -> Ok uri
      | Some scheme
        when String.length scheme >= 4
             && (String.sub scheme 0 4 = "bolt" || String.sub scheme 0 4 = "neo4") ->
          let host = Uri.host uri |> Option.value ~default:"localhost" in
          let is_secure =
            (* e.g. bolt+s / neo4j+s / neo4j+ssc *)
            String.contains scheme '+'
          in
          let scheme = if is_secure then "https" else "http" in
          let port =
            (* Local Neo4j uses dedicated HTTP ports (7474/7473), not the bolt port. *)
            if looks_like_localhost host then (if is_secure then 7473 else 7474)
            else Uri.port uri |> Option.value ~default:(if is_secure then 7473 else 7474)
          in
          Ok (Uri.make ~scheme ~host ~port ())
      | Some other ->
          Error (Printf.sprintf "Unsupported NEO4J_URI scheme for HTTP API: %s" other)
      | None ->
          Error "NEO4J_URI missing scheme"

let neo4j_tx_commit_uri () : (Uri.t, string) result =
  match neo4j_http_base_uri () with
  | Error _ as e -> e
  | Ok base ->
      let base_str = Uri.to_string base in
      let base_str =
        if String.length base_str > 0 && base_str.[String.length base_str - 1] = '/'
        then String.sub base_str 0 (String.length base_str - 1)
        else base_str
      in
      Ok (Uri.of_string (base_str ^ "/db/neo4j/tx/commit"))

let neo4j_auth_header () : (string * string, string) result =
  let user = Sys.getenv_opt "NEO4J_USER" |> Option.value ~default:"neo4j" in
  let password = Sys.getenv_opt "NEO4J_PASSWORD" |> Option.value ~default:"" in
  if String.trim password = "" then
    Error "NEO4J_PASSWORD not set (Neo4j persistence disabled)"
  else
    let creds = Base64.encode_exn (user ^ ":" ^ password) in
    Ok ("Authorization", "Basic " ^ creds)

(** Execute a Cypher query via Neo4j HTTP API.
    Returns Ok json_response on success, Error msg on failure.
    Uses environment variables: NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD *)
let execute_cypher_raw ~cypher : (Yojson.Safe.t, string) result =
  match !current_eio_context with
  | None ->
      Error "Eio net not initialized (Neo4j persistence disabled)"
  | Some ctx ->
      let net = ctx.net in
      let* endpoint_uri = neo4j_tx_commit_uri () in
      let* auth_header = neo4j_auth_header () in

      (* Build JSON payload using Yojson to avoid injection *)
      let payload =
        Yojson.Safe.to_string
          (`Assoc
            [
              ( "statements",
                `List [ `Assoc [ ("statement", `String cypher) ] ] );
            ])
      in

      let timeout_sec = 10.0 in
      let max_response_bytes = 1_000_000 in

      let run () =
        Eio.Switch.run (fun sw ->
          let client =
            if Uri.scheme endpoint_uri <> Some "https" then
              Masc_http_client.make_closing_client ~sw ~net ~https:None
            else
              match ctx.https_connector with
              | Some (Https_connector c) ->
                  Masc_http_client.make_closing_client ~sw ~net ~https:(Some c)
              | None ->
                  failwith "HTTPS requested but no https_connector provided to eio_context"
          in
          let headers =
            Cohttp.Header.of_list
              [ ("Content-Type", "application/json"); auth_header ]
          in
          let body_content = Eio.Flow.string_source payload in
          let resp, resp_body =
            Cohttp_eio.Client.post client ~sw endpoint_uri ~headers
              ~body:body_content
          in
          let status_code =
            Cohttp.Response.status resp |> Cohttp.Code.code_of_status
          in
          let response =
            Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_response_bytes
          in
          if String.length response = 0 then Error "Neo4j: empty response"
          else if not (Cohttp.Code.is_success status_code) then
            Error
              (Printf.sprintf "Neo4j HTTP %d: %s" status_code
                 (truncate_for_log response))
          else
            try
              let json = Yojson.Safe.from_string response in
              let open Yojson.Safe.Util in
              let errors = json |> member "errors" |> to_list in
              if errors = [] then Ok json
              else
                let err_msg =
                  errors
                  |> List.map (fun e ->
                         e |> member "message" |> to_string_option
                         |> Option.value ~default:"unknown")
                  |> String.concat "; "
                in
                Error (Printf.sprintf "Neo4j error: %s" err_msg)
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | e ->
              Error
                (Printf.sprintf "Neo4j response parse error: %s"
                   (Printexc.to_string e)))
      in

      (match ctx.clock with
      | Some clock -> (
          try Eio.Time.with_timeout_exn clock timeout_sec run
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Eio.Time.Timeout -> Error "Neo4j HTTP timeout"
          | exn -> Error (Printexc.to_string exn))
      | None -> (
          try run ()
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (Printexc.to_string exn)))

(** Execute a Cypher query, ignoring the response data.
    Returns Ok () on success, Error msg on failure. *)
let execute_cypher_http ~cypher : (unit, string) result =
  match execute_cypher_raw ~cypher with
  | Ok _ -> Ok ()
  | Error e -> Error e

(** {1 Dual-Stream Write} *)

(** Save thread to file (synchronous, required) *)
let save_to_file ~config ~(thread : Conversation.thread) : (unit, string) result =
  try
    Conversation.save_thread config thread;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
    Error (Printf.sprintf "File write failed: %s" (Printexc.to_string e))

(** Save thread to Neo4j (fire-and-forget, best-effort) *)
let save_to_neo4j_sync ~(thread : Conversation.thread) : bool =
  (* Save thread node *)
  let thread_cypher = thread_merge_cypher thread in
  match execute_cypher_http ~cypher:thread_cypher with
  | Error _ -> false
  | Ok () ->
      (* Save all turns *)
      let turns_ok = List.for_all (fun turn ->
        let turn_cypher = turn_merge_cypher ~thread_id:thread.id turn in
        match execute_cypher_http ~cypher:turn_cypher with
        | Ok () -> true
        | Error _ -> false
      ) thread.turns in

      (* Save participant relationships *)
      let participants_ok = List.for_all (fun participant ->
        let role = if participant = (match thread.floor_holder with Some f -> f | None -> "")
                   then "initiator" else "participant" in
        let part_cypher = participant_merge_cypher ~thread_id:thread.id ~participant ~role in
        match execute_cypher_http ~cypher:part_cypher with
        | Ok () -> true
        | Error _ -> false
      ) thread.participants in

      turns_ok && participants_ok

(** Main save function - dual-stream write *)
let save_thread ~config ~(thread : Conversation.thread) : persist_result =
  (* 1. File write (synchronous, required) *)
  match save_to_file ~config ~thread with
  | Error e ->
      { file_ok = false; neo4j_ok = false; error = Some e }
  | Ok () ->
      (* 2. Neo4j write (best-effort) *)
      let neo4j_ok = save_to_neo4j_sync ~thread in
      { file_ok = true; neo4j_ok; error = None }

(** {1 Load Operations} *)

(** Load thread - file is primary, Neo4j is not used for load *)
let load_thread ~config ~thread_id : Conversation.thread option =
  Conversation.get ~config ~thread_id

(** {1 Search Operations (Neo4j)} *)

(** Search threads by topic keyword *)
let search_by_topic ~(query : string) ?(room : string option) ?(limit = 10) ()
    : (string list, string) result =
  let room_filter = match room with
    | None -> ""
    | Some r -> Printf.sprintf "AND t.room = '%s'" (cypher_escape r)
  in
  let cypher = Printf.sprintf {|
    MATCH (t:Thread)
    WHERE t.topic CONTAINS '%s' %s
    RETURN t.id as id
    ORDER BY t.started_at DESC
    LIMIT %d
  |} (cypher_escape query) room_filter limit in

  match execute_cypher_raw ~cypher with
  | Error e -> Error e
  | Ok json ->
      (try
        let open Yojson.Safe.Util in
        let results = json |> member "results" |> to_list in
        let ids = match results with
          | [] -> []
          | first :: _ ->
              first |> member "data" |> to_list
              |> List.filter_map (fun row ->
                  try
                    match row |> member "row" |> to_list with
                    | h :: _ -> Some (h |> to_string)
                    | [] -> None
                  with Yojson.Safe.Util.Type_error _ -> None)
        in
        Ok ids
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | e ->
        Error (Printf.sprintf "Failed to parse search results: %s" (Printexc.to_string e)))

(** {1 Sync Operations} *)

(** Sync all file-based threads to Neo4j.
    Called on server startup to ensure consistency. *)
let sync_all ~config : (int, string) result =
  let threads = Conversation.list_all ~config in
  let synced = List.fold_left (fun count th ->
    if save_to_neo4j_sync ~thread:th then count + 1 else count
  ) 0 threads in
  Ok synced

(** {1 Index Creation} *)

(** Create Neo4j indexes (run once on setup) *)
let create_indexes () : (unit, string) result =
  let indexes = [
    "CREATE INDEX thread_id IF NOT EXISTS FOR (t:Thread) ON (t.id)";
    "CREATE INDEX thread_room IF NOT EXISTS FOR (t:Thread) ON (t.room)";
    "CREATE INDEX turn_id IF NOT EXISTS FOR (n:Turn) ON (n.id)";
  ] in
  let results = List.map (fun cypher -> execute_cypher_http ~cypher) indexes in
  if List.for_all Result.is_ok results then Ok ()
  else Error "Some indexes failed to create"
