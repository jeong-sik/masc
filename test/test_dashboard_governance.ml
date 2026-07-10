module Types = Masc_domain

(** Dashboard governance regression tests. *)

module Lib = Masc

open Alcotest
open Printf

let install_durable_resolution_delivery_hook () =
  Lib.Keeper_approval_queue.set_approval_resolution_wake_hook
    (fun
      ~base_path ~keeper_name ~approval_id ~decision ~channel ->
      let resolution = Keeper_event_queue.{ approval_id; decision; channel } in
      let stimulus : Keeper_event_queue.stimulus =
        { post_id = Keeper_event_queue.hitl_resolution_post_id resolution
        ; urgency = Keeper_event_queue.Immediate
        ; arrived_at = Unix.gettimeofday ()
        ; payload = Keeper_event_queue.Hitl_resolved resolution
        }
      in
      match
        Lib.Keeper_registry_event_queue.enqueue_durable_result
          ~base_path
          keeper_name
          stimulus
      with
      | Error _ as err -> err
      | Ok () -> Ok (fun () -> ()))

let () = install_durable_resolution_delivery_hook ()

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

let string_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub > len_s then false
  else
    let rec loop i =
      if i + len_sub > len_s then false
      else if String.sub s i len_sub = sub then true
      else loop (i + 1)
    in
    loop 0

let iso8601_of_unix ts =
  Masc_domain.iso8601_of_unix_seconds ts

let approval_resume_test_timeout_s = 1.0

let write_legacy_judgment ~base_path json =
  let masc = Filename.concat base_path Common.masc_dirname in
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
      let config = Workspace_utils.default_config dir in
      ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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
      check string "judge status is offline when no judge started" "offline"
        (judge |> member "status" |> to_string);
      check bool "cached judgments are not visible initially" false
        (judge |> member "cached_judgments_visible" |> to_bool);
      check bool "degraded_reason is null initially" true
        (judge |> member "degraded_reason" = `Null);
      check string "keeper_name is governance-judge" "governance-judge"
        (judge |> member "keeper_name" |> to_string);
      let fallback = judge |> member "lenient_json_fallback" in
      check string "fallback metrics label is governance" "governance"
        (fallback |> member "judge" |> to_string);
      ignore
        (fallback |> member "governance_judge_unparseable_total" |> to_int);
      ignore
        (fallback
         |> member "governance_lenient_json_fallback_hit_total"
         |> to_int);
      check bool "model_used is null when no judge started" true
        (judge |> member "model_used" = `Null);
      let judgments = json |> member "judgments" |> to_list in
      check int "judgments empty" 0 (List.length judgments);
      let pending = json |> member "pending_actions" |> to_list in
      check int "pending_actions empty" 0 (List.length pending))

let governance_fallback_count metric_name =
  int_of_float
    (Lib.Otel_metric_store.metric_value_or_zero
       metric_name
       ~labels:[("judge", "governance")]
       ())

let test_dashboard_surfaces_lenient_fallback_metrics () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let config = Workspace_utils.default_config dir in
      ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
      let before_unparseable =
        governance_fallback_count
          Lib.Otel_metric_store.metric_governance_judge_unparseable
      in
      let before_fallback =
        governance_fallback_count
          Lib.Otel_metric_store.metric_governance_lenient_json_fallback_hit
      in
      ignore
        (Judge_diagnostics.record_lenient_fallback
           ~judge_label:"Governance"
           "not-json");
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20
          ~offset:0 ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let fallback =
        json |> member "judge" |> member "lenient_json_fallback"
      in
      check int "unparseable fallback count surfaced"
        (before_unparseable + 1)
        (fallback |> member "governance_judge_unparseable_total" |> to_int);
      check int "lenient fallback hit count surfaced"
        (before_fallback + 1)
        (fallback
         |> member "governance_lenient_json_fallback_hit_total"
         |> to_int))

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
            ("target_id", `String "alice");
            ("status", `String "active");
            ("summary", `String "alice has been stalled for 30 minutes");
            ("confidence", `Float 0.85);
            ("generated_at", `String generated_at);
            ("expires_at", `String expires_at);
            ("model_used", `String "llama:qwen3.5");
            ("keeper_name", `String Dashboard_governance_judge.keeper_name);
            ( "recommended_action",
              `Assoc
                [
                  ("action_kind", `String "recover");
                  ("resolved_tool", `String "masc_operator_confirm");
                  ("target_type", `String "agent");
                  ("target_id", `String "alice");
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
      let st = Dashboard_governance_judge.get_state dir in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.judge_online <- true;
        st.generated_at <- Some generated_at;
        st.generated_at_unix <- Some now;
        st.expires_at <- Some expires_at;
        st.expires_at_unix <- Some expires_at_unix;
        st.model_used <- Some "llama:qwen3.5";
        st.last_error <- None);
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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
      check string "judge status is online" "online"
        (judge |> member "status" |> to_string);
      check bool "judge model is redacted" true
        (judge |> member "model_used" = `Null);
      let judgments = json |> member "judgments" |> to_list in
      check int "legacy judgment surfaced" 1 (List.length judgments);
      let first = List.hd judgments in
      check string "judgment target id" "alice"
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
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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
            ("keeper_name", `String Dashboard_governance_judge.keeper_name);
          ]);
      let json1 =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
          ~status_filter:None
      in
      check int "cooldown suppresses immediate reload" 0
        (json1 |> member "judgments" |> to_list |> List.length);
      let st = Dashboard_governance_judge.get_state dir in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.last_disk_load_unix <- Some (Unix.gettimeofday () -. 31.0));
      let json2 =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let expires_at_unix = now +. 600.0 in
      let generated_at = iso8601_of_unix now in
      let expires_at = iso8601_of_unix expires_at_unix in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.judge_online <- true;
        st.generated_at <- None;
        st.generated_at_unix <- Some now;
        st.expires_at <- None;
        st.expires_at_unix <- Some expires_at_unix;
        st.model_used <- Some "llama:qwen3.5";
        st.last_error <- None);
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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

let test_dashboard_surfaces_compute_telemetry () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      (* The in-flight state is governed by the typed state
         machine ([mark_compute_start] / [mark_compute_finish])
         and is exercised through that API, not by mutating a
         removed counter field.  Terminal-cycle telemetry is
         recorded by [mark_compute_finish] and the test's last
         finish call seeds it with the values the dashboard
         assertion expects. *)
      (* Idle → 0 *)
      check int "idle state projects to 0 in-flight" 0
        (Dashboard_governance_judge.read_in_flight st);
      (* Idle → In_flight : 1, with monotonic cycle_id *)
      let first_cycle = Dashboard_governance_judge.mark_compute_start st in
      check int "after start, in-flight = 1" 1
        (Dashboard_governance_judge.read_in_flight st);
      (* A second start before finish: routine log + replace;
         still 1 in-flight, but cycle_id advanced.  This is
         the typed invariant the previous int counter could
         not preserve. *)
      let second_cycle = Dashboard_governance_judge.mark_compute_start st in
      check bool "second start advances cycle_id" true
        (second_cycle > first_cycle);
      check int "after second start (no finish), in-flight = 1" 1
        (Dashboard_governance_judge.read_in_flight st);
      let started_at = Unix.gettimeofday () in
      ignore
        (Dashboard_governance_judge.mark_compute_finish st ~cycle_id:second_cycle ~started_at
           ~outcome:"ok" ~reason:"");
      check int "after finish, in-flight = 0" 0
        (Dashboard_governance_judge.read_in_flight st);
      (* finish is idempotent: a stray finish on Idle is a
         routine log + no-op, still 0. *)
      ignore
        (Dashboard_governance_judge.mark_compute_finish st ~cycle_id:second_cycle ~started_at
           ~outcome:"ok" ~reason:"");
      check int "stray finish is a no-op (Idle → 0)" 0
        (Dashboard_governance_judge.read_in_flight st);
      (* Seed terminal-cycle telemetry with the values the
         runtime/JSON assertions check, while leaving the
         state in Idle so the dashboard reads 0 in-flight
         with last-outcome=error / last-reason=timeout.  The
         per-cycle budget field [last_compute_timeout_sec]
         is not written by [mark_compute_finish] (the
         governance judge no longer carries a per-cycle
         budget) and is seeded directly here to keep the
         surface-render assertion honest. *)
      let started_at = now -. 12.5 in
      ignore
        (Dashboard_governance_judge.mark_compute_finish st ~cycle_id:second_cycle ~started_at
           ~outcome:"error" ~reason:"timeout");

      Dashboard_governance_judge.with_lock st (fun () ->
        st.last_compute_timeout_sec <- Some 45.0);

      let status =
        Dashboard_governance_judge.runtime_status_at ~now_ts:now dir
      in
      check int "runtime exposes compute in-flight" 0
        status.compute_in_flight;
      check (option string) "runtime exposes compute outcome" (Some "error")
        status.last_compute_outcome;
      check (option string) "runtime exposes compute reason" (Some "timeout")
        status.last_compute_reason;
      (match status.last_compute_duration_sec with
       | Some duration ->
         check (float 0.001) "runtime exposes compute duration" 12.5
           duration
       | None -> fail "expected compute duration");
      (match status.last_compute_timeout_sec with
       | Some timeout_sec ->
         check (float 0.001) "runtime exposes timeout budget" 45.0
           timeout_sec
       | None -> fail "expected timeout budget");
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20
          ~offset:0 ~status_filter:None
      in
      let open Yojson.Safe.Util in
      let judge = json |> member "judge" in
      check int "dashboard exposes compute in-flight" 0
        (judge |> member "compute_in_flight" |> to_int);
      check (float 0.001) "dashboard exposes compute duration" 12.5
        (judge |> member "last_compute_duration_sec" |> to_float);
      check (float 0.001) "dashboard exposes timeout budget" 45.0
        (judge |> member "last_compute_timeout_sec" |> to_float);
      check string "dashboard exposes compute outcome" "error"
        (judge |> member "last_compute_outcome" |> to_string);
      check string "dashboard exposes compute reason" "timeout"
        (judge |> member "last_compute_reason" |> to_string))

let test_parse_governance_response_requires_guardrail_state () =
  let raw =
    Yojson.Safe.to_string
      (`Assoc
        [
          ( "items",
            `List
              [
                `Assoc
                  [
                    ("kind", `String "agent_health");
                    ("id", `String "alice");
                    ("summary", `String "alice is stuck");
                    ("confidence", `Float 0.9);
                    ("evidence_refs", `List []);
                  ];
              ] );
        ])
  in
  match
    Dashboard_governance_judge.parse_governance_response_for_testing
      ~raw_text:raw ~generated_at:"2026-05-06T00:00:00Z"
      ~expires_at:"2026-05-06T00:10:00Z" ~model_used:"glm:test"
  with
  | Error (Dashboard_governance_judge.Structural_error reason) ->
      check bool "reason names guardrail_state" true
        (string_contains reason "missing guardrail_state")
  | Ok _ -> fail "missing guardrail_state must fail closed"

let test_parse_governance_response_preserves_guardrail_state () =
  let raw =
    Yojson.Safe.to_string
      (`Assoc
        [
          ( "items",
            `List
              [
                `Assoc
                  [
                    ("kind", `String "agent_health");
                    ("id", `String "alice");
                    ("summary", `String "alice is stuck");
                    ("confidence", `Float 0.9);
                    ("evidence_refs", `List [ `String "agent:alice" ]);
                    ( "guardrail_state",
                      `Assoc
                        [
                          ("requires_human_gate", `Bool true);
                          ("pending_confirm_token", `String "confirm-1");
                          ("ready_to_execute", `Bool false);
                        ] );
                  ];
              ] );
        ])
  in
  match
    Dashboard_governance_judge.parse_governance_response_for_testing
      ~raw_text:raw ~generated_at:"2026-05-06T00:00:00Z"
      ~expires_at:"2026-05-06T00:10:00Z" ~model_used:"glm:test"
  with
  | Error _ -> fail "valid guardrail_state should parse"
  | Ok [ judgment ] ->
      let open Yojson.Safe.Util in
      let guardrail = judgment |> member "guardrail_state" in
      check bool "requires_human_gate preserved" true
        (guardrail |> member "requires_human_gate" |> to_bool);
      check string "pending_confirm_token preserved" "confirm-1"
        (guardrail |> member "pending_confirm_token" |> to_string);
      check bool "ready_to_execute preserved" false
        (guardrail |> member "ready_to_execute" |> to_bool)
  | Ok rows -> fail (Printf.sprintf "expected one row, got %d" (List.length rows))

let test_parse_governance_response_requires_guardrail_fields () =
  let raw =
    Yojson.Safe.to_string
      (`Assoc
        [
          ( "items",
            `List
              [
                `Assoc
                  [
                    ("kind", `String "agent_health");
                    ("id", `String "alice");
                    ("summary", `String "alice is stuck");
                    ("confidence", `Float 0.9);
                    ("evidence_refs", `List [ `String "agent:alice" ]);
                    ( "guardrail_state",
                      `Assoc
                        [
                          ("requires_human_gate", `Bool true);
                          ("ready_to_execute", `Bool false);
                        ] );
                  ];
              ] );
        ])
  in
  match
    Dashboard_governance_judge.parse_governance_response_for_testing
      ~raw_text:raw ~generated_at:"2026-05-06T00:00:00Z"
      ~expires_at:"2026-05-06T00:10:00Z" ~model_used:"glm:test"
  with
  | Error (Dashboard_governance_judge.Structural_error reason) ->
      check bool "reason names missing field" true
        (string_contains reason "missing guardrail_state.pending_confirm_token")
  | Ok _ -> fail "incomplete guardrail_state must fail closed"

let test_parse_governance_response_requires_items_array () =
  let raw = "{\"judgments\": []}" in
  match
    Dashboard_governance_judge.parse_governance_response_for_testing
      ~raw_text:raw ~generated_at:"2026-05-06T00:00:00Z"
      ~expires_at:"2026-05-06T00:10:00Z" ~model_used:"glm:test"
  with
  | Error (Dashboard_governance_judge.Structural_error reason) ->
      check bool "reason names items array" true
        (string_contains reason "items array")
  | Ok _ -> fail "missing items array must fail closed"

let test_parse_governance_response_rejects_embedded_json_block () =
  let raw = "prefix {\"items\": [} suffix" in
  match
    Dashboard_governance_judge.parse_governance_response_for_testing
      ~raw_text:raw ~generated_at:"2026-05-06T00:00:00Z"
      ~expires_at:"2026-05-06T00:10:00Z" ~model_used:"glm:test"
  with
  | Error (Dashboard_governance_judge.Structural_error reason) ->
      check bool "reason names strict JSON" true
        (string_contains reason "invalid strict JSON")
  | Ok _ -> fail "embedded malformed JSON must fail closed"

let test_refresh_failure_keeps_fresh_cache_online () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let generated_at = iso8601_of_unix now in
      let expires_at = iso8601_of_unix (now +. 300.0) in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.refreshing <- true;
        st.judge_online <- true;
        st.generated_at <- Some generated_at;
        st.generated_at_unix <- Some now;
        st.expires_at <- Some expires_at;
        st.expires_at_unix <- Some (now +. 300.0);
        st.model_used <- Some "glm:test";
        st.last_error <- None;
        Dashboard_governance_judge.mark_refresh_failure
          ~now_ts:now st ~message:"Execution timed out after 60.0s");
      let status =
        Dashboard_governance_judge.runtime_status_at ~now_ts:now dir
      in
      check bool "judge remains online while cache fresh" true
        status.judge_online;
      check bool "refreshing cleared" false status.refreshing;
      check string "runtime status is stale_visible" "stale_visible"
        status.status;
      check (option string) "degraded_reason is timeout" (Some "timeout")
        status.degraded_reason;
      check bool "cached judgments remain visible" true
        status.cached_judgments_visible;
      check (option string) "last_error recorded"
        (Some "Execution timed out after 60.0s") status.last_error;
      check (option string) "model redacted" None
        status.model_used)

let test_refresh_failure_marks_expired_cache_offline () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.refreshing <- true;
        st.judge_online <- true;
        st.expires_at_unix <- Some (now -. 1.0);
        st.last_error <- None;
        Dashboard_governance_judge.mark_refresh_failure
          ~now_ts:now st ~message:"Execution timed out after 60.0s");
      let status =
        Dashboard_governance_judge.runtime_status_at ~now_ts:now dir
      in
      check bool "judge goes offline when cache expired" false
        status.judge_online;
      check string "runtime status is offline" "offline"
        status.status;
      check (option string) "degraded_reason is timeout" (Some "timeout")
        status.degraded_reason;
      check bool "cached judgments are hidden after expiry" false
        status.cached_judgments_visible;
      check (option string) "last_error recorded"
        (Some "Execution timed out after 60.0s") status.last_error)

let test_refresh_failure_sets_timeout_backoff () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let next_compute_after =
        Dashboard_governance_judge.with_lock st (fun () ->
          Dashboard_governance_judge.mark_refresh_failure
            ~now_ts:now st ~message:"Execution timed out after 45.0s";
          st.next_compute_after_unix)
      in
      match next_compute_after with
      | Some next ->
          check bool "timeout backoff is in the future" true (next > now);
          check bool "timeout backoff is capped" true (next <= now +. 300.1)
      | None -> fail "expected timeout backoff deadline")

let test_refresh_failure_clears_timeout_backoff_for_non_timeout () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let next_compute_after =
        Dashboard_governance_judge.with_lock st (fun () ->
          st.next_compute_after_unix <- Some (now +. 60.0);
          Dashboard_governance_judge.mark_refresh_failure
            ~now_ts:now st
            ~message:"Governance judge returned invalid JSON: malformed";
          st.next_compute_after_unix)
      in
      check (option (float 0.001)) "non-timeout clears timeout backoff" None
        next_compute_after)

let test_refresh_failure_marks_judge_output_invalid () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let message =
        "Governance judge returned structurally invalid response \
         (item agent_health:alice missing guardrail_state)"
      in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.refreshing <- true;
        st.judge_online <- false;
        st.last_error <- None;
        Dashboard_governance_judge.mark_refresh_failure
          ~now_ts:now st ~message);
      let status =
        Dashboard_governance_judge.runtime_status_at ~now_ts:now dir
      in
      check string "runtime status is offline" "offline" status.status;
      check (option string) "degraded_reason is judge_output_invalid"
        (Some "judge_output_invalid") status.degraded_reason;
      check (option string) "last_error recorded" (Some message)
        status.last_error)

let test_refresh_failure_marks_invalid_json_as_judge_output_invalid () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let message = "Governance judge returned invalid JSON: malformed items" in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.refreshing <- true;
        st.judge_online <- false;
        st.last_error <- None;
        Dashboard_governance_judge.mark_refresh_failure
          ~now_ts:now st ~message);
      let status =
        Dashboard_governance_judge.runtime_status_at ~now_ts:now dir
      in
      check string "runtime status is offline" "offline" status.status;
      check (option string) "degraded_reason is judge_output_invalid"
        (Some "judge_output_invalid") status.degraded_reason;
      check (option string) "last_error recorded" (Some message)
        status.last_error)

let test_refresh_once_skips_fresh_cached_result () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      let generated_at = iso8601_of_unix now in
      let expires_at_unix = now +. 600.0 in
      let expires_at = iso8601_of_unix expires_at_unix in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.refreshing <- true;
        st.judge_online <- true;
        st.runtime_status <- "refreshing";
        st.generated_at <- Some generated_at;
        st.generated_at_unix <- Some now;
        st.expires_at <- Some expires_at;
        st.expires_at_unix <- Some expires_at_unix;
        st.model_used <- Some "glm:cached";
        st.last_error <- None);
      let build_called = ref false in
      Eio.Switch.run @@ fun sw ->
      Dashboard_governance_judge.refresh_once ~sw
        ~net:(Eio.Stdenv.net env)
        ~masc_tools:[]
        ~dispatch:(fun ~name ~args:_ ->
          Error
            { Tool_result.class_ = Tool_result.Runtime_failure
            ; message = "unused"
            ; data = `String "unused"
            ; tool_name = name
            ; duration_ms = 0.0
            })
        ~base_path:dir
        ~build_facts:(fun () ->
          build_called := true;
          `Assoc []);
      check bool "fresh cached result skips build_facts" false !build_called;
      let status =
        Dashboard_governance_judge.runtime_status_at
          ~now_ts:(Unix.gettimeofday ()) dir
      in
      check bool "judge remains online" true status.judge_online;
      check bool "refreshing cleared" false status.refreshing;
      check string "runtime status is online" "online" status.status;
      check (option string) "last_error stays clear" None status.last_error)

let test_refresh_once_skips_timeout_backoff () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.refreshing <- false;
        st.judge_online <- false;
        st.runtime_status <- "offline";
        st.degraded_reason <- Some "timeout";
        st.last_error <- Some "Execution timed out after 45.0s";
        st.next_compute_after_unix <- Some (now +. 3600.0));
      let build_called = ref false in
      Eio.Switch.run @@ fun sw ->
      Dashboard_governance_judge.refresh_once ~sw
        ~net:(Eio.Stdenv.net env)
        ~masc_tools:[]
        ~dispatch:(fun ~name ~args:_ ->
          Error
            { Tool_result.class_ = Tool_result.Runtime_failure
            ; message = "unused"
            ; data = `String "unused"
            ; tool_name = name
            ; duration_ms = 0.0
            })
        ~base_path:dir
        ~build_facts:(fun () ->
          build_called := true;
          `Assoc []);
      check bool "timeout backoff skips build_facts" false !build_called;
      let status =
        Dashboard_governance_judge.runtime_status_at
          ~now_ts:(Unix.gettimeofday ()) dir
      in
      check (option string) "last timeout remains visible"
        (Some "Execution timed out after 45.0s") status.last_error)

let test_backoff_runtime_status_is_structured () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.refreshing <- false;
        st.judge_online <- false;
        st.runtime_status <- "backoff";
        st.degraded_reason <- Some "backoff";
        st.expires_at_unix <- Some (now +. 300.0);
        st.last_error <- Some "Backoff: local slots saturated");
      let status =
        Dashboard_governance_judge.runtime_status_at ~now_ts:now dir
      in
      check bool "backoff is not reported online" false status.judge_online;
      check string "runtime status is backoff" "backoff" status.status;
      check (option string) "degraded_reason is backoff" (Some "backoff")
        status.degraded_reason;
      check bool "fresh cached judgments remain visible during backoff" true
        status.cached_judgments_visible)

let test_governance_monitoring_uses_live_runtime () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      Eio_main.run @@ fun env ->
      with_test_fs env @@ fun () ->
      let st = Dashboard_governance_judge.get_state dir in
      let now = Unix.gettimeofday () in
      Dashboard_governance_judge.with_lock st (fun () ->
        st.judge_online <- true;
        st.generated_at_unix <- Some now;
        st.expires_at_unix <- Some (now +. 300.0));
      let (json, ok) =
        Dashboard_http_monitoring.governance_monitoring_json ~now_ts:now
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
        Filename.concat (Filename.concat dir Common.masc_dirname) "governance_v2/cases"
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
      let config = Workspace_utils.default_config dir in
      ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20
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
        Dashboard_http_monitoring.governance_monitoring_json ~now_ts:now
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
      let masc = Filename.concat dir Common.masc_dirname in
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
      let config = Workspace_utils.default_config dir in
      ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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
      let config = Workspace_utils.default_config dir in
      ignore (Lib.Workspace.init config ~agent_name:(Some "dashboard"));
      Eio.Switch.run @@ fun sw ->
      let decision_result = ref None in
      let resumed, resume_resolver = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        let decision =
          Lib.Keeper_approval_queue.submit_and_await
            ~keeper_name:"dashboard-keeper"
            ~tool_name:"tool_edit_file"
            ~input:(`Assoc [ ("path", `String "/tmp/danger") ])
            ~risk_level:Lib.Keeper_approval_queue.Critical
            ~base_path:dir
            ~selected_model:"openai:gpt-5.4"
            ()
        in
        decision_result := Some decision;
        Eio.Promise.resolve resume_resolver ());
      Eio.Fiber.yield ();
      let json =
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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
      check string "approval tool name" "tool_edit_file"
        (approval |> member "tool_name" |> to_string);
      check string "approval risk level" "critical"
        (approval |> member "risk_level" |> to_string);
      check bool "approval selected model is redacted" true
        (approval |> member "selected_model" = `Null);
      check string "approval preview"
        {|{"path":"/tmp/danger"}|}
        (approval |> member "input_preview" |> to_string);
      let id = approval |> member "id" |> to_string in
      (match
         Lib.Keeper_approval_queue.resolve
           ~base_path:dir
           ~id
           ~decision:Agent_sdk.Hooks.Approve
       with
       | Ok () -> ()
       | Error err ->
         fail ("resolve failed: " ^ Lib.Keeper_approval_queue.resolve_error_to_string err));
      let decision_result =
        match
          Eio.Time.with_timeout
            (Eio.Stdenv.clock env)
            approval_resume_test_timeout_s
            (fun () ->
               Eio.Promise.await resumed;
               Ok !decision_result)
        with
        | Ok decision_result -> decision_result
        | Error `Timeout ->
          fail
            (Printf.sprintf
               "approval fiber did not resume within %.1fs"
               approval_resume_test_timeout_s)
      in
      match decision_result with
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
            ("keeper_name", `String Dashboard_governance_judge.keeper_name);
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
        Dashboard_governance.dashboard_json ~base_path:dir ~limit:20 ~offset:0
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

let test_approval_queue_surfaces_action_key_and_sandbox_target () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let id =
        Lib.Keeper_approval_queue.submit_pending_observer
          ~keeper_name:"governance-judge"
          ~tool_name:"tool_execute"
          ~input:
            (`Assoc
              [ ("action", `String "pr_view")
              ; ("executable", `String "gh")
              ; ("argv", `List [ `String "pr"; `String "view"; `String "123" ])
              ])
          ~risk_level:Lib.Keeper_approval_queue.Medium
          ~runtime_contract:
            (`Assoc [("backend", `String "docker"); ("sandbox_target", `String "docker")])
          ~base_path:dir
          ~on_resolution_observer:(fun _ -> ())
          ()
      in
      Fun.protect
        ~finally:(fun () ->
          ignore
            (Lib.Keeper_approval_queue.resolve ~base_path:dir ~id
               ~decision:(Agent_sdk.Hooks.Reject "cleanup")))
        (fun () ->
          Eio_main.run @@ fun env ->
          with_test_fs env @@ fun () ->
          let json =
            Dashboard_governance.dashboard_json ~base_path:dir ~limit:20
              ~offset:0 ~status_filter:None
          in
          let open Yojson.Safe.Util in
          let approval =
            json |> member "approval_queue" |> to_list |> List.hd
          in
          check string "action key surfaced" "action:pr_view"
            (approval |> member "action_key" |> to_string);
          check string "sandbox target surfaced" "docker"
            (approval |> member "sandbox_target" |> to_string)))

let () =
  run "dashboard_governance"
    [
      ( "projection",
        [
          test_case "empty governance structure" `Quick
            test_empty_governance_structure;
          test_case "dashboard surfaces lenient fallback metrics" `Quick
            test_dashboard_surfaces_lenient_fallback_metrics;
          test_case "runtime status and judgments are live" `Quick
            test_runtime_status_and_judgments_are_live;
          test_case "empty judgment disk scan uses cooldown" `Quick
            test_empty_judgment_disk_scan_uses_cooldown;
          test_case "runtime timestamps fallback to unix values" `Quick
            test_runtime_timestamps_fallback_to_unix_values;
          test_case "dashboard surfaces compute telemetry" `Quick
            test_dashboard_surfaces_compute_telemetry;
          test_case "parser requires guardrail_state" `Quick
            test_parse_governance_response_requires_guardrail_state;
          test_case "parser preserves guardrail_state" `Quick
            test_parse_governance_response_preserves_guardrail_state;
          test_case "parser requires guardrail fields" `Quick
            test_parse_governance_response_requires_guardrail_fields;
          test_case "parser requires items array" `Quick
            test_parse_governance_response_requires_items_array;
          test_case "parser rejects embedded JSON block" `Quick
            test_parse_governance_response_rejects_embedded_json_block;
          test_case "refresh failure keeps fresh cache online" `Quick
            test_refresh_failure_keeps_fresh_cache_online;
          test_case "refresh failure marks expired cache offline" `Quick
            test_refresh_failure_marks_expired_cache_offline;
          test_case "refresh failure sets timeout backoff" `Quick
            test_refresh_failure_sets_timeout_backoff;
          test_case "non-timeout failure clears timeout backoff" `Quick
            test_refresh_failure_clears_timeout_backoff_for_non_timeout;
          test_case "refresh failure marks judge output invalid" `Quick
            test_refresh_failure_marks_judge_output_invalid;
          test_case "refresh failure marks invalid JSON invalid" `Quick
            test_refresh_failure_marks_invalid_json_as_judge_output_invalid;
          test_case "refresh_once skips fresh cached result" `Quick
            test_refresh_once_skips_fresh_cached_result;
          test_case "refresh_once skips timeout backoff" `Quick
            test_refresh_once_skips_timeout_backoff;
          test_case "backoff runtime status is structured" `Quick
            test_backoff_runtime_status_is_structured;
          test_case "monitoring uses live runtime" `Quick
            test_governance_monitoring_uses_live_runtime;
          test_case "dashboard exposes keeper approval queue" `Quick
            test_dashboard_exposes_keeper_approval_queue;
          test_case "approval queue surfaces action key and sandbox target" `Quick
            test_approval_queue_surfaces_action_key_and_sandbox_target;
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
