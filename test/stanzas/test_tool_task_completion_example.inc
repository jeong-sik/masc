; Regression for Tool_task.completion_rejection_message — every
; rejection must embed completion_notes_example so the keeper sees
; a concrete density of accepted notes (#8688 root-cause sweep).

(test
 (name test_tool_task_completion_example)
 (modules test_tool_task_completion_example)
 (libraries masc_test_deps))
