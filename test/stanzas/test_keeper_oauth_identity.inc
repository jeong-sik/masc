(test
 (name test_keeper_oauth_identity)
 (modules test_keeper_oauth_identity)
 ;; masc for Keeper_secret_projection: the declaration names where tokens go
 ;; and the projection decides what it accepts, and nothing but a test makes
 ;; those two agree.
 (libraries alcotest str unix uri yojson masc masc.keeper_identity masc.auth
   masc.embedded_config masc.http_client))
