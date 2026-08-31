(* Keeper-aware bridge that reads the keeper chat store and projects it into
   the tool timeline's neutral [Tool_agent_timeline.chat_line] (task-1647).

   This lives outside the tool surface on purpose: the tool timeline must not
   reference the keeper subsystem (RFC-0194 §3 tool -> keeper boundary), so
   the keeper -> tool direction is inverted here. A caller passes
   [lines_for ~base_dir ~keeper_name] as [Tool_agent_timeline.build_timeline]'s
   [load_chat] reader.

   Tool lines are dropped — tool activity is already surfaced by the timeline's
   [tool.called] source, so re-emitting the chat store's tool rows would
   double-count. *)
let chat_store_keeper_name raw = String.trim raw

let lines_for ~base_dir ~keeper_name : Tool_agent_timeline.chat_line list =
  let keeper_name = chat_store_keeper_name keeper_name in
  Keeper_chat_store.load ~base_dir ~keeper_name
  |> List.filter_map (fun (m : Keeper_chat_store.chat_message) ->
         match m.role with
         | Keeper_chat_store.Role.Tool | Keeper_chat_store.Role.System -> None
         | Keeper_chat_store.Role.User | Keeper_chat_store.Role.Assistant ->
             Some
               {
                 Tool_agent_timeline.cl_role = Keeper_chat_store.Role.to_label m.role;
                 cl_content = m.content;
                 cl_ts = m.ts;
                 cl_connector =
                   Option.map Surface_ref.lane_label m.surface;
                 cl_conversation_id = m.conversation_id;
               })

let same_keeper_identity left right =
  String.equal (String.trim left) (String.trim right)

let lines_for_self ~base_dir ~caller_keeper_name ~agent_name =
  if same_keeper_identity caller_keeper_name agent_name then
    lines_for ~base_dir ~keeper_name:agent_name
  else []
