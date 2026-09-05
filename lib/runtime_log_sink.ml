(** Sink from the in-process agent core structured logger into the MASC
    structured log ring / JSONL sink.

    The agent core exposes a composable [Log.sink = record -> unit] with pluggable
    fields (S/I/F/B/J) and levels (Debug/Info/Warn/Error).  The global
    sink registry starts empty, so [Log.info] / [Log.warn] calls inside
    the core (e.g. [packages/agent_core/lib/agent/agent.ml]'s per-turn timing) are
    silently dropped when MASC does not install a sink.

    This module provides a single sink that forwards every core record
    into [Log.emit] (the masc [masc_log] library, which is wrapped
    false and exposes [Log] as the top-level module) with:

    - level translated 1:1 (Debug → Debug, Info → Info, ...)
    - [module_name] prefixed with ["agent_core:"] to preserve provenance and
      keep core records from colliding with MASC's own Keeper /
      Server / Dashboard module names
    - [details] assembled from the record fields as a Yojson object so
      the existing JSONL sink (e.g. [<base_path>/.masc/logs/system_log_*.jsonl])
      captures every field as a first-class key

    No retry, no buffering — the sink is pure forwarding, so fiber
    concurrency safety is whatever [Log.emit] already provides.

    @since (feat) telemetry chain: agent-core boundary (base_url + 5xx dump) +
           agent-core boundary (per-turn timing) + this bridge *)

(** Convert an agent-core field into a (key, Yojson.Safe.t) pair for the
    [details] object.  Delegates to [Agent_core.Log.field_to_json] for the
    shared arms, but keeps the masc ["[REDACTED]"] placeholder for
    [Secret]: the core helper renders ["<redacted>"] ([lib/log.mli]
    documents that contract), while every other masc redactor in this
    JSONL stream writes ["[REDACTED]"].  Mixing placeholders in one
    stream would break grep-ability, so the divergence is deliberate. *)
let field_to_json (field : Agent_core.Log.field) : string * Yojson.Safe.t =
  match field with
  | Agent_core.Log.Secret (k, _) -> (k, `String "[REDACTED]")
  | field -> Agent_core.Log.field_to_json field

let level_to_masc (level : Agent_core.Log.level) : Log.level =
  match level with
  | Debug -> Log.Debug
  | Info -> Log.Info
  | Warn -> Log.Warn
  | Error -> Log.Error

(* Rendered-line budget.  Every field also rides in [details] as JSON, so
   these caps only bound the human mirror; the record itself is never
   trimmed. *)
let max_rendered_value_bytes = 160
let max_rendered_fields = 16

(* Truncate on a UTF-8 character boundary and say so, so a cut value is
   never mistaken for the whole value.  Continuation bytes are 0b10xxxxxx;
   walking back off them keeps the prefix decodable. *)
let truncate_value value =
  let len = String.length value in
  if len <= max_rendered_value_bytes then value
  else begin
    let cut = ref max_rendered_value_bytes in
    while !cut > 0 && Char.code value.[!cut] land 0xC0 = 0x80 do
      decr cut
    done;
    Printf.sprintf "%s...(%dB)" (String.sub value 0 !cut) len
  end

(* A field the producer attached is rendered whatever its value: a key with a
   null value is a statement that the value is unset, and dropping it from the
   line would be the same omission this renderer exists to stop. Total, so a
   new [Agent_core.Log.field] arm has to be given a rendering here. *)
let render_scalar (json : Yojson.Safe.t) : string =
  match json with
  | `Null -> "null"
  | `String value -> value
  | `Int value -> string_of_int value
  | `Intlit value -> value
  | `Float value -> Printf.sprintf "%.3f" value
  | `Bool value -> string_of_bool value
  | composite -> Yojson.Safe.to_string composite

(* Quote whenever the raw form would break the [key=value] reading a log
   line invites: spaces, quotes, or an empty value. *)
let render_pair (key, json) =
  let value = truncate_value (render_scalar json) in
  let needs_quoting =
    String.equal value ""
    || String.exists (fun c -> c = ' ' || c = '"' || c = '\n' || c = '\t') value
  in
  Printf.sprintf
    "%s=%s"
    key
    (if needs_quoting then Printf.sprintf "%S" value else value)

(* The human line renders every field the producer attached, in the order it
   attached them.

   The projection this replaced kept a per-message allowlist of keys and fell
   back to a fixed guess for anything it did not recognise, which made the
   line lie by omission: [turn checkpoint persisted] carries [stage], [turn]
   and [messages] but only [turn] was in the fallback list, so the three
   checkpoint stages of one turn rendered as three identical lines (1,289 of
   them in the two hours to 2026-08-22T02:03Z); [pipeline stage failed]
   carries [stage] and [error] and rendered with neither; [tool not found]
   rendered without the tool name.  Selecting keys by matching on the message
   text also meant every new producer message silently fell into the guess. *)
let render_message (record : Agent_core.Log.record) : string =
  let rendered =
    List.filteri (fun index _ -> index < max_rendered_fields) record.fields
    |> List.map field_to_json
    |> List.map render_pair
  in
  let omitted = List.length record.fields - max_rendered_fields in
  let parts =
    if omitted > 0
    then rendered @ [ Printf.sprintf "(+%d more in details)" omitted ]
    else rendered
  in
  match parts with
  | [] -> record.message
  | parts -> Printf.sprintf "%s %s" record.message (String.concat " " parts)

(** Build the sink function.  Prefix the module name with ["agent_core:"] so a
    record emitted by [Agent_core.Log.create ~module_name:"agent"] lands
    as ["agent_core:agent"] in the masc log stream, distinct from any
    masc module called "agent". *)
let make_sink () : Agent_core.Log.sink =
 fun record ->
  let message = render_message record in
  let details =
    match record.fields with
    | [] -> None
    | fields -> Some (`Assoc (List.map field_to_json fields))
  in
  Log.emit (level_to_masc record.level)
    ~module_name:("agent_core:" ^ record.module_name)
    ?details
    message

(** Process-wide latch to make [install] idempotent.  Unlike
    [Llm_metric_bridge] which uses [set_global] (replacement semantics),
    [Agent_core.Log.add_sink] appends to a sink list, so a naive double
    call would forward every record twice.  Bootstrap is the only
    documented caller today, but test harnesses, in-process restarts,
    or a future supervisor reconnect could all re-enter bootstrap.
    One [Atomic.compare_and_set] closes the hole cheaply. *)
let installed = Atomic.make false

(** Install the adapter as the global agent-core sink. First call registers the
    sink; subsequent calls are no-ops and return cleanly.  Intended to
    be invoked exactly once during server bootstrap, before any keeper
    turn fires an LLM call. *)
let install () : unit =
  if Atomic.compare_and_set installed false true then
    Agent_core.Log.add_sink (make_sink ())
