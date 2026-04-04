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
  reg Mod_inline [
    "masc_bounded_run";
    "masc_verify_request"; "masc_verify_submit";
    "masc_verify_pending"; "masc_verify_auto";
    (* board *)
    "masc_board_post"; "masc_board_comment";
    "masc_board_list"; "masc_board_get";
    "masc_board_vote"; "masc_board_stats";
    "masc_board_search"; "masc_board_comment_vote";
    "masc_board_delete";
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

  (* ── Mod_handover: non-schema tools ─────────────────────────── *)
  reg Mod_handover [
    "masc_handover_create"; "masc_handover_list";
    "masc_handover_get";
  ];

  (* ── Mod_heartbeat: Tool_heartbeat ────────────────────────────── *)
  reg Mod_heartbeat [
    "masc_heartbeat"; "masc_heartbeat_start";
    "masc_heartbeat_stop"; "masc_heartbeat_list";
  ];

  (* Mod_suspend: fully covered by schemas — no entries needed *)

  (* ── Mod_misc: Tool_misc ──────────────────────────────────────── *)
  reg Mod_misc [
    "masc_dashboard"; "masc_tool_help";
  ];

  (* ── Schema-gap fills for modules with partial schema exports ── *)
  reg Mod_room [
    "masc_workflow_guide"; "masc_check";
    "masc_init";
  ];
  reg Mod_agent [
    "masc_agent_card";
  ];

  ()
