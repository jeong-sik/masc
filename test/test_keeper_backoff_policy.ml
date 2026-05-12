(** RFC-0070 Phase 3c.1 — tests for [Keeper_backoff_policy].

    Pins the policy semantics: max_attempts is the *total* call budget
    (including first), should_retry is strict (no catch-all default),
    default_for_sandbox enumerates exactly the transient variants. *)

open Alcotest
open Masc_mcp

let test_default_for_sandbox_max_attempts () =
  check
    int
    "default max_attempts = 3"
    3
    (Keeper_backoff_policy.max_attempts Keeper_backoff_policy.default_for_sandbox)
;;

let test_default_retries_daemon_unreachable () =
  check
    bool
    "Daemon_unreachable retryable"
    true
    (Keeper_backoff_policy.should_retry
       Keeper_backoff_policy.default_for_sandbox
       Docker_client.Daemon_unreachable)
;;

let test_default_retries_image_pull_failed () =
  check
    bool
    "Image_pull_failed retryable"
    true
    (Keeper_backoff_policy.should_retry
       Keeper_backoff_policy.default_for_sandbox
       Docker_client.Image_pull_failed)
;;

let test_default_does_not_retry_oom () =
  check
    bool
    "Container_oom non-retryable"
    false
    (Keeper_backoff_policy.should_retry
       Keeper_backoff_policy.default_for_sandbox
       Docker_client.Container_oom)
;;

let test_default_does_not_retry_exec_timeout () =
  check
    bool
    "Exec_timeout non-retryable"
    false
    (Keeper_backoff_policy.should_retry
       Keeper_backoff_policy.default_for_sandbox
       Docker_client.Exec_timeout)
;;

let test_default_does_not_retry_format_drift () =
  check
    bool
    "Probe_format_drift non-retryable"
    false
    (Keeper_backoff_policy.should_retry
       Keeper_backoff_policy.default_for_sandbox
       Docker_client.Probe_format_drift)
;;

let test_default_does_not_retry_cleanup_failed () =
  check
    bool
    "Cleanup_failed non-retryable"
    false
    (Keeper_backoff_policy.should_retry
       Keeper_backoff_policy.default_for_sandbox
       Docker_client.Cleanup_failed)
;;

let test_custom_policy () =
  let p =
    Keeper_backoff_policy.make
      ~max_attempts:5
      ~retryable_errors:[ Docker_client.Container_oom ]
  in
  check int "custom max_attempts" 5 (Keeper_backoff_policy.max_attempts p);
  check
    bool
    "custom retryable: oom"
    true
    (Keeper_backoff_policy.should_retry p Docker_client.Container_oom);
  check
    bool
    "non-listed: daemon_unreachable"
    false
    (Keeper_backoff_policy.should_retry p Docker_client.Daemon_unreachable)
;;

let test_disable_retry () =
  let p = Keeper_backoff_policy.make ~max_attempts:1 ~retryable_errors:[] in
  check int "max_attempts = 1 (no retry)" 1 (Keeper_backoff_policy.max_attempts p);
  check
    bool
    "empty retryable list rejects every variant"
    false
    (Keeper_backoff_policy.should_retry p Docker_client.Daemon_unreachable)
;;

(* ── Precondition enforcement (Copilot review T20/T21) ──────── *)

let test_make_rejects_zero_attempts () =
  check_raises
    "max_attempts=0 raises Invalid_argument"
    (Invalid_argument "Keeper_backoff_policy.make: max_attempts must be >= 1 (got 0)")
    (fun () ->
       let _ : Keeper_backoff_policy.t =
         Keeper_backoff_policy.make ~max_attempts:0 ~retryable_errors:[]
       in
       ())
;;

let test_make_rejects_negative_attempts () =
  check_raises
    "max_attempts=-3 raises Invalid_argument"
    (Invalid_argument "Keeper_backoff_policy.make: max_attempts must be >= 1 (got -3)")
    (fun () ->
       let _ : Keeper_backoff_policy.t =
         Keeper_backoff_policy.make ~max_attempts:(-3) ~retryable_errors:[]
       in
       ())
;;

let test_make_accepts_minimum_one () =
  let p = Keeper_backoff_policy.make ~max_attempts:1 ~retryable_errors:[] in
  check int "min boundary 1 accepted" 1 (Keeper_backoff_policy.max_attempts p)
;;

let () =
  run
    "Keeper_backoff_policy"
    [ ( "default policy"
      , [ test_case "max_attempts = 3" `Quick test_default_for_sandbox_max_attempts
        ; test_case
            "retries Daemon_unreachable"
            `Quick
            test_default_retries_daemon_unreachable
        ; test_case
            "retries Image_pull_failed"
            `Quick
            test_default_retries_image_pull_failed
        ; test_case "does not retry Container_oom" `Quick test_default_does_not_retry_oom
        ; test_case
            "does not retry Exec_timeout"
            `Quick
            test_default_does_not_retry_exec_timeout
        ; test_case
            "does not retry Probe_format_drift"
            `Quick
            test_default_does_not_retry_format_drift
        ; test_case
            "does not retry Cleanup_failed"
            `Quick
            test_default_does_not_retry_cleanup_failed
        ] )
    ; ( "custom policy"
      , [ test_case "custom max_attempts + retryable list" `Quick test_custom_policy
        ; test_case "max_attempts=1 + empty list disables retry" `Quick test_disable_retry
        ] )
    ; ( "precondition enforcement"
      , [ test_case "make rejects max_attempts=0" `Quick test_make_rejects_zero_attempts
        ; test_case
            "make rejects negative max_attempts"
            `Quick
            test_make_rejects_negative_attempts
        ; test_case "make accepts minimum 1" `Quick test_make_accepts_minimum_one
        ] )
    ]
;;
