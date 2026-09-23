(* What a failed ordinary tool call does to the provider turn. See
   keeper_tool_failure_boundary.mli. *)
type boundary =
  | Any_effect_ends_turn
      (** A failure that may have left an effect ends the turn. *)
  | Applied_effect_ends_turn
      (** Only a failure proven to have applied its effect ends the turn. *)
  | Failure_returns_to_model

let of_handler (handler : Keeper_tool_descriptor.runtime_handler) =
  match handler with
  (* A spawn that started leaves a process running with no
     handle in the caller's hands if the call then fails, which
     is the same shape of loss Execute has. *)
  | Keeper_tool_descriptor.Tool_execute
  | Keeper_tool_descriptor.Tool_browser_act
  | Keeper_tool_descriptor.Tool_keeper_spawn_dispatch
  (* A failed webmcp call may have already executed the page's
     tool — the bridge cannot prove otherwise — which is the
     same effect-outcome-unknown shape Execute has. *)
  | Keeper_tool_descriptor.Tool_keeper_webmcp_dispatch ->
    Any_effect_ends_turn
  | Keeper_tool_descriptor.Tool_peer_artifact
  | Keeper_tool_descriptor.Tool_edit_file
  | Keeper_tool_descriptor.Tool_write_file ->
    Applied_effect_ends_turn
  (* A failed memory write or retract goes back to the model whatever it
     committed, because doing it again adds no second fact row: an ordinary
     fact is keyed by the SHA-256 of its title and content, a source-bound one
     by its path (a new claim for that path replaces the old one), and
     retracting a fact that is gone commits nothing. A repeat write still
     commits another revision. The result names what committed, so the Keeper
     can read memory before it tries again. *)
  | Keeper_tool_descriptor.Tool_memory_retract
  | Keeper_tool_descriptor.Tool_memory_write ->
    Failure_returns_to_model
  (* A Skill publish only creates: the editor refuses an existing package, so
     a repeat after a written-but-unpublished SKILL.md commits nothing and
     answers package_already_exists. The result names the reference that was
     written, so the Keeper can say so instead of losing the turn. *)
  | Keeper_tool_descriptor.Tool_skill_publish -> Failure_returns_to_model
  (* A code query starts a language server, but the pool owns it
     and the turn ends it either way, so a failed call leaves the
     caller holding nothing. It answers with the readers. *)
  | ( Keeper_tool_descriptor.Tool_keeper_code_query_dispatch
    | Keeper_tool_descriptor.Tool_search_files
    | Keeper_tool_descriptor.Tool_read_file
    | Keeper_tool_descriptor.Tool_lane_status
    | Keeper_tool_descriptor.Tool_tools_list
    | Keeper_tool_descriptor.Tool_capability_search
    | Keeper_tool_descriptor.Tool_context_status
    | Keeper_tool_descriptor.Tool_artifact_read
    | Keeper_tool_descriptor.Tool_skill_validate
    | Keeper_tool_descriptor.Tool_workspace_memory_read
    | Keeper_tool_descriptor.Tool_memory_search
    | Keeper_tool_descriptor.Tool_constitution_write
    | Keeper_tool_descriptor.Tool_constitution_remove
    | Keeper_tool_descriptor.Tool_library_search
    | Keeper_tool_descriptor.Tool_library_read
    | Keeper_tool_descriptor.Tool_surface_read
    | Keeper_tool_descriptor.Tool_surface_post
    | Keeper_tool_descriptor.Tool_person_note_set
    | Keeper_tool_descriptor.Tool_ide_annotate
    | Keeper_tool_descriptor.Tool_voice_dispatch
    | Keeper_tool_descriptor.Tool_task_dispatch
    | Keeper_tool_descriptor.Tool_board_dispatch
    | Keeper_tool_descriptor.Tool_masc_task_dispatch
    | Keeper_tool_descriptor.Tool_masc_plan_dispatch
    | Keeper_tool_descriptor.Tool_masc_run_dispatch
    | Keeper_tool_descriptor.Tool_masc_agent_dispatch
    | Keeper_tool_descriptor.Tool_masc_workspace_dispatch
    | Keeper_tool_descriptor.Tool_masc_misc_dispatch
    | Keeper_tool_descriptor.Tool_web_search
    | Keeper_tool_descriptor.Tool_web_fetch
    | Keeper_tool_descriptor.Tool_browser_tabs
    | Keeper_tool_descriptor.Tool_browser_read
    | Keeper_tool_descriptor.Tool_browser_session
    | Keeper_tool_descriptor.Tool_browser_goto
    | Keeper_tool_descriptor.Tool_browser_interact
    | Keeper_tool_descriptor.Tool_masc_control_dispatch
    | Keeper_tool_descriptor.Tool_masc_agent_timeline_dispatch
    | Keeper_tool_descriptor.Tool_masc_schedule_dispatch
    | Keeper_tool_descriptor.Tool_masc_keeper_dispatch
    | Keeper_tool_descriptor.Tool_masc_fusion_dispatch
    | Keeper_tool_descriptor.Tool_masc_fusion_status
    | Keeper_tool_descriptor.Tool_masc_fusion_decision
    | Keeper_tool_descriptor.Tool_masc_file_dispatch
    | Keeper_tool_descriptor.Tool_masc_library_dispatch
    | Keeper_tool_descriptor.Tool_masc_local_runtime_dispatch
    | Keeper_tool_descriptor.Tool_analyze_image ) ->
    Failure_returns_to_model
;;

let ends_turn
      handler
      (disposition : Tool_result.failure_effect_disposition)
  =
  match of_handler handler, disposition with
  | ( (Any_effect_ends_turn | Applied_effect_ends_turn | Failure_returns_to_model)
    , Tool_result.Proven_pre_effect ) ->
    false
  | (Any_effect_ends_turn | Applied_effect_ends_turn), Tool_result.Proven_post_effect ->
    true
  | Any_effect_ends_turn, Tool_result.Effect_outcome_unknown -> true
  | Applied_effect_ends_turn, Tool_result.Effect_outcome_unknown -> false
  | ( Failure_returns_to_model
    , (Tool_result.Proven_post_effect | Tool_result.Effect_outcome_unknown) ) ->
    false
;;
