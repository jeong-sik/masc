(test
 (name test_fusion_judge_response_evidence_walk)
 (modules test_fusion_judge_response_evidence_walk)
 (deps (source_tree %{workspace_root}/config/prompts))
 (libraries masc_test_deps masc masc.fusion_core masc.fs_compat masc.string_util
   masc.masc_eio_context))
