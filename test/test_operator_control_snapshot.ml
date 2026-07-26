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
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "fresh runtime signal promotes keeper status" "busy"
    status

let test_align_keeper_runtime_status_ignores_legacy_zombie_flag () =
  let status =
    Operator_control_snapshot.align_keeper_runtime_status
      ~surface_status:"inactive"
      ~diagnostic:(`Assoc [ ("health_state", `String "offline") ])
      ~agent_status_json:
        (`Assoc
          [
            ("status", `String "busy");
            ("last_seen_ago_s", `Float 5.0);
            ("is_zombie", `Bool true);
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "legacy zombie flag has no authority" "busy" status

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
          ])
      ~keepalive_running:true
  in
  Alcotest.(check string) "degraded health remains inactive" "inactive" status

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
            ("generation", `Int 1);
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      let keeper_name = "ctx-truth" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("instructions", `String "Prefer metrics context truth");
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

let context_test_meta ~name ~last_input_tokens =
  let base =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String name
          ; "agent_name", `String (name ^ "-agent")
          ; "trace_id", `String ("trace-" ^ name)
          ; "runtime_id", `String "primary"
          ; "generation", `Int 1
          ])
    with
    | Ok meta -> meta
    | Error error -> Alcotest.fail error
  in
  { base with
    runtime =
      { base.runtime with
        usage = { base.runtime.usage with last_input_tokens }
      }
  }
;;

let init_context_test_runtime () =
  let root = Masc_test_deps.find_project_root () in
  let config_path = Filename.concat root "config/runtime.toml" in
  match Runtime.init_default ~config_path with
  | Ok () -> ()
  | Error error -> Alcotest.failf "Runtime.init_default failed: %s" error
;;

let write_raw_metrics_row config keeper_name row =
  let store = Keeper_types_support.keeper_metrics_store config keeper_name in
  Dated_jsonl.append store (`Assoc [ "fixture", `Bool true ]);
  let only_entry label directory =
    match Sys.readdir directory |> Array.to_list with
    | [ entry ] -> Filename.concat directory entry
    | entries ->
      Alcotest.failf
        "expected one %s entry under %s, found %d"
        label
        directory
        (List.length entries)
  in
  let month_dir = only_entry "month" (Dated_jsonl.base_dir store) in
  let path = only_entry "day file" month_dir in
  Fs_compat.save_file path (row ^ "\n");
  path
;;

let test_context_snapshot_missing_metrics_uses_observed_metadata () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
       init_context_test_runtime ();
       let config = Workspace.default_config base_dir in
       let meta = context_test_meta ~name:"metrics-missing" ~last_input_tokens:731 in
       (match
          Operator_control_context_snapshot.latest_keeper_context_snapshot_from_files
            config
            meta.name
        with
        | Ok None -> ()
        | Ok (Some _) -> Alcotest.fail "missing metrics store returned a snapshot"
        | Error _ -> Alcotest.fail "missing metrics store returned a read failure");
       let snapshot =
         Operator_control_context_snapshot.keeper_context_snapshot_of_meta config meta
       in
       Alcotest.(check (option int)) "metadata token observation" (Some 731)
         snapshot.context_tokens;
       Alcotest.(check (option string)) "explicit metadata source"
         (Some "fallback_metadata") snapshot.context_source;
       Alcotest.(check bool) "no metrics failure" true
         (snapshot.context_metrics_unavailable = None))
;;

let test_context_snapshot_malformed_metrics_is_unavailable () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
       init_context_test_runtime ();
       let config = Workspace.default_config base_dir in
       let meta = context_test_meta ~name:"metrics-malformed" ~last_input_tokens:991 in
       let path = write_raw_metrics_row config meta.name "{not-json" in
       (match
          Operator_control_context_snapshot.latest_keeper_context_snapshot_from_files
            config
            meta.name
        with
        | Error
            (Operator_control_context_snapshot.Malformed_metrics_row
              { path = error_path; line_number = None; _ }) ->
          Alcotest.(check string) "exact malformed row path" path error_path
        | Error _ -> Alcotest.fail "unexpected metrics read error"
        | Ok _ -> Alcotest.fail "malformed metrics row was silently accepted");
       let snapshot =
         Operator_control_context_snapshot.keeper_context_snapshot_of_meta config meta
       in
       Alcotest.(check (option int)) "no metadata token fallback" None
         snapshot.context_tokens;
       Alcotest.(check (option string)) "no fabricated source" None
         snapshot.context_source;
       let json =
         `Assoc
           (Operator_control_context_snapshot.keeper_context_snapshot_fields snapshot)
       in
       let unavailable =
         Yojson.Safe.Util.member "context_metrics_unavailable" json
       in
       Alcotest.(check string) "typed decode failure" "malformed_json"
         Yojson.Safe.Util.(unavailable |> member "kind" |> to_string);
       Alcotest.(check string) "decode failure path" path
         Yojson.Safe.Util.(unavailable |> member "path" |> to_string))
;;

let test_context_snapshot_storage_failure_is_unavailable () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
       init_context_test_runtime ();
       let config = Workspace.default_config base_dir in
       let meta = context_test_meta ~name:"metrics-storage-error" ~last_input_tokens:557 in
       let metrics_dir = Keeper_types_support.keeper_metrics_dir config meta.name in
       Fs_compat.mkdir_p (Filename.dirname metrics_dir);
       Fs_compat.save_file metrics_dir "not a directory";
       let snapshot =
         Operator_control_context_snapshot.keeper_context_snapshot_of_meta config meta
       in
       Alcotest.(check (option int)) "no metadata token fallback" None
         snapshot.context_tokens;
       let json =
         `Assoc
           (Operator_control_context_snapshot.keeper_context_snapshot_fields snapshot)
       in
       let unavailable =
         Yojson.Safe.Util.member "context_metrics_unavailable" json
       in
       Alcotest.(check string) "typed storage failure" "storage_read_failed"
         Yojson.Safe.Util.(unavailable |> member "kind" |> to_string);
       Alcotest.(check string) "exact storage reason" "not_a_directory"
         Yojson.Safe.Util.(unavailable |> member "reason" |> to_string);
       Alcotest.(check string) "exact storage path" metrics_dir
         Yojson.Safe.Util.(unavailable |> member "path" |> to_string))
;;

let test_keeper_up_clears_dead_tombstone_resume_state () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_fd_backed_lifecycle_head_parents @@ fun () ->
  let base_dir = temp_dir () in
  let keeper_name = "dead-tombstone-operator-resume" in
  Eio.Switch.on_release sw (fun () ->
    Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
    Keeper_registry.For_testing.clear ();
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
      publication_recovery_provider =
        Masc_test_deps.publication_recovery_provider
          (publication_recovery_registry env sw config);
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
            ("runtime_id", `String "runtime.primary");
            ("generation", `Int 1);
          ])
    with
    | Error err -> Alcotest.fail ("keeper meta fixture failed: " ^ err)
    | Ok meta ->
      {
        meta with
        paused = true;
        latched_reason = Some Keeper_latched_reason.Dead_tombstone;
        runtime =
          {
            meta.runtime with
            last_blocker =
              Some
                (Keeper_meta_contract.blocker_info_of_class
                   ~detail:"stale timeout before operator resume"
                   Keeper_meta_contract.Stale_turn_timeout);
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
            ("instructions", `String "Resume tombstoned keeper");
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
    (running_entry.meta.runtime.nonce > persisted_seed.runtime.nonce);
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok `Cleared -> ()
   | Ok _ -> Alcotest.fail "committed revival did not leave a cleared tombstone"
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  ignore
    (Keeper_keepalive.stop_keepalive_and_await
       ~base_path:base_dir keeper_name);
  let resumed = read_meta "resumed" in
  Alcotest.(check bool) "operator resume clears paused" false resumed.paused;
  Alcotest.(check bool) "operator resume clears terminal latch" true
    (Option.is_none resumed.latched_reason);
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
      Keeper_registry.For_testing.clear ();
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
              ; "runtime_id", `String "runtime.primary"
              ; "generation", `Int 1
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
            ~expected_generation:persisted.runtime.nonce
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
               persisted.runtime.nonce owner.expected_generation
           | Error
               ( Keeper_registry.Registration_shutdown_reserved _
               | Keeper_registry.Registration_invalid _
               | Keeper_registry.Registration_event_queue_unavailable _ ) ->
             Alcotest.fail "registration failed for a non-lifecycle reason"
           | Ok _ -> Alcotest.fail "unowned registration crossed reservation");
          let entry =
            match
              Keeper_lifecycle_admission.Durable_transaction
              .with_durable_lifecycle_admission
                config
                ~keeper_name:persisted.name
                (fun permit ->
                   Keeper_registry.register_offline_if_admitted_for_lifecycle
                     permit
                     token
                     ~base_path:base_dir
                     persisted.name
                     persisted)
            with
            | Keeper_lifecycle_admission.Durable_transaction.Admission_completed
                (Keeper_registry.Lifecycle_mutation_completed (Ok entry))
            | Keeper_lifecycle_admission.Durable_transaction
              .Admission_completed_with_attention
                ((Keeper_registry.Lifecycle_mutation_completed (Ok entry)), _) ->
              entry
            | Keeper_lifecycle_admission.Durable_transaction.Admission_completed _
            | Keeper_lifecycle_admission.Durable_transaction
              .Admission_completed_with_attention _
            | Keeper_lifecycle_admission.Durable_transaction.Admission_blocked _ ->
              Alcotest.fail "owner registration was rejected"
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
             Keeper_lifecycle_admission.Durable_transaction
             .with_durable_lifecycle_admission
               config
               ~keeper_name:persisted.name
               (fun permit ->
                  Keeper_registry.update_entry_exact_for_lifecycle
                    permit
                    token
                    entry
                    Fun.id)
           with
           | Keeper_lifecycle_admission.Durable_transaction.Admission_completed
               (Keeper_registry.Lifecycle_mutation_completed
                  Keeper_registry.Exact_updated)
           | Keeper_lifecycle_admission.Durable_transaction
             .Admission_completed_with_attention
               ((Keeper_registry.Lifecycle_mutation_completed
                   Keeper_registry.Exact_updated), _) ->
             ()
           | Keeper_lifecycle_admission.Durable_transaction.Admission_completed _
           | Keeper_lifecycle_admission.Durable_transaction
             .Admission_completed_with_attention _
           | Keeper_lifecycle_admission.Durable_transaction.Admission_blocked _ ->
             Alcotest.fail "owner exact registry update was rejected");
          (match
             Keeper_lifecycle_admission.Durable_transaction
             .with_durable_lifecycle_admission
               config
               ~keeper_name:persisted.name
               (fun permit ->
                  Keeper_registry.unregister_exact_for_lifecycle
                    permit
                    token
                    entry)
           with
           | Keeper_lifecycle_admission.Durable_transaction.Admission_completed
               (Keeper_registry.Lifecycle_mutation_completed
                  Keeper_registry.Exact_unregistered)
           | Keeper_lifecycle_admission.Durable_transaction
             .Admission_completed_with_attention
               ((Keeper_registry.Lifecycle_mutation_completed
                   Keeper_registry.Exact_unregistered), _) ->
             ()
           | Keeper_lifecycle_admission.Durable_transaction.Admission_completed _
           | Keeper_lifecycle_admission.Durable_transaction
             .Admission_completed_with_attention _
           | Keeper_lifecycle_admission.Durable_transaction.Admission_blocked _ ->
             Alcotest.fail "owner exact unregister was rejected")))

let test_dead_revival_launch_failure_rolls_back_both_authorities () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_fd_backed_lifecycle_head_parents @@ fun () ->
  let base_dir = temp_dir () in
  let keeper_name = "dead-revival-rollback" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
      Keeper_registry.For_testing.clear ();
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
              ; "runtime_id", `String "runtime.primary"
              ; "generation", `Int 1
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
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
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
      Alcotest.(check bool) "rollback preserves forward generation" true
        (rolled_back.runtime.nonce > original.runtime.nonce);
      Alcotest.(check bool)
        "rollback does not restore stale Dead registry identity"
        true
        (Option.is_none (Keeper_registry.get ~base_path:base_dir keeper_name));
      (match
         Keeper_dead_revival_transaction.For_testing.current_journal_stage
           ~config
           ~keeper_name
       with
       | Ok `Cleared -> ()
       | Ok _ -> Alcotest.fail "successful rollback did not leave a cleared tombstone"
       | Error error ->
         Alcotest.fail
           (Keeper_dead_revival_transaction.error_to_string error)))

let with_settled_dead_revival_fixture ~keeper_name fn =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_fd_backed_lifecycle_head_parents @@ fun () ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
      Keeper_registry.For_testing.clear ();
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
              ; "trace_id", `String ("trace-" ^ keeper_name)
              ; "runtime_id", `String "runtime.primary"
              ; "generation", `Int 1
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
        | Ok None -> Alcotest.fail "dead revival fixture metadata disappeared"
        | Error detail -> Alcotest.fail detail
      in
      let dead_entry =
        Keeper_registry.register_offline ~base_path:base_dir keeper_name original
      in
      Keeper_registry.mark_dead
        ~base_path:base_dir
        keeper_name
        ~at:(Time_compat.now ());
      (match
         Keeper_lane.reject_before_start
           dead_entry.lane
           ~reason:(Failure "seed settled dead revival fixture")
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail (Keeper_lane.start_error_to_string error));
      ignore
        (Keeper_registry.resolve_done
           dead_entry
           ~source:"settled_dead_revival_fixture"
           (`Crashed "seed")
          : Keeper_registry.done_resolve_result);
      let ctx : _ Keeper_tool_surface.context =
        { config
        ; agent_name = "operator"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
        }
      in
      fn base_dir config original dead_entry ctx)
;;

module Revival_payload = Keeper_dead_revival_payload

type active_revival_journal =
  { raw : string
  ; transaction_id : string
  ; payload_ref : Revival_payload.immutable_ref
  }

let require_revival_payload_ok label = function
  | Ok value -> value
  | Error error ->
    Alcotest.failf
      "%s: %s"
      label
      (Revival_payload.error_to_string error)
;;

let active_revival_journal_of_raw raw =
  let open Yojson.Safe.Util in
  let json =
    try Yojson.Safe.from_string raw with
    | Yojson.Json_error detail ->
      Alcotest.failf "active revival journal is malformed: %s" detail
  in
  let transaction_id = json |> member "transaction_id" |> to_string in
  let payload_ref =
    json
    |> member "payload_ref"
    |> Revival_payload.immutable_ref_of_json
    |> require_revival_payload_ok "decode active revival payload ref"
  in
  { raw; transaction_id; payload_ref }
;;

let current_active_revival_journal ~config ~keeper_name =
  match
    Keeper_dead_revival_transaction.For_testing.current_journal_row
      ~config
      ~keeper_name
  with
  | Ok (Some raw) -> active_revival_journal_of_raw raw
  | Ok None -> Alcotest.fail "active revival journal is missing"
  | Error error ->
    Alcotest.fail
      (Keeper_dead_revival_transaction.error_to_string error)
;;

let revival_payload_path config payload_ref =
  Filename.concat
    (Filename.concat
       (Filename.concat
          (Workspace.masc_root_dir config)
          "keeper-lifecycle-transactions")
       "payloads")
    (Filename.concat
       (Revival_payload.immutable_ref_authority_leaf payload_ref)
       (Revival_payload.immutable_ref_transaction_leaf payload_ref))
;;

let current_revival_journal_path config =
  let root =
    Filename.concat
      (Workspace.masc_root_dir config)
      "keeper-lifecycle-transactions"
  in
  let rows =
    Sys.readdir root
    |> Array.to_list
    |> List.filter (fun leaf ->
      String.starts_with ~prefix:"revival-" leaf
      && Filename.check_suffix leaf ".json")
  in
  match rows with
  | [ leaf ] -> Filename.concat root leaf
  | _ ->
    Alcotest.failf
      "expected exactly one active revival journal, observed=%d"
      (List.length rows)
;;

let revival_journal_path config keeper_name =
  let sha256 value =
    Digestif.SHA256.(to_hex (digest_string value))
  in
  let length_delimited value =
    Printf.sprintf "%d:%s" (String.length value) value
  in
  Filename.concat
    (Filename.concat
       (Workspace.masc_root_dir config)
       "keeper-lifecycle-transactions")
    ("revival-"
     ^ sha256
         ("keeper-dead-revival-journal-leaf-v1\000"
          ^ length_delimited keeper_name)
     ^ ".json")
;;

let write_revival_fixture path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let replace_revival_payload_ref raw payload_ref =
  match Yojson.Safe.from_string raw with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
            if String.equal key "payload_ref"
            then key, Revival_payload.immutable_ref_to_json payload_ref
            else key, value)
         fields)
    |> Yojson.Safe.to_string
  | _ -> Alcotest.fail "active revival journal is not an object"
;;

let create_unjournaled_revival_payload
      ~config
      ~owner_id
      ~original
      ~candidate
  =
  let row =
    Keeper_dead_revival_transaction.For_testing.reserved_journal_row
      ~owner_id
      ~original
      ~candidate
  in
  let observed = active_revival_journal_of_raw row in
  let payload =
    Revival_payload.make_payload
      ~transaction_id:observed.transaction_id
      ~owner_id
      ~keeper_name:original.name
      ~expected_trace_id:original.runtime.trace_id
      ~expected_generation:original.runtime.nonce
      ~original
      ~candidate
    |> require_revival_payload_ok "make unjournaled revival payload"
  in
  let prepared =
    Revival_payload.prepare payload
    |> require_revival_payload_ok "prepare unjournaled revival payload"
  in
  (match Revival_payload.create config prepared with
   | Ok (Revival_payload.Created _ | Revival_payload.Reconciled_created _) -> ()
   | Error error ->
     Alcotest.fail
       (Revival_payload.error_to_string error));
  observed
;;

let reserve_revival_journal_fixture ~config ~owner_id ~original ~candidate =
  let observed =
    create_unjournaled_revival_payload
      ~config
      ~owner_id
      ~original
      ~candidate
  in
  write_revival_fixture
    (revival_journal_path config original.name)
    observed.raw;
  Ok observed.raw
;;

let replace_with_reserved_revival_journal_fixture
      ~config
      ~owner_id
      ~original
      ~candidate
  =
  let observed =
    create_unjournaled_revival_payload
      ~config
      ~owner_id
      ~original
      ~candidate
  in
  write_revival_fixture
    (current_revival_journal_path config)
    observed.raw;
  Ok ()
;;

let advance_revival_journal_to_launch_committed_fixture ~config ~keeper_name =
  match
    Keeper_dead_revival_transaction.For_testing.current_journal_row
      ~config
      ~keeper_name
  with
  | Error error -> Error error
  | Ok None ->
    Error
      (Keeper_dead_revival_transaction.Journal_ownership_changed
         "test launch source is missing")
  | Ok (Some raw) ->
    let stage =
      Keeper_lifecycle_admission.Durable_transaction.stage_to_wire
        Keeper_lifecycle_admission.Durable_transaction.Launch_committed
    in
    let updated =
      match Yojson.Safe.from_string raw with
      | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
                if String.equal key "stage"
                then key, `String stage
                else key, value)
             fields)
        |> Yojson.Safe.to_string
      | _ -> Alcotest.fail "active revival journal is not an object"
    in
    write_revival_fixture
      (current_revival_journal_path config)
      updated;
    Ok ()
;;

let test_dead_revival_final_clear_failure_preserves_commit () =
  let keeper_name = "dead-revival-final-clear" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original dead_entry ctx ->
  let detail = "injected final clear failure after launch commit" in
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    }
  in
  let committed, entry =
    match
      Keeper_dead_revival_transaction.For_testing.with_final_clear_failure
        ~detail
        (fun () ->
          Keeper_dead_revival_transaction.revive
            ctx
            ~original
            ~candidate)
    with
    | Error
        (Keeper_dead_revival_transaction.Post_commit_cleanup_required
           { committed
           ; entry
           ; cleanup_error =
               Keeper_dead_revival_transaction.Journal_write_failed observed
           })
      when String.equal observed detail ->
      committed, entry
    | Error error ->
      Alcotest.fail
        ("unexpected final clear result: "
         ^ Keeper_dead_revival_transaction.error_to_string error)
    | Ok _ ->
      Alcotest.fail "final clear failure was collapsed to clean revival success"
  in
  Alcotest.(check bool)
    "committed metadata is not paused"
    false
    committed.paused;
  Alcotest.(check bool)
    "committed metadata has no Dead tombstone"
    true
    (Option.is_none committed.latched_reason);
  Alcotest.(check bool)
    "committed lifecycle nonce advanced"
    true
    (committed.runtime.nonce > original.runtime.nonce);
  Alcotest.(check string)
    "returned registry entry retains exact committed metadata"
    (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json committed))
    (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json entry.meta));
  let current_entry =
    match Keeper_registry.get ~base_path:config.base_path keeper_name with
    | Some current -> current
    | None -> Alcotest.fail "committed revival registry entry disappeared"
  in
  Alcotest.(check bool)
    "returned lane remains the registered lane"
    true
    (Keeper_lane.Id.equal
       (Keeper_lane.id entry.lane)
       (Keeper_lane.id current_entry.lane));
  Alcotest.(check bool)
    "dead lane was not restored"
    false
    (Keeper_lane.Id.equal
       (Keeper_lane.id dead_entry.lane)
       (Keeper_lane.id current_entry.lane));
  Alcotest.(check bool)
    "committed registry phase is not Dead"
    false
    (current_entry.phase = Keeper_state_machine.Dead);
  let persisted_before_recovery =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "committed metadata disappeared"
    | Error error -> Alcotest.fail error
  in
  Alcotest.(check int)
    "durable lifecycle nonce remains committed"
    committed.runtime.nonce
    persisted_before_recovery.runtime.nonce;
  Alcotest.(check bool)
    "durable Dead state was not restored"
    true
    (not persisted_before_recovery.paused
     && Option.is_none persisted_before_recovery.latched_reason);
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok `Launch_committed -> ()
   | Ok _ -> Alcotest.fail "journal did not retain exact Launch_committed stage"
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_row
       ~config
       ~keeper_name
   with
   | Ok (Some raw) ->
     let fields =
       match Yojson.Safe.from_string raw with
       | `Assoc fields -> List.map fst fields |> List.sort String.compare
       | _ -> Alcotest.fail "active launch journal is not an object"
     in
     Alcotest.(check (list string))
       "active launch journal retains recovery payload"
       [ "expected_generation"
       ; "expected_trace_id"
       ; "keeper_name"
       ; "owner_id"
       ; "payload_ref"
       ; "schema"
       ; "stage"
       ; "transaction_id"
       ]
       fields;
     let payload_ref_fields =
       match
         Yojson.Safe.from_string raw
         |> Yojson.Safe.Util.member "payload_ref"
       with
       | `Assoc fields -> List.map fst fields |> List.sort String.compare
       | _ -> Alcotest.fail "active launch payload_ref is not an object"
     in
     Alcotest.(check (list string))
       "active launch journal retains only opaque payload metadata"
       [ "authority_leaf"
       ; "byte_count"
       ; "schema"
       ; "sha256"
       ; "transaction_leaf"
       ]
       payload_ref_fields
   | Ok None -> Alcotest.fail "active launch journal disappeared"
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  Alcotest.(check bool)
    "post-commit failure released lifecycle reservation"
    true
    (Option.is_none
       (Keeper_lifecycle_reservation.current
          ~base_path:config.base_path
          ~keeper_name));
  let recovery =
    Keeper_dead_revival_transaction.recover_pending config
  in
  Alcotest.(check int) "forward recovery does not roll back metadata" 0 recovery.recovered;
  Alcotest.(check int) "forward recovery clears launch journal" 1 recovery.cleared;
  Alcotest.(check int) "forward recovery is fully resolved" 0
    (List.length recovery.unresolved);
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok `Cleared -> ()
   | Ok _ -> Alcotest.fail "startup recovery did not forward-clear journal"
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_row
       ~config
       ~keeper_name
   with
   | Ok (Some raw) ->
     let fields =
       match Yojson.Safe.from_string raw with
       | `Assoc fields -> List.map fst fields |> List.sort String.compare
       | _ -> Alcotest.fail "cleared journal tombstone is not an object"
     in
     Alcotest.(check (list string))
       "cleared tombstone retains no metadata payload"
       [ "keeper_name"; "schema"; "stage"; "transaction_id" ]
       fields
   | Ok None -> Alcotest.fail "cleared journal tombstone disappeared"
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  let persisted_after_recovery =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "forward recovery removed committed metadata"
    | Error error -> Alcotest.fail error
  in
  Alcotest.(check int)
    "forward recovery preserves committed nonce"
    committed.runtime.nonce
    persisted_after_recovery.runtime.nonce
;;

let test_dead_revival_launch_publication_warning_preserves_commit () =
  let keeper_name = "dead-revival-launch-publication-warning" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    }
  in
  let committed, entry =
    match
      Keeper_dead_revival_transaction.For_testing
      .with_launch_publication_settlement_warning
        (fun () ->
          Keeper_dead_revival_transaction.revive
            ctx
            ~original
            ~candidate)
    with
    | Error
        (Keeper_dead_revival_transaction.Post_commit_cleanup_required
           { committed
           ; entry
           ; cleanup_error =
               Keeper_dead_revival_transaction.Journal_published_with_warnings
                 { warnings; _ }
           })
      when warnings <> [] ->
      committed, entry
    | Error error ->
      Alcotest.fail
        ("unexpected launch publication warning result: "
         ^ Keeper_dead_revival_transaction.error_to_string error)
    | Ok _ ->
      Alcotest.fail
        "publish-then-warning launch was collapsed to clean revival success"
  in
  Alcotest.(check bool)
    "publish-then-warning metadata remains live"
    true
    (not committed.paused && Option.is_none committed.latched_reason);
  Alcotest.(check bool)
    "publish-then-warning registry lane remains installed"
    true
    (match Keeper_registry.get ~base_path:config.base_path keeper_name with
     | Some current ->
       Keeper_lane.Id.equal
         (Keeper_lane.id entry.lane)
         (Keeper_lane.id current.lane)
     | None -> false);
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok `Launch_committed -> ()
   | Ok _ ->
     Alcotest.fail
       "publish-then-warning journal did not retain Launch_committed authority"
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  let persisted =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None ->
      Alcotest.fail "publish-then-warning committed metadata disappeared"
    | Error error -> Alcotest.fail error
  in
  Alcotest.(check int)
    "publish-then-warning durable nonce remains committed"
    committed.runtime.nonce
    persisted.runtime.nonce;
  let recovery =
    Keeper_dead_revival_transaction.recover_pending config
  in
  Alcotest.(check int)
    "publish-then-warning recovery does not roll back"
    0
    recovery.recovered;
  Alcotest.(check int)
    "publish-then-warning recovery forward-clears"
    1
    recovery.cleared;
  Alcotest.(check int)
    "publish-then-warning recovery is resolved"
    0
    (List.length recovery.unresolved)
;;

let test_dead_revival_durable_publication_warning_clears_actual_stage () =
  let keeper_name = "dead-revival-durable-publication-warning" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original dead_entry ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    }
  in
  (match
     Keeper_dead_revival_transaction.For_testing
     .with_durable_publication_settlement_warning
       (fun () ->
         Keeper_dead_revival_transaction.revive
           ctx
           ~original
           ~candidate)
   with
   | Error
       (Keeper_dead_revival_transaction.Journal_published_with_warnings
          { warnings; _ })
     when warnings <> [] -> ()
   | Error error ->
     Alcotest.fail
       ("unexpected durable publication warning result: "
        ^ Keeper_dead_revival_transaction.error_to_string error)
   | Ok _ ->
     Alcotest.fail
       "publish-then-warning durable transition was collapsed to revival success");
  let persisted =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None ->
      Alcotest.fail "durable publish-then-warning rollback removed metadata"
    | Error error -> Alcotest.fail error
  in
  let persisted_content =
    { persisted with
      meta_version = original.meta_version
    ; runtime =
        { persisted.runtime with
          trace_id = original.runtime.trace_id
        ; trace_history = original.runtime.trace_history
        ; nonce = original.runtime.nonce
        }
    }
  in
  Alcotest.(check string)
    "durable publish-then-warning restores original content"
    (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json original))
    (Yojson.Safe.to_string (Keeper_meta_json.meta_to_json persisted_content));
  Alcotest.(check bool)
    "durable publish-then-warning preserves forward generation"
    true
    (persisted.runtime.nonce > original.runtime.nonce);
  Alcotest.(check bool)
    "durable publish-then-warning does not restore stale Dead registry identity"
    true
    (Option.is_none
       (Keeper_registry.get ~base_path:config.base_path keeper_name));
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok `Cleared -> ()
   | Ok _ ->
     Alcotest.fail
       "durable publish-then-warning rollback did not clear actual authority stage"
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  Alcotest.(check bool)
    "durable publish-then-warning releases lifecycle reservation"
    true
    (Option.is_none
       (Keeper_lifecycle_reservation.current
          ~base_path:config.base_path
          ~keeper_name))
;;

let test_dead_revival_recovery_waits_for_forward_fence () =
  let keeper_name = "dead-revival-forward-fence" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    }
  in
  let journal_written_p, journal_written_u = Eio.Promise.create () in
  let release_forward_p, release_forward_u = Eio.Promise.create () in
  let revival_done_p, revival_done_u = Eio.Promise.create () in
  let recovery_started_p, recovery_started_u = Eio.Promise.create () in
  let recovery_done_p, recovery_done_u = Eio.Promise.create () in
  let recovery_waited, revival, recovery =
    Keeper_dead_revival_transaction.For_testing.with_boundary_hooks
      ~after_journal_write:(fun () ->
        Eio.Promise.resolve journal_written_u ();
        Eio.Promise.await release_forward_p)
      (fun () ->
        Eio.Fiber.fork ~sw:ctx.sw (fun () ->
          Eio.Promise.resolve
            revival_done_u
            (Keeper_dead_revival_transaction.revive
               ctx
               ~original
               ~candidate));
        Eio.Promise.await journal_written_p;
        Eio.Fiber.fork ~sw:ctx.sw (fun () ->
          Eio.Promise.resolve recovery_started_u ();
          let recovery =
            Keeper_dead_revival_transaction.recover_pending config
          in
          Eio.Promise.resolve recovery_done_u recovery);
        Eio.Promise.await recovery_started_p;
        Eio.Fiber.yield ();
        let recovery_waited =
          Option.is_none (Eio.Promise.peek recovery_done_p)
        in
        Eio.Promise.resolve release_forward_u ();
        ( recovery_waited
        , Eio.Promise.await revival_done_p
        , Eio.Promise.await recovery_done_p ))
  in
  Alcotest.(check bool)
    "recovery waits while forward transaction holds durable fence"
    true
    recovery_waited;
  (match revival with
   | Ok _ -> ()
   | Error error ->
     Alcotest.fail
       ("fenced revival failed: "
        ^ Keeper_dead_revival_transaction.error_to_string error));
  Alcotest.(check int)
    "serialized recovery does not roll back committed revival"
    0
    recovery.recovered;
  Alcotest.(check int)
    "serialized recovery observes the cleared transaction"
    1
    recovery.cleared;
  Alcotest.(check int)
    "serialized recovery has no unresolved transaction"
    0
    (List.length recovery.unresolved)
;;

let test_dead_revival_recovery_forwards_concurrent_launch_commit () =
  let keeper_name = "dead-revival-recovery-stage-race" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry _ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    ; runtime =
        { original.runtime with
          nonce = original.runtime.nonce + 1
        ; last_blocker = None
        }
    }
  in
  (match
     reserve_revival_journal_fixture
       ~config
       ~owner_id:"recovery-stage-race-owner"
       ~original
       ~candidate
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.fail (Keeper_dead_revival_transaction.error_to_string error));
  (match Keeper_meta_store.write_meta config candidate with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  let recovery =
    Keeper_dead_revival_transaction.For_testing.with_recovery_claim_hook
      ~before_recovery_claim:(fun () ->
        match
          advance_revival_journal_to_launch_committed_fixture
            ~config
            ~keeper_name
        with
        | Ok () -> ()
        | Error error ->
          Alcotest.fail
            (Keeper_dead_revival_transaction.error_to_string error))
      (fun () -> Keeper_dead_revival_transaction.recover_pending config)
  in
  Alcotest.(check int)
    "stage race does not report rollback recovery"
    0
    recovery.recovered;
  Alcotest.(check int)
    "stage race forward-clears launch authority"
    1
    recovery.cleared;
  Alcotest.(check int)
    "stage race is fully resolved"
    0
    (List.length recovery.unresolved);
  let persisted =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "forward recovery removed candidate metadata"
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check int)
    "forward recovery preserves candidate generation"
    candidate.runtime.nonce
    persisted.runtime.nonce
;;

let test_dead_revival_ambiguous_reserved_cancellation_settles_authority () =
  let keeper_name = "dead-revival-ambiguous-reserved-cancel" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun base_dir config original _dead_entry ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    }
  in
  let cancel () =
    raise
      (Eio.Cancel.Cancelled
         (Failure "injected ambiguous Reserved publication cancellation"))
  in
  let cancelled =
    try
      ignore
        (Keeper_dead_revival_transaction.For_testing.with_reserved_publication_failure
           (fun () ->
              Keeper_dead_revival_transaction.For_testing.with_boundary_hooks
                ~after_journal_write:cancel
                (fun () ->
                   Keeper_dead_revival_transaction.revive
                     ctx
                     ~original
                     ~candidate)));
      false
    with
    | Eio.Cancel.Cancelled _ -> true
  in
  Alcotest.(check bool)
    "ambiguous Reserved cancellation propagates"
    true
    cancelled;
  Alcotest.(check bool)
    "ambiguous Reserved cancellation releases lifecycle reservation"
    true
    (Option.is_none
       (Keeper_lifecycle_reservation.current
          ~base_path:base_dir
          ~keeper_name));
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok `Cleared -> ()
   | Ok _ -> Alcotest.fail "ambiguous Reserved cancellation was not settled"
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  let persisted =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "settled cancellation removed metadata"
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check bool)
    "ambiguous Reserved cancellation preserves forward generation"
    true
    (persisted.runtime.nonce > original.runtime.nonce);
  Alcotest.(check bool)
    "ambiguous Reserved cancellation preserves dead content"
    true
    (persisted.paused
     && persisted.latched_reason = Some Keeper_latched_reason.Dead_tombstone);
  Alcotest.(check bool)
    "ambiguous Reserved cancellation removes stale registry identity"
    true
    (Option.is_none
       (Keeper_registry.get ~base_path:base_dir keeper_name))
;;

type launch_payload_damage =
  | Launch_payload_missing
  | Launch_payload_corrupt

let test_dead_revival_launch_payload_damage_forward_cleans damage () =
  let keeper_name =
    match damage with
    | Launch_payload_missing -> "dead-revival-launch-payload-missing"
    | Launch_payload_corrupt -> "dead-revival-launch-payload-corrupt"
  in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry _ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    ; runtime =
        { original.runtime with
          nonce = original.runtime.nonce + 1
        ; last_blocker = None
        }
    }
  in
  (match
     reserve_revival_journal_fixture
       ~config
       ~owner_id:"launch-payload-damage-owner"
       ~original
       ~candidate
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  (match Keeper_meta_store.write_meta config candidate with
   | Ok () -> ()
   | Error detail -> Alcotest.fail detail);
  (match
     advance_revival_journal_to_launch_committed_fixture
       ~config
       ~keeper_name
   with
   | Ok () -> ()
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  let active =
    current_active_revival_journal ~config ~keeper_name
  in
  let payload_path = revival_payload_path config active.payload_ref in
  (match damage with
   | Launch_payload_missing -> Sys.remove payload_path
   | Launch_payload_corrupt ->
     write_revival_fixture payload_path "{corrupt");
  let recovery =
    Keeper_dead_revival_transaction.recover_pending config
  in
  Alcotest.(check int)
    "damaged launch payload never triggers rollback"
    0
    recovery.recovered;
  Alcotest.(check int)
    "damaged launch payload forward-clears"
    1
    recovery.cleared;
  Alcotest.(check int)
    "damaged launch payload leaves no unresolved transaction"
    0
    (List.length recovery.unresolved);
  let persisted =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "damaged launch recovery removed candidate"
    | Error detail -> Alcotest.fail detail
  in
  Alcotest.(check int)
    "damaged launch recovery preserves candidate generation"
    candidate.runtime.nonce
    persisted.runtime.nonce;
  Alcotest.(check bool)
    "damaged launch recovery removes payload evidence"
    false
    (Sys.file_exists payload_path)
;;

let test_dead_revival_swapped_payload_ref_preserves_evidence () =
  let keeper_name = "dead-revival-swapped-payload-ref" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry _ctx ->
  let first_candidate =
    { original with
      paused = false
    ; latched_reason = None
    ; runtime =
        { original.runtime with
          nonce = original.runtime.nonce + 1
        }
    }
  in
  (match
     reserve_revival_journal_fixture
       ~config
       ~owner_id:"swapped-ref-first-owner"
       ~original
       ~candidate:first_candidate
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  let first =
    current_active_revival_journal ~config ~keeper_name
  in
  let second_candidate =
    { first_candidate with
      runtime =
        { first_candidate.runtime with
          nonce = original.runtime.nonce + 2
        }
    }
  in
  let second =
    create_unjournaled_revival_payload
      ~config
      ~owner_id:"swapped-ref-second-owner"
      ~original
      ~candidate:second_candidate
  in
  let first_path = revival_payload_path config first.payload_ref in
  let second_path = revival_payload_path config second.payload_ref in
  write_revival_fixture
    (current_revival_journal_path config)
    (replace_revival_payload_ref first.raw second.payload_ref);
  let recovery =
    Keeper_dead_revival_transaction.recover_pending config
  in
  Alcotest.(check bool)
    "swapped ref is unresolved"
    true
    (recovery.unresolved <> []);
  Alcotest.(check int)
    "swapped ref never reports rollback"
    0
    recovery.recovered;
  Alcotest.(check bool)
    "swapped ref preserves original payload evidence"
    true
    (Sys.file_exists first_path);
  Alcotest.(check bool)
    "swapped ref preserves referenced payload evidence"
    true
    (Sys.file_exists second_path);
  Alcotest.(check bool)
    "swapped ref preserves invalid journal evidence"
    true
    (Sys.file_exists (current_revival_journal_path config))
;;

let test_dead_revival_exact_orphan_payload_is_deleted () =
  let keeper_name = "dead-revival-exact-orphan" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry _ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    ; runtime =
        { original.runtime with
          nonce = original.runtime.nonce + 1
        }
    }
  in
  let orphan =
    create_unjournaled_revival_payload
      ~config
      ~owner_id:"exact-orphan-owner"
      ~original
      ~candidate
  in
  let payload_path = revival_payload_path config orphan.payload_ref in
  Alcotest.(check bool)
    "exact orphan fixture exists"
    true
    (Sys.file_exists payload_path);
  let recovery =
    Keeper_dead_revival_transaction.recover_pending config
  in
  Alcotest.(check int)
    "exact orphan cleanup reports one clear"
    1
    recovery.cleared;
  Alcotest.(check int)
    "exact orphan cleanup has no unresolved evidence"
    0
    (List.length recovery.unresolved);
  Alcotest.(check bool)
    "exact orphan cleanup removes only payload"
    false
    (Sys.file_exists payload_path)
;;

type cleanup_test_direction =
  | Forward_cleanup
  | Rollback_cleanup

type cleanup_test_boundary =
  | After_cleanup_pending
  | After_cleanup_payload_delete

let test_dead_revival_cleanup_pending_recovery
      direction
      boundary
      ()
  =
  let keeper_name =
    match direction, boundary with
    | Forward_cleanup, After_cleanup_pending ->
      "dead-revival-forward-after-cleanup-pending"
    | Forward_cleanup, After_cleanup_payload_delete ->
      "dead-revival-forward-after-payload-delete"
    | Rollback_cleanup, After_cleanup_pending ->
      "dead-revival-rollback-after-cleanup-pending"
    | Rollback_cleanup, After_cleanup_payload_delete ->
      "dead-revival-rollback-after-payload-delete"
  in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry _ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    ; runtime =
        { original.runtime with
          nonce = original.runtime.nonce + 1
        ; last_blocker = None
        }
    }
  in
  (match
     reserve_revival_journal_fixture
       ~config
       ~owner_id:"cleanup-boundary-owner"
       ~original
       ~candidate
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  (match direction with
   | Forward_cleanup ->
     (match Keeper_meta_store.write_meta config candidate with
      | Ok () -> ()
      | Error detail -> Alcotest.fail detail);
     (match
        advance_revival_journal_to_launch_committed_fixture
          ~config
          ~keeper_name
      with
      | Ok () -> ()
      | Error error ->
        Alcotest.fail
          (Keeper_dead_revival_transaction.error_to_string error))
   | Rollback_cleanup -> ());
  let active =
    current_active_revival_journal ~config ~keeper_name
  in
  let payload_path = revival_payload_path config active.payload_ref in
  let expected_direction =
    match direction with
    | Forward_cleanup -> `Forward
    | Rollback_cleanup -> `Rollback
  in
  let failure_detail =
    "injected cleanup boundary failure"
  in
  let after_cleanup_pending observed =
    if
      observed = expected_direction
      && boundary = After_cleanup_pending
    then Some failure_detail
    else None
  in
  let after_payload_delete observed =
    if
      observed = expected_direction
      && boundary = After_cleanup_payload_delete
    then Some failure_detail
    else None
  in
  let first_recovery =
    Keeper_dead_revival_transaction.For_testing.with_cleanup_boundary_hooks
      ~after_cleanup_pending
      ~after_payload_delete
      (fun () ->
         Keeper_dead_revival_transaction.recover_pending config)
  in
  Alcotest.(check bool)
    "injected cleanup boundary remains unresolved"
    true
    (first_recovery.unresolved <> []);
  let expected_stage =
    match direction with
    | Forward_cleanup -> `Forward_cleanup_pending
    | Rollback_cleanup -> `Rollback_cleanup_pending
  in
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok stage when stage = expected_stage -> ()
   | Ok _ -> Alcotest.fail "cleanup boundary did not retain pending stage"
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  Alcotest.(check bool)
    "cleanup boundary retains exact payload state"
    (boundary = After_cleanup_pending)
    (Sys.file_exists payload_path);
  let recovery =
    Keeper_dead_revival_transaction.recover_pending config
  in
  Alcotest.(check int)
    "cleanup retry has no unresolved transaction"
    0
    (List.length recovery.unresolved);
  (match direction with
   | Forward_cleanup ->
     Alcotest.(check int)
       "forward cleanup retry never rolls back"
       0
       recovery.recovered;
     Alcotest.(check int)
       "forward cleanup retry clears journal"
       1
       recovery.cleared
   | Rollback_cleanup ->
     Alcotest.(check int)
       "rollback cleanup retry completes recovery"
       1
       recovery.recovered;
     Alcotest.(check int)
       "rollback cleanup retry is not a forward clear"
       0
       recovery.cleared);
  (match
     Keeper_dead_revival_transaction.For_testing.current_journal_stage
       ~config
       ~keeper_name
   with
   | Ok `Cleared -> ()
   | Ok _ -> Alcotest.fail "cleanup retry did not clear journal"
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  Alcotest.(check bool)
    "cleanup retry leaves payload absent"
    false
    (Sys.file_exists payload_path);
  let persisted =
    match Keeper_meta_store.read_meta config keeper_name with
    | Ok (Some meta) -> meta
    | Ok None -> Alcotest.fail "cleanup retry removed durable metadata"
    | Error detail -> Alcotest.fail detail
  in
  let expected_generation =
    match direction with
    | Forward_cleanup -> candidate.runtime.nonce
    | Rollback_cleanup -> original.runtime.nonce
  in
  Alcotest.(check int)
    "cleanup retry preserves direction-authoritative metadata"
    expected_generation
    persisted.runtime.nonce
;;

let test_update_keeper_surfaces_committed_cleanup_required () =
  let keeper_name = "dead-revival-update-cleanup" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir _config original _dead_entry ctx ->
  let parsed : Keeper_turn_up_args.parsed_args =
    { name = keeper_name
    ; runtime_id_opt = None
    ; allowed_paths_opt = None
    ; autoboot_enabled_opt = None
    ; mention_targets_opt = None
    ; active_goal_ids_opt = None
    ; max_context_override_opt = None
    ; max_context_override_present = false
    ; proactive_enabled_opt = None
    ; sandbox_profile_opt = None
    ; network_mode_opt = None
    ; instructions_arg = None
    ; profile_defaults = Keeper_types_profile.empty_keeper_profile_defaults
    ; instructions_opt = None
    }
  in
  let result =
    Keeper_dead_revival_transaction.For_testing.with_final_clear_failure
      ~detail:"injected update_keeper final clear failure"
      (fun () ->
        Keeper_turn_up_update.update_keeper ctx parsed original)
  in
  Alcotest.(check bool)
    "committed cleanup-required result is successful"
    true
    (Keeper_types_profile.tool_result_success result);
  let data = Tool_result.data result in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "typed committed outcome"
    "dead_revival_committed_with_cleanup_required"
    (data |> member "outcome" |> to_string);
  Alcotest.(check string)
    "ordinary revival retry is forbidden"
    "do_not_retry_revival"
    (data |> member "retry_disposition" |> to_string);
  Alcotest.(check bool)
    "launch success is explicit"
    true
    (data |> member "launch_committed" |> to_bool);
  Alcotest.(check bool)
    "transaction cleanup requirement is explicit"
    true
    (data |> member "transaction_cleanup_required" |> to_bool);
  Alcotest.(check bool)
    "journal-only cleanup field is absent"
    true
    (data |> member "journal_cleanup_required" = `Null);
  Alcotest.(check string)
    "cleanup error retains typed constructor"
    "journal_write_failed"
    (data |> member "cleanup_error" |> member "kind" |> to_string);
  Alcotest.(check string)
    "registry evidence retains committed metadata"
    (Yojson.Safe.to_string (data |> member "committed"))
    (Yojson.Safe.to_string
       (data |> member "registry_entry" |> member "meta"))
;;

type dead_revival_cancellation_boundary =
  | After_nonce_allocation
  | After_journal_write
  | After_journal_write_ownership_swap

let test_dead_revival_cancellation_releases_reservation boundary () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_fd_backed_lifecycle_head_parents @@ fun () ->
  let base_dir = temp_dir () in
  let keeper_name =
    match boundary with
    | After_nonce_allocation -> "dead-revival-cancel-after-nonce"
    | After_journal_write -> "dead-revival-cancel-after-journal"
    | After_journal_write_ownership_swap ->
      "dead-revival-cancel-ownership-swap"
  in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
      Keeper_registry.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let original =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ "name", `String keeper_name
              ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
              ; "trace_id", `String ("trace-" ^ keeper_name)
              ; "runtime_id", `String "runtime.primary"
              ; "generation", `Int 1
              ])
        with
        | Error detail -> Alcotest.fail detail
        | Ok meta ->
          { meta with
            paused = true
          ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
          }
      in
      let candidate =
        { original with
          paused = false
        ; latched_reason = None
        }
      in
      let competing_candidate =
        { candidate with
          runtime =
            { candidate.runtime with
              nonce = original.runtime.nonce + 100
            }
        }
      in
      let competing_row =
        Keeper_dead_revival_transaction.For_testing.reserved_journal_row
          ~owner_id:"competing-revival-owner"
          ~original
          ~candidate:competing_candidate
      in
      let ctx : _ Keeper_tool_surface.context =
        { config
        ; agent_name = "operator"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
        }
      in
      let cancel () =
        raise (Eio.Cancel.Cancelled (Failure "injected revival boundary cancellation"))
      in
      let invoke () =
        match boundary with
        | After_nonce_allocation ->
          Keeper_dead_revival_transaction.For_testing.with_boundary_hooks
            ~after_nonce_allocation:cancel
            (fun () ->
              Keeper_dead_revival_transaction.revive ctx ~original ~candidate)
        | After_journal_write ->
          Keeper_dead_revival_transaction.For_testing.with_boundary_hooks
            ~after_journal_write:cancel
            (fun () ->
              Keeper_dead_revival_transaction.revive ctx ~original ~candidate)
        | After_journal_write_ownership_swap ->
          Keeper_dead_revival_transaction.For_testing.with_boundary_hooks
            ~after_journal_write:(fun () ->
              (match
                 replace_with_reserved_revival_journal_fixture
                   ~config
                   ~owner_id:"competing-revival-owner"
                   ~original
                   ~candidate:competing_candidate
               with
               | Ok () -> ()
               | Error error ->
                 Alcotest.fail
                   (Keeper_dead_revival_transaction.error_to_string error));
              cancel ())
            (fun () ->
              Keeper_dead_revival_transaction.revive ctx ~original ~candidate)
      in
      let cancelled =
        try
          ignore (invoke ());
          false
        with
        | Eio.Cancel.Cancelled _ -> true
      in
      Alcotest.(check bool) "injected cancellation propagated" true cancelled;
      Alcotest.(check bool)
        "cancellation released lifecycle reservation"
        true
        (Option.is_none
           (Keeper_lifecycle_reservation.current
              ~base_path:base_dir
              ~keeper_name));
      let current_stage =
        match
          Keeper_dead_revival_transaction.For_testing.current_journal_stage
            ~config
            ~keeper_name
        with
        | Ok stage -> stage
        | Error error ->
          Alcotest.fail
            (Keeper_dead_revival_transaction.error_to_string error)
      in
      Alcotest.(check bool)
        "cancellation preserves only the transaction it owns"
        true
        (match boundary, current_stage with
         | After_nonce_allocation, `Missing -> true
         | After_journal_write, `Cleared -> true
         | After_journal_write_ownership_swap, `Reserved -> true
         | _ -> false);
      (match boundary with
       | After_journal_write_ownership_swap ->
         (match
            Keeper_dead_revival_transaction.For_testing.current_journal_row
              ~config
              ~keeper_name
          with
          | Ok (Some observed) ->
            Alcotest.(check string)
              "competing journal row is preserved byte-for-byte"
              competing_row
              observed
          | Ok None -> Alcotest.fail "competing journal authority disappeared"
          | Error error ->
            Alcotest.fail
              (Keeper_dead_revival_transaction.error_to_string error))
       | After_nonce_allocation | After_journal_write -> ()))
;;

let test_dead_revival_existing_reserved_journal_blocks () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  with_fd_backed_lifecycle_head_parents @@ fun () ->
  let base_dir = temp_dir () in
  let keeper_name = ".masc-capability-head-worker" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive ~base_path:base_dir keeper_name;
      Keeper_registry.For_testing.clear ();
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let original =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ "name", `String keeper_name
              ; "agent_name", `String (Keeper_identity.keeper_agent_name keeper_name)
              ; "trace_id", `String "trace-dead-revival-existing-journal"
              ; "runtime_id", `String "runtime.primary"
              ; "generation", `Int 1
              ])
        with
        | Error detail -> Alcotest.fail detail
        | Ok meta ->
          { meta with
            paused = true
          ; latched_reason = Some Keeper_latched_reason.Dead_tombstone
          }
      in
      let candidate =
        { original with
          paused = false
        ; latched_reason = None
        }
      in
      let seeded_candidate =
        { candidate with
          runtime =
            { candidate.runtime with
              nonce = original.runtime.nonce + 50
            }
        }
      in
      let seeded_row =
        match
          reserve_revival_journal_fixture
            ~config
            ~owner_id:"seeded-unresolved-owner"
            ~original
            ~candidate:seeded_candidate
        with
        | Ok row -> row
        | Error error ->
          Alcotest.fail
            (Keeper_dead_revival_transaction.error_to_string error)
      in
      let ctx : _ Keeper_tool_surface.context =
        { config
        ; agent_name = "operator"
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; proc_mgr = Some (Eio.Stdenv.process_mgr env)
        ; net = None
        ; publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config)
        }
      in
      (match
         Keeper_dead_revival_transaction.revive ctx ~original ~candidate
       with
       | Error (Keeper_dead_revival_transaction.Journal_conflict _) -> ()
       | Error error ->
         Alcotest.fail
           ("unexpected existing journal failure: "
            ^ Keeper_dead_revival_transaction.error_to_string error)
       | Ok _ ->
         Alcotest.fail "unresolved current-schema journal was overwritten");
      (match
         Keeper_dead_revival_transaction.For_testing.current_journal_row
           ~config
           ~keeper_name
       with
       | Ok (Some observed) ->
         Alcotest.(check string)
           "pre-existing unresolved row remains byte-for-byte exact"
           seeded_row
           observed
       | Ok None -> Alcotest.fail "pre-existing journal disappeared"
       | Error error ->
         Alcotest.fail
           (Keeper_dead_revival_transaction.error_to_string error));
      Alcotest.(check bool)
        "blocked transaction releases process reservation"
        true
        (Option.is_none
           (Keeper_lifecycle_reservation.current
              ~base_path:base_dir
              ~keeper_name)))
;;

module Durable_admission =
  Keeper_lifecycle_admission.Durable_transaction

let replace_revival_journal_stage raw stage =
  match Yojson.Safe.from_string raw with
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) ->
            if String.equal key "stage"
            then key, stage
            else key, value)
         fields)
    |> Yojson.Safe.to_string
  | _ -> Alcotest.fail "revival journal fixture is not an object"
;;

let replace_durable_admission_row ~config ~keeper_name:_ row =
  Out_channel.with_open_bin
    (current_revival_journal_path config)
    (fun channel -> output_string channel row)
;;

let expect_durable_start_admitted ~config ~keeper_name label =
  match
    Durable_admission.with_durable_lifecycle_admission
      config
      ~keeper_name
      (fun _permit -> ())
  with
  | Durable_admission.Admission_completed ()
  | Durable_admission.Admission_completed_with_attention ((), _) -> ()
  | Durable_admission.Admission_blocked reason ->
    Alcotest.failf
      "%s unexpectedly blocked: %s"
      label
      (Durable_admission.blocked_reason_to_wire reason)
;;

let expect_durable_start_blocked ~config ~keeper_name label =
  match
    Durable_admission.with_durable_lifecycle_admission
      config
      ~keeper_name
      (fun _permit -> ())
  with
  | Durable_admission.Admission_blocked _ -> ()
  | Durable_admission.Admission_completed ()
  | Durable_admission.Admission_completed_with_attention ((), _) ->
    Alcotest.failf "%s unexpectedly admitted" label
;;

let test_keeper_lifecycle_transaction_admission_current_schema () =
  let keeper_name = "dead-revival-start-admission" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry _ctx ->
  expect_durable_start_admitted
    ~config
    ~keeper_name
    "absent authority";
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    ; runtime =
        { original.runtime with
          nonce = original.runtime.nonce + 1
        }
    }
  in
  let reserved =
    match
      reserve_revival_journal_fixture
        ~config
        ~owner_id:"durable-start-admission-owner"
        ~original
        ~candidate
    with
    | Ok row -> row
    | Error error ->
      Alcotest.fail
        (Keeper_dead_revival_transaction.error_to_string error)
  in
  let ordinary_candidate =
    { original with
      instructions = original.instructions ^ "\nblocked ordinary mutation"
    }
  in
  (match Keeper_meta_store.write_meta config ordinary_candidate with
   | Error _ -> ()
   | Ok () ->
     Alcotest.fail
       "ordinary metadata write crossed unresolved rollback authority");
  (match Keeper_meta_store.read_meta config keeper_name with
   | Ok (Some persisted) ->
     Alcotest.(check int)
       "blocked ordinary write leaves generation unchanged"
       original.runtime.nonce
       persisted.runtime.nonce;
     Alcotest.(check string)
       "blocked ordinary write leaves payload unchanged"
       original.instructions
       persisted.instructions
   | Ok None -> Alcotest.fail "blocked ordinary write removed metadata"
   | Error detail -> Alcotest.fail detail);
  let blocked_stages =
    [ "Reserved", `Assoc [ "reserved", `Bool true ]
    ; "Durable_committed", `Assoc [ "durable_committed", `Bool true ]
    ; "Rollback_reserved", `Assoc [ "rollback_reserved", `Bool true ]
    ; ( "Rollback_durable_committed"
      , `Assoc [ "rollback_durable_committed", `Bool true ] )
    ; ( "Rollback_cleanup_pending_from_reserved"
      , `Assoc
          [ ( "rollback_cleanup_pending"
            , `Assoc [ "from_reserved", `Bool true ] )
          ] )
    ; ( "Rollback_cleanup_pending_from_durable_committed"
      , `Assoc
          [ ( "rollback_cleanup_pending"
            , `Assoc [ "from_durable_committed", `Bool true ] )
          ] )
    ]
  in
  List.iter
    (fun (label, stage) ->
       replace_durable_admission_row
         ~config
         ~keeper_name
         (replace_revival_journal_stage reserved stage);
       expect_durable_start_blocked ~config ~keeper_name label)
    blocked_stages;
  let admitted_stages =
    [ "Launch_committed", `Assoc [ "launch_committed", `Bool true ]
    ; ( "Forward_cleanup_pending"
      , `Assoc [ "forward_cleanup_pending", `Bool true ] )
    ]
  in
  List.iter
    (fun (label, stage) ->
       replace_durable_admission_row
         ~config
         ~keeper_name
         (replace_revival_journal_stage reserved stage);
       expect_durable_start_admitted ~config ~keeper_name label)
    admitted_stages;
  let reserved_json = Yojson.Safe.from_string reserved in
  let transaction_id =
    Yojson.Safe.Util.(reserved_json |> member "transaction_id" |> to_string)
  in
  let cleared =
    `Assoc
      [ "schema", `String "masc.keeper-dead-revival-journal.v3"
      ; "transaction_id", `String transaction_id
      ; "keeper_name", `String keeper_name
      ; "stage", `Assoc [ "cleared", `Bool true ]
      ]
    |> Yojson.Safe.to_string
  in
  replace_durable_admission_row ~config ~keeper_name cleared;
  expect_durable_start_admitted ~config ~keeper_name "Cleared";
  replace_durable_admission_row
    ~config
    ~keeper_name
    {|{"schema":"invalid-current-row"}|};
  (match
     Durable_admission.with_durable_lifecycle_admission
       config
       ~keeper_name
       (fun _permit -> ())
   with
   | Durable_admission.Admission_blocked
       (Durable_admission.Authority_invalid
          { failure = Durable_admission.Invalid_current_schema; _ }) ->
     ()
   | Durable_admission.Admission_blocked reason ->
     Alcotest.failf
       "invalid current row returned wrong block: %s"
       (Durable_admission.blocked_reason_to_wire reason)
   | Durable_admission.Admission_completed ()
   | Durable_admission.Admission_completed_with_attention ((), _) ->
     Alcotest.fail "invalid current row was admitted")
;;

let test_keeper_lifecycle_transaction_admission_waits_for_cleanup () =
  let keeper_name = "dead-revival-start-admission-cleanup-race" in
  with_settled_dead_revival_fixture ~keeper_name
  @@ fun _base_dir config original _dead_entry ctx ->
  let candidate =
    { original with
      paused = false
    ; latched_reason = None
    ; runtime =
        { original.runtime with
          nonce = original.runtime.nonce + 1
        }
    }
  in
  let reserved_row =
    match
      reserve_revival_journal_fixture
        ~config
        ~owner_id:"durable-start-admission-cleanup-owner"
        ~original
        ~candidate
    with
    | Ok row -> row
    | Error error ->
      Alcotest.fail
        (Keeper_dead_revival_transaction.error_to_string error)
  in
  let transaction_id =
    reserved_row
    |> Yojson.Safe.from_string
    |> Yojson.Safe.Util.member "transaction_id"
    |> Yojson.Safe.Util.to_string
  in
  (match
     Keeper_lifecycle_admission_durable_transaction.with_recovery_lifecycle_admission
       config
       ~keeper_name
       ~transaction_id
       (fun permit ->
          let lifecycle_token =
            match
              Keeper_lifecycle_reservation.acquire
                ~base_path:config.base_path
                ~keeper_name
                ~expected_generation:original.runtime.nonce
                ~purpose:Keeper_lifecycle_reservation.Dead_revival
            with
            | Ok token -> token
            | Error (Keeper_lifecycle_reservation.Already_reserved owner) ->
              Alcotest.fail
                (Keeper_lifecycle_reservation.snapshot_to_string owner)
          in
          let source =
            match
              Keeper_lifecycle_nonce.identity
                ~owner_id:
                  (Keeper_id.Trace_id.to_string original.runtime.trace_id)
                ~nonce:(Int64.of_int original.runtime.nonce)
            with
            | Ok identity -> identity
            | Error error ->
              Alcotest.fail (Keeper_lifecycle_nonce.error_to_string error)
          in
          let replacement =
            Keeper_lifecycle_nonce.replace_settled
              permit
              ~base_path:config.base_path
              ~keeper_id:keeper_name
              ~source
              ~owner_id:
                (Keeper_id.Trace_id.to_string candidate.runtime.trace_id)
              ()
          in
          (match replacement with
           | Error error ->
             Alcotest.fail (Keeper_lifecycle_nonce.error_to_string error)
           | Ok (Keeper_lifecycle_nonce.Settled_allocated witness) ->
             (match
                Keeper_meta_store.replace_meta
                  ~lifecycle_token
                  permit
                  witness
                  config
                  candidate
              with
              | Ok () -> ()
              | Error detail -> Alcotest.fail detail)
           | Ok (Keeper_lifecycle_nonce.Settled_recovered (witness, _)) ->
             (match
                Keeper_meta_store.recover_meta_exact
                  ~lifecycle_token
                  permit
                  witness
                  config
                  candidate
              with
              | Ok () -> ()
              | Error detail -> Alcotest.fail detail));
          (match
             Keeper_meta_store.read_meta config keeper_name
           with
           | Ok (Some persisted) ->
             Alcotest.(check int)
               "lifecycle owner committed replacement generation"
               candidate.runtime.nonce
               persisted.runtime.nonce
           | Ok None ->
             Alcotest.fail "lifecycle owner replacement disappeared"
           | Error detail -> Alcotest.fail detail);
          (match Keeper_lifecycle_reservation.release lifecycle_token with
           | Keeper_lifecycle_reservation.Released -> ()
           | Keeper_lifecycle_reservation.Release_missing ->
             Alcotest.fail "fixture lifecycle reservation disappeared"
           | Keeper_lifecycle_reservation.Release_not_owner owner ->
             Alcotest.fail
               (Keeper_lifecycle_reservation.snapshot_to_string owner)))
   with
   | Durable_admission.Admission_completed ()
   | Durable_admission.Admission_completed_with_attention ((), _) ->
     ()
   | Durable_admission.Admission_blocked reason ->
     Alcotest.fail
       (Durable_admission.blocked_reason_to_wire reason));
  (match
     advance_revival_journal_to_launch_committed_fixture
       ~config
       ~keeper_name
   with
   | Ok () -> ()
   | Error error ->
     Alcotest.fail
       (Keeper_dead_revival_transaction.error_to_string error));
  let cleanup_paused_p, cleanup_paused_u = Eio.Promise.create () in
  let release_cleanup_p, release_cleanup_u = Eio.Promise.create () in
  let recovery_done_p, recovery_done_u = Eio.Promise.create () in
  let admission_started_p, admission_started_u = Eio.Promise.create () in
  let admission_done_p, admission_done_u = Eio.Promise.create () in
  Keeper_dead_revival_transaction.For_testing.with_cleanup_boundary_hooks
    ~after_cleanup_pending:(fun direction ->
      match direction with
      | `Forward ->
        Eio.Promise.resolve cleanup_paused_u ();
        Eio.Promise.await release_cleanup_p;
        None
      | `Rollback -> None)
    (fun () ->
       Eio.Fiber.fork ~sw:ctx.sw (fun () ->
         Eio.Promise.resolve
           recovery_done_u
           (Keeper_dead_revival_transaction.recover_pending config)));
  Eio.Promise.await cleanup_paused_p;
  Eio.Fiber.fork ~sw:ctx.sw (fun () ->
    Eio.Promise.resolve admission_started_u ();
    Eio.Promise.resolve
      admission_done_u
      (Durable_admission.with_durable_lifecycle_admission
         config
         ~keeper_name
         (fun _permit -> ())));
  Eio.Promise.await admission_started_p;
  Eio.Fiber.yield ();
  Alcotest.(check bool)
    "admission waits while cleanup owns durable authority"
    true
    (Option.is_none (Eio.Promise.peek admission_done_p));
  Eio.Promise.resolve release_cleanup_u ();
  let recovery = Eio.Promise.await recovery_done_p in
  Alcotest.(check int)
    "cleanup race has no unresolved transaction"
    0
    (List.length recovery.unresolved);
  (match Eio.Promise.await admission_done_p with
   | Durable_admission.Admission_completed ()
   | Durable_admission.Admission_completed_with_attention ((), _) -> ()
   | Durable_admission.Admission_blocked reason ->
     Alcotest.failf
       "admission remained blocked after cleanup: %s"
       (Durable_admission.blocked_reason_to_wire reason))
;;

let test_lightweight_snapshot_surfaces_paused_keeper_runtime_trust () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "paused-runtime-trust" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.For_testing.clear ();
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
                ("runtime_id", `String "runtime.primary");
                ("generation", `Int 1);
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
                         "No configured provider runtime remained available"
                       (Keeper_meta_contract.Runtime_exhausted
                          Keeper_meta_contract.No_providers_available));
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
            ("terminal_reason_code", `String "runtime_exhausted");
            ("operator_disposition", `String "fail_open_next_runtime");
            ( "operator_disposition_reason",
              `String "runtime_exhausted" );
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
            ("error", `Assoc [ ("kind", `String "runtime") ]);
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
        "runtime_exhausted"
        (keeper |> member "runtime_blocker_class" |> to_string);
      Alcotest.(check bool) "attention surfaced" true
        (keeper |> member "needs_attention" |> to_bool);
      let trust = keeper |> member "runtime_trust" in
      Alcotest.(check string) "trust disposition blocks" "Blocked"
        (trust |> member "disposition" |> to_string);
      Alcotest.(check string) "operator reason preserved"
        "runtime_exhausted"
        (trust |> member "operator_disposition_reason" |> to_string);
      Alcotest.(check string) "terminal code preserved"
        "runtime_exhausted"
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
      Keeper_registry.For_testing.clear ();
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("instructions", `String "Expose keeper attention in digest");
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
                     ~detail:"No configured provider runtime remained available"
                     (Keeper_meta_contract.Runtime_exhausted
                        Keeper_meta_contract.No_providers_available));
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
        "runtime_exhausted"
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
      Keeper_registry.For_testing.clear ();
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("instructions", `String "Keep receipt causal signal in summary");
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
      Alcotest.(check string) "judgment owner" "fallback_read_model"
        Yojson.Safe.Util.(json |> member "judgment_owner" |> to_string);
      Alcotest.(check bool) "no authoritative judgment" false
        Yojson.Safe.Util.(json |> member "authoritative_judgment_available" |> to_bool);
      let inference = Yojson.Safe.Util.member "inference_inflight" json in
      Alcotest.(check bool) "inference observation present" true
        (inference <> `Null);
      Alcotest.(check string) "inference boundary owner" "oas_runtime"
        Yojson.Safe.Util.(inference |> member "boundary_owner" |> to_string);
      Alcotest.(check int) "no inference active" 0
        Yojson.Safe.Util.(inference |> member "active" |> to_int);
      Alcotest.(check bool) "no MASC-owned inference capacity" true
        (Yojson.Safe.Util.member "max_concurrent" inference = `Null);
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
      Keeper_registry.For_testing.clear ();
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      let keeper_name = "lightweight-audit" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("instructions", `String "Surface tool audit in lightweight snapshots");
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
          publication_recovery_provider =
            Masc_test_deps.publication_recovery_provider
              (publication_recovery_registry env sw config);
        }
      in
      let keeper_name = "lightweight-recent-tools" in
      let ok, _ =
        dispatch_keeper_exn keeper_ctx ~name:"masc_keeper_up"
          ~args:
            (`Assoc
              [
                ("name", `String keeper_name);
                ("instructions", `String "Keep recent tool names distinct from latest");
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
            "final clear failure preserves committed revival"
            `Quick
            test_dead_revival_final_clear_failure_preserves_commit;
          Alcotest.test_case
            "launch publication warning preserves committed revival"
            `Quick
            test_dead_revival_launch_publication_warning_preserves_commit;
          Alcotest.test_case
            "durable publication warning clears actual authority stage"
            `Quick
            test_dead_revival_durable_publication_warning_clears_actual_stage;
          Alcotest.test_case
            "recovery waits for the live revival durability fence"
            `Quick
            test_dead_revival_recovery_waits_for_forward_fence;
          Alcotest.test_case
            "recovery forward-completes a concurrent launch commit"
            `Quick
            test_dead_revival_recovery_forwards_concurrent_launch_commit;
          Alcotest.test_case
            "ambiguous Reserved cancellation settles forward authority"
            `Quick
            test_dead_revival_ambiguous_reserved_cancellation_settles_authority;
          Alcotest.test_case
            "Launch-committed recovery forward-cleans a missing payload"
            `Quick
            (test_dead_revival_launch_payload_damage_forward_cleans
               Launch_payload_missing);
          Alcotest.test_case
            "Launch-committed recovery forward-cleans a corrupt payload"
            `Quick
            (test_dead_revival_launch_payload_damage_forward_cleans
               Launch_payload_corrupt);
          Alcotest.test_case
            "swapped payload ref preserves shard evidence"
            `Quick
            test_dead_revival_swapped_payload_ref_preserves_evidence;
          Alcotest.test_case
            "exact no-journal payload orphan is deleted"
            `Quick
            test_dead_revival_exact_orphan_payload_is_deleted;
          Alcotest.test_case
            "forward cleanup resumes after pending-stage failure"
            `Quick
            (test_dead_revival_cleanup_pending_recovery
               Forward_cleanup
               After_cleanup_pending);
          Alcotest.test_case
            "forward cleanup resumes after payload deletion"
            `Quick
            (test_dead_revival_cleanup_pending_recovery
               Forward_cleanup
               After_cleanup_payload_delete);
          Alcotest.test_case
            "rollback cleanup resumes after pending-stage failure"
            `Quick
            (test_dead_revival_cleanup_pending_recovery
               Rollback_cleanup
               After_cleanup_pending);
          Alcotest.test_case
            "rollback cleanup resumes after payload deletion"
            `Quick
            (test_dead_revival_cleanup_pending_recovery
               Rollback_cleanup
               After_cleanup_payload_delete);
          Alcotest.test_case
            "keeper update preserves committed cleanup-required outcome"
            `Quick
            test_update_keeper_surfaces_committed_cleanup_required;
          Alcotest.test_case
            "nonce-boundary cancellation releases revival reservation"
            `Quick
            (test_dead_revival_cancellation_releases_reservation
               After_nonce_allocation);
          Alcotest.test_case
            "journal-boundary cancellation clears revival reservation"
            `Quick
            (test_dead_revival_cancellation_releases_reservation
               After_journal_write);
          Alcotest.test_case
            "cancellation cannot clear a competing journal transaction"
            `Quick
            (test_dead_revival_cancellation_releases_reservation
               After_journal_write_ownership_swap);
          Alcotest.test_case
            "pre-existing current-schema journal blocks revival"
            `Quick
            test_dead_revival_existing_reserved_journal_blocks;
          Alcotest.test_case
            "current-schema lifecycle authority fences Keeper lane starts"
            `Quick
            test_keeper_lifecycle_transaction_admission_current_schema;
          Alcotest.test_case
            "Keeper lane admission waits for concurrent lifecycle cleanup"
            `Quick
            test_keeper_lifecycle_transaction_admission_waits_for_cleanup;
          Alcotest.test_case
            "operator resume clears persisted dead-tombstone state"
            `Quick
            test_keeper_up_clears_dead_tombstone_resume_state;
        ] );
      ( "runtime status"
      , [
          Alcotest.test_case
            "fresh runtime signal promotes status"
            `Quick
            test_align_keeper_runtime_status_promotes_fresh_runtime_signal;
          Alcotest.test_case
            "legacy zombie flag has no authority"
            `Quick
            test_align_keeper_runtime_status_ignores_legacy_zombie_flag;
          Alcotest.test_case
            "attention health blocks promotion"
            `Quick
            test_align_keeper_runtime_status_preserves_attention_health;
          Alcotest.test_case
            "null runtime signal preserves surface status"
            `Quick
            test_align_keeper_runtime_status_tolerates_null_status_json;
        ] );
      ( "context metrics ledger"
      , [ Alcotest.test_case
            "missing ledger uses observed metadata"
            `Quick
            test_context_snapshot_missing_metrics_uses_observed_metadata
        ; Alcotest.test_case
            "malformed row is typed unavailable"
            `Quick
            test_context_snapshot_malformed_metrics_is_unavailable
        ; Alcotest.test_case
            "storage failure is typed unavailable"
            `Quick
            test_context_snapshot_storage_failure_is_unavailable
        ] );
    ]
;;
