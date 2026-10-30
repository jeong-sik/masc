(test
 (name test_keeper_memory_successor_http_replay)
 (modules test_keeper_memory_successor_http_replay)
 (deps (glob_files fixtures/memory_successor_http_replay/*.json))
 (libraries masc_test_deps exact_output_fixture masc masc.runtime masc.masc_eio_context agent_core eio_main))
