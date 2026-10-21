(rule
 (alias runtest-test_operator_quiz_package)
 (deps test_operator_quiz_package.py
       ../addons/protocol.py
       (glob_files ../addons/operator-quiz/*.py)
       ../addons/operator-quiz/lane.toml
       (glob_files ../addons/operator-quiz/schemas/*.json)
       (glob_files ../addons/operator-quiz/prompts/*.md)
       (glob_files ../addons/tests/test_operator_quiz_*.py))
 (action (run python3 %{dep:test_operator_quiz_package.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_operator_quiz_package)))
