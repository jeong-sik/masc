open Alcotest

module ES = Masc_mcp.Keeper_exec_status
module KSB = Masc_mcp.Keeper_status_bridge
module KR = Masc_mcp.Keeper_registry
module KT = Masc_mcp.Keeper_types
module Coord = Masc_mcp.Coord

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
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)

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

let test_runtime_surface_exposes_redacted_resumable_cli_session_blocker () =
  KR.clear ();
  let base = make_meta ~name:"runtime-resumable-cli-session-test" () in
  let reason =
    Masc_mcp.Oas_worker_exec.Kimi_cli_transport_local.resumable_session_detail
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
                "unified:error:Internal error: Turn wall-clock timeout after 1200s (MASC_KEEPER_TURN_TIMEOUT_SEC)";
              last_preview =
                "Internal error: Turn wall-clock timeout after 1200s (MASC_KEEPER_TURN_TIMEOUT_SEC)";
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
  check string "active model label"
    "codex_cli:auto"
    (runtime |> member "active_model_label" |> to_string);
  check string "last model used label"
    "codex_cli:auto"
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
          test_case "runtime surface derives slot wait timeout blocker" `Quick
            test_runtime_surface_derives_autonomous_slot_wait_timeout_from_meta;
          test_case "runtime surface derives cascade exhausted blocker" `Quick
            test_runtime_surface_derives_cascade_exhausted_from_meta;
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
          test_case "runtime surface exposes social model fields" `Quick
            test_runtime_surface_exposes_social_model_resolution_fields;
          test_case "runtime surface exposes model display labels" `Quick
            test_runtime_surface_exposes_model_display_labels;
        ] );
    ]
