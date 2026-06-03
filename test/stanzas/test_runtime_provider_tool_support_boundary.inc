; PR-R runtime boundary prep: Provider_tool_support is runtime-owned.
; Pure source-layout inspection; no project libs.

(test
 (name test_runtime_provider_tool_support_boundary)
 (modules test_runtime_provider_tool_support_boundary)
 (deps
  ../lib/runtime/provider_tool_support.ml
  ../lib/runtime/provider_tool_support.mli))
