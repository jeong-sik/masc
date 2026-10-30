(test
 (name test_keeper_tool_dispatch_runtime)
 (modules test_keeper_tool_dispatch_runtime)
 (deps
  ../bin/masc_native_addon_launcher.exe
  fixtures/browser-webdriver-script.cjs
  ../skills/browser-live-follow-read/SKILL.md
  ../skills/browser-navigate-read/SKILL.md)
 (libraries
  browser_addon_fixture
  mtime
  mtime.clock.os
  machine_worker_fixture
  masc.machine_configuration
  masc_test_deps
  masc.keeper_chat_operations
  masc.keeper_execution_scope
  masc.keeper_registry
  masc.keeper_runtime
  masc.gate
  masc.browser_lane
  masc.msx_lane
  fs_compat_test_support
  masc.skill_config
  masc.skill_reference
  masc.skill_snapshot))

(rule
 (alias runtest-test_keeper_result_scope_dispatch)
 (action (run %{exe:test_keeper_tool_dispatch_runtime.exe} test "peer_delegate_schema")))
