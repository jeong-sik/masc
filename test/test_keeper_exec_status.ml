open Alcotest

module ES = Masc_mcp.Keeper_exec_status
module KT = Masc_mcp.Keeper_types

let make_meta ?(name = "keeper-exec-status-test")
    ?(trace_id = "trace-keeper-exec-status") () =
  match
    KT.meta_of_json
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String "keeper_unified");
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
    true (health <> "stale");
  check bool "keepalive running + last_seen at boundary is NOT offline"
    true (health <> "offline")

let test_health_keepalive_stuck_secondary_timeout () =
  let meta = make_meta () in
  (* 700.0 > 2 * 300.0 = 600.0 — secondary stuck-fiber timeout should fire *)
  let agent_status = make_agent_status ~last_seen_ago_s:700.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check string "keepalive running but last_seen > 2x interval → stale (stuck fiber)" "stale" health

let test_health_keepalive_below_secondary_timeout () =
  let meta = make_meta () in
  (* 599.0 < 2 * 300.0 = 600.0 — below stuck threshold; keepalive should still override *)
  let agent_status = make_agent_status ~last_seen_ago_s:599.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check bool "keepalive running + last_seen just below 2x interval is NOT stale"
    true (health <> "stale")

let test_health_keepalive_stuck_respects_interval () =
  let meta = make_meta () in
  (* With a 30s interval, stuck threshold = 2 * 30 = 60s. 70s should be stale. *)
  let agent_status = make_agent_status ~last_seen_ago_s:70.0 () in
  let health =
    ES.keeper_health_state ~keepalive_interval_s:30.0 ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check string "keepalive running + last_seen > 2x configured interval → stale" "stale" health

let test_health_keepalive_not_running_respects_stale_last_seen () =
  let meta = make_meta () in
  let agent_status = make_agent_status ~last_seen_ago_s:600.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:false
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check string "no keepalive + stale last_seen → stale" "stale" health

let test_health_zombie_overrides_keepalive () =
  let meta = make_meta () in
  let agent_status = make_agent_status ~is_zombie:true ~last_seen_ago_s:10.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:true
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check string "zombie overrides keepalive" "stale" health

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
  check string "keepalive + fresh + turns → healthy" "healthy" health

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
  check string "fresh live signal keeps keeper healthy despite stale last turn"
    "healthy" health

let test_health_keepalive_not_running_not_stale_is_offline () =
  let meta = make_meta () in
  let agent_status = make_agent_status ~last_seen_ago_s:50.0 () in
  let health =
    ES.keeper_health_state ~meta ~keepalive_running:false
      ~agent_status ~quiet_reason:None ~now_ts:(Time_compat.now ()) ()
  in
  check string "no keepalive + not stale → offline" "offline" health

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

let () =
  run "keeper_exec_status"
    [
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
        ] );
    ]
