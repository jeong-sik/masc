(test
 (name test_runtime_model_label_binding)
 (modules test_runtime_model_label_binding)
 (libraries masc_test_deps alcotest yojson unix masc.agent_core masc.agent_core.llm_provider masc.discovery_cache masc.time_compat eio eio_main eio.mock cohttp cohttp-eio uri))
