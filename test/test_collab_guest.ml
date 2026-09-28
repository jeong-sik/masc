(** Stack 6 tests for RFC-0471: guest link/relay resolution, the
    welcome/snapshot/live join assembly, the terminal rendering, and a
    loopback dial against a scripted WS peer. *)

open Alcotest

module Join = Collab_guest_join
module Frame = Collab_frame
module Link = Collab_link
module Session = Collab_guest_session

let room = Link.generate ()

let view_link = Link.format_link room Link.View
let control_link = Link.format_link room Link.Control

let web_of link base = base ^ "/#" ^ link

let target_exn ~link ~relay =
  match Join.resolve ~link ~relay with
  | Error err -> fail (Join.resolve_error_to_string err)
  | Ok target -> target
;;

let test_resolve_terminal_link () =
  let target = target_exn ~link:view_link ~relay:(Some "ws://127.0.0.1:1777") in
  check string "room" room.Link.id target.Join.room_id;
  check bool "view" true (target.Join.capability = Link.View);
  check (option string) "no token" None target.Join.write_token;
  check bool "plain" false target.Join.ws_secure;
  check string "host" "127.0.0.1" target.Join.ws_host;
  check int "port" 1777 target.Join.ws_port;
  let control = target_exn ~link:control_link ~relay:(Some "wss://r.test") in
  check bool "control" true (control.Join.capability = Link.Control);
  check bool "secure" true control.Join.ws_secure;
  check int "default 443" 443 control.Join.ws_port;
  (match control.Join.write_token with
   | None -> fail "control token missing"
   | Some token -> check int "token bytes" 16 (String.length token));
  let http = target_exn ~link:view_link ~relay:(Some "http://r.test") in
  check bool "http maps to ws" false http.Join.ws_secure;
  check int "default 80" 80 http.Join.ws_port
;;

let test_resolve_web_link_and_errors () =
  let target =
    target_exn ~link:(web_of view_link "https://relay.test:8443") ~relay:None
  in
  check string "base host" "relay.test" target.Join.ws_host;
  check int "base port" 8443 target.Join.ws_port;
  check bool "base secure" true target.Join.ws_secure;
  let overridden =
    target_exn
      ~link:(web_of view_link "https://relay.test:8443")
      ~relay:(Some "ws://127.0.0.1:1")
  in
  check string "override wins" "127.0.0.1" overridden.Join.ws_host;
  check bool "terminal needs relay" true
    (Join.resolve ~link:view_link ~relay:None = Error Join.Relay_missing);
  check bool "bad link" true
    (Result.is_error (Join.resolve ~link:"nope" ~relay:(Some "ws://h:1")));
  check bool "bad relay" true
    (Result.is_error (Join.resolve ~link:view_link ~relay:(Some "gopher://h")))
;;

let test_resource_matches_route_parser () =
  let target = target_exn ~link:view_link ~relay:(Some "ws://127.0.0.1:1777") in
  let resource = Join.resource target in
  match Collab_wire.parse_request_target ~target:resource with
  | Error _ -> fail ("route parser refused " ^ resource)
  | Ok (room_id, role) ->
    check string "room roundtrips" room.Link.id room_id;
    check bool "guest role" true (role = Collab_wire.Guest)
;;

let welcome_frame =
  Frame.Welcome
    { Frame.proto = Collab_wire.proto_version
    ; header = { Frame.keeper = "imp"; operation = "op-1" }
    ; state = { Frame.active = true; guests = 2 }
    ; entry_count = 2
    ; read_only = true
    }
;;

let chunk_frame ~final rows = Frame.Snapshot_chunk { Frame.entries = rows; final }

let entry_frame ~op ~op_seq event =
  Frame.Entry { Frame.seq = 1; op; op_seq; ts = 0.; event }
;;

let row_json ~seq event =
  Masc.Keeper_chat_event_log.journaled_event_to_json
    { Masc.Keeper_chat_event_log.seq; ts = 0.; event }
;;


let test_join_buffers_and_dedupes () =
  let join = Join.create () in
  let open Masc.Keeper_chat_events in
  let early =
    entry_frame ~op:"op-1" ~op_seq:0
      (Masc.Keeper_chat_event_log.keeper_chat_event_to_json (Text_delta "early"))
  in
  check (list (testable Fmt.nop ( = ))) "pre-welcome buffered" [] (Join.feed join early);
  let state_events = Join.feed join welcome_frame in
  (match state_events with
   | [ Join.State state ] ->
     check bool "active" true state.Frame.active;
     check int "guests" 2 state.Frame.guests
   | _ -> fail "welcome emits state");
  (* Snapshot rows stream as they land; the final chunk flushes the
     buffered entry, and the overlap (op-1, seq 0) drops its twin. *)
  let rows =
    [ row_json ~seq:0 (Text_delta "early"); row_json ~seq:1 (Text_delta "late") ]
  in
  let chunked = Join.feed join (chunk_frame ~final:true rows) in
  (match chunked with
   | [ Join.Snapshot_row _; Join.Snapshot_row _ ] -> ()
   | _ -> fail "snapshot rows stream");
  (* A live twin of a snapshot row drops; a fresh one emits. *)
  let twin =
    entry_frame ~op:"op-1" ~op_seq:1
      (Masc.Keeper_chat_event_log.keeper_chat_event_to_json (Text_delta "late"))
  in
  check (list (testable Fmt.nop ( = ))) "twin dropped" [] (Join.feed join twin);
  let fresh =
    entry_frame ~op:"op-1" ~op_seq:2
      (Masc.Keeper_chat_event_log.keeper_chat_event_to_json (Text_delta "new"))
  in
  (match Join.feed join fresh with
   | [ Join.Live_entry entry ] -> check int "fresh seq" 2 entry.Frame.op_seq
   | _ -> fail "fresh live emits");
  (* A second welcome updates state without resetting the join. *)
  (match Join.feed join welcome_frame with
   | [ Join.State _ ] -> ()
   | _ -> fail "second welcome");
  check (list (testable Fmt.nop ( = ))) "twin still dropped" [] (Join.feed join twin)
;;

let test_join_passthrough_and_ignores () =
  let join = Join.create () in
  let _ = Join.feed join welcome_frame in
  let _ = Join.feed join (chunk_frame ~final:true []) in
  check bool "transcript passes" true
    (match
       Join.feed join (Frame.Transcript { Frame.req_id = 7; text = "hi"; new_size = 2; error = None })
     with
     | [ Join.Transcript t ] -> t.Frame.req_id = 7
     | _ -> false);
  check bool "bye passes" true
    (match Join.feed join (Frame.Bye "done") with
     | [ Join.Bye "done" ] -> true
     | _ -> false);
  check bool "error passes" true
    (match Join.feed join (Frame.Error_frame "no") with
     | [ Join.Error_frame "no" ] -> true
     | _ -> false);
  check bool "guest frames ignored" true
    (Join.feed join (Frame.Prompt "x") = []
     && Join.feed join Frame.Abort = []
     && Join.feed join (Frame.Fetch_transcript { Frame.req_id = 1; max_bytes = 9 }) = []);
  (* A chunk with no join in progress (a stray hello's shadow) drops. *)
  let stray = Join.create () in
  check bool "stray chunk dropped" true
    (Join.feed stray (chunk_frame ~final:true [ `String "x" ]) = []);
  (* An unparseable row still emits; it just cannot dedupe. *)
  let odd = Join.create () in
  let _ = Join.feed join welcome_frame in
  let _ = Join.feed odd welcome_frame in
  check bool "odd row emits" true
    (match Join.feed odd (chunk_frame ~final:false [ `String "x" ]) with
     | [ Join.Snapshot_row _ ] -> true
     | _ -> false)
;;

let key_of_room () =
  match Collab_seal.key_of_secret room.Link.key with
  | Error _ -> fail "room key rejected"
  | Ok key -> key
;;

let seal_frame ~key frame =
  let sealed = Collab_seal.seal key (Frame.frame_to_string frame) in
  match Collab_envelope.pack ~peer:Collab_envelope.broadcast_peer sealed with
  | Error _ -> fail "pack peer 0"
  | Ok envelope -> envelope
;;

let open_frame ~key payload =
  match Collab_envelope.unpack payload with
  | None -> fail "no envelope"
  | Some (_, sealed) -> (
    match Collab_seal.open_sealed key sealed with
    | Error _ -> fail "seal open"
    | Ok json -> (
      match Frame.frame_of_string json with
      | None -> fail "frame parse"
      | Some frame -> frame))
;;

let test_dial_and_drive () =
  let key = key_of_room () in
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let net = Eio.Stdenv.net env in
          let listener =
            Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr listener with
            | `Tcp (_, port) -> port
            | `Unix _ -> fail "TCP expected"
          in
          let seen_hello = ref None in
          Eio.Fiber.fork ~sw (fun () ->
              let flow, _ = Eio.Net.accept ~sw listener in
              let scripted writer =
                Ws_direct_core.Endpoint.handlers
                  ~on_message:(fun message ->
                    let payload =
                      Bigstringaf.to_string
                        message.Ws_direct_core.Connection.Message.payload
                    in
                    (match open_frame ~key payload with
                     | Frame.Hello hello ->
                       seen_hello := Some hello;
                       let send frame =
                         Ws_direct_core.Endpoint.Wsd.send_binary writer (seal_frame ~key frame)
                       in
                       send welcome_frame;
                       send
                         (chunk_frame ~final:false
                            [ row_json ~seq:0 Masc.Keeper_chat_events.(Text_delta "a")
                            ]);
                       (* Buffered (pre-final) twin of row 0: must drop. *)
                       send
                         (entry_frame ~op:"op-1" ~op_seq:0
                            (Masc.Keeper_chat_event_log.keeper_chat_event_to_json
                               Masc.Keeper_chat_events.(Text_delta "a")));
                       send (chunk_frame ~final:true []);
                       (* Fresh live entry past the barrier: must show. *)
                       send
                         (entry_frame ~op:"op-1" ~op_seq:9
                            (Masc.Keeper_chat_event_log.keeper_chat_event_to_json
                               Masc.Keeper_chat_events.(Text_delta "b")))
                     | _ -> ()))
                  ~on_close:(fun ~code:_ ~reason:_ -> ())
                  ~on_error:(fun _ -> ())
                  ~on_eof:(fun () -> ())
                  ()
              in
              (try
                 Ws_direct_eio.Server.handle ~clock:(Eio.Stdenv.clock env) flow scripted
               with
               | Failure _ -> ()));
          let target =
            target_exn ~link:view_link
              ~relay:(Some (Printf.sprintf "ws://127.0.0.1:%d" port))
          in
          let events = ref [] in
          let on_event event = events := !events @ [ event ] in
          (match Session.connect ~sw ~env ~target ~label:(Some "T") ~on_event with
           | Error err -> fail (Session.connect_error_to_string err)
           | Ok handle ->
             let deadline = Unix.gettimeofday () +. 5. in
             while List.length !events < 3 && Unix.gettimeofday () < deadline do
               Eio.Fiber.yield ()
             done;
             (match !events with
              | [ Session.Frame_event (Join.State _)
                ; Session.Frame_event (Join.Snapshot_row _)
                ; Session.Frame_event (Join.Live_entry entry)
                ] ->
                check int "fresh live shown" 9 entry.Frame.op_seq
              | _ -> fail "welcome + row + twin-drop + fresh");
             (match !seen_hello with
              | None -> fail "hello never arrived"
              | Some hello ->
                check (option string) "view hello" None hello.Frame.write_token;
                check (option string) "label" (Some "T") hello.Frame.label);
             (* A view handle refuses to steer without touching the socket. *)
             check bool "prompt refused" true
               (Session.send_prompt handle "steer" = Error Session.View_only);
             check bool "abort refused" true
               (Session.send_abort handle = Error Session.View_only);
             check bool "fetch allowed" true
               (Result.is_ok (Session.fetch_transcript handle ~req_id:1 ~max_bytes:9));
             Session.close handle)))
;;

let test_control_prompt_roundtrips () =
  let key = key_of_room () in
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let net = Eio.Stdenv.net env in
          let listener =
            Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:4
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
          in
          let port =
            match Eio.Net.listening_addr listener with
            | `Tcp (_, port) -> port
            | `Unix _ -> fail "TCP expected"
          in
          let got_prompt, set_prompt = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              let flow, _ = Eio.Net.accept ~sw listener in
              let builder writer =
                let open Ws_direct_core.Endpoint in
                handlers
                  ~on_message:(fun message ->
                    let payload =
                      Bigstringaf.to_string
                        message.Ws_direct_core.Connection.Message.payload
                    in
                    (match open_frame ~key payload with
                     | Frame.Hello _ ->
                       Wsd.send_binary writer (seal_frame ~key welcome_frame);
                       Wsd.send_binary writer (seal_frame ~key (chunk_frame ~final:true []))
                     | Frame.Prompt text -> (
                       match Eio.Promise.peek got_prompt with
                       | Some _ -> ()
                       | None -> Eio.Promise.resolve set_prompt text)
                     | _ -> ()))
                  ~on_close:(fun ~code:_ ~reason:_ -> ())
                  ~on_error:(fun _ -> ())
                  ~on_eof:(fun () -> ())
                  ()
              in
              (try
                 Ws_direct_eio.Server.handle ~clock:(Eio.Stdenv.clock env) flow builder
               with
               | Failure _ -> ()));
          let target =
            target_exn ~link:control_link
              ~relay:(Some (Printf.sprintf "ws://127.0.0.1:%d" port))
          in
          let on_event _ = () in
          (match Session.connect ~sw ~env ~target ~label:None ~on_event with
           | Error err -> fail (Session.connect_error_to_string err)
           | Ok handle ->
             check bool "prompt sent" true
               (Result.is_ok (Session.send_prompt handle "go left"));
             let deadline = Unix.gettimeofday () +. 5. in
             let rec await () =
               match Eio.Promise.peek got_prompt with
               | Some text -> text
               | None ->
                 if Unix.gettimeofday () > deadline
                 then fail "prompt never arrived"
                 else (Eio.Fiber.yield (); await ())
             in
             check string "prompt text" "go left" (await ());
             Session.close handle)))
;;

let test_render () =
  let open Masc.Keeper_chat_events in
  let row event = row_json ~seq:0 event in
  check (list string) "user header" [ "you:" ]
    (Masc_collab_join.render_snapshot_row
       (row (Text_message_start { message_id = "m"; role = User })));
  check (list string) "delta streams" [ "hel"; "lo" ]
    (Masc_collab_join.render_live_event
       (Masc.Keeper_chat_event_log.keeper_chat_event_to_json (Text_delta "hel\nlo")));
  check (list string) "tool call" [ "tool: shell" ]
    (Masc_collab_join.render_live_event
       (Masc.Keeper_chat_event_log.keeper_chat_event_to_json
          (Tool_call_start
             { occurrence = { stream_scope = 0; provider_message_id = None; block_index = 0 }
             ; tool_call_id = None
             ; tool_call_name = "shell"
             })));
  check (list string) "thinking hidden" []
    (Masc_collab_join.render_live_event
       (Masc.Keeper_chat_event_log.keeper_chat_event_to_json
          (Agent_core_thinking_delta { index = 0; delta = "secret" })));
  check (list string) "error shown" [ "error: boom" ]
    (Masc_collab_join.render_snapshot_row (row (Event_error { message = "boom" })));
  check bool "garbage row placeholder" true
    (match Masc_collab_join.render_snapshot_row (`String "x") with
     | [ line ] ->
       String.length line >= 1 && Char.code line.[0] = Char.code '('
     | _ -> false);
  check bool "garbage live placeholder" true
    (match Masc_collab_join.render_live_event (`Assoc [ ("t", `String "nope") ]) with
     | [ _ ] -> true
     | _ -> false)
;;

let () =
  run
    "collab-guest"
    [ ( "resolve",
        [ test_case "terminal link resolves" `Quick test_resolve_terminal_link
        ; test_case "web link and errors" `Quick test_resolve_web_link_and_errors
        ; test_case "resource matches route" `Quick test_resource_matches_route_parser
        ] )
    ; ( "join",
        [ test_case "buffers and dedupes" `Quick test_join_buffers_and_dedupes
        ; test_case "passthrough and ignores" `Quick test_join_passthrough_and_ignores
        ] )
    ; ( "session",
        [ test_case "dial and drive" `Quick test_dial_and_drive
        ; test_case "control prompt roundtrips" `Quick test_control_prompt_roundtrips
        ] )
    ; ("render", [ test_case "renders events" `Quick test_render ])
    ]
;;
