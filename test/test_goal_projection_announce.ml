(* RFC-0480 §3.4: every Goal projection source announces to the workspace's
   observer sessions after it drops the planning cache -- the Goal file, the
   verification ledger and the measurement store. The ledger write below
   leaves the Goal itself unchanged, so only the ledger's own announcement can
   reach a reader. *)

open Alcotest

let with_workspace f =
  let base_path = Masc_test_deps.setup_test_workspace () in
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_hook = Atomic.get Workspace_hooks.on_goal_projection_mutation_fn in
  Fun.protect ~finally:(fun () ->
    Atomic.set Workspace_hooks.on_goal_projection_mutation_fn previous_hook;
    Dashboard_cache.invalidate_all ();
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
            Server_dashboard_http.install_goal_projection_observer ();
            f config))))

let is_change (delivery : Masc.Sse.delivery) =
  match Yojson.Safe.Util.member "type" delivery.Masc.Sse.payload with
  | `String kind -> String.equal kind Masc.Goal_projection_broadcast.changed_event
  | _ -> false

(* An observer session of the workspace, as a terminal reader holds one. Only
   changes made after the call are delivered. *)
let observing ~(config : Masc.Workspace.config) f =
  let session_id = Printf.sprintf "goal-projection-announce-%d" (Unix.getpid ()) in
  let auth = Masc_test_deps.make_sse_auth config.base_path "goal-projection-announce" in
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
    | Some delivery -> drain (if is_change delivery then count + 1 else count)
  in
  drain 0

let test_every_source_announces_after_dropping_planning () =
  with_workspace @@ fun config ->
  let key = Server_dashboard_http.planning_cache_key ~base_path:config.base_path in
  let prime () = ignore (Server_dashboard_http.cached_planning_payload ~config) in
  let planning_dropped what =
    check bool (what ^ " drops the planning cache") true
      (Option.is_none (Dashboard_cache.peek key))
  in
  observing ~config @@ fun stream ->
  prime ();
  let goal, _, _ =
    match Goal_store.upsert_goal_with_events config ~actor:"dashboard"
            ~title:"Announced Goal" ~metric:"goals" ~target_value:"1" () with
    | Ok result -> result
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  planning_dropped "a Goal write";
  check bool "a Goal write announces" true (changes_heard stream > 0);
  prime ();
  (match Goal_verification.mark_proof_pending config ~goal_id:goal.id
           ~criterion:(Goal_store.criterion_of_goal goal) with
   | Ok _ -> ()
   | Error detail -> fail detail);
  planning_dropped "a ledger write";
  check int "a ledger write announces once" 1 (changes_heard stream);
  prime ();
  (match Goal_measurement.record config ~goal_id:goal.id
           ~criterion_revision:goal.criterion_revision ~observed_value:"1"
           ~evidence:"note:announced" ~actor:"dashboard" with
   | Ok _ -> ()
   | Error _ -> fail "measurement was refused");
  planning_dropped "a measurement write";
  check bool "a measurement write announces" true (changes_heard stream > 0)

let () =
  run "goal_projection_announce"
    [ ( "sources"
      , [ test_case "every Goal source announces after dropping planning" `Quick
            test_every_source_announces_after_dropping_planning
        ] )
    ]
