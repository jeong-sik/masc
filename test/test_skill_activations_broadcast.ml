(* RFC-0483 §4.2: the skill activation ledger knows only the trace it wrote.
   The server names the Keeper from the registry, where each Keeper holds its
   current trace, and announces the change to the workspace's observer
   sessions. The ledger's side, one call per appending write, is covered in
   test_keeper_skill_activation_ledger. *)

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
            f ~sw config))))

let register_analyst (config : Masc.Workspace.config) =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ "name", `String "analyst"; "activation_mode", `String "manual" ])
    with
    | Ok meta -> meta
    | Error detail -> fail ("keeper meta fixture failed: " ^ detail)
  in
  meta, Masc.Keeper_registry.register_offline ~base_path:config.base_path "analyst" meta

let trace_held_by_nobody () =
  match Keeper_id.Trace_id.of_string "trace-held-by-nobody" with
  | Ok trace -> trace
  | Error detail -> fail detail

(* The observer only records which trace changed; the announcing fiber sends
   once the writer's fiber yields. *)
let let_the_announcer_run () = Eio.Fiber.yield ()

(* An observer session of the workspace, as a terminal reader holds one. Only
   changes made after the call are delivered. *)
let observing ~(config : Masc.Workspace.config) f =
  let session_id = Printf.sprintf "skill-activations-broadcast-%d" (Unix.getpid ()) in
  let auth = Masc_test_deps.make_sse_auth config.base_path "skill-activations-broadcast" in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  match
    Masc.Sse.register ~kind:Observer ~auth session_id ~last_event_id:(Masc.Sse.current_id ())
  with
  | Error error -> fail (Masc.Sse.registration_error_to_string error)
  | Ok (_, stream, _) ->
    Fun.protect ~finally:(fun () -> Masc.Sse.unregister session_id) (fun () -> f stream)

(* The (keeper, trace) pairs announced so far, oldest first. *)
let announced stream =
  let module U = Yojson.Safe.Util in
  let rec drain heard =
    match Masc.Sse.take_delivery_nonblocking stream with
    | None -> List.rev heard
    | Some delivery ->
      let payload = delivery.Masc.Sse.payload in
      (match U.member "type" payload, U.member "name" payload, U.member "trace_id" payload with
       | `String kind, `String name, `String trace
         when String.equal kind Masc.Keeper_skill_activations_changed_event.event_type ->
         drain ((name, trace) :: heard)
       | _ -> drain heard)
  in
  drain []

let test_a_trace_names_the_keeper_that_holds_it () =
  with_workspace @@ fun ~sw:_ config ->
  let meta, entry = register_analyst config in
  let name_of = Server_skill_activations_broadcast.keeper_of_trace [ entry ] in
  check (option string) "the registered trace names its Keeper" (Some "analyst")
    (name_of meta.runtime.trace_id);
  check (option string) "a trace no entry holds names nobody" None
    (name_of (trace_held_by_nobody ()))

let test_a_change_reaches_observers_named () =
  with_workspace @@ fun ~sw config ->
  let meta, _ = register_analyst config in
  let trace_id = meta.runtime.trace_id in
  let trace = Keeper_id.Trace_id.to_string trace_id in
  observing ~config @@ fun stream ->
  let changed = Server_skill_activations_broadcast.start ~sw in
  changed ~config ~trace_id;
  changed ~config ~trace_id;
  let_the_announcer_run ();
  check (list (pair string string)) "changes before the fiber runs announce once"
    [ "analyst", trace ] (announced stream);
  changed ~config ~trace_id:(trace_held_by_nobody ());
  let_the_announcer_run ();
  check (list (pair string string)) "a trace no Keeper holds announces nothing" []
    (announced stream);
  changed ~config ~trace_id;
  let_the_announcer_run ();
  check (list (pair string string)) "a later change announces again"
    [ "analyst", trace ] (announced stream)

let () =
  run "skill_activations_broadcast"
    [ ( "naming"
      , [ test_case "a trace names the Keeper that holds it" `Quick
            test_a_trace_names_the_keeper_that_holds_it
        ] )
    ; ( "announcing"
      , [ test_case "a change reaches observers with its Keeper" `Quick
            test_a_change_reaches_observers_named
        ] )
    ]
