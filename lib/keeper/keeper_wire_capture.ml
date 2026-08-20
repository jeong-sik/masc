(** See [keeper_wire_capture.mli]. *)

let enabled () = Env_config_keeper.KeeperWireCapture.enabled ()

let redact redaction text =
  text
  |> Llm_provider.Secret_redactor.redact_string
  |> Keeper_secret_redaction.redact_text redaction

(* Dated per-day store, mirroring the cost-ledger appender
   ([Keeper_hooks_agent_core_cost_events.emit_cost_event]); concurrent keepers
   serialise on a per-day file rather than one global blob. *)
let wire_capture_dir masc_root = Filename.concat masc_root "wire-capture"

(** Cache [Dated_jsonl.t] handles per MASC root so the diagnostic harness does
    not recreate the store (and re-scan/re-prune) on every request/response
    capture. The cache is keyed by the effective root path and invalidated when
    retention or byte-budget configuration changes. *)
type store_entry =
  { store : Dated_jsonl.t
  ; retention_days : int
  ; max_bytes : int
  }

let store_cache : (string, store_entry) Hashtbl.t = Hashtbl.create 16
let store_cache_mu = Stdlib.Mutex.create ()

let store_for ~masc_root =
  let retention_days = Env_config_keeper.KeeperWireCapture.retention_days () in
  let max_bytes = Env_config_keeper.KeeperWireCapture.max_bytes () in
  Stdlib.Mutex.protect store_cache_mu (fun () ->
    match Hashtbl.find_opt store_cache masc_root with
    | Some entry
      when entry.retention_days = retention_days && entry.max_bytes = max_bytes ->
      entry
    | _ ->
      let store =
        Dated_jsonl.create
          ~base_dir:(wire_capture_dir masc_root)
          ~retention_days
          ~max_bytes
          ()
      in
      let entry = { store; retention_days; max_bytes } in
      Hashtbl.replace store_cache masc_root entry;
      entry)
;;

type prune_error =
  | Retention_prune_failed of
      { path : string
      ; detail : string
      }

let prune_error_to_string = function
  | Retention_prune_failed { path; detail } ->
    Printf.sprintf "wire-capture retention prune failed path=%s: %s" path detail
;;

let prune_expired ~masc_root =
  let path = wire_capture_dir masc_root in
  try
    let { store; retention_days; _ } = store_for ~masc_root in
    Ok (Dated_jsonl.prune store ~days:retention_days)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Retention_prune_failed { path; detail = Printexc.to_string exn })
;;

type record_skip_reason =
  | Rotation_sequence_exhausted
  | Append_guard_refused

let record_skip_reason_label = function
  | Rotation_sequence_exhausted -> "rotation_sequence_exhausted"
  | Append_guard_refused -> "append_guard_refused"
;;

type write_failure_site =
  | Request_capture
  | Response_capture

let write_failure_site_label = function
  | Request_capture -> "request"
  | Response_capture -> "response"
;;

let record_skip ~store ~keeper_name ~turn_id reason detail =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string WireCaptureRecordSkipped)
    ~labels:
      [ ("keeper", keeper_name)
      ; ("turn_id", string_of_int turn_id)
      ; ("reason", record_skip_reason_label reason)
      ]
    ();
  Log.Keeper.warn
    "keeper_wire_capture: skipped record (%s) under %s"
    detail
    (Dated_jsonl.base_dir store)
;;

(* Segments are sized at a fraction of the store byte budget so the
   budget-driven oldest-first prune keeps a ring of several completed
   segments plus the current file. With segment size = budget, a freshly
   rotated segment would already exceed the budget and be pruned at
   once, collapsing the ring to a single file. *)
let segments_per_byte_budget = 8

let write_payload ~masc_root ~keeper_name ~turn_id (payload : Yojson.Safe.t) =
  let { store; max_bytes; _ } = store_for ~masc_root in
  let segment_bytes = Stdlib.Int.max 1 (max_bytes / segments_per_byte_budget) in
  match
    Dated_jsonl.append_rotating
      store
      ~max_current_file_bytes:segment_bytes
      payload
  with
  | Dated_jsonl.Appended_to_current -> ()
  | Dated_jsonl.Appended_after_rotation { segment } ->
    (* Rotation is the byte cap working, not a loss: the row landed in a
       fresh current file and the completed segment stays readable until
       the store byte budget prunes the oldest segments. *)
    Log.Keeper.info
      "keeper_wire_capture: rotated full day file to %s under %s"
      segment
      (Dated_jsonl.base_dir store)
  | Dated_jsonl.Skipped_rotation_exhausted { sequence_limit } ->
    record_skip ~store ~keeper_name ~turn_id Rotation_sequence_exhausted
      (Printf.sprintf
         "day already holds %d rotated segments of %d bytes"
         sequence_limit
         segment_bytes)
  | Dated_jsonl.Skipped_by_append_guard ->
    record_skip ~store ~keeper_name ~turn_id Append_guard_refused
      "append guard declined the write"

let best_effort ~site ~masc_root ~keeper_name ~turn_id f =
  let base_dir = wire_capture_dir masc_root in
  try f () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string WireCaptureWriteFailures)
      ~labels:
        [ ("keeper", keeper_name)
        ; ("turn_id", string_of_int turn_id)
        ; ("site", write_failure_site_label site)
        ]
      ();
    Log.Keeper.error "keeper_wire_capture: write failed to %s: %s" base_dir
      (Printexc.to_string exn)

let json_string_opt redaction = function
  | Some value -> `String (redact redaction value)
  | None -> `Null

let rec redact_json_strings
          redaction
          (json : Yojson.Safe.t)
  : Yojson.Safe.t
  =
  match json with
  | `String value -> `String (redact redaction value)
  | `Assoc fields ->
    `Assoc
      (List.map
         (fun (key, value) -> key, redact_json_strings redaction value)
         fields)
  | `List values ->
    `List (List.map (redact_json_strings redaction) values)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as value -> value

let capture_request ~base_path ~masc_root ~keeper_name ~turn_id ~agent_core_turn
    ~system_prompt ~extra_system_context ~user_message ~history_messages ~tools
    ?trace_id () =
  if not (enabled ()) then ()
  else
    best_effort ~site:Request_capture ~masc_root ~keeper_name ~turn_id (fun () ->
      let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
      let raw_tools =
        List.map Agent_core.Tool.schema_to_json tools
      in
      let tool_schema_bytes =
        Yojson.Safe.to_string (`List raw_tools) |> String.length
      in
      let redacted_tools =
        List.map (redact_json_strings redaction) raw_tools
      in
      (* The redacted schema array is stored once in the shared content-addressed
         blob store and referenced from the row. The array is identical across
         every request of the same tool surface (measured 2026-08-18 on a live
         root: 2,702 rows carried 2 unique arrays of ~80KB each — 99.3% of all
         capture bytes), so inlining it spent the day-file byte budget on
         copies. [put_durable] is idempotent per content address, and blob
         maintenance already lists wire-capture as a durable consumer, so the
         blob lives exactly as long as a retained row references it. A blob
         write failure raises out to [best_effort], which skips the whole
         record: a marker is never emitted for bytes that were not persisted. *)
      let tools_ref =
        let blob_store = Tool_blob_store.create ~base_path in
        Tool_blob_store.put_durable
          blob_store
          ~bytes:(Yojson.Safe.to_string (`List redacted_tools))
          ~mime:"application/json"
      in
      (* The replayed conversation is not copied into this record. It is
         already durable in the AGENT_CORE checkpoint and its [agent-core-snapshot-*]
         history, and [capture_request] fires once per agent-core turn, so
         embedding it made one record as large as the checkpoint itself
         (measured 2026-08-05: 14,465 messages = 9.8MB per record, which
         exhausts the 64MiB day-file budget after 7 records and skips every
         request after that). [history_messages_digest] is the same MD5 the
         [context_injected] runtime manifest records, so a capture row joins
         to the manifest row and to the checkpoint that holds the text. *)
      let history_messages_digest =
        Keeper_context_digest.message_texts_as_joined history_messages
      in
      let payload : Yojson.Safe.t =
        `Assoc
          [ ("ts", `String (Masc_domain.now_iso ()))
          ; ("kind", `String "request")
          ; ("keeper", `String keeper_name)
          ; ("turn_id", `Int turn_id)
          ; ( "trace_id"
            , match trace_id with
              | Some t -> `String (Keeper_id.Trace_id.to_string t)
              | None -> `Null )
          ; ("agent_core_turn", `Int agent_core_turn)
          ; ("system_prompt", `String (redact redaction system_prompt))
          ; ( "extra_system_context"
            , json_string_opt redaction extra_system_context )
          ; ( "extra_system_context_present"
            , `Bool (Option.is_some extra_system_context) )
          ; ( "extra_system_context_bytes"
            , match extra_system_context with
              | Some context -> `Int (String.length context)
              | None -> `Null )
          ; ("tool_count", `Int (List.length tools))
          ; ("tool_schema_bytes", `Int tool_schema_bytes)
          ; ("tools_ref", Tool_output.normalized_artifact_ref_to_json tools_ref)
          ; ("user_message", `String (redact redaction user_message))
          ; ("history_message_count", `Int (List.length history_messages))
          ; ("history_messages_digest", `String history_messages_digest)
          ]
      in
      write_payload ~masc_root ~keeper_name ~turn_id payload)

let capture_response ~base_path ~masc_root ~keeper_name ~turn_id ~agent_core_turn
    ~response_text ?trace_id () =
  if not (enabled ()) then ()
  else
    best_effort ~site:Response_capture ~masc_root ~keeper_name ~turn_id (fun () ->
      let redaction = Keeper_secret_redaction.snapshot ~base_path ~keeper_name in
      let payload : Yojson.Safe.t =
        `Assoc
          [ ("ts", `String (Masc_domain.now_iso ()))
          ; ("kind", `String "response")
          ; ("keeper", `String keeper_name)
          ; ("turn_id", `Int turn_id)
          ; ( "trace_id"
            , match trace_id with
              | Some t -> `String (Keeper_id.Trace_id.to_string t)
              | None -> `Null )
          ; ("agent_core_turn", `Int agent_core_turn)
          ; ("response_text", `String (redact redaction response_text))
          ]
      in
      write_payload ~masc_root ~keeper_name ~turn_id payload)
