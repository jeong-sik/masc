; MASC_EXEC_ALLOW_LOCAL_PLAYGROUND: the fixtures run the typed dispatch on a
; keeper meta whose sandbox_profile resolves to Local (incidental — the suite
; measures dispatch runtime/tool-surface behavior, not sandbox isolation),
; and dispatch now rejects Local fail-closed without the hatch.
(test
 (name test_keeper_tool_dispatch_runtime)
 (modules test_keeper_tool_dispatch_runtime)
 (action
  (setenv
   MASC_EXEC_ALLOW_LOCAL_PLAYGROUND
   true
   (run %{test})))
 (libraries
  masc_test_deps
  fs_compat_test_support
  masc.skill_config
  masc.skill_reference
  masc.skill_snapshot))
