(test
 (name test_browser_keeper_firefox)
 (modules test_browser_keeper_firefox)
 (libraries alcotest eio eio_main digestif otoml unix yojson masc masc.server masc.browser_configuration
  masc.browser_lane masc.masc_process masc.string_util))
