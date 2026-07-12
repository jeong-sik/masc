(** Projects the keeper chat store into the tool timeline's neutral chat
    lines, inverting the keeper -> tool dependency so the tool surface never
    references the keeper subsystem (RFC-0194 §3). *)

val lines_for :
  config:Workspace.config ->
  base_dir:string -> keeper_name:string -> Tool_agent_timeline.chat_line list
(** [lines_for ~base_dir ~keeper_name] reads the keeper's chat store and
    returns its user/assistant lines (tool rows and rows without a timestamp
    dropped) as neutral [Tool_agent_timeline.chat_line] values, ready to pass
    as [build_timeline]'s [load_chat] reader. *)

val lines_for_self :
  config:Workspace.config ->
  base_dir:string ->
  caller_keeper_name:string ->
  agent_name:string ->
  Tool_agent_timeline.chat_line list
(** [lines_for_self ~base_dir ~caller_keeper_name ~agent_name] is the
    keeper-runtime scoped reader: it returns chat lines only when the queried
    [agent_name] resolves to the caller keeper. Operator/dashboard read paths
    that intentionally inspect arbitrary keepers should use [lines_for]. *)
