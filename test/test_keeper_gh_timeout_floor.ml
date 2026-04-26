(** Ratchet for [Keeper_exec_shell.gh_min_timeout_sec].

    2026-04-17/18 logs (~/me/.masc/tool_calls) showed 41
    gh_command_timed_out rejections in 2 days, every one at
    timeout_sec=5. gh round-trip + auth handshake is usually 3-10s,
    so any floor under ~15s lets the LLM request a
    sub-network-latency timeout and re-enters the same failure loop.

    This test locks the floor at 15.0 — future contributors who try
    to drop it back into sub-latency territory must update the
    constant AND this assertion, which surfaces the regression in
    review. See #8688. *)

module Shell = Masc_mcp.Keeper_exec_shell

let test_floor_is_at_least_network_latency () =
  Alcotest.(check (float 0.01))
    "gh_min_timeout_sec floor >= network latency budget (15s)"
    15.0
    Shell.gh_min_timeout_sec;
  Alcotest.(check bool)
    "floor is strictly above historical 5s failure point"
    true
    (Shell.gh_min_timeout_sec > 5.0)
;;

let () =
  Alcotest.run
    "keeper_gh_timeout_floor"
    [ ( "gh_min_timeout_sec"
      , [ Alcotest.test_case "floor >= 15s" `Quick test_floor_is_at_least_network_latency
        ] )
    ]
;;
