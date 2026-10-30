(* HTTP/2 requests are admitted on the terms HTTP/1 applies: the same body
   size ceiling, on POST /graphql the read gate before the body is read, and
   on the Board reads the same strict-mode public-read gate.
   Every case runs a real H2 exchange in memory, an h2 client connection
   pumped against a server connection, so what is checked is what a peer
   sees on the wire. *)

open Alcotest

let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

module Helpers = Server_h2_gateway_helpers
module Mcp_error_code = Masc.Mcp_error_code

(* The request's :authority and the gateway's trust policy name the same
   listener; a mismatch would make the gateway refuse every request as an
   untrusted authority. *)
let listener_host = "localhost"

let listener_port = 8935

let authority = Printf.sprintf "%s:%d" listener_host listener_port

let max_bytes = Masc.Http_server_eio.Request.max_body_bytes

type reply = { status : int; body : string }

type response_failure =
  | Stream_failure of H2.Client_connection.error
  | Incomplete_response_body

(* Bytes one side wrote that the other side's [read] has not taken yet. h2
   reads whole frames, and a frame can be split across iovecs or writes, so
   the unconsumed tail is offered again together with the next bytes. *)
type lane = { mutable pending : string }

(* What one [transfer] round saw on its writer. [Waiting] is a writer that
   yielded with nothing to send; [Closed] is one that will never send again. *)
type lane_round = Moved | Waiting | Closed

(* Request work runs in fibers the connection reader only schedules, so an
   exchange waits for the server's next output instead of failing the first
   round that moves no bytes. A server still silent after this bound is
   stalled. It stays below [case_timeout_s], the bound [with_request_scope]
   puts on a whole case, so the stall is reported by name, not as an Eio
   timeout. *)
let exchange_stall_timeout_s = 5.0

let case_timeout_s = 10.0

let transfer lane next_write report_write read =
  let rec drain progressed =
    match next_write () with
    | `Write iovecs ->
      let chunk = Buffer.create 4096 in
      Buffer.add_string chunk lane.pending;
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t H2.IOVec.t) ->
            Buffer.add_string chunk
              (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
            total + iov.len)
          0 iovecs
      in
      report_write (`Ok written);
      let data = Buffer.contents chunk in
      let length = String.length data in
      let consumed =
        read (Bigstringaf.of_string data ~off:0 ~len:length) ~off:0 ~len:length
      in
      lane.pending <- String.sub data consumed (length - consumed);
      drain true
    | `Yield -> if progressed then Moved else Waiting
    | `Close _ -> if progressed then Moved else Closed
  in
  drain false

type session =
  { client : H2.Client_connection.t
  ; server : H2.Server_connection.t
  ; to_server : lane
  ; to_client : lane
  ; await_output : unit -> unit
  }

let create_session ~clock ~handler ?(config = H2.Config.default) () =
  let client = H2.Client_connection.create
    ~error_handler:(fun _ -> fail "H2 connection error") () in
  let server = H2.Server_connection.create ~config
    ~error_handler:(Server_h2_gateway.make_error_handler ()
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))) handler in
  let await_output () =
    let ready, wake = Eio.Promise.create () in
    H2.Server_connection.yield_writer server (fun () -> Eio.Promise.resolve wake ());
    match Eio.Time.with_timeout clock exchange_stall_timeout_s
      (fun () -> Eio.Promise.await ready; Ok ()) with
    | Ok () -> ()
    | Error `Timeout -> fail "H2 exchange stalled before the response completed"
  in
  { client; server; to_server = { pending = "" }; to_client = { pending = "" }; await_output }

let flush_upload session =
  transfer session.to_server
    (fun () -> H2.Client_connection.next_write_operation session.client)
    (H2.Client_connection.report_write_result session.client)
    (H2.Server_connection.read session.server)

let rec pump_until session finished =
  if not (finished ()) then (
    let sent = flush_upload session in
    let received = transfer session.to_client
      (fun () -> H2.Server_connection.next_write_operation session.server)
      (H2.Server_connection.report_write_result session.server)
      (H2.Client_connection.read session.client) in
    if not (finished ()) then (
      (match sent, received with
       | Moved, _ | _, Moved -> ()
       | (Waiting | Closed), Waiting -> session.await_output ()
       | (Waiting | Closed), Closed -> fail "H2 connection closed before response");
      pump_until session finished))

let open_request session ?(meth = `POST) ?(headers = [])
    ?(on_response_headers = fun _ -> ()) ?(on_stream_error = fun _ -> ()) target =
  let reply, resolve = Eio.Promise.create () in
  let finish result =
    if not (Eio.Promise.is_resolved reply) then Eio.Promise.resolve resolve result
  in
  let request = H2.Request.create ~scheme:"http" meth target
    ~headers:(H2.Headers.of_list ((":authority", authority) :: headers)) in
  let writer = H2.Client_connection.request session.client
    ~flush_headers_immediately:true request
    ~error_handler:(fun error ->
      on_stream_error error;
      finish (Error (Stream_failure error)))
    ~response_handler:(fun response reader ->
      on_response_headers response;
      let body = Buffer.create 256 in
      let rec read () = H2.Body.Reader.schedule_read reader
        ~on_eof:(fun () -> match H2.Body.Reader.completion reader with
          | Complete -> finish (Ok { status = H2.Status.to_code response.status; body = Buffer.contents body })
          | Pending | Aborted -> finish (Error Incomplete_response_body))
        ~on_read:(fun bytes ~off ~len ->
          Buffer.add_string body (Bigstringaf.substring bytes ~off ~len); read ()) in
      read ()) in
  writer, reply

let await_reply session reply =
  pump_until session (fun () -> Eio.Promise.is_resolved reply);
  match Eio.Promise.await reply with
  | Ok response -> response
  | Error (Stream_failure _ | Incomplete_response_body) ->
    fail "H2 stream failed before a complete response"

let exchange_on session ?meth ?headers ~send target =
  let writer, reply = open_request session ?meth ?headers target in
  send writer;
  await_reply session reply

(* Existing individual admission cases and continuity cases use the same wire
   pump. A session keeps the actual client/server connection for later POSTs. *)
let exchange ~clock ~handler ?meth ?headers ~send target =
  exchange_on (create_session ~clock ~handler ()) ?meth ?headers ~send target

let reset_stream session stream_id =
  let frame = Bytes.make 13 '\000' in
  Bytes.set frame 2 '\004';
  Bytes.set frame 3 '\003';
  Bytes.set_int32_be frame 5 stream_id;
  (* RFC7540 RST_STREAM CANCEL. This is the real server parser input. *)
  Bytes.set_int32_be frame 9 8l;
  let bytes = session.to_server.pending ^ Bytes.to_string frame in
  let len = String.length bytes in
  let consumed = H2.Server_connection.read session.server
    (Bigstringaf.of_string bytes ~off:0 ~len) ~off:0 ~len in
  check int "complete reset frame consumed" len consumed;
  session.to_server.pending <- ""

(* Closes the writer only once every byte has been handed to the connection.
   h2 sends END_STREAM for a closed writer whenever its send window is empty,
   even with bytes still unsent (Respd.flush_request_body), so closing right
   after the write cut the body at the 65535-byte initial window before the
   server's SETTINGS could widen it. *)
let send_whole payload writer =
  H2.Body.Writer.write_string writer payload;
  H2.Body.Writer.flush writer (fun _ -> H2.Body.Writer.close writer)

(* Use RFC7540's initial window rather than h2's enlarged default. Two unread
   40000-byte bodies would exhaust the connection's 65535-byte credit. The
   following POST must deliver its body, not merely return a headers-only GET. *)
let continuity_config = { H2.Config.default with initial_window_size = 65535l }
let continuity_body = String.make 40000 'x'

let check_next_body session delivered =
  let reply = exchange_on session ~send:(send_whole continuity_body) "/next" in
  check int "next POST completes on the same connection" 200 reply.status;
  check (option int) "next body is delivered whole"
    (Some (String.length continuity_body)) !delivered

(* Records what the body reader handed over and answers 200, so a case tells a
   delivered body from a refused one and checks how much arrived. *)
let ceiling_handler ~sw delivered reqd =
  Helpers.h2_read_body ~sw reqd (fun body ->
    delivered := Some (String.length body);
    Helpers.h2_respond_text reqd "delivered")

(* Nothing is sent after the headers. A reader that waited for the declared
   bytes would stall the exchange. *)
let test_declared_length_over_the_ceiling_is_refused_before_any_byte ~clock sw =
  let delivered = ref None in
  let reply =
    exchange ~clock ~handler:(ceiling_handler ~sw delivered)
      ~headers:[ "content-length", string_of_int (max_bytes + 1) ]
      ~send:(fun _writer -> ())
      "/upload"
  in
  check int "refused as too large" 413 reply.status;
  check (option int) "the callback never ran" None !delivered

let test_streamed_body_over_the_ceiling_is_refused ~clock sw =
  let delivered = ref None in
  let reply =
    exchange ~clock ~handler:(ceiling_handler ~sw delivered)
      ~send:(send_whole (String.make (max_bytes + 1) 'x'))
      "/upload"
  in
  check int "refused as too large" 413 reply.status;
  check (option int) "the callback never ran" None !delivered

let test_body_at_the_ceiling_is_delivered_whole ~clock sw =
  let delivered = ref None in
  let reply =
    exchange ~clock ~handler:(ceiling_handler ~sw delivered)
      ~send:(send_whole (String.make max_bytes 'x'))
      "/upload"
  in
  check int "admitted" 200 reply.status;
  check (option int) "every byte reached the callback" (Some max_bytes)
    !delivered

(* The declared-length check and the streamed check are separate branches;
   this one pins the first at the boundary. *)
let test_declared_length_at_the_ceiling_is_delivered_whole ~clock sw =
  let delivered = ref None in
  let reply =
    exchange ~clock ~handler:(ceiling_handler ~sw delivered)
      ~headers:[ "content-length", string_of_int max_bytes ]
      ~send:(send_whole (String.make max_bytes 'x'))
      "/upload"
  in
  check int "admitted" 200 reply.status;
  check (option int) "every byte reached the callback" (Some max_bytes)
    !delivered

let test_declared_refusals_preserve_connection_credit ~clock sw =
  let delivered = ref None in
  let session = create_session ~clock ~config:continuity_config
    ~handler:(ceiling_handler ~sw delivered) () in
  for _ = 1 to 3 do
    let reply = exchange_on session
      ~headers:[ "content-length", string_of_int (max_bytes + 1) ]
      (* Keep the request open: rejection must not wait for its declared body. *)
      ~send:(fun writer -> H2.Body.Writer.write_string writer continuity_body)
      "/upload" in
    check int "declared oversize refused" 413 reply.status;
    check (option int) "oversize callback never ran" None !delivered
  done;
  check_next_body session delivered

let test_streamed_refusal_preserves_connection_credit ~clock sw =
  let delivered = ref None in
  let session = create_session ~clock ~config:continuity_config
    ~handler:(ceiling_handler ~sw delivered) () in
  let reply = exchange_on session
    ~send:(send_whole (String.make (max_bytes + 1) 'x')) "/upload" in
  check int "streamed oversize refused" 413 reply.status;
  check (option int) "oversize callback never ran" None !delivered;
  check_next_body session delivered

let test_malformed_body_preserves_next_post headers payload ~clock sw =
  let delivered = ref None in
  let session = create_session ~clock ~config:continuity_config
    ~handler:(ceiling_handler ~sw delivered) () in
  let reply = exchange_on session ~headers ~send:(send_whole payload) "/upload" in
  check int "malformed body refused" 400 reply.status;
  check (option int) "malformed body never reached the application" None !delivered;
  check_next_body session delivered

let test_malformed_headers_preserve_next_post headers ~clock sw =
  let delivered = ref None in
  let deliveries = ref 0 in
  let seen_status = ref None in
  let seen_error = ref None in
  let handler reqd = Helpers.h2_read_body ~sw reqd (fun body ->
    incr deliveries;
    delivered := Some (String.length body);
    Helpers.h2_respond_text reqd "delivered") in
  let session = create_session ~clock ~config:continuity_config ~handler () in
  let writer, reply = open_request session ~headers
    ~on_response_headers:(fun response -> seen_status := Some (H2.Status.to_code response.status))
    ~on_stream_error:(fun error -> seen_error := Some error)
    "/upload" in
  (* Invalid HEADERS are refused before the request handler. This upload is
     already in flight: the pinned H2 parser then resets the closed stream.
     Keep both the 400 headers and the precise reset visible; a completed HTTP
     error body is not promised for DATA arriving after malformed HEADERS. *)
  send_whole continuity_body writer;
  pump_until session (fun () ->
    Eio.Promise.is_resolved reply && Option.is_some !seen_error);
  check (option int) "malformed headers produced HTTP 400" (Some 400) !seen_status;
  (match Eio.Promise.await reply with
   | Error (Stream_failure _ | Incomplete_response_body) -> ()
   | Ok _ -> fail "expected a failed response after malformed HEADERS and in-flight DATA");
  (* Closing the stream discards its reader before the error handler runs.
     The first reply can therefore be aborted EOF; observe the typed reset
     independently rather than losing it to first-wins reply settlement. *)
  (match !seen_error with
   | Some (`Protocol_error (code, _)) ->
     check bool "in-flight DATA produced the pinned StreamClosed reset" true
       (code = H2.Error_code.StreamClosed)
   | Some (`Malformed_response _ | `Invalid_response_body_length _ | `Exn _)
   | None -> fail "expected the pinned parser's typed reset after in-flight DATA");
  check int "malformed upload never reached the application" 0 !deliveries;
  check_next_body session delivered;
  check int "only the next valid body was delivered" 1 !deliveries

let test_stream_error_prevents_body_delivery ~at_eof ~clock sw =
  let delivered = ref None in
  let deliveries = ref 0 in
  let current = ref None in
  let handler reqd =
    current := Some reqd;
    Helpers.h2_read_body ~sw reqd (fun body ->
      incr deliveries;
      delivered := Some (String.length body);
      Helpers.h2_respond_text reqd "delivered") in
  let session = create_session ~clock ~config:continuity_config ~handler () in
  let writer, reply = open_request session "/upload" in
  if at_eof then send_whole continuity_body writer
  else H2.Body.Writer.write_string writer continuity_body;
  ignore (flush_upload session);
  let reqd = match !current with
    | Some reqd -> reqd
    | None -> fail "request headers did not reach the server" in
  check bool "injection occurs at the intended body boundary" at_eof
    (match H2.Body.Reader.completion (H2.Reqd.request_body reqd) with
     | Complete -> true
     | Pending | Aborted -> false);
  check (option int) "application work is deferred" None !delivered;
  H2.Reqd.report_exn reqd (Failure "injected request stream error");
  check int "stream error response" 500 (await_reply session reply).status;
  check (option int) "failed body never reached the application" None !delivered;
  check_next_body session delivered;
  check int "only the next valid body was delivered" 1 !deliveries

let test_reset_after_eof_prevents_body_delivery ~clock sw =
  let delivered = ref None in
  let deliveries = ref 0 in
  let current = ref None in
  let handler reqd =
    current := Some reqd;
    Helpers.h2_read_body ~sw reqd (fun body ->
      incr deliveries;
      delivered := Some (String.length body);
      Helpers.h2_respond_text reqd "delivered") in
  let session = create_session ~clock ~config:continuity_config
    ~handler () in
  let writer, _reply = open_request session "/upload" in
  send_whole continuity_body writer;
  ignore (flush_upload session);
  check (option int) "EOF only schedules application work" None !delivered;
  let reqd = match !current with
    | Some reqd -> reqd
    | None -> fail "request headers did not reach the server" in
  check bool "EOF was parsed before the reset" true
    (match H2.Body.Reader.completion (H2.Reqd.request_body reqd) with
     | Complete -> true
     | Pending | Aborted -> false);
  reset_stream session 1l;
  check_next_body session delivered;
  check int "only the next valid body was delivered" 1 !deliveries

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let trust_policy () =
  match
    Server_request_authority.make_trust_policy ~bind_host:listener_host
      ~bind_port:listener_port ~explicit_base_url:None
  with
  | Ok policy -> policy
  | Error error ->
    fail (Server_request_authority.trust_policy_error_to_string error)

let graphql_body = {|{"query":"{ status { project paused } }"}|}

(* A workspace whose auth config requires a token, published as the running
   server's state, and the H2 gateway's own request handler serving it. *)
let with_gateway_and_switch ?(prepare_workspace=Fun.id) f =
  let base_path = Filename.temp_file "masc-h2-body-admission" "" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      rm_rf base_path)
    (fun () ->
      Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      Eio_context.with_test_env
        ~net:(Eio.Stdenv.net env)
        ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env)
        ~sw
        (fun () ->
          let workspace_path = prepare_workspace base_path in
          let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace_path in
          ignore
            (Masc.Workspace.init (Masc.Mcp_server.workspace_config state)
               ~agent_name:None);
          Server_auth.For_testing.restore_server_state (Some state);
          Auth.save_auth_config base_path
            { Masc_domain.default_auth_config with
              enabled = true
            ; require_token = true
            };
          let handler =
            Server_h2_gateway.make_request_handler ~routes:(Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock:(Eio.Stdenv.clock env))
              ~trust_policy:(trust_policy ()) ~sw ~request_sw:sw
              ~clock:(Eio.Stdenv.clock env) ~server_start_time:0.
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
          in
          f ~base_path ~clock:(Eio.Stdenv.clock env) ~sw handler))

let with_gateway ?prepare_workspace f =
  with_gateway_and_switch ?prepare_workspace
    (fun ~base_path ~clock ~sw:_ handler -> f ~base_path ~clock handler)

(* Exercise the actual H2 MCP admission path, including OAuth and session
   validation, so a response from an earlier refusal cannot satisfy the test. *)
let test_oauth_scope_refusal_preserves_request_ids () =
  Mirage_crypto_rng_unix.use_default ();
  let allowed_origin = "http://localhost:5173" in
  let rejected_origin = "https://example.invalid" in
  let policy =
    Server_auth_config.resolve
      { allow_anonymous_mutations = None
      ; loopback_dev_mutation_origins = Some allowed_origin
      }
    |> Result.get_ok
  in
  Server_auth.For_testing.restore_auth_config (Some policy);
  Fun.protect
    ~finally:(fun () -> Server_auth.For_testing.restore_auth_config None)
    (fun () ->
  with_gateway_and_switch @@ fun ~base_path ~clock ~sw handler ->
  let bootstrap =
    match Auth.create_token base_path ~agent_name:"h2-step-up" ~role:Masc_domain.Worker with
    | Ok (token, _) -> token
    | Error error -> fail (Masc_domain.masc_error_to_string error)
  in
  let redirect_uri = "http://127.0.0.1:43123/callback" in
  let resource = "http://localhost:8935/mcp" in
  let verifier = String.make 43 'v' in
  let client = Auth_oauth.register_client ~base_path ~client_name:(Some "h2-step-up")
      ~redirect_uris:[redirect_uri] |> Result.get_ok in
  let oauth_authority =
    match Server_request_authority.of_host_port ~host:listener_host ~port:listener_port with
    | Ok value -> value
    | Error `Malformed -> fail "fixture authority is invalid" in
  let exposes_challenge = function
    | None -> false
    | Some value ->
      String.split_on_char ',' value
      |> List.exists (fun name ->
           String.equal (String.lowercase_ascii (String.trim name)) "www-authenticate")
  in
  (* HTTP/1 calls this same builder with its captured authority after the
     asynchronous body read, when the request-local authority is unavailable. *)
  List.iter (fun (origin, admitted) ->
    let request = Httpun.Request.create `POST "/mcp"
        ~headers:(Httpun.Headers.of_list ["origin", origin]) in
    let cors = Server_mcp_transport_http.scope_challenge_cors_headers
        ~request_authority:oauth_authority request in
    check (option string) "H1 scope response reflects only an admitted origin"
      (if admitted then Some origin else None)
      (List.assoc_opt "access-control-allow-origin" cors);
    check bool "H1 scope response exposes the challenge only to admitted origin"
      admitted (exposes_challenge (List.assoc_opt "access-control-expose-headers" cors)))
    [allowed_origin, true; rejected_origin, false];
  check bool "ordinary CORS headers do not gain challenge exposure" false
    (exposes_challenge
       (List.assoc_opt "access-control-expose-headers" (Server_auth.cors_headers allowed_origin)));
  let form = Uri.encoded_of_query
    [ "response_type", ["code"]; "client_id", [client.client_id]
    ; "redirect_uri", [redirect_uri]; "resource", [resource]
    ; "scope", ["mcp:tools"]; "code_challenge", [Auth_oauth.pkce_s256 verifier]
    ; "code_challenge_method", ["S256"]; "bootstrap_token", [bootstrap]
    ; "decision", ["authorize"] ] in
  let location =
    match Server_oauth_service.authorize_post ~base_path ~authority:oauth_authority
        ~fetch_client_metadata:(fun _ -> Error "unexpected client document") ~body:form with
    | Ok (Server_oauth_service.Authorization_redirect location) -> location
    | Ok (Server_oauth_service.Authorization_form_error {message; _}) -> fail message
    | Error error -> fail (Auth_oauth.show_error error) in
  let code = match Uri.get_query_param (Uri.of_string location) "code" with
    | Some code -> code | None -> fail "authorization returned no code" in
  let oauth =
    match Auth_oauth.exchange_authorization_code ~base_path ~expected_resource:resource
        ~code ~client_id:client.client_id ~redirect_uri ~resource:(Some resource)
        ~code_verifier:verifier with
    | Ok pair -> pair.access_token
    | Error error -> fail (Auth_oauth.show_error error) in
  let protocol = Mcp_transport_protocol.default_protocol_version in
  let headers =
    [ "authorization", "Bearer " ^ oauth; "content-type", "application/json"
    ; "accept", "application/json, text/event-stream"; "mcp-protocol-version", protocol ] in
  let session = create_session ~clock ~handler () in
  let session_id = ref None in
  let writer, reply = open_request session ~headers
      ~on_response_headers:(fun response ->
        session_id := H2.Headers.get response.headers "mcp-session-id") "/mcp" in
  let initialize = Yojson.Safe.to_string
    (`Assoc ["jsonrpc", `String "2.0"; "id", `String "init";
      "method", `String "initialize"; "params", `Assoc [
        "protocolVersion", `String protocol; "capabilities", `Assoc [];
        "clientInfo", `Assoc ["name", `String "h2-step-up"; "version", `String "0"]]]) in
  send_whole initialize writer;
  check int "initialize succeeds" 200 (await_reply session reply).status;
  let session_id = match !session_id with
    | Some value -> value | None -> fail "initialize returned no session id" in
  List.iter (fun id ->
    let request = Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "id", id; "method", `String "tools/call";
        "params", `Assoc ["name", `String "masc_keeper_down"; "arguments", `Assoc []]]) in
    let response_headers = ref None in
    let writer, pending = open_request session
        ~headers:(("origin", allowed_origin) :: ("mcp-session-id", session_id) :: headers)
        ~on_response_headers:(fun response -> response_headers := Some response.headers)
        "/mcp" in
    send_whole request writer;
    let reply = await_reply session pending in
    check int "insufficient scope is HTTP 403" 403 reply.status;
    let response_headers = match !response_headers with
      | Some value -> value | None -> fail "scope response returned no headers" in
    check (option string) "scope challenge names the exact OAuth scope"
      (Some (Server_oauth_metadata.insufficient_scope_challenge oauth_authority Auth_oauth.Mcp_admin))
      (H2.Headers.get response_headers "www-authenticate");
    check (option string) "H2 scope response reflects the admitted origin"
      (Some allowed_origin)
      (H2.Headers.get response_headers "access-control-allow-origin");
    check bool "H2 scope response exposes the challenge to the admitted origin"
      true (exposes_challenge (H2.Headers.get response_headers "access-control-expose-headers"));
    let response = Yojson.Safe.from_string reply.body in
    check string "error echoes the request id" (Yojson.Safe.to_string id)
      (Yojson.Safe.to_string (Yojson.Safe.Util.member "id" response));
    check int "error is insufficient scope"
      (Mcp_error_code.to_wire_code Mcp_error_code.Insufficient_scope)
      Yojson.Safe.Util.(response |> member "error" |> member "code" |> to_int))
    [`Int 17; `String "call-한글"];
  (* 2026 requests carry routing headers and metadata on every request; no
     legacy session is needed. A continuation must still reach the existing
     no-resume refusal rather than the scope challenge. *)
  let modern_version = Mcp_transport_protocol.protocol_version_2026_07_28 in
  let modern_headers =
    [ "mcp-method", "tools/call"; "mcp-name", "masc_keeper_down" ]
    @ List.map (fun (name, value) ->
        if String.equal name "mcp-protocol-version" then name, modern_version
        else name, value) headers
  in
  let modern_call id extra =
    Yojson.Safe.to_string
      (`Assoc ["jsonrpc", `String "2.0"; "id", id; "method", `String "tools/call";
        "params", `Assoc
          ([ "name", `String "masc_keeper_down"
           ; "arguments", `Assoc [ "name", `String "audit-fixture-absent" ]
           ; "_meta", `Assoc
               [ Mcp_transport_protocol.protocol_version_meta_key, `String modern_version
               ; Mcp_transport_protocol.client_capabilities_meta_key, `Assoc [] ] ]
           @ extra)])
  in
  let post_modern body =
    let challenge = ref None in
    let writer, pending = open_request session ~headers:modern_headers
        ~on_response_headers:(fun response ->
          challenge := H2.Headers.get response.headers "www-authenticate") "/mcp" in
    send_whole body writer;
    let reply = await_reply session pending in
    reply, !challenge
  in
  let modern_id = `String "modern-admin-한글" in
  let reply, challenge = post_modern (modern_call modern_id []) in
  check int "2026 insufficient scope is HTTP 403" 403 reply.status;
  check (option string) "2026 challenge names the admin scope"
    (Some (Server_oauth_metadata.insufficient_scope_challenge oauth_authority Auth_oauth.Mcp_admin))
    challenge;
  let response = Yojson.Safe.from_string reply.body in
  check bool "2026 scope challenge echoes the request id" true
    Yojson.Safe.Util.(response |> member "id" = modern_id);
  check int "2026 scope challenge has insufficient-scope code"
    (Mcp_error_code.to_wire_code Mcp_error_code.Insufficient_scope)
    Yojson.Safe.Util.(response |> member "error" |> member "code" |> to_int);
  let continuation_id = `Int 21 in
  let reply, challenge =
    post_modern (modern_call continuation_id [ "requestState", `String "opaque" ]) in
  check int "2026 unknown continuation is HTTP 400" 400 reply.status;
  check (option string) "2026 continuation does not receive a scope challenge" None challenge;
  let response = Yojson.Safe.from_string reply.body in
  check bool "2026 continuation refusal echoes the request id" true
    Yojson.Safe.Util.(response |> member "id" = continuation_id);
  check int "2026 continuation retains invalid-params code" (-32602)
    Yojson.Safe.Util.(response |> member "error" |> member "code" |> to_int);
  check string "2026 continuation keeps the existing no-resume refusal"
    "This server has no resumable request for the supplied continuation"
    Yojson.Safe.Util.(response |> member "error" |> member "message" |> to_string);
  (* This registered admin tool is callable on Full but is not public MCP.
     Its worker refusal must reach the existing audit, not stop at step-up. *)
  let non_public_tool = "masc_keeper_clear" in
  let audit_config = Masc.Workspace.default_config base_path in
  let matching_audit_entries () =
    Masc.Audit_log.read_entries audit_config
    |> List.filter (fun (entry : Masc.Audit_log.audit_entry) ->
         entry.action = Masc.Audit_log.Custom "non_public_tool_call"
         && Yojson.Safe.Util.member "tool_name" entry.details = `String non_public_tool)
  in
  check int "no prior non-public fixture audit" 0
    (List.length (matching_audit_entries ()));
  let non_public_request = Yojson.Safe.to_string
    (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 20; "method", `String "tools/call";
      "params", `Assoc ["name", `String non_public_tool;
        "arguments", `Assoc ["name", `String "audit-fixture-absent";
                             "reason", `String "isolated OAuth permission test"]]]) in
  let non_public_challenge = ref None in
  let writer, pending = open_request session
      ~headers:(("mcp-session-id", session_id) :: headers)
      ~on_response_headers:(fun response ->
        non_public_challenge := H2.Headers.get response.headers "www-authenticate")
      "/mcp" in
  send_whole non_public_request writer;
  let non_public_reply = await_reply session pending in
  check int "non-public tool retains its tool-level response" 200 non_public_reply.status;
  check (option string) "non-public tool has no OAuth scope challenge" None !non_public_challenge;
  let non_public_response = Yojson.Safe.from_string non_public_reply.body in
  check bool "non-public refusal keeps the request id" true
    Yojson.Safe.Util.(non_public_response |> member "id" = `Int 20);
  check bool "non-public tool reports a permission failure" true
    Yojson.Safe.Util.(non_public_response |> member "result" |> member "isError" |> to_bool);
  check string "non-public tool retains insufficient-role classification" "insufficient_role"
    Yojson.Safe.Util.(non_public_response |> member "result" |> member "structuredContent"
                      |> member "auth_error_code" |> to_string);
  let audit_entry = match matching_audit_entries () with
    | [ entry ] -> entry
    | entries -> failf "expected one non-public tool audit, got %d" (List.length entries) in
  check string "non-public audit identifies the token owner" "h2-step-up" audit_entry.agent_id;
  check bool "non-public audit records failure" true
    (match audit_entry.outcome with Masc.Audit_log.Failure _ -> true | Masc.Audit_log.Success -> false);
  check string "non-public audit marks its surface" "non_public"
    Yojson.Safe.Util.(audit_entry.details |> member "surface" |> to_string);
  let rejected_request = Yojson.Safe.to_string
    (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 18; "method", `String "tools/call";
      "params", `Assoc ["name", `String "masc_keeper_down"; "arguments", `Assoc []]]) in
  let rejected_headers = ref None in
  let writer, pending = open_request session
      ~headers:(("origin", rejected_origin) :: ("mcp-session-id", session_id) :: headers)
      ~on_response_headers:(fun response -> rejected_headers := Some response.headers)
      "/mcp" in
  send_whole rejected_request writer;
  let rejected = await_reply session pending in
  check int "rejected origin is refused before dispatch" 403 rejected.status;
  let rejected_headers = match !rejected_headers with
    | Some value -> value | None -> fail "origin refusal returned no headers" in
  List.iter (fun name ->
    check (option string) ("rejected origin has no " ^ name) None
      (H2.Headers.get rejected_headers name))
    ["www-authenticate"; "access-control-allow-origin"; "access-control-expose-headers"];
  let rejected_response = Yojson.Safe.from_string rejected.body in
  check int "origin gate retains its invalid-request error"
    (Mcp_error_code.to_wire_code Mcp_error_code.Invalid_request)
    Yojson.Safe.Util.(rejected_response |> member "error" |> member "code" |> to_int);
  check bool "origin gate retains null id" true
    Yojson.Safe.Util.(rejected_response |> member "id" = `Null);
  (* The same registered admin tool is excluded by the managed profile, so a
     wider OAuth scope cannot unlock it; the ordinary profile refusal must win. *)
  let managed_session_id = ref None in
  let writer, pending = open_request session ~headers
      ~on_response_headers:(fun response ->
        managed_session_id := H2.Headers.get response.headers "mcp-session-id")
      "/mcp/managed" in
  send_whole initialize writer;
  check int "managed initialize succeeds" 200 (await_reply session pending).status;
  let managed_session_id = match !managed_session_id with
    | Some value -> value | None -> fail "managed initialize returned no session id" in
  let request = Yojson.Safe.to_string
    (`Assoc ["jsonrpc", `String "2.0"; "id", `Int 19; "method", `String "tools/call";
      "params", `Assoc ["name", `String "masc_keeper_down";
        "arguments", `Assoc ["name", `String "audit-fixture-absent"]]]) in
  let challenge = ref None in
  let writer, pending = open_request session
      ~headers:(("mcp-session-id", managed_session_id) :: headers)
      ~on_response_headers:(fun response ->
        challenge := H2.Headers.get response.headers "www-authenticate")
      "/mcp/managed" in
  send_whole request writer;
  let reply = await_reply session pending in
  check (option string) "managed refusal does not claim a wider scope fixes it" None !challenge;
  let response = Yojson.Safe.from_string reply.body in
  check int "managed profile keeps its method-not-found refusal"
    (Mcp_error_code.to_wire_code Mcp_error_code.Method_not_found)
    Yojson.Safe.Util.(response |> member "error" |> member "code" |> to_int);
  (* The token was issued for the same loopback resource above. A server moved
     to a public listener can still admit that authority explicitly, but OAuth
     discovery is unavailable there and must not be advertised in a 403. *)
  let public_policy =
    match Server_request_authority.make_trust_policy
        ~bind_host:"0.0.0.0" ~bind_port:listener_port
        ~explicit_base_url:(Some "http://localhost:8935") with
    | Ok policy -> policy
    | Error error -> fail (Server_request_authority.trust_policy_error_to_string error)
  in
  let public_handler =
    Server_h2_gateway.make_request_handler ~routes:(Server_routes_http.make_routes ~port:0 ~host:"127.0.0.1" ~sw ~clock:clock)
      ~trust_policy:public_policy ~sw ~request_sw:sw ~clock ~server_start_time:0.
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
  in
  let public_session = create_session ~clock ~handler:public_handler () in
  let discovery = exchange_on public_session ~meth:`GET
      ~send:(send_whole "") "/.well-known/oauth-protected-resource" in
  check int "public listener does not expose OAuth discovery" 404 discovery.status;
  let public_session_id = ref None in
  let writer, pending = open_request public_session ~headers
      ~on_response_headers:(fun response ->
        public_session_id := H2.Headers.get response.headers "mcp-session-id")
      "/mcp" in
  send_whole initialize writer;
  check int "public listener still accepts the OAuth token" 200
    (await_reply public_session pending).status;
  let public_session_id = match !public_session_id with
    | Some value -> value | None -> fail "public initialize returned no session id" in
  let challenge = ref None in
  let writer, pending = open_request public_session
      ~headers:(("mcp-session-id", public_session_id) :: headers)
      ~on_response_headers:(fun response ->
        challenge := H2.Headers.get response.headers "www-authenticate")
      "/mcp" in
  send_whole request writer;
  let reply = await_reply public_session pending in
  check (option string) "public listener does not advertise unavailable OAuth" None !challenge;
  check int "public listener retains the tool-level response" 200 reply.status;
  let response = Yojson.Safe.from_string reply.body in
  check bool "public listener refusal echoes the request id" true
    Yojson.Safe.Util.(response |> member "id" = `Int 19);
  check bool "public listener retains the permission refusal" true
    Yojson.Safe.Util.(response |> member "result" |> member "isError" |> to_bool);
  check string "public listener refusal retains insufficient-role classification"
    "insufficient_role"
    Yojson.Safe.Util.(response |> member "result" |> member "structuredContent"
                      |> member "auth_error_code" |> to_string))

(* The client starts the body and never ends it. With the gate ahead of the
   read the refusal arrives anyway; a gateway that read the body first would
   wait for its end, and the exchange would fail as stalled. *)
let test_unauthenticated_graphql_post_is_refused_before_its_body () =
  with_gateway @@ fun ~base_path:_ ~clock handler ->
  let reply =
    exchange ~clock ~handler
      ~headers:[ "content-type", "application/json" ]
      ~send:(fun writer -> H2.Body.Writer.write_string writer graphql_body)
      "/graphql"
  in
  check int "refused without a token" 401 reply.status

let test_authenticated_graphql_post_reads_its_body () =
  with_gateway @@ fun ~base_path ~clock handler ->
  let token =
    match
      Auth.create_token base_path ~agent_name:"h2-graphql-reader"
        ~role:Masc_domain.Worker
    with
    | Ok (token, _) -> token
    | Error error -> fail (Masc_domain.masc_error_to_string error)
  in
  let reply =
    exchange ~clock ~handler
      ~headers:
        [ "content-type", "application/json"
        ; "authorization", "Bearer " ^ token
        ]
      ~send:(send_whole graphql_body)
      "/graphql"
  in
  check int "answered" 200 reply.status;
  let project =
    Yojson.Safe.Util.(
      Yojson.Safe.from_string reply.body
      |> member "data" |> member "status" |> member "project")
  in
  check bool "the query in the body was executed" true (project <> `Null)

(* HTTP/1 serves GET /api/v1/board/sub-boards/<id> under with_public_read, so
   under strict auth a token-less read is refused. Over h2c the same path fell
   into the post-detail arm, which authorized nothing when no token was sent.
   The token-holding read must come back as the sub-board, not as a post
   lookup for "sub-boards/<id>". *)
let test_board_reads_require_a_token_under_strict_auth () =
  with_gateway @@ fun ~base_path ~clock handler ->
  Fun.protect ~finally:Masc.Board.reset_global_for_test
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key
    (Some base_path)
  @@ fun () ->
  Fun.protect ~finally:Masc.Board_dispatch.reset_for_test
  @@ fun () ->
  Masc.Board.reset_global_for_test ();
  Masc.Board_dispatch.reset_for_test ();
  Masc.Board_dispatch.init_jsonl ~recipient_lookup:Masc.Recipient_lookup.none_declared ();
  Masc_test_deps.with_process_env "MASC_HTTP_AUTH_STRICT" (Some "1")
  @@ fun () ->
  let slug = "h2-strict-read" in
  (match
     Masc.Board_dispatch.create_sub_board ~slug ~name:"Strict" ~description:""
       ~owner:"h2-board-reader" ~members:[] ()
   with
   | Ok _ -> ()
   | Error error -> fail (Board_tool.board_error_to_string error));
  let token =
    match
      Auth.create_token base_path ~agent_name:"h2-board-reader"
        ~role:Masc_domain.Worker
    with
    | Ok (token, _) -> token
    | Error error -> fail (Masc_domain.masc_error_to_string error)
  in
  let get ?token path =
    let headers =
      Option.fold ~none:[]
        ~some:(fun token -> [ "authorization", "Bearer " ^ token ])
        token
    in
    exchange ~clock ~handler ~meth:`GET ~headers ~send:H2.Body.Writer.close path
  in
  let sub_board_path = "/api/v1/board/sub-boards/" ^ slug in
  List.iter
    (fun path ->
      check int (path ^ " without a token") 401 (get path).status)
    [ sub_board_path; "/api/v1/board"; "/api/v1/board/some-post-id" ];
  let reply = get ~token sub_board_path in
  check int "sub-board detail with a token" 200 reply.status;
  check string "answered by the sub-board handler" slug
    Yojson.Safe.Util.(
      Yojson.Safe.from_string reply.body |> member "slug" |> to_string);
  check int "board list with a token" 200 (get ~token "/api/v1/board").status

let catalog_path = "/api/v1/lane-addons/package-catalog"
let preview_path = "/api/v1/lane-addons/package-preview"
let package_manifest title = Printf.sprintf {|id="catalog-fixture"
revision="1"
title=%S
image="fixture/image"
command=["observer"]
contributions=["observe"]
[resources]
cpus=0.5
memory_bytes=67108864
pids=16
max_reply_bytes=4096
|} title
let write_file path text = Out_channel.with_open_bin path (fun out -> output_string out text)
let reader_token base_path = match Auth.create_token base_path ~agent_name:"catalog-reader" ~role:Masc_domain.Worker with
  | Ok (token,_) -> token | Error error -> fail (Masc_domain.masc_error_to_string error)

let test_auth_refusals_preserve_next_authenticated_post () =
  with_gateway @@ fun ~base_path ~clock handler ->
  let token = reader_token base_path in
  let session = create_session ~clock ~config:continuity_config ~handler () in
  for _ = 1 to 3 do
    let reply = exchange_on session
      ~headers:[ "content-type", "application/json" ]
      ~send:(send_whole continuity_body) "/graphql" in
    check int "tokenless upload refused" 401 reply.status
  done;
  let reply = exchange_on session
    ~headers:[ "content-type", "application/json"; "authorization", "Bearer " ^ token ]
    ~send:(send_whole (String.make 40000 ' ' ^ graphql_body)) "/graphql" in
  check int "authenticated POST completes on the same connection" 200 reply.status;
  let project = Yojson.Safe.Util.(Yojson.Safe.from_string reply.body
    |> member "data" |> member "status" |> member "project") in
  check bool "the next POST's query was executed" true (project <> `Null)

let test_oauth_refusals_preserve_next_registration () =
  with_gateway @@ fun ~base_path:_ ~clock handler ->
  let session = create_session ~clock ~config:continuity_config ~handler () in
  let headers = [ "content-type", "application/json" ] in
  for _ = 1 to 3 do
    let reply = exchange_on session ~headers
      ~send:(send_whole continuity_body) "/oauth/register" in
    check int "OAuth oversize refused" 400 reply.status;
    check string "OAuth body limit produced the refusal" "request body is too large"
      Yojson.Safe.Util.(Yojson.Safe.from_string reply.body
        |> member "error_description" |> to_string)
  done;
  let body = String.make 10000 ' ' ^
    {|{"redirect_uris":["http://127.0.0.1:48765/callback"]}|} in
  let reply = exchange_on session ~headers ~send:(send_whole body) "/oauth/register" in
  check int "next registration completes on the same connection" 201 reply.status;
  let client_id = Yojson.Safe.Util.(Yojson.Safe.from_string reply.body
    |> member "client_id" |> to_string) in
  check bool "registration body was executed" true (String.length client_id > 0)

let get_h2 ~clock ~handler ?token path =
  let headers = Option.fold ~none:[] ~some:(fun token -> ["authorization","Bearer " ^ token]) token in
  exchange ~clock ~handler ~meth:`GET ~headers ~send:H2.Body.Writer.close path
let query path key value = path ^ "?" ^ Uri.encoded_of_query [key,[value]]

let test_package_h2_read_auth_and_payloads () = with_gateway (fun ~base_path ~clock handler ->
  let manifest = Filename.concat base_path "lane.toml" in
  write_file manifest (package_manifest "HTTP2 package");
  let token = reader_token base_path in
  List.iter (fun path ->
    check int "catalog and preview require a token" 401 (get_h2 ~clock ~handler path).status;
    check int "invalid bearer is refused" 401 (get_h2 ~clock ~handler ~token:"invalid-token" path).status)
    [catalog_path;query preview_path "manifest_path" manifest];
  let catalog = get_h2 ~clock ~handler ~token catalog_path in
  check int "authenticated H2 catalog" 200 catalog.status;
  check string "catalog title is parsed from manifest" "HTTP2 package"
    Yojson.Safe.Util.(Yojson.Safe.from_string catalog.body |> member "entries" |> to_list |> List.hd |> member "title" |> to_string);
  let preview = get_h2 ~clock ~handler ~token (query preview_path "manifest_path" "lane.toml") in
  check int "authenticated H2 preview" 200 preview.status;
  check string "preview title is parsed from manifest" "HTTP2 package"
    Yojson.Safe.Util.(Yojson.Safe.from_string preview.body |> member "package" |> member "title" |> to_string);
  List.iter (fun path -> check int "same strict query contract" 400 (get_h2 ~clock ~handler ~token path).status)
    [catalog_path ^ "?unknown=x";catalog_path ^ "?directory=.&directory=.";preview_path;preview_path ^ "?manifest_path=lane.toml&unexpected=x"])

let git root args =
  let command = "git -C " ^ Filename.quote root ^ " " ^ String.concat " " (List.map Filename.quote args) ^ " >/dev/null 2>&1" in
  check int "Git worktree fixture setup" 0 (Sys.command command)
let prepare_linked_workspace root =
  git root ["init"];
  write_file (Filename.concat root "lane.toml") (package_manifest "Main checkout package");
  git root ["add";"lane.toml"];
  git root ["-c";"user.name=fixture";"-c";"user.email=fixture@example.invalid";"commit";"-m";"fixture"];
  let active = Filename.concat root "active-checkout" in
  git root ["worktree";"add";"-b";"active-fixture";active];
  write_file (Filename.concat active "lane.toml") (package_manifest "Active branch package");
  active
let test_package_active_worktree_payloads () =
  with_gateway ~prepare_workspace:prepare_linked_workspace (fun ~base_path ~clock handler ->
    let state = match Server_auth.For_testing.snapshot_server_state () with Some state -> state | None -> fail "state missing" in
    let config = Masc.Mcp_server.workspace_config state in
    let active = Unix.realpath (Filename.concat base_path "active-checkout") in
    check string "workspace config retains linked checkout" active (Unix.realpath config.workspace_path);
    check string "workspace config shares main state root" (Unix.realpath base_path) config.base_path;
    let catalog = Server_routes_http_routes_lane_addons.package_catalog_payload state [] |> Result.get_ok in
    check string "catalog starts at active checkout" active Yojson.Safe.Util.(member "directory" catalog |> to_string);
    let preview fields = Server_routes_http_routes_lane_addons.package_preview_payload state fields in
    let result = preview ["manifest_path","lane.toml"] |> Result.get_ok in
    check string "relative preview reads active branch metadata" "Active branch package"
      Yojson.Safe.Util.(member "package" result |> member "title" |> to_string);
    Unix.symlink (Filename.concat base_path "lane.toml") (Filename.concat active "outside.toml");
    List.iter (fun path -> check bool "preview cannot escape active worktree" true
      (Result.is_error (preview ["manifest_path",path])))
      [Filename.concat base_path "lane.toml";"../lane.toml";"outside.toml"];
    let token = reader_token base_path in
    List.iter (fun path -> check int "H2 preview enforces the active worktree boundary" 400
      (get_h2 ~clock ~handler ~token (query preview_path "manifest_path" path)).status)
      [Filename.concat base_path "lane.toml";"../lane.toml";"outside.toml"];
    check int "H2 catalog cannot browse the main checkout" 400
      (get_h2 ~clock ~handler ~token (query catalog_path "directory" base_path)).status;
    let response = get_h2 ~clock ~handler ~token catalog_path in
    check int "H2 serves linked worktree catalog" 200 response.status;
    check string "H2 active directory equals H1 payload" active
      Yojson.Safe.Util.(Yojson.Safe.from_string response.body |> member "directory" |> to_string);
    let response = get_h2 ~clock ~handler ~token (query preview_path "manifest_path" "lane.toml") in
    check int "H2 accepts active-worktree preview" 200 response.status;
    check string "H2 active preview title" "Active branch package"
      Yojson.Safe.Util.(Yojson.Safe.from_string response.body |> member "package" |> member "title" |> to_string))

let with_request_scope test () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    Eio.Time.with_timeout_exn clock case_timeout_s (fun () ->
      Eio.Switch.run (fun sw ->
        let resources=Server_h2_response_resources.create
          ~max_pending_bytes:H2_response_limits.default_max_pending_bytes in
        Server_h2_response_resources.with_request resources ~sw (fun () -> test ~clock sw))))

let () =
  run "H2 request body admission"
    [ ("OAuth step-up", [
        test_case "scope refusal echoes numeric and string request ids" `Quick
          test_oauth_scope_refusal_preserves_request_ids])
    ; ("package catalog", [
        test_case "H2 read auth and payload parity" `Quick test_package_h2_read_auth_and_payloads;
        test_case "active linked worktree controls discovery and preview" `Quick test_package_active_worktree_payloads])
    ; ( "body ceiling"
      , [ test_case "a declared length over the ceiling is refused before any byte"
            `Quick
            (with_request_scope test_declared_length_over_the_ceiling_is_refused_before_any_byte)
        ; test_case "a streamed body over the ceiling is refused" `Quick
            (with_request_scope test_streamed_body_over_the_ceiling_is_refused)
        ; test_case "a body at the ceiling is delivered whole" `Quick
            (with_request_scope test_body_at_the_ceiling_is_delivered_whole)
        ; test_case "a declared length at the ceiling is delivered whole"
            `Quick
            (with_request_scope test_declared_length_at_the_ceiling_is_delivered_whole)
        ] )
    ; ( "graphql read gate"
      , [ test_case "an unauthenticated POST is refused before its body" `Quick
            test_unauthenticated_graphql_post_is_refused_before_its_body
        ; test_case "an authenticated POST still reads its body" `Quick
            test_authenticated_graphql_post_reads_its_body
        ] )
    ; ( "body lifecycle and connection continuity"
      , [ test_case "repeated declared 413 uploads preserve the next POST" `Quick
            (with_request_scope test_declared_refusals_preserve_connection_credit)
        ; test_case "streamed 413 preserves the next POST" `Quick
            (with_request_scope test_streamed_refusal_preserves_connection_credit)
        ; test_case "non-decimal Content-Length is refused without delivery" `Quick
            (with_request_scope
              (test_malformed_headers_preserve_next_post [ "content-length", "0x10" ]))
        ; test_case "conflicting Content-Length is refused without delivery" `Quick
            (with_request_scope
              (test_malformed_headers_preserve_next_post
                [ "content-length", "2"; "content-length", "3" ]))
        ; test_case "short fixed body is refused without delivery" `Quick
            (with_request_scope
              (test_malformed_body_preserves_next_post [ "content-length", "10" ] "abc"))
        ; test_case "missing fixed body is refused without delivery" `Quick
            (with_request_scope
              (test_malformed_body_preserves_next_post [ "content-length", "10" ] ""))
        ; test_case "stream error after a prefix prevents delivery" `Quick
            (with_request_scope (test_stream_error_prevents_body_delivery ~at_eof:false))
        ; test_case "stream error after EOF before dispatch prevents delivery" `Quick
            (with_request_scope (test_stream_error_prevents_body_delivery ~at_eof:true))
        ; test_case "reset after EOF before dispatch prevents delivery" `Quick
            (with_request_scope test_reset_after_eof_prevents_body_delivery)
        ; test_case "repeated 401 uploads preserve authenticated GraphQL POST" `Quick
            test_auth_refusals_preserve_next_authenticated_post
        ; test_case "repeated OAuth oversize uploads preserve registration POST" `Quick
            test_oauth_refusals_preserve_next_registration
        ] )
    ; ( "board read gate"
      , [ test_case "strict auth refuses token-less Board reads" `Quick
            test_board_reads_require_a_token_under_strict_auth
        ] )
    ]
