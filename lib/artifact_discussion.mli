(** Durable discussion events share the draft's atomic commit. Thread views
    are derived, never a second persisted authority. *)
type command =
  | Comment of { position : Artifact_document_engine.selection; quote : string; body : string; proposal : string option }
  | Reply of { thread_id : string; body : string }
  | Resolve of string | Reopen of string | Accept of string | Reject of string
type request = { id : string; command : command }
type event = private
  { request : request; actor : string; at : string; applied : Artifact_document_engine.selection option }
type message = { id : string; actor : string; at : string; body : string }
type decision = Pending | Applied of event | Rejected of event
type thread =
  { id : string; position : Artifact_document_engine.selection; quote : string
  ; messages : message list; proposal : string option; decision : decision; resolved : bool }
val request_of_json : Yojson.Safe.t -> (request, string) result
val request_to_json : request -> Yojson.Safe.t
val events_of_json : Yojson.Safe.t -> (event list, string) result
val events_to_json : event list -> Yojson.Safe.t
val threads : event list -> (thread list, string) result
val thread_to_json : thread -> Yojson.Safe.t
val check : event list -> actor:string -> request -> (event option, string) result
val append : event list -> actor:string -> at:string -> request ->
  applied:Artifact_document_engine.selection option -> (event list, string) result
