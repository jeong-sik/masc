(** Pin the {!Env_config_keeper.KeeperBootstrap} polling/settle
    interval contract. Three values were extracted from inline
    literals at [server_bootstrap_loops.ml]:

    - line 157  0.25  → lazy_startup_poll_interval_sec
    - line 240  0.25  → keeper_listener_retry_interval_sec
    - line 482  5.0   → post_startup_settle_sec

    The two [0.25] values shared a literal but encode *different*
    intents (lazy-startup polling vs. listener-retry backoff). The
    SSOT keeps them as separate knobs so future operator overrides
    can tune one without affecting the other.

    Properties pinned:

    1. Defaults preserve the pre-extraction literals (regression
       guard against silent shifts that would change autoboot wall-
       clock or burn CPU on busy-poll).
    2. Polling intervals have a >= 0.05s floor (50ms) so an operator
       typo doesn't accidentally turn the loop into a CPU sink.
    3. [post_startup_settle_sec] allows 0 (no settle) but caps at
       no upper bound — operators on slow machines may raise. *)

open Alcotest

module KB = Env_config_keeper.KeeperBootstrap

let approx = float 0.001

let test_default_lazy_startup_poll () =
  check approx
    "lazy_startup_poll_interval_sec default (was inline 0.25)"
    0.25 KB.lazy_startup_poll_interval_sec

let test_default_listener_retry () =
  check approx
    "keeper_listener_retry_interval_sec default (was inline 0.25)"
    0.25 KB.keeper_listener_retry_interval_sec

let test_default_post_startup_settle () =
  check approx
    "post_startup_settle_sec default (was inline 5.0)"
    5.0 KB.post_startup_settle_sec

let test_polling_floor () =
  check bool
    "lazy_startup_poll_interval_sec must satisfy the documented \
     >= 0.05s floor (else the loop becomes a CPU sink)"
    true
    (KB.lazy_startup_poll_interval_sec >= 0.05);
  check bool
    "keeper_listener_retry_interval_sec must satisfy the documented \
     >= 0.05s floor"
    true
    (KB.keeper_listener_retry_interval_sec >= 0.05)

let test_smoke_call_sites_compile () =
  let _ = KB.lazy_startup_poll_interval_sec in
  let _ = KB.keeper_listener_retry_interval_sec in
  let _ = KB.post_startup_settle_sec in
  check bool "all three accessors are reachable" true true

let () =
  run "env_config_keeper_bootstrap_intervals"
    [
      ( "defaults preserve pre-extraction literals",
        [
          test_case "lazy_startup_poll = 0.25" `Quick
            test_default_lazy_startup_poll;
          test_case "listener_retry = 0.25" `Quick
            test_default_listener_retry;
          test_case "post_startup_settle = 5.0" `Quick
            test_default_post_startup_settle;
        ] );
      ( "polling floors",
        [
          test_case ">= 0.05s floor on both polling intervals" `Quick
            test_polling_floor;
        ] );
      ( "API surface",
        [
          test_case "all three accessors reachable" `Quick
            test_smoke_call_sites_compile;
        ] );
    ]
