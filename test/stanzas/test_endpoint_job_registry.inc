(test
 (name test_endpoint_job_registry)
 (modules test_endpoint_job_registry)
 (libraries endpoint_job_registry endpoint_job_protocol exec_ssh_protocol masc_process alcotest digestif eio eio_main unix))
