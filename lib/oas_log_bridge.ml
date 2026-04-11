(** Bridge between the OAS [agent_sdk] structured logger and the masc-mcp
    structured log ring / JSONL sink.

    OAS exposes a composable [Log.sink = record -> unit] with pluggable
    fields (S/I/F/B/J) and levels (Debug/Info/Warn/Error).  The global
    sink registry starts empty, so [Log.info] / [Log.warn] calls inside
    [agent_sdk] (e.g. [lib/agent/agent.ml]'s per-turn timing) are
    silently dropped when no host plugs in.

    This module provides a single sink that forwards every OAS record
    into [Log.emit] (the masc-mcp [masc_log] library, which is wrapped
    false and exposes [Log] as the top-level module) with:

    - level translated 1:1 (Debug → Debug, Info → Info, ...)
    - [module_name] prefixed with ["oas:"] to preserve provenance and
      keep oas records from colliding with masc-mcp's own Keeper /
      Server / Dashboard module names
    - [details] assembled from the record fields as a Yojson object so
      the existing JSONL sink (e.g. [~/.masc/logs/system_log_*.jsonl])
      captures every field as a first-class key

    No retry, no buffering — the sink is pure forwarding, so fiber
    concurrency safety is whatever [Log.emit] already provides.

    @since (feat) telemetry chain: oas#814 (base_url + 5xx dump) +
           oas#816 (per-turn timing) + this bridge *)

(** Convert an OAS field into a (key, Yojson.Safe.t) pair for the
    [details] object.  Mirrors [Agent_sdk.Log.field_to_json] but we
    build the pair inline to avoid pulling the helper through the
    library boundary. *)
let field_to_json (field : Agent_sdk.Log.field) : string * Yojson.Safe.t =
  match field with
  | Agent_sdk.Log.S (k, v) -> (k, `String v)
  | Agent_sdk.Log.I (k, v) -> (k, `Int v)
  | Agent_sdk.Log.F (k, v) -> (k, `Float v)
  | Agent_sdk.Log.B (k, v) -> (k, `Bool v)
  | Agent_sdk.Log.J (k, v) -> (k, v)

let level_to_masc (level : Agent_sdk.Log.level) : Log.level =
  match level with
  | Debug -> Log.Debug
  | Info -> Log.Info
  | Warn -> Log.Warn
  | Error -> Log.Error

(** Build the sink function.  Prefix the module name with ["oas:"] so a
    record emitted by [Agent_sdk.Log.create ~module_name:"agent"] lands
    as ["oas:agent"] in the masc-mcp log stream, distinct from any
    masc-mcp module called "agent". *)
let make_sink () : Agent_sdk.Log.sink =
 fun record ->
  let details =
    match record.fields with
    | [] -> None
    | fields -> Some (`Assoc (List.map field_to_json fields))
  in
  Log.emit (level_to_masc record.level)
    ~module_name:("oas:" ^ record.module_name)
    ?details
    record.message

(** Process-wide latch to make [install] idempotent.  Unlike
    [Llm_metric_bridge] which uses [set_global] (replacement semantics),
    [Agent_sdk.Log.add_sink] appends to a sink list, so a naive double
    call would forward every record twice.  Bootstrap is the only
    documented caller today, but test harnesses, in-process restarts,
    or a future supervisor reconnect could all re-enter bootstrap.
    One [Atomic.compare_and_set] closes the hole cheaply. *)
let installed = Atomic.make false

(** Install the bridge as a global OAS sink.  First call registers the
    sink; subsequent calls are no-ops and return cleanly.  Intended to
    be invoked exactly once during server bootstrap, before any keeper
    turn fires an LLM call. *)
let install () : unit =
  if Atomic.compare_and_set installed false true then
    Agent_sdk.Log.add_sink (make_sink ())
# trigger marker
