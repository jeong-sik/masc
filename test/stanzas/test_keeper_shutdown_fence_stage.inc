; A [Blocked] shutdown held the admission fence for every failure stage, so a
; Keeper that failed before the shutdown mutated anything durable was
; permanently unbootable (#31738). The fence now follows the stage.

(test
 (name test_keeper_shutdown_fence_stage)
 (modules test_keeper_shutdown_fence_stage)
 (libraries masc_test_deps))
