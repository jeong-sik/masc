; Per-file dune stanza for the [Env_config_runtime_services.ScheduleRunner]
; knob contract suite (floor clamp + documented default).

(test
 (name test_env_config_schedule_runner)
 (modules test_env_config_schedule_runner)
 (libraries masc_test_deps))
