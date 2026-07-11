(** #9764/#9733/#9769: write_meta CAS retry semantics.

    Verifies that [Keeper_meta_store.write_meta_with_merge] with
    [Keeper_meta_merge.caller_wins]:
      - succeeds when no concurrent writer interferes
      - succeeds after N attempts when the disk version has advanced
      - distinguishes typed version conflicts from storage errors *)

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
    (* [goal] is TOML-only, so use the persisted typed goal-id list as the
       round-trip payload marker. *)
    let m1 = { disk with active_goal_ids = [ "goal-updated" ] } in
    match
      Keeper_meta_store.write_meta_with_merge
        ~merge:Keeper_meta_merge.caller_wins config m1
    with
    | Ok () ->
      let after = match Keeper_meta_store.read_meta config "alpha" with
        | Ok (Some m) -> m
        | _ -> fail "read after write failed"
      in
      check (list string) "active_goal_ids updated" [ "goal-updated" ]
        after.active_goal_ids
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
    (match Keeper_meta_store.write_meta config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let caller_view = match Keeper_meta_store.read_meta config "beta" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    (* Simulate a concurrent writer bumping the disk version while
       [caller_view] is held by the cycle-completion fiber. *)
    let racing = { caller_view with active_goal_ids = [ "goal-racing" ] } in
    (match Keeper_meta_store.write_meta config racing with
     | Ok () -> ()
     | Error e -> fail ("racing write failed: " ^ e));
    (* Now the cycle attempts to write its own payload. CAS would fail
       once; caller_wins retry must lift the payload onto the new disk
       version and succeed. *)
    let cycle_payload = { caller_view with active_goal_ids = [ "goal-cycle" ] } in
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
    check (list string) "cycle payload wins (last writer)" [ "goal-cycle" ]
      final.active_goal_ids;
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
    (match Keeper_meta_store.write_meta config m0 with
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

let test_operator_pause_survives_stale_heartbeat_retry () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"operator-pause-cas" in
    (match Keeper_meta_store.write_meta config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let stale_turn_view = match Keeper_meta_store.read_meta config "operator-pause-cas" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    let operator_pause =
      { stale_turn_view with
        paused = true;
        latched_reason =
          Some
            (Keeper_latched_reason.Operator_paused
               { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive });
        auto_resume_after_sec = None;
        runtime = { stale_turn_view.runtime with last_blocker = None };
        updated_at = Keeper_meta_contract.now_iso ();
      }
    in
    (match Keeper_meta_store.write_meta config operator_pause with
     | Ok () -> ()
     | Error e -> fail ("operator pause write failed: " ^ e));
    let stale_completion =
      { stale_turn_view with
        paused = false;
        runtime =
          { stale_turn_view.runtime with
            usage =
              { stale_turn_view.runtime.usage with
                total_turns = stale_turn_view.runtime.usage.total_turns + 1;
              };
          };
        updated_at = Keeper_meta_contract.now_iso ();
      }
    in
    (match
       Keeper_meta_store.write_meta_with_merge
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk config stale_completion
     with
     | Ok () -> ()
     | Error e -> fail ("stale retry write failed: " ^ e));
    let final = match Keeper_meta_store.read_meta config "operator-pause-cas" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check bool "operator pause survives stale retry" true final.paused;
    check bool "auto resume stays disabled" true
      (Option.is_none final.auto_resume_after_sec);
    check bool "stale blocker stays cleared" true
      (Option.is_none final.runtime.last_blocker))

let test_concurrent_same_version_writers_have_one_typed_winner () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let initial = make_meta ~name:"concurrent-cas" in
    (match Keeper_meta_store.write_meta config initial with
     | Ok () -> ()
     | Error err -> fail ("seed write failed: " ^ err));
    let stale =
      match Keeper_meta_store.read_meta config initial.name with
      | Ok (Some meta) -> meta
      | Ok None -> fail "seed meta disappeared"
      | Error err -> fail ("seed read failed: " ^ err)
    in
    let first = { stale with active_goal_ids = [ "first" ] } in
    let second = { stale with active_goal_ids = [ "second" ] } in
    let first_result = ref None in
    let second_result = ref None in
    Eio.Fiber.both
      (fun () -> first_result := Some (Keeper_meta_store.write_meta_result config first))
      (fun () -> second_result := Some (Keeper_meta_store.write_meta_result config second));
    let results =
      [ Option.value ~default:(Error (Keeper_meta_store.Storage_error "first missing")) !first_result
      ; Option.value ~default:(Error (Keeper_meta_store.Storage_error "second missing")) !second_result
      ]
    in
    let successes, conflicts =
      List.fold_left
        (fun (successes, conflicts) -> function
           | Ok () -> successes + 1, conflicts
           | Error (Keeper_meta_store.Version_conflict _) -> successes, conflicts + 1
           | Error (Keeper_meta_store.Storage_error err) ->
             fail ("unexpected storage error: " ^ err))
        (0, 0)
        results
    in
    check int "exactly one same-version writer commits" 1 successes;
    check int "the loser receives a typed conflict" 1 conflicts;
    let persisted =
      match Keeper_meta_store.read_meta config initial.name with
      | Ok (Some meta) -> meta
      | Ok None -> fail "concurrent CAS winner disappeared"
      | Error err -> fail ("concurrent CAS winner read failed: " ^ err)
    in
    check int "winner advances the disk version"
      (stale.meta_version + 1) persisted.meta_version;
    check bool "one complete winner payload reaches disk" true
      (persisted.active_goal_ids = first.active_goal_ids
       || persisted.active_goal_ids = second.active_goal_ids))

(* RFC-0237: the [write_meta ~force:true] escape hatch is removed, so the
   counter-rewind path the four keeper-internal sites carried
   (keeper_tool_surface / keeper_tool_surface_ops / keeper_keepalive /
   keeper_heartbeat_loop_presence) is unrepresentable. A stale-snapshot
   plain write that would have rewound a concurrent turn's counters is now
   rejected by CAS; callers must route through [write_meta_with_merge]
   (proven monotonic by [test_monotonic_usage_counters_on_cas_retry]). This
   test pins that the bypass no longer exists: the stale write conflicts and
   the advanced disk counter survives. *)
let test_stale_write_conflicts_without_force () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let m0 = make_meta ~name:"delta" in
    (match Keeper_meta_store.write_meta config m0 with
     | Ok () -> ()
     | Error e -> fail ("seed write failed: " ^ e));
    let caller_view = match Keeper_meta_store.read_meta config "delta" with
      | Ok (Some m) -> m
      | _ -> fail "seed read failed"
    in
    let with_usage (m : Keeper_meta_contract.keeper_meta) usage =
      { m with runtime = { m.runtime with usage } }
    in
    (* Concurrent turn advances counters on disk, bumping the version. *)
    let racing =
      with_usage caller_view
        { caller_view.runtime.usage with total_turns = 42 }
    in
    (match Keeper_meta_store.write_meta config racing with
     | Ok () -> ()
     | Error e -> fail ("racing write failed: " ^ e));
    (* A stale snapshot write (the shape the old force path clobbered with)
       now hits CAS: its version no longer matches the advanced disk, so the
       write is rejected instead of rewinding the counter. *)
    let stale =
      with_usage caller_view
        { caller_view.runtime.usage with total_turns = 5 }
    in
    (match Keeper_meta_store.write_meta config stale with
     | Ok () -> fail "stale write unexpectedly succeeded (CAS bypass present?)"
     | Error _ -> ());
    (match Keeper_meta_store.write_meta_result config stale with
     | Error (Keeper_meta_store.Version_conflict { expected_version; actual; _ }) ->
       check int "typed conflict carries expected version"
         stale.meta_version expected_version;
       check int "typed conflict carries exact disk version"
         (stale.meta_version + 1) actual.meta_version
     | Error (Keeper_meta_store.Storage_error err) ->
       fail ("expected typed conflict, got storage error: " ^ err)
     | Ok () -> fail "typed stale write unexpectedly succeeded");
    let final = match Keeper_meta_store.read_meta config "delta" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check int "advanced disk counter survives (no rewind without force)"
      42 final.runtime.usage.total_turns)

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
          test_case "operator pause survives stale heartbeat retry"
            `Quick test_operator_pause_survives_stale_heartbeat_retry;
          test_case "concurrent same-version writers have one typed winner"
            `Quick test_concurrent_same_version_writers_have_one_typed_winner;
          test_case "stale write conflicts without force (RFC-0237 escape hatch closed)"
            `Quick test_stale_write_conflicts_without_force;
        ] );
    ]
