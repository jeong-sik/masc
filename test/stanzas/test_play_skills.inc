; RFC play-link-for-the-shared-machine §2.7: the attached DOS machine's Skills
; through the invite link, with real Lane runtime and Skill snapshot state.

(test
 (name test_play_skills)
 (modules test_play_skills)
 ; The agent guide renders config/prompts/play.agent_guide.md.
 (deps (source_tree %{workspace_root}/config/prompts))
 (action (run %{test}))
 (libraries masc_test_deps mcp_protocol alcotest yojson bigstringaf unix eio eio_main masc.masc_core masc.server masc.skill_snapshot_service))
