(** Diagnostic sink for refused streaming wire frames.

    Agent Core does not read host environment variables directly. A host that
    wants refused SSE/NDJSON frames dumped installs a sink explicitly via
    {!set_refused_frame_sink} or scopes one via {!with_refused_frame_sink}. *)

(** A full refused frame for the optional diagnostic sink. [raw] is kept
    intact here; {!append_refused_frame_to_path} redacts it before writing and
    records whether its bytes changed. *)
type refused_frame =
  { wire_format : Http_client.provider_wire_format
  ; reason : string
  ; raw : string
  }

(** Append a redacted refused frame record to [path] (mode [0o600]).
    When [path] is empty, does nothing. [Sys_error] is ignored so diagnostic
    file failures do not replace the provider error; other exceptions propagate
    unchanged. *)
val append_refused_frame_to_path : path:string -> refused_frame -> unit

(** Install or clear the process-wide refused-frame diagnostic sink. *)
val set_refused_frame_sink : (refused_frame -> unit) option -> unit

(** Run [fn] with a fiber-local refused-frame sink override when running inside
    Eio, or temporarily overriding the process sink outside Eio. *)
val with_refused_frame_sink : (refused_frame -> unit) option -> (unit -> 'a) -> 'a

(** Deliver [frame] to the active refused-frame sink, if any. *)
val dump_refused_frame : refused_frame -> unit
