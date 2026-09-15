(test
 (name test_keeper_tool_dispatch_runtime)
 (modules test_keeper_tool_dispatch_runtime)
 (deps
  fixtures/browser-webdriver-script.cjs
  ../skills/browser-live-follow-read/SKILL.md
  ../skills/browser-navigate-read/SKILL.md)
 (libraries
  masc_test_deps
  masc.keeper_chat_operations
  masc.keeper_execution_scope
  masc.keeper_registry
  masc.keeper_runtime
  masc.browser_lane
  masc.msx_lane
  fs_compat_test_support
  masc.skill_config
  masc.skill_reference
  masc.skill_snapshot))
