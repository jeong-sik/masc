(rule
 (alias runtest-test_operator_media_inspection)
 (deps ../bin/main_eio.exe test_operator_media_inspection.py
       ../scripts/ci/presentation_fixture.py
       fixtures/verifier-video.mp4
       ../docs/evidence/2026-09-10-collaboration-baseline/goal-publication/booklet.pdf)
 (action
  (run python3 %{dep:test_operator_media_inspection.py} --binary %{dep:../bin/main_eio.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_operator_media_inspection)))

(rule
 (alias runtest-test_presentation_fixture_contract)
 (deps test_presentation_fixture_contract.py ../scripts/ci/presentation_fixture.py)
 (action (run python3 %{dep:test_presentation_fixture_contract.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_presentation_fixture_contract)))
