(* HTTP/2 requests are admitted on the terms HTTP/1 applies: the same body
   size ceiling, on POST /graphql the read gate before the body is read, and
   on the Board reads the same strict-mode public-read gate.
   Every case runs a real H2 exchange in memory, an h2 client connection
   pumped against a server connection, so what is checked is what a peer
   sees on the wire. *)

open Alcotest

let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

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

(* [send] writes the request body. A [send] that leaves the writer open is a
   client still uploading: the exchange then completes only if the server
   answers without waiting for the end of the body. A server that waits stops
   making progress, and the pump fails instead of hanging once
   [exchange_stall_timeout_s] passes without server output. *)
let exchange ~clock ~handler ?(meth = `POST) ?(headers = []) ~send target =
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
  (* h2's Eio runtime waits the same way: [yield_writer] runs its callback
     once a response, a body chunk or a stream end is queued. The server's
     [yield_reader] resumes at once in h2 0.13, so reads never wait. *)
  let await_server_output () =
    let ready, wake = Eio.Promise.create () in
    H2.Server_connection.yield_writer server (fun () ->
      Eio.Promise.resolve wake ());
    Eio.Promise.await ready
  in
  let stalled () = fail "H2 exchange stalled before the response completed" in
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
    else
      match sent, received with
      | Moved, _ | _, Moved -> pump ()
      | (Waiting | Closed), Waiting ->
        await_server_output ();
        pump ()
      | (Waiting | Closed), Closed -> stalled ()
  in
  (match
     Eio.Time.with_timeout clock exchange_stall_timeout_s (fun () ->
       Ok (pump ()))
   with
   | Ok () -> ()
   | Error `Timeout -> stalled ());
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
let with_gateway ?(prepare_workspace=Fun.id) f =
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
            Server_h2_gateway.make_request_handler
              ~trust_policy:(trust_policy ()) ~sw ~request_sw:sw
              ~clock:(Eio.Stdenv.clock env) ~server_start_time:0.
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 54321))
          in
          f ~base_path ~clock:(Eio.Stdenv.clock env) handler))

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
      Eio.Switch.run (test ~clock)))

let () =
  run "H2 request body admission"
    [ ("package catalog", [
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
    ; ( "board read gate"
      , [ test_case "strict auth refuses token-less Board reads" `Quick
            test_board_reads_require_a_token_under_strict_auth
        ] )
    ]
