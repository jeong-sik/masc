(** Error recovery hints — pattern-matches error messages to suggest next actions.

    Called from mcp_server_eio_call_tool.ml on tool failure to help agents
    self-recover without human intervention.
    self-correct without human intervention. *)

let contains s sub =
  Re.execp (Re.str sub |> Re.compile) s

(** Given an error message, return a suggested recovery action or None. *)
let recovery_hint (message : string) : string option =
  let msg = String.lowercase_ascii message in
  if contains msg "not initialized" || contains msg "no .masc/" then
    Some "Run masc_init to initialize, or use masc_start(path=...) for one-step setup."
  else if contains msg "not joined" || contains msg "join the room" then
    Some "Call masc_join first, or use masc_start for one-step setup."
  else if contains msg "task not found" || contains msg "not found" && contains msg "task" then
    Some "Call masc_status to see available tasks."
  else if contains msg "already claimed" then
    Some "Call masc_status to see other available tasks, or use masc_claim_next."
  else if contains msg "no unclaimed tasks" then
    Some "Call masc_add_task to create a new task."
  else if contains msg "rate limit" || contains msg "too many" then
    Some "Wait briefly and retry. This is a transient error."
  else if contains msg "room" && contains msg "set" then
    Some "Call masc_start(path=...) to set the room and join in one step."
  else if contains msg "current_task" || contains msg "no current task" then
    Some "Call masc_plan_set_task(task_id=...) after claiming a task."
  else if contains msg "path is required" then
    Some "Provide the project directory path, e.g., masc_start(path=\"~/my-project\")."
  else
    None
