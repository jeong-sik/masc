open Alcotest
open Masc

module Owner = Server_dashboard_operator_snapshot_observation

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

let observation marker next_deadline_unix : Dashboard_projection_read.observation =
  {json = `Assoc ["marker", `String marker]; next_deadline_unix; completeness = Complete}

let json owner = Owner.publication_json (Owner.publication owner)
let marker owner = Yojson.Safe.Util.(json owner |> member "marker" |> to_string)

let test_hard_approval_invalidation_rejects_old_attempts_and_rows () =
  with_owner (fun _state scope owner ->
    let installed = Owner.begin_attempt owner ~origin:Default_request in
    check bool "first actual body is admitted" true
      (Owner.publish_observation installed (observation "earlier approval rows" None));
    let before = Owner.publication owner in
    let old_read = Owner.begin_attempt owner ~origin:Source_read in
    let invalidations = ref 0 in
    let unsubscribe = Owner.subscribe_completed owner (function
      | Owner.Invalidated -> incr invalidations
      | Installed _ | Failed _ | Source_changed -> ()) in
    Fun.protect ~finally:unsubscribe (fun () ->
      (* Drive the existing mutation authority, not a source-only notice. *)
      Dashboard_projection_cache.invalidate_snapshot_json ~config:scope.config;
      Owner.synchronize_invalidation ();
      check int "one mutation is synchronized once" 1 !invalidations;
      check bool "pre-mutation Current completion is refused" false
        (Owner.publish_observation old_read (observation "stale approval rows" None));
      check bool "its timeout cannot replace the tombstone" false
        (Owner.publish_failure_message old_read "old attempt timeout");
      check bool "the prior prepared payload is superseded" true
        (Owner.publication_status owner before = Owner.Superseded);
      let current = json owner in
      check string "canonical mutation body is invalidated" "invalidated"
        Yojson.Safe.Util.(current |> member "snapshot_observation_state" |> to_string);
      check bool "old approval body is absent" true
        Yojson.Safe.Util.(current |> member "marker" = `Null);
      check bool "mutation tombstone can be published while the read is owed" true
        (Owner.publication_is_current owner (Owner.publication owner));
      let fresh = Owner.begin_attempt owner ~origin:Source_read in
      check bool "a new Current read recovers the mutation generation" true
        (Owner.publish_observation fresh (observation "fresh rows" None));
      check bool "own successful return wins a closing timeout" false
        (Owner.publish_failure_message fresh "late timeout");
      check string "fresh body remains canonical" "fresh rows" (marker owner)))

let test_source_notices_preserve_progress_and_ordered_request_ownership () =
  with_owner (fun _state _scope owner ->
    let first = Owner.begin_attempt owner ~origin:Source_read in
    ignore (Owner.publish_observation first (observation "initial" None));
    let prepared = Owner.publication owner in
    let bytes = Yojson.Safe.to_string (Owner.publication_json prepared) in
    let held_read = Owner.begin_attempt owner ~origin:Source_read in
    check string "attempt bookkeeping does not mutate the prepared identity" bytes
      (Yojson.Safe.to_string (Owner.publication_json (Owner.publication owner)));
    Owner.source_changed owner;
    Owner.source_changed owner;
    Owner.source_changed owner;
    check bool "prepared source body waits for an actual completion" true
      (Owner.publication_status owner prepared = Owner.Source_pending);
    check bool "notices do not starve an actual completed Current read" true
      (Owner.publish_observation held_read (observation "completed while inputs arrived" None));
    check string "the completed observation progresses" "completed while inputs arrived" (marker owner);
    check bool "old publication debt is superseded after completion" true
      (Owner.publication_status owner prepared = Owner.Superseded);
    let source = Owner.begin_attempt owner ~origin:Source_read in
    let request = Owner.begin_attempt owner ~origin:Default_request in
    check bool "newer request installs its own default rows" true
      (Owner.publish_observation request (observation "newer request" None));
    check bool "older source completion cannot replace the request" false
      (Owner.publish_observation source (observation "older source" None));
    check bool "older source failure cannot degrade it" false
      (Owner.publish_failure_message source "older source failed");
    check string "request ownership is preserved" "newer request" (marker owner))

let test_partial_body_and_semantic_deadline_are_same_read () =
  with_owner (fun _state _scope owner ->
    let initial = Owner.begin_attempt owner ~origin:Source_read in
    check bool "healthy read without a deadline installs" true
      (Owner.publish_observation initial (observation "healthy" None));
    check bool "null is a healthy no-deadline observation" true (Owner.observation_is_usable owner);
    let success_at = (Owner.cache_snapshot owner).last_success_unix in
    let partial_read = Owner.begin_attempt owner ~origin:Source_read in
    let at = Time_compat.now () in
    let partial = {(observation "readable partial rows" (Some at)) with
      completeness = Dashboard_projection_read.Partial "actual partial source read"} in
    check bool "actual partial rows are retained" true (Owner.publish_observation partial_read partial);
    check (option (float 0.0)) "partial did not stamp another full success" success_at
      (Owner.cache_snapshot owner).last_success_unix;
    check bool "partial body satisfies a cold response without bypassing retry" true (Owner.has_observation owner);
    check string "the shared wire preserves actual completeness" "partial"
      Yojson.Safe.Util.(json owner |> member "projection_diagnostics" |> member "read_completeness" |> to_string);
    check (float 0.0) "wire carries that original semantic transition" at
      Yojson.Safe.Util.(json owner |> member "snapshot_fresh_until_unix" |> to_number);
    check bool "an elapsed semantic deadline needs a new read" false (Owner.observation_is_usable owner);
    check bool "outer partial failure cannot erase the completed partial rows" false
      (Owner.publish_failure_message partial_read "outer failure callback");
    check string "actual partial rows remain visible" "readable partial rows" (marker owner);
    let failed = Owner.begin_attempt owner ~origin:Source_read in
    check bool "a later read with no result is a separate failure" true
      (Owner.publish_failure_message failed "actual read raised");
    check bool "a failed read does not reissue prior approval rows" true
      Yojson.Safe.Util.(json owner |> member "marker" = `Null))

let test_same_path_replacement_and_listener_failure_keep_original_authority () =
  with_owner (fun state scope owner ->
    let old = Owner.begin_attempt owner ~origin:Default_request in
    (match Mcp_server.set_workspace_config state scope.config with
     | Ok () -> () | Error _ -> fail "same-path workspace replacement failed");
    let replacement = Mcp_server.workspace_scope state in
    let current = Owner.owner_for_scope ~state replacement in
    let unsubscribe = Owner.subscribe_completed current (fun _ -> failwith "broken metadata listener") in
    Fun.protect ~finally:unsubscribe (fun () ->
      let read = Owner.begin_attempt current ~origin:Source_read in
      check bool "listener failure cannot change the successful producer result" true
        (Owner.publish_observation read (observation "replacement" None));
      check bool "retired request cannot publish into the replacement" false
        (Owner.publish_observation old (observation "retired request" None));
      check bool "a delayed old-scope lookup cannot replace the active owner" true
        (Owner.owner_for_scope ~state replacement == current);
      let stale = Owner.owner_for_scope ~state scope in
      check bool "the old captured owner stays retired" false (Owner.is_current stale);
      check bool "a delayed old lookup leaves the current owner intact" true
        (Owner.owner_for_scope ~state replacement == current);
      check string "canonical output attests only its original captured instance"
        (Server_observer_scope.instance_id replacement)
        Yojson.Safe.Util.(json current |> member "observer_instance_id" |> to_string);
      check string "replacement body survives all stale paths" "replacement" (marker current)))

let () = Alcotest.run "operator_snapshot_observation" ["authority", [
  test_case "hard approval generation rejects old attempts and bodies" `Quick
    test_hard_approval_invalidation_rejects_old_attempts_and_rows;
  test_case "source notices preserve progress and ordered request ownership" `Quick
    test_source_notices_preserve_progress_and_ordered_request_ownership;
  test_case "partial body retains the same semantic deadline" `Quick
    test_partial_body_and_semantic_deadline_are_same_read;
  test_case "same-path replacement and listener failure preserve authority" `Quick
    test_same_path_replacement_and_listener_failure_keep_original_authority]]
