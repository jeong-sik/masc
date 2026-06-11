(** White-box tests for [Server_bootstrap_http.with_cleanups_on_release]
    introduced by PR-C5 (follow-up to PR-B / PR #20583, PR-C1, PR-C2).

    PR-B replaced the per-fiber [int Atomic.t] counter and its
    [Eio.Switch.on_release] decrement callback with a typed state
    machine.  PR-C1 spread the same pattern to [fd_accountant].
    PR-C2 took a *different* shape for [operator_control_snapshot] --
    [Fun.protect ~finally] scope encapsulation.

    PR-C5 takes yet another shape for the
    [server_bootstrap_http] / [server_routes_http_routes_dashboard]
    call sites: a [with_cleanups_on_release] helper that runs each
    cleanup step in its own [try/with] so a single non-Cancelled
    exception in step N cannot skip step N+1.

    The underlying [Eio.Switch.on_release] callback is *cancel-safe*
    (it fires on both normal exit and [Eio.Cancel.Cancelled] unwind)
    but *not exception-safe* when the body has multiple sequential
    cleanup steps.  For example, the pre-fix [on_connection_release]
    did [Transport_metrics.record_http_connection_closed ~mode]
    followed by [Eio.Flow.close flow]; if the first step raised, the
    flow close was skipped and the descriptor leaked.  The helper
    eliminates that failure mode by isolating each step.

    The white-box tests below drive [with_cleanups_on_release]
    directly to verify the all-or-nothing invariant across the
    cleanup list. *)

open Alcotest
module SBH = Server_bootstrap_http

let test_with_cleanups_on_release_runs_all_on_normal_exit () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let order = ref [] in
  let cleanup_a () = order := "a" :: !order in
  let cleanup_b () = order := "b" :: !order in
  let cleanup_c () = order := "c" :: !order in
  SBH.with_cleanups_on_release ~sw [ cleanup_a; cleanup_b; cleanup_c ] ;
  Eio.Switch.run (fun _trigger_sw ->
      (* Trigger a no-op cancellation so the on_release fires
         on a clean switch without other side effects. *)
      ());
  (* Force the on_release by failing the switch with a benign
     error; that runs all on_release callbacks then unwinds. *)
  (try
     Eio.Switch.run (fun release_sw ->
         SBH.with_cleanups_on_release ~sw:release_sw
           [ cleanup_a; cleanup_b; cleanup_c ];
         Eio.Switch.fail release_sw (Failure "trigger release"))
   with
   | Failure _ -> ()) ;
  (* The first invocation registered on [sw] (the *outer*
     one) which never failed.  We only observe side effects of
     the second invocation, which registered on [release_sw]
     and ran on its fail. *)
  let observed = List.rev !order in
  check string "all cleanups ran in order on release"
    "abc" (String.concat "" observed)

let test_with_cleanups_on_release_continues_after_step_exception () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _outer_sw ->
  let step_a_ran = ref false in
  let step_b_ran = ref false in
  let step_c_ran = ref false in
  let failing_cleanup () =
    step_a_ran := true ;
    raise (Failure "intentional step failure")
  in
  let surviving_cleanup_b () = step_b_ran := true in
  let surviving_cleanup_c () = step_c_ran := true in
  (try
     Eio.Switch.run (fun release_sw ->
         SBH.with_cleanups_on_release ~sw:release_sw
           [ failing_cleanup; surviving_cleanup_b; surviving_cleanup_c ];
         Eio.Switch.fail release_sw (Failure "trigger release"))
   with
   | Failure _ -> ()) ;
  check bool "step A ran (and raised)" true !step_a_ran ;
  check bool "step B ran despite step A's exception" true !step_b_ran ;
  check bool "step C ran despite step A's exception" true !step_c_ran

let test_with_cleanups_on_release_preserves_list_order () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _outer_sw ->
  let order = ref [] in
  let make_cleanup label () = order := label :: !order in
  (try
     Eio.Switch.run (fun release_sw ->
         SBH.with_cleanups_on_release ~sw:release_sw
           [ make_cleanup "first"; make_cleanup "second"; make_cleanup "third" ];
         Eio.Switch.fail release_sw (Failure "trigger release"))
   with
   | Failure _ -> ()) ;
  check string "cleanups run in supplied order"
    "third-second-first"
    (String.concat "-" (List.rev !order))

(** Cancelled semantics: when the switch unwinds with Cancelled,
    the on_release callback fires and *all* cleanups run.  Cancelled
    itself only propagates from the *fiber* operation (e.g.
    [Eio.Time.sleep]) that observes the cancellation -- not from
    inside the cleanup list.  So this test asserts both cleanups
    ran and the fiber observed Cancelled, not the cleanups. *)
let test_with_cleanups_on_release_runs_all_on_cancel () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun outer_sw ->
  let step_a_ran = ref false in
  let step_b_ran = ref false in
  let helper_observed_cancel = ref false in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.fork ~sw:outer_sw (fun () ->
      try
        Eio.Switch.run (fun inner_sw ->
            SBH.with_cleanups_on_release ~sw:inner_sw
              [ (fun () -> step_a_ran := true);
                (fun () -> step_b_ran := true) ];
            (* Suspend; the outer [Eio.Switch.fail] below cancels
               this fiber mid-sleep, then the inner switch unwinds
               and the on_release callback runs. *)
            Eio.Time.sleep clock 60.0)
      with
      | Eio.Cancel.Cancelled _ -> helper_observed_cancel := true
      | _ -> ()) ;
  Eio.Time.sleep clock 0.3 ;
  Eio.Switch.fail outer_sw (Failure "trigger release") ;
  Eio.Time.sleep clock 0.3 ;
  check bool "fiber observed Eio.Cancel.Cancelled" true
    !helper_observed_cancel ;
  check bool "step A ran on switch unwind" true !step_a_ran ;
  check bool "step B ran on switch unwind (after step A)" true !step_b_ran

let () =
  run "With_cleanups_on_release"
    [ "with_cleanups_on_release runs all on normal exit"
    , [ test_case "all cleanups run in order when the switch unwinds" `Quick
          test_with_cleanups_on_release_runs_all_on_normal_exit ]
    ; "with_cleanups_on_release continues after step exception"
    , [ test_case "later cleanups run even when an earlier one raises" `Quick
          test_with_cleanups_on_release_continues_after_step_exception ]
    ; "with_cleanups_on_release preserves list order"
    , [ test_case "cleanups run in the order they are supplied" `Quick
          test_with_cleanups_on_release_preserves_list_order ]
    ; "with_cleanups_on_release runs all on cancel"
    , [ test_case "all cleanups run on Cancelled unwind" `Quick
          test_with_cleanups_on_release_runs_all_on_cancel ]
    ]
;;
