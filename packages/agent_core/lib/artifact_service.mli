(** Artifact service.

    @stability Evolving
    @since 0.93.1 *)

type descriptor = Runtime.artifact

val extension_of_kind : string -> string
val mime_type_of_kind : string -> string

val save_text_internal
  :  Runtime_store.t
  -> session_id:string
  -> name:string
  -> kind:string
  -> content:string
  -> (descriptor, Error.sdk_error) result

val persisted_path : descriptor -> (string, Error.sdk_error) result

val overwrite_text_internal
  :  descriptor
  -> content:string
  -> (unit, Error.sdk_error) result

val list
  :  ?session_root:string
  -> session_id:string
  -> unit
  -> (descriptor list, Error.sdk_error) result

val get_text
  :  ?session_root:string
  -> session_id:string
  -> artifact_id:string
  -> unit
  -> (string, Error.sdk_error) result
