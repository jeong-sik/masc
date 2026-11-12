open Alcotest
open Masc

module Owner = Server_dashboard_operator_digest_observation
module Cache = Server_dashboard_http_cache

let with_owner f = Eio_main.run (fun env ->
  let previous_fs = Fs_compat.get_fs_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  Fun.protect ~finally:(fun () ->
    Masc_test_deps.cleanup_test_workspace base_path;
    match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ())
    (fun () ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let scope = Mcp_server.workspace_scope state in
      f state scope (Owner.owner_for_scope ~state scope)))

let observation marker next_deadline_unix : Dashboard_projection_cache.digest_observation =
  {json = `Assoc ["health", `String "ok"; "marker", `String marker]; next_deadline_unix}

let marker owner = Yojson.Safe.Util.((Owner.publication owner).json |> member "marker" |> to_string)

let test_request_and_source_admission () = with_owner (fun _state _scope owner ->
  let source = Owner.begin_attempt owner ~origin:Source_read in
  let request = Owner.begin_attempt owner ~origin:Default_request in
  check bool "newer default fill owns its observation" true
    (Owner.publish_success request (observation "actual request" (Some 123.0)));
  check bool "own successful return wins a closing timeout window" false
    (Owner.publish_failure_message request "late timeout");
  check bool "older source completion cannot replace the newer request" false
    (Owner.publish_success source (observation "older source" None));
  check bool "older source failure cannot replace it either" false
    (Owner.publish_failure_message source "old source failure");
  check string "current rows belong to the actual admitted request" "actual request" (marker owner);
  check (option (float 0.0)) "that observation owns its semantic deadline" (Some 123.0)
    (Owner.next_deadline_unix owner);
  check (option string) "a rejected outer timeout adds no synthetic cache error" None
    (Cache.snapshot (Owner.cache owner)).last_error)

let test_invalidation_then_completion_keeps_publication_debt () = with_owner (fun _state _scope owner ->
  let initial = Owner.begin_attempt owner ~origin:Source_read in
  check bool "initial read succeeds" true (Owner.publish_success initial (observation "old rows" None));
  let prepared = Owner.publication owner in
  let old_read = Owner.begin_attempt owner ~origin:Source_read in
  Owner.invalidate owner;
  check bool "current source generation is still unread" true
    (Owner.publication_status owner prepared = Owner.Source_pending);
  check bool "actual completion after a source notice can publish its observation" true
    (Owner.publish_success old_read (observation "completed read" None));
  check string "continuous inputs do not discard actual completed reads" "completed read" (marker owner);
  let current = Owner.begin_attempt owner ~origin:Source_read in
  check bool "actual post-mutation read settles the current source" true
    (Owner.publish_success current (observation "current rows" None));
  check bool "an old preparation now retains publication debt" true
    (Owner.publication_status owner prepared = Owner.Superseded);
  check bool "current immutable bytes may be published" true
    (Owner.publication_is_current owner (Owner.publication owner)))

let test_same_path_request_cannot_borrow_a_new_instance () = with_owner (fun state scope owner ->
  let request = Owner.begin_attempt owner ~origin:Default_request in
  let captured = Owner.publication owner in
  (match Mcp_server.set_workspace_config state scope.config with
   | Ok () -> () | Error _ -> fail "same-path workspace replacement failed");
  let replacement = Mcp_server.workspace_scope state in
  let current = Owner.owner_for_scope ~state replacement in
  let current_read = Owner.begin_attempt current ~origin:Source_read in
  check bool "new instance publishes its own rows" true
    (Owner.publish_success current_read (observation "new instance" None));
  check bool "old request completion cannot seed the new instance" false
    (Owner.publish_success request (observation "old request" None));
  check bool "old request failure cannot degrade the new instance" false
    (Owner.publish_failure_message request "retired request failure");
  let delayed = Owner.owner_for_scope ~state scope in
  check bool "late old-scope lookup cannot retire the current cell" true
    (Owner.cache current == Owner.cache (Owner.owner_for_scope ~state replacement));
  check bool "a late private old-scope cell is not current" false (Owner.is_current delayed);
  check bool "old preparation has a typed retirement outcome" true
    (Owner.publication_status owner captured = Owner.Retired);
  check string "old payload keeps the original captured instance" (Server_observer_scope.instance_id scope)
    Yojson.Safe.Util.(captured.json |> member "observer_instance_id" |> to_string);
  check string "new payload attests only the new captured instance" (Server_observer_scope.instance_id replacement)
    Yojson.Safe.Util.((Owner.publication current).json |> member "observer_instance_id" |> to_string))

let test_failure_and_listener_isolation () = with_owner (fun _state _scope owner ->
  let unsubscribe = Owner.subscribe_completed owner (fun _ -> raise Exit) in
  Fun.protect ~finally:unsubscribe (fun () ->
    let read = Owner.begin_attempt owner ~origin:Source_read in
    check bool "listener exception cannot replace committed success" true
      (Owner.publish_success read (observation "last-good" None));
    let failed = Owner.begin_attempt owner ~origin:Source_read in
    check bool "actual read failure is admitted independently of its listener" true
      (Owner.publish_failure_message failed "original failure");
    let publication = Owner.publication owner in
    check string "failure retains this owner's last-good rows" "last-good" (marker owner);
    check string "canonical state exposes the actual failure" "error"
      Yojson.Safe.Util.(publication.json |> member "digest_observation_state" |> to_string);
    check (option string) "original failure is retained" (Some "original failure") publication.source.last_error))

let with_runtime f = Eio_main.run (fun env ->
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_context = Eio_context.snapshot_state () in
  let previous_clock = Eio_context.get_clock_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  let mock_clock = Eio_mock.Clock.make () in
  let clock = (mock_clock :> float Eio.Time.clock_ty Eio.Resource.t) in
  Eio_mock.Clock.set_time mock_clock (Unix.gettimeofday ());
  Fun.protect ~finally:(fun () ->
    Eio_context.restore_state previous_context;
    (match previous_clock with Some clock -> Time_compat.set_clock clock | None -> Time_compat.clear_clock ());
    Masc_test_deps.cleanup_test_workspace base_path;
    match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ()) (fun () ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
          Time_compat.set_clock clock;
          let state = Mcp_server.For_testing.create_state ~base_path in
          let scope = Mcp_server.workspace_scope state in
          ignore (Workspace.init scope.config ~agent_name:None);
          f ~env ~sw ~clock ~mock_clock ~state ~scope)))))

let test_actual_cold_read_and_source_deadline () = with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
  let cold = match Server_dashboard_http_core_operator_digest_http.operator_digest_http_json
      ~state ~sw ~clock (Httpun.Request.create `GET "/api/v1/operator/digest") with
    | Ok json -> json | Error _ -> fail "cold Digest read failed" in
  check string "cold default read installs canonical metadata" "ready"
    Yojson.Safe.Util.(cold |> member "digest_observation_state" |> to_string);
  let frames = Eio.Stream.create 8 in
  let id = "actual-operator-digest-observation" in
  Sse.subscribe_external ~id
    ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
    ~observer_instance_id:(Server_observer_scope.instance_id scope)
    ~callback:(fun event ->
      if Yojson.Safe.Util.member "type" event.Sse.ext_payload = `String "operator_digest" then
        Eio.Stream.add frames (Yojson.Safe.Util.member "payload" event.ext_payload)) ();
  Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id);
  let ordering payload = Yojson.Safe.Util.(
    payload |> member "digest_publication_generation" |> to_int),
    Yojson.Safe.Util.(payload |> member "digest_publication_sequence" |> to_int) in
  let rec ready_after previous =
    let payload = Eio.Stream.take frames in
    match Yojson.Safe.Util.member "digest_observation_state" payload with
    | `String "ready" ->
        let generation, sequence = ordering payload in
        let previous_generation, previous_sequence = ordering previous in
        if generation > previous_generation ||
          (generation = previous_generation && sequence > previous_sequence)
        then payload else ready_after previous
    | `String "initializing" -> ready_after previous
    | `String "error" -> fail "actual Digest source read failed"
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
        fail "Digest frame has no closed observation state" in
  Server_dashboard_http_core_digest_refresh.start_operator_digest_refresh_loop
    ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env);
  let initial = ready_after cold in
  check string "canonical initial frame keeps its captured instance"
    (Server_observer_scope.instance_id scope)
    Yojson.Safe.Util.(initial |> member "observer_instance_id" |> to_string);
  check bool "retention does not invent a healthy refresh interval" true
    Yojson.Safe.Util.(initial |> member "retention" |> member "background_refresh_interval_s" = `Null);
  Eio.Fiber.yield ();
  check bool "healthy empty Digest has no timer" false (Eio_mock.Clock.try_advance mock_clock);
  let now = Time_compat.now () in
  let confidence = match Operator_judgment.Confidence.of_float 0.91 with
    | Some value -> value | None -> fail "invalid fixture confidence" in
  let action = `Assoc ["action_kind", `String "actual-digest-action"] in
  let judgment = Operator_judgment.record scope.config ~surface:Operator_judgment.Command_namespace
      ~target_type:Operator_judgment.Workspace ~target_id:None ~summary:"Actual Digest source"
      ~confidence ~generated_at:(Masc_domain.iso8601_of_unix_seconds now) ~generated_at_unix:now
      ~fresh_until:(Masc_domain.iso8601_of_unix_seconds (now +. 60.0)) ~fresh_until_unix:(now +. 60.0)
      ~keeper_name:"digest-source-judge" ~recommended_action:action () in
  let changed = ready_after initial in
  check bool "actual judgment commit reaches the source worker and scoped frame" true
    Yojson.Safe.Util.(changed |> member "recommended_actions" = `List [action]);
  let owner = Owner.owner_for_scope ~state scope in
  check (option (float 0.0)) "same read owns the exact recorded deadline"
    (Some judgment.fresh_until_unix) (Owner.next_deadline_unix owner);
  Eio_mock.Clock.set_time mock_clock judgment.fresh_until_unix;
  let expired = ready_after changed in
  check bool "the actual deadline retires the old recommended action" true
    Yojson.Safe.Util.(expired |> member "recommended_actions" = `List []);
  Eio.Fiber.yield ();
  check bool "settled expiry and own output leave no cadence" false (Eio_mock.Clock.try_advance mock_clock))

let test_parameter_cache_is_bound_to_the_original_workspace () =
  with_runtime (fun ~env:_ ~sw ~clock ~mock_clock:_ ~state ~scope ->
    let other_base = Masc_test_deps.setup_test_workspace () in
    Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace other_base) (fun () ->
      let other = Workspace.default_config other_base in
      ignore (Workspace.init other ~agent_name:None);
      let confidence = match Operator_judgment.Confidence.of_float 0.91 with
        | Some value -> value | None -> fail "invalid fixture confidence" in
      let seed config marker =
        let now = Time_compat.now () in
        ignore (Operator_judgment.record config ~surface:Operator_judgment.Command_namespace
          ~target_type:Operator_judgment.Workspace ~target_id:None ~summary:marker ~confidence
          ~generated_at:(Masc_domain.iso8601_of_unix_seconds now) ~generated_at_unix:now
          ~fresh_until:(Masc_domain.iso8601_of_unix_seconds (now +. 60.0)) ~fresh_until_unix:(now +. 60.0)
          ~keeper_name:"query-source-judge" ~recommended_action:(`Assoc ["marker", `String marker]) ()) in
      seed scope.config "original workspace";
      seed other "replacement workspace";
      let read () = match Server_dashboard_http_core_operator_digest_http.operator_digest_http_json
          ~state ~sw ~clock (Httpun.Request.create `GET "/api/v1/operator/digest?agent_name=same-actor") with
        | Ok json -> json | Error _ -> fail "parameterized Digest read failed" in
      let first = read () in
      check bool "the first query reads its actual source" true
        Yojson.Safe.Util.(first |> member "recommended_actions" =
          `List [`Assoc ["marker", `String "original workspace"]]);
      (match Mcp_server.set_workspace_config state other with
       | Ok () -> () | Error _ -> fail "workspace query replacement failed");
      let replacement = Mcp_server.workspace_scope state in
      let second = read () in
      check bool "the same actor and query cannot borrow another workspace's cache" true
        Yojson.Safe.Util.(second |> member "recommended_actions" =
          `List [`Assoc ["marker", `String "replacement workspace"]]);
      check string "first response retains its captured workspace instance"
        (Server_observer_scope.instance_id scope)
        Yojson.Safe.Util.(first |> member "observer_instance_id" |> to_string);
      check string "replacement response is attested by its own captured instance"
        (Server_observer_scope.instance_id replacement)
        Yojson.Safe.Util.(second |> member "observer_instance_id" |> to_string)))

let () = run "Operator Digest observation owner" ["publication", [
  test_case "request and source admission" `Quick test_request_and_source_admission;
  test_case "current source settlement preserves publication debt" `Quick test_invalidation_then_completion_keeps_publication_debt;
  test_case "same-path request retains original instance" `Quick test_same_path_request_cannot_borrow_a_new_instance;
  test_case "failure retains rows and callback outcome" `Quick test_failure_and_listener_isolation;
  test_case "actual cold read and source policy deadline" `Quick test_actual_cold_read_and_source_deadline;
  test_case "parameter cache stays in its captured workspace" `Quick test_parameter_cache_is_bound_to_the_original_workspace]]
