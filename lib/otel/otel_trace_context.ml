(** OTel Trace Context — W3C traceparent propagation for MASC transport.

    Bridges the [Opentelemetry.W3C_trace_context] API to MASC's JSON-based
    message passing (broadcast, SSE) and HTTP headers.

    All functions are safe to call when OTel is disabled — they return [None]
    or empty values without side effects.

    Boundary: this module does NOT touch [Otel_spans], [Otel_dispatch_hook],
    or Prometheus metrics. It only converts between W3C traceparent strings
    and the library's typed representations.

    @since 2.105.0 *)

module OT = Opentelemetry

(** {2 Types} *)

(** Parsed W3C trace context suitable for JSON serialization. *)
type t =
  { traceparent : string
    (** Full W3C traceparent value, e.g. "00-<trace_id>-<parent_id>-01" *)
  ; trace_id : OT.Trace_id.t
  ; parent_id : OT.Span_id.t
  ; sampled : bool
  }

(** {2 Parsing — from external sources into MASC} *)

(** Parse a W3C traceparent header value.
    Returns [None] on invalid format (rather than raising).

    Format: [{version}-{trace_id}-{parent_id}-{trace_flags}]
    - version: 2 hex chars (must be "00" for current spec)
    - trace_id: 32 hex chars (16 bytes), all-zero is invalid
    - parent_id: 16 hex chars (8 bytes), all-zero is invalid
    - trace_flags: 2 hex chars, bit 0 = sampled *)
let parse (s : string) : t option =
  let trimmed = String.trim s in
  if String.length trimmed < 55
  then None
  else (
    match OT.Span_ctx.of_w3c_trace_context (Bytes.of_string trimmed) with
    | Ok span_ctx ->
      let trace_id = OT.Span_ctx.trace_id span_ctx in
      let parent_id = OT.Span_ctx.parent_id span_ctx in
      (* W3C spec: all-zero trace_id or parent_id are invalid. *)
      if not (OT.Trace_id.is_valid trace_id)
      then None
      else if not (OT.Span_id.is_valid parent_id)
      then None
      else (
        let sampled = OT.Span_ctx.sampled span_ctx in
        Some { traceparent = trimmed; trace_id; parent_id; sampled })
    | Error _ -> None)
;;

(** {2 Generation — from MASC ambient context to external format} *)

(** Generate a W3C traceparent string from typed components. *)
let to_traceparent
      ~(trace_id : OT.Trace_id.t)
      ~(parent_id : OT.Span_id.t)
      ?(sampled = true)
      ()
  : string
  =
  let span_ctx = OT.Span_ctx.make ~sampled ~trace_id ~parent_id () in
  Bytes.to_string (OT.Span_ctx.to_w3c_trace_context span_ctx)
;;

(** Capture the current ambient trace context as a traceparent string.
    Returns [None] when OTel is disabled or no active span exists. *)
let from_ambient () : string option =
  if not Otel_config.enabled
  then None
  else (
    match OT.Scope.get_ambient_scope () with
    | Some scope ->
      let span_ctx = OT.Scope.to_span_ctx scope in
      let trace_id = OT.Span_ctx.trace_id span_ctx in
      let parent_id = OT.Span_ctx.parent_id span_ctx in
      if OT.Trace_id.is_valid trace_id && OT.Span_id.is_valid parent_id
      then
        Some
          (to_traceparent ~trace_id ~parent_id ~sampled:(OT.Span_ctx.sampled span_ctx) ())
      else None
    | None -> None)
;;

(** {2 Propagation — advance parent_id for downstream spans} *)

(** Create a new traceparent for a child span.
    Keeps the same trace_id, generates a fresh parent_id (span_id).
    This is what W3C spec requires: each hop updates parent_id. *)
let propagate (ctx : t) : t =
  let new_parent_id = OT.Span_id.create () in
  let traceparent =
    to_traceparent ~trace_id:ctx.trace_id ~parent_id:new_parent_id ~sampled:ctx.sampled ()
  in
  { traceparent
  ; trace_id = ctx.trace_id
  ; parent_id = new_parent_id
  ; sampled = ctx.sampled
  }
;;

(** {2 JSON helpers — for MASC broadcast/SSE messages} *)

(** Extract trace_context field from a JSON object.
    Returns [None] if field is absent or null. *)
let of_json (json : Yojson.Safe.t) : t option =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "trace_context" fields with
     | Some (`String s) -> parse s
     | _ -> None)
  | _ -> None
;;

(** Inject trace_context field into a JSON association list.
    No-op (returns input unchanged) when [traceparent] is [None]. *)
let inject_json (fields : (string * Yojson.Safe.t) list) (traceparent : string option)
  : (string * Yojson.Safe.t) list
  =
  match traceparent with
  | Some tp -> ("trace_context", `String tp) :: fields
  | None -> fields
;;

(** {2 HTTP header helpers} *)

(** Header name per W3C spec (lowercase). *)
let header_name = "traceparent"

(** Extract traceparent from HTTP headers (case-insensitive lookup).
    W3C spec: if multiple traceparent headers exist, discard all. *)
let of_headers (headers : (string * string) list) : t option =
  let lower_name = header_name in
  let matches =
    List.filter_map
      (fun (k, v) -> if String.lowercase_ascii k = lower_name then Some v else None)
      headers
  in
  match matches with
  | [ single ] -> parse single
  | _ -> None (* absent or multiple → invalid per W3C spec *)
;;

(** Build a traceparent header pair for outbound HTTP requests. *)
let to_header (ctx : t) : string * string = header_name, ctx.traceparent
