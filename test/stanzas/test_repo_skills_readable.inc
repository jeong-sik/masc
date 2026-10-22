; #45124: the repository's .agents/skills, read through the server's Skill
; publisher and the Keeper catalog projection.
(test
 (name test_repo_skills_readable)
 (modules test_repo_skills_readable)
 (libraries alcotest masc masc.skill_reference masc.skill_snapshot masc.skill_snapshot_service))
