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

let test_usage_does_not_create_context_snapshot () =
  let model_budget = 256_000 in
  let base =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String "ctx-ratio-demo");
            ("trace_id", `String "trace-ctx-ratio-demo");
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
              last_input_tokens = 790_360;
              last_output_tokens = 17;
              last_total_tokens = 790_377;
              last_usage_reported_at = Some 1_700_000_000.0;
            };
        };
    }
  in
  let json =
    `Assoc
      (Keeper_context_observation_projection.missing_context_fields ())
  in
  Alcotest.(check bool)
    "fixture is deliberately above the assigned model budget"
    true
    (meta.runtime.usage.last_input_tokens > model_budget);
  Alcotest.(check bool)
    "usage is not context ratio" true
    Yojson.Safe.Util.(json |> member "context_ratio" = `Null);
  Alcotest.(check bool)
    "usage is not context tokens" true
    Yojson.Safe.Util.(json |> member "context_tokens" = `Null);
  Alcotest.(check bool)
    "model budget is not an observed context max" true
    Yojson.Safe.Util.(json |> member "context_max" = `Null);
  Alcotest.(check bool)
    "fallback source is not fabricated" true
    Yojson.Safe.Util.(json |> member "context_source" = `Null);
  Alcotest.(check string)
    "missing measurement kind" "not_observed"
    Yojson.Safe.Util.(
      json
      |> member "context_metrics_unavailable"
      |> member "kind"
      |> to_string);
  Alcotest.(check string)
    "missing measurement reason" "context_measurement_missing"
    Yojson.Safe.Util.(
      json
      |> member "context_metrics_unavailable"
      |> member "reason"
      |> to_string)
  ;
  let usage_json =
    Keeper_context_observation_projection.last_turn_usage_json_of_meta meta
  in
  Alcotest.(check int) "usage JSON input retained" 790_360
    Yojson.Safe.Util.(usage_json |> member "input_tokens" |> to_int);
  Alcotest.(check int) "usage JSON output retained" 17
    Yojson.Safe.Util.(usage_json |> member "output_tokens" |> to_int);
  Alcotest.(check int) "usage JSON total retained" 790_377
    Yojson.Safe.Util.(usage_json |> member "total_tokens" |> to_int);
  Alcotest.(check string) "usage JSON source is explicit"
    "keeper_runtime_usage"
    Yojson.Safe.Util.(usage_json |> member "source" |> to_string);
  Alcotest.(check string) "usage JSON keeps its own observation timestamp"
    "2023-11-14T22:13:20Z"
    Yojson.Safe.Util.(usage_json |> member "observed_at" |> to_string);
  let cumulative_sample : Keeper_usage_resolution.sample =
    { input_tokens = 1_200
    ; output_tokens = 30
    ; cache_creation_input_tokens = 0
    ; cache_read_input_tokens = 0
    ; cost_usd = Some 0.25
    }
  in
  let cumulative_resolution, _ =
    Keeper_usage_resolution.resolve
      ~cursor:None
      ~basis:
        (Keeper_usage_resolution.Conversation_counter
           { runtime_id = "antigravity"
           ; conversation_id = "conversation-1"
           ; position = Keeper_usage_resolution.Fresh
           })
      ~observation:(Some cumulative_sample)
      ~observed_at:1_700_000_001.0
  in
  let cumulative_meta =
    { meta with
      runtime =
        { meta.runtime with
          last_usage_resolution = Some cumulative_resolution
        }
    }
  in
  let cumulative_json =
    Keeper_context_observation_projection.last_turn_usage_json_of_meta
      cumulative_meta
  in
  Alcotest.(check int)
    "cumulative provider exposes the resolved turn delta"
    1_200
    Yojson.Safe.Util.(cumulative_json |> member "input_tokens" |> to_int);
  Alcotest.(check int)
    "public total keeps the legacy shape"
    1_230
    Yojson.Safe.Util.(cumulative_json |> member "total_tokens" |> to_int);
  Alcotest.(check string)
    "resolved usage timestamp remains ISO-8601"
    "2023-11-14T22:13:21Z"
    Yojson.Safe.Util.(cumulative_json |> member "observed_at" |> to_string);
  Alcotest.(check string)
    "typed resolution is embedded separately"
    "conversation_counter"
    Yojson.Safe.Util.(
      cumulative_json
      |> member "usage_resolution"
      |> member "basis"
      |> member "kind"
      |> to_string)

let init_runtime_default_for_snapshot base_dir =
  let path = Filename.concat base_dir "runtime.toml" in
  let content =
    {|
version = 1

[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
max-concurrent = 1
|}
  in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error err -> Alcotest.failf "Runtime.init_default failed: %s" err

let append_heartbeat_snapshot config keeper_name ~timestamp ~timestamp_unix =
  Dated_jsonl.append
    (Keeper_types_support.keeper_metrics_store config keeper_name)
    (`Assoc
      (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
       @ [ "ts", `String timestamp
         ; "ts_unix", `Float timestamp_unix
         ; "name", `String keeper_name
         ]))

let test_snapshot_keeps_context_unobserved_and_usage_separate () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      init_runtime_default_for_snapshot base_dir;
      ignore (Workspace.init config ~agent_name:(Some "owner"));
      ignore (Workspace.bind_session config ~agent_name:"owner" ~capabilities:[] ());
      (match Keeper_owner_registry.install_from_store ~sw ~operation_runner:None ~on_turn_slot_released:None config with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_owner_registry.install_error_to_string error));
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
      ignore
        (Keeper_keepalive.stop_keepalive_and_await
           ~base_path:config.base_path
           keeper_name);
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
                  last_usage_reported_at = Some 1_700_000_000.0;
                };
            };
        }
      in
      let heartbeat_timestamp = "2026-08-12T01:02:03Z" in
      append_heartbeat_snapshot
        config
        keeper_name
        ~timestamp:heartbeat_timestamp
        ~timestamp_unix:1_786_499_323.0;
      (match
         Keeper_owner_registry.commit_turn_runtime
           ~base_path:config.base_path
           ~keeper_name
           ~before:meta
           ~after:updated_meta
       with
       | Ok _ -> ()
       | Error error ->
         Alcotest.fail (Keeper_owner_registry.command_error_to_string error));
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
      Alcotest.(check bool) "keeper row omits dead agent projection" false
        (match keeper with
         | `Assoc fields -> List.mem_assoc "agent" fields
         | _ -> true);
      Alcotest.(check bool) "unowned ratio is ignored" true
        Yojson.Safe.Util.(keeper |> member "context_ratio" = `Null);
      Alcotest.(check bool) "unowned tokens are ignored" true
        Yojson.Safe.Util.(keeper |> member "context_tokens" = `Null);
      Alcotest.(check bool) "unowned max is ignored" true
        Yojson.Safe.Util.(keeper |> member "context_max" = `Null);
      Alcotest.(check bool) "unowned source is ignored" true
        Yojson.Safe.Util.(keeper |> member "context_source" = `Null);
      Alcotest.(check (float 0.1)) "summary keeper cadence is projected" 300.0
        Yojson.Safe.Util.(
          keeper |> member "keeper_keepalive_interval_s" |> to_float);
      Alcotest.(check (float 0.1)) "summary snapshot cadence is projected" 300.0
        Yojson.Safe.Util.(
          keeper |> member "keeper_snapshot_interval_s" |> to_float);
      Alcotest.(check (float 0.1)) "summary stale window is projected" 360.0
        Yojson.Safe.Util.(keeper |> member "heartbeat_stale_after_s" |> to_float);
      Alcotest.(check string) "summary heartbeat comes from persisted producer"
        heartbeat_timestamp
        Yojson.Safe.Util.(keeper |> member "last_heartbeat" |> to_string);
      Alcotest.(check string) "missing owner remains explicit" "not_observed"
        Yojson.Safe.Util.(
          keeper
          |> member "context_metrics_unavailable"
          |> member "kind"
          |> to_string);
      Alcotest.(check int) "live last-turn usage remains separate" 6_637_033
        Yojson.Safe.Util.(
          keeper
          |> member "last_turn_usage"
          |> member "input_tokens"
          |> to_int);
      Keeper_registry.For_testing.clear ();
      Operator_control.invalidate_snapshot_cache ();
      let persisted_json =
        Operator_control.snapshot_json ~view:"summary"
          ~include_keepers:true ~include_messages:false
          (operator_ctx env sw config "owner")
      in
      let persisted_keeper =
        match
          Yojson.Safe.Util.(
            persisted_json |> member "keepers" |> member "items" |> to_list)
          |> List.find_opt (fun row ->
                 Yojson.Safe.Util.(row |> member "name" |> to_string)
                 = keeper_name)
        with
        | Some keeper -> keeper
        | None -> Alcotest.fail "expected persisted keeper in snapshot"
      in
      Alcotest.(check bool)
        "persisted token counters do not imply an observed last-turn usage"
        true
        Yojson.Safe.Util.(persisted_keeper |> member "last_turn_usage" = `Null))

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
                ("trace_id", `String "trace-paused-runtime-trust");
                ("runtime_id", `String "runtime.primary");
              ])
        with
        | Ok meta ->
          {
            meta with
            paused = true;
          }
        | Error err -> Alcotest.fail ("keeper meta fixture failed: " ^ err)
      in
      (match Keeper_meta_store.replace_snapshot config meta with
      | Ok () -> ()
      | Error err -> Alcotest.fail err);
      Dated_jsonl.append
        (Keeper_types_support.keeper_execution_receipt_store config keeper_name)
        (`Assoc
          [
            ("schema", `String "keeper.execution_receipt.v1");
            ("keeper_name", `String keeper_name);
            ("agent_name", `String meta.name);
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
      let heartbeat_timestamp = "2026-08-12T02:03:04Z" in
      append_heartbeat_snapshot
        config
        keeper_name
        ~timestamp:heartbeat_timestamp
        ~timestamp_unix:1_786_502_584.0;
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
      Alcotest.(check string) "paused lightweight heartbeat is persisted truth"
        heartbeat_timestamp
        (keeper |> member "last_heartbeat" |> to_string);
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
        (full_keeper |> member "pipeline_stage" |> to_string);
      Alcotest.(check string) "full paused heartbeat is persisted truth"
        heartbeat_timestamp
        (full_keeper |> member "last_heartbeat" |> to_string))

(* PR #28216 regression: an unreadable heartbeat ledger must not be relabeled
   as an absent/missing heartbeat.  Corrupt the metrics ledger with an invalid
   month directory so [Keeper_heartbeat_persisted_snapshot.latest] fails, then
   assert the operator row surfaces [heartbeat_observation_error] and keeps
   [last_heartbeat] null instead of substituting a fallback. *)
let test_lightweight_snapshot_surfaces_heartbeat_read_error () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  let keeper_name = "heartbeat-read-error" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_keepalive.stop_keepalive keeper_name;
      Keeper_registry.For_testing.clear ();
      Keeper_runtime.reset_test_state base_dir;
      cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      init_runtime_default_for_snapshot base_dir;
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ ("name", `String keeper_name)
              ; ("trace_id", `String "trace-heartbeat-read-error")
              ])
        with
        | Ok meta -> { meta with paused = true }
        | Error err -> Alcotest.fail ("keeper meta fixture failed: " ^ err)
      in
      (match Keeper_meta_store.replace_snapshot config meta with
       | Ok () -> ()
       | Error err -> Alcotest.fail err);
      (* Corrupt the heartbeat metrics ledger: an invalid month directory is a
         layout violation, so the persisted-snapshot read returns an error. *)
      let metrics_dir =
        Keeper_types_support.keeper_metrics_dir config keeper_name
      in
      let rec mkdir_p path =
        if not (Sys.file_exists path)
        then (
          mkdir_p (Filename.dirname path);
          Unix.mkdir path 0o755)
      in
      mkdir_p (Filename.concat metrics_dir "2026-13");
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
      Alcotest.(check bool) "last_heartbeat is not relabeled" true
        (keeper |> member "last_heartbeat" = `Null);
      Alcotest.(check bool) "heartbeat observation error surfaced" true
        (keeper |> member "heartbeat_observation_error" <> `Null))

let test_diagnostic_uses_persisted_heartbeat_freshness () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      let keeper_name = "heartbeat-health" in
      let now_ts = Unix.gettimeofday () in
      let heartbeat_ts = now_ts -. 30.0 in
      let heartbeat_timestamp =
        Masc_domain.iso8601_of_unix_seconds heartbeat_ts
      in
      let meta =
        match
          Masc_test_deps.meta_of_json_fixture
            (`Assoc
              [ "name", `String keeper_name
              ; "trace_id", `String "trace-heartbeat-health"
              ; "total_turns", `Int 1
              ])
        with
        | Ok meta -> meta
        | Error error -> Alcotest.fail error
      in
      append_heartbeat_snapshot
        config
        keeper_name
        ~timestamp:heartbeat_timestamp
        ~timestamp_unix:heartbeat_ts;
      let diagnostic =
        Keeper_status_runtime.keeper_diagnostic_json
          ~config
          ~meta
          ~keepalive_running:true
          ~history_items:[]
          ~now_ts
      in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "fresh heartbeat keeps runtime healthy"
        "healthy"
        (diagnostic |> member "health_state" |> to_string);
      Alcotest.(check string) "diagnostic exposes persisted heartbeat"
        heartbeat_timestamp
        (diagnostic |> member "last_heartbeat" |> to_string);
      let active_keeper_name = "active-health" in
      let active_meta = { meta with name = active_keeper_name } in
      append_heartbeat_snapshot
        config
        active_keeper_name
        ~timestamp:(Masc_domain.iso8601_of_unix_seconds (now_ts -. 900.0))
        ~timestamp_unix:(now_ts -. 900.0);
      let active_diagnostic =
        Keeper_status_runtime.keeper_diagnostic_json
          ~config
          ~meta:active_meta
          ~keepalive_running:true
          ~history_items:[]
          ~now_ts
      in
      Alcotest.(check string) "stale heartbeat stays visible"
        "stale"
        (active_diagnostic |> member "health_state" |> to_string))

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
        }
      in
      (match Keeper_meta_store.replace_snapshot config meta with
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
      Alcotest.(check bool) "fallback cannot synthesize keeper probe" true
        (keeper_probe = `Null);
      Alcotest.(check int) "fallback recommendation summary is empty" 0
        (digest |> member "recommendation_summary" |> member "count" |> to_int);
      Alcotest.(check bool) "observation summary remains visible" true
        (digest |> member "active_summary" |> member "count" |> to_int > 0))

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
            ("agent_name", `String meta.name);
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
      ignore (Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"owner" ~content:"operator snapshot seed");
      let json = Operator_control.snapshot_json (operator_ctx env sw config "owner") in
      let root = Yojson.Safe.Util.member "workspace" json in
      Alcotest.(check bool) "root block present" true
        (root <> `Null);
      Alcotest.(check bool) "root initialized" true
        Yojson.Safe.Util.(root |> member "initialized" |> to_bool);
      Alcotest.(check bool) "project nonempty" true
        (String.trim Yojson.Safe.Util.(root |> member "project" |> to_string) <> "");
      Alcotest.(check bool) "sessions absent" true
        (Yojson.Safe.Util.member "sessions" json = `Null);
      Alcotest.(check bool) "keepers present" true
        (Yojson.Safe.Util.member "keepers" json <> `Null);
      Alcotest.(check bool) "recent_messages present" true
        (Yojson.Safe.Util.member "recent_messages" json <> `Null);
      Alcotest.(check bool) "pending-confirm envelope present" true
        (Yojson.Safe.Util.member "pending_confirm_envelope" json <> `Null);
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
      Alcotest.(check string) "inference boundary owner" "agent_core_runtime"
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
      let summary =
        Yojson.Safe.Util.(snapshot |> member "pending_confirm_envelope" |> member "summary")
      in
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
          (Keeper_metrics_record.fields Keeper_metrics_record.Turn
          @ [
            ("ts", `String (Masc_domain.now_iso ()));
            ("ts_unix", `Float (Time_compat.now ()));
            ("trace_id", `String "trace-lightweight-audit");
            ("channel", `String "turn");
            ("turn_mode", `String "tool_use");
            ("latency_ms", `Int 1);
            ("handoff_performed", `Bool false);
            ("tool_call_count", `Int 2);
            ("tools_used", `List [ `String "masc_status"; `String "masc_tasks" ]);
          ]));
      Dated_jsonl.append metrics_store
        (`Assoc
          (Keeper_metrics_record.fields Keeper_metrics_record.Turn
          @ [
            ("ts", `String (Masc_domain.now_iso ()));
            ("ts_unix", `Float (Time_compat.now ()));
            ("trace_id", `String "trace-lightweight-audit");
            ("channel", `String "turn");
            ("turn_mode", `String "text_response");
            ("latency_ms", `Int 1);
            ("handoff_performed", `Bool false);
            ("tool_call_count", `Int 0);
            ("tools_used", `List []);
          ]));
      for index = 1 to 129 do
        Dated_jsonl.append metrics_store
          (`Assoc
            (Keeper_metrics_record.fields Keeper_metrics_record.Heartbeat
            @ [
              ("ts", `String (Masc_domain.now_iso ()));
              ("ts_unix", `Float (Time_compat.now ()));
              ("channel", `String "heartbeat");
              ("sequence", `Int index);
            ]))
      done;
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      let first_audit =
        Operator_control_snapshot_tool_audit.cached_tool_audit_json config meta
      in
      Alcotest.(check bool) "lightweight audit returns fallback immediately" true
        (Yojson.Safe.Util.member "tool_audit_source" first_audit = `Null);
      let rec wait_for_metrics attempts =
        let audit =
          Operator_control_snapshot_tool_audit.cached_tool_audit_json config meta
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
      Alcotest.(check int) "latest turn with no tools stays zero" 0
        Yojson.Safe.Util.(keeper |> member "latest_tool_call_count" |> to_int);
      Alcotest.(check (list string)) "latest tool names stay latest-only"
        []
        Yojson.Safe.Util.
          (keeper |> member "latest_tool_names" |> to_list |> List.map to_string);
      Alcotest.(check (list string)) "recent tool names retain current rows"
        [ "masc_status"; "masc_tasks" ]
        Yojson.Safe.Util.
          (keeper |> member "recent_tool_names" |> to_list |> List.map to_string))

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
      let metrics_store =
        Keeper_types_support.keeper_metrics_store config keeper_name
      in
      Dated_jsonl.append metrics_store
        (`Assoc
          (Keeper_metrics_record.fields Keeper_metrics_record.Turn
          @ [
            ("ts", `String (Masc_domain.now_iso ()));
            ("ts_unix", `Float (Time_compat.now ()));
            ("trace_id", `String "trace-lightweight-recent-tools");
            ("channel", `String "turn");
            ("turn_mode", `String "tool_use");
            ("latency_ms", `Int 1);
            ("handoff_performed", `Bool false);
            ("tool_call_count", `Int 2);
            ("tools_used", `List [ `String "masc_status"; `String "masc_tasks" ]);
          ]));
      for _ = 1 to 20 do
        Dated_jsonl.append metrics_store
          (`Assoc
            (Keeper_metrics_record.fields Keeper_metrics_record.Turn
            @ [
              ("ts", `String (Masc_domain.now_iso ()));
              ("ts_unix", `Float (Time_compat.now ()));
              ("trace_id", `String "trace-lightweight-recent-tools");
              ("channel", `String "turn");
              ("turn_mode", `String "text_response");
              ("latency_ms", `Int 1);
              ("handoff_performed", `Bool false);
              ("tool_call_count", `Int 0);
              ("tools_used", `List []);
            ]))
      done;
      let meta =
        match Keeper_meta_store.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      ignore
        (Operator_control_snapshot_tool_audit.cached_tool_audit_json
           config
           meta);
      let rec wait_for_recent_tools attempts =
        let audit =
          Operator_control_snapshot_tool_audit.cached_tool_audit_json
            config
            meta
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
          cause = Failure_envelope.Tool_host_timeout;
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

let test_last_compaction_ago_s_removed_from_backend_serializers () =
  let root = Masc_test_deps.find_project_root () in
  let files =
    [ "lib/operator/operator_control_snapshot.ml"
    ; "lib/dashboard/dashboard_http_keeper.ml"
    ; "lib/keeper/keeper_status_detail.ml" ]
  in
  List.iter
    (fun rel ->
       let path = Filename.concat root rel in
       match Safe_ops.read_file_safe path with
       | Error err -> Alcotest.failf "read %s failed: %s" rel err
       | Ok text ->
           Alcotest.(check bool)
             (Printf.sprintf "%s does not contain last_compaction_ago_s" rel)
             true
             (Option.is_none (last_substring_index text "last_compaction_ago_s")))
    files

let assert_snapshot_rejects_pending_confirm_store store_json =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Workspace.default_config base_dir in
      ignore (Workspace.init config ~agent_name:(Some "operator"));
      Workspace_utils.mkdir_p (Operator_control.operator_dir config);
      (match
         Workspace_utils.write_json_result config
           (Operator_control.pending_confirms_path config)
           store_json
       with
       | Ok () -> ()
       | Error error -> Alcotest.fail error);
      match
        Operator_control.snapshot_json
          (operator_ctx env sw config "operator")
      with
      | _ -> Alcotest.fail "malformed pending-confirm store must reject snapshot"
      | exception Operator_control.Store_error _ -> ())

let test_snapshot_rejects_non_list_pending_confirm_store () =
  assert_snapshot_rejects_pending_confirm_store (`Assoc [])

let test_snapshot_rejects_pending_confirm_without_confirm_token () =
  assert_snapshot_rejects_pending_confirm_store
    (`List
      [ `Assoc
          [ "trace_id", `String "trace-missing-token"
          ; "actor", `String "operator"
          ; "action_type", `String "namespace_pause"
          ; "target_type", `String "workspace"
          ; "target_id", `Null
          ; "payload", `Assoc []
          ; "delegated_tool", `String "masc_pause"
          ; "created_at", `String "2026-08-08T00:00:00Z"
          ; "expires_at", `Null
          ]
      ])

let test_snapshot_rejects_pending_confirm_with_invalid_timestamp () =
  assert_snapshot_rejects_pending_confirm_store
    (`List
      [ `Assoc
          [ "confirm_token", `String "confirm-invalid-time"
          ; "trace_id", `String "trace-invalid-time"
          ; "actor", `String "operator"
          ; "action_type", `String "namespace_pause"
          ; "target_type", `String "workspace"
          ; "target_id", `Null
          ; "payload", `Assoc []
          ; "delegated_tool", `String "masc_pause"
          ; "created_at", `String "not-a-timestamp"
          ; "expires_at", `Null
          ]
      ])

(* The walk takes names from the newest rows and stops at the limit, so the
   rows behind the stopping point are never parsed. What it returns must not
   depend on that: the newest names, in the order the newest rows give them,
   and a malformed row it reaches is skipped rather than fatal. *)
let turn_row tools =
  Yojson.Safe.to_string
    (`Assoc
       [ "kind", `String "turn"
       ; "tools_used", `List (List.map (fun t -> `String t) tools)
       ])
;;

let test_recent_tool_names_take_the_newest_rows () =
  let lines =
    [ turn_row [ "oldest_a"; "oldest_b" ]
    ; turn_row [ "middle" ]
    ; turn_row [ "newest_a"; "newest_b" ]
    ]
  in
  Alcotest.(check (list string))
    "newest row first, then older ones, up to the limit"
    [ "newest_a"; "newest_b"; "middle"; "oldest_a" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names ~limit:4 lines);
  Alcotest.(check (list string))
    "a limit the newest row alone fills stops there"
    [ "newest_a" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names ~limit:1 lines)
;;

let test_recent_tool_names_skip_a_malformed_row () =
  let lines =
    [ turn_row [ "oldest" ]; "{ not json"; turn_row [ "newest" ] ]
  in
  Alcotest.(check (list string))
    "a malformed row between two good ones is skipped, not fatal"
    [ "newest"; "oldest" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names ~limit:4 lines)
;;

let test_recent_tool_names_ignore_blank_rows () =
  Alcotest.(check (list string))
    "blank rows carry no names and do not stop the walk"
    [ "only" ]
    (Operator_control_snapshot_tool_names.collect_recent_tool_names
       ~limit:4
       [ ""; turn_row [ "only" ]; "   " ])
;;

let () =
  Alcotest.run
    "operator_control_snapshot"
    [
      ( "runtime status"
      , [
          Alcotest.test_case
            "diagnostic uses persisted heartbeat freshness"
            `Quick
            test_diagnostic_uses_persisted_heartbeat_freshness;
          Alcotest.test_case
            "lightweight snapshot surfaces heartbeat read error"
            `Quick
            test_lightweight_snapshot_surfaces_heartbeat_read_error;
        ] );
      ( "context metrics ledger"
      , [ Alcotest.test_case
            "last-turn usage does not create context"
            `Quick
            test_usage_does_not_create_context_snapshot
        ; Alcotest.test_case
            "snapshot keeps context unobserved and usage separate"
            `Quick
            test_snapshot_keeps_context_unobserved_and_usage_separate
        ] );
      ( "last_compaction_ago_s removal"
      , [ Alcotest.test_case
            "backend serializers do not emit last_compaction_ago_s"
            `Quick
            test_last_compaction_ago_s_removed_from_backend_serializers
        ] );
      ( "tool host attention"
      , [ Alcotest.test_case
            "digest includes typed tool-host failure"
            `Quick
            test_digest_workspace_includes_tool_host_failure_attention
        ] );
      ( "recent tool names"
      , [ Alcotest.test_case
            "newest rows fill the limit"
            `Quick
            test_recent_tool_names_take_the_newest_rows
        ; Alcotest.test_case
            "a malformed row is skipped"
            `Quick
            test_recent_tool_names_skip_a_malformed_row
        ; Alcotest.test_case
            "blank rows are ignored"
            `Quick
            test_recent_tool_names_ignore_blank_rows
        ] );
      ( "pending-confirm store"
      , [ Alcotest.test_case
            "non-list store rejects snapshot"
            `Quick
            test_snapshot_rejects_non_list_pending_confirm_store
        ; Alcotest.test_case
            "missing confirm token rejects snapshot"
            `Quick
            test_snapshot_rejects_pending_confirm_without_confirm_token
        ; Alcotest.test_case
            "invalid timestamp rejects snapshot"
            `Quick
            test_snapshot_rejects_pending_confirm_with_invalid_timestamp
        ] );
    ]
;;
