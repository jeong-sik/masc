(test
 (name test_keeper_media_reading_reply)
 (modules test_keeper_media_reading_reply)
 (enabled_if (= %{system} linux))
 (libraries masc_test_deps exec_ssh_protocol masc.agent_core.protocol)
 (deps ../bin/masc_exec_shim.exe)
 (action (run %{test} %{dep:../bin/masc_exec_shim.exe})))
