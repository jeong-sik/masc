; Whether a microVM guest is there when inspect did not answer: the listing
; that tells a missing guest from a runtime that could not look, and the
; callers that must not act on "could not look" as absence (#44676).
(test
 (name test_keeper_microvm_guest_probe)
 (modules test_keeper_microvm_guest_probe)
 (libraries masc_test_deps))
