(* RFC-0480 §3.4: a lane add-on export change reaches the workspace's
   observer sessions. Which lifecycle steps call it is
   Lane_addon_runtime.notify_exports; this checks where it lands. *)

open Alcotest

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect ~finally:(fun () ->
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
            f config))))

let observing ~(config : Masc.Workspace.config) f =
  let session_id = Printf.sprintf "lane-addon-exports-announce-%d" (Unix.getpid ()) in
  let auth = Masc_test_deps.make_sse_auth config.base_path "lane-addon-exports-announce" in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  match
    Masc.Sse.register ~kind:Observer ~auth session_id ~last_event_id:(Masc.Sse.current_id ())
  with
  | Error error -> fail (Masc.Sse.registration_error_to_string error)
  | Ok (_, stream, _) ->
    Fun.protect ~finally:(fun () -> Masc.Sse.unregister session_id) (fun () -> f stream)

let changes_heard stream =
  let rec drain count =
    match Masc.Sse.take_delivery_nonblocking stream with
    | None -> count
    | Some delivery ->
      let changed =
        match Yojson.Safe.Util.member "type" delivery.Masc.Sse.payload with
        | `String kind -> String.equal kind Masc.Lane_addon_exports_broadcast.changed_event
        | _ -> false
      in
      drain (if changed then count + 1 else count)
  in
  drain 0

let test_a_change_reaches_the_workspace_observers () =
  with_workspace @@ fun config ->
  observing ~config @@ fun stream ->
  Masc.Lane_addon_exports_broadcast.changed ~base_path:config.base_path;
  check int "one change, one announcement" 1 (changes_heard stream)

let () =
  run "lane_addon_exports_announce"
    [ ( "exports"
      , [ test_case "a change reaches the workspace observers" `Quick
            test_a_change_reaches_the_workspace_observers ] )
    ]
