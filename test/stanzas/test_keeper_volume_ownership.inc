; Workspace-scoped ownership markers for Apple Keeper volumes: the byte-level
; interpreter only. No volume, image, or CLI is touched, so this suite runs
; anywhere; the runtime-side probe layers on top of this contract later.
(test
 (name test_keeper_volume_ownership)
 (modules test_keeper_volume_ownership)
 (libraries alcotest masc yojson))
