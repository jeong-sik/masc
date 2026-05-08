open Alcotest

module ES = Masc_mcp.Keeper_exec_status
module Metrics = Masc_mcp.Keeper_exec_status_metrics
module KSB = Masc_mcp.Keeper_status_bridge
module KR = Masc_mcp.Keeper_registry
module KT = Masc_mcp.Keeper_types
module KMP = Masc_mcp.Keeper_memory_policy
module KTS = Masc_mcp.Keeper_types_support
module Coord = Masc_mcp.Coord
module OWN = Masc_mcp.Keeper_turn_driver
module Prom = Masc_mcp.Prometheus

let keeper_health_testable : KT.keeper_health Alcotest.testable =
  Alcotest.testable
    (fun fmt h -> Format.pp_print_string fmt (ES.keeper_health_to_string h))
    (=)

let make_meta ?(name = "keeper-exec-status-test")
    ?(trace_id = "trace-keeper-exec-status") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
          ("last_model_used", `String "llama:auto");
          ("sandbox_profile", `String "local");
          ("network_mode", `String "inherit");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_base_path prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)

let has_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > hay_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let iso_of_seconds_ago age_s =
  let ts = Time_compat.now () -. age_s in
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let test_keeper_surface_status_preserves_live_agent_states () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "busy") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "healthy") ])
  in
  check string "healthy busy keeper stays busy" "busy" status

let test_keeper_surface_status_maps_stale_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "active") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "stale") ])
  in
  check string "stale keeper is not surfaced as active" "inactive" status

let test_keeper_surface_status_maps_degraded_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "listening") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "degraded") ])
  in
  check string "degraded keeper is not surfaced as listening" "inactive" status

let test_keeper_surface_status_maps_zombie_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "active") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "zombie") ])
  in
  check string "zombie keeper is not surfaced as active" "inactive" status

let test_keeper_surface_status_maps_dead_to_inactive () =
  let status =
    ES.keeper_surface_status
      ~agent_status:
        (`Assoc
          [ ("exists", `Bool true); ("status", `String "busy") ])
      ~diagnostic:(`Assoc [ ("health_state", `String "dead") ])
  in
  check string "dead keeper is not surfaced as busy" "inactive" status

let test_keeper_status_helpers_tolerate_null_status_json () =
  check string "null agent status is unknown" "unknown" (ES.agent_status_text `Null);
  check bool "null agent status has no live signal" false
    (ES.agent_runtime_has_live_signal `Null);
  check string "null surface inputs fall back offline" "offline"
    (ES.keeper_surface_status ~agent_status:`Null ~diagnostic:`Null)

let assoc_member key fields =
  match List.assoc_opt key fields with
  | Some value -> value
  | None -> `Null

let write_lines path lines =
  KT.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      List.iter
        (fun line ->
          output_string oc line;
          output_char oc '\n')
        lines)

let persistence_read_drop_total ~surface ~reason =
  Prom.metric_value_or_zero Prom.metric_persistence_read_drops
    ~labels:[("surface", surface); ("reason", reason)]
    ()

let check_persistence_drop_delta ~surface ~reason ~before ~delta =
  Alcotest.(check (float 0.0001))
    (Printf.sprintf "%s/%s persistence drops" surface reason)
    (before +. float_of_int delta)
    (persistence_read_drop_total ~surface ~reason)

let test_metrics_summary_counts_parse_drops () =
  let surface = "keeper_exec_status_metrics" in
  let entry_reason = "entry_load_error" in
  let invalid_reason = "invalid_payload" in
  let before_entry =
    persistence_read_drop_total ~surface ~reason:entry_reason
  in
  let before_invalid =
    persistence_read_drop_total ~surface ~reason:invalid_reason
  in
  let summary =
    Metrics.summarize_metrics_lines
      [
        {|{"channel":"turn","ts_unix":1.0,"trace_id":"trace-ok"}|};
        "{not-json";
        "[]";
      ]
      ~default_generation:0
  in
  let summary_json = Metrics.metrics_summary_to_json summary in
  let sample_points =
    match assoc_member "sample_points" (Yojson.Safe.Util.to_assoc summary_json) with
    | `Int value -> value
    | other ->
        Alcotest.failf "unexpected sample_points JSON: %s"
          (Yojson.Safe.to_string other)
  in
  check int "only valid object rows are summarized" 1 sample_points;
  check_persistence_drop_delta ~surface ~reason:entry_reason
    ~before:before_entry ~delta:1;
  check_persistence_drop_delta ~surface ~reason:invalid_reason
    ~before:before_invalid ~delta:1

let test_tool_audit_counts_decision_log_parse_drops () =
  let surface = "keeper_exec_status_decision_log" in
  let entry_reason = "entry_load_error" in
  let invalid_reason = "invalid_payload" in
  let before_entry =
    persistence_read_drop_total ~surface ~reason:entry_reason
  in
  let before_invalid =
    persistence_read_drop_total ~surface ~reason:invalid_reason
  in
  with_temp_base_path "test-keeper-exec-status-decision-drops" (fun base_path ->
      let config = Coord.default_config base_path in
      let keeper_name = "keeper-tool-audit-decisions" in
      write_lines
        (KT.keeper_decision_log_path config keeper_name)
        [
          {|{"ts":"2026-05-07T00:00:00Z","tools_used":["masc_task_status"],"tool_call_count":1}|};
          "[]";
          "{not-json";
        ];
      match
        Metrics.latest_tool_audit_snapshot_from_files config ~keeper_name
      with
      | None -> Alcotest.fail "expected decision log tool audit snapshot"
      | Some snapshot ->
          check (list string) "decision tools" ["masc_task_status"]
            snapshot.latest_tool_names;
          check (option int) "decision tool count" (Some 1)
            snapshot.latest_tool_call_count;
          check (option string) "decision source" (Some "keeper_decision_log")
            snapshot.tool_audit_source);
  check_persistence_drop_delta ~surface ~reason:entry_reason
    ~before:before_entry ~delta:1;
  check_persistence_drop_delta ~surface ~reason:invalid_reason
    ~before:before_invalid ~delta:1

let test_tool_audit_counts_metrics_parse_drops () =
  let surface = "keeper_exec_status_keeper_metrics" in
  let entry_reason = "entry_load_error" in
  let invalid_reason = "invalid_payload" in
  let before_entry =
    persistence_read_drop_total ~surface ~reason:entry_reason
  in
  let before_invalid =
    persistence_read_drop_total ~surface ~reason:invalid_reason
  in
  with_temp_base_path "test-keeper-exec-status-metrics-drops" (fun base_path ->
      let config = Coord.default_config base_path in
      let keeper_name = "keeper-tool-audit-metrics" in
      write_lines
        (KT.keeper_metrics_path config keeper_name)
        [
          {|{"ts":"2026-05-07T00:00:00Z","tools_used":["masc_board_post"],"tool_call_count":1}|};
          "[]";
          "{not-json";
        ];
      match
        Metrics.latest_tool_audit_snapshot_from_files config ~keeper_name
      with
      | None -> Alcotest.fail "expected metrics tool audit snapshot"
      | Some snapshot ->
          check (list string) "metrics tools" ["masc_board_post"]
            snapshot.latest_tool_names;
          check (option int) "metrics tool count" (Some 1)
            snapshot.latest_tool_call_count;
          check (option string) "metrics source" (Some "keeper_metrics")
            snapshot.tool_audit_source);
  check_persistence_drop_delta ~surface ~reason:entry_reason
    ~before:before_entry ~delta:1;
  check_persistence_drop_delta ~surface ~reason:invalid_reason
    ~before:before_invalid ~delta:1

let test_attention_fields_promote_runtime_trust_attention () =
  let fields =
    [
      ("needs_attention", `Bool false);
      ("attention_reason", `Null);
      ("next_human_action", `Null);
      ("source", `String "exec_status");
    ]
  in
  let trust =
    `Assoc
      [
        ("needs_attention", `Bool true);
        ("attention_reason", `String "required_tool_use_unsatisfied");
        ("next_human_action", `String "inspect_runtime_trust");
      ]
  in
  let merged = KSB.attention_fields_with_runtime_trust fields trust in
  check bool "trust attention promoted" true
    (assoc_member "needs_attention" merged = `Bool true);
  check string "trust reason promoted" "required_tool_use_unsatisfied"
    (Yojson.Safe.Util.to_string (assoc_member "attention_reason" merged));
  check string "trust action promoted" "inspect_runtime_trust"
    (Yojson.Safe.Util.to_string (assoc_member "next_human_action" merged));
  check string "extra field preserved" "exec_status"
    (Yojson.Safe.Util.to_string (assoc_member "source" merged))

let test_attention_fields_keep_existing_attention_reason () =
  let fields =
    [
      ("needs_attention", `Bool true);
      ("attention_reason", `String "approval_pending");
      ("next_human_action", `String "resolve_approval");
    ]
  in
  let trust =
    `Assoc
      [
        ("needs_attention", `Bool true);
        ("attention_reason", `String "runtime_trust_pause");
        ("next_human_action", `String "inspect_runtime_trust");
      ]
  in
  let merged = KSB.attention_fields_with_runtime_trust fields trust in
  check string "existing reason preserved" "approval_pending"
    (Yojson.Safe.Util.to_string (assoc_member "attention_reason" merged));
  check string "existing action preserved" "resolve_approval"
    (Yojson.Safe.Util.to_string (assoc_member "next_human_action" merged))

(* --- keeper_health_state tests (online/offline mismatch fix) --- *)

let make_agent_status ?(exists = true) ?(status = "active")
    ?(last_seen_ago_s = 10.0) ?(is_zombie = false) () : Yojson.Safe.t =
  `Assoc [
    ("exists", `Bool exists);
    ("status", `String status);
    ("last_seen", `String (iso_of_seconds_ago last_seen_ago_s));
    ("last_seen_ago_s", `Float last_seen_ago_s);
    ("is_zombie", `Bool is_zombie);
  ]

let test_keeper_diagnostic_tolerates_null_agent_status () =
  let meta = make_meta ~name:"keeper-null-agent-status-test" () in
  let diagnostic =
    ES.keeper_diagnostic_json ~meta ~agent_status:`Null ~keepalive_running:true
      ~history_items:[] ~now_ts:(Time_compat.now ())
  in
  let open Yojson.Safe.Util in
  check string "null agent status maps diagnostic offline" "offline"
    (diagnostic |> member "health_state" |> to_string);
  check string "null agent status maps quiet reason" "agent_missing"
    (diagnostic |> member "quiet_reason" |> to_string)

let test_health_keepalive_running_overrides_stale_last_seen () =
  let meta = make_meta () in
  (* 600.0 is at the boundary of 2 * 300.0 (default interval); > is strict so NOT stale *)
  let agent_status = make_agent_status ~last_seen_ago_s:600.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  (* keepalive is running and last_seen has not exceeded 2x the max keepalive interval *)
  check bool "keepalive running + last_seen at boundary is NOT stale"
    true (health <> KT.KH_stale);
  check bool "keepalive running + last_seen at boundary is NOT offline"
    true (health <> KT.KH_offline)

let test_health_keepalive_stuck_secondary_timeout () =
  let meta = make_meta () in
  (* 700.0 > 2 * 300.0 = 600.0 — secondary stuck-fiber timeout should fire *)
  let agent_status = make_agent_status ~last_seen_ago_s:700.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check keeper_health_testable "keepalive running but last_seen > 2x interval → stale (stuck fiber)" KT.KH_stale health

let test_health_keepalive_below_secondary_timeout () =
  let meta = make_meta () in
  (* 599.0 < 2 * 300.0 = 600.0 — below stuck threshold; keepalive should still override *)
  let agent_status = make_agent_status ~last_seen_ago_s:599.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check bool "keepalive running + last_seen just below 2x interval is NOT stale"
    true (health <> KT.KH_stale)

let test_health_keepalive_stuck_respects_interval () =
  let meta = make_meta () in
  (* With a 30s interval, stuck threshold = 2 * 30 = 60s. 70s should be stale. *)
  let agent_status = make_agent_status ~last_seen_ago_s:70.0 () in
  let health =
    ES.keeper_health_state ~keepalive_interval_s:30.0 ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check keeper_health_testable "keepalive running + last_seen > 2x configured interval → stale" KT.KH_stale health

let test_health_keepalive_not_running_respects_stale_last_seen () =
  let meta = make_meta () in
  let agent_status = make_agent_status ~last_seen_ago_s:600.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:false
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check keeper_health_testable "no keepalive + stale last_seen → stale" KT.KH_stale health

let test_health_zombie_overrides_keepalive () =
  let meta = make_meta () in
  let agent_status = make_agent_status ~is_zombie:true ~last_seen_ago_s:10.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check keeper_health_testable "zombie overrides keepalive" KT.KH_stale health

let test_health_keepalive_running_fresh_is_healthy () =
  let meta =
    let base = make_meta () in
    { base with runtime = { base.runtime with
        usage = { base.runtime.usage with
          total_turns = 5;
          last_turn_ts = Time_compat.now () };
      }}
  in
  let agent_status = make_agent_status ~last_seen_ago_s:10.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check keeper_health_testable "keepalive + fresh + turns → healthy" KT.KH_healthy health

let test_health_keepalive_running_recent_live_signal_avoids_idle () =
  let now_ts = Time_compat.now () in
  let meta =
    let base = make_meta () in
    {
      base with
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              total_turns = 5;
              last_turn_ts = now_ts -. 3600.0;
            };
        };
    }
  in
  let agent_status = make_agent_status ~status:"active" ~last_seen_ago_s:10.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts ()
  in
  check keeper_health_testable "fresh live signal keeps keeper healthy despite stale last turn"
    KT.KH_healthy health

let test_health_keepalive_not_running_not_stale_is_offline () =
  let meta = make_meta () in
  let agent_status = make_agent_status ~last_seen_ago_s:50.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:false
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check keeper_health_testable "no keepalive + not stale → offline" KT.KH_offline health

let test_diagnostic_ignores_stale_error_when_live_signal_is_newer () =
  let now_ts = Time_compat.now () in
  let base = make_meta () in
  let stale_error_ts = now_ts -. 1800.0 in
  let meta =
    {
      base with
      updated_at = iso_of_seconds_ago 1800.0;
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              total_turns = 5;
              last_turn_ts = stale_error_ts;
            };
          proactive_rt =
            {
              base.runtime.proactive_rt with
              count_total = 5;
              last_ts = stale_error_ts;
              last_outcome = KT.Proactive_error;
              last_reason =
                "unified:error:Timeout: Execution cancelled after 300.0s";
              last_preview = "Timeout: Execution cancelled after 300.0s";
            };
        };
    }
  in
  let diagnostic =
    ES.keeper_diagnostic_json ~meta ~keepalive_running:true
      ~agent_status:(make_agent_status ~status:"busy" ~last_seen_ago_s:10.0 ())
      ~history_items:[] ~now_ts
  in
  let open Yojson.Safe.Util in
  check string "fresh live signal suppresses stale degraded status"
    "healthy"
    (diagnostic |> member "health_state" |> to_string)

let test_runtime_surface_derives_autonomous_slot_wait_timeout_from_meta () =
  KR.clear ();
  let base = make_meta ~name:"runtime-slot-timeout-test" () in
  let reason =
    "autonomous turn slot wait timeout after 30.0s (limit=30.0s, wait_ms=30000); skipped cycle before OAS run"
  in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          last_blocker = reason;
        };
    }
  in
  let config = Coord.default_config "/tmp/test-keeper-exec-status-slot-timeout" in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "runtime blocker class"
    "autonomous_slot_wait_timeout"
    (runtime |> member "runtime_blocker_class" |> to_string);
  check string "runtime blocker summary"
    reason
    (runtime |> member "runtime_blocker_summary" |> to_string);
  check bool "runtime blocker continue gate stays false"
    false
    (runtime |> member "runtime_blocker_continue_gate" |> to_bool)

let test_runtime_surface_derives_cascade_exhausted_from_meta () =
  KR.clear ();
  let base = make_meta ~name:"runtime-cascade-exhausted-test" () in
  let reason =
    "Internal error: [masc_oas_error] {\"kind\":\"cascade_exhausted\",\"cascade_name\":\"big_three\",\"detail\":\"all providers failed: Connection refused\"}"
  in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          last_blocker = reason;
        };
    }
  in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-cascade-exhausted"
  in
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "runtime blocker class"
    "cascade_exhausted"
    (runtime |> member "runtime_blocker_class" |> to_string);
  check string "runtime blocker summary"
    "Cascade exhausted after provider failures; local runtime connection refused."
    (runtime |> member "runtime_blocker_summary" |> to_string);
  check bool "runtime blocker continue gate stays false"
    false
    (runtime |> member "runtime_blocker_continue_gate" |> to_bool)

let test_runtime_surface_names_no_tool_provider_details () =
  KR.clear ();
  let payload =
    OWN.No_tool_capable_provider
      {
        cascade_name = OWN.cascade_name_of_string "tool_required";
        configured_labels = [ "codex"; "kimi" ];
        required_tool_names = [ "keeper_bash"; "masc_worktree_create" ];
        provider_rejections =
          [
            {
              OWN.provider_label = "codex_cli:codex";
              provider_kind = "codex_cli";
              reason = "codex_keeper_bound_actor_required";
            };
          ];
      }
  in
  let summary =
    match OWN.summary_of_masc_internal_error payload with
    | Some summary -> summary
    | None -> fail "expected no-tool provider summary"
  in
  let base = make_meta ~name:"runtime-no-tool-provider-test" () in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          last_blocker = summary;
          last_blocker_class = Some KT.No_tool_capable_provider;
        };
    }
  in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-no-tool-provider"
  in
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  let surfaced_summary =
    runtime |> member "runtime_blocker_summary" |> to_string
  in
  check string "runtime blocker class"
    "no_tool_capable_provider"
    (runtime |> member "runtime_blocker_class" |> to_string);
  check bool "summary names required worktree tool" true
    (has_substring surfaced_summary "masc_worktree_create");
  check bool "summary names rejected provider and reason" true
    (has_substring surfaced_summary
       "codex_cli:codex:codex_keeper_bound_actor_required")

let test_runtime_surface_routes_oas_timeout_to_timeout_action () =
  KR.clear ();
  with_temp_base_path "test-keeper-exec-status-oas-timeout" (fun base_path ->
      let base = make_meta ~name:"runtime-oas-timeout-action-test" () in
      let meta =
        {
          base with
          runtime =
            {
              base.runtime with
              last_blocker =
                "OAS budget timeout fired before the keeper hard timeout.";
              last_blocker_class = Some KT.Oas_timeout_budget;
            };
        }
      in
      let config = Coord.default_config base_path in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let runtime = KSB.runtime_surface_json config meta in
      let open Yojson.Safe.Util in
      check string "runtime blocker class"
        "oas_timeout_budget"
        (runtime |> member "runtime_blocker_class" |> to_string);
      check bool "needs attention" true
        (runtime |> member "needs_attention" |> to_bool);
      check string "attention reason"
        "timeout_budget_exhausted"
        (runtime |> member "attention_reason" |> to_string);
      check string "next human action"
        "inspect_timeout_budget"
        (runtime |> member "next_human_action" |> to_string))

let test_runtime_surface_routes_paused_timeout_to_paused_action () =
  KR.clear ();
  with_temp_base_path "test-keeper-exec-status-paused-oas-timeout"
    (fun base_path ->
      let base = make_meta ~name:"runtime-paused-oas-timeout-action-test" () in
      let meta =
        {
          base with
          paused = true;
          runtime =
            {
              base.runtime with
              last_blocker =
                "OAS budget timeout fired before the keeper hard timeout.";
              last_blocker_class = Some KT.Oas_timeout_budget;
            };
        }
      in
      let config = Coord.default_config base_path in
      ignore (KR.register ~base_path:config.base_path meta.name meta);
      let runtime = KSB.runtime_surface_json config meta in
      let open Yojson.Safe.Util in
      check string "runtime blocker class"
        "oas_timeout_budget"
        (runtime |> member "runtime_blocker_class" |> to_string);
      check bool "needs attention" true
        (runtime |> member "needs_attention" |> to_bool);
      check string "attention reason"
        "paused_blocked"
        (runtime |> member "attention_reason" |> to_string);
      check string "next human action"
        "inspect_runtime_blocker"
        (runtime |> member "next_human_action" |> to_string))

let test_runtime_surface_exposes_redacted_resumable_cli_session_blocker () =
  KR.clear ();
  let base = make_meta ~name:"runtime-resumable-cli-session-test" () in
  let reason =
    Masc_mcp.Cascade_runner.Kimi_cli_transport_local.resumable_session_detail
  in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          last_blocker = reason;
          last_blocker_class =
            Some (KT.Cascade_exhausted (KT.Other_detail reason));
        };
    }
  in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-resumable-cli-session"
  in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  let runtime = KSB.runtime_surface_json config meta in
  let contains_substring haystack needle =
    let hay_len = String.length haystack in
    let needle_len = String.length needle in
    let rec loop i =
      if i + needle_len > hay_len then false
      else if String.sub haystack i needle_len = needle then true
      else loop (i + 1)
    in
    needle_len = 0 || loop 0
  in
  let open Yojson.Safe.Util in
  let summary = runtime |> member "runtime_blocker_summary" |> to_string in
  check string "last blocker stays redacted"
    reason
    (runtime |> member "last_blocker" |> to_string);
  check string "runtime blocker class"
    "cascade_exhausted"
    (runtime |> member "runtime_blocker_class" |> to_string);
  check string "runtime blocker summary stays redacted"
    reason
    summary;
  check bool "runtime blocker hides raw session command" false
    (contains_substring summary "kimi -r");
  check bool "runtime blocker continue gate stays false"
    false
    (runtime |> member "runtime_blocker_continue_gate" |> to_bool)

let test_runtime_surface_derives_continue_gate_from_ambiguous_partial_commit () =
  KR.clear ();
  let meta = make_meta ~name:"runtime-continue-gate-test" () in
  let detail =
    "Mutating tools [keeper_fs_edit] committed before the turn timed out."
  in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-continue-gate"
  in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  KR.set_failure_reason ~base_path:config.base_path meta.name
    (Some
       (KR.Ambiguous_partial_commit
          {
            kind = KR.Post_commit_timeout;
            detail;
          }));
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "runtime blocker class"
    "ambiguous_post_commit_timeout"
    (runtime |> member "runtime_blocker_class" |> to_string);
  check string "runtime blocker summary"
    detail
    (runtime |> member "runtime_blocker_summary" |> to_string);
  check bool "runtime blocker continue gate"
    true
    (runtime |> member "runtime_blocker_continue_gate" |> to_bool)

let test_runtime_surface_derives_continue_gate_from_persisted_ambiguous_blocker () =
  KR.clear ();
  let base = make_meta ~name:"runtime-persisted-manual-reconcile-test" () in
  let reason =
    "turn outcome ambiguous after committed mutating tool call(s): [keeper_board_cleanup]; retry disabled to avoid duplicate mutation; original_error=Completion contract [require_tool_use] violated"
  in
  let meta =
    {
      base with
      paused = true;
      runtime =
        {
          base.runtime with
          last_blocker = reason;
        };
    }
  in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-persisted-manual-reconcile"
  in
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "runtime blocker class"
    "ambiguous_post_commit_failure"
    (runtime |> member "runtime_blocker_class" |> to_string);
  check string "runtime blocker summary"
    reason
    (runtime |> member "runtime_blocker_summary" |> to_string);
  check bool "runtime blocker continue gate"
    true
    (runtime |> member "runtime_blocker_continue_gate" |> to_bool)

let test_runtime_surface_suppresses_stale_proactive_timeout_reason () =
  KR.clear ();
  let now_ts = Time_compat.now () in
  let base = make_meta ~name:"runtime-stale-proactive-timeout-test" () in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              total_turns = 3;
              last_turn_ts = now_ts;
            };
          proactive_rt =
            {
              base.runtime.proactive_rt with
              last_ts = now_ts -. 600.0;
              last_outcome = KT.Proactive_error;
              last_reason =
                "unified:error:Internal error: Turn wall-clock timeout after 3600s (MASC_KEEPER_TURN_TIMEOUT_SEC)";
              last_preview =
                "Internal error: Turn wall-clock timeout after 3600s (MASC_KEEPER_TURN_TIMEOUT_SEC)";
            };
        };
    }
  in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-stale-proactive-timeout"
  in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  let json_string_opt = function
    | `Null -> None
    | `String value -> Some value
    | _ -> fail "expected string-or-null runtime blocker field"
  in
  check (option string) "stale proactive timeout suppressed" None
    (runtime |> member "runtime_blocker_summary" |> json_string_opt);
  check (option string) "stale proactive blocker class suppressed" None
    (runtime |> member "runtime_blocker_class" |> json_string_opt)

let test_runtime_surface_maps_stale_watchdog_failure_reason () =
  KR.clear ();
  let meta = make_meta ~name:"runtime-stale-watchdog-test" () in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-stale-watchdog"
  in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  KR.set_failure_reason ~base_path:config.base_path meta.name
    (Some
       (KR.Stale_turn_timeout
          (KR.In_turn_hung
             { active_seconds = 720.0; timeout_threshold = 600.0 })));
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "runtime blocker class" "stale_turn_timeout"
    (runtime |> member "runtime_blocker_class" |> to_string);
  let summary = runtime |> member "runtime_blocker_summary" |> to_string in
  check bool "summary preserves stale kill subclass" true
    (has_substring summary "in_turn_hung");
  check bool "runtime attention needed" true
    (runtime |> member "needs_attention" |> to_bool);
  check string "runtime next action" "inspect_runtime_blocker"
    (runtime |> member "next_human_action" |> to_string)

let test_runtime_surface_maps_stale_termination_storm_failure_reason () =
  KR.clear ();
  let meta = make_meta ~name:"runtime-stale-storm-test" () in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-stale-storm"
  in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  KR.set_failure_reason ~base_path:config.base_path meta.name
    (Some (KR.Stale_termination_storm { count = 8 }));
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "runtime blocker class" "stale_termination_storm"
    (runtime |> member "runtime_blocker_class" |> to_string);
  let summary = runtime |> member "runtime_blocker_summary" |> to_string in
  check bool "summary preserves storm count" true
    (has_substring summary "8 keeper cycle");
  check bool "runtime attention needed" true
    (runtime |> member "needs_attention" |> to_bool);
  check string "runtime attention reason" "runtime_blocked"
    (runtime |> member "attention_reason" |> to_string)

let test_runtime_surface_maps_heartbeat_failure_reason () =
  KR.clear ();
  let meta = make_meta ~name:"runtime-heartbeat-failure-test" () in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-heartbeat-failure"
  in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  KR.set_failure_reason ~base_path:config.base_path meta.name
    (Some (KR.Heartbeat_consecutive_failures 3));
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "runtime blocker class" "heartbeat_failures"
    (runtime |> member "runtime_blocker_class" |> to_string);
  let summary = runtime |> member "runtime_blocker_summary" |> to_string in
  check bool "summary preserves count" true
    (has_substring summary "3 consecutive")

let test_runtime_surface_maps_registry_failure_reason_blockers () =
  let cases =
    [
      ( "turn-failures",
        KR.Turn_consecutive_failures 4,
        "turn_failures",
        "4 consecutive" );
      ( "fiber-unresolved",
        KR.Fiber_unresolved,
        "fiber_unresolved",
        "did not resolve" );
      ( "exception",
        KR.Exception "forced boom",
        "exception",
        "forced boom" );
    ]
  in
  List.iter
    (fun (suffix, reason, expected_class, expected_summary_substring) ->
       KR.clear ();
       let meta = make_meta ~name:("runtime-" ^ suffix ^ "-test") () in
       let config =
         Coord.default_config
           ("/tmp/test-keeper-exec-status-" ^ suffix)
       in
       ignore (KR.register ~base_path:config.base_path meta.name meta);
       KR.set_failure_reason ~base_path:config.base_path meta.name
         (Some reason);
       let runtime = KSB.runtime_surface_json config meta in
       let open Yojson.Safe.Util in
       check string (suffix ^ " runtime blocker class") expected_class
         (runtime |> member "runtime_blocker_class" |> to_string);
       let summary =
         runtime |> member "runtime_blocker_summary" |> to_string
       in
       check bool (suffix ^ " summary preserves root cause") true
         (has_substring summary expected_summary_substring);
       check bool (suffix ^ " runtime attention needed") true
         (runtime |> member "needs_attention" |> to_bool))
    cases

let test_runtime_surface_classifies_progress_narrative_blockers () =
  let cases =
    [
      ( "operator-gate",
        "OpenQuestions: Why hasn't the push gate been resolved in 24h+?",
        "awaiting_operator",
        "push gate" );
      ( "sandbox-egress",
        "OpenQuestions: whether keeper docker sandboxes can be granted github.com push egress",
        "awaiting_sandbox_egress",
        "github.com push egress" );
      ( "supervisor-paused",
        "Decisions: [SYNTHETIC] Last output: 실제 막힘. supervisor가 의도적으로 건 pause",
        "supervisor_paused",
        "supervisor" );
      ( "synthetic-stall",
        "Decisions: [SYNTHETIC] BELIEF_SUMMARY: Continuity advisory flags backlog delta",
        "synthetic_stall",
        "BELIEF_SUMMARY" );
      ( "self-imposed-idle",
        "Next: watch the next dispatch cycle; no next action",
        "self_imposed_idle",
        "no next action" );
    ]
  in
  List.iter
    (fun (suffix, continuity_summary, expected_class, expected_summary_substring) ->
       KR.clear ();
       let base = make_meta ~name:("runtime-progress-" ^ suffix ^ "-test") () in
       let meta = { base with continuity_summary } in
       let config =
         Coord.default_config ("/tmp/test-keeper-exec-status-progress-" ^ suffix)
       in
       let runtime = KSB.runtime_surface_json config meta in
       let open Yojson.Safe.Util in
       check string (suffix ^ " runtime blocker class") expected_class
         (runtime |> member "runtime_blocker_class" |> to_string);
       let summary =
         runtime |> member "runtime_blocker_summary" |> to_string
       in
       check bool (suffix ^ " summary preserves progress narrative") true
         (has_substring summary expected_summary_substring);
       check bool (suffix ^ " runtime attention needed") true
         (runtime |> member "needs_attention" |> to_bool))
    cases

let test_runtime_surface_reads_progress_md_narrative_blocker () =
  KR.clear ();
  with_temp_base_path "test-keeper-exec-status-progress-md-" (fun base_path ->
    let meta = make_meta ~name:"runtime-progress-md-narrative-test" () in
    let config = Coord.default_config base_path in
    let snapshot =
      {
        KMP.empty_keeper_state_snapshot with
        open_questions =
          [
            "when operator responds to the 4-gate decision tree";
          ];
      }
    in
    let path = KTS.keeper_progress_path config meta.name in
    match KMP.write_progress_snapshot_path ~path snapshot with
    | Error err -> fail ("write_progress_snapshot_path failed: " ^ err)
    | Ok () ->
        let runtime = KSB.runtime_surface_json config meta in
        let open Yojson.Safe.Util in
        check string "progress.md blocker class" "awaiting_operator"
          (runtime |> member "runtime_blocker_class" |> to_string);
        check bool "progress.md blocker summary keeps narrative" true
          (has_substring
             (runtime |> member "runtime_blocker_summary" |> to_string)
             "4-gate decision tree"))

let test_runtime_surface_prefers_typed_blocker_over_progress_narrative () =
  KR.clear ();
  let base = make_meta ~name:"runtime-progress-typed-priority-test" () in
  let meta =
    {
      base with
      continuity_summary =
        "OpenQuestions: when operator responds to the 4-gate decision tree";
      runtime =
        {
          base.runtime with
          last_blocker = "turn wall-clock timeout exceeded";
          last_blocker_class = Some KT.Turn_timeout;
        };
    }
  in
  let config = Coord.default_config "/tmp/test-keeper-exec-status-progress-priority" in
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "typed runtime blocker wins" "turn_timeout"
    (runtime |> member "runtime_blocker_class" |> to_string)

let test_runtime_surface_exposes_social_model_resolution_fields () =
  KR.clear ();
  let base = make_meta ~name:"runtime-social-model-test" () in
  let meta =
    {
      base with
      social_model = "experimental_v99";
      runtime =
        {
          base.runtime with
          last_speech_act =
            Masc_mcp.Keeper_social_model.speech_act_to_string
              Masc_mcp.Keeper_social_model.Stay_silent;
          last_social_transition_reason = "tool_only:stay_silent";
          last_blocker = "waiting_for_delta";
          last_need = "";
        };
    }
  in
  let config = Coord.default_config "/tmp/test-keeper-exec-status-social-model" in
  ignore (KR.register ~base_path:config.base_path meta.name meta);
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  check string "normalized social model"
    "bdi_speech_v1"
    (runtime |> member "social_model" |> to_string);
  check string "configured social model preserved"
    "experimental_v99"
    (runtime |> member "configured_social_model" |> to_string);
  check bool "recognized flag" false
    (runtime |> member "social_model_recognized" |> to_bool);
  check string "fallback social model"
    "bdi_speech_v1"
    (runtime |> member "social_model_fallback" |> to_string);
  check string "last speech act"
    "stay_silent"
    (runtime |> member "last_speech_act" |> to_string);
  check string "delivery surface view"
    "silent"
    (runtime |> member "delivery_surface_view" |> to_string);
  check string "delivery surface view source"
    "derived_from_last_speech_act"
    (runtime |> member "delivery_surface_view_source" |> to_string);
  check string "transition reason"
    "tool_only:stay_silent"
    (runtime |> member "last_social_transition_reason" |> to_string);
  check string "last blocker"
    "waiting_for_delta"
    (runtime |> member "last_blocker" |> to_string);
  check (option string) "blank last_need omitted" None
    (runtime |> member "last_need" |> to_string_option)

let test_runtime_surface_exposes_model_display_labels () =
  KR.clear ();
  let base = make_meta ~name:"runtime-model-label-test" () in
  let meta =
    {
      base with
      runtime =
        {
          base.runtime with
          usage =
            {
              base.runtime.usage with
              last_model_used = "codex";
            };
        };
    }
  in
  let config =
    Coord.default_config "/tmp/test-keeper-exec-status-model-display-labels"
  in
  let runtime = KSB.runtime_surface_json config meta in
  let open Yojson.Safe.Util in
  let active_model_label =
    runtime |> member "active_model_label" |> to_string
  in
  check bool "active model provider label" true
    (String.starts_with ~prefix:"codex_cli:" active_model_label);
  check string "last model used label"
    active_model_label
    (runtime |> member "last_model_used_label" |> to_string)

(* Issue #8670: parser must round-trip every constructor and reject
   unknown strings. The previous catch-all silently mapped typos to
   KH_offline, masking drift between dashboard producers and consumers. *)
let test_parser_roundtrip_all_constructors () =
  let all : KT.keeper_health list =
    [ KH_healthy; KH_idle; KH_offline; KH_stale;
      KH_degraded; KH_zombie; KH_dead ]
  in
  List.iter (fun h ->
    let wire = ES.keeper_health_to_string h in
    match ES.keeper_health_of_string_opt wire with
    | Some h' when h' = h -> ()
    | Some _ -> Alcotest.failf "roundtrip mismatch for %s" wire
    | None -> Alcotest.failf "of_string_opt rejected canonical wire %S" wire)
  all

let test_parser_rejects_unknown () =
  Alcotest.(check (option string)) "typo → None" None
    (Option.map ES.keeper_health_to_string
       (ES.keeper_health_of_string_opt "healty"));
  Alcotest.(check (option string)) "future variant → None" None
    (Option.map ES.keeper_health_to_string
       (ES.keeper_health_of_string_opt "compacting"))

let () =
  run "keeper_exec_status"
    [
      ( "health_state_parser",
        [
          test_case "round-trip covers all 7 constructors" `Quick
            test_parser_roundtrip_all_constructors;
          test_case "rejects unknown wire strings" `Quick
            test_parser_rejects_unknown;
        ] );
      ( "metrics_read_drops",
        [
          test_case "metrics summary counts malformed rows" `Quick
            test_metrics_summary_counts_parse_drops;
          test_case "decision log tool audit counts malformed rows" `Quick
            test_tool_audit_counts_decision_log_parse_drops;
          test_case "metrics tool audit counts malformed rows" `Quick
            test_tool_audit_counts_metrics_parse_drops;
        ] );
      ( "health_state",
        [
          test_case "keepalive running overrides stale last_seen" `Quick
            test_health_keepalive_running_overrides_stale_last_seen;
          test_case "keepalive stuck: secondary timeout fires" `Quick
            test_health_keepalive_stuck_secondary_timeout;
          test_case "keepalive stuck: below threshold not stale" `Quick
            test_health_keepalive_below_secondary_timeout;
          test_case "keepalive stuck: respects configured interval" `Quick
            test_health_keepalive_stuck_respects_interval;
          test_case "no keepalive respects stale last_seen" `Quick
            test_health_keepalive_not_running_respects_stale_last_seen;
          test_case "zombie overrides keepalive" `Quick
            test_health_zombie_overrides_keepalive;
          test_case "keepalive + fresh turns → healthy" `Quick
            test_health_keepalive_running_fresh_is_healthy;
          test_case "keepalive + recent live signal avoids idle" `Quick
            test_health_keepalive_running_recent_live_signal_avoids_idle;
          test_case "no keepalive + not stale → offline" `Quick
            test_health_keepalive_not_running_not_stale_is_offline;
          test_case "fresh live signal suppresses stale error degradation" `Quick
            test_diagnostic_ignores_stale_error_when_live_signal_is_newer;
          test_case "diagnostic tolerates null agent status json" `Quick
            test_keeper_diagnostic_tolerates_null_agent_status;
        ] );
      ( "surface_status",
        [
          test_case "preserves live agent states" `Quick
            test_keeper_surface_status_preserves_live_agent_states;
          test_case "maps stale to inactive" `Quick
            test_keeper_surface_status_maps_stale_to_inactive;
          test_case "maps degraded to inactive" `Quick
            test_keeper_surface_status_maps_degraded_to_inactive;
          test_case "maps zombie to inactive" `Quick
            test_keeper_surface_status_maps_zombie_to_inactive;
          test_case "maps dead to inactive" `Quick
            test_keeper_surface_status_maps_dead_to_inactive;
          test_case "status helpers tolerate null status json" `Quick
            test_keeper_status_helpers_tolerate_null_status_json;
          test_case "attention fields promote runtime trust attention" `Quick
            test_attention_fields_promote_runtime_trust_attention;
          test_case "attention fields keep existing attention reason" `Quick
            test_attention_fields_keep_existing_attention_reason;
          test_case "runtime surface derives slot wait timeout blocker" `Quick
            test_runtime_surface_derives_autonomous_slot_wait_timeout_from_meta;
          test_case "runtime surface derives cascade exhausted blocker" `Quick
            test_runtime_surface_derives_cascade_exhausted_from_meta;
          test_case "runtime surface names no-tool provider details" `Quick
            test_runtime_surface_names_no_tool_provider_details;
          test_case "runtime surface routes OAS timeout to timeout action"
            `Quick
            test_runtime_surface_routes_oas_timeout_to_timeout_action;
          test_case "runtime surface routes paused timeout to paused action"
            `Quick
            test_runtime_surface_routes_paused_timeout_to_paused_action;
          test_case "runtime surface keeps resumable CLI blocker redacted"
            `Quick
            test_runtime_surface_exposes_redacted_resumable_cli_session_blocker;
          test_case "runtime surface derives continue-gate blocker" `Quick
            test_runtime_surface_derives_continue_gate_from_ambiguous_partial_commit;
          test_case "runtime surface derives persisted continue-gate blocker"
            `Quick
            test_runtime_surface_derives_continue_gate_from_persisted_ambiguous_blocker;
          test_case "runtime surface suppresses stale proactive timeout blocker"
            `Quick
            test_runtime_surface_suppresses_stale_proactive_timeout_reason;
          test_case "runtime surface maps stale watchdog failure reason"
            `Quick
            test_runtime_surface_maps_stale_watchdog_failure_reason;
          test_case "runtime surface maps stale termination storm failure reason"
            `Quick
            test_runtime_surface_maps_stale_termination_storm_failure_reason;
          test_case "runtime surface maps heartbeat failure reason" `Quick
            test_runtime_surface_maps_heartbeat_failure_reason;
          test_case "runtime surface maps registry failure blockers" `Quick
            test_runtime_surface_maps_registry_failure_reason_blockers;
          test_case "runtime surface classifies progress narrative blockers"
            `Quick
            test_runtime_surface_classifies_progress_narrative_blockers;
          test_case "runtime surface reads progress.md narrative blocker"
            `Quick
            test_runtime_surface_reads_progress_md_narrative_blocker;
          test_case "runtime surface prefers typed blocker over progress narrative"
            `Quick
            test_runtime_surface_prefers_typed_blocker_over_progress_narrative;
          test_case "runtime surface exposes social model fields" `Quick
            test_runtime_surface_exposes_social_model_resolution_fields;
          test_case "runtime surface exposes model display labels" `Quick
            test_runtime_surface_exposes_model_display_labels;
        ] );
    ]
