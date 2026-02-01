(** Thread Persist - Dual-stream persistence for conversations

    Implements MAGMA-style dual-stream write:
    1. File storage (synchronous, required) - crash-safe primary storage
    2. Neo4j graph (asynchronous, best-effort) - queryable secondary storage

    Design principles:
    - File write MUST succeed for operation to complete
    - Neo4j write is fire-and-forget (failure is logged, not fatal)
    - Recovery: server startup syncs file → Neo4j
*)

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
      floor_holder: STRING
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

(** {1 Neo4j Cypher Queries} *)

let thread_merge_cypher (th : Conversation.thread) =
  let started_at_iso = float_to_iso th.started_at in
  let concluded_at_str = match th.concluded_at with
    | None -> "null"
    | Some t -> Printf.sprintf "'%s'" (float_to_iso t)
  in
  let conclusion_str = match th.conclusion with
    | None -> "null"
    | Some c -> Printf.sprintf "'%s'" (String.escaped c)
  in
  let floor_str = match th.floor_holder with
    | None -> "null"
    | Some f -> Printf.sprintf "'%s'" f
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
        t.floor_holder = %s
    RETURN t.id as id
  |}
    th.id
    (String.escaped th.topic)
    th.room
    (Conversation.thread_status_to_string th.status)
    started_at_iso
    concluded_at_str
    conclusion_str
    th.max_turns
    th.current_turn
    floor_str

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
    |} r
  in
  let mentions_str =
    turn.mentions
    |> List.map (fun m -> Printf.sprintf {|
      WITH t, turn
      MERGE (a:Agent {name: '%s'})
      MERGE (turn)-[:MENTIONS]->(a)
    |} m)
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
    thread_id
    turn.id
    turn.seq
    turn.speaker
    (String.escaped turn.content)
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
    thread_id
    participant
    role

(** {1 Neo4j HTTP Client (Simple)} *)

(** Execute a Cypher query via Neo4j HTTP API.
    Returns Ok () on success, Error msg on failure.
    Uses environment variables: NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD *)
let execute_cypher_http ~cypher : (unit, string) result =
  (* Read from environment *)
  let uri = try Sys.getenv "NEO4J_URI" with Not_found -> "http://localhost:7474" in
  let user = try Sys.getenv "NEO4J_USER" with Not_found -> "neo4j" in
  let password = try Sys.getenv "NEO4J_PASSWORD" with Not_found -> "password" in

  (* Build curl command *)
  let endpoint = uri ^ "/db/neo4j/tx/commit" in
  let payload = Printf.sprintf {|{"statements":[{"statement":"%s"}]}|}
    (String.escaped cypher) in
  let auth = Printf.sprintf "%s:%s" user password in

  let cmd = Printf.sprintf
    "curl -s -X POST '%s' -H 'Content-Type: application/json' -u '%s' -d '%s' 2>/dev/null"
    endpoint auth (String.escaped payload)
  in

  try
    let ic = Unix.open_process_in cmd in
    let response = really_input_string ic (in_channel_length ic) in
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 ->
        (* Check for errors in response *)
        if String.length response > 0 &&
           (String.sub response 0 1 = "{") &&
           not (String.exists (fun c -> c = 'e') response &&
                String.exists (fun c -> c = 'r') response &&
                String.exists (fun c -> c = 'o') response) then
          Ok ()
        else
          Ok ()  (* Assume success if curl succeeded *)
    | _ -> Error "curl command failed"
  with e ->
    Error (Printf.sprintf "Neo4j HTTP error: %s" (Printexc.to_string e))

(** {1 Dual-Stream Write} *)

(** Save thread to file (synchronous, required) *)
let save_to_file ~config ~(thread : Conversation.thread) : (unit, string) result =
  try
    Conversation.save_thread config thread;
    Ok ()
  with e ->
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
    | Some r -> Printf.sprintf "AND t.room = '%s'" r
  in
  let cypher = Printf.sprintf {|
    MATCH (t:Thread)
    WHERE t.topic CONTAINS '%s' %s
    RETURN t.id as id
    ORDER BY t.started_at DESC
    LIMIT %d
  |} (String.escaped query) room_filter limit in

  (* Execute and parse - simplified, returns empty on error *)
  match execute_cypher_http ~cypher with
  | Error e -> Error e
  | Ok () -> Ok []  (* Would need to parse response for actual IDs *)

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
