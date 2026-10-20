(test
 (name test_browser_addon_owner)
 (modules test_browser_addon_owner)
 (libraries masc masc.browser_lane masc.time_compat alcotest eio eio_main yojson uuidm))

(test
 (name test_browser_addon_wire)
 (modules test_browser_addon_wire)
 (libraries masc masc.browser_lane alcotest yojson))

(test
 (name test_browser_addon_service)
 (modules test_browser_addon_service)
 (libraries masc masc.time_compat alcotest eio eio_main yojson unix))
