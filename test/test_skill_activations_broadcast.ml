(* RFC-0483 §4.2: the skill activation ledger knows only the trace it wrote.
   The server names the Keeper from the registry, where each Keeper holds its
   current trace, before it announces. *)

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

let test_a_trace_names_the_keeper_that_holds_it () =
  with_workspace @@ fun config ->
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String "analyst"; "activation_mode", `String "manual" ])
    with
    | Ok meta -> meta
    | Error detail -> fail ("keeper meta fixture failed: " ^ detail)
  in
  let entry =
    Masc.Keeper_registry.register_offline ~base_path:config.Masc.Workspace.base_path
      "analyst" meta
  in
  let name_of = Server_skill_activations_broadcast.keeper_of_trace [ entry ] in
  check (option string) "the registered trace names its Keeper" (Some "analyst")
    (name_of meta.runtime.trace_id);
  match Keeper_id.Trace_id.of_string "trace-held-by-nobody" with
  | Error detail -> fail detail
  | Ok other ->
    check (option string) "a trace no entry holds names nobody" None (name_of other)

let () =
  run "skill_activations_broadcast"
    [ ( "naming"
      , [ test_case "a trace names the Keeper that holds it" `Quick
            test_a_trace_names_the_keeper_that_holds_it
        ] )
    ]
