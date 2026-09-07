; MSX frame route (RFC-0439 §3.7) — the serializer over a real loaded machine.
(test
 (name test_msx_frame_route)
 (modules test_msx_frame_route)
 (libraries alcotest yojson base64 masc.msx_lane masc.server))
