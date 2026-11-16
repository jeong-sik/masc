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

  (** Run [f] synchronously within a traced span. Implementations call [f]
      once and return its result. The implementation can set up fiber-local context before
      [start_span] and tear it down after [end_span].  [end_span] is
      called on both normal return and exception, with [ok] set
      accordingly. The body's exception is re-raised. Use the module-level
      [Tracing.with_span] boundary to isolate failures of the tracer itself. *)
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
    or [[]] when the tracer has no active context or its observation fails.
    Reserved runtime exceptions still propagate. *)
val trace_context_headers : t -> (string * string) list

(** Run [f] within a traced span, preserving the operation's result and
    exception/backtrace when the tracer fails. A tracer failure before body
    entry runs [f] untraced; a failure after entry never replays the operation.
    Reserved runtime exceptions from the tracer still propagate.

    Delegates span context management to [TRACER.with_span]. Low-level tracer
    operations such as [TRACER.start_span] do not have this isolation boundary. *)
val with_span : t -> span_attrs -> (t -> 'a) -> 'a
