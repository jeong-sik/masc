(** Lodge Memory — Agent experience recall & store

    Combines multiple memory sources:
    - Council thread (short-term, per-agent conversation history)
    - Memory Stream (scored retrieval, long-term)
    - Neo4j graph (agent activity relationships)

    Self-contained: accesses Council.Conversation and Memory_stream directly
    to avoid circular dependency with Lodge_heartbeat.

    @since 3.0.0
*)

[@@@warning "-32"]

(** {1 Types} *)

type experience = {
  agent_name: string;
  action_type: string;        (** "post" | "comment" | "upvote" | "skip" *)
  content: string;
  context: string;            (** trigger/reason *)
  board_id: string option;
  timestamp: float;
}

(** {1 Non-blocking Shell Execution} *)

let run_shell_nonblocking cmd =
  Eio_unix.run_in_systhread (fun () ->
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 1024 in
    (try
      while true do
        Buffer.add_string buf (input_line ic);
        Buffer.add_char buf '\n'
      done
    with End_of_file -> ());
    let _ = Unix.close_process_in ic in
    Buffer.contents buf
  )

(** {1 Council Thread Access (direct, no Lodge_heartbeat dependency)} *)

let agent_thread_config () : Council.Conversation.config =
  let me_root = Sys.getenv_opt "ME_ROOT" |> Option.value ~default:"/Users/dancer/me" in
  { base_path = me_root; room = "lodge" }

let find_agent_thread ~agent_name : Council.Conversation.thread option =
  let config = agent_thread_config () in
  let threads = Council.Conversation.list_active ~config in
  List.find_opt (fun (th : Council.Conversation.thread) ->
    String.length th.topic >= String.length agent_name &&
    String.sub th.topic 0 (String.length agent_name) = agent_name
  ) threads

let get_or_create_agent_thread ~agent_name : Council.Conversation.thread option =
  match find_agent_thread ~agent_name with
  | Some th -> Some th
  | None ->
      let config = agent_thread_config () in
      let topic = Printf.sprintf "%s 활동 기록" agent_name in
      match Council.Conversation.start ~config ~topic ~initiator:agent_name ~max_turns:100 () with
      | Ok th -> Some th
      | Error _ -> None

(** {1 Read — Recall memories for prompt context} *)

(** Recall from Council thread (short-term memory).
    Reads thread turns directly via Council.Conversation. *)
let recall_from_thread ~agent_name ~limit : (string * float) list =
  match find_agent_thread ~agent_name with
  | None -> []
  | Some thread ->
    let recent =
      thread.turns
      |> List.rev  (* Most recent first *)
      |> (fun lst ->
          let rec take n acc = function
            | [] -> List.rev acc
            | _ when n <= 0 -> List.rev acc
            | x :: xs -> take (n - 1) (x :: acc) xs
          in
          take limit [] lst)
      |> List.rev  (* Back to chronological order *)
    in
    let n = List.length recent in
    List.mapi (fun i (t : Council.Conversation.turn) ->
      let recency = float_of_int (i + 1) /. float_of_int (max n 1) in
      (String.trim t.content, 0.5 +. recency *. 0.3)  (* 0.5 - 0.8 range *)
    ) recent

(** Recall from Memory Stream (scored long-term memory). *)
let recall_from_stream ~agent_name ~query ~limit : (string * float) list =
  let entries = Memory_stream.retrieve ~agent_name ~query ~limit in
  List.map (fun (e : Memory_stream.memory_entry) ->
    (e.content, 0.4 +. float_of_int e.importance *. 0.06)  (* 0.4 - 1.0 range *)
  ) entries

(** Recall from Neo4j agent interests.
    Fetches agent's recent activity and interest topics from graph. *)
let recall_from_neo4j ~agent_name ~limit : (string * float) list =
  let query = Printf.sprintf
    "MATCH (a:Agent {name: '%s'})-[r:PERFORMED]->(act:LodgeActivity) \
     RETURN act.content, act.action_type, act.timestamp \
     ORDER BY act.timestamp DESC LIMIT %d"
    (String.escaped agent_name) limit
  in
  let cmd = Printf.sprintf
    "cd /Users/dancer/me && sb neo4j query \"%s\" 2>/dev/null"
    (String.escaped query)
  in
  try
    let result = run_shell_nonblocking cmd in
    if String.length result < 5 then []
    else begin
      let json = Yojson.Safe.from_string result in
      let records = Yojson.Safe.Util.(json |> member "records" |> to_list) in
      List.filter_map (fun record ->
        try
          let arr = Yojson.Safe.Util.to_list record in
          let inner = Yojson.Safe.Util.to_list (List.hd arr) in
          let content = Yojson.Safe.Util.to_string (List.nth inner 0) in
          Some (content, 0.6)  (* Fixed relevance for graph-based recall *)
        with _ -> None
      ) records
    end
  with _ -> []

(** Recall relevant memories for an agent.
    Combines thread + Memory Stream + Neo4j activity. Sorted by relevance. *)
let recall ~agent_name ~query ~limit =
  let thread_memories = recall_from_thread ~agent_name ~limit in
  let stream_memories = recall_from_stream ~agent_name ~query ~limit in
  let neo4j_memories = recall_from_neo4j ~agent_name ~limit in
  let all = thread_memories @ stream_memories @ neo4j_memories in
  (* Deduplicate by content prefix (first 50 chars) *)
  let seen = Hashtbl.create 16 in
  let deduped = List.filter (fun (content, _) ->
    let key = String.sub content 0 (min 50 (String.length content)) in
    if Hashtbl.mem seen key then false
    else (Hashtbl.add seen key (); true)
  ) all in
  (* Sort by relevance (descending), take top [limit] *)
  let sorted = List.sort (fun (_, s1) (_, s2) -> compare s2 s1) deduped in
  let rec take n = function
    | [] -> []
    | _ when n <= 0 -> []
    | x :: rest -> x :: take (n - 1) rest
  in
  take limit sorted

(** Format recalled memories for inclusion in LLM prompt *)
let format_for_prompt memories =
  if memories = [] then ""
  else
    let lines = List.map (fun (content, score) ->
      Printf.sprintf "- (%.1f) %s" score content
    ) memories in
    String.concat "\n" lines

(** {1 Write — Store new experiences} *)

(** Record experience to Council thread (short-term) *)
let store_to_thread (exp : experience) =
  match get_or_create_agent_thread ~agent_name:exp.agent_name with
  | None -> ()
  | Some thread ->
      let config = agent_thread_config () in
      let action_prefix = match exp.action_type with
        | "post" -> Printf.sprintf "[POST: %s] " exp.context
        | "comment" ->
            let target = Option.value ~default:"" exp.board_id in
            Printf.sprintf "[COMMENT on: %s] " (String.sub target 0 (min 30 (String.length target)))
        | "upvote" -> "[UPVOTE] "
        | _ -> "[SKIP] "
      in
      let full_content = action_prefix ^ exp.content in
      ignore (Council.Conversation.reply ~config ~thread_id:thread.id
                ~speaker:exp.agent_name ~content:full_content ())

(** Record experience to Memory Stream (scored long-term) *)
let store_to_stream (exp : experience) =
  let mem_type = match exp.action_type with
    | "post" -> Memory_stream.Action "post"
    | "comment" -> Memory_stream.Action "comment"
    | "upvote" -> Memory_stream.Action "upvote"
    | _ -> Memory_stream.Action "skip"
  in
  Memory_stream.add_memory ~agent_name:exp.agent_name ~content:exp.content ~importance:5 mem_type;
  Memory_stream.rotate_if_needed ~agent_name:exp.agent_name

(** Record experience to Neo4j graph (long-term) *)
let store_to_neo4j (exp : experience) =
  let board_id_str = Option.value ~default:"" exp.board_id in
  let query = Printf.sprintf
    "MATCH (a:Agent {name: '%s'}) \
     CREATE (act:LodgeActivity { \
       content: '%s', \
       action_type: '%s', \
       context: '%s', \
       board_id: '%s', \
       timestamp: datetime() \
     }) \
     CREATE (a)-[:PERFORMED]->(act) \
     RETURN act"
    (String.escaped exp.agent_name)
    (String.escaped (String.sub exp.content 0 (min 200 (String.length exp.content))))
    (String.escaped exp.action_type)
    (String.escaped (String.sub exp.context 0 (min 100 (String.length exp.context))))
    (String.escaped board_id_str)
  in
  let cmd = Printf.sprintf
    "cd /Users/dancer/me && sb neo4j query \"%s\" 2>/dev/null"
    (String.escaped query)
  in
  ignore (run_shell_nonblocking cmd)

(** Record an agent's experience to all memory stores *)
let store exp =
  store_to_thread exp;
  store_to_stream exp;
  (* Only store non-skip actions to Neo4j *)
  if exp.action_type <> "skip" then
    store_to_neo4j exp
