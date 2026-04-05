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
    "masc_governance_set"; "masc_spawn";
    "masc_episode_flush"; "masc_episode_list";
    "masc_recall_search";
    (* board *)
    "masc_board_post"; "masc_board_comment";
    "masc_board_list"; "masc_board_get";
    "masc_board_vote"; "masc_board_stats";
    "masc_board_search"; "masc_board_comment_vote";
    "masc_board_profile"; "masc_board_hearths"; "masc_board_migrate";
    "masc_board_delete";
    "masc_board_reclassify";
  ];

  (* ── Mod_task: non-schema tools ─────────────────────────────── *)
  reg Mod_task [
    "masc_transition";
  ];

  (* ── Mod_code: Tool_code ──────────────────────────────────────── *)
  reg Mod_code [
    "masc_code_search"; "masc_code_symbols"; "masc_code_read";
  ];

  (* ── Mod_code_write: Tool_code_write ────────────────────────── *)
  reg Mod_code_write [
    "masc_code_write"; "masc_code_edit"; "masc_code_delete";
    "masc_code_shell"; "masc_code_git";
  ];

  (* ── Mod_a2a: a2a federation tools deprecated (#4999).
     poll_events and heartbeat_result remain — used by dashboard/auth. *)
  reg Mod_a2a [
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

  (* Mod_suspend: fully covered by schemas — no entries needed *)

  (* ── Mod_library: Tool_library ────────────────────────────────── *)
  reg Mod_library [
    "masc_library_list"; "masc_library_read"; "masc_library_add";
    "masc_library_promote"; "masc_library_search";
  ];

  (* ── Mod_misc: Tool_misc ──────────────────────────────────────── *)
  reg Mod_misc [
    "masc_dashboard"; "masc_verify_handoff";
    "masc_gc"; "masc_cleanup_zombies";
    "masc_tool_stats"; "masc_tool_help";
    "masc_tool_admin_snapshot"; "masc_tool_admin_update";
    "masc_keeper_tool_catalog";
    "masc_feature_flags";
  ];

  (* ── Mod_shard: Tool_shard ────────────────────────────────────── *)
  reg Mod_shard [
    "masc_tool_grant"; "masc_tool_revoke"; "masc_tool_list";
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
