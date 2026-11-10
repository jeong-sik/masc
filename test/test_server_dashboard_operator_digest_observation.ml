open Alcotest
open Masc

module Owner = Server_dashboard_operator_digest_observation
module Cache = Server_dashboard_http_cache

let () =
  Dashboard_projection_cache.register_operator_snapshot_json {snapshot = Operator_control.snapshot_json};
  Dashboard_projection_cache.register_operator_digest_observer {observe_digest = Operator_control.observe}

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
  {json = `Assoc ["health", `String "ok"; "marker", `String marker]; next_deadline_unix;
   completeness = Dashboard_projection_read.Complete}

let marker owner = Yojson.Safe.Util.((Owner.publication owner).json |> member "marker" |> to_string)

let test_partial_read_retains_body_without_success () = with_owner (fun _state _scope owner ->
  let marker () = Yojson.Safe.Util.((Owner.publication owner).json |> member "marker" |> to_string) in
  let read = Owner.begin_attempt owner ~origin:Source_read in
  let partial = {(observation "readable partial rows" None) with
    completeness = Dashboard_projection_read.Partial "actual storage failure"} in
  check bool "a partial actual body is admitted" true (Owner.publish_observation read partial);
  check bool "the retained body satisfies a cold GET" true (Owner.has_observation owner);
  check (option (float 0.0)) "partial does not stamp a full success" None
    (Cache.snapshot (Owner.cache owner)).last_success_unix;
  check string "partial body is the actual new observation" "readable partial rows" (marker ());
  let json = (Owner.publication owner).json in
  check string "partial canonical state is error" "error"
    Yojson.Safe.Util.(json |> member "digest_observation_state" |> to_string);
  check string "typed partial outcome reaches the shared wire diagnostics" "partial"
    Yojson.Safe.Util.(json |> member "projection_diagnostics" |> member "read_completeness" |> to_string);
  check bool "outer failure retains partial rows" true (Owner.publish_failure_message read "retry retained");
  check string "the outer failure does not restore older data" "readable partial rows" (marker ());
  let recovered = Owner.begin_attempt owner ~origin:Source_read in
  check bool "a later complete read recovers" true
    (Owner.publish_observation recovered (observation "recovered" None));
  check bool "the same success cannot be degraded to partial" false
    (Owner.publish_observation recovered partial);
  check string "complete read clears the original partial error" "complete"
    Yojson.Safe.Util.((Owner.publication owner).json |> member "projection_diagnostics"
      |> member "read_completeness" |> to_string);
  check bool "complete diagnostics clear read_error" true
    Yojson.Safe.Util.((Owner.publication owner).json |> member "projection_diagnostics"
      |> member "read_error" = `Null))

let test_request_and_source_admission () = with_owner (fun _state _scope owner ->
  let source = Owner.begin_attempt owner ~origin:Source_read in
  let request = Owner.begin_attempt owner ~origin:Default_request in
  check bool "newer default fill owns its observation" true
    (Owner.publish_observation request (observation "actual request" (Some 123.0)));
  check bool "own successful return wins a closing timeout window" false
    (Owner.publish_failure_message request "late timeout");
  check bool "older source completion cannot replace the newer request" false
    (Owner.publish_observation source (observation "older source" None));
  check bool "older source failure cannot replace it either" false
    (Owner.publish_failure_message source "old source failure");
  check string "current rows belong to the actual admitted request" "actual request" (marker owner);
  check (option (float 0.0)) "that observation owns its semantic deadline" (Some 123.0)
    (Owner.next_deadline_unix owner);
  check (option string) "a rejected outer timeout adds no synthetic cache error" None
    (Cache.snapshot (Owner.cache owner)).last_error)

let test_invalidation_then_completion_keeps_publication_debt () = with_owner (fun _state _scope owner ->
  let initial = Owner.begin_attempt owner ~origin:Source_read in
  check bool "initial read succeeds" true (Owner.publish_observation initial (observation "old rows" None));
  let prepared = Owner.publication owner in
  let old_read = Owner.begin_attempt owner ~origin:Source_read in
  Owner.invalidate owner;
  check bool "current source generation is still unread" true
    (Owner.publication_status owner prepared = Owner.Source_pending);
  check bool "actual completion after a source notice can publish its observation" true
    (Owner.publish_observation old_read (observation "completed read" None));
  check string "continuous inputs do not discard actual completed reads" "completed read" (marker owner);
  let current = Owner.begin_attempt owner ~origin:Source_read in
  check bool "actual post-mutation read settles the current source" true
    (Owner.publish_observation current (observation "current rows" None));
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
    (Owner.publish_observation current_read (observation "new instance" None));
  check bool "old request completion cannot seed the new instance" false
    (Owner.publish_observation request (observation "old request" None));
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
      (Owner.publish_observation read (observation "last-good" None));
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

type partial_surface = Mission | Digest
type expected_frame = Partial_frame | Ready_frame

let test_actual_partial_retry_after_quiet_repair surface =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let event_type, state_field, sequence_field, retry_interval = match surface with
      | Mission -> "mission_snapshot", "mission_observation_state", "mission_publication_sequence", 120.0
      | Digest -> "operator_digest", "digest_observation_state", "digest_publication_sequence",
          Server_dashboard_http_core_operator.operator_refresh_interval_s in
    let read ?(private_actor = false) () =
      let suffix = if private_actor then "?agent_name=partial-reader" else "" in
      match surface with
      | Mission -> Server_dashboard_http_core_mission.json ~sw ~clock
          (Server_dashboard_http_core_mission.request ~state
            (Httpun.Request.create `GET ("/api/v1/dashboard/briefing" ^ suffix)))
      | Digest -> match Server_dashboard_http_core_operator_digest_http.operator_digest_http_json
          ~state ~sw ~clock (Httpun.Request.create `GET ("/api/v1/operator/digest" ^ suffix)) with
          | Ok json -> json | Error _ -> fail "partial Digest HTTP read failed" in
    let start () = match surface with
      | Mission -> Server_dashboard_http_core_mission.start ~state ~sw ~clock
          ~mono_clock:(Eio.Stdenv.mono_clock env)
      | Digest -> Server_dashboard_http_core_digest_refresh.start_operator_digest_refresh_loop
          ~state ~sw ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) in
    let next_deadline () = match surface with
      | Mission -> Server_dashboard_mission_observation.next_deadline_unix
          (Server_dashboard_mission_observation.owner_for_scope ~state scope)
      | Digest -> Owner.next_deadline_unix (Owner.owner_for_scope ~state scope) in
    let now = Eio.Time.now clock in
    let confidence = match Operator_judgment.Confidence.of_float 0.91 with
      | Some value -> value | None -> fail "invalid fixture confidence" in
    let action = `Assoc ["action_kind", `String "actual-partial-recommendation"] in
    let judgment = Operator_judgment.record scope.config ~surface:Operator_judgment.Command_namespace
        ~target_type:Operator_judgment.Workspace ~target_id:None ~summary:"Readable actual judgment"
        ~confidence ~generated_at:(Masc_domain.iso8601_of_unix_seconds now) ~generated_at_unix:now
        ~fresh_until:(Masc_domain.iso8601_of_unix_seconds (now +. 900.0)) ~fresh_until_unix:(now +. 900.0)
        ~keeper_name:"partial-read-judge" ~recommended_action:action () in
    let broken = Keeper_types_profile.keeper_meta_path scope.config "unread-metadata" in
    (match Fs_compat.save_file_atomic broken "{" with
     | Ok () -> () | Error detail -> fail detail);
    let diagnostic json field = Yojson.Safe.Util.(json |> member "projection_diagnostics" |> member field) in
    let assert_partial json =
      check bool "producer partial outcome reaches the private/shared wire" true
        (diagnostic json "read_completeness" = `String "partial");
      (match diagnostic json "read_error" with
       | `String _ -> ()
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _ ->
           fail "actual read error was lost");
      check bool "readable original judgment rows are retained" true
        Yojson.Safe.Util.(json |> member "recommended_actions" = `List [action]) in
    let private_read = read ~private_actor:true () in
    assert_partial private_read;
    check bool "private HTTP does not fabricate canonical ordering" true
      (Yojson.Safe.Util.member sequence_field private_read = `Null);
    let cold = read () in
    assert_partial cold;
    check string "cold partial body is a canonical error" "error"
      Yojson.Safe.Util.(cold |> member state_field |> to_string);
    let sequence json = Yojson.Safe.Util.(json |> member sequence_field |> to_int) in
    let repeated = read () in
    check int "a repeated partial GET cannot start an immediate cold retry"
      (sequence cold) (sequence repeated);
    let frames = Eio.Stream.create 16 in
    let id = "actual-partial-retry-" ^ event_type in
    Sse.subscribe_external ~id
      ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
      ~observer_instance_id:(Server_observer_scope.instance_id scope)
      ~callback:(fun event ->
        if Yojson.Safe.Util.member "type" event.Sse.ext_payload = `String event_type then
          Eio.Stream.add frames (Yojson.Safe.Util.member "payload" event.ext_payload)) ();
    Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id);
    let rec frame_after previous wanted =
      let payload = Eio.Stream.take frames in
      if sequence payload <= sequence previous then frame_after previous wanted
      else match Yojson.Safe.Util.member state_field payload, wanted with
        | `String "error", Partial_frame | `String "ready", Ready_frame -> payload
        | `String ("initializing" | "error" | "ready"), (Partial_frame | Ready_frame) -> frame_after previous wanted
        | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _),
          (Partial_frame | Ready_frame) ->
            fail "canonical frame lost its closed observation state" in
    start ();
    let partial = frame_after cold Partial_frame in
    assert_partial partial;
    check (option (float 0.0)) "the partial read retains the actual authority deadline"
      (Some judgment.fresh_until_unix) (next_deadline ());
    (* No canonical writer, input event, GET refresh or filesystem observer is
       invoked for repair. Only the existing failure-only retry can reread it. *)
    Sys.remove broken;
    let rec advance_when_registered () =
      Eio.Fiber.yield ();
      if not (Eio_mock.Clock.try_advance mock_clock) then advance_when_registered () in
    advance_when_registered ();
    let recovered = frame_after partial Ready_frame in
    check (float 0.) "recovery used the existing failure retry deadline"
      (now +. retry_interval) (Eio.Time.now clock);
    check bool "retry rereads the repaired actual file" true
      (diagnostic recovered "read_completeness" = `String "complete");
    check bool "recovery clears the actual read error" true
      (diagnostic recovered "read_error" = `Null);
    check bool "recovered source still retains its original active judgment" true
      Yojson.Safe.Util.(recovered |> member "recommended_actions" = `List [action]);
    Eio_mock.Clock.set_time mock_clock judgment.fresh_until_unix;
    let expired = frame_after recovered Ready_frame in
    check bool "the independent actual authority deadline is still observed" true
      Yojson.Safe.Util.(expired |> member "recommended_actions" = `List []);
    Eio.Fiber.yield ();
    check bool "after repair and actual expiry no healthy timer remains" false
      (Eio_mock.Clock.try_advance mock_clock))

let test_execution_partial_read_retries_after_quiet_repair () =
  with_runtime (fun ~env ~sw ~clock ~mock_clock ~state ~scope ->
    let module Execution = Server_dashboard_http_execution_surfaces in
    let module Attempt = Execution.For_testing in
    let owner = Attempt.owner_for_state ~state in
    let declarations = Config_dir_resolver.keepers_dir_for_base_path ~base_path:scope.config.base_path in
    Workspace_utils.mkdir_p declarations;
    (match Fs_compat.save_file_atomic (Filename.concat declarations "readable-declaration.toml")
        "[keeper]\nactivation_mode = \"manual\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\ninstructions = \"Help the operator.\"\n" with
     | Ok () -> () | Error detail -> fail detail);
    let broken = Keeper_types_profile.keeper_meta_path scope.config "unread-metadata" in
    (match Fs_compat.save_file_atomic broken "{" with
     | Ok () -> () | Error detail -> fail detail);
    let read suffix = Execution.dashboard_execution_http_json ~state ~sw ~clock
        (Httpun.Request.create `GET ("/api/v1/dashboard/execution" ^ suffix)) in
    let diagnostic json field = Yojson.Safe.Util.(json |> member "projection_diagnostics" |> member field) in
    let assert_partial json =
      check bool "Execution carries actual partial read diagnostics" true
        (diagnostic json "read_completeness" = `String "partial");
      check bool "Execution retains its independently readable row" true
        Yojson.Safe.Util.(json |> member "keepers" |> to_list |> List.exists (fun row ->
          row |> member "name" = `String "readable-declaration"));
      match Keeper_snapshot_unread.list_of_json Yojson.Safe.Util.(json |> member "keepers_unread") with
      | Ok [{name = "unread-metadata"; reason = Meta_read_failed _}] -> ()
      | Ok _ | Error _ -> fail "Execution lost the actual unread metadata" in
    assert_partial (read "?agent_name=partial-reader");
    assert_partial (read "");
    (match Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches state with
     | Some json -> check bool "first partial Execution also reaches cached Namespace" true
         (diagnostic json "read_completeness" = `String "partial")
     | None -> fail "Namespace dropped the first partial observation for lacking full success");
    check (option (float 0.0)) "Execution partial cold fill is not a complete success" None
      (Cache.snapshot (Attempt.cache owner)).last_success_unix;
    let before = Cache.snapshot (Attempt.cache owner) in
    assert_partial (read "");
    check bool "another partial GET cannot bypass source retry" true
      (before == Cache.snapshot (Attempt.cache owner));
    assert_partial (read "?force=true");
    let source_failed, mark_source_failed = Eio.Promise.create () in
    let marked = ref false in
    let unsubscribe = Attempt.subscribe_completion ~owner (function
      | Attempt.Cache_failed Observation_read ->
          if not !marked then (marked := true; Eio.Promise.resolve mark_source_failed ())
      | Cache_failed Request_read | Cache_installed (Observation_read | Request_read)
      | Cache_patched | Shell_installed -> ()) in
    Eio.Switch.on_release sw unsubscribe;
    let frames = Eio.Stream.create 16 and namespace_frames = Eio.Stream.create 8 in
    let id = "actual-execution-partial-retry" in
    Sse.subscribe_external ~id
      ~runtime_authority:(Sse.runtime_authority_exn ~base_path:scope.config.base_path)
      ~observer_instance_id:(Server_observer_scope.instance_id scope)
      ~callback:(fun event ->
        match Yojson.Safe.Util.member "type" event.Sse.ext_payload with
        | `String "execution_snapshot" ->
            Eio.Stream.add frames (Yojson.Safe.Util.member "payload" event.ext_payload)
        | `String "project_snapshot" ->
            Eio.Stream.add namespace_frames (Yojson.Safe.Util.member "payload" event.ext_payload)
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> ()) ();
    Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id);
    Execution.start_execution_refresh_loop ~state ~sw ~clock ~net:(Eio.Stdenv.net env)
      ~mono_clock:(Eio.Stdenv.mono_clock env);
    Eio.Promise.await source_failed;
    let partial_namespace = Eio.Stream.take namespace_frames in
    check bool "actual canonical Namespace reports the partial source" true
      (diagnostic partial_namespace "read_completeness" = `String "partial");
    (* The actual source read has now installed a partial body. Repair emits
       no metadata input or event; only its failure retry can recover. *)
    let failed_at = Eio.Time.now clock in
    Sys.remove broken;
    let rec advance_when_registered () =
      Eio.Fiber.yield ();
      if not (Eio_mock.Clock.try_advance mock_clock) then advance_when_registered () in
    advance_when_registered ();
    let rec complete_frame () =
      let payload = Eio.Stream.take frames in
      match diagnostic payload "read_completeness" with
      | `String "complete" -> payload
      | `String "partial" -> complete_frame ()
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
          fail "Execution canonical frame lost its typed read diagnostics" in
    let recovered = complete_frame () in
    let rec complete_namespace () =
      let payload = Eio.Stream.take namespace_frames in
      match diagnostic payload "read_completeness" with
      | `String "complete" -> ()
      | `String "partial" -> complete_namespace ()
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
          fail "Namespace lost its original typed source completeness" in
    complete_namespace ();
    check (float 0.) "Execution recovers at its existing failure interval" (failed_at +. 60.0)
      (Eio.Time.now clock);
    check bool "the successful actual reread clears read_error" true
      (diagnostic recovered "read_error" = `Null);
    check bool "the repaired source no longer reports unread rows" true
      Yojson.Safe.Util.(recovered |> member "keepers_unread" = `List []);
    check string "canonical completion retains the original observer instance"
      (Server_observer_scope.instance_id scope)
      Yojson.Safe.Util.(recovered |> member "observer_instance_id" |> to_string);
    Eio.Fiber.yield ();
    check bool "quiet recovered Execution has no healthy timer" false (Eio_mock.Clock.try_advance mock_clock))

let test_execution_lifecycle_patch_preserves_typed_namespace_outcome () =
  with_runtime (fun ~env:_ ~sw:_ ~clock:_ ~mock_clock:_ ~state ~scope ->
    let module Execution = Server_dashboard_http_execution_surfaces in
    let module Attempt = Execution.For_testing in
    let owner = Attempt.owner_for_state ~state in
    let row = `Assoc ["name", `String "patched-keeper"; "status", `String "idle";
      "phase", `String "running"; "keepalive_running", `Bool true] in
    let payload row = `Assoc ["keepers", `List [row]] in
    let completeness = [Dashboard_projection_read.Complete; Partial "original source read failed"] in
    List.iter (fun completeness ->
      let read = Attempt.begin_execution_attempt ~owner () in
      check bool "actual source observation is installed" true
        (Attempt.publish_execution_observation read {
          json = payload row; next_deadline_unix = None; completeness});
      let old_attempt = Attempt.begin_execution_attempt ~owner () in
      let old_generation = Attempt.execution_publication_generation ~owner () in
      Execution.patch_keeper_dependent_caches ~keeper_name:"patched-keeper"
        ~event:(Keeper_lifecycle_events.Phase_event Keeper_state_machine.Paused);
      let source, outcome = Execution.execution_cached_observation_for_scope ~state scope in
      check bool "a patch retains the exact original typed read outcome" true (outcome = Some completeness);
      check bool "the patch keeps its hard publication fence" true
        (Attempt.execution_publication_generation ~owner () > old_generation);
      check string "the actual lifecycle patch reached the cached row" "paused"
        Yojson.Safe.Util.(source.json |> member "keepers" |> index 0 |> member "phase" |> to_string);
      (match Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches state with
       | None -> fail "actual patched observation disappeared from canonical Namespace"
       | Some json ->
           let expected = match completeness with Complete -> "complete" | Partial _ -> "partial" in
           check string "Namespace retains the patched source's original completeness" expected
             Yojson.Safe.Util.(json |> member "projection_diagnostics" |> member "read_completeness" |> to_string));
      check bool "an attempt admitted before the lifecycle patch cannot publish" false
        (Attempt.publish_execution_attempt_success old_attempt (payload row))) completeness;
    let read = Attempt.begin_execution_attempt ~owner () in
    let declaration = Keeper_declared_roster.to_json {
      name = "patched-keeper"; requirements = [Runtime_check_required]} in
    check bool "declaration snapshot is admitted" true
      (Attempt.publish_execution_attempt_success read (payload declaration));
    Execution.patch_keeper_dependent_caches ~keeper_name:"patched-keeper"
      ~event:(Keeper_lifecycle_events.Custom_event {verb = Started; phase = None});
    let _, outcome = Execution.execution_cached_observation_for_scope ~state scope in
    check bool "a stale declaration uses actual invalidation, not outcome migration" true (outcome = None);
    check bool "explicit invalidation still removes canonical Namespace readiness" true
      (Option.is_none (Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches state));
    (* The cache helper is also a typed complete writer used by existing
       fixtures. Its explicit success marker remains a complete observation. *)
    Cache.mark_cached_surface_success (Attempt.cache owner) (payload row);
    let _, outcome = Execution.execution_cached_observation_for_scope ~state scope in
    check bool "canonical cache success retains its existing typed contract" true
      (outcome = Some Dashboard_projection_read.Complete))

let () = run "Operator Digest observation owner" ["publication", [
  test_case "request and source admission" `Quick test_request_and_source_admission;
    test_case "partial rows retain failure debt without success" `Quick test_partial_read_retains_body_without_success;
  test_case "current source settlement preserves publication debt" `Quick test_invalidation_then_completion_keeps_publication_debt;
  test_case "same-path request retains original instance" `Quick test_same_path_request_cannot_borrow_a_new_instance;
  test_case "failure retains rows and callback outcome" `Quick test_failure_and_listener_isolation;
  test_case "actual cold read and source policy deadline" `Quick test_actual_cold_read_and_source_deadline;
  test_case "parameter cache stays in its captured workspace" `Quick test_parameter_cache_is_bound_to_the_original_workspace;
  test_case "Mission actual partial read recovers after quiet raw repair" `Quick
    (fun () -> test_actual_partial_retry_after_quiet_repair Mission);
  test_case "Digest actual partial read recovers after quiet raw repair" `Quick
    (fun () -> test_actual_partial_retry_after_quiet_repair Digest);
  test_case "Execution actual partial read recovers after quiet raw repair" `Quick
    test_execution_partial_read_retries_after_quiet_repair;
  test_case "Execution lifecycle patch preserves typed Namespace outcome" `Quick
    test_execution_lifecycle_patch_preserves_typed_namespace_outcome]]
