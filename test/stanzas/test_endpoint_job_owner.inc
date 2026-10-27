(test
 (name test_endpoint_job_owner)
 (modules test_endpoint_job_owner)
 (libraries endpoint_job_owner endpoint_job_launch endpoint_job_lifetime endpoint_job_registry endpoint_job_result endpoint_job_protocol endpoint_process_gate exec_ssh_protocol fs_compat fs_compat_test_support alcotest digestif eio eio.unix eio_main unix))
