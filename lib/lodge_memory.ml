(** Lodge Memory — Agent experience recall & store

    Combines multiple memory sources:
    - Council thread (short-term, per-agent conversation history)
    - Memory Stream (scored retrieval, long-term)
    - Neo4j graph via GraphQL (agent activity relationships)

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

(** {1 Utilities} *)

(** Truncate string to max [n] bytes, UTF-8 safe (cuts at char boundary). *)
let truncate s n =
  if String.length s <= n then s
  else
    (* Find last valid UTF-8 char boundary before n *)
    let rec find_boundary i =
      if i <= 0 then 0
      else
        let byte = Char.code s.[i] in
        if byte land 0xC0 <> 0x80 then i  (* start of UTF-8 char *)
        else find_boundary (i - 1)
    in
    String.sub s 0 (find_boundary n)

(** Use local GraphQL by default for local MCP runs.
    Set GRAPHQL_URL explicitly to force remote endpoint. *)
let default_graphql_url () =
  let port = Sys.getenv_opt "MASC_MCP_PORT" |> Option.value ~default:"8935" in
  Printf.sprintf "http://127.0.0.1:%s/graphql" port

(** Keep auth token out of argv so process errors don't leak secrets. *)
let with_auth_header_file api_key f =
  if api_key = "" then f None
  else
    let path = Filename.temp_file "masc-gql-auth-" ".hdr" in
    Fun.protect
      ~finally:(fun () -> try Sys.remove path with _ -> ())
      (fun () ->
         let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
         let oc = Unix.out_channel_of_descr fd in
         output_string oc ("Authorization: Bearer " ^ api_key ^ "\n");
         close_out oc;
         f (Some path))

(** curl-based GraphQL request — reliable DNS resolution in Railway containers *)
let graphql_request_curl body : (string, string) Stdlib.result =
  let url = Sys.getenv_opt "GRAPHQL_URL" |> Option.value ~default:(default_graphql_url ()) in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  with_auth_header_file api_key (fun auth_header_file ->
      let argv =
        [ "curl"; "-s"; "-m"; "10"; url;
          "-H"; "Content-Type: application/json"
        ]
        |> fun base ->
        match auth_header_file with
        | None -> base
        | Some header_file -> base @ [ "-H"; "@" ^ header_file ]
        |> fun with_auth ->
        (* Read request body from stdin to avoid quoting/escaping issues. *)
        with_auth @ [ "-d"; "@-" ]
      in
      try
        let output =
          Process_eio.run_argv_with_stdin ~timeout_sec:15.0 ~stdin_content:body argv
        in
        if String.length output = 0 then Error "curl: empty response" else Ok output
      with exn -> Error (Printf.sprintf "curl: %s" (Printexc.to_string exn)))

(** GraphQL request via Cohttp_eio with curl fallback.
    Falls back to curl if Cohttp fails (Railway DNS issues). *)
let graphql_request ?(timeout_sec=5.0) body : (string, string) Stdlib.result =
  let url = Sys.getenv_opt "GRAPHQL_URL" |> Option.value ~default:(default_graphql_url ()) in
  let api_key = Sys.getenv_opt "GRAPHQL_API_KEY" |> Option.value ~default:"" in
  let max_response_bytes = 1_000_000 in
  let suppress_body _s = "body suppressed" in
  let cohttp_result = match Eio_context.get_net_opt () with
  | None -> Error "Eio net not initialized"
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
              Cohttp_eio.Client.make ~https:None net
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
            Error "empty response"
          else if Cohttp.Code.is_success status then
            Ok body_str
          else
            Error (Printf.sprintf "HTTP %d (%s)" status (suppress_body body_str))
        )
      in
      match Eio_context.get_clock_opt () with
      | Some clock ->
          (try Eio.Time.with_timeout_exn clock timeout_sec run
           with exn -> Error (Printexc.to_string exn))
      | None ->
          (try run () with exn -> Error (Printexc.to_string exn))
  in
  match cohttp_result with
  | Ok _ as success -> success
  | Error cohttp_err ->
      Printf.eprintf "[Lodge_memory] Cohttp failed (%s), trying curl fallback...\n%!" cohttp_err;
      graphql_request_curl body

(** Resolve ME_ROOT consistently *)
let me_root () =
  Sys.getenv_opt "ME_ROOT" |> Option.value ~default:"/Users/dancer/me"

(** {1 Council Thread Access (direct, no Lodge_heartbeat dependency)} *)

let agent_thread_config () : Council.Conversation.config =
  { base_path = me_root (); room = "lodge" }

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

(** Recall from Neo4j via GraphQL API.
    Fetches agent's recent LodgeActivity records through the GraphQL layer.
    Uses structured JSON construction (no string interpolation → no injection). *)
let recall_from_neo4j ~agent_name ~limit : (string * float) list =
  let query = Printf.sprintf
    "{ agentActivities(agentName: %s, first: %d) { edges { node { content } } } }"
    (Yojson.Safe.to_string (`String agent_name)) limit
  in
  let body = Yojson.Safe.to_string (`Assoc [("query", `String query)]) in
  try
    match graphql_request body with
    | Error err ->
        Eio.traceln "   ⚠️ [Lodge_memory] GraphQL recall failed: %s" err;
        []
    | Ok result ->
        let json = Yojson.Safe.from_string result in
        let edges = json
          |> Yojson.Safe.Util.member "data"
          |> Yojson.Safe.Util.member "agentActivities"
          |> Yojson.Safe.Util.member "edges"
          |> Yojson.Safe.Util.to_list
        in
        List.filter_map (fun edge ->
          try
            let node = Yojson.Safe.Util.member "node" edge in
            let content = Yojson.Safe.Util.(member "content" node |> to_string) in
            Some (content, 0.6)
          with Yojson.Safe.Util.Type_error _ | Failure _ -> None
        ) edges
  with
  | Yojson.Json_error msg ->
      Eio.traceln "   ⚠️ [Lodge_memory] GraphQL recall JSON parse error: %s" msg;
      []
  | exn ->
      Eio.traceln "   ⚠️ [Lodge_memory] GraphQL recall error: %s" (Printexc.to_string exn);
      []

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
      (try ignore (Council.Conversation.reply ~config ~thread_id:thread.id
                ~speaker:exp.agent_name ~content:full_content ())
       with exn -> Printf.eprintf "[lodge-memory] council reply failed: %s\n%!" (Printexc.to_string exn))

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

(** Record experience to Neo4j graph via GraphQL mutation (long-term).
    Uses Yojson for JSON construction (no manual escaping → no injection). *)
let store_to_neo4j (exp : experience) =
  let content = truncate exp.content 200 in
  let context = truncate exp.context 100 in
  let board_id_part = match exp.board_id with
    | Some b -> Printf.sprintf ", boardId: %s" (Yojson.Safe.to_string (`String b))
    | None -> ""
  in
  let query = Printf.sprintf
    "mutation { createLodgeActivity(agentName: %s, content: %s, actionType: %s, context: %s%s) { success message } }"
    (Yojson.Safe.to_string (`String exp.agent_name))
    (Yojson.Safe.to_string (`String content))
    (Yojson.Safe.to_string (`String exp.action_type))
    (Yojson.Safe.to_string (`String context))
    board_id_part
  in
  let body = Yojson.Safe.to_string (`Assoc [("query", `String query)]) in
  try
    match graphql_request body with
    | Error err ->
        Eio.traceln "   ⚠️ [Lodge_memory] GraphQL store failed for %s: %s" exp.agent_name err
    | Ok result ->
        let json = Yojson.Safe.from_string result in
        match Yojson.Safe.Util.member "errors" json with
        | `List (_ :: _ as errors) ->
          let msg = try
            List.hd errors |> Yojson.Safe.Util.member "message" |> Yojson.Safe.Util.to_string
          with _ -> "unknown" in
          Eio.traceln "   ⚠️ [Lodge_memory] GraphQL store error for %s: %s" exp.agent_name msg
        | _ -> ()
  with exn ->
    Eio.traceln "   ⚠️ [Lodge_memory] GraphQL store exception for %s: %s"
      exp.agent_name (Printexc.to_string exn)

(** Record an agent's experience to all memory stores *)
let store exp =
  (* Skip empty content (e.g. ActionSkip) for thread/stream to avoid noise *)
  if String.length exp.content > 0 then begin
    store_to_thread exp;
    store_to_stream exp
  end;
  (* Only store non-skip actions to Neo4j *)
  if exp.action_type <> "skip" then
    store_to_neo4j exp
