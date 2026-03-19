(** Trace - Structured tracing for multi-agent observability

    Provides OpenTelemetry-compatible span tracking with Lamport timestamps
    for causal ordering across agents.

    Key concepts:
    - Trace: A complete interaction flow (may span multiple agents)
    - Span: A single operation within a trace
    - Lamport time: Causal ordering independent of wall clock
*)

(** Global Lamport clock shared by all spans *)
let global_clock = Lamport.create ()

(** Monotonic counter for ID uniqueness within the same millisecond *)
let id_counter = Atomic.make 0

(** Generate trace/span IDs *)
let generate_id prefix =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let seq = Atomic.fetch_and_add id_counter 1 in
  Printf.sprintf "%s-%d-%06x" prefix ts (seq land 0xFFFFFF)

(** Span status *)
type span_status = Ok | Error of string
[@@deriving show, eq]

(** A single operation span *)
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

(** In-memory span storage (bounded) *)
let max_spans = 1000
let spans : (string, span) Hashtbl.t = Hashtbl.create 64
let span_order : string Queue.t = Queue.create ()

let evict_if_needed () =
  while Hashtbl.length spans > max_spans do
    match Queue.pop span_order with
    | id -> Hashtbl.remove spans id
    | exception Queue.Empty -> ()
  done

(** Start a new span *)
let start_span ?parent ?trace_id ~operation ~agent () =
  let lamport_start = Lamport.tick global_clock in
  let span_id = generate_id "span" in
  let trace_id = match trace_id with
    | Some id -> id
    | None -> (match parent with
        | Some p -> p.trace_id
        | None -> generate_id "trace")
  in
  let parent_id = match parent with
    | Some p -> Some p.span_id
    | None -> None
  in
  let span = {
    trace_id;
    span_id;
    parent_id;
    operation;
    agent;
    start_time = Time_compat.now ();
    end_time = None;
    status = Ok;
    attributes = [];
    lamport_start;
    lamport_end = None;
  } in
  evict_if_needed ();
  Hashtbl.replace spans span_id span;
  Queue.push span_id span_order;
  span

(** End a span *)
let end_span ?(status = Ok) span =
  span.end_time <- Some (Time_compat.now ());
  span.status <- status;
  span.lamport_end <- Some (Lamport.tick global_clock)

(** Add attribute to a span *)
let set_attribute span key value =
  span.attributes <- (key, value) :: span.attributes

(** Record receiving a message with remote Lamport time *)
let record_recv ~remote_time =
  Lamport.recv global_clock ~remote_time

(** Get current Lamport time *)
let current_lamport_time () =
  Lamport.current global_clock

(** Export span to JSON *)
let span_to_json span =
  let base = [
    ("trace_id", `String span.trace_id);
    ("span_id", `String span.span_id);
    ("operation", `String span.operation);
    ("agent", `String span.agent);
    ("start_time", `Float span.start_time);
    ("lamport_start", `Int span.lamport_start);
    ("status", match span.status with
      | Ok -> `String "ok"
      | Error msg -> `Assoc [("error", `String msg)]);
  ] in
  let opt field = function
    | Some v -> [(field, v)]
    | None -> []
  in
  `Assoc (base
    @ opt "parent_id" (Option.map (fun s -> `String s) span.parent_id)
    @ opt "end_time" (Option.map (fun f -> `Float f) span.end_time)
    @ opt "lamport_end" (Option.map (fun i -> `Int i) span.lamport_end)
    @ (if span.attributes = [] then []
       else [("attributes", `Assoc (List.map (fun (k, v) -> (k, `String v)) span.attributes))]))

(** Export all spans for a trace *)
let export_trace trace_id =
  Hashtbl.fold (fun _ span acc ->
    if String.equal span.trace_id trace_id then
      span_to_json span :: acc
    else acc
  ) spans []

(** Export recent spans (sorted by lamport time) *)
let export_recent ?(limit=50) () =
  let all = Hashtbl.fold (fun _ span acc -> span :: acc) spans [] in
  let sorted = List.sort (fun a b ->
    Int.compare b.lamport_start a.lamport_start  (* newest first *)
  ) all in
  let limited = List.filteri (fun i _ -> i < limit) sorted in
  `List (List.map span_to_json limited)

(** Find spans by agent *)
let spans_by_agent agent =
  Hashtbl.fold (fun _ span acc ->
    if String.equal span.agent agent then span :: acc
    else acc
  ) spans []

(** Clear all spans (for testing) *)
let clear () =
  Hashtbl.clear spans;
  Queue.clear span_order;
  Lamport.reset global_clock;
  Atomic.set id_counter 0
