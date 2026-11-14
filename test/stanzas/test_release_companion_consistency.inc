; task-3500, #45119: every hand-maintained list of release executables (packager
; NAMES, Linux and macOS build targets, release job packaging and assets,
; installer, install smoke, bundle helper, publication gate, receipt parser,
; packager probe runs) must agree, and must hold every program the browser
; Add-on runs (Native_addon_program names, carried browser package commands).
; The deps are the watched sources, so any PR touching one of them re-runs this
; suite in the pull-request gate.
(rule
 (alias runtest-test_release_companion_consistency)
 (deps
  test_release_companion_consistency.py
  ../scripts/package-macos-runtime.py
  ../scripts/install-smoke.sh
  ../scripts/ci/prepare-release-publication.py
  ../lib/installed_dashboard.ml
  ../scripts/build-linux-release.sh
  ../.github/workflows/release-build.yml
  ../scripts/install.sh
  ../scripts/release-dashboard-bundle.py
  ../.github/workflows/lane-addon-native.yml
  ../.github/workflows/linux-x64-probe.yml
  ../lib/lane_addon/native_addon_program.ml
  (source_tree ../addons/browser))
 (action
  (run python3 -B %{dep:test_release_companion_consistency.py}
   --packager %{dep:../scripts/package-macos-runtime.py}
   --smoke %{dep:../scripts/install-smoke.sh}
   --gate %{dep:../scripts/ci/prepare-release-publication.py}
   --parser %{dep:../lib/installed_dashboard.ml}
   --linux-build %{dep:../scripts/build-linux-release.sh}
   --release-workflow %{dep:../.github/workflows/release-build.yml}
   --installer %{dep:../scripts/install.sh}
   --bundle %{dep:../scripts/release-dashboard-bundle.py}
   --lane-addon-probe %{dep:../.github/workflows/lane-addon-native.yml}
   --runtime-probe %{dep:../.github/workflows/linux-x64-probe.yml}
   --native-programs %{dep:../lib/lane_addon/native_addon_program.ml}
   --browser-packages ../addons/browser)))

(alias
 (name runtest)
 (deps (alias runtest-test_release_companion_consistency)))
