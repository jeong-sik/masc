; DOS frame route (#38424) — the spectator serializer over a real loaded
; machine. The test assembles its own COM program, so CI carries no game image.
(test
 (name test_dos_frame_route)
 (modules test_dos_frame_route)
 (libraries alcotest yojson base64 unix fs_compat masc.masc_core masc.dos_lane masc.server))
