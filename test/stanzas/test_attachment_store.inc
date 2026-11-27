(test
 (name test_attachment_store)
 (modules test_attachment_store)
 (libraries alcotest eio_main masc.attachment_store masc_compression masc_core masc_process yojson unix))
