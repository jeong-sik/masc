(** #9764/#9733/#9769: write_meta CAS retry semantics.

    Verifies that [Keeper_meta_store.write_meta_with_merge] with
    [Keeper_meta_merge.caller_wins]:
      - succeeds when no concurrent writer interferes
      - succeeds after N attempts when the disk version has advanced
      - distinguishes version conflicts from real I/O errors via
        [is_version_conflict_error] *)

open Alcotest
open Masc

let () =
  Server_startup_state.mark_state_ready
    ~backend:Server_startup_state.Filesystem_backend
  |> Result.get_ok

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
    check bool "stale blocker stays cleared" true
      (Option.is_none final.runtime.last_blocker))

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

let test_is_version_conflict_error_classifies () =
  let conflict_msg = "meta version conflict for foo: expected 3, disk has 4" in
  let other_msg = "failed to write meta /tmp/x: Permission denied" in
  check bool "classifies version conflict" true
    (Keeper_meta_store.is_version_conflict_error conflict_msg);
  check bool "rejects unrelated error" false
    (Keeper_meta_store.is_version_conflict_error other_msg)

(* Fix: [paused=false] + [Dead_tombstone] is un-recoverable — lifecycle
   admission denies by the latch regardless of [paused], but every sanctioned
   clear runs through [mark_resumed] / dead revival which nulls the latch. The
   store rejects the split fail-closed so it is unrepresentable on disk. *)
let is_dead_tombstone (m : Keeper_meta_contract.keeper_meta) =
  match m.latched_reason with
  | Some Keeper_latched_reason.Dead_tombstone -> true
  | Some _ | None -> false

let test_store_rejects_unpaused_dead_tombstone () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    (* The canonical pairing (paused=true + Dead_tombstone) writes fine. *)
    let seed =
      { (make_meta ~name:"dead-invariant") with
        paused = true;
        latched_reason = Some Keeper_latched_reason.Dead_tombstone;
      }
    in
    (match Keeper_meta_store.write_meta config seed with
     | Ok () -> ()
     | Error e -> fail ("canonical paused+dead write should succeed: " ^ e));
    let disk = match Keeper_meta_store.read_meta config "dead-invariant" with
      | Ok (Some m) -> m | _ -> fail "seed read failed" in
    (* The illegal split — clear paused, keep the latch — is rejected. *)
    let split = { disk with paused = false } in
    (match Keeper_meta_store.write_meta config split with
     | Ok () ->
       fail "store accepted paused=false + Dead_tombstone (invariant not enforced)"
     | Error _ -> ());
    let after = match Keeper_meta_store.read_meta config "dead-invariant" with
      | Ok (Some m) -> m | _ -> fail "read after rejected write failed" in
    check bool "rejected write left paused=true on disk" true after.paused;
    check bool "rejected write left the Dead_tombstone latch" true
      (is_dead_tombstone after))

let test_mark_resumed_clears_dead_tombstone_and_persists () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun _sw ->
  let base_dir = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_dir) (fun () ->
    let config = Workspace.default_config base_dir in
    ignore (Workspace.init config ~agent_name:(Some "operator"));
    let seed =
      { (make_meta ~name:"resume-dead") with
        paused = true;
        latched_reason = Some Keeper_latched_reason.Dead_tombstone;
      }
    in
    (match Keeper_meta_store.write_meta config seed with
     | Ok () -> () | Error e -> fail ("seed write failed: " ^ e));
    let disk = match Keeper_meta_store.read_meta config "resume-dead" with
      | Ok (Some m) -> m | _ -> fail "seed read failed" in
    let resumed =
      { (Keeper_meta_contract.mark_resumed disk) with
        updated_at = Keeper_meta_contract.now_iso () }
    in
    check (option string) "mark_resumed leaves no invariant violation"
      None (Keeper_meta_contract.dead_tombstone_pause_violation resumed);
    (match Keeper_meta_store.write_meta config resumed with
     | Ok () -> () | Error e -> fail ("resumed write should succeed: " ^ e));
    let after = match Keeper_meta_store.read_meta config "resume-dead" with
      | Ok (Some m) -> m | _ -> fail "read after resume failed" in
    check bool "resumed keeper is unpaused" false after.paused;
    check (option string) "resumed keeper has no latch" None
      (match after.latched_reason with
       | Some r -> Some (Keeper_latched_reason.to_wire r) | None -> None))

let test_dead_tombstone_pause_violation_classifies () =
  let base = make_meta ~name:"classify" in
  let paused_dead =
    { base with paused = true;
      latched_reason = Some Keeper_latched_reason.Dead_tombstone } in
  let unpaused_dead =
    { base with paused = false;
      latched_reason = Some Keeper_latched_reason.Dead_tombstone } in
  let unpaused_none = { base with paused = false; latched_reason = None } in
  check bool "paused+dead is valid (no violation)" true
    (Option.is_none (Keeper_meta_contract.dead_tombstone_pause_violation paused_dead));
  check bool "unpaused+dead is a violation" true
    (Option.is_some (Keeper_meta_contract.dead_tombstone_pause_violation unpaused_dead));
  check bool "unpaused+no-latch is valid" true
    (Option.is_none (Keeper_meta_contract.dead_tombstone_pause_violation unpaused_none))

(* PR #24351 review (P1): [Keeper_turn_up_update.revival_decision] is the
   extracted decision that used to be inlined in [update_keeper]. Before
   this PR, [dead_revival_requested] required [old.paused = true]; this PR
   decoupled it to trigger on the [Dead_tombstone] latch alone -- the
   single riskiest behavior change in the PR, and until now the only tests
   touching this area were store/contract-level (rejecting the split on
   write, [mark_resumed] clearing it). Neither exercised the decision
   itself. These pin the full [latched_reason] x [paused] matrix directly
   against the pure function, no store/disk involved. *)
let grpc_directive_pause =
  Keeper_latched_reason.Operator_paused
    { operator_actor = Keeper_latched_reason.operator_actor_grpc_directive }

(* The scenario the PR title promises: a keeper stranded at
   paused=false + Dead_tombstone (the split
   [test_store_rejects_unpaused_dead_tombstone] shows the store now refuses
   to persist, but which legacy writers predating this PR could already
   have left on disk) must still be revivable via masc_keeper_up, not
   permanently stuck. *)
let test_revival_decision_stranded_dead_tombstone_is_revivable () =
  let decision =
    Keeper_turn_up_update.revival_decision
      ~latched_reason:(Some Keeper_latched_reason.Dead_tombstone) ~paused:false
  in
  check bool "stranded dead_tombstone requests dead-revival" true
    decision.dead_revival_requested;
  check bool "stranded dead_tombstone clears pause state" true
    decision.clear_pause_state

let test_revival_decision_matrix () =
  let case ~label ~latched_reason ~paused ~expect_dead_revival ~expect_clear =
    let decision = Keeper_turn_up_update.revival_decision ~latched_reason ~paused in
    check bool (label ^ ": dead_revival_requested") expect_dead_revival
      decision.dead_revival_requested;
    check bool (label ^ ": clear_pause_state") expect_clear
      decision.clear_pause_state
  in
  case ~label:"no latch, not paused" ~latched_reason:None ~paused:false
    ~expect_dead_revival:false ~expect_clear:false;
  case ~label:"no latch, paused (plain resume)" ~latched_reason:None ~paused:true
    ~expect_dead_revival:false ~expect_clear:true;
  case ~label:"operator_paused latch, not paused (inconsistent state, not dead-revival)"
    ~latched_reason:(Some grpc_directive_pause) ~paused:false
    ~expect_dead_revival:false ~expect_clear:false;
  case ~label:"operator_paused latch, paused (canonical operator-pause resume)"
    ~latched_reason:(Some grpc_directive_pause) ~paused:true
    ~expect_dead_revival:false ~expect_clear:true;
  case ~label:"dead_tombstone latch, not paused (stranded -- must still revive)"
    ~latched_reason:(Some Keeper_latched_reason.Dead_tombstone) ~paused:false
    ~expect_dead_revival:true ~expect_clear:true;
  case ~label:"dead_tombstone latch, paused (canonical dead-revival)"
    ~latched_reason:(Some Keeper_latched_reason.Dead_tombstone) ~paused:true
    ~expect_dead_revival:true ~expect_clear:true

let () =
  run "Keeper_types CAS retry (#9764/#9733/#9769)"
    [
      ( "dead-tombstone pause invariant",
        [
          test_case "store rejects paused=false + Dead_tombstone split" `Quick
            test_store_rejects_unpaused_dead_tombstone;
          test_case "mark_resumed clears the latch and persists" `Quick
            test_mark_resumed_clears_dead_tombstone_and_persists;
          test_case "dead_tombstone_pause_violation classifies states" `Quick
            test_dead_tombstone_pause_violation_classifies;
        ] );
      ( "update_keeper revival_decision (#24351)",
        [
          test_case "stranded paused=false + Dead_tombstone is still revivable" `Quick
            test_revival_decision_stranded_dead_tombstone_is_revivable;
          test_case "latched_reason x paused decision matrix" `Quick
            test_revival_decision_matrix;
        ] );
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
          test_case "stale write conflicts without force (RFC-0237 escape hatch closed)"
            `Quick test_stale_write_conflicts_without_force;
        ] );
      ( "is_version_conflict_error",
        [
          test_case "classifies conflict vs I/O error" `Quick
            test_is_version_conflict_error_classifies;
        ] );
    ]
