(test
 (name test_h2_request_fibers)
 (modules test_h2_request_fibers)
 (libraries masc alcotest httpun h2 h2-eio bigstringaf yojson eio eio_main eio.unix mtime masc.masc_core masc.server masc.config masc_log masc.string_util))
