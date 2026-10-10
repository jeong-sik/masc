# Build-link refusal preserves its actual cause

PR #42118.

When a scanned checkout path contained an ambiguous separator or an empty segment, build_link_target rejected it. build_link_rows_of_scan then replaced the reason with Link_refused_real_directory. The runtime consequently warned that real build output existed and would be removed at the next boot, even for an absent build directory.

Link_refused_invalid_path now carries the original error. The direct runtime consumer reports that path error instead of the real-directory explanation. Real-directory refusals and link creation/retargeting retain their existing behavior. Both refused states generate no link action or target directory. This is a specific logic repair; it does not finish the microVM Godfile audit.

Focused build `opam exec -- dune build test/test_keeper_sandbox_microvm.exe` completed exit 0. Selected execution `_build/default/test/test_keeper_sandbox_microvm.exe test 'build volume' 5-14 --color=never` completed exit 0: ten PASS, run QVI04BDC. It covers pure planning, flat target paths, ambiguous-path rejection, scan argv and parsing, retained invalid-path reasons, an invalid path over a real directory and real-directory diagnostics. Other groups were skipped. The new cases verify the original error, the absence of guest actions/targets, and that an invalid path over a real `_build` keeps the scanned state so the next-boot removal is still reported. No VM or live Keeper was started; runtime log emission is source-reviewed, not observed live.

The selected output is retained here. Full CI, installation, deployment, formal GitHub approval and merge are unverified. Backend execution, lifecycle and the remaining image/volume/inventory policies still require semantic audit. The original 171-candidate campaign remains open.
