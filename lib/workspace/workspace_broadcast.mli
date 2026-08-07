(** Workspace broadcast — emit workspace-wide messages and the
    accompanying message-activity event. *)


type broadcast_delivery =
  { rendered : string
  ; from_agent : string
  ; content : string
  ; mention : string option
  ; msg_type : string
  }

val emit_message_activity : Workspace_utils_backend_setup.config ->
           from_agent:string ->
           content:string ->
           mention:string option ->
           ?session_id:string ->
           ?operation_id:string ->
           ?worker_run_id:string ->
           ?evidence_refs:string list -> unit -> unit
val broadcast_channel : Workspace_utils_backend_setup.config -> string
val on_broadcast_mention : (string option -> unit) ref
val broadcast : ?trace_context:string ->
           ?msg_type:string ->
           Workspace_utils_backend_setup.config ->
           from_agent:string -> content:string -> broadcast_delivery
