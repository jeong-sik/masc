(test
 (name test_h2_json_worker)
 (modules test_h2_json_worker)
 (libraries alcotest h2 bigstringaf yojson decompress.gz decompress.de eio eio_main masc.masc_core masc.server))
