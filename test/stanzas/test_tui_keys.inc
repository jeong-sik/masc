(test
 (name test_tui_keys)
 (modules test_tui_keys)
 (libraries masc_tui_fusion_model masc_tui_surface_search masc_tui_approvals_model masc_tui_surface_navigation alcotest yojson masc masc.masc_goal masc.repo_manager
  ;; The modify gate is checked against the schedule contract's own status
  ;; vocabulary, so the test reads that list instead of keeping a copy.
  masc.masc_schedule
  ;; [Standalone_lane.t] is what the lane rows and lane views carry.
  masc.runtime
  masc_tui_mcp masc_tui_types masc_tui_operator_projection
  masc_tui_keys masc_tui_keeper_mark masc_tui_memory_mark masc_tui_footer
  masc_tui_config_mark
  ;; The global quit test, so a detail tab key is checked against the one
  ;; that runs before it rather than against a copy of its two letters.
  masc_tui_render_schedule
  masc_tui_file_icon
  masc_tui_message_layout
   masc_tui_fetched masc_tui_keeper_chat_transcript))
