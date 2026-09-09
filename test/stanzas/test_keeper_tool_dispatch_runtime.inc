(test
 (name test_keeper_tool_dispatch_runtime)
 (modules test_keeper_tool_dispatch_runtime)
 (deps fixtures/browser-webdriver-script.cjs)
 (libraries
  masc_test_deps
  masc.keeper_chat_operations
  masc.keeper_execution_scope
  masc.keeper_registry
  masc.browser_lane
  masc.msx_lane
  fs_compat_test_support
  masc.skill_config
  masc.skill_reference
  masc.skill_snapshot))
