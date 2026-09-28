(test
 (name test_browser_stagehand_model)
 (modules test_browser_stagehand_model)
 (deps fixtures/stagehand/llm-generate-params.json)
 (libraries masc masc_test_deps exact_output_fixture alcotest yojson eio eio_main))
