(* RFC-0483 L2: one Keeper's activations and usage are read from that
   Keeper's ledger alone, and the answer says which of its closed states it
   is in. *)

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

let member key json = Yojson.Safe.Util.member key json

let test_a_keeper_without_a_ledger_answers_no_ledger () =
  with_workspace @@ fun config ->
  let json = Server_keeper_skill_activations_read.json ~config ~keeper_name:"ghost" in
  check string "the schema" "masc.keeper-skill-activations/v1"
    (Yojson.Safe.Util.to_string (member "schema" json));
  check string "the Keeper it answers for" "ghost"
    (Yojson.Safe.Util.to_string (member "keeper" json));
  check string "no ledger, so no usage" "no_ledger"
    (Yojson.Safe.Util.to_string (member "state" (member "usage" json)));
  check bool "the activation projection is carried" true
    (member "skill_activations" json <> `Null)

let () =
  run "keeper_skill_activations_read"
    [ ( "answer"
      , [ test_case "a Keeper without a ledger answers no_ledger" `Quick
            test_a_keeper_without_a_ledger_answers_no_ledger
        ] )
    ]
