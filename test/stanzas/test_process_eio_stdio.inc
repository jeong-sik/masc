(test
 (name test_process_eio_stdio)
 (modules test_process_eio_stdio)
 (enabled_if (= %{system} linux))
 (libraries masc_process fs_compat eio eio_main alcotest cstruct unix))
