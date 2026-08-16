(** Retry-scheduling decision for a completed completion-authority review.

    [process_task] used to schedule the maintenance-pulse retry for every
    [Deferred] outcome unconditionally, including a review whose seed message
    alone already exceeds the target's whole request budget — a failure that
    cannot change on a retry of the same request, so the retry kept firing
    every [maintenance_pulse_interval_sec] forever (masc, task-336
    diagnosis 2026-08-15/16: 20 identical failures in 20 minutes on a 294,670
    byte single-atom review against a 262,144 byte lane).

    [Task.Anti_rationalization.review_result.retryable] already carries
    [Agent_core.Error.is_retryable] for that case; these pin that
    [should_schedule_retry] — the pure decision [process_task] calls — reads
    it correctly, on both sides. *)

module CA = Masc.Completion_authority_agent

let test_committed_never_retries () =
  Alcotest.(check bool)
    "committed"
    false
    (CA.For_testing.should_schedule_retry CA.For_testing.Committed)
;;

let test_retryable_defer_retries () =
  Alcotest.(check bool)
    "retryable defer"
    true
    (CA.For_testing.should_schedule_retry
       (CA.For_testing.Deferred { retryable = true }))
;;

let test_non_retryable_defer_does_not_retry () =
  Alcotest.(check bool)
    "non-retryable defer"
    false
    (CA.For_testing.should_schedule_retry
       (CA.For_testing.Deferred { retryable = false }))
;;

let () =
  Alcotest.run
    "completion_authority_retry_policy"
    [ ( "should_schedule_retry"
      , [ Alcotest.test_case "Committed never retries" `Quick test_committed_never_retries
        ; Alcotest.test_case
            "Deferred { retryable = true } retries"
            `Quick
            test_retryable_defer_retries
        ; Alcotest.test_case
            "Deferred { retryable = false } does not retry"
            `Quick
            test_non_retryable_defer_does_not_retry
        ] )
    ]
;;
