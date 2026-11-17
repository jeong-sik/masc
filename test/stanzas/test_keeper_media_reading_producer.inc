(test
 (name test_keeper_media_reading_producer)
 (modules test_keeper_media_reading_producer)
 (enabled_if (= %{system} linux))
 (libraries masc_test_deps exec_ssh_protocol)
 (deps ../bin/masc_exec_shim.exe)
 (action (run %{test} %{dep:../bin/masc_exec_shim.exe})))
