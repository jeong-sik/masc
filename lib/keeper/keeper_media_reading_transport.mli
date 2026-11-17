(** Complete transport observations owned by one media original. No execution,
    storage, approval or retry occurs in this codec. *)
type t
val mime_type : string
val capture : Keeper_sandbox_remote.execution_observation -> (t, string) result
val bytes : t -> string
val observation : t -> Keeper_sandbox_remote.execution_observation
val restore_bytes : string -> (t, string) result
(** Exact canonical ordinary JSON. Observed values retain the complete typed
    trailer and receipt, including signal, syscall observations and shim error.
    This is not a raw stderr transcript. Blob contents are opaque to GC. *)
val request_not_sent : t -> bool

type link
val link : original:Keeper_media_reading_original.t -> captured:t ->
  Tool_output.artifact_ref -> (link, string) result
val artifact : link -> Tool_output.artifact_ref
val link_to_json : link -> Yojson.Safe.t
val link_of_json : original:Keeper_media_reading_original.t -> Yojson.Safe.t ->
  (link, string) result
val link_request_not_sent : link -> bool
val check_value : link -> t -> (unit, string) result
(** A link binds the exact original request/body/execution identity and the
    normalized blob reference. Its no-send classification is derived only
    from the captured observation and checked again when loading the blob. *)
val validate_progress : original:Keeper_media_reading_original.t ->
  Lane_addon_request_progress.t -> (link option, string) result
(** Reject a later dispatch on this same observed invocation, a reply paired
    with Request_not_sent, or possibly-sent evidence before dispatch. No link
    means no retained transport evidence, never proof of absence or retry. *)
