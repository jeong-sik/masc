(test
 (name test_keeper_identity_declarations)
 (modules test_keeper_identity_declarations)
 ;; masc for Keeper_secret_projection: a declaration names where tokens go
 ;; and the projection decides what it accepts, and nothing but a test makes
 ;; those two agree.
 (libraries alcotest unix masc masc.keeper_identity masc.embedded_config))
