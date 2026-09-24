; GET /api/v1/lane-addons/live (RFC machine-spectating-goes-through-lanes
; §2.1, stage 1): the MSX change counter and the read route, over a ROM-less
; machine and the real lane-addon router.
(test
 (name test_lane_addon_live_route)
 (modules test_lane_addon_live_route)
 (libraries masc_test_deps alcotest yojson base64 bigstringaf unix eio eio_main masc.masc_core masc.msx_lane masc.server))
