(** Tool_tag_init — Bulk name→tag registration for tools NOT in any module's schemas.

    Called once at startup (after schema-based registrations) to ensure
    every dispatched tool name has an O(1) tag lookup entry.

    Tools that are already in a module's [schemas] list are registered via
    [register_module_tag] in [mcp_server_eio.ml] and do NOT need entries here.
    Only tools dispatched by a module but missing from its schema list are included. *)

let register_all () =
  let open Tool_dispatch in
  let reg tag names =
    List.iter (fun name -> register_name_tag ~tool_name:name ~tag) names
  in

  (* ── Mod_inline: Tool_inline_dispatch ─────────────────────────── *)
  (* 16 tools are in Tool_schemas_inline.schemas; only non-schema tools here *)
  reg Mod_inline [
    "masc_bounded_run";
    "masc_verify_request"; "masc_verify_submit";
    "masc_verify_pending"; "masc_verify_auto";
    "masc_mcp_session";
    "masc_cancellation"; "masc_subscription"; "masc_progress";
    "masc_governance_set"; "masc_spawn"; "masc_memento_mori";
    "masc_episode_flush"; "masc_episode_list";
    "masc_self_introspect"; "masc_recall_search";
    (* board *)
    "masc_board_post"; "masc_board_comment";
    "masc_board_list"; "masc_board_get";
    "masc_board_vote"; "masc_board_stats";
    "masc_board_search"; "masc_board_comment_vote";
    "masc_board_profile"; "masc_board_hearths"; "masc_board_migrate";
    (* lodge *)
    "lodge_heartbeat"; "lodge_classify"; "lodge_react"; "lodge_cycle";
    "lodge_discussion"; "lodge_orchestrate"; "lodge_auto_chain";
    "lodge_evolve"; "lodge_spawn"; "lodge_agents";
    "lodge_agent_patrol"; "lodge_autonomous_loop";
    "lodge_propose_project"; "lodge_join_project"; "lodge_share_code";
    "lodge_research"; "lodge_profile";
    "lodge_search"; "lodge_comment_like"; "lodge_progress";
    (* conversations *)
    "masc_convo_start"; "masc_convo_reply"; "masc_convo_conclude";
    "masc_convo_get"; "masc_convo_list";
  ];

  (* ── Mod_task: non-schema tools ─────────────────────────────── *)
  reg Mod_task [
    "masc_transition";
  ];

  (* ── Mod_control: non-schema tools ──────────────────────────── *)
  reg Mod_control [
    "masc_switch_mode"; "masc_get_config";
  ];

  (* ── Mod_run: Tool_run ────────────────────────────────────────── *)
  reg Mod_run [
    "masc_run_init"; "masc_run_plan"; "masc_run_log";
    "masc_run_deliverable"; "masc_run_get"; "masc_run_list";
  ];

  (* ── Mod_cache: Tool_cache ────────────────────────────────────── *)
  reg Mod_cache [
    "masc_cache_set"; "masc_cache_get"; "masc_cache_delete";
    "masc_cache_list"; "masc_cache_clear"; "masc_cache_stats";
  ];

  (* ── Mod_tempo: non-schema tools ────────────────────────────── *)
  reg Mod_tempo [
    "masc_tempo_get"; "masc_tempo_set"; "masc_tempo_adjust";
    "masc_tempo";
  ];

  (* ── Mod_mitosis: non-schema tools ──────────────────────────── *)
  reg Mod_mitosis [
    "masc_mitosis_all"; "masc_mitosis_pool";
    "masc_mitosis_divide"; "masc_mitosis_check"; "masc_mitosis_record";
    "masc_mitosis_prepare"; "masc_mitosis_handoff";
    "masc_metrics_compare"; "masc_metrics_record";
  ];

  (* ── Mod_code: Tool_code ──────────────────────────────────────── *)
  reg Mod_code [
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
  ];

  (* ── Mod_vote: Tool_vote ──────────────────────────────────────── *)
  reg Mod_vote [
    "masc_vote_create"; "masc_vote_cast"; "masc_vote_status"; "masc_votes";
  ];

  (* ── Mod_social: Tool_social ──────────────────────────────────── *)
  reg Mod_social [
    "masc_post_create"; "masc_post_list"; "masc_post_get";
    "masc_comment_add"; "masc_comment_list"; "masc_vote";
  ];

  (* ── Mod_council: non-schema tools ──────────────────────────── *)
  reg Mod_council [
    "masc_route"; "masc_execute"; "masc_execute_dry_run";
    "masc_debate_start"; "masc_debate_argue";
    "masc_debate_close"; "masc_debate_status"; "masc_debates";
    "masc_consensus_start"; "masc_consensus_vote";
    "masc_consensus_close"; "masc_consensus_result"; "masc_sessions";
  ];

  (* ── Mod_a2a: Tool_a2a ───────────────────────────────────────── *)
  reg Mod_a2a [
    "masc_a2a_discover"; "masc_a2a_query_skill"; "masc_a2a_delegate";
    "masc_a2a_subscribe"; "masc_a2a_unsubscribe";
    "masc_poll_events"; "masc_heartbeat_result";
  ];

  (* ── Mod_handover: non-schema tools ─────────────────────────── *)
  reg Mod_handover [
    "masc_handover_create"; "masc_handover_list";
    "masc_handover_get";
  ];

  (* ── Mod_relay: non-schema tools ────────────────────────────── *)
  reg Mod_relay [
    "masc_relay_checkpoint";
    "masc_relay_now"; "masc_relay_smart_check";
  ];

  (* ── Mod_heartbeat: Tool_heartbeat ────────────────────────────── *)
  reg Mod_heartbeat [
    "masc_heartbeat"; "masc_heartbeat_start";
    "masc_heartbeat_stop"; "masc_heartbeat_list";
  ];

  (* ── Mod_encryption: non-schema tools ───────────────────────── *)
  reg Mod_encryption [
    "masc_generate_key";
  ];

  (* ── Mod_hat: non-schema tools ──────────────────────────────── *)
  reg Mod_hat [
    "masc_hat_wear";
  ];

  (* ── Mod_audit: Tool_audit ────────────────────────────────────── *)
  reg Mod_audit [
    "masc_audit_query"; "masc_audit_stats"; "masc_governance_report";
  ];

  (* Mod_cost and Mod_rate_limit: fully covered by schemas — no entries needed *)

  (* Mod_suspend: fully covered by schemas — no entries needed *)

  (* ── Mod_walph: non-schema tools ────────────────────────────── *)
  reg Mod_walph [
    "masc_walph_loop"; "masc_walph_control";
    "masc_walph_natural";
  ];

  (* ── Mod_library: Tool_library ────────────────────────────────── *)
  reg Mod_library [
    "masc_library_list"; "masc_library_read"; "masc_library_add";
    "masc_library_promote"; "masc_library_search";
  ];

  (* ── Mod_gardener: non-schema tools ─────────────────────────── *)
  reg Mod_gardener [
    "masc_gardener_health";
    "masc_gardener_propose_spawn"; "masc_gardener_retire_agent";
    "masc_gardener_config"; "masc_gardener_execute_spawn";
    "masc_gardener_execute_retire";
  ];

  (* ── Mod_misc: Tool_misc ──────────────────────────────────────── *)
  reg Mod_misc [
    "masc_dashboard"; "masc_verify_handoff";
    "masc_gc"; "masc_cleanup_zombies"; "masc_purge_test_data";
    "masc_tool_stats"; "masc_tool_help";
    "masc_tool_admin_snapshot"; "masc_tool_admin_update";
    "masc_keeper_tool_catalog";
  ];

  (* ── Schema-gap fills for modules with partial schema exports ── *)
  reg Mod_room [
    "masc_workflow_guide"; "masc_check";
    "masc_init";
  ];
  reg Mod_agent [
    "masc_register_capabilities"; "masc_find_by_capability";
    "masc_collaboration_graph"; "masc_consolidate_learning"; "masc_get_metrics";
  ];

  ()
