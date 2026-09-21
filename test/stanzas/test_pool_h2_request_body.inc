(test
 (name test_pool_h2_request_body)
 (modules test_pool_h2_request_body)
 (libraries alcotest eio eio_main cstruct bigstringaf h2 httpun-types gluten-eio piaf uri masc.http_client))
