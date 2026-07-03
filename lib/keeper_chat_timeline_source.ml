(* Keeper-aware bridge that reads the keeper chat store and projects it into
   the tool timeline's neutral [Tool_agent_timeline.chat_line] (task-1647).

   This lives outside the tool surface on purpose: the tool timeline must not
   reference the keeper subsystem (RFC-0194 §3 tool -> keeper boundary), so
   the keeper -> tool direction is inverted here. A caller passes
   [lines_for ~base_dir ~keeper_name] as [Tool_agent_timeline.build_timeline]'s
   [load_chat] reader.

   Tool lines are dropped — tool activity is already surfaced by the timeline's
   [tool.called] source, so re-emitting the chat store's tool rows would
   double-count. Rows without a timestamp (legacy pre-ts lines) are dropped
   because they cannot be placed chronologically. *)
let lines_for ~base_dir ~keeper_name : Tool_agent_timeline.chat_line list =
  Keeper_chat_store.load ~base_dir ~keeper_name
  |> List.filter_map (fun (m : Keeper_chat_store.chat_message) ->
         match (m.role, m.ts) with
         | Keeper_chat_store.Role.Tool, _ | _, None -> None
         | role, Some ts ->
             Some
               {
                 Tool_agent_timeline.cl_role = Keeper_chat_store.Role.to_label role;
                 cl_content = m.content;
                 cl_ts = ts;
                 cl_connector = m.source;
                 cl_conversation_id = m.conversation_id;
               })
