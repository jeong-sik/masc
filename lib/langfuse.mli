(** Langfuse Integration - LLM Observability Platform.

    Traces LLM calls via the Langfuse API. Reads configuration from
    environment variables:
    - [LANGFUSE_SECRET_KEY]: API secret key
    - [LANGFUSE_PUBLIC_KEY]: API public key
    - [LANGFUSE_HOST]: Langfuse server URL (default: [http://localhost:3100]) *)

(** {1 Configuration} *)

(** Langfuse configuration loaded from environment. *)
type config = {
  secret_key : string;
  public_key : string;
  host : string;
  enabled : bool;
}

(** Whether Langfuse tracing is enabled (both keys present). *)
val is_enabled : unit -> bool

(** {1 Trace Types} *)

(** A trace represents a complete chain execution. *)
type trace = {
  trace_id : string;
  name : string;
  mutable metadata : (string * string) list;
  started_at : float;
}

(** A generation represents a single LLM call within a trace. *)
type generation = {
  gen_id : string;
  trace_id : string;
  name : string;
  model : string;
  input : string;
  mutable output : string option;
  mutable usage : (int * int * int) option;
  started_at : float;
  mutable ended_at : float option;
  mutable status : [ `Running | `Success | `Error of string ];
}

(** A span represents a generic timed operation within a trace. *)
type span = {
  span_id : string;
  trace_id : string;
  name : string;
  mutable metadata : (string * string) list;
  started_at : float;
  mutable ended_at : float option;
}

(** {1 Trace Lifecycle} *)

(** Create a new trace. Sends the trace creation event to Langfuse. *)
val create_trace :
  name:string -> ?metadata:(string * string) list -> unit -> trace

(** End a trace by sending its final metadata to Langfuse. *)
val end_trace : trace -> unit

(** {1 Generation Lifecycle} *)

(** Create a generation (LLM call record) within a trace. *)
val create_generation :
  trace:trace -> name:string -> model:string -> input:string -> unit ->
  generation

(** End a generation with output and token usage counts.
    @param output The LLM response text.
    @param prompt_tokens Number of prompt tokens consumed.
    @param completion_tokens Number of completion tokens generated. *)
val end_generation :
  generation ->
  output:string ->
  prompt_tokens:int ->
  completion_tokens:int ->
  unit

(** Mark a generation as failed with an error message. *)
val error_generation : generation -> message:string -> unit

(** {1 Span Lifecycle} *)

(** Create a span (timed operation) within a trace. *)
val create_span :
  trace:trace -> name:string -> ?metadata:(string * string) list -> unit ->
  span

(** End a span, recording its end timestamp. *)
val end_span : span -> unit

(** {1 High-Level Wrappers} *)

(** Wrap an LLM call with tracing. The function [f] returns
    [(output, prompt_tokens, completion_tokens)]. On exception, the
    generation is marked as error and the exception is re-raised. *)
val trace_model :
  trace:trace ->
  name:string ->
  model:string ->
  input:string ->
  (unit -> string * int * int) ->
  string

(** Wrap an operation with a span. On exception, the span is ended
    and the exception is re-raised. *)
val trace_span :
  trace:trace ->
  name:string ->
  ?metadata:(string * string) list ->
  (unit -> 'a) ->
  'a

(** {1 Status} *)

(** Human-readable status string indicating whether Langfuse is enabled. *)
val status : unit -> string
