(rule
 (alias runtest-test_operator_media_inspection)
 (deps ../bin/main_eio.exe test_operator_media_inspection.py
       fixtures/verifier-video.mp4
       ../docs/evidence/2026-09-10-collaboration-baseline/goal-publication/booklet.pdf)
 (action
  (run python3 %{dep:test_operator_media_inspection.py} --binary %{dep:../bin/main_eio.exe})))

(alias
 (name runtest)
 (deps (alias runtest-test_operator_media_inspection)))
