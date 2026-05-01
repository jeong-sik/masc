; Operator Control (7 modules)

(test
 (name test_operator_control)
 (modules test_operator_control
          test_operator_control_support
          test_operator_control_snapshot
          test_operator_control_actions
          test_operator_control_judgment
          test_operator_control_confirm
          test_operator_control_keeper)
 (libraries masc_test_deps)
 (enabled_if (= %{env:MASC_INCLUDE_OPERATOR_CONTROL=true} "true")))
