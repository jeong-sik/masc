(** The before-turn hook does not decide the thinking parameters.

    [Keeper_run_tools_hooks] is assembled once per keeper turn with the
    assignment id. It used to rewrite [enable_thinking] and [preserve_thinking]
    on every agent-core turn from [Runtime_inference.for_runtime] of that id,
    which in a lane is the head's seed handed to every later candidate: a
    glm-5.3 head declaring [preserve-thinking = false] sent [Some false] into a
    claude_code candidate, whose official-client host refuses any explicit
    value, and each glm rate limit ended the turn with a config_error instead
    of failing over (#34899, 121 failures over three keepers).

    The turn driver resolves both fields per dispatched candidate
    ([Keeper_turn_driver.attempt_inference_policy]) and they reach the agent
    config, which [Pipeline_stage_prepare] reads when the turn parameter is
    [None]. That is the one authority; this pins that the hook module does not
    read a runtime seed at all, so the second writer cannot come back in the
    same shape. *)

open Alcotest

let hooks_module = "lib/keeper/keeper_run_tools_hooks.ml"

let test_hook_does_not_read_a_runtime_seed () =
  check int
    (Printf.sprintf "%s does not call Runtime_inference.for_runtime" hooks_module)
    0
    (Ast_grep.count_calls ~module_path:hooks_module ~callee:"Runtime_inference.for_runtime")
;;

let () =
  run
    "keeper_hook_thinking_authority"
    [ ( "before_turn_params"
      , [ test_case "the hook does not read a runtime seed" `Quick
            test_hook_does_not_read_a_runtime_seed
        ] )
    ]
;;
