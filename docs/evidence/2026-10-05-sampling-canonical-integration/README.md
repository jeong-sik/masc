# Canonical-parent fix in Native Stack 40961

Qualified local leaf `a7bb25fd5b4787d3c81f66c63b2542cbf14686f2` incorporates the six-case RED / 41-case GREEN parent repair and applies the same canonical ownership helper to the extracted cold-retention function at #41033. All seven direct-consumer executables compiled and passed: worker 42, server composition 17, retained receipts 11, runtime 22, provenance 15, bounded history 13, MCP integration 27 (147 total).

The first build command mistakenly named the MCP test under test/ and exited before qualification; the corrected target is packages/agent_core/test/test_mcp_integration.exe. Preserved logs correspond to the corrected successful build and actual executions. Each executable ran from its built directory with explicit DUNE_SOURCEROOT, blank base-path/provider-key overrides and disabled sandbox preflight/Docker playground, as in the prior integration evidence.

This does not resolve the separate pending-recovery performance review or UID-0 compaction-fixture finding. It is focused local evidence, not hosted CI or release approval. Terminal-Bench was not run.
