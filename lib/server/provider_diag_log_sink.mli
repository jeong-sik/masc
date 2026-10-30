(** Route provider [Llm_provider.Diag] diagnostics into MASC's structured log.

    Without this, provider-boundary diagnostics go to the default stderr
    sink and never reach [system_log_*.jsonl]. See #25148 / #25031. *)

(** [format_line ~ctx message] prefixes the provider subsystem [ctx] onto [message]
    ([\[agent_core:http_client\] ...]) for attribution in the shared runtime log, then
    applies the provider layer's canonical diagnostic secret redaction. Custom sinks receive
    raw diagnostic messages, so this preserves the default sink's security
    boundary before durable persistence. *)
val format_line : ctx:string -> string -> string

(** [route ~debug ~info ~warn ~error level ~ctx message] dispatches to the
    emitter matching the provider [level], passing the [format_line]-formatted
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

(** Install the global provider diagnostic sink, routing into [Log.Runtime] with the
    [Boundary] category. Call once at server boot, before any provider call. *)
val install : unit -> unit
