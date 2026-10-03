(rule
 (alias runtest-test_lane_fusion_compute_packages)
 (deps test_lane_fusion_compute_packages.py
       qualify_lane_composition_containers.py test_qualify_lane_composition_containers.py
       ../addons/protocol.py ../addons/fusion_sampling.py ../addons/fusion_judge.py
       ../addons/fusion-compute/server.py ../addons/fusion-compute/lane.toml
       ../addons/fusion-report/server.py ../addons/fusion-report/lane.toml
       ../addons/fusion-results/server.py ../addons/fusion-results/export_snapshot.py
       ../addons/fusion-results/lane.toml
       ../addons/tests/test_fusion_compute.py ../addons/tests/test_fusion_report.py
       ../addons/tests/test_fusion_results.py ../addons/tests/test_packages.py
       ../addons/tests/stdio_fixture.py
       (glob_files ../docs/examples/lane-addons/fusion-compute/*.toml))
 (action (progn
  (run python3 %{dep:test_lane_fusion_compute_packages.py})
  (run python3 %{dep:test_qualify_lane_composition_containers.py}))))

(alias
 (name runtest)
 (deps (alias runtest-test_lane_fusion_compute_packages)))
