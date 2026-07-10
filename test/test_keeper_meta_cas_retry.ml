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
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_dir)
    (fun () ->
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
    let persisted =
      match
        Keeper_meta_store.write_meta_with_merge_returning
          ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
          config
          stale_completion
      with
      | Ok persisted -> persisted
      | Error e -> fail ("stale retry write failed: " ^ e)
    in
    let final = match Keeper_meta_store.read_meta config "operator-pause-cas" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check bool "operator pause survives stale retry" true final.paused;
    check bool "returned snapshot reports preserved operator pause" true persisted.paused;
    check int
      "returned snapshot carries authoritative version"
      final.meta_version
      persisted.meta_version;
    check bool "auto resume stays disabled" true
      (Option.is_none final.auto_resume_after_sec);
    check bool "stale blocker stays cleared" true
      (Option.is_none final.runtime.last_blocker);
    ignore
      (Keeper_registry.register
         ~base_path:config.base_path
         final.name
         stale_completion);
    let live =
      match Keeper_registry.get ~base_path:config.base_path final.name with
      | Some entry -> entry
      | None -> fail "post-install durable reconciliation lost registry entry"
    in
    check int
      "stale registrar refreshes authoritative meta version"
      final.meta_version
      live.meta.meta_version;
    check bool
      "stale registrar preserves durable pause"
      true
      live.meta.paused;
    check bool
      "stale registrar derives Paused FSM"
      true
      (live.phase = Keeper_state_machine.Paused))

let test_concurrent_stale_writers_have_one_cas_winner () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let guard_was_ready = Eio_guard.is_ready () in
  Eio_guard.disable ();
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      if guard_was_ready then Eio_guard.enable () else Eio_guard.disable ();
      cleanup_dir base_dir)
    (fun () ->
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
    let launch candidate =
      Eio.Fiber.yield ();
      Keeper_meta_store.write_meta_returning config candidate
    in
    let first_result = ref None in
    let second_result = ref None in
    Eio.Fiber.both
      (fun () -> first_result := Some (launch first))
      (fun () -> second_result := Some (launch second));
    let first_result =
      Option.value
        ~default:(Error "first concurrent writer did not complete")
        !first_result
    in
    let second_result =
      Option.value
        ~default:(Error "second concurrent writer did not complete")
        !second_result
    in
    let successes, conflicts =
      List.fold_left
        (fun (successes, conflicts) result ->
           match result with
           | Ok persisted -> persisted :: successes, conflicts
           | Error err when Keeper_meta_store.is_version_conflict_error err ->
             successes, err :: conflicts
           | Error err -> fail ("unexpected concurrent CAS error: " ^ err))
        ([], [])
        [ first_result; second_result ]
    in
    check int "exactly one stale writer commits" 1 (List.length successes);
    check int "the other stale writer conflicts" 1 (List.length conflicts);
    let losing_candidate =
      match first_result, second_result with
      | Error _, Ok _ -> first
      | Ok _, Error _ -> second
      | (Ok _ | Error _), (Ok _ | Error _) -> fail "unexpected CAS result split"
    in
    let retried =
      match
        Keeper_meta_store.write_meta_with_merge_returning
          ~merge:Keeper_meta_merge.caller_wins
          config
          losing_candidate
      with
      | Ok persisted -> persisted
      | Error err -> fail ("losing writer retry failed: " ^ err)
    in
    let final =
      match Keeper_meta_store.read_meta config initial.name with
      | Ok (Some meta) -> meta
      | Ok None -> fail "final meta disappeared"
      | Error err -> fail ("final read failed: " ^ err)
    in
    check int
      "serialized winner and retry advance two distinct versions"
      (stale.meta_version + 2)
      final.meta_version;
    check int
      "returned retry snapshot is authoritative"
      final.meta_version
      retried.meta_version;
    check (list string)
      "retry preserves the losing caller payload"
      losing_candidate.active_goal_ids
      final.active_goal_ids)

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
     | Error msg ->
       check bool "stale write is rejected as a version conflict" true
         (Keeper_meta_store.is_version_conflict_error msg));
    let final = match Keeper_meta_store.read_meta config "delta" with
      | Ok (Some m) -> m
      | _ -> fail "final read failed"
    in
    check int "advanced disk counter survives (no rewind without force)"
      42 final.runtime.usage.total_turns)

let test_non_operator_merges_preserve_typed_control_state () =
  let base = make_meta ~name:"typed-control-merge" in
  let blocker =
    Keeper_meta_contract.blocker_info_of_class
      ~detail:"operator decision required"
      Keeper_meta_contract.Ambiguous_post_commit_timeout
  in
  let gate =
    Keeper_latched_reason.Continue_gate_pending
      { gate_id = "continue-exact"
      ; origin = Keeper_latched_reason.Partial_commit
      ; committed_tools = [ "keeper_board_post" ]
      }
  in
  let latest =
    { base with
      meta_version = 7
    ; paused = true
    ; latched_reason = Some gate
    ; auto_resume_after_sec = None
    ; runtime = { base.runtime with last_blocker = Some blocker; generation = 2 }
    }
  in
  let caller_trace = (make_meta ~name:"caller-trace").runtime.trace_id in
  let caller =
    { latest with
      meta_version = 6
    ; agent_name = "keeper-typed-control-merge-agent"
    ; paused = false
    ; latched_reason = None
    ; auto_resume_after_sec = Some 30.
    ; runtime =
        { latest.runtime with
          trace_id = caller_trace
        ; generation = 3
        ; last_blocker = None
        }
    }
  in
  let presence =
    Keeper_meta_merge.non_operator_control_fields_from_disk ~latest ~caller
  in
  check bool "presence merge preserves durable pause" true presence.paused;
  check bool "presence merge preserves exact typed gate" true
    (presence.latched_reason = latest.latched_reason);
  check bool "presence merge preserves durable blocker" true
    (presence.runtime.last_blocker = latest.runtime.last_blocker);
  let repaired =
    Keeper_meta_merge.identity_repair_fields_from_caller ~latest ~caller
  in
  check bool "identity repair preserves durable pause" true repaired.paused;
  check bool "identity repair preserves exact typed gate" true
    (repaired.latched_reason = latest.latched_reason);
  check bool "identity repair preserves durable blocker" true
    (repaired.runtime.last_blocker = latest.runtime.last_blocker);
  check string "identity repair copies caller-owned agent name"
    caller.agent_name repaired.agent_name;
  check bool "identity repair copies caller-owned trace id" true
    (repaired.runtime.trace_id = caller.runtime.trace_id);
  check int "identity repair advances generation"
    caller.runtime.generation repaired.runtime.generation

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
          test_case "operator pause survives stale heartbeat retry"
            `Quick test_operator_pause_survives_stale_heartbeat_retry;
          test_case "concurrent stale writers have one CAS winner"
            `Quick test_concurrent_stale_writers_have_one_cas_winner;
          test_case "non-operator merges preserve typed control state"
            `Quick test_non_operator_merges_preserve_typed_control_state;
          test_case "stale write conflicts without force (RFC-0237 escape hatch closed)"
            `Quick test_stale_write_conflicts_without_force;
        ] );
      ( "is_version_conflict_error",
        [
          test_case "classifies conflict vs I/O error" `Quick
            test_is_version_conflict_error_classifies;
        ] );
    ]
