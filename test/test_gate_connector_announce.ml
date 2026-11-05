(* RFC-0480 §3.4: a connector's state reaches the workspace's observer sessions
   through the observer the server installs at boot. The connector name
   directory announces a new or changed name and stays quiet when a name
   repeats; the binding store's announcement is covered in
   test_channel_gate_binding_store. *)

open Alcotest

module Keeper_connector_names = Masc.Keeper_connector_names

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
    Gate_connector_announce.install (fun ~connector_id:_ -> ());
    Server_auth.For_testing.restore_server_state previous_state;
    (match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ());
    Masc_test_deps.cleanup_test_workspace base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw
          (fun () ->
            let state = Masc.Mcp_server.For_testing.create_state ~base_path in
            Server_auth.For_testing.restore_server_state (Some state);
            let config = Masc.Mcp_server.workspace_config state in
            ignore (Workspace_core.init config ~agent_name:(Some "test"));
            Server_gate_connector_broadcast.install ~sw ~base_path:config.base_path;
            f config))))

(* The writer only records which connector changed; the announcing fiber
   sends once the writer's fiber yields. *)
let let_the_announcer_run () = Eio.Fiber.yield ()

(* An observer session of the workspace, as a terminal reader holds one. Only
   changes made after the call are delivered. *)
let observing ~(config : Masc.Workspace.config) f =
  let session_id = Printf.sprintf "gate-connector-announce-%d" (Unix.getpid ()) in
  let auth = Masc_test_deps.make_sse_auth config.base_path "gate-connector-announce" in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  match
    Masc.Sse.register ~kind:Observer ~auth session_id ~last_event_id:(Masc.Sse.current_id ())
  with
  | Error error -> fail (Masc.Sse.registration_error_to_string error)
  | Ok (_, stream, _) ->
    Fun.protect ~finally:(fun () -> Masc.Sse.unregister session_id) (fun () -> f stream)

(* The connectors named by the changes delivered so far, oldest first. *)
let connector_changes stream =
  let rec drain heard =
    match Masc.Sse.take_delivery_nonblocking stream with
    | None -> List.rev heard
    | Some delivery ->
      let payload = delivery.Masc.Sse.payload in
      (match Yojson.Safe.Util.member "type" payload, Yojson.Safe.Util.member "connector" payload with
       | `String kind, `String connector
         when String.equal kind Masc.Gate_connector_changed_event.event_type ->
         drain (connector :: heard)
       | _ -> drain heard)
  in
  drain []

let test_a_new_connector_name_reaches_observers () =
  with_workspace @@ fun config ->
  observing ~config @@ fun stream ->
  let remember ~id name =
    Keeper_connector_names.remember ~base_dir:config.base_path ~connector:"fixture"
      ~scope:Keeper_connector_names.Channel ~id ~name ()
  in
  remember ~id:"C1" "general";
  let_the_announcer_run ();
  check (list string) "a new name announces its connector" [ "fixture" ]
    (connector_changes stream);
  remember ~id:"C1" "general";
  let_the_announcer_run ();
  check (list string) "a repeated name announces nothing" [] (connector_changes stream);
  remember ~id:"C1" "random";
  let_the_announcer_run ();
  check (list string) "a changed name announces again" [ "fixture" ]
    (connector_changes stream);
  (* A directory sync hands a whole page over; the page is one change. *)
  let remember_page entries =
    Keeper_connector_names.remember_many ~base_dir:config.base_path ~connector:"fixture"
      ~scope:Keeper_connector_names.Channel entries
  in
  remember_page [ "C2", "design"; "C3", "ops"; "C4", "random" ];
  let_the_announcer_run ();
  check (list string) "a page of names announces once" [ "fixture" ]
    (connector_changes stream);
  remember_page [ "C2", "design"; "C3", "ops" ];
  let_the_announcer_run ();
  check (list string) "a page of known names announces nothing" []
    (connector_changes stream)

(* The Telegram poll loop writes its state after every poll. Only a change
   in what the connector list draws -- polling or not, the bot, the error --
   announces; a new offset alone does not. *)
let test_a_telegram_offset_alone_announces_nothing () =
  let heard = ref [] in
  Gate_connector_announce.install (fun ~connector_id -> heard := connector_id :: !heard);
  Fun.protect ~finally:(fun () -> Gate_connector_announce.install (fun ~connector_id:_ -> ()))
  @@ fun () ->
  Channel_gate_telegram_state.record_error "fixture: before";
  heard := [];
  Channel_gate_telegram_state.record_poll_ok ~bot_user_id:7L ~next_offset:(Some 1L);
  check (list string) "a poll that recovers announces" [ "telegram" ] !heard;
  Channel_gate_telegram_state.record_poll_ok ~bot_user_id:7L ~next_offset:(Some 2L);
  check (list string) "a new offset alone announces nothing" [ "telegram" ] !heard;
  Channel_gate_telegram_state.record_error "fixture: getUpdates failed";
  check (list string) "a failed poll announces" [ "telegram"; "telegram" ] !heard

let () =
  run "gate_connector_announce"
    [ ( "observers"
      , [ test_case "a new connector name reaches observers" `Quick
            test_a_new_connector_name_reaches_observers
        ] )
    ; ( "poll state"
      , [ test_case "a Telegram offset alone announces nothing" `Quick
            test_a_telegram_offset_alone_announces_nothing
        ] )
    ]
