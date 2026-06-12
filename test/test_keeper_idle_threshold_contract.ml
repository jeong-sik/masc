(** Idle threshold contract between the OAS loop guard and the masc
    graduated idle hook.

    The hook ({!Keeper_hooks_oas_idle}) escalates over consecutive idle
    turns: nudge -> final warning (skip_at - 1) -> graceful Skip (skip_at).
    The OAS loop guard aborts the run with [IdleDetected] once the idle
    counter reaches [max_idle_turns]. The contract: for every turn channel,
    the guard must sit strictly above the hook's skip threshold — otherwise
    Skip is unreachable, the final warning is injected on a turn the model
    never gets, and the run dies as an error instead of ending gracefully.

    Regression context: the kmsg (user chat) path used to fall back to the
    OAS default guard of 3 while skip_at defaults to 4, so user chat turns
    were killed as [IdleDetected] errors while autonomous turns (guard
    10-15) ended via Skip. *)

open Alcotest

let skip_at = Env_config_keeper.KeeperKeepalive.idle_skip_threshold

let test_reactive_guard_above_skip () =
  let guard = Masc.Keeper_runtime_resolved.reactive_max_idle_turns () in
  check bool
    (Printf.sprintf
       "reactive guard (%d) must exceed idle skip threshold (%d)"
       guard
       skip_at)
    true
    (guard > skip_at)

let test_autonomous_guard_above_skip () =
  let guard = Masc.Keeper_runtime_resolved.autonomous_max_idle_turns () in
  check bool
    (Printf.sprintf
       "autonomous guard (%d) must exceed idle skip threshold (%d)"
       guard
       skip_at)
    true
    (guard > skip_at)

(* The hook injects its final warning at [skip_at - 1]; the model needs at
   least one further turn to react before the guard aborts. Equivalent to
   the strict inequality above, stated separately so a future threshold
   reshuffle that breaks only the warning headroom still fails loudly. *)
let test_final_warning_has_a_reaction_turn () =
  let reactive = Masc.Keeper_runtime_resolved.reactive_max_idle_turns () in
  let autonomous = Masc.Keeper_runtime_resolved.autonomous_max_idle_turns () in
  let final_warning_at = skip_at - 1 in
  check bool
    (Printf.sprintf
       "reactive guard (%d) leaves a turn after final warning (%d)"
       reactive
       final_warning_at)
    true
    (reactive > final_warning_at + 1);
  check bool
    (Printf.sprintf
       "autonomous guard (%d) leaves a turn after final warning (%d)"
       autonomous
       final_warning_at)
    true
    (autonomous > final_warning_at + 1)

let () =
  Alcotest.run
    "Keeper_idle_threshold_contract"
    [ ( "guard vs skip threshold"
      , [ test_case "reactive channel" `Quick test_reactive_guard_above_skip
        ; test_case "autonomous channel" `Quick test_autonomous_guard_above_skip
        ; test_case
            "final warning leaves a reaction turn"
            `Quick
            test_final_warning_has_a_reaction_turn
        ] )
    ]
