(** Auto-Responder Daemon - Automatic @mention response *)

type mode = Disabled | Spawn | Model

val get_mode : unit -> mode
val is_enabled : unit -> bool

(** Mention helpers (re-exported from Mention) *)
val spawnable_agents : string list
val agent_type_of_mention : string -> string
val is_spawnable : string -> bool

(** Respond to an @mention in a broadcast message.
    Returns [Some task_id] if a response was dispatched, [None] otherwise. *)
val maybe_respond :
  sw:Eio.Switch.t ->
  base_path:string ->
  from_agent:string ->
  content:string ->
  mention:string option ->
  string option
