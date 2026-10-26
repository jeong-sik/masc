(test
 (name test_endpoint_job_registry)
 (modules test_endpoint_job_registry)
 (libraries endpoint_job_registry endpoint_job_protocol exec_ssh_protocol masc_process fs_compat fs_compat_test_support alcotest masc.agent_core.digest eio eio_main unix yojson))
