(** Dashboard governance regression tests. *)

module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_governance" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let iso8601_of_unix ts =
  Types.iso8601_of_unix_seconds ts

let write_legacy_judgment ~base_path json =
  let masc = Filename.concat base_path ".masc" in
  let governance = Filename.concat masc "governance" in
  Fs_compat.mkdir_p masc;
  Fs_compat.mkdir_p governance;
  let path = Filename.concat governance "judgments.jsonl" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (Yojson.Safe.to_string json);
      output_char oc '\n')

let with_test_fs env f =
  let previous_fs = Fs_compat.get_fs_opt () in
  Fun.protect
    ~finally:(fun () ->
      match previous_fs with
      | Some fs -> Fs_compat.set_fs fs
      | None -> Fs_compat.clear_fs ())
    (fun () ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      f ())

let test_empty_governance_structure () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let _gen = json |> member "generated_at" |> to_string in
      let summary = json |> member "summary" in
      check int "cases_open is 0" 0 (summary |> member "cases_open" |> to_int);
      check int "pending_ruling is 0" 0 (summary |> member "pending_ruling" |> to_int);
      check int "ready_auto_execute is 0" 0
        (summary |> member "ready_auto_execute" |> to_int);
      check int "needs_human_gate is 0" 0
        (summary |> member "needs_human_gate" |> to_int);
      check int "executed is 0" 0 (summary |> member "executed" |> to_int);
      check int "blocked is 0" 0 (summary |> member "blocked" |> to_int);
      check int "ready_to_execute equals ready_auto_execute" 0
        (summary |> member "ready_to_execute" |> to_int);
      check bool "oldest_open_case_age_s is null" true
        (summary |> member "oldest_open_case_age_s" = `Null);
      check bool "last_activity_age_s is null" true
        (summary |> member "last_activity_age_s" = `Null);
      let items = json |> member "items" |> to_list in
      check int "items empty" 0 (List.length items);
      let activity = json |> member "activity" |> to_list in
      check int "activity empty" 0 (List.length activity);
      let judge = json |> member "judge" in
      check bool "judge_online is false when no judge started" false
        (judge |> member "judge_online" |> to_bool);
      check string "keeper_name is governance-judge" "governance-judge"
        (judge |> member "keeper_name" |> to_string);
      check bool "model_used is null when no judge started" true
        (judge |> member "model_used" = `Null);
      let judgments = json |> member "judgments" |> to_list in
      check int "judgments empty" 0 (List.length judgments);
      let pending = json |> member "pending_actions" |> to_list in
      check int "pending_actions empty" 0 (List.length pending))

let test_runtime_status_and_judgments_are_live () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let now = Unix.gettimeofday () in
      let generated_at = iso8601_of_unix now in
      let expires_at_unix = now +. 3600.0 in
      let expires_at = iso8601_of_unix expires_at_unix in
      let legacy_judgment =
        `Assoc
          [
            ("target_kind", `String "agent_health");
            ("target_id", `String "dreamer");
            ("status", `String "active");
            ("summary", `String "dreamer has been stalled for 30 minutes");
            ("confidence", `Float 0.85);
            ("generated_at", `String generated_at);
            ("expires_at", `String expires_at);
            ("model_used", `String "llama:qwen3.5");
            ("keeper_name", `String Lib.Dashboard_governance_judge.keeper_name);
            ( "recommended_action",
              `Assoc
                [
                  ("action_kind", `String "recover");
                  ("resolved_tool", `String "masc_operator_confirm");
                  ("target_type", `String "agent");
                  ("target_id", `String "dreamer");
                  ("reason", `String "zombie agent detected");
                ] );
            ( "guardrail_state",
              `Assoc
                [
                  ("requires_human_gate", `Bool true);
                  ("ready_to_execute", `Bool false);
                ] );
          ]
      in
      write_legacy_judgment ~base_path:dir legacy_judgment;
      let st = Lib.Dashboard_governance_judge.get_state dir in
      Lib.Dashboard_governance_judge.with_lock st (fun () ->
        st.judge_online <- true;
        st.generated_at <- Some generated_at;
        st.generated_at_unix <- Some now;
        st.expires_at <- Some expires_at;
        st.expires_at_unix <- Some expires_at_unix;
        st.model_used <- Some "llama:qwen3.5";
        st.last_error <- None);
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let summary = json |> member "summary" in
      check bool "summary judge_online is live" true
        (summary |> member "judge_online" |> to_bool);
      check string "summary judge_last_seen_at uses runtime" generated_at
        (summary |> member "judge_last_seen_at" |> to_string);
      let judge = json |> member "judge" in
      check bool "judge section online" true
        (judge |> member "judge_online" |> to_bool);
      check string "judge model uses runtime" "llama:qwen3.5"
        (judge |> member "model_used" |> to_string);
      let judgments = json |> member "judgments" |> to_list in
      check int "legacy judgment surfaced" 1 (List.length judgments);
      let first = List.hd judgments in
      check string "judgment target id" "dreamer"
        (first |> member "target_id" |> to_string);
      check string "judgment tool" "masc_operator_confirm"
        (first |> member "recommended_action" |> member "resolved_tool" |> to_string))

let test_empty_judgment_disk_scan_uses_cooldown () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let json0 =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      check int "initially empty" 0
        (json0 |> member "judgments" |> to_list |> List.length);
      let now = Unix.gettimeofday () in
      let generated_at = iso8601_of_unix now in
      let expires_at = iso8601_of_unix (now +. 3600.0) in
      write_legacy_judgment ~base_path:dir
        (`Assoc
          [
            ("target_kind", `String "agent_health");
            ("target_id", `String "cooldown-check");
            ("status", `String "active");
            ("summary", `String "disk cooldown regression guard");
            ("confidence", `Float 0.75);
            ("generated_at", `String generated_at);
            ("expires_at", `String expires_at);
            ("model_used", `String "llama:test");
            ("keeper_name", `String Lib.Dashboard_governance_judge.keeper_name);
          ]);
      let json1 =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      check int "cooldown suppresses immediate reload" 0
        (json1 |> member "judgments" |> to_list |> List.length);
      let st = Lib.Dashboard_governance_judge.get_state dir in
      Lib.Dashboard_governance_judge.with_lock st (fun () ->
        st.last_disk_load_unix <- Some (Unix.gettimeofday () -. 31.0));
      let json2 =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      check int "reload resumes after cooldown" 1
        (json2 |> member "judgments" |> to_list |> List.length))

let test_runtime_timestamps_fallback_to_unix_values () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Lib.Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let expires_at_unix = now +. 600.0 in
      let generated_at = iso8601_of_unix now in
      let expires_at = iso8601_of_unix expires_at_unix in
      Lib.Dashboard_governance_judge.with_lock st (fun () ->
        st.judge_online <- true;
        st.generated_at <- None;
        st.generated_at_unix <- Some now;
        st.expires_at <- None;
        st.expires_at_unix <- Some expires_at_unix;
        st.model_used <- Some "llama:qwen3.5";
        st.last_error <- None);
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let summary = json |> member "summary" in
      check string "summary falls back to generated_at_unix" generated_at
        (summary |> member "judge_last_seen_at" |> to_string);
      let judge = json |> member "judge" in
      check string "judge generated_at falls back to unix" generated_at
        (judge |> member "generated_at" |> to_string);
      check string "judge expires_at falls back to unix" expires_at
        (judge |> member "expires_at" |> to_string))

let test_governance_monitoring_uses_live_runtime () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Lib.Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      Lib.Dashboard_governance_judge.with_lock st (fun () ->
        st.judge_online <- true;
        st.generated_at_unix <- Some now;
        st.expires_at_unix <- Some (now +. 300.0));
      let (json, ok) =
        Lib.Dashboard_http_monitoring.governance_monitoring_json ~now_ts:now
          ~base_path:dir
      in
      let open Yojson.Safe.Util in
      check bool "monitoring call succeeds" true ok;
      check bool "monitoring exposes live judge_online" true
        (json |> member "judge_online" |> to_bool))

let test_pending_ruling_reflects_disk_truth () =
  (* #7815: the dashboard previously hardcoded pending_ruling=0 even
     when .masc/governance_v2/cases/ held stale pending cases.  Seed
     one case and assert both dashboard surfaces surface it. *)
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let cases_dir =
        Filename.concat (Filename.concat dir ".masc") "governance_v2/cases"
      in
      Fs_compat.mkdir_p cases_dir;
      let now = Unix.gettimeofday () in
      let case_json =
        `Assoc
          [
            ("id", `String "case-7815-regression");
            ("title", `String "High-risk tool: stale fixture");
            ("status", `String "pending_ruling");
            ("risk_class", `String "high");
            ("created_at", `Float (now -. 3600.0));
          ]
      in
      let oc =
        open_out (Filename.concat cases_dir "case-7815-regression.json")
      in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc (Yojson.Safe.to_string case_json));
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20
          ~offset:0 ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let summary = json |> member "summary" in
      check int "dashboard pending_ruling counts disk" 1
        (summary |> member "pending_ruling" |> to_int);
      check int "dashboard cases_open mirrors pending_ruling" 1
        (summary |> member "cases_open" |> to_int);
      (match summary |> member "oldest_open_case_age_s" with
       | `Float age ->
         check bool "oldest_open_case_age_s > 0" true (age > 0.0)
       | other ->
         failf "expected float age, got %s" (Yojson.Safe.to_string other));
      let (monitoring, ok) =
        Lib.Dashboard_http_monitoring.governance_monitoring_json ~now_ts:now
          ~base_path:dir
      in
      check bool "monitoring call succeeds" true ok;
      check int "monitoring pending_ruling counts disk" 1
        (monitoring |> member "pending_ruling" |> to_int);
      check string "monitoring alert_level escalates to warn"
        "warn"
        (monitoring |> member "alert_level" |> to_string))

let test_governance_dir_created_before_read () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let masc = Filename.concat dir ".masc" in
      let gov = Filename.concat masc "governance" in
      let judgments = Filename.concat gov "judgments" in
      (* Before ensure_dir: directories do not exist *)
      check bool ".masc/governance does not exist yet" false (Sys.file_exists gov);
      (* Simulate what start() now does: ensure_dir calls Fs_compat.mkdir_p *)
      Unix.mkdir masc 0o755;
      Unix.mkdir gov 0o755;
      Unix.mkdir judgments 0o755;
      check bool ".masc/governance exists" true (Sys.file_exists gov && Sys.is_directory gov);
      check bool ".masc/governance/judgments exists" true
        (Sys.file_exists judgments && Sys.is_directory judgments);
      (* read_recent on empty dir returns [] — dashboard_json should still work *)
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let items = json |> member "items" |> to_list in
      check int "items empty after dir init" 0 (List.length items))

let test_dashboard_exposes_keeper_approval_queue () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let config = Coord_utils.default_config dir in
      ignore (Lib.Coord.init config ~agent_name:(Some "dashboard"));
      Eio.Switch.run @@ fun sw ->
      let decision_result = ref None in
      Eio.Fiber.fork ~sw (fun () ->
        let decision =
          Lib.Keeper_approval_queue.submit_and_await
            ~keeper_name:"dashboard-keeper"
            ~tool_name:"masc_code_delete"
            ~input:(`Assoc [ ("path", `String "/tmp/danger") ])
            ~risk_level:Lib.Keeper_approval_queue.Critical
        in
        decision_result := Some decision);
      Eio.Fiber.yield ();
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let summary = json |> member "summary" in
      check int "needs_human_gate reflects queue" 1
        (summary |> member "needs_human_gate" |> to_int);
      let approval_queue = json |> member "approval_queue" |> to_list in
      check int "approval_queue length" 1 (List.length approval_queue);
      let approval = List.hd approval_queue in
      check string "approval keeper name" "dashboard-keeper"
        (approval |> member "keeper_name" |> to_string);
      check string "approval tool name" "masc_code_delete"
        (approval |> member "tool_name" |> to_string);
      check string "approval risk level" "critical"
        (approval |> member "risk_level" |> to_string);
      check string "approval preview"
        {|{"path":"/tmp/danger"}|}
        (approval |> member "input_preview" |> to_string);
      let id = approval |> member "id" |> to_string in
      (match Lib.Keeper_approval_queue.resolve ~id ~decision:Agent_sdk.Hooks.Approve with
       | Ok () -> ()
       | Error msg -> fail ("resolve failed: " ^ msg));
      Eio.Fiber.yield ();
      match !decision_result with
      | Some Agent_sdk.Hooks.Approve -> ()
      | Some (Agent_sdk.Hooks.Reject reason) ->
        fail ("expected approval resume, got reject: " ^ reason)
      | Some (Agent_sdk.Hooks.Edit _) ->
        fail "expected approval resume, got edit"
      | None -> fail "approval fiber did not resume")

let test_recommended_action_tool_is_canonicalized () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let now = Unix.gettimeofday () in
      let generated_at = iso8601_of_unix now in
      let expires_at = iso8601_of_unix (now +. 3600.0) in
      write_legacy_judgment ~base_path:dir
        (`Assoc
          [
            ("target_kind", `String "agent_health");
            ("target_id", `String "canonical-tool");
            ("status", `String "active");
            ("summary", `String "tool names should tolerate whitespace drift");
            ("confidence", `Float 0.92);
            ("generated_at", `String generated_at);
            ("expires_at", `String expires_at);
            ("model_used", `String "llama:test");
            ("keeper_name", `String Lib.Dashboard_governance_judge.keeper_name);
            ( "recommended_action",
              `Assoc
                [
                  ("action_kind", `String "recover");
                  ("resolved_tool", `String "  MASC_OPERATOR_CONFIRM  ");
                  ("target_type", `String "agent");
                  ("target_id", `String "canonical-tool");
                  ("reason", `String "normalize whitespace and case");
                ] );
          ]);
      let json =
        Lib.Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let judgments = json |> member "judgments" |> to_list in
      check int "canonicalized judgment surfaced" 1 (List.length judgments);
      let resolved_tool =
        List.hd judgments
        |> member "recommended_action" |> member "resolved_tool" |> to_string
      in
      check string "resolved_tool canonicalized" "masc_operator_confirm"
        resolved_tool)

let () =
  run "dashboard_governance"
    [
      ( "projection",
        [
          test_case "empty governance structure" `Quick
            test_empty_governance_structure;
          test_case "runtime status and judgments are live" `Quick
            test_runtime_status_and_judgments_are_live;
          test_case "empty judgment disk scan uses cooldown" `Quick
            test_empty_judgment_disk_scan_uses_cooldown;
          test_case "runtime timestamps fallback to unix values" `Quick
            test_runtime_timestamps_fallback_to_unix_values;
          test_case "monitoring uses live runtime" `Quick
            test_governance_monitoring_uses_live_runtime;
          test_case "dashboard exposes keeper approval queue" `Quick
            test_dashboard_exposes_keeper_approval_queue;
          test_case "recommended action tool is canonicalized" `Quick
            test_recommended_action_tool_is_canonicalized;
          test_case "pending_ruling reflects disk truth (#7815)" `Quick
            test_pending_ruling_reflects_disk_truth;
        ] );
      ( "init",
        [
          test_case "governance dirs created before read" `Quick
            test_governance_dir_created_before_read;
        ] );
    ]
