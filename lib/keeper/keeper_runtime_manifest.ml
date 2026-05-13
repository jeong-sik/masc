(** Durable per-turn decision manifest for keeper runtime diagnosis. *)

type event_kind =
  | Turn_started
  | Phase_gate_decided
  | Cascade_routed
  | Pre_dispatch_blocked
  | Tool_surface_selected
  | Provider_lane_resolved
  | Provider_attempt_started
  | Provider_attempt_finished
  | Context_injected
  | Context_compacted
  | State_snapshot_sidecar_saved
  | Event_bus_correlated
  | Memory_injected
  | Memory_flushed
  | Checkpoint_loaded
  | Checkpoint_saved
  | Receipt_appended
  | Turn_finished

type links = {
  receipt_path : string option;
  checkpoint_path : string option;
  tool_call_log_path : string option;
}

type t = {
  schema_version : int;
  ts : string;
  keeper_name : string;
  agent_name : string option;
  trace_id : string;
  generation : int option;
  keeper_turn_id : int option;
  oas_turn_count : int option;
  event : event_kind;
  cascade_name : string option;
  provider_kind : string option;
  model_id : string option;
  status : string;
  decision : Yojson.Safe.t;
  links : links;
}

type turn_context = {
  manifest_keeper_name : string;
  manifest_agent_name : string option;
  manifest_trace_id : string;
  manifest_generation : int option;
  manifest_keeper_turn_id : int option;
}

let schema_version = 1

let all_event_kinds =
  [
    Turn_started;
    Phase_gate_decided;
    Cascade_routed;
    Pre_dispatch_blocked;
    Tool_surface_selected;
    Provider_lane_resolved;
    Provider_attempt_started;
    Provider_attempt_finished;
    Context_injected;
    Context_compacted;
    State_snapshot_sidecar_saved;
    Event_bus_correlated;
    Memory_injected;
    Memory_flushed;
    Checkpoint_loaded;
    Checkpoint_saved;
    Receipt_appended;
    Turn_finished;
  ]

let event_kind_to_string = function
  | Turn_started -> "turn_started"
  | Phase_gate_decided -> "phase_gate_decided"
  | Cascade_routed -> "cascade_routed"
  | Pre_dispatch_blocked -> "pre_dispatch_blocked"
  | Tool_surface_selected -> "tool_surface_selected"
  | Provider_lane_resolved -> "provider_lane_resolved"
  | Provider_attempt_started -> "provider_attempt_started"
  | Provider_attempt_finished -> "provider_attempt_finished"
  | Context_injected -> "context_injected"
  | Context_compacted -> "context_compacted"
  | State_snapshot_sidecar_saved -> "state_snapshot_sidecar_saved"
  | Event_bus_correlated -> "event_bus_correlated"
  | Memory_injected -> "memory_injected"
  | Memory_flushed -> "memory_flushed"
  | Checkpoint_loaded -> "checkpoint_loaded"
  | Checkpoint_saved -> "checkpoint_saved"
  | Receipt_appended -> "receipt_appended"
  | Turn_finished -> "turn_finished"

let event_kind_of_string = function
  | "turn_started" -> Some Turn_started
  | "phase_gate_decided" -> Some Phase_gate_decided
  | "cascade_routed" -> Some Cascade_routed
  | "pre_dispatch_blocked" -> Some Pre_dispatch_blocked
  | "tool_surface_selected" -> Some Tool_surface_selected
  | "provider_lane_resolved" -> Some Provider_lane_resolved
  | "provider_attempt_started" -> Some Provider_attempt_started
  | "provider_attempt_finished" -> Some Provider_attempt_finished
  | "context_injected" -> Some Context_injected
  | "context_compacted" -> Some Context_compacted
  | "state_snapshot_sidecar_saved" -> Some State_snapshot_sidecar_saved
  | "event_bus_correlated" -> Some Event_bus_correlated
  | "memory_injected" -> Some Memory_injected
  | "memory_flushed" -> Some Memory_flushed
  | "checkpoint_loaded" -> Some Checkpoint_loaded
  | "checkpoint_saved" -> Some Checkpoint_saved
  | "receipt_appended" -> Some Receipt_appended
  | "turn_finished" -> Some Turn_finished
  | _ -> None

let safe_segment value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (function
      | '/' | '\\' | ':' | '\000' -> Buffer.add_char buf '_'
      | c -> Buffer.add_char buf c)
    value;
  let sanitized = Buffer.contents buf |> String.trim in
  if String.equal sanitized "" then
    "unknown"
  else
    sanitized

let make ?(ts = Masc_domain.now_iso ()) ~keeper_name ?agent_name ~trace_id
    ?generation ?keeper_turn_id ?oas_turn_count ~event ?cascade_name
    ?provider_kind ?model_id ?(status = "ok") ?(decision = `Assoc [])
    ?receipt_path ?checkpoint_path ?tool_call_log_path () =
  {
    schema_version;
    ts;
    keeper_name;
    agent_name;
    trace_id;
    generation;
    keeper_turn_id;
    oas_turn_count;
    event;
    cascade_name;
    provider_kind;
    model_id;
    status;
    decision;
    links = { receipt_path; checkpoint_path; tool_call_log_path };
  }

let make_for_context ctx ~event ?oas_turn_count ?cascade_name ?provider_kind
    ?model_id ?status ?decision ?receipt_path ?checkpoint_path
    ?tool_call_log_path () =
  make ~keeper_name:ctx.manifest_keeper_name
    ?agent_name:ctx.manifest_agent_name ~trace_id:ctx.manifest_trace_id
    ?generation:ctx.manifest_generation
    ?keeper_turn_id:ctx.manifest_keeper_turn_id ?oas_turn_count ~event
    ?cascade_name ?provider_kind ?model_id ?status ?decision ?receipt_path
    ?checkpoint_path ?tool_call_log_path ()

let json_of_string_opt = function
  | None -> `Null
  | Some value -> `String value

let json_of_int_opt = function
  | None -> `Null
  | Some value -> `Int value

let links_to_json links =
  `Assoc
    [
      ("receipt_path", json_of_string_opt links.receipt_path);
      ("checkpoint_path", json_of_string_opt links.checkpoint_path);
      ("tool_call_log_path", json_of_string_opt links.tool_call_log_path);
    ]

let to_json manifest =
  `Assoc
    [
      ("schema_version", `Int manifest.schema_version);
      ("ts", `String manifest.ts);
      ("keeper_name", `String manifest.keeper_name);
      ("agent_name", json_of_string_opt manifest.agent_name);
      ("trace_id", `String manifest.trace_id);
      ("generation", json_of_int_opt manifest.generation);
      ("keeper_turn_id", json_of_int_opt manifest.keeper_turn_id);
      ("oas_turn_count", json_of_int_opt manifest.oas_turn_count);
      ("event", `String (event_kind_to_string manifest.event));
      ("cascade_name", json_of_string_opt manifest.cascade_name);
      ("provider_kind", json_of_string_opt manifest.provider_kind);
      ("model_id", json_of_string_opt manifest.model_id);
      ("status", `String manifest.status);
      ("decision", manifest.decision);
      ("links", links_to_json manifest.links);
    ]

let field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field %S" key)

let required_string key fields =
  match field key fields with
  | Ok (`String value) -> Ok value
  | Ok _ -> Error (Printf.sprintf "field %S must be a string" key)
  | Error _ as err -> err

let required_int key fields =
  match field key fields with
  | Ok (`Int value) -> Ok value
  | Ok _ -> Error (Printf.sprintf "field %S must be an int" key)
  | Error _ as err -> err

let optional_string key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "field %S must be a string or null" key)

let optional_int key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "field %S must be an int or null" key)

let links_of_json = function
  | `Assoc fields -> (
      match optional_string "receipt_path" fields with
      | Error _ as err -> err
      | Ok receipt_path -> (
          match optional_string "checkpoint_path" fields with
          | Error _ as err -> err
          | Ok checkpoint_path -> (
              match optional_string "tool_call_log_path" fields with
              | Error _ as err -> err
              | Ok tool_call_log_path ->
                  Ok { receipt_path; checkpoint_path; tool_call_log_path })))
  | _ -> Error "field \"links\" must be an object"

let of_json = function
  | `Assoc fields -> (
      match required_int "schema_version" fields with
      | Error _ as err -> err
      | Ok parsed_schema_version ->
          if parsed_schema_version <> schema_version then
            Error
              (Printf.sprintf "unsupported schema_version: %d"
                 parsed_schema_version)
          else
            let ( >>= ) result f = match result with Ok value -> f value | Error _ as err -> err in
            required_string "ts" fields >>= fun ts ->
            required_string "keeper_name" fields >>= fun keeper_name ->
            optional_string "agent_name" fields >>= fun agent_name ->
            required_string "trace_id" fields >>= fun trace_id ->
            optional_int "generation" fields >>= fun generation ->
            optional_int "keeper_turn_id" fields >>= fun keeper_turn_id ->
            optional_int "oas_turn_count" fields >>= fun oas_turn_count ->
            required_string "event" fields >>= fun event_string ->
            (match event_kind_of_string event_string with
            | None -> Error (Printf.sprintf "unknown event: %S" event_string)
            | Some event -> Ok event)
            >>= fun event ->
            optional_string "cascade_name" fields >>= fun cascade_name ->
            optional_string "provider_kind" fields >>= fun provider_kind ->
            optional_string "model_id" fields >>= fun model_id ->
            required_string "status" fields >>= fun status ->
            field "decision" fields >>= fun decision ->
            field "links" fields >>= fun links_json ->
            links_of_json links_json >>= fun links ->
            Ok
              {
                schema_version;
                ts;
                keeper_name;
                agent_name;
                trace_id;
                generation;
                keeper_turn_id;
                oas_turn_count;
                event;
                cascade_name;
                provider_kind;
                model_id;
                status;
                decision;
                links;
              })
  | _ -> Error "manifest row must be a JSON object"

let dated_jsonl_today_path base_dir =
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month = Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) in
  let day = Printf.sprintf "%02d.jsonl" tm.tm_mday in
  Filename.concat (Filename.concat base_dir month) day

let execution_receipt_path_for_today config ~keeper_name =
  Keeper_types_support.keeper_execution_receipt_store config keeper_name
  |> Dated_jsonl.base_dir
  |> dated_jsonl_today_path

let base_dir config ~keeper_name =
  Filename.concat
    (Filename.concat (Keeper_types_support.keeper_dir_ config) keeper_name)
    "runtime-manifests"

let path_for_trace config ~keeper_name ~trace_id =
  Filename.concat (base_dir config ~keeper_name)
    (safe_segment trace_id ^ ".jsonl")

let append_to_path path manifest =
  try
    let dir = Filename.dirname path in
    Keeper_types_support.mkdir_p dir;
    Keeper_types_support.append_jsonl_line path (to_json manifest);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

let append config manifest =
  append_to_path
    (path_for_trace config ~keeper_name:manifest.keeper_name
       ~trace_id:manifest.trace_id)
    manifest

let append_best_effort ?(site = "runtime_manifest") config manifest =
  match append config manifest with
  | Ok () -> ()
  | Error msg ->
      let masc_root = Coord.masc_root_dir config in
      (try
         Telemetry_coverage_gap.record
           ~masc_root
           ~source:"runtime_manifest"
           ~producer:site
           ~durable_store:
             (base_dir config ~keeper_name:manifest.keeper_name)
           ~dashboard_surface:"masc-trace/runtime-manifests"
           ~stale_reason:"runtime_manifest_append_failed"
           ~keeper_name:manifest.keeper_name
           ~trace_id:manifest.trace_id
           ~error:msg
           ()
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Keeper.warn
           "keeper:%s runtime_manifest coverage-gap append failed site=%s \
            trace_id=%s event=%s: %s"
           manifest.keeper_name site manifest.trace_id
           (event_kind_to_string manifest.event)
           (Printexc.to_string exn));
      Log.Keeper.warn
        "keeper:%s runtime_manifest append failed site=%s trace_id=%s event=%s: %s"
        manifest.keeper_name site manifest.trace_id
        (event_kind_to_string manifest.event)
        msg

let read_rows_from_path path =
  try
    let rows =
      Fs_compat.fold_jsonl_lines
        ~init:[]
        ~f:(fun acc ~line_no:_ json ->
          match of_json json with
          | Ok row -> row :: acc
          | Error _ -> acc)
        path
      |> List.rev
    in
    Ok rows
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printexc.to_string exn)

let last_unfinished_provider_attempt config (ctx : turn_context) =
  let path =
    path_for_trace config ~keeper_name:ctx.manifest_keeper_name
      ~trace_id:ctx.manifest_trace_id
  in
  match read_rows_from_path path with
  | Error msg -> Error msg
  | Ok rows ->
    let same_turn row =
      match ctx.manifest_keeper_turn_id with
      | None -> true
      | Some turn -> row.keeper_turn_id = Some turn
    in
    let pending =
      List.fold_left
        (fun pending row ->
           if not (same_turn row) then
             pending
           else
             match row.event with
             | Provider_attempt_started -> Some row
             | Provider_attempt_finished -> None
             | _ -> pending)
        None
        rows
    in
    Ok pending

let append_unfinished_provider_attempt_finished_best_effort
      ?(site = "runtime_manifest_unfinished_provider_terminal")
      config
      ctx
      ~status
      ~error
      ?exception_kind
      ()
  =
  match last_unfinished_provider_attempt config ctx with
  | Error msg ->
    Log.Keeper.warn
      "keeper:%s runtime_manifest unfinished provider scan failed site=%s trace_id=%s: %s"
      ctx.manifest_keeper_name site ctx.manifest_trace_id msg
  | Ok None -> ()
  | Ok (Some started) ->
    let inherited_fields =
      match started.decision with
      | `Assoc fields -> fields
      | _ -> []
    in
    let terminal_fields =
      [
        ( "repair_reason",
          `String "outer_timeout_or_cancellation_interrupted_provider_attempt" );
        ("matched_started_ts", `String started.ts);
        ("matched_started_status", `String started.status);
        ("error", `String error);
      ]
    in
    let terminal_fields =
      match exception_kind with
      | None -> terminal_fields
      | Some kind -> ("exception_kind", `String kind) :: terminal_fields
    in
    make_for_context ctx ~event:Provider_attempt_finished
      ?cascade_name:started.cascade_name
      ?provider_kind:started.provider_kind
      ?model_id:started.model_id
      ~status
      ~decision:(`Assoc (inherited_fields @ terminal_fields))
      ()
    |> append_best_effort ~site config
