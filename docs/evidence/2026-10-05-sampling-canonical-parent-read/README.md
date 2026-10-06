# Canonical parent reads and relative store roots

Against exact baseline `d3e765062a3f2621b3f4a5f0f2dddb61ac1c26be`, six new cases fail: public and recovery-journal reads accept a replaced canonical parent when its external leaf is absent or a directory, and relative-root blob/sequence cold reads reject their ownership root. Final RED fixtures run from an isolated system temporary directory; none disables the home-directory test guard.

The fix captures relative roots against the creation working directory and shares canonical-parent validation across publication, public reads and journal recovery. An owned directory obstruction remains a valid fallback condition. Intermediate symlinks are rejected without resolving them into an authorized root.

Focused build: `opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build test/test_lane_addon_worker.exe`. Baseline cases use `test lifecycle 0` through `5`; the fixed executable runs its complete 41-case suite from `_build/default/test`. Both use an explicit source root and blank provider keys/base-path plus disabled sandbox preflight/Docker playground. Final build succeeded and all 41 tests passed in 7.191 seconds.

An earlier fixture placed relative data below the checkout and hit the home-directory isolation guard in two cases. It was corrected to a system temporary directory before the final six-case RED and 41-case GREEN; that fixture failure is not a product regression. These results do not establish hosted CI, upstack consumer qualification, or release readiness. Terminal-Bench was not run.
