(** Route OAS [Llm_provider.Diag] diagnostics into MASC's structured log.

    Without this, OAS provider-boundary diagnostics go to the default stderr
    sink and never reach [system_log_*.jsonl]. See #25148 / #25031. *)

(** [format_line ~ctx message] prefixes the OAS subsystem [ctx] onto [message]
    ([\[oas:http_client\] ...]) for attribution in the shared runtime log. *)
val format_line : ctx:string -> string -> string

(** [route ~debug ~info ~warn ~error level ~ctx message] dispatches to the
    emitter matching the OAS [level], passing the [format_line]-formatted
    message. Written as dependency injection so the mapping is testable without
    capturing global log output. *)
val route
  :  debug:(string -> unit)
  -> info:(string -> unit)
  -> warn:(string -> unit)
  -> error:(string -> unit)
  -> Llm_provider.Diag.level
  -> ctx:string
  -> string
  -> unit

(** Install the global OAS diagnostic sink, routing into [Log.Runtime] with the
    [Boundary] category. Call once at server boot, before any provider call. *)
val install : unit -> unit
