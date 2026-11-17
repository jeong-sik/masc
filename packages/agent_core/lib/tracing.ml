(** Tracing / Observability module.
    Defines a TRACER module type and two built-in implementations:
    - Null_tracer: zero-allocation no-op (default)
    - Fmt_tracer: stderr output for development/debugging

    Uses first-class modules for runtime tracer selection. *)

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
  }

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
  val with_span : span_attrs -> (unit -> 'a) -> 'a
end

module Null_tracer : TRACER with type span = unit = struct
  type span = unit

  let start_span _attrs = ()
  let end_span () ~ok:_ = ()
  let add_event () _msg = ()
  let add_attrs () _attrs = ()
  let add_link () ~trace_id:_ ~span_id:_ = ()
  let trace_id () = None
  let span_id () = None
  let trace_context_headers () = []
  let with_span _attrs f = f ()
end

module Fmt_tracer : TRACER = struct
  type span =
    { attrs : span_attrs
    ; start_time : float
    }

  let span_kind_to_string = function
    | Agent_run -> "agent_run"
    | Api_call -> "api_call"
    | Tool_exec -> "tool_exec"
    | Hook_invoke -> "hook_invoke"
  ;;

  let start_span attrs =
    let start_time = Unix.gettimeofday () in
    Format.eprintf
      "[TRACE] START %s/%s (agent=%s turn=%d)@."
      (span_kind_to_string attrs.kind)
      attrs.name
      attrs.agent_name
      attrs.turn;
    { attrs; start_time }
  ;;

  let end_span span ~ok =
    let elapsed = Unix.gettimeofday () -. span.start_time in
    Format.eprintf
      "[TRACE] END %s/%s ok=%b elapsed=%.3fs@."
      (span_kind_to_string span.attrs.kind)
      span.attrs.name
      ok
      elapsed
  ;;

  let add_event span msg =
    Format.eprintf
      "[TRACE] EVENT %s/%s: %s@."
      (span_kind_to_string span.attrs.kind)
      span.attrs.name
      msg
  ;;

  let add_attrs span attrs =
    List.iter
      (fun (k, v) ->
         Format.eprintf
           "[TRACE] ATTR %s/%s: %s=%s@."
           (span_kind_to_string span.attrs.kind)
           span.attrs.name
           k
           v)
      attrs
  ;;

  let add_link span ~trace_id ~span_id =
    Format.eprintf
      "[TRACE] LINK %s/%s -> trace=%s span=%s@."
      (span_kind_to_string span.attrs.kind)
      span.attrs.name
      trace_id
      span_id
  ;;

  let trace_id _span = None
  let span_id _span = None
  let trace_context_headers () = []

  let with_span attrs f =
    let span = start_span attrs in
    match f () with
    | result ->
      end_span span ~ok:true;
      result
    | exception exn ->
      end_span span ~ok:false;
      raise exn
  ;;
end

type t = (module TRACER)

let null : t = (module Null_tracer)
let fmt : t = (module Fmt_tracer)

let trace_context_headers (type a) (tracer : t) =
  let module T = (val tracer : TRACER) in
  try T.trace_context_headers () with
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    []
;;

type 'a body_outcome =
  | Body_not_entered
  | Body_running
  | Body_returned of 'a
  | Body_raised of exn * Printexc.raw_backtrace

(** The wrapped operation owns its outcome. The tracer may fail before entry
    or after an effect has already happened; only the first case admits an
    untraced call. Keep the result and original exception/backtrace here,
    rather than trusting a tracer's cleanup to preserve them. *)
let with_span (type a) (tracer : t) (attrs : span_attrs) (f : t -> a) : a =
  let module T = (val tracer : TRACER) in
  let body_outcome = ref Body_not_entered in
  let body () =
    match !body_outcome with
    | Body_not_entered ->
      body_outcome := Body_running;
      (match f tracer with
       | result ->
         body_outcome := Body_returned result;
         result
       | exception exn ->
         let backtrace = Printexc.get_raw_backtrace () in
         body_outcome := Body_raised (exn, backtrace);
         Printexc.raise_with_backtrace exn backtrace)
    | Body_returned result -> result
    | Body_raised (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
    | Body_running -> invalid_arg "tracer re-entered a running span body"
  in
  match T.with_span attrs body with
  | result -> result
  | exception observer_exn ->
    let observer_backtrace = Printexc.get_raw_backtrace () in
    (match !body_outcome with
     | Body_not_entered ->
       Llm_provider.Reserved_exn.reraise_if_reserved observer_exn;
       body ()
     | Body_returned result ->
       Llm_provider.Reserved_exn.reraise_if_reserved observer_exn;
       result
     | Body_raised (body_exn, body_backtrace) ->
       if observer_exn != body_exn
       then Llm_provider.Reserved_exn.reraise_if_reserved observer_exn;
       Printexc.raise_with_backtrace body_exn body_backtrace
     | Body_running ->
       (* A tracer that returned control while its body is still running has
          no settled result to recover. Never launch the operation again. *)
       Printexc.raise_with_backtrace observer_exn observer_backtrace)
;;
