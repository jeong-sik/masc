(test
 (name test_runtime_toml_namespace)
 (modules test_runtime_toml_namespace)
 (libraries alcotest masc.runtime masc.runtime_toml_namespace masc.keeper_runtime masc.config
  masc.fs_compat masc.string_util masc.agent_core.llm_provider))
