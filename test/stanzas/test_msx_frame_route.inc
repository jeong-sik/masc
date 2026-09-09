; MSX frame route (RFC-0439 §3.7) — the serializer over a real loaded machine.
(test
 (name test_msx_frame_route)
 (modules test_msx_frame_route)
 (libraries masc_test_deps alcotest yojson base64 unix eio eio_main masc.masc_core masc.msx_lane masc.server))
