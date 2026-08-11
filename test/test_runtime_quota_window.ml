(* Pins Runtime_quota_window: account-scoped provider quota windows consumed
   as a lane-ordering preference (RFC-0370 §3.3). [now] is a parameter
   everywhere, so no time stubbing. *)

module Q = Runtime_quota_window

let reset () = Q.reset_for_testing ()

(* provider mapping used by demote tests: "prov.model" ids, unknown for
   ids without a dot — mirrors candidates the driver cannot resolve. *)
let provider_id_of candidate =
  match String.index_opt candidate '.' with
  | Some i -> Some (String.sub candidate 0 i)
  | None -> None

let test_window_lifecycle () =
  reset ();
  Alcotest.(check (option (float 0.0)))
    "no window recorded"
    None
    (Q.active_until ~provider_id:"claude_code" ~now:100.0);
  Q.note_exhausted ~provider_id:"claude_code" ~resets_at:500.0;
  Alcotest.(check (option (float 0.0)))
    "active before reset"
    (Some 500.0)
    (Q.active_until ~provider_id:"claude_code" ~now:499.9);
  Alcotest.(check (option (float 0.0)))
    "expired at reset"
    None
    (Q.active_until ~provider_id:"claude_code" ~now:500.0);
  Alcotest.(check (option (float 0.0)))
    "expiry pruned the entry (no resurrection at an earlier now)"
    None
    (Q.active_until ~provider_id:"claude_code" ~now:0.0)

let test_later_reset_extends_earlier_is_ignored () =
  reset ();
  Q.note_exhausted ~provider_id:"codex_subscription" ~resets_at:500.0;
  Q.note_exhausted ~provider_id:"codex_subscription" ~resets_at:900.0;
  Alcotest.(check (option (float 0.0)))
    "later reset extends"
    (Some 900.0)
    (Q.active_until ~provider_id:"codex_subscription" ~now:100.0);
  Q.note_exhausted ~provider_id:"codex_subscription" ~resets_at:600.0;
  Alcotest.(check (option (float 0.0)))
    "earlier reset cannot shorten"
    (Some 900.0)
    (Q.active_until ~provider_id:"codex_subscription" ~now:100.0)

let candidates =
  [ "claude_code.sonnet"; "ollama.qwen"; "claude_code.opus"; "codex.spark" ]

let test_demote_moves_exhausted_provider_to_tail () =
  reset ();
  Q.note_exhausted ~provider_id:"claude_code" ~resets_at:500.0;
  Alcotest.(check (list string))
    "exhausted provider's candidates keep order at the tail"
    [ "ollama.qwen"; "codex.spark"; "claude_code.sonnet"; "claude_code.opus" ]
    (Q.demote_order ~now:100.0 ~provider_id_of candidates)

let test_demote_noop_paths () =
  reset ();
  Alcotest.(check (list string))
    "no windows: unchanged"
    candidates
    (Q.demote_order ~now:100.0 ~provider_id_of candidates);
  Q.note_exhausted ~provider_id:"claude_code" ~resets_at:500.0;
  Alcotest.(check (list string))
    "window passed: unchanged"
    candidates
    (Q.demote_order ~now:501.0 ~provider_id_of candidates);
  Q.note_exhausted ~provider_id:"unrelated_provider" ~resets_at:900.0;
  Alcotest.(check (list string))
    "window on a provider with no candidate: unchanged"
    candidates
    (Q.demote_order ~now:100.0 ~provider_id_of candidates)

let test_unknown_provider_stays_in_place () =
  reset ();
  Q.note_exhausted ~provider_id:"claude_code" ~resets_at:500.0;
  Alcotest.(check (list string))
    "unresolvable id is not demoted"
    [ "no-dot-id"; "ollama.qwen"; "claude_code.sonnet" ]
    (Q.demote_order
       ~now:100.0
       ~provider_id_of
       [ "no-dot-id"; "claude_code.sonnet"; "ollama.qwen" ]
     |> fun reordered ->
     (* stable partition keeps no-dot-id and ollama.qwen in declared order,
        claude_code.sonnet at the tail *)
     reordered)

let test_all_demoted_keeps_declared_order () =
  reset ();
  Q.note_exhausted ~provider_id:"claude_code" ~resets_at:500.0;
  Alcotest.(check (list string))
    "every candidate demoted: declared order preserved, still attemptable"
    [ "claude_code.sonnet"; "claude_code.opus" ]
    (Q.demote_order
       ~now:100.0
       ~provider_id_of
       [ "claude_code.sonnet"; "claude_code.opus" ])

let () =
  Alcotest.run
    "runtime_quota_window"
    [ ( "window"
      , [ Alcotest.test_case "lifecycle" `Quick test_window_lifecycle
        ; Alcotest.test_case
            "later reset extends, earlier ignored"
            `Quick
            test_later_reset_extends_earlier_is_ignored
        ] )
    ; ( "demote"
      , [ Alcotest.test_case
            "exhausted provider to tail"
            `Quick
            test_demote_moves_exhausted_provider_to_tail
        ; Alcotest.test_case "no-op paths" `Quick test_demote_noop_paths
        ; Alcotest.test_case
            "unknown provider stays"
            `Quick
            test_unknown_provider_stays_in_place
        ; Alcotest.test_case
            "all demoted keeps order"
            `Quick
            test_all_demoted_keeps_declared_order
        ] )
    ]
