# Native Stack 40952 integration

The seven published heads were merged bottom-up onto main `87123f7df94a27ded447b5b05d01c2f5178de029`. Historical replay was aborted after replay conflicts; each recorded merge preserves its published first parent and current downstack second parent. Original production/test changes remain, with one composed Work render/test conflict: current backlog retains priority while baseline/current timestamps and baseline delta remain visible when space permits. Documentation conflicts preserve existing evidence limits and both audit entries.

At combined leaf `720c74791ca0f562db56be11df1901611e6f1c9b`, the focused TUI and three test executables built. Actual native tests passed: planning 7, decode 353, provider overview 19 (379 total). Actual studio PTY passed all five scenarios: summary priority in color and NO_COLOR, surface studio in color and NO_COLOR, and advancing-current/preserved-baseline refresh. Ruff and Pyright passed the changed PTY file.

The initial provider run inherited NO_COLOR=1 from the host and failed its explicit nonempty-color assertion. The raw failure is retained; removing NO_COLOR for the color-dependent suite passed all 19 tests without source changes. The PTY harness separately exercises both color settings. This is an execution-environment correction, not a product RED/GREEN claim.

Root and independent source review checked preservation of all seven original changes and the intentional composition. Execution proves the named combined-leaf paths, not every individual PR head, every feature, live provider behavior, full CI or release readiness. Terminal-Bench was not run. Checks pin the tested source, binary and unmodified raw logs; this evidence-only commit does not alter the tested code.
