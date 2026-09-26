; The skill_catalog section of /health?full=1: a rejected Skill configuration
; degrades health and reaches the operator rollup (#39269).
(test
 (name test_server_skill_catalog_health)
 (modules test_server_skill_catalog_health)
 (libraries alcotest masc_server masc.skill_snapshot masc.skill_config yojson))
