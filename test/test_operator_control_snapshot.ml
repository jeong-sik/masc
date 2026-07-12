module Types = Masc_domain

open Masc
open Test_operator_control_support

let last_substring_index haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  if n_len = 0 || n_len > h_len then None
  else
    let rec loop i last =
      if i + n_len > h_len then last
      else
        let last =
          if String.sub haystack i n_len = needle then Some i else last
        in
        loop (i + 1) last
    in
    loop 0 None

(* Find the FIRST occurrence of [needle] in [haystack] at or after
   [from].  Used by the regression below to anchor on the emit that
   actually follows the timing computations, rather than the last
   occurrence in the file (which can be unrelated, e.g. an early
   paused-branch emit at a higher offset, or a new caller added later
   anywhere in the source). *)
let first_substring_index_after haystack needle ~from =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  if n_len = 0 || n_len > h_len || from >= h_len then None
  else
    let rec loop i =
      if i + n_len > h_len then None
      else if String.sub haystack i n_len = needle then Some i
      else loop (i + 1)
    in
    loop (max 0 from)

let expect_source_marker source marker =
  match last_substring_index source marker with
  | Some idx -> idx
  | None -> Alcotest.failf "source marker not found: %s" marker

(* PR #13114 regression guard.

   The regression we defend against: the non-paused branch of
   [keepers_json] computed [dt_profile] / [dt_activity] AFTER calling
   [emit_timing_log], so the timing log always reported zero for the
   profile and activity fields.

   The invariant: in the non-paused branch, both timing assignments
   must precede the [emit_timing_log] call that consumes them.  The
   file also contains an early [emit_timing_log] call in the paused
   branch (which intentionally exits before the timing
   computations), so a literal "last emit in file" anchor is fragile
   — Copilot correctly flagged this could mask a real regression if
   a new [emit_timing_log] caller appeared anywhere later in the
   file.

   Robust formulation: anchor on the FIRST [emit_timing_log] that
   appears at or after both [dt_profile :=] and [dt_activity :=].
   That is exactly the "timing log emitted after the timing
   computations" the PR enforces, regardless of how many other
   [emit_timing_log] callers exist before or after. *)
let test_keeper_subop_timing_log_after_profile_activity () =
  let root = Masc_test_deps.find_project_root () in
  let path =
    Filename.concat root "lib/operator/operator_control_snapshot.ml"
  in
  let source =
    match Safe_ops.read_file_safe path with
    | Ok text -> text
    | Error err -> Alcotest.failf "read %s failed: %s" path err
  in
  let profile_idx =
    expect_source_marker source
      "dt_profile := Time_compat.now () -. t_profile"
  in
  let activity_idx =
    expect_source_marker source
      "dt_activity := Time_compat.now () -. t_act"
  in
  let timings_done_idx = max profile_idx activity_idx in
  let emit_idx =
    match
      first_substring_index_after source
        "emit_timing_log (Time_compat.now () -. t_work_start)"
        ~from:timings_done_idx
    with
    | Some idx -> idx
    | None ->
        Alcotest.failf
          "no [emit_timing_log (Time_compat.now () -. t_work_start)] found \
           after the latest dt_profile/dt_activity assignment (last at byte \
           %d).  PR #13114 requires the non-paused branch to call the \
           timing log AFTER computing both deltas."
          timings_done_idx
  in
  Alcotest.(check bool) "profile timing computed before non-paused log" true
    (profile_idx < emit_idx);
  Alcotest.(check bool) "activity timing computed before non-paused log" true
    (activity_idx < emit_idx)

let test_align_keeper_runtime_status_promotes_fresh_runtime_signal () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive"
      ~diagnostic:(`Assoc [ ("health_state", `String "offline") ])
      ~agent_status_json:
        (`Assoc
          [
            ("status", `String "busy");
            ("last_seen_ago_s", `Float 5.0);
            ("is_zombie", `Bool false);
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "fresh runtime signal promotes keeper status" "busy"
    status

let test_align_keeper_runtime_status_preserves_attention_health () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive"
      ~diagnostic:(`Assoc [ ("health_state", `String "degraded") ])
      ~agent_status_json:
        (`Assoc
          [
            ("status", `String "active");
            ("last_seen_ago_s", `Float 5.0);
            ("is_zombie", `Bool false);
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "degraded health remains inactive" "inactive" status

let test_align_keeper_runtime_status_ignores_zombie_runtime_signal () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive"
      ~diagnostic:(`Assoc [ ("health_state", `String "offline") ])
      ~agent_status_json:
        (`Assoc
          [
            ("status", `String "active");
            ("last_seen_ago_s", `Float 5.0);
            ("is_zombie", `Bool true);
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "zombie runtime does not override inactive" "inactive"
    status

let test_align_keeper_runtime_status_tolerates_null_status_json () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive" ~diagnostic:`Null ~agent_status_json:`Null
      ~keepalive_running:true
  in
  Alcotest.(check string) "null runtime status keeps surface status" "inactive"
    status

let test_compute_context_ratio_resolves_budget_and_clamps_at_ceiling () =
  (* The runtime_id ("primary") resolves to an effective context budget via
     [Keeper_context_runtime]; [last_input_tokens] here is deliberately above
     that budget, so the ratio is clamped to the [0,1] ceiling (1.0). The
     pre-#22080 stub returned [None] (no budget was ever inferred); this test
     now pins the resolved+clamped behaviour, not the absence of inference. *)
  let base =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String "ctx-ratio-demo");
            ("agent_name", `String "keeper-ctx-ratio-demo-agent");
            ("trace_id", `String "trace-ctx-ratio-demo");
            ("runtime_id", `String "primary");
          ])
    with
    | Ok meta -> meta
    | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
  in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              (* over-budget on purpose: ratio clamps to 1.0 *)
              last_input_tokens = 2_106_223;
            };
        };
    }
  in
  Alcotest.(check (option (float 0.0001)))
    "resolved budget clamps an over-budget ratio to 1.0" (Some 1.0)
    (Operator_control_snapshot.compute_context_ratio meta)

let test_snapshot_prefers_metrics_context_truth_over_usage_counters () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name = "owner";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_name = "ctx-truth" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Prefer metrics context truth");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      let updated_meta =
        {
          meta with
          runtime =
            {
              meta.runtime with
              usage =
                {
                  meta.runtime.usage with
                  last_input_tokens = 6_637_033;
                  last_total_tokens = 6_670_646;
                };
            };
        }
      in
      (match Keeper_meta_store.write_meta config updated_meta with
      | Ok () -> ()
      | Error err -> Alcotest.fail err);
      let metrics_store = Keeper_types_support.keeper_metrics_store config keeper_name in
      Dated_jsonl.append metrics_store
        (`Assoc
          [
            ("ts", `String (Masc_domain.now_iso ()));
            ("channel", `String "heartbeat");
            ("snapshot_source", `String "keeper_context_status");
            ("context_ratio", `Float 0.1274375);
            ("context_tokens", `Int 16312);
            ("context_max", `Int 128000);
          ]);
      Operator_control.invalidate_snapshot_cache ();
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:false
          (operator_ctx env sw config "owner")
      in
      let keeper =
        match
          Yojson.Safe.Util.(json |> member "keepers" |> member "items" |> to_list)
          |> List.find_opt (fun row ->
                 Yojson.Safe.Util.(row |> member "name" |> to_string) = keeper_name)
        with
        | Some keeper -> keeper
        | None -> Alcotest.fail "expected keeper in snapshot"
      in
      let latest_metrics_snapshot =
        Dated_jsonl.read_recent_lines metrics_store 8
        (* read_recent_lines returns chronological order; inspect newest first. *)
        |> List.rev
        |> List.find_map (fun line ->
               try
                 let json = Yojson.Safe.from_string line in
                 match Safe_ops.json_string_opt "snapshot_source" json with
                 | Some "keeper_context_status" ->
                     Option.bind (Safe_ops.json_float_opt "context_ratio" json)
                       (fun ratio ->
                         Option.bind (Safe_ops.json_int_opt "context_tokens" json)
                           (fun tokens ->
                             Option.map
                               (fun max_ctx -> (ratio, tokens, max_ctx))
                               (Safe_ops.json_int_opt "context_max" json)))
                 | _ -> None
               with Yojson.Json_error _ -> None)
      in
      let metrics_ratio, metrics_tokens, metrics_max =
        match latest_metrics_snapshot with
        | Some snapshot -> snapshot
        | None -> Alcotest.fail "expected keeper_context_status metrics snapshot"
      in
      let usage_ratio =
        Operator_control_snapshot.compute_context_ratio updated_meta
      in
      let snapshot_ratio =
        Yojson.Safe.Util.(keeper |> member "context_ratio" |> to_float)
      in
      let snapshot_tokens =
        Yojson.Safe.Util.(keeper |> member "context_tokens" |> to_int)
      in
      let snapshot_max =
        Yojson.Safe.Util.(keeper |> member "context_max" |> to_int)
      in
      Alcotest.(check (float 0.000001)) "latest metrics ratio retained"
        metrics_ratio snapshot_ratio;
      Alcotest.(check int) "latest metrics tokens retained"
        metrics_tokens snapshot_tokens;
      Alcotest.(check int) "latest metrics max retained"
        metrics_max snapshot_max;
      Alcotest.(check string) "metrics source retained" "keeper_context_status"
        Yojson.Safe.Util.(keeper |> member "context_source" |> to_string);
      Alcotest.(check (option (float 0.000001)))
        "usage fallback does not infer provider context" None usage_ratio;
      Alcotest.(check bool) "metrics tokens differ from usage fallback" true
        (snapshot_tokens <> updated_meta.runtime.usage.last_input_tokens);
      Alcotest.(check bool) "nested context payload omitted" true
        (Yojson.Safe.Util.member "context" keeper = `Null))

let test_keeper_up_clears_dead_tombstone_resume_state () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "dead-tombstone-operator-resume" in
  Eio.Switch.on_release sw (fun () ->
    Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
    Keeper_registry.clear ();
    Keeper_runtime.reset_test_state base_dir;
    cleanup_dir base_dir);
  let config = Workspace.default_config base_dir in
  ignore (Workspace.init config ~agent_name:(Some "operator"));
  ignore
    (Workspace.bind_session config ~agent_name:"operator" ~capabilities:[] ());
  (* A resumable keeper resolves its sandbox_profile from a keeper profile TOML;
     masc_keeper_up fails closed without one — this is intentional
     (keeper_meta_contract [effective_meta_of_profile_defaults], and the
     "missing profile source fails loudly" contract test). Seed the profile the
     way a real workspace persists it so this test exercises the operator-resume
     clearing path rather than the missing-profile rejection. *)
  let () =
    let keepers_dir =
      List.fold_left Filename.concat base_dir [ ".masc"; "config"; "keepers" ]
    in
    Fs_compat.mkdir_p keepers_dir;
    Fs_compat.save_file
      (Filename.concat keepers_dir (keeper_name ^ ".toml"))
      "[keeper]\nsandbox_profile = \"local\"\n"
  in
  let keeper_ctx : _ Keeper_tool_surface.context =
    {
      config;
      agent_name = "operator";
      sw;
      clock = Eio.Stdenv.clock env;
      proc_mgr = Some (Eio.Stdenv.process_mgr env);
      net = None;
    }
  in
  let read_meta label =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.failf "expected %s keeper meta" label
    | Error err -> Alcotest.fail err
  in
  let seeded =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String keeper_name);
            ("agent_name", `String (Keeper_identity.keeper_agent_name keeper_name));
            ("trace_id", `String "trace-dead-tombstone-operator-resume");
            ("goal", `String "Resume a tombstoned keeper");
            ("runtime_id", `String "runtime.primary");
          ])
    with
    | Error err -> Alcotest.fail ("keeper meta fixture failed: " ^ err)
    | Ok meta ->
      {
        meta with
        paused = true;
        latched_reason = Some Keeper_latched_reason.Dead_tombstone;
        auto_resume_after_sec = Some 60.0;
        runtime =
          {
            meta.runtime with
            last_blocker =
              Some
                (Keeper_meta_contract.blocker_info_of_class
                   ~detail:"stale timeout before operator resume"
                   Keeper_meta_contract.Turn_timeout);
          };
      }
  in
  (match Keeper_meta_store.write_meta config seeded with
  | Ok () -> ()
  | Error err -> Alcotest.fail err);
  let persisted_seed = read_meta "seeded tombstone" in
  Alcotest.(check bool) "seed is paused" true persisted_seed.paused;
  Alcotest.(check bool) "seed has terminal latch" true
    (Option.is_some persisted_seed.latched_reason);
  Alcotest.(check bool) "seed has auto-resume delay" true
    (Option.is_some persisted_seed.auto_resume_after_sec);
  Alcotest.(check bool) "seed has runtime blocker" true
    (Option.is_some persisted_seed.runtime.last_blocker);
  let dead_entry =
    Keeper_registry.register_offline ~base_path:base_dir keeper_name persisted_seed
  in
  Keeper_registry.mark_dead ~base_path:base_dir keeper_name
    ~at:(Time_compat.now ());
  (match
     Keeper_lane.reject_before_start
       dead_entry.lane
       ~reason:(Failure "seed dead tombstone")
   with
   | Ok () -> ()
   | Error error ->
     Alcotest.fail
       ("failed to settle seeded Dead lane: "
        ^ Keeper_lane.start_error_to_string error));
  ignore
    (Keeper_registry.resolve_done
       dead_entry
       ~source:"operator_control_snapshot_seed"
       (`Crashed "seed dead tombstone")
      : Keeper_registry.done_resolve_result);
  let ok, dispatch_message =
    dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
      ~args:
        (`Assoc
          [
            ("name", `String keeper_name);
            ("goal", `String "Resume tombstoned keeper");
            ("proactive_enabled", `Bool false);
            ("autoboot_enabled", `Bool false);
          ])
  in
  (* Surface the tool_result message so a rejection reports its cause instead of
     a bare [Received false]; the previous [_] discarded the failure detail. *)
  if not ok then
    Alcotest.failf "masc_keeper_up rejected the tombstoned resume: %s"
      dispatch_message;
  Alcotest.(check bool) "keeper_up resumes tombstoned keeper" true ok;
  let running_entry =
    match Keeper_registry.get ~base_path:base_dir keeper_name with
    | Some entry -> entry
    | None -> Alcotest.fail "revival committed without a registry lane"
  in
  Alcotest.(check bool) "revival launches a running lane" true
    (running_entry.phase = Keeper_state_machine.Running);
  Alcotest.(check bool) "revival replaces the exact Dead lane" true
    (not
       (Keeper_lane.Id.equal
          (Keeper_lane.id running_entry.lane)
          (Keeper_lane.id dead_entry.lane)));
  Alcotest.(check bool) "revival mints a new generation" true
    (running_entry.meta.runtime.generation > persisted_seed.runtime.generation);
  let journal_path =
    List.fold_left Filename.concat base_dir
      [ ".masc"; "keeper-lifecycle-transactions"; keeper_name ^ ".json" ]
  in
  Alcotest.(check bool) "committed revival clears durable journal" false
    (Fs_compat.file_exists journal_path);
  ignore
    (Keeper_keepalive.stop_keepalive_and_await
       ~base_path:base_dir keeper_name);
  let resumed = read_meta "resumed" in
  Alcotest.(check bool) "operator resume clears paused" false resumed.paused;
  Alcotest.(check bool) "operator resume clears terminal latch" true
    (Option.is_none resumed.latched_reason);
  Alcotest.(check bool) "operator resume clears auto-resume delay" true
    (Option.is_none resumed.auto_resume_after_sec);
  Alcotest.(check bool) "operator resume clears runtime blocker" true
    (Option.is_none resumed.runtime.last_blocker)

let test_lifecycle_reservation_is_per_keeper_and_owner_typed () =
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let module Reservation = Keeper_lifecycle_reservation in
      let start = Atomic.make false in
      let attempted = Atomic.make 0 in
      let worker () =
        while not (Atomic.get start) do
          Domain.cpu_relax ()
        done;
        let result =
          Reservation.acquire
            ~base_path:base_dir
            ~keeper_name:"concurrent"
            ~expected_generation:11
            ~purpose:Reservation.Dead_revival
        in
        Atomic.incr attempted;
        (match result with
         | Ok token ->
           while Atomic.get attempted < 2 do
             Domain.cpu_relax ()
           done;
           ignore (Reservation.release token : Reservation.release_outcome)
         | Error _ -> ());
        result
      in
      let left = Domain.spawn worker in
      let right = Domain.spawn worker in
      Atomic.set start true;
      let concurrent_results = [ Domain.join left; Domain.join right ] in
      let owners, conflicts =
        List.fold_left
          (fun (owners, conflicts) -> function
             | Ok _ -> owners + 1, conflicts
             | Error (Reservation.Already_reserved _) -> owners, conflicts + 1)
          (0, 0)
          concurrent_results
      in
      Alcotest.(check int) "concurrent requests have one owner" 1 owners;
      Alcotest.(check int) "concurrent follower gets typed conflict" 1 conflicts;
      let first =
        match
          Reservation.acquire
            ~base_path:base_dir
            ~keeper_name:"alpha"
            ~expected_generation:7
            ~purpose:Reservation.Dead_revival
        with
        | Ok token -> token
        | Error _ -> Alcotest.fail "first reservation acquisition failed"
      in
      Fun.protect
        ~finally:(fun () -> ignore (Reservation.release first : Reservation.release_outcome))
        (fun () ->
          (match
             Reservation.acquire
               ~base_path:base_dir
               ~keeper_name:"alpha"
               ~expected_generation:7
               ~purpose:Reservation.Dead_revival
           with
           | Error (Reservation.Already_reserved owner) ->
             Alcotest.(check int) "conflict reports expected generation" 7
               owner.expected_generation
           | Ok token ->
             ignore (Reservation.release token : Reservation.release_outcome);
             Alcotest.fail "same keeper acquired two lifecycle owners");
          (match
             Reservation.authorize
               ~base_path:base_dir
               ~keeper_name:"alpha"
               ()
           with
           | Error owner ->
             Alcotest.(check int) "unowned mutation sees reservation" 7
               owner.expected_generation
           | Ok () -> Alcotest.fail "unowned mutation crossed reservation");
          (match
             Reservation.authorize
               ~token:first
               ~base_path:base_dir
               ~keeper_name:"alpha"
               ()
           with
           | Ok () -> ()
           | Error _ -> Alcotest.fail "opaque owner token was rejected");
          let other =
            match
              Reservation.acquire
                ~base_path:base_dir
                ~keeper_name:"beta"
                ~expected_generation:3
                ~purpose:Reservation.Dead_revival
            with
            | Ok token -> token
            | Error _ -> Alcotest.fail "reservation leaked across keeper lanes"
          in
          Alcotest.(check bool) "different keeper has independent owner" true
            (not (String.equal (Reservation.owner_id first) (Reservation.owner_id other)));
          ignore (Reservation.release other : Reservation.release_outcome)))

let test_lifecycle_owner_gates_meta_and_registry_mutations () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ "name", `String "reserved-dead"
              ; "agent_name", `String (Keeper_identity.keeper_agent_name "reserved-dead")
              ; "trace_id", `String "trace-reserved-dead"
              ; "goal", `String "Verify lifecycle ownership"
              ; "runtime_id", `String "runtime.primary"
              ])
        with
        | Ok meta -> meta
        | Error detail -> Alcotest.fail detail
      in
      (match Keeper_meta_store.write_meta config meta with
       | Ok () -> ()
       | Error detail -> Alcotest.fail detail);
      let persisted =
        match Keeper_meta_store.read_meta config meta.name with
        | Ok (Some persisted) -> persisted
        | Ok None -> Alcotest.fail "seeded metadata disappeared"
        | Error detail -> Alcotest.fail detail
      in
      let token =
        match
          Keeper_lifecycle_reservation.acquire
            ~base_path:base_dir
            ~keeper_name:persisted.name
            ~expected_generation:persisted.runtime.generation
            ~purpose:Keeper_lifecycle_reservation.Dead_revival
        with
        | Ok token -> token
        | Error _ -> Alcotest.fail "lifecycle reservation acquisition failed"
      in
      Fun.protect
        ~finally:(fun () ->
          ignore
            (Keeper_lifecycle_reservation.release token
              : Keeper_lifecycle_reservation.release_outcome))
        (fun () ->
          (match Keeper_meta_store.write_meta config persisted with
           | Error _ -> ()
           | Ok () -> Alcotest.fail "unowned durable write crossed reservation");
          (match
             Keeper_registry.register_offline_if_admitted
               ~base_path:base_dir
               persisted.name
               persisted
           with
           | Error (Keeper_registry.Registration_lifecycle_reserved owner) ->
             Alcotest.(check int) "registration conflict generation"
               persisted.runtime.generation owner.expected_generation
           | Error
               ( Keeper_registry.Registration_shutdown_reserved _
               | Keeper_registry.Registration_invalid _
               | Keeper_registry.Registration_event_queue_unavailable _ ) ->
             Alcotest.fail "registration failed for a non-lifecycle reason"
           | Ok _ -> Alcotest.fail "unowned registration crossed reservation");
          let entry =
            match
              Keeper_registry.register_offline_if_admitted_for_lifecycle
                token
                ~base_path:base_dir
                persisted.name
                persisted
            with
            | Ok entry -> entry
            | Error _ -> Alcotest.fail "owner registration was rejected"
          in
          (match Keeper_registry.update_entry_exact entry Fun.id with
           | Keeper_registry.Exact_update_invalid
               (Keeper_registry.Lifecycle_transaction_reserved _) -> ()
           | Keeper_registry.Exact_updated
           | Keeper_registry.Exact_update_missing
           | Keeper_registry.Exact_update_replaced
           | Keeper_registry.Exact_update_invalid
               ( Keeper_registry.Healthy
               | Keeper_registry.Meta_validation_failed _
               | Keeper_registry.Required_field_missing _
               | Keeper_registry.Base_path_mismatch _
               | Keeper_registry.Name_mismatch _ ) ->
             Alcotest.fail "unowned exact registry update crossed reservation");
          (match
             Keeper_registry.update_entry_exact_for_lifecycle token entry Fun.id
           with
           | Keeper_registry.Exact_updated -> ()
           | Keeper_registry.Exact_update_missing
           | Keeper_registry.Exact_update_replaced
           | Keeper_registry.Exact_update_invalid _ ->
             Alcotest.fail "owner exact registry update was rejected");
          (match Keeper_registry.unregister_exact_for_lifecycle token entry with
           | Keeper_registry.Exact_unregistered -> ()
           | Keeper_registry.Exact_entry_missing
           | Keeper_registry.Exact_entry_replaced
           | Keeper_registry.Exact_unregister_lifecycle_reserved _ ->
             Alcotest.fail "owner exact unregister was rejected")))

let test_dead_revival_launch_failure_rolls_back_both_authorities () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "dead-revival-rollback" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
      Keeper_registry.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let original_seed =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ "name", `String keeper_name
              ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
              ; "trace_id", `String "trace-dead-revival-rollback"
              ; "goal", `String "Rollback a rejected revival"
              ; "runtime_id", `String "runtime.primary"
              ])
        with
        | Error detail -> Alcotest.fail detail
        | Ok meta ->
          { meta with
            paused = true
          ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
          }
      in
      (match Keeper_meta_store.write_meta config original_seed with
       | Ok () -> ()
       | Error detail -> Alcotest.fail detail);
      let original =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "rollback seed metadata disappeared"
        | Error detail -> Alcotest.fail detail
      in
      let dead_entry =
        Keeper_registry.register_offline ~base_path:base_dir keeper_name original
      in
      Keeper_registry.mark_dead ~base_path:base_dir keeper_name
        ~at:(Time_compat.now ());
      (match
         Keeper_lane.reject_before_start
           dead_entry.lane
           ~reason:(Failure "seed dead revival rollback")
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail (Keeper_lane.start_error_to_string error));
      ignore
        (Keeper_registry.resolve_done
           dead_entry
           ~source:"dead_revival_rollback_seed"
           (`Crashed "seed")
          : Keeper_registry.done_resolve_result);
      let candidate =
        { original with
          agent_name = "intentionally-invalid-transaction-identity"
        ; paused = false
        ; latched_reason = None
        }
      in
      let ctx : _ Keeper_tool_surface.context =
        { config
        ; agent_name = "operator"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = None
        }
      in
      (match Keeper_dead_revival_transaction.revive ctx ~original ~candidate with
       | Error
           (Keeper_dead_revival_transaction.Launch_failed
              Keeper_keepalive.Keepalive_identity_unrepairable) -> ()
       | Error error ->
         Alcotest.fail
           ("unexpected revival failure: "
            ^ Keeper_dead_revival_transaction.error_to_string error)
       | Ok _ -> Alcotest.fail "invalid transactional identity unexpectedly launched");
      let rolled_back =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "rollback removed durable metadata"
        | Error detail -> Alcotest.fail detail
      in
      Alcotest.(check bool) "rollback restores paused Dead metadata" true
        rolled_back.paused;
      Alcotest.(check bool) "rollback restores Dead tombstone" true
        (rolled_back.latched_reason = Some Keeper_latched_reason.Dead_tombstone);
      Alcotest.(check int) "rollback restores original generation"
        original.runtime.generation rolled_back.runtime.generation;
      let restored_entry =
        match Keeper_registry.get ~base_path:base_dir keeper_name with
        | Some entry -> entry
        | None -> Alcotest.fail "rollback did not restore Dead registry entry"
      in
      Alcotest.(check bool) "rollback restores exact Dead lane" true
        (Keeper_lane.Id.equal
           (Keeper_lane.id restored_entry.lane)
           (Keeper_lane.id dead_entry.lane));
      Alcotest.(check bool) "rollback registry phase is Dead" true
        (restored_entry.phase = Keeper_state_machine.Dead);
      let journal_path =
        List.fold_left Filename.concat base_dir
          [ ".masc"; "keeper-lifecycle-transactions"; keeper_name ^ ".json" ]
      in
      Alcotest.(check bool) "successful rollback clears journal" false
        (Fs_compat.file_exists journal_path))

let test_lightweight_snapshot_surfaces_paused_keeper_runtime_trust () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "paused-runtime-trust" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      (* See: this fixture only needs an initialized workspace for digest reads. *)
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [
                ("name", `String keeper_name);
                ("agent_name", `String (Keeper_identity.keeper_agent_name keeper_name));
                ("trace_id", `String "trace-paused-runtime-trust");
                ("goal", `String "Expose paused keeper failure in summary");
                ("runtime_id", `String "runtime.primary");
              ])
        with
        | Ok meta ->
          {
            meta with
            paused = true;
            runtime =
              {
                meta.runtime with
                last_blocker =
                  Some
                    (Keeper_meta_contract.blocker_info_of_class
                      ~detail:
                         "Completion contract [tool_contract] violated: no ToolUse block"
                       Keeper_meta_contract.Completion_contract_violation);
              };
          }
        | Error err -> Alcotest.fail ("keeper meta fixture failed: " ^ err)
      in
      (match Keeper_meta_store.write_meta config meta with
      | Ok () -> ()
      | Error err -> Alcotest.fail err);
      Dated_jsonl.append
        (Keeper_types_support.keeper_execution_receipt_store config keeper_name)
        (`Assoc
          [
            ("schema", `String "keeper.execution_receipt.v1");
            ("keeper_name", `String keeper_name);
            ("agent_name", `String meta.agent_name);
            ("trace_id", `String "trace-paused-runtime-trust");
            ("turn_count", `Int 12);
            ("outcome", `String "error");
            ( "terminal_reason_code",
              `String "completion_contract_violation:tool_contract" );
            ("operator_disposition", `String "pause_human");
            ( "operator_disposition_reason",
              `String "unmapped_runtime_state" );
            ("tools_used", `List []);
            ( "tool_surface",
              `Assoc
                [
                  ("turn_lane", `String "tool_optional");
                ] );
            ( "sandbox",
              `Assoc
                [
                  ("kind", `String "docker");
                  ("sandbox_root", `String base_dir);
                  ("network_mode", `String "inherit");
                ] );
            ( "runtime",
              `Assoc
                [
                  ("name", `String "primary");
                  ("selected_model", `String "kimi-for-coding");
                  ("outcome", `String "completed");
                ] );
            ("error", `Assoc [ ("kind", `String "contract") ]);
            ("ended_at", `String (Masc_domain.now_iso ()));
          ]);
      Operator_control.invalidate_snapshot_cache ();
      let snapshot =
        Operator_control.snapshot_json ~view:"summary" ~include_messages:false
          ~include_keepers:true ~include_summary_fields:false
          ~lightweight_summary:true
          (operator_ctx env sw config "operator")
      in
      let open Yojson.Safe.Util in
      let keeper =
        snapshot |> member "keepers" |> member "items" |> to_list
        |> List.find_opt (fun row -> row |> member "name" |> to_string = keeper_name)
        |> Option.value ~default:`Null
      in
      Alcotest.(check bool) "keeper present" true (keeper <> `Null);
      Alcotest.(check string) "runtime blocker class surfaced"
        "completion_contract_violation"
        (keeper |> member "runtime_blocker_class" |> to_string);
      Alcotest.(check bool) "attention surfaced" true
        (keeper |> member "needs_attention" |> to_bool);
      let trust = keeper |> member "runtime_trust" in
      Alcotest.(check string) "trust disposition blocks" "Blocked"
        (trust |> member "disposition" |> to_string);
      Alcotest.(check string) "operator reason preserved"
        "unmapped_runtime_state"
        (trust |> member "operator_disposition_reason" |> to_string);
      Alcotest.(check string) "terminal code preserved"
        "completion_contract_violation:tool_contract"
        (trust |> member "latest_terminal_reason" |> member "code"
       |> to_string);
      Operator_control.invalidate_snapshot_cache ();
      let full_snapshot =
        Operator_control.snapshot_json ~view:"summary" ~include_messages:false
          ~include_keepers:true ~include_summary_fields:false
          ~lightweight_summary:false
          (operator_ctx env sw config "operator")
      in
      let full_keeper =
        full_snapshot |> member "keepers" |> member "items" |> to_list
        |> List.find_opt (fun row -> row |> member "name" |> to_string = keeper_name)
        |> Option.value ~default:`Null
      in
      Alcotest.(check bool) "full keeper present" true (full_keeper <> `Null);
      Alcotest.(check string) "full paused status" "paused"
        (full_keeper |> member "status" |> to_string);
      Alcotest.(check bool) "full paused flag" true
        (full_keeper |> member "paused" |> to_bool);
      Alcotest.(check string) "full pause state" "paused"
        (full_keeper |> member "pause_state" |> to_string);
      Alcotest.(check string) "full paused pipeline" "paused"
        (full_keeper |> member "pipeline_stage" |> to_string))

let test_digest_workspace_includes_keeper_runtime_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "digest-runtime-attention" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator")); (* See: fixture init. *)
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Expose keeper attention in digest");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      let meta =
        {
          meta with
          paused = true;
          runtime =
            {
              meta.runtime with
              last_blocker =
                Some
                  (Keeper_meta_contract.blocker_info_of_class
                     ~detail:"Completion contract requires a keeper tool call"
                     Keeper_meta_contract.Completion_contract_violation);
            };
        }
      in
      (match Keeper_meta_store.write_meta config meta with
      | Ok () -> ()
      | Error err -> Alcotest.fail err);
      let digest =
        match
          Operator_control.digest_json ~actor:"dashboard"
            (operator_ctx env sw config "dashboard")
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let open Yojson.Safe.Util in
      let target_id_is_keeper item =
        match item |> member "target_id" with
        | `String value -> String.equal value keeper_name
        | _ -> false
      in
      let keeper_attention =
        digest |> member "attention_items" |> to_list
        |> List.find_opt target_id_is_keeper
        |> Option.value ~default:`Null
      in
      Alcotest.(check bool) "keeper attention present" true
        (keeper_attention <> `Null);
      Alcotest.(check string) "keeper attention target type" "keeper"
        (keeper_attention |> member "target_type" |> to_string);
      Alcotest.(check string) "keeper attention kind" "keeper_paused"
        (keeper_attention |> member "kind" |> to_string);
      Alcotest.(check string) "keeper attention severity" "bad"
        (keeper_attention |> member "severity" |> to_string);
      Alcotest.(check string) "keeper attention blocker class"
        "completion_contract_violation"
        (keeper_attention |> member "evidence" |> member "runtime_blocker"
         |> member "runtime_blocker_class" |> to_string);
      let keeper_probe =
        digest |> member "recommended_actions" |> to_list
        |> List.find_opt (fun row ->
          target_id_is_keeper row
          && String.equal "keeper_probe" (row |> member "action_type" |> to_string))
        |> Option.value ~default:`Null
      in
      Alcotest.(check bool) "keeper probe recommendation present" true
        (keeper_probe <> `Null);
      Alcotest.(check bool) "recommendation summary is non-empty" true
        (digest |> member "recommendation_summary" |> member "count" |> to_int > 0))

let test_lightweight_snapshot_preserves_receipt_latest_causal_event () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "receipt-causal-lightweight" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name = "operator";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Keep receipt causal signal in summary");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      Dated_jsonl.append
        (Keeper_types_support.keeper_execution_receipt_store config keeper_name)
        (`Assoc
          [
            ("schema", `String "keeper.execution_receipt.v1");
            ("keeper_name", `String keeper_name);
            ("agent_name", `String meta.agent_name);
            ("trace_id", `String "trace-receipt-causal-lightweight");
            ("turn_count", `Int 3);
            ("outcome", `String "ok");
            ("operator_disposition", `String "pass");
            ("operator_disposition_reason", `String "healthy");
            ( "runtime",
              `Assoc
                [
                  ("name", `String "primary");
                  ("selected_model", `String "kimi-for-coding");
                  ("outcome", `String "completed");
                ] );
            ("ended_at", `String (Masc_domain.now_iso ()));
          ]);
      Operator_control.invalidate_snapshot_cache ();
      let snapshot =
        Operator_control.snapshot_json ~view:"summary" ~include_messages:false
          ~include_keepers:true ~include_summary_fields:false
          ~lightweight_summary:true
          (operator_ctx env sw config "operator")
      in
      let open Yojson.Safe.Util in
      let keeper =
        snapshot |> member "keepers" |> member "items" |> to_list
        |> List.find_opt (fun row -> row |> member "name" |> to_string = keeper_name)
        |> Option.value ~default:`Null
      in
      Alcotest.(check bool) "keeper present" true (keeper <> `Null);
      let trust = keeper |> member "runtime_trust" in
      Alcotest.(check string) "receipt remains latest causal fallback"
        "execution_receipt"
        (trust |> member "latest_causal_event" |> member "kind" |> to_string))

let test_snapshot_has_expected_sections () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      ignore (Workspace.add_task config ~title:"operator backlog" ~priority:2 ~description:"");
      ignore (Workspace.broadcast config ~from_agent:"owner" ~content:"operator snapshot seed");
      let json = Operator_control.snapshot_json (operator_ctx env sw config "owner") in
      let root = Yojson.Safe.Util.member "workspace" json in
      Alcotest.(check bool) "root block present" true
        (root <> `Null);
      Alcotest.(check bool) "root initialized" true
        Yojson.Safe.Util.(root |> member "initialized" |> to_bool);
      Alcotest.(check bool) "project nonempty" true
        (String.trim Yojson.Safe.Util.(root |> member "project" |> to_string) <> "");
      Alcotest.(check bool) "sessions present" true
        (Yojson.Safe.Util.member "sessions" json <> `Null);
      Alcotest.(check bool) "keepers present" true
        (Yojson.Safe.Util.member "keepers" json <> `Null);
      Alcotest.(check bool) "recent_messages present" true
        (Yojson.Safe.Util.member "recent_messages" json <> `Null);
      Alcotest.(check bool) "pending_confirms present" true
        (Yojson.Safe.Util.member "pending_confirms" json <> `Null);
      Alcotest.(check bool) "trace_id present" true
        (json |> Yojson.Safe.Util.member "trace_id" |> Yojson.Safe.Util.to_string
       <> "");
      Alcotest.(check string) "server profile" "operator_remote_v1"
        (json |> Yojson.Safe.Util.member "server_profile"
         |> Yojson.Safe.Util.member "name" |> Yojson.Safe.Util.to_string);
      Alcotest.(check bool) "attention summary present" true
        (Yojson.Safe.Util.member "attention_summary" json <> `Null);
      Alcotest.(check bool) "recommendation summary present" true
        (Yojson.Safe.Util.member "recommendation_summary" json <> `Null);
      Alcotest.(check bool) "operator judge runtime present" true
        (Yojson.Safe.Util.member "operator_judge_runtime" json <> `Null);
      Alcotest.(check bool) "operator judge enabled by default" true
        Yojson.Safe.Util.
          (json |> member "operator_judge_runtime" |> member "enabled" |> to_bool);
      Alcotest.(check string) "judgment owner" "fallback_read_model"
        Yojson.Safe.Util.(json |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "no authoritative judgment" false
        Yojson.Safe.Util.(json |> member "authoritative_judgment_available" |> to_bool);
      let admission = Yojson.Safe.Util.member "admission_queue" json in
      Alcotest.(check bool) "admission queue present" true
        (admission <> `Null);
      Alcotest.(check bool) "admission throttle is not reported as mode field" true
        (match Yojson.Safe.Util.member "mode" admission with
         | `Null -> true
         | _ -> false);
      Alcotest.(check string) "admission throttle owner" "oas_runtime"
        Yojson.Safe.Util.(admission |> member "throttle_owner" |> to_string);
      Alcotest.(check bool) "recent_actions list present" true
        (match Yojson.Safe.Util.member "recent_actions" json with
        | `List _ -> true
        | _ -> false))

let test_snapshot_pending_confirm_summary_tracks_actor_scope () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      let ctx = operator_ctx env sw config "owner" in
      let request_namespace_pause actor =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String actor);
                ("action_type", `String "namespace_pause");
                ("target_type", `String "workspace");
              ])
        with
        | Ok _ -> ()
        | Error err -> Alcotest.fail err
      in
      request_namespace_pause "operator-a";
      request_namespace_pause "operator-b";
      let snapshot = Operator_control.snapshot_json ~actor:"operator-a" ctx in
      let summary = Yojson.Safe.Util.(snapshot |> member "pending_confirm_summary") in
      Alcotest.(check string) "actor filter" "operator-a"
        Yojson.Safe.Util.(summary |> member "actor_filter" |> to_string);
      Alcotest.(check bool) "filter active" true
        Yojson.Safe.Util.(summary |> member "filter_active" |> to_bool);
      Alcotest.(check int) "visible count" 1
        Yojson.Safe.Util.(summary |> member "visible_count" |> to_int);
      Alcotest.(check int) "total count" 2
        Yojson.Safe.Util.(summary |> member "total_count" |> to_int);
      Alcotest.(check int) "hidden count" 1
        Yojson.Safe.Util.(summary |> member "hidden_count" |> to_int);
      Alcotest.(check bool) "hidden actor listed" true
        (List.mem (`String "operator-b")
           Yojson.Safe.Util.(summary |> member "hidden_actors" |> to_list));
      let confirm_required_actions =
        Yojson.Safe.Util.(summary |> member "confirm_required_actions" |> to_list)
      in
      Alcotest.(check bool) "namespace pause listed" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "namespace_pause")
           confirm_required_actions);
      Alcotest.(check bool) "keeper recover listed" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string)
             = "keeper_recover")
           confirm_required_actions);
      Alcotest.(check bool) "team stop removed from confirm surface" false
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "team_stop")
           confirm_required_actions);
      Alcotest.(check bool) "task inject not listed" false
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(row |> member "action_type" |> to_string) = "task_inject")
           confirm_required_actions))

let test_snapshot_summary_view_excludes_retired_command_plane () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_messages:false
          (operator_ctx env sw config "owner")
      in
      Alcotest.(check bool) "command_plane field absent" true
        (not (List.mem_assoc "command_plane"
           Yojson.Safe.Util.(to_assoc json)));
      Alcotest.(check bool) "swarm_status omitted" true
        (Yojson.Safe.Util.member "swarm_status" json = `Null);
      Alcotest.(check bool) "attention summary still present" true
        (Yojson.Safe.Util.member "attention_summary" json <> `Null);
      Alcotest.(check bool) "recommendation summary still present" true
        (Yojson.Safe.Util.member "recommendation_summary" json <> `Null))

let test_snapshot_lightweight_summary_omits_heavy_activity () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:true
          ~lightweight_summary:true
          (operator_ctx env sw config "owner")
      in
      let keepers =
        Yojson.Safe.Util.(json |> member "keepers" |> member "items" |> to_list)
      in
      List.iter
        (fun keeper ->
          Alcotest.(check int) "lightweight recent_activity omitted" 0
            Yojson.Safe.Util.(keeper |> member "recent_activity" |> to_list |> List.length))
        keepers;
      Alcotest.(check int) "lightweight recent_messages omitted" 0
        Yojson.Safe.Util.(json |> member "recent_messages" |> to_list |> List.length);
      Alcotest.(check int) "lightweight recent_actions omitted" 0
        Yojson.Safe.Util.(json |> member "recent_actions" |> to_list |> List.length))

let test_snapshot_lightweight_summary_keeps_tool_audit () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio_guard.enable ();
  Dashboard_cache.invalidate_all ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Eio_guard.disable ();
      Keeper_keepalive.stop_keepalive "lightweight-audit";
      Keeper_registry.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name = "owner";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_name = "lightweight-audit" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Surface tool audit in lightweight snapshots");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let metrics_store = Keeper_types_support.keeper_metrics_store config keeper_name in
      let metrics_dir = Dated_jsonl.base_dir metrics_store in
      cleanup_dir metrics_dir;
      Fs_compat.mkdir_p metrics_dir;
      Dated_jsonl.append metrics_store
        (`Assoc
          [
            ("ts", `String (Masc_domain.now_iso ()));
            ("channel", `String "turn");
            ("tool_call_count", `Int 2);
            ("tools_used", `List [ `String "masc_status"; `String "masc_tasks" ]);
          ]);
      Dated_jsonl.append metrics_store
        (`Assoc
          [
            ("ts", `String (Masc_domain.now_iso ()));
            ("channel", `String "turn");
            ("tool_call_count", `Int 0);
            ("tools_used", `List []);
          ]);
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      let first_audit =
        Operator_control_snapshot.cached_tool_audit_json ~lightweight:true
          config meta
      in
      Alcotest.(check bool) "lightweight audit returns fallback immediately" true
        (Yojson.Safe.Util.member "tool_audit_source" first_audit = `Null);
      let rec wait_for_metrics attempts =
        let audit =
          Operator_control_snapshot.cached_tool_audit_json ~lightweight:true
            config meta
        in
        match Yojson.Safe.Util.member "tool_audit_source" audit with
        | `String "keeper_metrics" -> audit
        | _ when attempts > 0 ->
            Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
            wait_for_metrics (attempts - 1)
        | _ -> Alcotest.fail "expected refreshed lightweight tool audit"
      in
      ignore (wait_for_metrics 20);
      Operator_control.invalidate_snapshot_cache ();
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:false
          ~lightweight_summary:true
          (operator_ctx env sw config "owner")
      in
      let keeper =
        match
          Yojson.Safe.Util.(json |> member "keepers" |> member "items" |> to_list)
          |> List.find_opt (fun row ->
                 Yojson.Safe.Util.(row |> member "name" |> to_string) = keeper_name)
        with
        | Some keeper -> keeper
        | None -> Alcotest.fail "expected keeper in lightweight snapshot"
      in
      Alcotest.(check string) "lightweight tool audit source retained"
        "keeper_metrics"
        Yojson.Safe.Util.(keeper |> member "tool_audit_source" |> to_string);
      Alcotest.(check int) "lightweight tool audit count retained" 2
        Yojson.Safe.Util.(keeper |> member "latest_tool_call_count" |> to_int);
      Alcotest.(check (list string)) "lightweight latest tool names retained"
        [ "masc_status"; "masc_tasks" ]
        Yojson.Safe.Util.
          (keeper |> member "latest_tool_names" |> to_list |> List.map to_string))

let test_snapshot_lightweight_summary_keeps_recent_tools_distinct_from_latest () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio_guard.enable ();
  Dashboard_cache.invalidate_all ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Dashboard_cache.invalidate_all ();
      Eio_guard.disable ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      let keeper_ctx : _ Keeper_tool_surface.context =
        {
          config;
          agent_name = "owner";
          sw;
          clock = Eio.Stdenv.clock env;
          proc_mgr = Some (Eio.Stdenv.process_mgr env);
          net = None;
        }
      in
      let keeper_name = "lightweight-recent-tools" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("goal", `String "Keep recent tool names distinct from latest");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let decision_path = Keeper_types_support.keeper_decision_log_path config keeper_name in
      Fs_compat.append_jsonl decision_path
        (`Assoc
          [
            ("ts", `String (Masc_domain.now_iso ()));
            ("selected_mode", `String "tool_use");
            ("tool_call_count", `Int 2);
            ("tools_used", `List [ `String "masc_status"; `String "masc_tasks" ]);
          ]);
      for _ = 1 to 20 do
        Fs_compat.append_jsonl decision_path
          (`Assoc
            [
              ("ts", `String (Masc_domain.now_iso ()));
              ("selected_mode", `String "text_response");
              ("tool_call_count", `Int 0);
              ("tools_used", `List []);
            ])
      done;
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      ignore
        (Operator_control_snapshot.cached_tool_audit_json ~lightweight:true
           config meta);
      let rec wait_for_recent_tools attempts =
        let audit =
          Operator_control_snapshot.cached_tool_audit_json ~lightweight:true
            config meta
        in
        let recent =
          Yojson.Safe.Util.(audit |> member "recent_tool_names" |> to_list)
        in
        if recent <> [] then audit
        else if attempts > 0 then (
          Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
          wait_for_recent_tools (attempts - 1))
        else Alcotest.fail "expected refreshed lightweight recent tools"
      in
      ignore (wait_for_recent_tools 20);
      Operator_control.invalidate_snapshot_cache ();
      let json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:false
          ~lightweight_summary:true
          (operator_ctx env sw config "owner")
      in
      let keeper =
        match
          Yojson.Safe.Util.(json |> member "keepers" |> member "items" |> to_list)
          |> List.find_opt (fun row ->
                 Yojson.Safe.Util.(row |> member "name" |> to_string) = keeper_name)
        with
        | Some keeper -> keeper
        | None -> Alcotest.fail "expected keeper in lightweight snapshot"
      in
      Alcotest.(check (list string)) "recent tool names retain recent window"
        [ "masc_status"; "masc_tasks" ]
        Yojson.Safe.Util.
          (keeper |> member "recent_tool_names" |> to_list |> List.map to_string);
      Alcotest.(check (list string)) "latest tool names stay latest-only"
        []
        Yojson.Safe.Util.
          (keeper |> member "latest_tool_names" |> to_list |> List.map to_string))

(* Snapshot cache behavioural tests live in
   [test_operator_control_snapshot_cache.ml]; they drive the public
   [Operator_control_snapshot_cache] API directly rather than the removed
   internal cache types. *)

(* test_orchestra_workspace_core_shape removed (CP purge: Command_plane_orchestra deleted) *)

let test_digest_workspace_exposes_pending_confirm_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
               ("action_type", `String "namespace_pause");
               ("target_type", `String "workspace");
            ])
      in
      (match action_json with Ok _ -> () | Error err -> Alcotest.fail err);
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "target_type" "workspace"
        Yojson.Safe.Util.(digest |> member "target_type" |> to_string);
      Alcotest.(check string) "health" "warn"
        Yojson.Safe.Util.(digest |> member "health" |> to_string);
      Alcotest.(check bool) "operator judge runtime present" true
        (Yojson.Safe.Util.member "operator_judge_runtime" digest <> `Null);
      let attention_items = Yojson.Safe.Util.(digest |> member "attention_items" |> to_list) in
      Alcotest.(check bool) "pending confirm attention present" true
        (List.exists
           (fun item ->
             Yojson.Safe.Util.(item |> member "kind" |> to_string)
             = "pending_confirm_waiting")
           attention_items);
      Alcotest.(check bool) "attention provenance present" true
        (List.for_all
           (fun item ->
             String.equal "derived"
               Yojson.Safe.Util.(item |> member "provenance" |> to_string))
           attention_items);
      (* command_* attention items only appear when microarch signals
         are warn/bad; in a fresh workspace they are absent *)
      Alcotest.(check bool) "no command attention in fresh workspace" true
        (not
           (List.exists
              (fun item ->
                String.starts_with
                  ~prefix:"command_"
                  Yojson.Safe.Util.(item |> member "kind" |> to_string))
              attention_items)))

let test_digest_workspace_includes_tool_host_failure_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      Dashboard_tool_host_events.record ~fs:() config
        {
          Dashboard_tool_host_events.agent_name = "codex";
          client_name = "codex";
          tool_name = "masc_keeper_msg";
          transport = "mcp_http";
          phase = Some "tools/call";
          message = "timed out awaiting tools/call after 90s";
          request_id = Some "opsd-toolhost-1";
          session_id = Some "sess-toolhost-1";
          trace_id = Some "trace-toolhost-1";
          timeout_ms = Some 90000;
        };
      let digest =
        match Operator_control.digest_json ~actor:"dashboard"
                (operator_ctx env sw config "dashboard")
        with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      let attention_items =
        Yojson.Safe.Util.(digest |> member "attention_items" |> to_list)
      in
      let tool_host_attention =
        List.find_opt
          (fun item ->
            Yojson.Safe.Util.(item |> member "kind" |> to_string)
            = "tool_host_timeout"
            && Yojson.Safe.Util.
                 (item |> member "evidence" |> member "failure_envelope"
                |> member "evidence_ref" |> member "request_id" |> to_string)
               = "opsd-toolhost-1")
          attention_items
      in
      let item =
        match tool_host_attention with
        | Some item -> item
        | None -> Alcotest.fail "expected tool host attention item"
      in
      Alcotest.(check string) "tool host severity" "bad"
        Yojson.Safe.Util.(item |> member "severity" |> to_string);
      Alcotest.(check string) "tool host operator action" "masc_operator_digest"
        Yojson.Safe.Util.
          (item |> member "evidence" |> member "failure_envelope"
         |> member "operator_action" |> to_string))

let test_operator_digest_severity_rank_supports_critical () =
  Alcotest.(check int) "critical rank" 3
    (Operator_digest.severity_rank Operator_digest.Sev_critical);
  Alcotest.(check bool) "critical outranks bad" true
    (Operator_digest.severity_rank Sev_critical
    > Operator_digest.severity_rank Sev_bad)

(* test_snapshot_and_digest_expose_role_runtime_census removed:
   depended on team session start/update which is no longer available. *)

let () =
  Alcotest.run
    "operator_control_snapshot"
    [
      ( "keeper_up resume"
      , [
          Alcotest.test_case
            "lifecycle reservations are per keeper and owner typed"
            `Quick
            test_lifecycle_reservation_is_per_keeper_and_owner_typed;
          Alcotest.test_case
            "lifecycle owner gates durable and registry mutations"
            `Quick
            test_lifecycle_owner_gates_meta_and_registry_mutations;
          Alcotest.test_case
            "rejected revival rolls back durable and registry authorities"
            `Quick
            test_dead_revival_launch_failure_rolls_back_both_authorities;
          Alcotest.test_case
            "operator resume clears persisted dead-tombstone state"
            `Quick
            test_keeper_up_clears_dead_tombstone_resume_state;
        ] );
    ]
;;
