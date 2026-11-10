open Alcotest
open Masc

module Owner = Server_dashboard_mission_observation
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
  check bool "the read from before the mutation cannot publish" false
    (Owner.publish_success in_flight (observation "old source" None));
  check bool "last-good rows survive while current source read is owed" true
    (Yojson.Safe.Util.member "marker" (Cache.snapshot (Owner.cache owner)).json = `String "last-good");
  let fresh = Owner.begin_attempt owner ~origin:Source_read in
  check bool "next current read settles the actual source debt" true
    (Owner.publish_success fresh (observation "current source" None));
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

let () = run "Mission observation owner"
  ["publication", [
    test_case "own success and ordered attempts" `Quick test_own_success_and_newer_attempt_order;
    test_case "source invalidation keeps actual read debt" `Quick test_invalidated_read_remains_owed;
    test_case "same-path scope retirement preserves instance" `Quick test_same_path_retirement_keeps_its_original_instance;
    test_case "read failure retains rows and original outcome" `Quick test_failure_keeps_last_good_rows_and_callback_outcome]]
