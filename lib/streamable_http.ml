(** Streamable HTTP Transport for MCP

    Implements MCP spec 2025-03-26 Streamable HTTP transport.

    Architecture:
    - Stateless by default (no session required for simple request/response)
    - Optional session for: SSE streaming, server-initiated messages
    - Thread-safe session storage using Mutex
*)

type transport =
  | SSE_legacy
  | Streamable_HTTP

type session = {
  id: string;
  created_at: float;
  mutable last_seen: float;
  transport: transport;
  mutable subscriptions: string list;
}

type response_mode =
  | Json_response of Yojson.Safe.t
  | Json_batch of Yojson.Safe.t list
  | Sse_upgrade
  | Error_response of int * string

(** Session storage with mutex protection *)
module Session = struct
  let sessions : (string, session) Hashtbl.t = Hashtbl.create 64
  let mutex = Mutex.create ()

  let generate_id () =
    (* Use Mirage_crypto_rng for secure random ID *)
    let random_str = Mirage_crypto_rng.generate 16 in
    let hex = random_str
      |> String.to_seq
      |> Seq.map (fun c -> Printf.sprintf "%02x" (Char.code c))
      |> List.of_seq
      |> String.concat ""
    in
    (* Format as UUID: 8-4-4-4-12 *)
    Printf.sprintf "%s-%s-%s-%s-%s"
      (String.sub hex 0 8)
      (String.sub hex 8 4)
      (String.sub hex 12 4)
      (String.sub hex 16 4)
      (String.sub hex 20 12)

  let create ~transport =
    Mutex.lock mutex;
    let session = {
      id = generate_id ();
      created_at = Unix.gettimeofday ();
      last_seen = Unix.gettimeofday ();
      transport;
      subscriptions = [];
    } in
    Hashtbl.replace sessions session.id session;
    Mutex.unlock mutex;
    session

  let find id =
    Mutex.lock mutex;
    let result = Hashtbl.find_opt sessions id in
    Mutex.unlock mutex;
    result

  let touch session =
    session.last_seen <- Unix.gettimeofday ()

  let remove id =
    Mutex.lock mutex;
    Hashtbl.remove sessions id;
    Mutex.unlock mutex

  let list_all () =
    Mutex.lock mutex;
    let result = Hashtbl.fold (fun _ v acc -> v :: acc) sessions [] in
    Mutex.unlock mutex;
    result

  let cleanup ~ttl_seconds =
    let now = Unix.gettimeofday () in
    let cutoff = now -. ttl_seconds in
    Mutex.lock mutex;
    let to_remove = Hashtbl.fold (fun id session acc ->
      if session.last_seen < cutoff then id :: acc else acc
    ) sessions [] in
    List.iter (Hashtbl.remove sessions) to_remove;
    Mutex.unlock mutex;
    List.length to_remove
end

(** JSON-RPC helpers *)
module Jsonrpc = struct
  let is_valid_request json =
    match json with
    | `Assoc fields ->
        List.mem_assoc "jsonrpc" fields &&
        List.mem_assoc "method" fields
    | _ -> false

  let is_batch json =
    match json with
    | `List _ -> true
    | _ -> false

  let error_response ~id ~code ~message =
    `Assoc [
      ("jsonrpc", `String "2.0");
      ("id", id);
      ("error", `Assoc [
        ("code", `Int code);
        ("message", `String message);
      ]);
    ]

  let _parse_error () =
    error_response
      ~id:`Null
      ~code:(-32700)
      ~message:"Parse error"

  let invalid_request () =
    error_response
      ~id:`Null
      ~code:(-32600)
      ~message:"Invalid Request"
end

(** Handle POST /mcp - JSON-RPC request processing *)
let handle_post ?session_id ~body () =
  (* Parse JSON body *)
  let json_result =
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error msg -> Error msg
  in

  match json_result with
  | Error _ ->
      (Error_response (400, "Invalid JSON"), None)

  | Ok json ->
      (* Find or create session if session_id provided *)
      let session = match session_id with
        | Some id -> Session.find id
        | None -> None
      in

      (* Touch session if found *)
      Option.iter Session.touch session;

      (* Check if batch or single request *)
      if Jsonrpc.is_batch json then
        match json with
        | `List requests ->
            (* Process batch: for now, return placeholder *)
            let responses = List.filter_map (fun req ->
              if Jsonrpc.is_valid_request req then
                (* Delegate to MCP handler - placeholder *)
                Some (`Assoc [
                  ("jsonrpc", `String "2.0");
                  ("id", match req with
                    | `Assoc fields -> List.assoc_opt "id" fields |> Option.value ~default:`Null
                    | _ -> `Null);
                  ("result", `Assoc [("status", `String "ok")]);
                ])
              else
                Some (Jsonrpc.invalid_request ())
            ) requests in
            (Json_batch responses, session)
        | _ ->
            (Error_response (400, "Invalid batch format"), session)
      else if Jsonrpc.is_valid_request json then
        (* Single request - delegate to MCP handler *)
        let id = match json with
          | `Assoc fields -> List.assoc_opt "id" fields |> Option.value ~default:`Null
          | _ -> `Null
        in
        let response = `Assoc [
          ("jsonrpc", `String "2.0");
          ("id", id);
          ("result", `Assoc [("status", `String "ok"); ("transport", `String "streamable_http")]);
        ] in
        (Json_response response, session)
      else
        (Error_response (400, "Invalid JSON-RPC request"), session)

(** Handle GET /mcp - SSE stream setup *)
let handle_get ?session_id () =
  match session_id with
  | Some id ->
      (match Session.find id with
       | Some session ->
           Session.touch session;
           Ok session
       | None ->
           (* Create new session for SSE *)
           let session = Session.create ~transport:Streamable_HTTP in
           Ok session)
  | None ->
      (* Create new session *)
      let session = Session.create ~transport:Streamable_HTTP in
      Ok session

(** Check if request uses Streamable HTTP (vs legacy SSE) *)
let is_streamable_request (request : Httpun.Request.t) =
  (* Check for MCP-specific headers or content-type *)
  let headers = request.headers in
  let has_mcp_header = Httpun.Headers.get headers "mcp-session-id" <> None in
  let content_type = Httpun.Headers.get headers "content-type" in
  let is_json = match content_type with
    | Some ct -> String.lowercase_ascii ct |> fun s ->
        String.sub s 0 (min 16 (String.length s)) = "application/json"
    | None -> false
  in
  has_mcp_header || is_json

(** Extract session ID from request headers *)
let get_session_id (request : Httpun.Request.t) =
  Httpun.Headers.get request.headers "mcp-session-id"

(** Add session ID to response headers *)
let with_session_header session headers =
  ("mcp-session-id", session.id) :: headers
