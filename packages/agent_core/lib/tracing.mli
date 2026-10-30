(** Tracing / Observability module.

    Defines a {!TRACER} module type and two built-in implementations:
    - {!Null_tracer}: zero-allocation no-op (default)
    - {!Fmt_tracer}: stderr output for development/debugging

    Uses first-class modules for runtime tracer selection.

    @stability Evolving
    @since 0.93.1 *)

(** {1 Types} *)

type span_kind =
  | Agent_run
  | Api_call
  | Tool_exec
  | Hook_invoke

type span_attrs =
  { kind : span_kind
  ; name : string
  ; agent_name : string
  ; turn : int
  ; extra : (string * string) list
  ; links : (string * string) list
    (** (trace_id, span_id) pairs for cross-trace linking. *)
  }

(** {1 Tracer Interface} *)

module type TRACER = sig
  type span

  val start_span : span_attrs -> span
  val end_span : span -> ok:bool -> unit
  val add_event : span -> string -> unit
  val add_attrs : span -> (string * string) list -> unit
  val add_link : span -> trace_id:string -> span_id:string -> unit
  val trace_id : span -> string option
  val span_id : span -> string option
  val trace_context_headers : unit -> (string * string) list

  (** Run [f] within a traced span.  This is the preferred entry point
      because the implementation can set up fiber-local context before
      [start_span] and tear it down after [end_span].  [end_span] is
      called on both normal return and exception, with [ok] set
      accordingly.  The exception is re-raised. *)
  val with_span : span_attrs -> (unit -> 'a) -> 'a
end

(** {1 Built-in Tracers} *)

module Null_tracer : TRACER with type span = unit
module Fmt_tracer : TRACER

(** {1 First-class Module API} *)

(** A first-class tracer module. *)
type t = (module TRACER)

(** No-op tracer (zero allocation). *)
val null : t

(** Stderr-printing tracer for development. *)
val fmt : t

(** Return outbound W3C trace context headers for the current active span,
    or [[]] when the tracer has no active context. *)
val trace_context_headers : t -> (string * string) list

(** Run [f] within a traced span.  Delegates to the tracer's
    [TRACER.with_span] so the implementation can manage fiber-local
    context.  [end_span] is called on both normal return and exception,
    with [ok] set accordingly.  The exception is re-raised. *)
val with_span : t -> span_attrs -> (t -> 'a) -> 'a
