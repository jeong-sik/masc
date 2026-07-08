(** Keeper-owned recurring task tool handler.

    Dispatches the public [masc_recurring_*] tool surface to the in-process
    recurring task registry while enforcing duplicate-label and owner-scoped
    remove rules at the tool boundary. *)

val dispatch :
  agent_name:string ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option
