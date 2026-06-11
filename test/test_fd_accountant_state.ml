(** White-box tests for the per-kind fd_holding state machine
    introduced by PR-C1 (follow-up to PR-B / PR #20583).

    PR-B replaced the [int Atomic.t] counter and its
    [Eio.Switch.on_release] decrement callback with a typed
    variant.  PR-C1 spreads the same pattern to [fd_accountant]
    because it shared the same risk class (over-decrement under
    parent-fibre cancellation, hidden by a [max 0 (... - 1)]
    clamp).

    These tests drive the [mark_acquire] / [mark_release] /
    [read_holding] entry points directly, independent of
    [with_slot] and [acquire_lifetime_slot], to verify:

    1. Idle state projects to 0 in the 0/1 projection.
    2. After [mark_acquire] returns, the projection is 1.
    3. A second [mark_acquire] before release advances
       [hold_id] (the typed state machine replaces the slot,
       no panic, no stuck-positive).
    4. After [mark_release], the projection returns to 0.
    5. A stray [mark_release] on Idle is a no-op (still 0)
       -- the user-site exception path that re-raises after
       partial teardown cannot desync the state machine.
    6. The kind-level API is independent across kinds: a
       Sandbox_exec slot does not move a Docker_spawn slot.

    The black-box behaviour ([with_slot] / [acquire_lifetime_slot]
    round-trips, exception release, cap fan-in) is already
    covered by [test_fd_accountant.ml].  This file pins down
    only the typed-state invariant. *)

open Alcotest
module FA = Fd_accountant

let test_idle_projects_to_zero () =
  (* Eio.Mutex.use_rw ~protect:true installs a Cancel.protect that
     performs [Cancel.Get_context].  Eio.Switch.run is the only
     handler for that effect, so even Idle reads must run inside a
     switch.  Eio_main.run is needed to provide the underlying
     event-loop fiber; the inner Eio.Switch.run gives Cancel.protect
     a cancellation context to read.  This mirrors PR-B's
     dashboard_governance_judge tests, which use the same wrap
     pattern. *)
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  List.iter
    (fun kind ->
      let h = FA.read_holding ~kind in
      check int "idle projects to 0" 0 h)
    FA.all_kinds

let test_mark_acquire_then_release () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  List.iter
    (fun kind ->
      let () =
        check int "idle baseline 0" 0 (FA.read_holding ~kind)
      in
      let _hold_id = FA.mark_acquire ~kind in
      check int "after mark_acquire" 1 (FA.read_holding ~kind) ;
      FA.mark_release ~kind ~hold_id:0 ;
      check int "after mark_release" 0 (FA.read_holding ~kind))
    FA.all_kinds

let test_second_mark_acquire_advances_hold_id () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  (* PR-B / dashboard_governance_judge surfaced [hold_id] as a
     monotonic cycle identifier.  The same pattern applies here:
     the second [mark_acquire] returns a strictly larger
     [hold_id] than the first.  Under the legacy [int] counter
     this property was implicit (every acquire bumped the
     counter); under the typed-state machine it is the only
     way to distinguish a fresh acquire from a re-entrant one. *)
  let kind = FA.Sandbox_exec in
  let first = FA.mark_acquire ~kind in
  let second = FA.mark_acquire ~kind in
  check bool "second mark_acquire advances hold_id" true (second > first) ;
  check int "in_flight remains 1 across second mark_acquire" 1
    (FA.read_holding ~kind) ;
  (* Typed invariant: a "stuck positive" cannot occur because
     the second [mark_acquire] replaces the [In_flight _]
     branch with a new [In_flight { hold_id = second }].  The
     [hold_id] advancing is the visible witness. *)
  FA.mark_release ~kind ~hold_id:second ;
  check int "after mark_release of the new cycle" 0
    (FA.read_holding ~kind)

let test_stray_mark_release_is_noop () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let kind = FA.Provider_http in
  let () = check int "idle baseline 0" 0 (FA.read_holding ~kind) in
  (* Stray release on Idle: a user-site exception path that
     re-raises after partial teardown cannot desync the state
     machine.  PR-B documents the same guarantee for
     mark_compute_finish. *)
  FA.mark_release ~kind ~hold_id:999 ;
  check int "stray mark_release is a no-op" 0 (FA.read_holding ~kind)

let test_kinds_are_independent () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  let a = FA.Docker_spawn in
  let b = FA.Sandbox_exec in
  let _ = FA.mark_acquire ~kind:a in
  check int "a held" 1 (FA.read_holding ~kind:a) ;
  check int "b idle (cross-kind independence)" 0 (FA.read_holding ~kind:b) ;
  FA.mark_release ~kind:a ~hold_id:0 ;
  check int "a released" 0 (FA.read_holding ~kind:a) ;
  check int "b still idle" 0 (FA.read_holding ~kind:b)

let test_idle_after_release_under_concurrent_reader () =
  Eio_main.run @@ fun _env ->
  Eio.Switch.run @@ fun _sw ->
  (* Regression: a previous [Eio.Switch.on_release] callback
     could over-decrement and the [max 0 (... - 1)] clamp would
     mask the leak (the projection was 0 even when the
     underlying counter was -2).  PR-C1 removes both: the
     state machine cannot underflow because [mark_release]
     can only transition [In_flight _] -> [Idle]. *)
  let kind = FA.Log_writer in
  let _hold_id = FA.mark_acquire ~kind in
  let _hold_id' = FA.mark_acquire ~kind in
  check int "two acquires still project to 1 (single slot)" 1
    (FA.read_holding ~kind) ;
  FA.mark_release ~kind ~hold_id:0 ;
  check int "one release returns to 0" 0 (FA.read_holding ~kind) ;
  (* A second release on Idle is idempotent and does not
     underflow.  This is the regression assertion the legacy
     [int] counter with [max 0] clamp could not express. *)
  FA.mark_release ~kind ~hold_id:0 ;
  check int "second release on Idle stays 0" 0 (FA.read_holding ~kind)

let () =
  run "Fd_accountant_state"
    [ "idle projection"
    , [ test_case "Idle projects to 0" `Quick test_idle_projects_to_zero ]
    ; "mark_acquire/release round-trip"
    , [ test_case "all kinds round-trip" `Quick test_mark_acquire_then_release ]
    ; "hold_id monotonicity"
    , [ test_case "second mark_acquire advances hold_id" `Quick
          test_second_mark_acquire_advances_hold_id ]
    ; "stray release idempotent"
    , [ test_case "stray mark_release is a no-op" `Quick
          test_stray_mark_release_is_noop ]
    ; "cross-kind independence"
    , [ test_case "kinds are independent" `Quick
          test_kinds_are_independent ]
    ; "no underflow"
    , [ test_case "no underflow under double acquire/release" `Quick
          test_idle_after_release_under_concurrent_reader ]
    ]
;;
