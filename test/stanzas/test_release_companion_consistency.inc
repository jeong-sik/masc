; task-3500: the four hand-maintained companion lists (packager NAMES, install
; smoke executables + ASSETS, publication gate expected set, receipt parser
; allowlist) must agree.  The deps are the watched sources, so any PR touching
; one of them re-runs this suite in the pull-request gate.
(rule
 (alias runtest-test_release_companion_consistency)
 (deps
  test_release_companion_consistency.py
  ../scripts/package-macos-runtime.py
  ../scripts/install-smoke.sh
  ../scripts/ci/prepare-release-publication.py
  ../lib/installed_dashboard.ml)
 (action
  (run python3 -B %{dep:test_release_companion_consistency.py}
   --packager %{dep:../scripts/package-macos-runtime.py}
   --smoke %{dep:../scripts/install-smoke.sh}
   --gate %{dep:../scripts/ci/prepare-release-publication.py}
   --parser %{dep:../lib/installed_dashboard.ml})))

(alias
 (name runtest)
 (deps (alias runtest-test_release_companion_consistency)))
