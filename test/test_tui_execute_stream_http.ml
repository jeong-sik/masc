(* The Terminal tab's request for a Keeper's Execute output stream, over a real
   loopback socket against a server that answers the way the dashboard route
   and its workspace check do: a stream that carries the workspace receipt, a
   stream that does not, and a refusal.

   The route and its check are not run here; what is run is the terminal's
   side: the URL it asks for, which responses it reads, and which it refuses
   before it reads a byte. *)

module EO = Dashboard_execute_output
module Http = Masc_tui_http

let receipt_name = "x-masc-workspace-read"
let receipt = receipt_name, "matched-v1"

let identity : Masc.Tui_decode.server_identity =
  let module Decode = Masc.Tui_decode in
  { sid_version = "test"
  ; sid_binary_commit = "test"
  ; sid_binary_commit_age_s = None
  ; sid_base_path = Decode.Canonical_path.of_path "/owned-workspace"
  ; sid_masc_root = Decode.Canonical_path.of_path "/owned-workspace/.masc"
  ; sid_executable_in_worktree = None
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
  }
;;

(* What the route writes first on a connection to a Keeper that has run one
   command. *)
let first_frames () =
  EO.reset_for_testing ();
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:1 ~task_id:None ~command:"run";
  EO.append_stream_chunk ~keeper_name:"alpha" ~stream_id:1 ~stream:`Stdout "one\n";
  match EO.subscribe ~keeper_name:"alpha" with
  | None -> Alcotest.fail "the server gave no subscriber"
  | Some subscriber ->
    Fun.protect
      ~finally:(fun () -> EO.unsubscribe subscriber)
      (fun () -> "retry: 1500\n\n" ^ EO.sse_frame (EO.initial_event_json subscriber))
;;

(* The headers the route sets on its stream, and whatever receipts the test
   adds to them. The route keeps its connection alive and ends a stream only
   when the server stops; this one closes the connection after its frames, so a
   client reads to the end without waiting out its idle limit. *)
let stream_response ~receipts frames reqd =
  let headers =
    Httpun.Headers.of_list
      ([ "content-type", "text/event-stream"
       ; "cache-control", "private, no-store"
       ; "connection", "close"
       ; "x-accel-buffering", "no"
       ]
       @ receipts)
  in
  let body = Httpun.Reqd.respond_with_streaming reqd (Httpun.Response.create ~headers `OK) in
  List.iter (fun frame -> Httpun.Body.Writer.write_string body frame) frames;
  Httpun.Body.Writer.close body
;;

let json_response ~status body reqd =
  let headers =
    Httpun.Headers.of_list
      [ "content-type", "application/json"
      ; "content-length", string_of_int (String.length body)
      ]
  in
  Httpun.Reqd.respond_with_string reqd (Httpun.Response.create ~headers status) body
;;

(* The accept loop of the real server on a loopback port, with [handler] in
   place of its router. *)
let with_server env ~handler body =
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let socket =
      Eio.Net.listen
        ~reuse_addr:true
        ~backlog:8
        ~sw
        (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port =
      match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "the test listens on TCP"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Server_bootstrap_http.serve
        ~sw
        ~clock
        ~socket
        ~addr_label:"execute stream test"
        ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
          handler gluten_reqd.Gluten.Reqd.reqd);
      `Stop_daemon);
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () -> body ~port)))
;;

let observe env ~port ?(keeper = "alpha") ~on_chunk () =
  Http.observe_execute_output_stream
    ~clock:(Eio.Stdenv.clock env)
    ~expected_workspace:identity
    ~host:"127.0.0.1"
    ~port
    ~keeper
    ~on_chunk
;;

let with_env test () = Eio_main.run (fun env -> test env)

let test_an_attested_stream_is_read_to_its_end env =
  let frames = first_frames () in
  let target = ref "" in
  let handler reqd =
    target := (Httpun.Reqd.request reqd).Httpun.Request.target;
    stream_response ~receipts:[ receipt ] [ frames ] reqd
  in
  with_server env ~handler (fun ~port ->
    let received = Buffer.create 256 in
    (match observe env ~port ~on_chunk:(Buffer.add_string received) () with
     | Ok () -> ()
     | Error (Http.Http_refused { status; detail }) ->
       Alcotest.failf "the stream was refused (%d): %s" status detail
     | Error (Http.Transport_failed detail) ->
       Alcotest.failf "the transport failed: %s" detail);
    Alcotest.(check string) "the bytes the server wrote" frames (Buffer.contents received);
    let uri = Uri.of_string !target in
    Alcotest.(check string) "the route" "/api/v1/dashboard/execute-output/alpha" (Uri.path uri);
    Alcotest.(check (option string))
      "bound to the base path"
      (Some "/owned-workspace")
      (Uri.get_query_param uri "expected_base_path");
    Alcotest.(check (option string))
      "and to the masc root"
      (Some "/owned-workspace/.masc")
      (Uri.get_query_param uri "expected_masc_root"))
;;

(* A server that does not know the two fields answers for whichever workspace
   it holds, and says nothing about it. The stream is not read. *)
let test_a_stream_without_the_receipt_is_refused_before_a_byte_is_read env =
  List.iter
    (fun (label, receipts) ->
       let handler = stream_response ~receipts [ first_frames () ] in
       with_server env ~handler (fun ~port ->
         let chunks = ref 0 in
         match observe env ~port ~on_chunk:(fun _ -> incr chunks) () with
         | Error (Http.Http_refused { status; detail }) ->
           Alcotest.(check int) (label ^ ": the status is the stream's") 200 status;
           Alcotest.(check bool)
             (label ^ ": it says the read was not attested")
             true
             (String_util.contains_substring detail "attest");
           Alcotest.(check int) (label ^ ": nothing was read") 0 !chunks
         | Error (Http.Transport_failed detail) ->
           Alcotest.failf "%s: the transport failed instead: %s" label detail
         | Ok () -> Alcotest.failf "%s: the stream was accepted" label))
    [ "no receipt", []
    ; "another value", [ receipt_name, "matched-v0" ]
    ; "the receipt twice", [ receipt; receipt ]
    ]
;;

let test_a_workspace_mismatch_is_refused_with_its_status env =
  let handler =
    json_response
      ~status:`Conflict
      {|{"error_code":"workspace_precondition_failed","error":"workspace precondition failed"}|}
  in
  with_server env ~handler (fun ~port ->
    let chunks = ref 0 in
    match observe env ~port ~on_chunk:(fun _ -> incr chunks) () with
    | Error (Http.Http_refused { status; detail }) ->
      Alcotest.(check int) "the status" 409 status;
      Alcotest.(check bool)
        "it names the stream that was refused"
        true
        (String_util.contains_substring detail "Execute output stream");
      Alcotest.(check int) "nothing was read" 0 !chunks
    | Error (Http.Transport_failed detail) ->
      Alcotest.failf "the transport failed instead: %s" detail
    | Ok () -> Alcotest.fail "a refusal was read as a stream")
;;

let test_a_keeper_name_is_encoded_in_the_path env =
  let target = ref "" in
  let handler reqd =
    target := (Httpun.Reqd.request reqd).Httpun.Request.target;
    json_response ~status:`Not_found "{}" reqd
  in
  with_server env ~handler (fun ~port ->
    ignore
      (observe env ~port ~keeper:"a b" ~on_chunk:ignore () : (unit, Http.observer_error) result);
    Alcotest.(check string)
      "the path"
      "/api/v1/dashboard/execute-output/a%20b"
      (List.hd (String.split_on_char '?' !target)))
;;

let () =
  let case name test = Alcotest.test_case name `Quick (with_env test) in
  Alcotest.run
    "Tui_execute_stream_http"
    [ ( "the request"
      , [ case
            "an attested stream is read to its end"
            test_an_attested_stream_is_read_to_its_end
        ; case
            "a keeper name is encoded in the path"
            test_a_keeper_name_is_encoded_in_the_path
        ] )
    ; ( "what is refused"
      , [ case
            "a stream without the receipt is refused before a byte is read"
            test_a_stream_without_the_receipt_is_refused_before_a_byte_is_read
        ; case
            "a workspace mismatch is refused with its status"
            test_a_workspace_mismatch_is_refused_with_its_status
        ] )
    ]
;;
