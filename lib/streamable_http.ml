(** Streamable HTTP Transport for MCP

    Implements MCP spec 2025-03-26 Streamable HTTP transport.

    Architecture:
    - Stateless by default (no session required for simple request/response)
    - Optional session for: SSE streaming, server-initiated messages
    - Thread-safe session storage using Mutex
*)

type transport = Streamable_HTTP

type session = {
  id: string;
  created_at: float;
  mutable last_seen: float [@atomic];
  transport: transport;
  mutable subscriptions: string list;
}

type response_mode =
  | Json_response of Yojson.Safe.t
  | Json_batch of Yojson.Safe.t list
  | Sse_upgrade
  | Error_response of int * string

type request_handler =
  Yojson.Safe.t -> Yojson.Safe.t

module StringMap = Map.Make (String)

(** Session storage with mutex protection *)
module Session = struct
  let sessions : session StringMap.t ref = ref StringMap.empty
  let mutex = Eio.Mutex.create ()

  let generate_id () =
    let hex = Random_id.hex ~bytes:16 in
    (* Format as UUID: 8-4-4-4-12 *)
    Printf.sprintf "%s-%s-%s-%s-%s"
      (String.sub hex 0 8)
      (String.sub hex 8 4)
      (String.sub hex 12 4)
      (String.sub hex 16 4)
      (String.sub hex 20 12)

  let with_lock f =
    Eio.Mutex.use_rw ~protect:true mutex (fun () -> f ())

  let create ~transport =
    with_lock (fun () ->
      let session = {
        id = generate_id ();
        created_at = Time_compat.now ();
        last_seen = Time_compat.now ();
        transport;
        subscriptions = [];
      } in
      sessions := StringMap.add session.id session !sessions;
      session)

  let find id =
    with_lock (fun () -> StringMap.find_opt id !sessions)

  let touch session =
    session.last_seen <- Time_compat.now ()

  let remove id =
    with_lock (fun () -> sessions := StringMap.remove id !sessions)

  let list_all () =
    with_lock (fun () ->
      !sessions
      |> StringMap.bindings
      |> List.map (fun (_, v) -> v)
    )

  let cleanup ~ttl_seconds =
    let now = Time_compat.now () in
    let cutoff = now -. ttl_seconds in
    with_lock (fun () ->
      let to_remove = StringMap.fold (fun id session acc ->
        if session.last_seen < cutoff then id :: acc else acc
      ) !sessions [] in
      List.iter (fun id -> sessions := StringMap.remove id !sessions) to_remove;
      List.length to_remove)
end

(** JSON-RPC low-level helpers (raw Yojson, pre-parse validation). *)

let jsonrpc_is_valid_request = function
  | `Assoc fields ->
      List.mem_assoc "jsonrpc" fields &&
      List.mem_assoc "method" fields
  | _ -> false

let jsonrpc_is_batch = function
  | `List _ -> true
  | _ -> false

let jsonrpc_error_response ~id ~code ~message =
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", id);
    ("error", `Assoc [
      ("code", `Int code);
      ("message", `String message);
    ]);
  ]

let jsonrpc_extract_id = function
  | `Assoc fields ->
      List.assoc_opt "id" fields |> Option.value ~default:`Null
  | _ -> `Null

let jsonrpc_dispatch_request (handler : request_handler) request =
  try
    handler request
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    jsonrpc_error_response
      ~id:(jsonrpc_extract_id request)
      ~code:(-32603)
      ~message:(Log.Server.error "streamable_http dispatch: %s" (Printexc.to_string exn); "Internal error")

(** Handle POST /mcp - JSON-RPC request processing *)
let handle_post ?session_id ~body ?request_handler () =
  (* Parse JSON body *)
  let json_result =
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error msg -> Error msg
  in
  let request_handler =
      Option.value request_handler
      ~default:(fun request ->
        let id = jsonrpc_extract_id request in
        if jsonrpc_is_valid_request request then
          jsonrpc_error_response ~id ~code:(-32601)
            ~message:"Method not found: no request handler configured"
        else
          jsonrpc_error_response ~id ~code:(-32600) ~message:"Invalid Request")
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

      (* Streamable HTTP transport no longer accepts JSON-RPC batches. *)
      if jsonrpc_is_batch json then
        (Error_response (400, "JSON-RPC batch requests are not supported"), session)
      else if jsonrpc_is_valid_request json then
        (* Single request - delegate to MCP handler *)
        let response = jsonrpc_dispatch_request request_handler json in
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
