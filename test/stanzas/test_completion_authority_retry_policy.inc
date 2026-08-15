; A Deferred review outcome that is known not to be retryable (e.g. a review
; whose seed message alone exceeds the target's whole request budget) must
; not keep arming the maintenance-pulse retry timer forever (masc, task-336).

(test
 (name test_completion_authority_retry_policy)
 (modules test_completion_authority_retry_policy)
 (libraries masc_test_deps))
