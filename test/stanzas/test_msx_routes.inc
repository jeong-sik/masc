; MSX HTTP control routes (RFC-0439 §3.7, RFC #38695).
(test
 (name test_msx_routes)
 (modules test_msx_routes)
 (libraries masc_test_deps alcotest yojson base64 bigstringaf unix eio eio_main masc.masc_core masc.msx_lane masc.server))
