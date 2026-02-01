(** Trace - Structured tracing for multi-agent observability *)

type span_status = Ok | Error of string

val show_span_status : span_status -> string
val equal_span_status : span_status -> span_status -> bool

type span = {
  trace_id: string;
  span_id: string;
  parent_id: string option;
  operation: string;
  agent: string;
  start_time: float;
  mutable end_time: float option;
  mutable status: span_status;
  mutable attributes: (string * string) list;
  lamport_start: int;
  mutable lamport_end: int option;
}

val start_span :
  ?parent:span ->
  ?trace_id:string ->
  operation:string ->
  agent:string ->
  unit -> span

val end_span : ?status:span_status -> span -> unit
val set_attribute : span -> string -> string -> unit

val record_recv : remote_time:int -> int
val current_lamport_time : unit -> int

val span_to_json : span -> Yojson.Safe.t
val export_trace : string -> Yojson.Safe.t list
val export_recent : ?limit:int -> unit -> Yojson.Safe.t

val spans_by_agent : string -> span list
val clear : unit -> unit
