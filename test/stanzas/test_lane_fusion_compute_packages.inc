(rule
 (alias runtest-test_lane_fusion_compute_packages)
 (deps test_lane_fusion_compute_packages.py
       ../addons/protocol.py ../addons/fusion_sampling.py ../addons/fusion_judge.py
       ../addons/fusion-compute/server.py ../addons/fusion-compute/lane.toml
       ../addons/fusion-report/server.py ../addons/fusion-report/lane.toml
       ../addons/fusion-results/server.py ../addons/fusion-results/export_snapshot.py
       ../addons/tests/test_fusion_compute.py ../addons/tests/test_fusion_report.py
       ../addons/tests/test_fusion_results.py ../addons/tests/stdio_fixture.py
       ../addons/tests/test_packages.py
       (glob_files ../docs/examples/lane-addons/fusion-compute/*.toml))
 (action (run python3 %{dep:test_lane_fusion_compute_packages.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_lane_fusion_compute_packages)))
