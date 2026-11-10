open Alcotest
open Masc

module Owner = Server_dashboard_mission_observation
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

let observation marker next_deadline_unix : Dashboard_briefing.observation =
  {json = `Assoc ["marker", `String marker; "summary", `Assoc ["workspace_health", `String "ok"]];
   next_deadline_unix}

let test_own_success_and_newer_attempt_order () = with_owner (fun _state _scope owner ->
  let older = Owner.begin_attempt owner ~origin:Source_read in
  let newer = Owner.begin_attempt owner ~origin:Default_request in
  check bool "newer successful request is admitted" true
    (Owner.publish_success newer (observation "newer" (Some 123.0)));
  check bool "the same attempt cannot degrade its successful result" false
    (Owner.publish_failure_message newer "outer window closed");
  check bool "an older source read cannot replace the request" false
    (Owner.publish_success older (observation "older" None));
  check bool "the older source failure is rejected too" false
    (Owner.publish_failure_message older "late source failure");
  check (option string) "successful result has no synthetic window error" None
    (Cache.snapshot (Owner.cache owner)).last_error;
  check (option (float 0.0)) "the admitted observation owns its exact deadline" (Some 123.0)
    (Owner.next_deadline_unix owner))

let test_invalidated_read_remains_owed () = with_owner (fun _state _scope owner ->
  let first = Owner.begin_attempt owner ~origin:Source_read in
  check bool "initial answer is admitted" true
    (Owner.publish_success first (observation "last-good" (Some 123.0)));
  let prepared = Owner.publication owner in
  let in_flight = Owner.begin_attempt owner ~origin:Source_read in
  check bool "attempt diagnostics supersede prepared cache bytes" true
    (Owner.publication_status owner prepared = Owner.Superseded);
  Owner.invalidate owner;
  check bool "a dirty source is different from mere preparation supersession" true
    (Owner.publication_status owner prepared = Owner.Source_pending);
  check bool "a read completing after the mutation may publish its actual observation" true
    (Owner.publish_success in_flight (observation "completed read" None));
  check bool "the actual completed read replaces last-good rows despite newer inputs" true
    (Yojson.Safe.Util.member "marker" (Cache.snapshot (Owner.cache owner)).json = `String "completed read");
  let fresh = Owner.begin_attempt owner ~origin:Source_read in
  check bool "the actual follow-up read is admitted too" true
    (Owner.publish_success fresh (observation "current source" None));
  check bool "an older preparation owes publication after the current read has settled" true
    (Owner.publication_status owner prepared = Owner.Superseded);
  check bool "the current immutable publication can be sent" true
    (Owner.publication_is_current owner (Owner.publication owner)))

let test_same_path_retirement_keeps_its_original_instance () = with_owner (fun state old_scope old_owner ->
  let old_attempt = Owner.begin_attempt old_owner ~origin:Default_request in
  let old_payload = Owner.publication old_owner in
  (match Mcp_server.set_workspace_config state old_scope.config with
   | Ok () -> () | Error _ -> fail "same-path replacement failed");
  let scope = Mcp_server.workspace_scope state in
  let current = Owner.owner_for_scope ~state scope in
  check bool "same path receives a distinct cache owner" true (Owner.cache current != Owner.cache old_owner);
  let attempt = Owner.begin_attempt current ~origin:Source_read in
  check bool "current source publishes" true (Owner.publish_success attempt (observation "current scope" None));
  check bool "retired request success is rejected" false
    (Owner.publish_success old_attempt (observation "retired request" None));
  check bool "retired request error is rejected" false
    (Owner.publish_failure_message old_attempt "late retired failure");
  let delayed = Owner.owner_for_scope ~state old_scope in
  check bool "a delayed retired lookup cannot retire the current owner" true
    (Owner.cache current == Owner.cache (Owner.owner_for_scope ~state scope));
  check bool "the delayed private cell cannot be admitted" false (Owner.is_current delayed);
  check bool "the retired immutable payload has a typed retirement result" true
    (Owner.publication_status old_owner old_payload = Owner.Retired);
  check string "retired response keeps its originally captured instance" (Server_observer_scope.instance_id old_scope)
    Yojson.Safe.Util.(old_payload.json |> member "observer_instance_id" |> to_string);
  check string "current canonical payload attests only its own instance" (Server_observer_scope.instance_id scope)
    Yojson.Safe.Util.((Owner.publication current).json |> member "observer_instance_id" |> to_string))

let test_failure_keeps_last_good_rows_and_callback_outcome () = with_owner (fun _state _scope owner ->
  let unsubscribe = Owner.subscribe_completed owner (fun _ -> raise Exit) in
  Fun.protect ~finally:unsubscribe (fun () ->
    let ready = Owner.begin_attempt owner ~origin:Source_read in
    check bool "listener exception cannot replace a committed cache success" true
      (Owner.publish_success ready (observation "last-good" None));
    let failed = Owner.begin_attempt owner ~origin:Source_read in
    check bool "a newer actual read failure is retained" true
      (Owner.publish_failure_message failed "isolated read failure");
    let publication = Owner.publication owner in
    check string "error envelope keeps the exact last-good source rows" "last-good"
      Yojson.Safe.Util.(publication.json |> member "marker" |> to_string);
    check string "wire state makes the failure explicit" "error"
      Yojson.Safe.Util.(publication.json |> member "mission_observation_state" |> to_string);
    check (option string) "cache diagnostic retains the original cause" (Some "isolated read failure")
      publication.source.last_error))

let test_actual_worker_follows_store_and_policy_inputs () = Eio_main.run (fun env ->
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_context = Eio_context.snapshot_state () in
  let previous_clock = Eio_context.get_clock_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock (Unix.gettimeofday ());
  Fun.protect ~finally:(fun () ->
    Eio_context.restore_state previous_context;
    (match previous_clock with Some clock -> Time_compat.set_clock clock | None -> Time_compat.clear_clock ());
    Masc_test_deps.cleanup_test_workspace base_path;
    match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ()) (fun () ->
    (* Real-clock watchdog bounds fixture hangs only, not product freshness. *)
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
          ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
          Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
          let state = Mcp_server.For_testing.create_state ~base_path in
          let scope = Mcp_server.workspace_scope state in
          let config = scope.config in
          ignore (Workspace.init config ~agent_name:None);
          let initial_request = Server_dashboard_http_core_mission.request ~state
              (Httpun.Request.create `GET "/api/v1/dashboard/briefing") in
          let cold = Server_dashboard_http_core_mission.json ~sw
              ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) initial_request in
          check string "the actual cold HTTP read installs canonical default metadata" "ready"
            Yojson.Safe.Util.(cold |> member "mission_observation_state" |> to_string);
          check string "cold HTTP metadata belongs to its captured instance"
            (Server_observer_scope.instance_id scope)
            Yojson.Safe.Util.(cold |> member "observer_instance_id" |> to_string);
          let frames = Eio.Stream.create 8 in
          let id = "actual-mission-source-observation" in
          Sse.subscribe_external ~id
            ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
            ~observer_instance_id:(Server_observer_scope.instance_id scope)
            ~callback:(fun event ->
              if Yojson.Safe.Util.member "type" event.Sse.ext_payload = `String "mission_snapshot" then
                Eio.Stream.add frames (Yojson.Safe.Util.member "payload" event.ext_payload)) ();
          Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id);
          let ordering payload =
            Yojson.Safe.Util.(payload |> member "mission_publication_generation" |> to_int),
            Yojson.Safe.Util.(payload |> member "mission_publication_sequence" |> to_int) in
          let rec ready_after ~previous ~source_changed =
            let payload = Eio.Stream.take frames in
            match Yojson.Safe.Util.member "mission_observation_state" payload with
            | `String "ready" ->
                let generation, sequence = ordering payload in
                let previous_generation, previous_sequence = ordering previous in
                if (if source_changed then generation > previous_generation
                    else generation > previous_generation ||
                      (generation = previous_generation && sequence > previous_sequence))
                then payload else ready_after ~previous ~source_changed
            | `String "initializing" -> ready_after ~previous ~source_changed
            | `String "error" -> fail "production Mission read failed"
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
                fail "Mission frame lost its closed observation state" in
          Server_dashboard_http_core_mission.start ~state ~sw
            ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
            ~mono_clock:(Eio.Stdenv.mono_clock env);
          (* The cached cold fill and the initial source completion can both
             publish ready. Wait for the actual source attempt, then fence
             every later step against retained or duplicate earlier frames. *)
          let initial = ready_after ~previous:cold ~source_changed:false in
          check string "canonical initial success uses the actual captured instance"
            (Server_observer_scope.instance_id scope)
            Yojson.Safe.Util.(initial |> member "observer_instance_id" |> to_string);
          Eio.Fiber.yield ();
          check bool "healthy empty Mission has no refresh clock" false (Eio_mock.Clock.try_advance clock);
          let now = Time_compat.now () in
          let confidence = match Operator_judgment.Confidence.of_float 0.91 with
            | Some value -> value | None -> fail "invalid fixture confidence" in
          let judgment = Operator_judgment.record config ~surface:Operator_judgment.Command_namespace
              ~target_type:Operator_judgment.Workspace ~target_id:None ~summary:"Actual source input"
              ~confidence ~generated_at:(Masc_domain.iso8601_of_unix_seconds now) ~generated_at_unix:now
              ~fresh_until:(Masc_domain.iso8601_of_unix_seconds (now +. 60.0)) ~fresh_until_unix:(now +. 60.0)
              ~keeper_name:"actual-source-judge"
              ~recommended_action:(`Assoc ["action_kind", `String "actual-recorded-action"]) () in
          let changed = ready_after ~previous:initial ~source_changed:true in
          let actions payload = Yojson.Safe.Util.(payload |> member "recommended_actions" |> to_list) in
          check int "actual judgment append reaches the production worker and canonical frame" 1 (List.length (actions changed));
          check bool "canonical action is exactly the original recorded value" true
            (actions changed = [`Assoc ["action_kind", `String "actual-recorded-action"]]);
          let owner = Owner.owner_for_scope ~state scope in
          check (option (float 0.0)) "the worker adopted the exact recorded expiry"
            (Some judgment.fresh_until_unix) (Owner.next_deadline_unix owner);
          Eio_mock.Clock.set_time clock judgment.fresh_until_unix;
          let expired = ready_after ~previous:changed ~source_changed:false in
          check int "at the actual policy deadline no old authority action survives" 0 (List.length (actions expired));
          let stamp = Masc_domain.iso8601_of_unix_seconds (Time_compat.now ()) in
          let agent : Masc_domain.agent = {id = None; name = "actual-mission-agent";
            agent_type = "test"; status = Masc_domain.Active; capabilities = [];
            current_task = None; session_bound_at = stamp; last_seen = stamp; meta = None} in
          Workspace_agent_record.write config (Filename.concat (Workspace.agents_dir config) "actual-mission-agent.json")
            ~previous:None agent;
          let live = ready_after ~previous:expired ~source_changed:true in
          let truth payload = match Yojson.Safe.Util.(payload |> member "agent_briefs" |> to_list) with
            | [row] -> Yojson.Safe.Util.(row |> member "signal_truth" |> to_string)
            | rows -> failf "expected the one actual source agent, got %d" (List.length rows) in
          check string "actual agent write reaches canonical Mission" "live" (truth live);
          let expected = match Masc_domain.parse_iso8601_opt stamp with
            | Some seen -> seen +. 301.0 | None -> fail "fixture timestamp is unreadable" in
          check (option (float 0.0)) "only the actual integer-policy boundary remains" (Some expected)
            (Owner.next_deadline_unix owner);
          Eio_mock.Clock.set_time clock expected;
          let stale = ready_after ~previous:live ~source_changed:false in
          check string "actual semantic expiry changes canonical agent truth" "stale" (truth stale);
          Eio.Fiber.yield ();
          check bool "settled policies leave no healthy cadence or output feedback" false (Eio_mock.Clock.try_advance clock);
          let context = Server_dashboard_http_core_mission.request ~state
              (Httpun.Request.create `GET "/api/v1/dashboard/briefing") in
          (match Mcp_server.set_workspace_config state config with
           | Ok () -> () | Error _ -> fail "same-path worker scope replacement failed");
          let late = Server_dashboard_http_core_mission.json ~sw
              ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t) context in
          check string "request context cannot borrow the replacement instance after dispatch"
            (Server_observer_scope.instance_id scope)
            Yojson.Safe.Util.(late |> member "observer_instance_id" |> to_string))))))

let test_source_burst_preserves_completed_read_and_one_trailing_read () = Eio_main.run (fun env ->
  let previous_fs = Fs_compat.get_fs_opt () in
  let previous_context = Eio_context.snapshot_state () in
  let previous_clock = Eio_context.get_clock_opt () in
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Masc_test_deps.setup_test_workspace () in
  let clock = Eio_mock.Clock.make () in
  Eio_mock.Clock.set_time clock (Unix.gettimeofday ());
  Fun.protect ~finally:(fun () ->
    Dashboard_projection_cache.register_operator_digest_observer {observe_digest = Operator_control.observe};
    Eio_context.restore_state previous_context;
    (match previous_clock with Some clock -> Time_compat.set_clock clock | None -> Time_compat.clear_clock ());
    Masc_test_deps.cleanup_test_workspace base_path;
    match previous_fs with Some fs -> Fs_compat.set_fs fs | None -> Fs_compat.clear_fs ()) (fun () ->
    Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 10.0 (fun () ->
      Eio.Switch.run (fun sw ->
        Eio_context.with_test_env ~net:(Eio.Stdenv.net env)
          ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
          ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
          Time_compat.set_clock (clock :> float Eio.Time.clock_ty Eio.Resource.t);
          let state = Mcp_server.For_testing.create_state ~base_path in
          let scope = Mcp_server.workspace_scope state in
          ignore (Workspace.init scope.config ~agent_name:None);
          let first_started, mark_first_started = Eio.Promise.create () in
          let second_started, mark_second_started = Eio.Promise.create () in
          let first_release, release_first = Eio.Promise.create () in
          let second_release, release_second = Eio.Promise.create () in
          let reads = ref 0 in
          Dashboard_projection_cache.register_operator_digest_observer {
            observe_digest = (fun ?actor ?target_type ?target_id ?include_workers ctx ->
              let result = Operator_control.observe ?actor ?target_type ?target_id ?include_workers ctx in
              incr reads;
              (match !reads with
               | 1 -> Eio.Promise.resolve mark_first_started (); Eio.Promise.await first_release
               | 2 -> Eio.Promise.resolve mark_second_started (); Eio.Promise.await second_release
               | _ -> ());
              result)};
          let frames = Eio.Stream.create 8 in
          let id = "mission-source-burst-observation" in
          Sse.subscribe_external ~id
            ~runtime_authority:(Sse.runtime_authority_exn ~base_path)
            ~observer_instance_id:(Server_observer_scope.instance_id scope)
            ~callback:(fun event ->
              if Yojson.Safe.Util.member "type" event.Sse.ext_payload = `String "mission_snapshot" then
                Eio.Stream.add frames (Yojson.Safe.Util.member "payload" event.ext_payload)) ();
          Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external id);
          let rec ready_after sequence =
            let payload = Eio.Stream.take frames in
            match Yojson.Safe.Util.member "mission_observation_state" payload with
            | `String "ready" ->
                if Yojson.Safe.Util.(payload |> member "mission_publication_sequence" |> to_int) > sequence
                then payload else ready_after sequence
            | `String "initializing" -> ready_after sequence
            | `String "error" -> fail "production Mission burst read failed"
            | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ ->
                fail "Mission burst frame has no closed observation state" in
          Server_dashboard_http_core_mission.start ~state ~sw
            ~clock:(clock :> float Eio.Time.clock_ty Eio.Resource.t)
            ~mono_clock:(Eio.Stdenv.mono_clock env);
          Eio.Promise.await first_started;
          let owner = Owner.owner_for_scope ~state scope in
          let invalidations = Eio.Stream.create 1 in
          let unsubscribe = Owner.subscribe_completed owner (function
            | Owner.Invalidated -> Eio.Stream.add invalidations ()
            | Installed _ | Failed _ -> ()) in
          Eio.Switch.on_release sw unsubscribe;
          let now = Time_compat.now () in
          let confidence = match Operator_judgment.Confidence.of_float 0.91 with
            | Some value -> value | None -> fail "invalid fixture confidence" in
          for revision = 1 to 3 do
            let generated = now -. 200.0 +. float_of_int revision in
            let expired = now -. 100.0 in
            ignore (Operator_judgment.record scope.config ~surface:Operator_judgment.Command_namespace
              ~target_type:Operator_judgment.Workspace ~target_id:None
              ~summary:(Printf.sprintf "Original input %d" revision) ~confidence
              ~generated_at:(Masc_domain.iso8601_of_unix_seconds generated) ~generated_at_unix:generated
              ~fresh_until:(Masc_domain.iso8601_of_unix_seconds expired) ~fresh_until_unix:expired
              ~keeper_name:"burst-source-judge" ());
            (* Observe the production owner's actual input admission before
               writing the next revision, while its first read stays held. *)
            Eio.Stream.take invalidations
          done;
          Eio.Promise.resolve release_first ();
          Eio.Promise.await second_started;
          let first = ready_after 0 in
          check int "first completed read publishes before the trailing read returns" 1
            Yojson.Safe.Util.(first |> member "mission_publication_sequence" |> to_int);
          check int "the source burst leaves exactly one active trailing read" 2 !reads;
          Eio.Promise.resolve release_second ();
          let second = ready_after 1 in
          check int "the one trailing read also publishes" 2
            Yojson.Safe.Util.(second |> member "mission_publication_sequence" |> to_int);
          Eio.Fiber.yield ();
          check bool "settled burst has no healthy refresh clock" false (Eio_mock.Clock.try_advance clock);
          check int "quiet input creates no extra compute" 2 !reads)))))

let () = run "Mission observation owner"
  ["publication", [
    test_case "own success and ordered attempts" `Quick test_own_success_and_newer_attempt_order;
    test_case "source invalidation keeps actual read debt" `Quick test_invalidated_read_remains_owed;
    test_case "same-path scope retirement preserves instance" `Quick test_same_path_retirement_keeps_its_original_instance;
    test_case "read failure retains rows and original outcome" `Quick test_failure_keeps_last_good_rows_and_callback_outcome;
    test_case "actual cold read and worker follow original writes and exact policy deadlines" `Quick test_actual_worker_follows_store_and_policy_inputs;
    test_case "source burst publishes completed read and one trailing read" `Quick test_source_burst_preserves_completed_read_and_one_trailing_read]]
