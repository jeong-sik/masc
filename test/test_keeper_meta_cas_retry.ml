(** #9764/#9733/#9769: write_meta CAS retry semantics.

    Verifies that [Keeper_meta_store.write_meta_with_merge] with
    [Keeper_meta_merge.caller_wins]:
      - succeeds when no concurrent writer interferes
      - succeeds after N attempts when the disk version has advanced
      - distinguishes version conflicts from real I/O errors via
        [is_version_conflict_error] *)

open Alcotest
open Masc

let () = Server_startup_state.mark_state_ready ~backend_mode:"test"

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_meta_cas_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let ensure_fs env =
  if not (Fs_compat.has_fs ()) then
    Fs_compat.set_fs (Eio.Stdenv.fs env)

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let make_meta ~name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String ("keeper-" ^ name ^ "-agent"));
          ("trace_id", `String ("trace-" ^ name));
          ("goal", `String "test keeper");
          ("autoboot_enabled", `Bool false);
        ])
  with
  | Ok m -> m
  | Error e -> fail ("meta_of_json failed: " ^ e)

let test_no_conflict_writes_first_attempt () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"alpha" in
    (* Initial write — no existing file. *)
    (match
       Keeper_meta_store.write_meta_with_merge
         ~merge:Keeper_meta_merge.caller_wins config m0
     with
     | Ok () -> ()
     | Error e -> fail ("first write failed: " ^ e));
    (* Read what landed on disk and bump caller's version to match. *)
    let disk = match Keeper_meta_store.read_meta config "alpha" with
      | Ok (Some m) -> m
      | _ -> fail "disk read failed"
    in
    (* #20781: [goal] became TOML-only (meta JSON persists runtime state),
       so the round-trip payload marker is [continuity_summary], which is
       still JSON-persisted. *)
    let m1 = { disk with continuity_summary = "updated summary" } in
    match
      Keeper_meta_store.write_meta_with_merge
        ~merge:Keeper_meta_merge.caller_wins config m1
    with
    | Ok () ->
      let after = match Keeper_meta_store.read_meta config "alpha" with
        | Ok (Some m) -> m
        | _ -> fail "read after write failed"
      in
      check string "continuity_summary updated" "updated summary"
        after.continuity_summary
    | Error e -> fail ("second write failed: " ^ e))

let test_retry_succeeds_after_concurrent_bump () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"beta" in
    (match Keeper_meta_store.write_meta ~force:true config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let caller_view = match Keeper_meta_store.read_meta config "beta" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    (* Simulate a concurrent writer bumping the disk version while
       [caller_view] is held by the cycle-completion fiber. *)
    let racing = { caller_view with continuity_summary = "racing writer" } in
    (match Keeper_meta_store.write_meta config racing with
     | Ok () -> ()
     | Error e -> fail ("racing write failed: " ^ e));
    (* Now the cycle attempts to write its own payload. CAS would fail
       once; caller_wins retry must lift the payload onto the new disk
       version and succeed. *)
    let cycle_payload =
      { caller_view with continuity_summary = "cycle payload" }
    in
    let before_retry_metric =
      Otel_metric_store.metric_value_or_zero
        Otel_metric_store.metric_write_meta_cas_retry_total
        ~labels:[("keeper", "beta")]
        ()
    in
    (match
       Keeper_meta_store.write_meta_with_merge
         ~merge:Keeper_meta_merge.caller_wins config cycle_payload
     with
     | Ok () -> ()
     | Error e -> fail ("retry write failed: " ^ e));
    let after_retry_metric =
      Otel_metric_store.metric_value_or_zero
        Otel_metric_store.metric_write_meta_cas_retry_total
        ~labels:[("keeper", "beta")]
        ()
    in
    let final = match Keeper_meta_store.read_meta config "beta" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check string "cycle payload wins (last writer)" "cycle payload"
      final.continuity_summary;
    check bool "version moved past racing write" true
      (final.meta_version > racing.meta_version + 1);
    check (float 0.001) "CAS retry metric increments" 1.0
      (after_retry_metric -. before_retry_metric))

(* RFC-0225 §3.2: a CAS retry from a stale snapshot must not rewind
   cumulative usage counters. Reproduces the 2026-06-10 total_turns
   385→370 regression shape: a concurrent writer advanced the disk
   counters, then a stale cycle write (computed from the old snapshot)
   retried under CAS and — with plain caller_wins — clobbered them. *)
let test_monotonic_usage_counters_on_cas_retry () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"gamma" in
    (match Keeper_meta_store.write_meta ~force:true config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let caller_view = match Keeper_meta_store.read_meta config "gamma" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    let with_usage (m : Keeper_meta_contract.keeper_meta) usage =
      { m with runtime = { m.runtime with usage } }
    in
    (* Concurrent writer advances cumulative counters on disk. *)
    let racing =
      with_usage caller_view
        { caller_view.runtime.usage with
          total_turns = 10; total_tokens = 1000 }
    in
    (match Keeper_meta_store.write_meta config racing with
     | Ok () -> ()
     | Error e -> fail ("racing write failed: " ^ e));
    (* Stale cycle write computed from the pre-race snapshot. *)
    let stale =
      with_usage caller_view
        { caller_view.runtime.usage with
          total_turns = 3; total_tokens = 200; last_latency_ms = 777 }
    in
    (match
       Keeper_meta_store.write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk config stale
     with
     | Ok () -> ()
     | Error e -> fail ("stale retry write failed: " ^ e));
    let final = match Keeper_meta_store.read_meta config "gamma" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check int "total_turns keeps the larger disk value" 10
      final.runtime.usage.total_turns;
    check int "total_tokens keeps the larger disk value" 1000
      final.runtime.usage.total_tokens;
    check int "last_* observation stays with the caller" 777
      final.runtime.usage.last_latency_ms)

(* Characterization of the hazard the dashboard write sites carried:
   [write_meta ~force:true] from a stale snapshot bypasses CAS and
   rewinds cumulative usage counters that a concurrent turn advanced.
   This is why the dashboard PATCH/pause/tool-config paths
   (server_dashboard_http_keeper_api_post.ml, keeper_turn_up_update.ml)
   must route through [write_meta_with_merge]
   ~merge:heartbeat_fields_from_disk instead of [~force:true]. If a
   future change reverts a dashboard write back to [~force:true], the
   counter regression this test pins becomes reachable again. *)
let test_force_write_rewinds_usage_counters () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"delta" in
    (match Keeper_meta_store.write_meta ~force:true config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let caller_view = match Keeper_meta_store.read_meta config "delta" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    let with_usage (m : Keeper_meta_contract.keeper_meta) usage =
      { m with runtime = { m.runtime with usage } }
    in
    (* Concurrent turn advances counters on disk. *)
    let racing =
      with_usage caller_view
        { caller_view.runtime.usage with total_turns = 42 }
    in
    (match Keeper_meta_store.write_meta config racing with
     | Ok () -> ()
     | Error e -> fail ("racing write failed: " ^ e));
    (* A stale snapshot force-write (the old dashboard behavior) ignores
       the disk version and clobbers the advanced counter. *)
    let stale =
      with_usage caller_view
        { caller_view.runtime.usage with total_turns = 5 }
    in
    (match Keeper_meta_store.write_meta ~force:true config stale with
     | Ok () -> ()
     | Error e -> fail ("stale force write failed: " ^ e));
    let final = match Keeper_meta_store.read_meta config "delta" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check int "force:true rewinds total_turns from the concurrent disk value"
      5 final.runtime.usage.total_turns)

let test_is_version_conflict_error_classifies () =
  let conflict_msg = "meta version conflict for foo: expected 3, disk has 4" in
  let other_msg = "failed to write meta /tmp/x: Permission denied" in
  check bool "classifies version conflict" true
    (Keeper_meta_store.is_version_conflict_error conflict_msg);
  check bool "rejects unrelated error" false
    (Keeper_meta_store.is_version_conflict_error other_msg)

let () =
  run "Keeper_types CAS retry (#9764/#9733/#9769)"
    [
      ( "write_meta_with_merge caller_wins",
        [
          test_case "writes on first attempt when no conflict" `Quick
            test_no_conflict_writes_first_attempt;
          test_case "lifts payload onto disk version after concurrent bump" `Quick
            test_retry_succeeds_after_concurrent_bump;
          test_case "usage counters stay monotonic on stale retry (RFC-0225 §3.2)"
            `Quick test_monotonic_usage_counters_on_cas_retry;
          test_case "force:true rewinds counters (dashboard hazard characterization)"
            `Quick test_force_write_rewinds_usage_counters;
        ] );
      ( "is_version_conflict_error",
        [
          test_case "classifies conflict vs I/O error" `Quick
            test_is_version_conflict_error_classifies;
        ] );
    ]
