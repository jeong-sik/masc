(** OTel Trace Context — W3C traceparent propagation for MASC transport.

    Bridges [Opentelemetry.W3C_trace_context] to MASC JSON messages and HTTP.
    All functions are no-op safe when OTel is disabled.

    @since 2.105.0 *)

(** Parsed W3C trace context. *)
type t =
  { traceparent : string
  ; trace_id : Opentelemetry.Trace_id.t
  ; parent_id : Opentelemetry.Span_id.t
  ; sampled : bool
  }

(** {2 Parsing} *)

(** Parse a W3C traceparent header value. [None] on invalid format. *)
val parse : string -> t option

(** {2 Generation} *)

(** Generate a W3C traceparent string from typed components. *)
val to_traceparent
  :  trace_id:Opentelemetry.Trace_id.t
  -> parent_id:Opentelemetry.Span_id.t
  -> ?sampled:bool
  -> unit
  -> string

(** Capture current ambient trace context as a traceparent string.
    [None] when OTel is disabled or no active span. *)
val from_ambient : unit -> string option

(** {2 Propagation} *)

(** Create a child context: same trace_id, fresh parent_id. *)
val propagate : t -> t

(** {2 JSON helpers} *)

(** Extract [trace_context] field from a JSON object. *)
val of_json : Yojson.Safe.t -> t option

(** Inject [trace_context] field into JSON assoc list. No-op when [None]. *)
val inject_json
  :  (string * Yojson.Safe.t) list
  -> string option
  -> (string * Yojson.Safe.t) list

(** {2 HTTP header helpers} *)

(** ["traceparent"] *)
val header_name : string

(** Extract traceparent from HTTP headers (case-insensitive). *)
val of_headers : (string * string) list -> t option

(** Build [(header_name, traceparent)] pair for outbound HTTP. *)
val to_header : t -> string * string
