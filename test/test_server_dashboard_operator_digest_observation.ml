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

let () = run "Operator Digest observation owner" ["publication", [
  test_case "request and source admission" `Quick test_request_and_source_admission;
  test_case "current source settlement preserves publication debt" `Quick test_invalidation_then_completion_keeps_publication_debt;
  test_case "same-path request retains original instance" `Quick test_same_path_request_cannot_borrow_a_new_instance;
  test_case "failure retains rows and callback outcome" `Quick test_failure_and_listener_isolation]]
