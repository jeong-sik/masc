(** Error recovery hints — pattern-matches error messages to suggest next actions.

    Called from mcp_server_eio_call_tool.ml on tool failure to help agents
    self-recover without human intervention.
    self-correct without human intervention. *)

(* Byte-wise substring containment.

   [recovery_hint] chains ~15 [contains] calls per error message; the
   old form built a fresh [Re.t] per call (10-30 [Re.compile] per
   tool failure once short-circuiting is accounted for).  The needles
   are short literals and [s] is already lowercased by the caller, so
   a naive byte scan is strictly cheaper than DFA construction. *)
let contains s sub =
  let nlen = String.length sub in
  let hlen = String.length s in
  if nlen = 0
  then true
  else if nlen > hlen
  then false
  else (
    let rec match_at i j =
      if j = nlen
      then true
      else if String.unsafe_get s (i + j) <> String.unsafe_get sub j
      then false
      else match_at i (j + 1)
    in
    let last = hlen - nlen in
    let rec loop i =
      if i > last then false else if match_at i 0 then true else loop (i + 1)
    in
    loop 0)
;;

(** Given an error message, return a suggested recovery action or None. *)
let recovery_hint (message : string) : string option =
  let msg = String.lowercase_ascii message in
  if contains msg "not initialized" || contains msg "no .masc/"
  then Some "Run masc_init to initialize, or use masc_start(path=...) for one-step setup."
  else if contains msg "not joined" || contains msg "join the room"
  then Some "Call masc_join first, or use masc_start for one-step setup."
  else if
    contains msg "task not found" || (contains msg "not found" && contains msg "task")
  then Some "Call masc_status to see available tasks."
  else if contains msg "already claimed"
  then Some "Call masc_status to see other available tasks, or use masc_claim_next."
  else if contains msg "no unclaimed tasks"
  then Some "Call masc_add_task to create a new task."
  else if contains msg "rate limit" || contains msg "too many"
  then Some "Wait briefly and retry. This is a transient error."
  else if contains msg "room" && contains msg "set"
  then Some "Call masc_start(path=...) to set the project scope and join in one step."
  else if contains msg "current_task" || contains msg "no current task"
  then Some "Call masc_plan_set_task(task_id=...) after claiming a task."
  else if contains msg "path is required"
  then Some "Provide the project directory path, e.g., masc_start(path=\"~/my-project\")."
  else None
;;
