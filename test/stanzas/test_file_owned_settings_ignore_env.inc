; A setting the runtime file alone feeds never reads the process environment:
; the probe runs over every such registry row, and the loader declares the names.
(test
 (name test_file_owned_settings_ignore_env)
 (modules test_file_owned_settings_ignore_env)
 (libraries masc_test_deps))
