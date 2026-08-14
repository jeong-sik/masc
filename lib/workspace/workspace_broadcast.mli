(** Workspace broadcast — emit workspace-wide messages and the
    accompanying message-activity event. *)


type broadcast_error = Broadcast_not_persisted of string

val broadcast_error_to_string : broadcast_error -> string

type broadcast_delivery =
  { request_id : string
  ; seq : int
  ; rendered : string
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

(** Atomically replace the process-wide committed-broadcast notification
    handler. The handler runs only after the authoritative workspace message
    write commits. *)
val set_on_broadcast_mention : (broadcast_delivery -> unit) -> unit

val broadcast : ?trace_context:string ->
           ?msg_type:string ->
           Workspace_utils_backend_setup.config ->
           from_agent:string -> content:string ->
           (broadcast_delivery, broadcast_error) result

module For_testing : sig
  (** Replace the handler and return the prior one. Test isolation only. *)
  val replace_on_broadcast_mention :
    (broadcast_delivery -> unit) -> broadcast_delivery -> unit

  (** Replace the authoritative write boundary and return the prior function.
      Tests use this to prove failure fanout without depending on filesystem
      permission behavior. *)
  val replace_write_json_commit :
    (Workspace_utils_backend_setup.config ->
     string ->
     Yojson.Safe.t ->
     (Workspace_utils.write_json_commit, string) result) ->
    (Workspace_utils_backend_setup.config ->
     string ->
     Yojson.Safe.t ->
     (Workspace_utils.write_json_commit, string) result)
end
