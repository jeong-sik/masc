(** Durable per-turn decision manifest for keeper runtime diagnosis.

    See the corresponding [mli] for the layered SSOT hierarchy. *)

include Keeper_runtime_manifest_types

type payload_role =
  | Model_input
  | Operator_evidence
  | Checkpoint
  | Memory_store

let payload_role_to_string = function
  | Model_input -> "model_input"
  | Operator_evidence -> "operator_evidence"
  | Checkpoint -> "checkpoint"
  | Memory_store -> "memory_store"

type source_clock =
  | Wall
  | Monotonic
  | Logical
  | Provider
  | Event_bus

let source_clock_to_string = function
  | Wall -> "wall"
  | Monotonic -> "monotonic"
  | Logical -> "logical"
  | Provider -> "provider"
  | Event_bus -> "agent_core_event_bus"

let source_clock_of_string = function
  | "wall" -> Some Wall
  | "monotonic" -> Some Monotonic
  | "logical" -> Some Logical
  | "provider" -> Some Provider
  | "agent_core_event_bus" -> Some Event_bus
  | _ -> None

let source_clock_of_event = function
  | Event_bus_correlated -> Event_bus
  | Provider_attempt_started
  | Provider_attempt_finished ->
    Provider
  | Context_injected
  | Context_compacted ->
    Logical
  | _ -> Wall

type logical_ordering = {
  parent_event_id : string option;
  caused_by : string option;
  logical_seq : int option;
}

module StringSet = Set_util.StringSet

let schema_version = 1
let manifest_file_suffix = ".jsonl"

type compaction_outcome =
  | Checkpoint_committed
  | Lifecycle_cleanup_failed_without_checkpoint

let compaction_outcome_key = "compaction_outcome"

let compaction_outcome_to_string = function
  | Checkpoint_committed -> "checkpoint_committed"
  | Lifecycle_cleanup_failed_without_checkpoint ->
    "lifecycle_cleanup_failed_without_checkpoint"
;;

let compaction_outcome_of_string = function
  | "checkpoint_committed" -> Some Checkpoint_committed
  | "lifecycle_cleanup_failed_without_checkpoint" ->
    Some Lifecycle_cleanup_failed_without_checkpoint
  | _ -> None
;;

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

let string_field_opt key value =
  match value with
  | Some value when String.trim value <> "" -> Some (key, `String value)
  | Some _ | None -> None

let int_field_opt key value =
  match value with
  | Some value -> Some (key, `Int value)
  | None -> None

let clock_refs ?edge_id ?lane ?source_clock ?observed_at ?started_at
    ?finished_at ?elapsed_ms ?provider_attempt_id ?tool_batch_id ?checkpoint_id
    ?compaction_id ?compaction_source ?event_bus_correlation_id
    ?event_bus_run_id ?parent_event_id ?caused_by ?logical_seq () =
  `Assoc
    (List.filter_map
       (fun value -> value)
       [
         string_field_opt "edge_id" edge_id;
         string_field_opt "lane" lane;
         string_field_opt "source_clock"
           (Option.map source_clock_to_string source_clock);
         string_field_opt "observed_at" observed_at;
         string_field_opt "started_at" started_at;
         string_field_opt "finished_at" finished_at;
         int_field_opt "elapsed_ms" elapsed_ms;
         string_field_opt "provider_attempt_id" provider_attempt_id;
         string_field_opt "tool_batch_id" tool_batch_id;
         string_field_opt "checkpoint_id" checkpoint_id;
         string_field_opt "compaction_id" compaction_id;
         string_field_opt "compaction_source" compaction_source;
         string_field_opt "event_bus_correlation_id" event_bus_correlation_id;
         string_field_opt "event_bus_run_id" event_bus_run_id;
         string_field_opt "parent_event_id" parent_event_id;
         string_field_opt "caused_by" caused_by;
         int_field_opt "logical_seq" logical_seq;
       ])

let extract_clock_refs decision =
  match decision with
  | `Assoc fields -> List.assoc_opt "clock_refs" fields
  | _ -> None

let source_clock_from_manifest manifest =
  match extract_clock_refs manifest.decision with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "source_clock" fields with
    | Some (`String s) -> source_clock_of_string s
    | _ -> None)
  | _ -> None

let logical_ordering manifest =
  match extract_clock_refs manifest.decision with
  | Some (`Assoc fields) ->
    let parent_event_id =
      match List.assoc_opt "parent_event_id" fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let caused_by =
      match List.assoc_opt "caused_by" fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let logical_seq =
      match List.assoc_opt "logical_seq" fields with
      | Some (`Int i) -> Some i
      | _ -> None
    in
    { parent_event_id; caused_by; logical_seq }
  | _ -> { parent_event_id = None; caused_by = None; logical_seq = None }

let comparable_for_latency a b =
  match source_clock_from_manifest a, source_clock_from_manifest b with
  | Some sc_a, Some sc_b ->
    if sc_a = sc_b then Ok sc_a
    else
      Error
        (Printf.sprintf
           "latency comparison invalid: source_clock mismatch (%s vs %s)"
           (source_clock_to_string sc_a)
           (source_clock_to_string sc_b))
  | None, _ ->
    Error "latency comparison invalid: manifest a has no source_clock"
  | _, None ->
    Error "latency comparison invalid: manifest b has no source_clock"

let clock_lane_of_event = function
  | Turn_started
  | Phase_gate_decided
  | Pre_dispatch_blocked
  | Receipt_appended
  | Turn_finished ->
    "keeper"
  | Runtime_routed
  | Runtime_execution_built
  | Runtime_completed
  | Runtime_failed
  | Provider_lane_resolved ->
    "masc_policy_runtime"
  | Provider_attempt_started
  | Provider_attempt_finished ->
    "provider"
  | Checkpoint_loaded
  | Checkpoint_saved ->
    "agent_core_agent"
  | Context_injected
  | Context_compacted
  | Event_bus_correlated ->
    "memory_context"

let turn_label ctx =
  match ctx.manifest_keeper_turn_id with
  | Some value -> string_of_int value
  | None -> "unknown"

let agent_core_turn_label = function
  | Some value -> string_of_int value
  | None -> "0"

let context_edge_id ctx event =
  Printf.sprintf "%s:keeper-%s:%s" ctx.manifest_trace_id (turn_label ctx)
    (event_kind_to_string event)

let context_tool_batch_id ctx ?agent_core_turn_count () =
  Printf.sprintf "%s:keeper-%s:tool-batch-agent_core-%s"
    ctx.manifest_trace_id (turn_label ctx) (agent_core_turn_label agent_core_turn_count)

let context_checkpoint_id ctx ?agent_core_turn_count () =
  Printf.sprintf "checkpoint:%s:agent_core-%s" ctx.manifest_trace_id
    (agent_core_turn_label agent_core_turn_count)

let context_compaction_id ctx ~source =
  Printf.sprintf "%s:keeper-%s:compaction-%s"
    ctx.manifest_trace_id (turn_label ctx) source

let clock_refs_for_context ctx ~event ?agent_core_turn_count ?elapsed_ms
    ?event_bus_correlation_id ?event_bus_run_id ?parent_event_id ?caused_by
    ?logical_seq ?compaction_source () =
  let tool_batch_id =
    match event with
    | Provider_lane_resolved ->
      Some (context_tool_batch_id ctx ?agent_core_turn_count ())
    | _ -> None
  in
  let checkpoint_id =
    match event with
    | Checkpoint_loaded
    | Checkpoint_saved ->
      Some (context_checkpoint_id ctx ?agent_core_turn_count ())
    | _ -> None
  in
  let compaction_id =
    match event with
    | Context_compacted ->
      Some (context_compaction_id ctx ~source:(Option.value ~default:"pre_dispatch" compaction_source))
    | Event_bus_correlated ->
      Some (context_compaction_id ctx ~source:(Option.value ~default:"event_bus" compaction_source))
    | _ -> None
  in
  clock_refs ~edge_id:(context_edge_id ctx event)
    ~lane:(clock_lane_of_event event) ~source_clock:(source_clock_of_event event)
    ?elapsed_ms ?tool_batch_id
    ?checkpoint_id ?compaction_id ?compaction_source
    ?event_bus_correlation_id ?event_bus_run_id ?parent_event_id ?caused_by
    ?logical_seq ()

let assoc_has_key key fields =
  List.exists (fun (field, _) -> String.equal field key) fields

let with_clock_refs ~clock_refs decision =
  match clock_refs with
  | `Assoc [] -> decision
  | _ -> (
    match decision with
    | `Assoc fields when assoc_has_key "clock_refs" fields -> decision
    | `Assoc fields -> `Assoc (fields @ [ ("clock_refs", clock_refs) ])
    | other -> `Assoc [ ("decision", other); ("clock_refs", clock_refs) ])

let with_payload_role ~payload_role decision =
  match decision with
  | `Assoc fields when assoc_has_key "payload_role" fields -> decision
  | `Assoc fields ->
    `Assoc (fields @ [ ("payload_role", `String (payload_role_to_string payload_role)) ])
  | other ->
    `Assoc
      [
        ("decision", other);
        ("payload_role", `String (payload_role_to_string payload_role));
      ]

let with_compaction_outcome ~compaction_outcome decision =
  let outcome_json = `String (compaction_outcome_to_string compaction_outcome) in
  match decision with
  | `Assoc fields when assoc_has_key compaction_outcome_key fields -> decision
  | `Assoc fields -> `Assoc (fields @ [ compaction_outcome_key, outcome_json ])
  | other ->
    `Assoc [ "decision", other; compaction_outcome_key, outcome_json ]
;;

let make ?(ts = Masc_domain.now_iso ()) ~keeper_name ?agent_name ~trace_id
    ?keeper_turn_id ?agent_core_turn_count ?logical_seq ~event ?runtime_id
    ?(status = "ok") ?(decision = `Assoc []) ?receipt_path ?checkpoint_path
    ?tool_call_log_path () =
  {
    schema_version;
    ts;
    keeper_name;
    agent_name;
    trace_id;
    keeper_turn_id;
    agent_core_turn_count;
    logical_seq;
    event;
    runtime_id;
    status;
    decision;
    links = { receipt_path; checkpoint_path; tool_call_log_path };
  }

let make_for_context ctx ~event ?agent_core_turn_count ?logical_seq ?runtime_id
    ?status ?decision ?receipt_path ?checkpoint_path ?tool_call_log_path () =
  make ~keeper_name:ctx.manifest_keeper_name
    ?agent_name:ctx.manifest_agent_name ~trace_id:ctx.manifest_trace_id
    ?keeper_turn_id:ctx.manifest_keeper_turn_id ?agent_core_turn_count ?logical_seq
    ~event ?runtime_id ?status ?decision ?receipt_path ?checkpoint_path
    ?tool_call_log_path ()

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

(* Allowlist-based public projection.
   The previous substring-based redaction (§2 anti-pattern) has been removed;
   public filtering now uses explicit allowlists in {!public_projection_of_decision}. *)

(* [trigger_detail] keys come from the encoder that writes them, not from a
   copy kept here. The flat list below used to name only "kind" and
   "limit_tokens", so a [Request_body_over_capacity] refusal reached the public
   projection stripped of the two measured integers that justify it — the
   operator saw the refusal and not its bounds. Sourcing the key set from
   {!Compaction_trigger.wire_field_names} means a field added to a trigger
   constructor cannot be dropped here without also failing to compile there. *)
let decision_public_allowlist =
  StringSet.of_list
    (Compaction_trigger.wire_field_names
    @ [ "edge_id"; "lane"; "source_clock"; "observed_at"; "started_at"; "finished_at"
    ; "elapsed_ms"; "provider_attempt_id"; "tool_batch_id"; "checkpoint_id"
    ; "compaction_id"; "event_bus_correlation_id"
    ; "event_bus_run_id"; "parent_event_id"; "caused_by"; "logical_seq"
    ; "compaction_source"; "repair_reason"; "matched_started_ts"
    ; "matched_started_status"; "error"; "exception_kind"; "latency_ms"
    ; "checkpoint_after_present"; "is_last"
    ; "liveness_mode"; "liveness_budget_source"
    ; "context_compact_started_count"; "context_compacted_count"
    ; "last_compaction"
    ; "routing_action"; "routing_reason"; "degraded_runtime_id"
    ; "runtime_execution_built"
    ; "media_dropped_total"; "media_dropped_counts"
    ; "payload_role"; "trigger"; "trigger_detail"
    ; "ratio"; "threshold"; "count"
    ; "source_requeued"; compaction_outcome_key
    ; Keeper_compaction_evidence.exact_evidence_key
    ; "clock_refs"
    ; "checkpoint_installation_schema"; "checkpoint_installation_state"
    ; "checkpoint_installed_ref"; "checkpoint_installation_auxiliary"
    ; "compaction_post_install_schema"; "compaction_lifecycle"
    ; "operator_action_required"; "trace_id"; "turn_count"
    ; "sha256"; "kind"; "detail"; "backtrace_present"; "completion_error"
    ; "failure_dispatch"; "failure_dispatch_error"
    (* Runtime attempt attribution (#28871): the lane walk stores the
       attempted candidate in decision.runtime_id/idx (error_kind on
       failures) while the row's top-level runtime_id is the lane id.
       Dropping these here made intra-lane failover unreadable on every
       API consumer. *)
    ; "idx"; "runtime_id"; "error_kind"
    ])

let compaction_evidence_public_allowlist =
  StringSet.of_list Keeper_compaction_evidence.wire_field_names

let clock_refs_public_allowlist =
  StringSet.of_list
    [ "edge_id"; "lane"; "source_clock"; "observed_at"; "started_at"; "finished_at"
    ; "elapsed_ms"; "provider_attempt_id"; "tool_batch_id"; "checkpoint_id"
    ; "compaction_id"; "compaction_source"; "event_bus_correlation_id"
    ; "event_bus_run_id"; "parent_event_id"; "caused_by"; "logical_seq"
    ]

type decision_projection_scope =
  | Decision
  | Clock_refs
  | Compaction_evidence

let decision_allowlist = function
  | Decision -> decision_public_allowlist
  | Clock_refs -> clock_refs_public_allowlist
  | Compaction_evidence -> compaction_evidence_public_allowlist

let decision_child_scope scope key =
  if String.equal key "clock_refs" then Clock_refs
  else if String.equal key Keeper_compaction_evidence.exact_evidence_key
  then Compaction_evidence
  else scope

let public_projection_of_decision decision =
  let rec project scope path = function
    | `Assoc fields ->
        let allowlist = decision_allowlist scope in
        `Assoc
          (List.filter_map
             (fun (key, value) ->
               if StringSet.mem key allowlist then
                 Some
                   ( key
                   , project
                       (decision_child_scope scope key)
                       (if String.equal path "" then key else path ^ "." ^ key)
                       value )
               else None)
             fields)
    | `List values -> `List (List.map (project scope path) values)
    | other -> other
  in
  project Decision "" decision

let to_json manifest =
  `Assoc
    [
      ("schema_version", `Int manifest.schema_version);
      ("ts", `String manifest.ts);
      ("keeper_name", `String manifest.keeper_name);
      ("agent_name", json_of_string_opt manifest.agent_name);
      ("trace_id", `String manifest.trace_id);
        ("keeper_turn_id", json_of_int_opt manifest.keeper_turn_id);
      ("agent_core_turn_count", json_of_int_opt manifest.agent_core_turn_count);
      ("logical_seq", json_of_int_opt manifest.logical_seq);
      ("event", `String (event_kind_to_string manifest.event));
      ("runtime_id", json_of_string_opt manifest.runtime_id);
      ("status", `String manifest.status);
      ("decision", manifest.decision);
      ("links", links_to_json manifest.links);
    ]

let public_to_json manifest =
  `Assoc
    [
      ("schema_version", `Int manifest.schema_version);
      ("ts", `String manifest.ts);
      ("keeper_name", `String manifest.keeper_name);
      ("agent_name", json_of_string_opt manifest.agent_name);
      ("trace_id", `String manifest.trace_id);
      ("keeper_turn_id", json_of_int_opt manifest.keeper_turn_id);
      ("agent_core_turn_count", json_of_int_opt manifest.agent_core_turn_count);
      ("logical_seq", json_of_int_opt manifest.logical_seq);
      ("event", `String (event_kind_to_string manifest.event));
      ("runtime_id", json_of_string_opt manifest.runtime_id);
      ("status", `String manifest.status);
      ("decision", public_projection_of_decision manifest.decision);
      ("links", links_to_json manifest.links);
    ]

let field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing field %S" key)

let required_string key fields =
  match field key fields with
  | Ok (`String value) -> Ok value
  | Ok other ->
      Error
        (Printf.sprintf "field %S must be a string (received %s)" key
           (Json_util.kind_name other))
  | Error _ as err -> err

let required_int key fields =
  match field key fields with
  | Ok (`Int value) -> Ok value
  | Ok other ->
      Error
        (Printf.sprintf "field %S must be an int (received %s)" key
           (Json_util.kind_name other))
  | Error _ as err -> err

let optional_string key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some other ->
      Error
        (Printf.sprintf "field %S must be a string or null (received %s)" key
           (Json_util.kind_name other))

let optional_int key fields =
  match List.assoc_opt key fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some other ->
      Error
        (Printf.sprintf "field %S must be an int or null (received %s)" key
           (Json_util.kind_name other))

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
  | other ->
      Error
        (Printf.sprintf "field \"links\" must be an object (received %s)"
           (Json_util.kind_name other))

type parsed_row = {
  ts : string;
  keeper_name : string;
  agent_name : string option;
  trace_id : string;
  keeper_turn_id : int option;
  agent_core_turn_count : int option;
  logical_seq : int option;
  event_wire : string;
  runtime_id : string option;
  status : string;
  decision : Yojson.Safe.t;
  links : links;
}

let canonicalize_compaction_evidence ~event_wire decision =
  let evidence_key = Keeper_compaction_evidence.exact_evidence_key in
  let canonicalize_present fields evidence_json =
    match Keeper_compaction_evidence.of_json evidence_json with
    | Error error ->
      Error
        (Printf.sprintf
           "field \"decision.%s\" is invalid: %s"
           evidence_key
           (Keeper_compaction_evidence.decode_error_to_string error))
    | Ok evidence ->
      let canonical = Keeper_compaction_evidence.to_json evidence in
      Ok
        (`Assoc
           (List.map
              (fun (key, value) ->
                 if String.equal key evidence_key then key, canonical else key, value)
              fields))
  in
  match decision with
  | `Assoc fields ->
    let evidence_entries =
      List.filter (fun (key, _) -> String.equal key evidence_key) fields
    in
    if not (String.equal event_wire (event_kind_to_string Context_compacted))
    then
      (match evidence_entries with
       | [] -> Ok decision
       | [ _, evidence_json ] -> canonicalize_present fields evidence_json
       | _ ->
         Error
           (Printf.sprintf
              "field \"decision.%s\" must appear exactly once"
              evidence_key))
    else
      let outcome_entries =
        List.filter (fun (key, _) -> String.equal key compaction_outcome_key) fields
      in
      (match outcome_entries with
       | [ _, `String wire ] ->
         (match compaction_outcome_of_string wire with
          | None ->
            Error
              (Printf.sprintf
                 "field \"decision.%s\" has unknown value %S"
                 compaction_outcome_key
                 wire)
          | Some Checkpoint_committed ->
            (match evidence_entries with
             | [ _, evidence_json ] -> canonicalize_present fields evidence_json
             | [] ->
               Error
                 (Printf.sprintf
                    "field \"decision.%s\" is required for checkpoint_committed"
                    evidence_key)
             | _ ->
               Error
                 (Printf.sprintf
                    "field \"decision.%s\" must appear exactly once"
                    evidence_key))
          | Some Lifecycle_cleanup_failed_without_checkpoint ->
            (match evidence_entries with
             | _ :: _ ->
               Error
                 (Printf.sprintf
                    "field \"decision.%s\" is forbidden without a committed checkpoint"
                    evidence_key)
             | [] ->
               (match
                  List.filter (fun (key, _) -> String.equal key "error") fields
                with
                | [ _, `String cause ] when String.trim cause <> "" -> Ok decision
                | [ _, `String _ ] ->
                  Error
                    "field \"decision.error\" must be nonblank for a failed compaction outcome"
                | [ _, other ] ->
                  Error
                    (Printf.sprintf
                       "field \"decision.error\" must be a string (received %s)"
                       (Json_util.kind_name other))
                | [] ->
                  Error
                    "field \"decision.error\" is required for a failed compaction outcome"
                | _ ->
                  Error "field \"decision.error\" must appear exactly once")))
       | [ _, other ] ->
         Error
           (Printf.sprintf
              "field \"decision.%s\" must be a string (received %s)"
              compaction_outcome_key
              (Json_util.kind_name other))
       | [] ->
         Error
           (Printf.sprintf
              "field \"decision.%s\" is required for current context_compacted rows"
              compaction_outcome_key)
       | _ ->
         Error
           (Printf.sprintf
              "field \"decision.%s\" must appear exactly once"
              compaction_outcome_key))
  | _ when String.equal event_wire (event_kind_to_string Context_compacted) ->
    Error
      (Printf.sprintf
         "field \"decision.%s\" is required for current context_compacted rows"
         compaction_outcome_key)
  | _ -> Ok decision
;;

let parse_row = function
  | `Assoc fields -> (
      let ( >>= ) result f =
        match result with Ok value -> f value | Error _ as err -> err
      in
      match required_int "schema_version" fields with
      | Error _ as err -> err
      | Ok parsed_schema_version ->
          if parsed_schema_version <> schema_version then
            Error
              (Printf.sprintf "unsupported schema_version: %d"
                 parsed_schema_version)
          else
            required_string "ts" fields >>= fun ts ->
            required_string "keeper_name" fields >>= fun keeper_name ->
            optional_string "agent_name" fields >>= fun agent_name ->
            required_string "trace_id" fields >>= fun trace_id ->
            optional_int "keeper_turn_id" fields >>= fun keeper_turn_id ->
            optional_int "agent_core_turn_count" fields >>= fun agent_core_turn_count ->
            optional_int "logical_seq" fields >>= fun logical_seq ->
            required_string "event" fields >>= fun event_wire ->
            optional_string "runtime_id" fields >>= fun runtime_id ->
            required_string "status" fields >>= fun status ->
            field "decision" fields >>= fun decision ->
            canonicalize_compaction_evidence ~event_wire decision
            >>= fun decision ->
            field "links" fields >>= fun links_json ->
            links_of_json links_json >>= fun links ->
            Ok
              {
                ts;
                keeper_name;
                agent_name;
                trace_id;
                keeper_turn_id;
                agent_core_turn_count;
                logical_seq;
                event_wire;
                runtime_id;
                status;
                decision;
                links;
              })
  | other ->
      Error
        (Printf.sprintf "manifest row must be a JSON object (received %s)"
           (Json_util.kind_name other))

let row_identity (row : parsed_row) : row_identity =
  {
    keeper_name = row.keeper_name;
    trace_id = row.trace_id;
    keeper_turn_id = row.keeper_turn_id;
  }

let active_row (row : parsed_row) event : t =
  {
    schema_version;
    ts = row.ts;
    keeper_name = row.keeper_name;
    agent_name = row.agent_name;
    trace_id = row.trace_id;
    keeper_turn_id = row.keeper_turn_id;
    agent_core_turn_count = row.agent_core_turn_count;
    logical_seq = row.logical_seq;
    event;
    runtime_id = row.runtime_id;
    status = row.status;
    decision = row.decision;
    links = row.links;
  }

let decode_persisted_row json =
  match parse_row json with
  | Error _ as error -> error
  | Ok row ->
    (match event_kind_of_string row.event_wire with
     | Some event -> Ok (Active_row (active_row row event))
     | None -> Ok (Unsupported_row (row_identity row, row.event_wire)))

let of_json json =
  match decode_persisted_row json with
  | Ok (Active_row row) -> Ok row
  | Ok (Unsupported_row (_, event)) ->
      Error (Printf.sprintf "unknown event: %S" event)
  | Error _ as error -> error

let execution_receipt_path_for_today config ~keeper_name =
  (* [Jsonl_writer.dated_path_now] is the same calculation the writer runs;
     a second copy here is free to drift to a different calendar (#27143). *)
  let base_dir =
    Keeper_types_support.keeper_execution_receipt_store config keeper_name
    |> Dated_jsonl.base_dir
  in
  (Jsonl_writer.dated_path_now ~base_dir).Jsonl_writer.path

let base_dir config ~keeper_name =
  Filename.concat
    (Filename.concat
       (Workspace.keepers_runtime_dir config)
       keeper_name)
    "runtime-manifests"

let path_for_trace config ~keeper_name ~trace_id =
  Filename.concat (base_dir config ~keeper_name)
    (safe_segment trace_id ^ manifest_file_suffix)

include Keeper_runtime_manifest_housekeeping

let append_to_path path manifest =
  try
    let dir = Filename.dirname path in
    let (_ : string) = Keeper_fs.ensure_dir dir in
    Keeper_types_support.append_jsonl_line path (to_json manifest);
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Keeper_fd_pressure.note_exception
      ~site:"keeper_runtime_manifest.append_to_path"
      exn;
    Keeper_disk_pressure.note_exception
      ~site:"keeper_runtime_manifest.append_to_path"
      exn;
    Error (Printexc.to_string exn)

let append config manifest =
  let base_dir = base_dir config ~keeper_name:manifest.keeper_name in
  match
    append_to_path
      (Filename.concat base_dir
         (safe_segment manifest.trace_id ^ manifest_file_suffix))
      manifest
  with
  | Ok () ->
    maybe_prune_retention ~base_dir;
    Ok ()
  | Error _ as err -> err

let append_best_effort ?(site = "runtime_manifest") config manifest =
  match append config manifest with
  | Ok () -> ()
  | Error msg ->
      let masc_root = Workspace.masc_root_dir config in
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
         Log.Keeper.warn ~keeper_name:manifest.keeper_name
           "runtime_manifest coverage-gap append failed site=%s \
            trace_id=%s event=%s: %s"
           site manifest.trace_id
           (event_kind_to_string manifest.event)
           (Printexc.to_string exn));
      Log.Keeper.warn ~keeper_name:manifest.keeper_name
        "runtime_manifest append failed site=%s trace_id=%s event=%s: %s"
        site manifest.trace_id
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
    Log.Keeper.warn ~keeper_name:ctx.manifest_keeper_name
      "runtime_manifest unfinished provider scan failed site=%s trace_id=%s: %s"
      site ctx.manifest_trace_id msg
  | Ok None -> ()
  | Ok (Some started) ->
    let inherited_fields =
      match started.decision with
      | `Assoc fields ->
        List.filter (fun (k, _) -> not (String.equal k "clock_refs")) fields
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
    let decision = `Assoc (inherited_fields @ terminal_fields) in
    let clock_refs = clock_refs_for_context ctx ~event:Provider_attempt_finished () in
    let decision = with_clock_refs ~clock_refs decision in
    make_for_context ctx ~event:Provider_attempt_finished
      ?runtime_id:started.runtime_id
      ~status
      ~decision
      ()
    |> append_best_effort ~site config
