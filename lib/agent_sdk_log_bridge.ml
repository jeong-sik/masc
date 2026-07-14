(** Bridge between the OAS [agent_sdk] structured logger and the masc
    structured log ring / JSONL sink.

    OAS exposes a composable [Log.sink = record -> unit] with pluggable
    fields (S/I/F/B/J) and levels (Debug/Info/Warn/Error).  The global
    sink registry starts empty, so [Log.info] / [Log.warn] calls inside
    [agent_sdk] (e.g. [lib/agent/agent.ml]'s per-turn timing) are
    silently dropped when no host plugs in.

    This module provides a single sink that forwards every OAS record
    into [Log.emit] (the masc [masc_log] library, which is wrapped
    false and exposes [Log] as the top-level module) with:

    - level translated 1:1 (Debug → Debug, Info → Info, ...)
    - [module_name] prefixed with ["oas:"] to preserve provenance and
      keep oas records from colliding with masc's own Keeper /
      Server / Dashboard module names
    - [details] assembled from the record fields as a Yojson object so
      the existing JSONL sink (e.g. [<base_path>/.masc/logs/system_log_*.jsonl])
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
  | Agent_sdk.Log.Secret (k, _) -> (k, `String "[REDACTED]")

let details_of_fields (fields : Agent_sdk.Log.field list)
    : (string * Yojson.Safe.t) list =
  List.map field_to_json fields

let json_stringish = function
  | `String s ->
      let trimmed = String.trim s in
      if trimmed = "" then None else Some trimmed
  | `Int n -> Some (string_of_int n)
  | `Float f when Float.is_finite f ->
      Some
        (if Float.equal f (Float.of_int (int_of_float f)) then
           string_of_int (int_of_float f)
         else
           string_of_float f)
  | `Bool b -> Some (string_of_bool b)
  | _ -> None

let first_detail_label details keys =
  let rec find_key = function
    | [] -> None
    | key :: rest -> (
        match List.assoc_opt key details with
        | Some value -> (
            match json_stringish value with
            | Some _ as label -> label
            | None -> find_key rest)
        | None -> find_key rest)
  in
  find_key keys

let replace_first_placeholder message value =
  let len = String.length message in
  let rec loop idx =
    if idx + 1 >= len then
      message
    else if message.[idx] = '%'
            && (message.[idx + 1] = 's' || message.[idx + 1] = 'd')
    then
      String.sub message 0 idx ^ value
      ^ String.sub message (idx + 2) (len - idx - 2)
    else
      loop (idx + 1)
  in
  loop 0

let interpolate_printf_message message details =
  if not (String.contains message '%') then
    message
  else
    let replacements =
      [
        first_detail_label details [ "tool_name"; "tool" ];
        first_detail_label details [ "fixes" ];
        first_detail_label details [ "count" ];
        first_detail_label details [ "client_name" ];
        first_detail_label details [ "phase" ];
        first_detail_label details [ "request_id" ];
        first_detail_label details [ "session_id" ];
      ]
      |> List.filter_map Fun.id
    in
    List.fold_left replace_first_placeholder message replacements

let render_agent_tools_message ~message ~details =
  let detail_segments keys =
    keys
    |> List.filter_map (fun key ->
         match first_detail_label details [ key ] with
         | Some value -> Some (Printf.sprintf "%s=%s" key value)
         | None -> None)
  in
  match
    first_detail_label details [ "tool_name"; "tool" ],
    first_detail_label details [ "fixes"; "count" ]
  with
  | Some tool_name, Some fixes
    when String.equal message "correction_pipeline fixed tool input fields"
         || String.equal message
              "tool %s: correction_pipeline fixed %d field(s)" ->
      let detail =
        detail_segments
          [ "fields"
          ; "stages"
          ; "input_keys"
          ; "corrected_keys"
          ; "added_fields"
          ; "changed_fields"
          ]
      in
      Some
        (String.concat " "
           (Printf.sprintf "tool %s: correction_pipeline fixed %s field(s)"
              tool_name fixes
            :: detail))
  | _ -> None

let render_record_message (record : Agent_sdk.Log.record) : string =
  let details = details_of_fields record.fields in
  match record.module_name with
  | "agent_tools" -> (
      match render_agent_tools_message ~message:record.message ~details with
      | Some rendered -> rendered
      | None -> interpolate_printf_message record.message details)
  | _ -> interpolate_printf_message record.message details

let level_to_masc (level : Agent_sdk.Log.level) : Log.level =
  match level with
  | Debug -> Log.Debug
  | Info -> Log.Info
  | Warn -> Log.Warn
  | Error -> Log.Error

let field_value_to_human (json : Yojson.Safe.t) : string option =
  match json with
  | `String value when String.trim value <> "" -> Some value
  | `Int value -> Some (string_of_int value)
  | `Intlit value -> Some value
  | `Float value -> Some (Printf.sprintf "%.3f" value)
  | `Bool value -> Some (string_of_bool value)
  | _ -> None

let preferred_summary_keys message =
  match message with
  | "turn completed" | "turn started" ->
      [ "turn"; "max_turns"; "turn_duration_sec"; "elapsed_run_sec"; "model"; "stop" ]
  | "agent completed" | "agent started" ->
      [ "agent_name"; "agent"; "task_id"; "elapsed_s"; "input_tokens"; "output_tokens" ]
  | "tool completed" | "tool called" ->
      [ "agent_name"; "agent"; "tool_name"; "turn" ]
  | _ ->
      [ "agent_name"; "agent"; "task_id"; "turn"; "tool_name"; "model"; "stop" ]

let summarize_fields ~message (fields : Agent_sdk.Log.field list) : string list =
  let assoc = List.map field_to_json fields in
  preferred_summary_keys message
  |> List.filter_map (fun key ->
       match List.assoc_opt key assoc with
       | None -> None
       | Some value -> (
           match field_value_to_human value with
           | Some rendered -> Some (Printf.sprintf "%s=%s" key rendered)
           | None -> None))

let should_promote_warn_to_error (record : Agent_sdk.Log.record) =
  match record.level, record.module_name, record.message with
  | Warn, "agent_config", "MCP server failed" -> true
  | Warn, "agent_turn", "context_injector raised" -> true
  | _ -> false

let should_demote_info_to_debug (record : Agent_sdk.Log.record) =
  match record.level, record.module_name, record.message with
  | ( Info,
      "completion_contract",
      "tool_choice contract relaxed (provider does not support tool_choice)" ) ->
      true
  | _ -> false

let effective_level (record : Agent_sdk.Log.record) : Log.level =
  if should_promote_warn_to_error record then
    Log.Error
  else if should_demote_info_to_debug record then
    Log.Debug
  else
    level_to_masc record.level

let render_message_with_summary (record : Agent_sdk.Log.record) =
  let base_message = render_record_message record in
  if not (String.equal base_message record.message) then
    base_message
  else
    match summarize_fields ~message:record.message record.fields with
    | [] -> base_message
    | summary ->
        Printf.sprintf "%s %s" base_message (String.concat " " summary)

let emit_correction_pipeline_metric (record : Agent_sdk.Log.record) =
  match record.module_name with
  | "agent_tools" -> (
      let details = details_of_fields record.fields in
      match
        ( first_detail_label details [ "tool_name"; "tool" ],
          first_detail_label details [ "fixes"; "count" ] )
      with
      | Some tool_name, Some _fixes
        when String.equal record.message
               "correction_pipeline fixed tool input fields"
             || String.equal record.message
                  "tool %s: correction_pipeline fixed %d field(s)" ->
          Otel_metric_store.inc_counter
            Otel_metric_store.metric_oas_correction_pipeline_fixes_total
            ~labels:[ ("tool_name", tool_name) ]
            ()
      | _ -> ())
  | _ -> ()

(** Build the sink function.  Prefix the module name with ["oas:"] so a
    record emitted by [Agent_sdk.Log.create ~module_name:"agent"] lands
    as ["oas:agent"] in the masc log stream, distinct from any
    masc module called "agent". *)
let make_sink () : Agent_sdk.Log.sink =
 fun record ->
  emit_correction_pipeline_metric record;
  let message = render_message_with_summary record in
  let details =
    match record.fields with
    | [] -> None
    | fields -> Some (`Assoc (List.map field_to_json fields))
  in
  Log.emit (effective_level record)
    ~module_name:("oas:" ^ record.module_name)
    ?details
    message

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
