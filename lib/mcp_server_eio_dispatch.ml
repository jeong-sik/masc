(** Mcp_server_eio_dispatch — Tool dispatch chain

    Extracted from mcp_server_eio.ml execute_tool_eio.
    Receives pre-built tool contexts and runs V2 + fallback dispatch.
*)

(** All pre-built tool contexts needed for the dispatch chain. *)
type dispatch_contexts = {
  config : Room.config;
  agent_name : string;
  arguments : Yojson.Safe.t;
  name : string;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  mcp_session_id : string option;
  auth_token : string option;
  registry : Session.registry;
  ctx_plan : Tool_plan.context;
  ctx_run : Tool_run.context;
  ctx_team_session : float Tool_team_session.context;
  ctx_operator : Tool_operator.context;
  ctx_command_plane : (Eio.Net.Sockaddr.stream, Eio.Net.connection_handler) Tool_command_plane.context;
  ctx_cache : Tool_cache.context;
  ctx_tempo : Tool_tempo.context;
  ctx_mitosis : Tool_mitosis.context;
  ctx_portal : Tool_portal.context;
  ctx_worktree : Tool_worktree.context;
  ctx_code : Tool_code.context;
  ctx_vote : Tool_vote.context;
  ctx_social : Tool_social.context;
  ctx_council : Tool_council.context;
  ctx_experiment : Tool_experiment.context;
  ctx_a2a : Tool_a2a.context;
  ctx_handover : Tool_handover.context;
  ctx_relay : Tool_relay.context;
  ctx_goals : Tool_goals.context;
  ctx_heartbeat : Tool_heartbeat.context;
  ctx_encryption : Tool_encryption.context;
  ctx_auth : Tool_auth.context;
  ctx_hat : Tool_hat.context;
  ctx_audit : Tool_audit.context;
  ctx_rate_limit : Tool_rate_limit.context;
  ctx_cost : Tool_cost.context;
  ctx_walph : (float Tool_walph.context, string) result;
  ctx_agent : Tool_agent.context;
  ctx_task : Tool_task.context;
  ctx_room : Tool_room.context;
  ctx_control : Tool_control.context;
  ctx_misc : Tool_misc.context;
  ctx_agent_timeline : Tool_agent_timeline.context;
  ctx_llama : Tool_llama.context;
  ctx_voice : float Tool_voice.context;
  ctx_suspend : Tool_suspend.context;
  ctx_library : Tool_library.context;
  ctx_mdal : Tool_mdal.context;
  ctx_autoresearch : Tool_autoresearch.context;
  ctx_perpetual : Tool_perpetual.context;
  ctx_keeper : float Tool_keeper.context;
  ctx_trpg : Tool_trpg.context;
  ctx_protocol : Tool_protocol_game_view.context;
  build_inline_ctx : unit -> Tool_inline_dispatch.context;
}

let dispatch (c : dispatch_contexts) : bool * string =
  let name = c.name in
  let arguments = c.arguments in

  (* === V2 Dispatch: O(1) Hashtbl-based central dispatch === *)
  let v2_result =
    if Tool_dispatch.v2_enabled then begin
      let reg = Tool_dispatch.register_module in
      reg ~schemas:Tool_operator.schemas
        ~handler:(fun ~name ~args -> Tool_operator.dispatch c.ctx_operator ~name ~args);
      reg ~schemas:Tool_command_plane.schemas
        ~handler:(fun ~name ~args -> Tool_command_plane.dispatch c.ctx_command_plane ~name ~args);
      reg ~schemas:Tool_llama.schemas
        ~handler:(fun ~name ~args -> Tool_llama.dispatch c.ctx_llama ~name ~args);
      reg ~schemas:Tool_team_session.schemas
        ~handler:(fun ~name ~args -> Tool_team_session.dispatch c.ctx_team_session ~name ~args);
      reg ~schemas:Tool_voice.schemas
        ~handler:(fun ~name ~args -> Tool_voice.dispatch c.ctx_voice ~name ~args);
      reg ~schemas:Tool_protocol_game_view.schemas
        ~handler:(fun ~name ~args -> Tool_protocol_game_view.dispatch c.ctx_protocol ~name ~args);
      reg ~schemas:Tool_experiment.schemas
        ~handler:(fun ~name ~args -> Tool_experiment.dispatch c.ctx_experiment ~name ~args);
      reg ~schemas:Tool_goals.schemas
        ~handler:(fun ~name ~args -> Tool_goals.dispatch c.ctx_goals ~name ~args);
      reg ~schemas:Tool_perpetual.schemas
        ~handler:(fun ~name ~args -> Tool_perpetual.dispatch c.ctx_perpetual ~name ~args);
      reg ~schemas:Tool_mdal.schemas
        ~handler:(fun ~name ~args -> Tool_mdal.dispatch c.ctx_mdal ~name ~args);
      reg ~schemas:Tool_keeper.schemas
        ~handler:(fun ~name ~args -> Tool_keeper.dispatch c.ctx_keeper ~name ~args);
      reg ~schemas:Tool_trpg.schemas
        ~handler:(fun ~name ~args -> Tool_trpg.dispatch c.ctx_trpg ~name ~args);
      reg ~schemas:Tool_autoresearch.schemas
        ~handler:(fun ~name ~args -> Tool_autoresearch.dispatch c.ctx_autoresearch ~name ~args);
      reg ~schemas:Tool_risc.schemas
        ~handler:(fun ~name ~args -> Some (Tool_risc.dispatch name args));
      reg ~schemas:Tool_agent_timeline.schemas
        ~handler:(fun ~name ~args -> Tool_agent_timeline.dispatch c.ctx_agent_timeline ~name ~args);
      reg ~schemas:Tool_plan.schemas
        ~handler:(fun ~name ~args -> Tool_plan.dispatch c.ctx_plan ~name ~args);
      reg ~schemas:Tool_portal.schemas
        ~handler:(fun ~name ~args -> Tool_portal.dispatch c.ctx_portal ~name ~args);
      reg ~schemas:Tool_worktree.schemas
        ~handler:(fun ~name ~args -> Tool_worktree.dispatch c.ctx_worktree ~name ~args);
      reg ~schemas:Tool_auth.schemas
        ~handler:(fun ~name ~args -> Tool_auth.dispatch c.ctx_auth ~name ~args);
      reg ~schemas:Tool_agent.schemas
        ~handler:(fun ~name ~args -> Tool_agent.dispatch c.ctx_agent ~name ~args);
      reg ~schemas:Tool_room.schemas
        ~handler:(fun ~name ~args -> Tool_room.dispatch c.ctx_room ~name ~args);
      Tool_dispatch.dispatch ~name ~args:arguments
    end else None
  in
  match v2_result with
  | Some result -> result
  | None ->

  (* Chain through all extracted tool modules *)
  match Tool_plan.dispatch c.ctx_plan ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_run.dispatch c.ctx_run ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_operator.dispatch c.ctx_operator ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_command_plane.dispatch c.ctx_command_plane ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_llama.dispatch c.ctx_llama ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_team_session.dispatch c.ctx_team_session ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_voice.dispatch c.ctx_voice ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_cache.dispatch c.ctx_cache ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_tempo.dispatch c.ctx_tempo ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_mitosis.dispatch c.ctx_mitosis ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_portal.dispatch c.ctx_portal ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_worktree.dispatch c.ctx_worktree ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_code.dispatch c.ctx_code ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_vote.dispatch c.ctx_vote ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_social.dispatch c.ctx_social ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_council.dispatch c.ctx_council ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_protocol_game_view.dispatch c.ctx_protocol ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_experiment.dispatch c.ctx_experiment ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_a2a.dispatch c.ctx_a2a ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_handover.dispatch c.ctx_handover ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_relay.dispatch c.ctx_relay ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_goals.dispatch c.ctx_goals ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_heartbeat.dispatch c.ctx_heartbeat ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_encryption.dispatch c.ctx_encryption ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_auth.dispatch c.ctx_auth ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_hat.dispatch c.ctx_hat ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_audit.dispatch c.ctx_audit ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_rate_limit.dispatch c.ctx_rate_limit ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_cost.dispatch c.ctx_cost ~name ~args:arguments with
  | Some result -> result
  | None ->
  if String.length name >= 11 && String.equal (String.sub name 0 11) "masc_walph_" then
    (match c.ctx_walph with
     | Error msg -> (false, msg)
     | Ok ctx ->
       match Tool_walph.dispatch ctx ~name ~args:arguments with
       | Some result -> result
       | None -> (false, Printf.sprintf "Unknown Walph tool: %s" name))
  else
  match Tool_agent.dispatch c.ctx_agent ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_task.dispatch c.ctx_task ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_room.dispatch c.ctx_room ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_control.dispatch c.ctx_control ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_agent_timeline.dispatch c.ctx_agent_timeline ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_misc.dispatch c.ctx_misc ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_suspend.dispatch c.ctx_suspend ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_library.dispatch c.ctx_library ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_keeper.dispatch c.ctx_keeper ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_perpetual.dispatch c.ctx_perpetual ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_mdal.dispatch c.ctx_mdal ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_autoresearch.dispatch c.ctx_autoresearch ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_trpg.dispatch c.ctx_trpg ~name ~args:arguments with
  | Some result -> result
  | None ->
  match Tool_notifications.dispatch c.state.Mcp_server.session_registry ~agent_name:c.agent_name ~name arguments with
  | Some result -> result
  | None ->
  if String.length name >= 14 && String.sub name 0 14 = "masc_gardener_" then
    Tool_gardener.dispatch () name arguments
  else

  if Tool_risc.is_risc_tool name then
    Tool_risc.dispatch name arguments
  else

  let inline_ctx = c.build_inline_ctx () in
  match Tool_inline_dispatch.dispatch inline_ctx ~name with
  | Some result -> result
  | None ->
      (false, Printf.sprintf "Unknown tool: %s" name)
