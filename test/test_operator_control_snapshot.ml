module Types = Masc_domain

open Masc_mcp
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

let test_max_turns_override_source_accepts_raised_ceiling () =
  Alcotest.(check string) "100 is a valid profile override" "override"
    (Operator_control_snapshot.max_turns_override_source (Some 100));
  Alcotest.(check string) "101 remains invalid" "override_invalid"
    (Operator_control_snapshot.max_turns_override_source (Some 101));
  Alcotest.(check string) "missing override comes from env" "env"
    (Operator_control_snapshot.max_turns_override_source None)

let test_compute_context_ratio_uses_resolved_cli_context_budget () =
  let base =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [
            ("name", `String "ctx-ratio-demo");
            ("agent_name", `String "keeper-ctx-ratio-demo-agent");
            ("trace_id", `String "trace-ctx-ratio-demo");
            ("cascade_name", `String "big_three");
          ])
    with
    | Ok meta -> meta
    | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)
  in
  let meta =
    {
      base with
      models = [ "codex_cli:auto" ];
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              last_model_used = "codex";
              last_input_tokens = 2_106_223;
            };
        };
    }
  in
  let ratio =
    match Operator_control_snapshot.compute_context_ratio meta with
    | Some value -> value
    | None -> Alcotest.fail "expected context ratio"
  in
  Alcotest.(check (float 0.0001)) "codex bare provider uses 1.05M context"
    (2106223.0 /. 1050000.0) ratio

let test_snapshot_prefers_metrics_context_truth_over_usage_counters () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
      let keeper_ctx : _ Tool_keeper.context =
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
        match Keeper_types.read_meta config keeper_name with
        | Ok (Some meta) -> meta
        | Ok None -> Alcotest.fail "expected keeper meta"
        | Error err -> Alcotest.fail err
      in
      let updated_meta =
        {
          meta with
          models = [ "codex_cli:auto" ];
          runtime =
            {
              meta.runtime with
              usage =
                {
                  meta.runtime.usage with
                  last_model_used = "codex";
                  last_input_tokens = 6_637_033;
                  last_total_tokens = 6_670_646;
                };
            };
        }
      in
      (match Keeper_types.write_meta config updated_meta with
      | Ok () -> ()
      | Error err -> Alcotest.fail err);
      let metrics_store = Keeper_types.keeper_metrics_store config keeper_name in
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
        match Operator_control_snapshot.compute_context_ratio updated_meta with
        | Some value -> value
        | None -> Alcotest.fail "expected usage fallback ratio"
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
      Alcotest.(check bool) "metrics ratio differs from usage fallback" true
        (Float.abs (snapshot_ratio -. usage_ratio) > 0.000001);
      Alcotest.(check bool) "metrics tokens differ from usage fallback" true
        (snapshot_tokens <> updated_meta.runtime.usage.last_input_tokens);
      Alcotest.(check bool) "nested context payload omitted" true
        (Yojson.Safe.Util.member "context" keeper = `Null))

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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let keeper_ctx : _ Tool_keeper.context =
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
                ("goal", `String "Expose paused keeper failure in summary");
                ("proactive_enabled", `Bool false);
                ("autoboot_enabled", `Bool false);
              ])
      in
      Alcotest.(check bool) "keeper up ok" true ok;
      Keeper_keepalive.stop_keepalive keeper_name;
      let meta =
        match Keeper_types.read_meta config keeper_name with
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
                "Completion contract [require_tool_use] violated: actionable keeper signal was present, but the model called no keeper tools";
              last_blocker_class =
                Some Keeper_types.Completion_contract_violation;
            };
        }
      in
      (match Keeper_types.write_meta config meta with
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
              `String "completion_contract_violation:require_tool_use" );
            ("operator_disposition", `String "pause_human");
            ( "operator_disposition_reason",
              `String "tool_required_unsatisfied" );
            ( "tool_contract_result",
              `String "missing_required_tool_use" );
            ("tools_used", `List []);
            ( "tool_surface",
              `Assoc
                [
                  ("tool_requirement", `String "required");
                  ("required_tools", `List [ `String "keeper_bash" ]);
                  ("missing_required_tools", `List [ `String "keeper_bash" ]);
                  ("visible_tool_count", `Int 8);
                ] );
            ( "sandbox",
              `Assoc
                [
                  ("kind", `String "docker");
                  ("sandbox_root", `String base_dir);
                  ("network_mode", `String "inherit");
                ] );
            ( "cascade",
              `Assoc
                [
                  ("name", `String "big_three");
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
      Alcotest.(check string) "trust disposition pauses" "Pause"
        (trust |> member "disposition" |> to_string);
      Alcotest.(check string) "operator reason preserved"
        "tool_required_unsatisfied"
        (trust |> member "operator_disposition_reason" |> to_string);
      Alcotest.(check string) "terminal code preserved"
        "required_tool_use_unsatisfied"
        (trust |> member "latest_terminal_reason" |> member "code"
       |> to_string))

let test_snapshot_has_expected_sections () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
      ignore (Coord.add_task config ~title:"operator backlog" ~priority:2 ~description:"");
      ignore (Coord.broadcast config ~from_agent:"owner" ~content:"operator snapshot seed");
      let json = Operator_control.snapshot_json (operator_ctx env sw config "owner") in
      let root = Yojson.Safe.Util.member "root" json in
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
      Alcotest.(check string) "admission mode" "passthrough"
        Yojson.Safe.Util.(admission |> member "mode" |> to_string);
      Alcotest.(check string) "admission throttle owner" "oas_cascade"
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      let ctx = operator_ctx env sw config "owner" in
      let request_namespace_pause actor =
        match
          Operator_control.action_json ctx
            (`Assoc
              [
                ("actor", `String actor);
                ("action_type", `String "namespace_pause");
                ("target_type", `String "namespace");
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
      Alcotest.(check bool) "root github identity login prepare listed" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(
               row |> member "action_type" |> to_string)
             = "github_identity_login_prepare")
           confirm_required_actions);
      Alcotest.(check bool) "keeper github identity login prepare listed" true
        (List.exists
           (fun row ->
             Yojson.Safe.Util.(
               row |> member "action_type" |> to_string)
             = "keeper_github_identity_login_prepare")
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
      let keeper_ctx : _ Tool_keeper.context =
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
      let metrics_store = Keeper_types.keeper_metrics_store config keeper_name in
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
        match Keeper_types.read_meta config keeper_name with
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
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
      let keeper_ctx : _ Tool_keeper.context =
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
      let decision_path = Keeper_types.keeper_decision_log_path config keeper_name in
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
        match Keeper_types.read_meta config keeper_name with
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

let test_snapshot_waiters_share_inflight_result () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio_guard.enable ();
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
      Operator_control.invalidate_snapshot_cache ();
      let ctx = operator_ctx env sw config "owner" in
      ignore (Operator_control.snapshot_json ctx);
      let cache_key =
        Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
          (fun () ->
            match
              Hashtbl.to_seq_keys Operator_control_snapshot._snapshot_table
              |> List.of_seq
            with
            | key :: _ -> key
            | [] -> Alcotest.fail "expected primed snapshot cache key")
      in
      Operator_control.invalidate_snapshot_cache ();
      let cond = Eio.Condition.create () in
      Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
        (fun () ->
          Hashtbl.replace Operator_control_snapshot._snapshot_table cache_key
            (Operator_control_snapshot.Computing { cond }));
      let waiter_a, resolve_waiter_a = Eio.Promise.create () in
      let waiter_b, resolve_waiter_b = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolve_waiter_a (Operator_control.snapshot_json ctx));
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Promise.resolve resolve_waiter_b (Operator_control.snapshot_json ctx));
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
      let shared =
        `Assoc
          [
            ("trace_id", `String "shared-trace");
            ("status", `String "ok");
          ]
      in
      Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
        (fun () ->
          Hashtbl.replace Operator_control_snapshot._snapshot_table cache_key
            (Operator_control_snapshot.Cached
               {
                 value = shared;
                 expires_at =
                   Time_compat.now () +. Operator_control_snapshot._snapshot_ttl_s;
               }));
      Eio.Condition.broadcast cond;
      let first = Eio.Promise.await waiter_a in
      let second = Eio.Promise.await waiter_b in
      Alcotest.(check string) "waiter a shared trace" "shared-trace"
        Yojson.Safe.Util.(first |> member "trace_id" |> to_string);
      Alcotest.(check string) "waiter b shared trace" "shared-trace"
        Yojson.Safe.Util.(second |> member "trace_id" |> to_string);
      let cached_retained =
        Eio.Mutex.use_rw ~protect:true Operator_control_snapshot._snapshot_mu
          (fun () ->
            match
              Hashtbl.find_opt Operator_control_snapshot._snapshot_table cache_key
            with
            | Some (Operator_control_snapshot.Cached _) -> true
            | _ -> false)
      in
      Alcotest.(check bool) "healthy inflight slot not evicted" true cached_retained)

(* test_orchestra_room_core_shape removed (CP purge: Command_plane_orchestra deleted) *)

let test_digest_room_exposes_pending_confirm_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "operator"));
      let ctx = operator_ctx env sw config "operator" in
      let action_json =
        Operator_control.action_json ctx
          (`Assoc
            [
              ("actor", `String "operator");
               ("action_type", `String "namespace_pause");
               ("target_type", `String "namespace");
            ])
      in
      (match action_json with Ok _ -> () | Error err -> Alcotest.fail err);
      let digest =
        match Operator_control.digest_json ~actor:"operator" ctx with
        | Ok json -> json
        | Error err -> Alcotest.fail err
      in
      Alcotest.(check string) "target_type" "root"
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
         are warn/bad; in a fresh room they are absent *)
      Alcotest.(check bool) "no command attention in fresh room" true
        (not
           (List.exists
              (fun item ->
                String.starts_with
                  ~prefix:"command_"
                  Yojson.Safe.Util.(item |> member "kind" |> to_string))
              attention_items)))

let test_digest_room_includes_tool_host_failure_attention () =
  Eio_main.run @@ fun env ->
  ensure_fs env;
  Eio.Switch.run @@ fun sw ->
  let base_dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      let config = Coord.default_config base_dir in
      ignore (Coord.init config ~agent_name:(Some "owner"));
      ignore (Coord.join config ~agent_name:"owner" ~capabilities:[] ());
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
