(rule
 (alias runtest-test_operator_lesson_package)
 (deps test_operator_lesson_package.py
       ../addons/protocol.py
       ../addons/records.py
       (glob_files ../addons/operator-lesson/*.py)
       ../addons/operator-lesson/lane.toml
       (glob_files ../addons/operator-lesson/schemas/*.json)
       (glob_files ../addons/operator-lesson/prompts/*.md)
       ../addons/tests/test_operator_lesson.py
       ../addons/tests/test_operator_quiz_flow.py
       (glob_files ../addons/operator-quiz/*.py))
 (action (run python3 %{dep:test_operator_lesson_package.py})))

(alias
 (name runtest)
 (deps (alias runtest-test_operator_lesson_package)))
