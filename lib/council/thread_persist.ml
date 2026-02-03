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

(** Read all bytes from an input channel (pipe-safe, does NOT use in_channel_length). *)
let read_all_from_ic ic =
  let buf = Buffer.create 4096 in
  (try while true do
    Buffer.add_char buf (input_char ic)
  done with End_of_file -> ());
  Buffer.contents buf

(** Execute a Cypher query via Neo4j HTTP API.
    Returns Ok json_response on success, Error msg on failure.
    Uses environment variables: NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD *)
let execute_cypher_raw ~cypher : (Yojson.Safe.t, string) result =
  let uri = match Sys.getenv_opt "NEO4J_URI" with Some v -> v | None -> "http://localhost:7474" in
  let user = match Sys.getenv_opt "NEO4J_USER" with Some v -> v | None -> "neo4j" in
  let password = match Sys.getenv_opt "NEO4J_PASSWORD" with Some v -> v | None -> "password" in

  let endpoint = uri ^ "/db/neo4j/tx/commit" in
  (* Build JSON payload using Yojson to avoid injection *)
  let payload = Yojson.Safe.to_string (`Assoc [
    ("statements", `List [
      `Assoc [("statement", `String cypher)]
    ])
  ]) in

  (* Write payload to temp file to avoid shell escaping issues *)
  let tmp_file = Filename.temp_file "neo4j_" ".json" in
  Fun.protect ~finally:(fun () ->
    try Sys.remove tmp_file with _ -> ()
  ) (fun () ->
    let oc = open_out tmp_file in
    output_string oc payload;
    close_out oc;

    let cmd = Printf.sprintf
      "curl -s --max-time 10 -X POST '%s' -H 'Content-Type: application/json' -u '%s:%s' -d @'%s' 2>/dev/null"
      endpoint user password tmp_file
    in
    let ic = Unix.open_process_in cmd in
    let response = try read_all_from_ic ic with Sys_error _ -> "" in
    let status = Unix.close_process_in ic in
    match status with
    | Unix.WEXITED 0 ->
        (try
          let json = Yojson.Safe.from_string response in
          let open Yojson.Safe.Util in
          let errors = json |> member "errors" |> to_list in
          if errors = [] then Ok json
          else
            let err_msg = errors
              |> List.map (fun e -> e |> member "message" |> to_string_option |> Option.value ~default:"unknown")
              |> String.concat "; "
            in
            Error (Printf.sprintf "Neo4j error: %s" err_msg)
        with e ->
          if String.length response = 0 then
            Error "Neo4j: empty response (server unreachable?)"
          else
            Error (Printf.sprintf "Neo4j response parse error: %s" (Printexc.to_string e)))
    | Unix.WEXITED code ->
        Error (Printf.sprintf "curl exited with code %d" code)
    | _ -> Error "curl command terminated abnormally"
  )

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
                  try Some (row |> member "row" |> to_list |> List.hd |> to_string)
                  with _ -> None)
        in
        Ok ids
      with e ->
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
