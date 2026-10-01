(rule
 (alias runtest-test_lane_quiz_packages)
 (deps test_lane_quiz_packages.py
       ../addons/protocol.py
       ../addons/quiz-questions/server.py
       ../addons/quiz-questions/skills/quiz-deck/scripts/build_deck.py
       ../addons/quiz-grader/server.py
       ../addons/quiz-grader/lane.toml
       ../addons/tests/test_quiz_lane.py ../addons/tests/stdio_fixture.py)
 (action (run python3 %{dep:test_lane_quiz_packages.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_lane_quiz_packages)))
