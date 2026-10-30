; Boot recovery settles durable shutdown operations whose keeper was removed
; outright: with the owner gone and the metadata gone with it there is no
; admission fence left to release (2026-08-12 [full-cycle-probe] zombies).

(test
 (name test_keeper_shutdown_ownerless_admission_release)
 (modules test_keeper_shutdown_ownerless_admission_release)
 (libraries masc_test_deps))
