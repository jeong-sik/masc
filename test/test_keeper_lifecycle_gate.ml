(* test_keeper_lifecycle_gate.ml — RFC-0297 Phase 1 (P0-1).

   Pins the closed-variant gate truth table: a lifecycle activity is
   enabled iff BOTH the global (config) kill-switch and the per-keeper
   (meta) flag are true, and every flag defaults to true so the historical
   always-on behaviour is preserved. Regression guard for the silent-drop
   that RFC-0297 §P0-1 closes. *)

open Alcotest
open Masc

module G = Keeper_lifecycle_gate

let enabled g ~global ~meta = G.gate_enabled g ~global ~meta

let test_default_all_on () =
  (* No kill-switch pinned anywhere → every gate enabled (backwards compat). *)
  let global = G.all_enabled and meta = G.all_enabled in
  check bool "reactive default on" true (enabled G.Reactive ~global ~meta);
  check bool "proactive default on" true (enabled G.Proactive ~global ~meta);
  check bool "autonomous default on" true (enabled G.Autonomous ~global ~meta);
  check bool "bootstrap default on" true (enabled G.Bootstrap ~global ~meta)

let test_global_kill_switch () =
  (* Global [proactive] enabled=false must suppress proactive even though
     the per-keeper flag is on. This is the case that was silently dropped
     before the key_to_env mapping + gate existed. *)
  let global = { G.all_enabled with proactive = false } in
  let meta = G.all_enabled in
  check bool "global proactive kill-switch suppresses proactive" false
    (enabled G.Proactive ~global ~meta);
  check bool "other gates unaffected by proactive kill-switch" true
    (enabled G.Reactive ~global ~meta
     && enabled G.Autonomous ~global ~meta
     && enabled G.Bootstrap ~global ~meta)

let test_per_keeper_flag () =
  (* Per-keeper meta flag off suppresses even when the global switch is on. *)
  let global = G.all_enabled in
  let meta = { G.all_enabled with proactive = false } in
  check bool "per-keeper proactive off suppresses proactive" false
    (enabled G.Proactive ~global ~meta);
  check bool "per-keeper proactive off leaves reactive on" true
    (enabled G.Reactive ~global ~meta)

let test_both_off_and_and_semantics () =
  (* AND semantics: any side false → disabled; both false → disabled. *)
  let global = { G.all_enabled with autonomous = false } in
  let meta = { G.all_enabled with autonomous = false } in
  check bool "both sides off → disabled" false
    (enabled G.Autonomous ~global ~meta);
  let global_only = { G.all_enabled with bootstrap = false } in
  check bool "global bootstrap off → bootstrap disabled" false
    (enabled G.Bootstrap ~global:global_only ~meta:G.all_enabled)

let test_gate_labels () =
  check string "reactive label" "reactive" (G.gate_to_string G.Reactive);
  check string "proactive label" "proactive" (G.gate_to_string G.Proactive);
  check string "autonomous label" "autonomous" (G.gate_to_string G.Autonomous);
  check string "bootstrap label" "bootstrap" (G.gate_to_string G.Bootstrap)

let () =
  run "keeper_lifecycle_gate"
    [ ( "gate_enabled",
        [ test_case "default all-on" `Quick test_default_all_on
        ; test_case "global kill-switch" `Quick test_global_kill_switch
        ; test_case "per-keeper flag" `Quick test_per_keeper_flag
        ; test_case "AND semantics" `Quick test_both_off_and_and_semantics
        ; test_case "gate labels" `Quick test_gate_labels
        ] )
    ]
