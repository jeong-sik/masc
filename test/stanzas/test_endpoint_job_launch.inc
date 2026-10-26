(test
 (name test_endpoint_job_launch)
 (modules test_endpoint_job_launch)
 (libraries endpoint_job_launch endpoint_job_output endpoint_job_supervisor endpoint_job_result endpoint_job_registry endpoint_job_protocol endpoint_process_gate exec_ssh_protocol fs_compat masc_process alcotest masc.agent_core.digest eio eio.unix eio_main unix yojson))
