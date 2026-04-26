(** Auto-Responder Daemon - Automatic @mention response *)

type mode =
  | Disabled
  | Spawn
  | Model

val get_mode : unit -> mode
val is_enabled : unit -> bool
val activity_log_file : unit -> string

val build_response_prompt
  :  from_agent:string
  -> content:string
  -> mention:string
  -> string

val extract_nickname : string -> string option
val chain_limit : int
val chain_window_sec : float

(** Mention helpers *)
val agent_type_of_mention : string -> string

val is_spawnable : string -> bool

(** Respond to an @mention in a broadcast message.
    Returns [Some task_id] if a response was dispatched, [None] otherwise. *)
val maybe_respond
  :  sw:Eio.Switch.t
  -> base_path:string
  -> from_agent:string
  -> content:string
  -> mention:string option
  -> string option
