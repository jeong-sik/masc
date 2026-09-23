(* HTTP/2 requests are admitted on the terms HTTP/1 applies: the same body
   size ceiling, on POST /graphql the read gate before the body is read, and
   on the Board reads the same strict-mode public-read gate.
   Every case runs a real H2 exchange in memory, an h2 client connection
   pumped against a server connection, so what is checked is what a peer
   sees on the wire. *)

open Alcotest

module Helpers = Server_h2_gateway_helpers

(* The request's :authority and the gateway's trust policy name the same
   listener; a mismatch would make the gateway refuse every request as an
   untrusted authority. *)
let listener_host = "localhost"

let listener_port = 8935

let authority = Printf.sprintf "%s:%d" listener_host listener_port

let max_bytes = Masc.Http_server_eio.Request.max_body_bytes

type reply = { status : int; body : string }

(* Bytes one side wrote that the other side's [read] has not taken yet. h2
   reads whole frames, and a frame can be split across iovecs or writes, so
   the unconsumed tail is offered again together with the next bytes. *)
type lane = { mutable pending : string }

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
    | `Yield | `Close _ -> progressed
  in
  drain false

(* [send] writes the request body. A [send] that leaves the writer open is a
   client still uploading: the exchange then completes only if the server
   answers without waiting for the end of the body. A server that waits stops
   making progress, and the pump fails instead of hanging. *)
let exchange ~handler ?(meth = `POST) ?(headers = []) ~send target =
  let status = ref None in
  let body = Buffer.create 256 in
  let complete = ref false in
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> fail "H2 connection error") ()
  in
  let request =
    H2.Request.create ~scheme:"http" meth target
      ~headers:(H2.Headers.of_list ((":authority", authority) :: headers))
  in
  (* h2 holds HEADERS back until the first body write unless told otherwise,
     and a case that sends no body would never reach the server. *)
  let writer =
    H2.Client_connection.request client ~flush_headers_immediately:true request
      ~error_handler:(fun _ -> fail "H2 stream error")
      ~response_handler:(fun response reader ->
        status := Some (H2.Status.to_code response.H2.Response.status);
        let rec consume () =
          H2.Body.Reader.schedule_read reader
            ~on_eof:(fun () -> complete := true)
            ~on_read:(fun buffer ~off ~len ->
              Buffer.add_string body (Bigstringaf.substring buffer ~off ~len);
              consume ())
        in
        consume ())
  in
  send writer;
  let server = H2.Server_connection.create handler in
  let to_server = { pending = "" } in
  let to_client = { pending = "" } in
  let rec pump () =
    let sent =
      transfer to_server
        (fun () -> H2.Client_connection.next_write_operation client)
        (H2.Client_connection.report_write_result client)
        (H2.Server_connection.read server)
    in
    let received =
      transfer to_client
        (fun () -> H2.Server_connection.next_write_operation server)
        (H2.Server_connection.report_write_result server)
        (H2.Client_connection.read client)
    in
    if !complete then ()
    else if sent || received then pump ()
    else fail "H2 exchange stalled before the response completed"
  in
  pump ();
  match !status with
  | Some status -> { status; body = Buffer.contents body }
  | None -> fail "the response carried no headers"

(* Closes the writer only once every byte has been handed to the connection.
   h2 sends END_STREAM for a closed writer whenever its send window is empty,
   even with bytes still unsent (Respd.flush_request_body), so closing right
   after the write cut the body at the 65535-byte initial window before the
   server's SETTINGS could widen it. *)
let send_whole payload writer =
  H2.Body.Writer.write_string writer payload;
  H2.Body.Writer.flush writer (fun _ -> H2.Body.Writer.close writer)

(* Records what the body reader handed over and answers 200, so a case tells a
   delivered body from a refused one and checks how much arrived. *)
let ceiling_handler delivered reqd =
  Helpers.h2_read_body reqd (fun body ->
    delivered := Some (String.length body);
    Helpers.h2_respond_text reqd "delivered")

(* Nothing is sent after the headers. A reader that waited for the declared
   bytes would stall the exchange. *)
let test_declared_length_over_the_ceiling_is_refused_before_any_byte () =
  let delivered = ref None in
  let reply =
    exchange ~handler:(ceiling_handler delivered)
      ~headers:[ "content-length", string_of_int (max_bytes + 1) ]
      ~send:(fun _writer -> ())
      "/upload"
  in
  check int "refused as too large" 413 reply.status;
  check (option int) "the callback never ran" None !delivered

let test_streamed_body_over_the_ceiling_is_refused () =
  let delivered = ref None in
  let reply =
    exchange ~handler:(ceiling_handler delivered)
      ~send:(send_whole (String.make (max_bytes + 1) 'x'))
      "/upload"
  in
  check int "refused as too large" 413 reply.status;
  check (option int) "the callback never ran" None !delivered

let test_body_at_the_ceiling_is_delivered_whole () =
  let delivered = ref None in
  let reply =
    exchange ~handler:(ceiling_handler delivered)
      ~send:(send_whole (String.make max_bytes 'x'))
      "/upload"
  in
  check int "admitted" 200 reply.status;
  check (option int) "every byte reached the callback" (Some max_bytes)
    !delivered

(* The declared-length check and the streamed check are separate branches;
   this one pins the first at the boundary. *)
let test_declared_length_at_the_ceiling_is_delivered_whole () =
  let delivered = ref None in
  let reply =
    exchange ~handler:(ceiling_handler delivered)
      ~headers:[ "content-length", string_of_int max_bytes ]
      ~send:(send_whole (String.make max_bytes 'x'))
      "/upload"
  in
  check int "admitted" 200 reply.status;
  check (option int) "every byte reached the callback" (Some max_bytes)
    !delivered

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
let with_gateway f =
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
          let state = Masc.Mcp_server.For_testing.create_state ~base_path in
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
            Server_h2_gateway.make_request_handler
              ~trust_policy:(trust_policy ()) ~sw
              ~clock:(Eio.Stdenv.clock env) ~server_start_time:0.
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
          in
          f ~base_path handler))

(* The client starts the body and never ends it. With the gate ahead of the
   read the refusal arrives anyway; a gateway that read the body first would
   wait for its end, and the exchange would fail as stalled. *)
let test_unauthenticated_graphql_post_is_refused_before_its_body () =
  with_gateway @@ fun ~base_path:_ handler ->
  let reply =
    exchange ~handler
      ~headers:[ "content-type", "application/json" ]
      ~send:(fun writer -> H2.Body.Writer.write_string writer graphql_body)
      "/graphql"
  in
  check int "refused without a token" 401 reply.status

let test_authenticated_graphql_post_reads_its_body () =
  with_gateway @@ fun ~base_path handler ->
  let token =
    match
      Auth.create_token base_path ~agent_name:"h2-graphql-reader"
        ~role:Masc_domain.Worker
    with
    | Ok (token, _) -> token
    | Error error -> fail (Masc_domain.masc_error_to_string error)
  in
  let reply =
    exchange ~handler
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
  with_gateway @@ fun ~base_path handler ->
  Fun.protect ~finally:Masc.Board.reset_global_for_test
  @@ fun () ->
  Masc_test_deps.with_process_env Env_config_core.base_path_env_key
    (Some base_path)
  @@ fun () ->
  Fun.protect ~finally:Masc.Board_dispatch.reset_for_test
  @@ fun () ->
  Masc.Board.reset_global_for_test ();
  Masc.Board_dispatch.reset_for_test ();
  Masc.Board_dispatch.init_jsonl ();
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
    exchange ~handler ~meth:`GET ~headers ~send:H2.Body.Writer.close path
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

let () =
  run "H2 request body admission"
    [ ( "body ceiling"
      , [ test_case "a declared length over the ceiling is refused before any byte"
            `Quick
            test_declared_length_over_the_ceiling_is_refused_before_any_byte
        ; test_case "a streamed body over the ceiling is refused" `Quick
            test_streamed_body_over_the_ceiling_is_refused
        ; test_case "a body at the ceiling is delivered whole" `Quick
            test_body_at_the_ceiling_is_delivered_whole
        ; test_case "a declared length at the ceiling is delivered whole"
            `Quick
            test_declared_length_at_the_ceiling_is_delivered_whole
        ] )
    ; ( "graphql read gate"
      , [ test_case "an unauthenticated POST is refused before its body" `Quick
            test_unauthenticated_graphql_post_is_refused_before_its_body
        ; test_case "an authenticated POST still reads its body" `Quick
            test_authenticated_graphql_post_reads_its_body
        ] )
    ; ( "board read gate"
      , [ test_case "strict auth refuses token-less Board reads" `Quick
            test_board_reads_require_a_token_under_strict_auth
        ] )
    ]
