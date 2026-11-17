(test
 (name test_keeper_sandbox_remote_stdio)
 (modules test_keeper_sandbox_remote_stdio)
 (enabled_if (= %{system} linux))
 (libraries masc_test_deps exec_ssh_protocol masc.agent_core.protocol)
 (deps ../bin/masc_exec_shim.exe)
 (action (run %{test} %{dep:../bin/masc_exec_shim.exe})))
