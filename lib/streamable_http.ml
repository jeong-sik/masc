(** Streamable HTTP Transport for MCP

    Implements MCP spec 2025-03-26 Streamable HTTP transport.

    Architecture:
    - Stateless by default (no session required for simple request/response)
    - Optional session for: SSE streaming, server-initiated messages
    - Lock-free session storage using atomic CAS
*)

type transport = Streamable_HTTP

type session = {
  id: string;
  created_at: float;
  last_seen: float Atomic.t;
  transport: transport;
  subscriptions: string list;
}

type response_mode =
  | Json_response of Yojson.Safe.t
  | Sse_upgrade
  | Error_response of int * string

type request_handler =
  Yojson.Safe.t -> Yojson.Safe.t

module StringMap = Set_util.StringMap

(** Session storage using lock-free atomic updates.
    A single [Atomic.t] holds the immutable session map so reads never block
    and writers retry via CAS instead of taking a mutex. *)
module Session = struct
  let sessions : session StringMap.t Atomic.t = Atomic.make StringMap.empty

  let generate_id () =
    let hex = Random_id.hex ~bytes:16 in
    (* Format as UUID: 8-4-4-4-12 *)
    Printf.sprintf "%s-%s-%s-%s-%s"
      (String.sub hex 0 8)
      (String.sub hex 8 4)
      (String.sub hex 12 4)
      (String.sub hex 16 4)
      (String.sub hex 20 12)

  let create ~transport =
    let now = Time_compat.now () in
    let session = {
      id = generate_id ();
      created_at = now;
      last_seen = Atomic.make now;
      transport;
      subscriptions = [];
    } in
    Lockfree_atomic.update sessions (StringMap.add session.id session);
    session

  let find id =
    StringMap.find_opt id (Atomic.get sessions)

  let touch session =
    Atomic.set session.last_seen (Time_compat.now ())

  let remove id =
    Lockfree_atomic.update sessions (StringMap.remove id)

  let list_all () =
    Atomic.get sessions
    |> StringMap.bindings
    |> List.map (fun (_, v) -> v)

  let cleanup ~ttl_seconds =
    let now = Time_compat.now () in
    let cutoff = now -. ttl_seconds in
    Lockfree_atomic.update_with_commit sessions (fun map ->
      let expired = ref [] in
      let next =
        StringMap.fold
          (fun id session acc ->
             if Atomic.get session.last_seen < cutoff then begin
               expired := id :: !expired;
               StringMap.remove id acc
             end else acc)
          map map
      in
      { next_state = next; result = List.length !expired })
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

let jsonrpc_error_response ~id ~(code : Mcp_error_code.t) ~message =
  `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", id);
    ("error", `Assoc [
      ("code", `Int (Mcp_error_code.to_wire_code code));
      ("message", `String message);
    ]);
  ]

let jsonrpc_extract_id = function
  | `Assoc fields ->
      List.assoc_opt "id" fields |> Option.value ~default:`Null
  | _ -> `Null

let jsonrpc_dispatch_request (handler : request_handler) request =
  try handler request
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    jsonrpc_error_response
       ~id:(jsonrpc_extract_id request)
       ~code:Mcp_error_code.Internal_error
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
          jsonrpc_error_response ~id ~code:Mcp_error_code.Method_not_found
            ~message:"Method not found: no request handler configured"
        else
          jsonrpc_error_response ~id ~code:Mcp_error_code.Invalid_request ~message:"Invalid Request")
  in

  match json_result with
  | Error parse_msg ->
      (* Include the parser's position-bearing message in the 400 response
         body. Yojson.Json_error carries "at line N, char M: <reason>",
         which is bounded by the parser regardless of body size — no info
         leak to the same client that sent the malformed body. Without
         this, operators staring at a 400 cannot tell apart "trailing
         comma at char 487" from "body was a binary blob". *)
      ( Error_response (400, Printf.sprintf "Invalid JSON: %s" parse_msg),
        None )

  | Ok json ->
      (* A syntactically valid request body on an existing streamable session
         proves client activity even if JSON-RPC validation or handler dispatch
         later returns an error response. Malformed JSON does not reach here and
         therefore does not refresh the activity window. *)
      let session = match session_id with
        | Some id -> Session.find id
        | None -> None
      in
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
