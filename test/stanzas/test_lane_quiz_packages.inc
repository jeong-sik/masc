(rule
 (alias runtest-test_lane_quiz_packages)
 (deps test_lane_quiz_packages.py
       ../addons/protocol.py
       ../addons/quiz-questions/server.py
       ../addons/quiz-grader/server.py
       ../addons/tests/test_quiz_lane.py)
 (action (run python3 %{dep:test_lane_quiz_packages.py})))
