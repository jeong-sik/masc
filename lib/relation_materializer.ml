(** Relation Materializer — agent relationship recording.
    Second Brain GraphQL integration has been retired; callbacks are retained as no-op.
*)

(** Build a single batched GraphQL mutation using aliases (retained for compatibility/tests). *)
let build_batch_mutation ~agent ~peers ~context =
  let escape s =
    let parts = String.split_on_char '"' s in
    String.concat "\\\"" parts
  in
  let fields = List.mapi (fun i peer ->
    Printf.sprintf
      "c%d: recordCollaborationByName(agent1Name: \"%s\", agent2Name: \"%s\", context: \"%s\") { success }"
      i (escape agent) (escape peer) (escape context)
  ) peers in
  "mutation { " ^ String.concat " " fields ^ " }"

(** Retired: no external GraphQL mutation on session end. *)
let on_agent_session_ended ~leaving_agent:_ ~active_agents:_ = ()

(** Retired: no external GraphQL mutation on task completion. *)
let on_task_done ~assignee:_ ~active_agents:_ = ()
