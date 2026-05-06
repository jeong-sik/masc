open Alcotest
module Rec = Masc_mcp.Keeper_recurring
module Live = Masc_mcp.Keeper_turn_liveness

let capacity_info ?(total = 1) ?(active = 1) ?(available = 0) ?(queue = 0) () =
  Masc_mcp.Cascade_throttle.
    { total
    ; process_active = active
    ; process_available = available
    ; process_queue_length = queue
    ; source = Llm_provider.Provider_throttle.Discovered
    }
;;

let test_recurring_task_reenable_waits_for_disable_cooldown () =
  Rec.clear ();
  let keeper_name = "death-spiral-recurring" in
  let _task =
    Rec.add
      ~keeper_name
      ~label:"coordination"
      ~interval_sec:10
      ~max_failures:2
      (Rec.Broadcast "tick")
  in
  let dispatch_failure _task _action = Error "boom" in
  ignore (Rec.dispatch_due ~keeper_name ~now_ts:10.0 ~dispatch:dispatch_failure);
  ignore (Rec.dispatch_due ~keeper_name ~now_ts:20.0 ~dispatch:dispatch_failure);
  let disabled = List.hd (Rec.list ~keeper_name) in
  check bool "task disabled after max failures" false disabled.enabled;
  check
    int
    "before cooldown no reenable"
    0
    (Rec.reenable_due_tasks ~keeper_name ~now_ts:39.0);
  check bool "task still disabled before cooldown" false disabled.enabled;
  check
    int
    "after cooldown reenabled"
    1
    (Rec.reenable_due_tasks ~keeper_name ~now_ts:40.0);
  check bool "task enabled after cooldown" true disabled.enabled;
  check int "failure count reset" 0 disabled.failure_count
;;

let test_saturation_skip_cap_forces_turn_after_limit () =
  let keeper_name = "death-spiral-saturation" in
  Live.For_testing.reset_saturation_skip_count ~keeper_name ();
  let url = "http://127.0.0.1:11434" in
  let saturated = capacity_info ~active:1 ~available:0 ~queue:1 () in
  let lookup _ = Some saturated in
  for i = 1 to Live.For_testing.max_consecutive_saturation_skips do
    check
      bool
      (Printf.sprintf "saturated skip %d remains true" i)
      true
      (Live.is_ollama_saturated ~keeper_name ~capacity_lookup:lookup url)
  done;
  check
    bool
    "skip cap forces a turn"
    false
    (Live.is_ollama_saturated ~keeper_name ~capacity_lookup:lookup url);
  check
    bool
    "counter resets after forced turn"
    true
    (Live.is_ollama_saturated ~keeper_name ~capacity_lookup:lookup url);
  Live.For_testing.reset_saturation_skip_count ~keeper_name ()
;;

let test_saturation_without_keeper_name_is_stateless () =
  let url = "http://127.0.0.1:11434" in
  let saturated = capacity_info ~active:1 ~available:0 ~queue:1 () in
  let lookup _ = Some saturated in
  for i = 1 to Live.For_testing.max_consecutive_saturation_skips + 2 do
    check
      bool
      (Printf.sprintf "anonymous saturated check %d stays stateless" i)
      true
      (Live.is_ollama_saturated ~capacity_lookup:lookup url)
  done
;;

let () =
  run
    "keeper_death_spiral_prevention"
    [ ( "recurring"
      , [ test_case
            "reenable waits for disable cooldown"
            `Quick
            test_recurring_task_reenable_waits_for_disable_cooldown
        ] )
    ; ( "saturation"
      , [ test_case
            "skip cap forces turn"
            `Quick
            test_saturation_skip_cap_forces_turn_after_limit
        ; test_case
            "anonymous saturation checks stay stateless"
            `Quick
            test_saturation_without_keeper_name_is_stateless
        ] )
    ]
;;
