(** Workspace broadcast — emit workspace-wide messages and the
    accompanying message-activity event. *)

open Masc_domain
open Workspace_utils

(** RFC-0061: closed variants for broadcast envelope observability. *)
type rewrite_reason =
  | Cache_invalidated of { task_id : string; status : string }
  | Task_cache_rewrite

type rewrite_event = {
  reason : rewrite_reason;
  module_name : string;
}

type msg_type_typed =
  | Broadcast
  | Cache_invalidated of { task_id : string; status : string }

val string_of_msg_type_typed : msg_type_typed -> string

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
           ?task_cache_invariant_checked:bool ->
           Workspace_utils_backend_setup.config ->
           from_agent:string -> content:string -> string
