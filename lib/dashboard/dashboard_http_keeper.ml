(** Dashboard HTTP keeper — the execution-trust dashboard surface and the
    keeper counts and config snapshot the dashboard routes read. *)


open Keeper_status_bridge

include Dashboard_http_keeper_detail

(** Runtime display constants and live runtime-id resolver moved
    to Dashboard_http_keeper_types (intra-library file split, 2026-05-16). *)
include Dashboard_http_keeper_types
module Trust = Dashboard_http_keeper_trust

(* prompt_block_json / tokens_per_sec_json /
   last_latency_ms_json moved to Dashboard_http_keeper_types
   (intra-library file split, 2026-05-16). *)

let keeper_trust_json = Trust.keeper_trust_json

(* execution_trust_source / _producer / _dashboard_surface / _freshness_slo_s
   moved to Dashboard_http_keeper_types (intra-library file split,
   2026-05-16). *)

(* execution_receipt path/diagnostic helpers extracted to
   [Dashboard_http_keeper_execution_receipt] (godfile decomp). *)
let execution_receipt_store_pattern = Dashboard_http_keeper_execution_receipt.execution_receipt_store_pattern
let count_execution_receipt_entries = Dashboard_http_keeper_execution_receipt.count_execution_receipt_entries
let execution_receipt_coverage_gaps = Dashboard_http_keeper_execution_receipt.execution_receipt_coverage_gaps

let keeper_count (config : Workspace.config) : int option =
  match Keeper_meta_store.keeper_names_result config with
  | Ok names -> Some (List.length names)
  | Error detail ->
    Log.Keeper.warn "keeper_count: keeper names unread: %s" detail;
    None

let configured_keeper_count (config : Workspace.config) : int =
  List.length (Keeper_meta_store.configured_keeper_names config)

let non_empty_trimmed_string_opt value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

(* The [diagnostic] object of a row whose dashboard worker raised. Both the
   degraded row and the name-only row carry it, so they cannot drift apart. *)
let worker_failure_diagnostic ~(error : string) =
  `Assoc
    [ ("status", `String "degraded")
    ; ( "reason"
      , `String
          Keeper_runtime_trust_snapshot_core.(
            disposition_reason_to_wire Keeper_dashboard_worker_exception) )
    ; ("error", `String error)
    ; ("fd_observation", `Assoc (Keeper_fd_pressure.projection_fields ()))
    ]

let degraded_keeper_dashboard_row
      ~(error : string)
      (m : Keeper_meta_contract.keeper_meta)
  =
  let runtime_trust = Trust.degraded_keeper_trust_json ~error in
  let runtime_id =
    Keeper_meta_contract.runtime_id_of_meta m |> non_empty_trimmed_string_opt
  in
  let runtime_id_json = Json_util.string_opt_to_json runtime_id in
  let diagnostic = worker_failure_diagnostic ~error in
  `Assoc
    ([ ("name", `String m.name)
     ; ( "keeper_id"
       , match m.keeper_id with
         | Some keeper_id -> `String (Keeper_id.Uid.to_string keeper_id)
         | None -> `Null )
     ; ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id))
     ; ("current_task_id",
        Json_util.string_opt_to_json
          (Option.map Keeper_id.Task_id.to_string m.current_task_id))
     ; ("created_at", `String m.created_at)
     ; ("updated_at", `String m.updated_at)
     ; ("phase", `String "degraded")
     ; ("pipeline_stage", `String "degraded")
     ; ("status", `String "degraded")
     ; ("degraded", `Bool true)
     ; ("diagnostic", diagnostic)
     ; ("trust", runtime_trust)
     ; ("runtime_trust", runtime_trust)
     ; ("paused", `Bool m.paused)
     ; ("keepalive_running", `Bool false)
     ; ("total_turns", `Int m.runtime.usage.total_turns)
     ; ("runtime_id", runtime_id_json)
     ; ("runtime_canonical", runtime_id_json)
     ; ("selected_runtime_canonical", runtime_id_json)
      ; ("primary_model", `String (Keeper_meta_contract.runtime_id_of_meta m))
      ; ("active_model", `String (Keeper_status_runtime.active_model_of_meta m))
      ; ("active_model_label", `String (Keeper_status_runtime.active_model_label_of_meta m))
     ])

let invalid_profile_dashboard_row ~keeper_name error =
  let config_error =
    Keeper_types_profile.keeper_toml_config_error_of_load_error
      ~keeper_name
      error
    |> Keeper_types_profile.keeper_toml_config_error_to_json
  in
  `Assoc
    [ ("name", `String keeper_name)
    ; ("phase", `String (Keeper_state_machine.phase_to_string Keeper_state_machine.Offline))
    ; ("lifecycle_phase", `String (Keeper_state_machine.phase_to_string Keeper_state_machine.Offline))
    ; ("pipeline_stage", `String "offline")
    ; ("pipeline_stage_detail", `String "keeper_profile_load_failed")
    ; ("status", `String "blocked")
    ; ("degraded", `Bool true)
    ; ("needs_attention", `Bool true)
    ; ("attention_reason", `String "config_invalid")
    ; ("next_human_action", `String "fix_keeper_toml_config")
    ; ("config_error", config_error)
    ; ("paused", `Bool false)
    ; ("keepalive_running", `Bool false)
    ]

(* The row for a keeper whose dashboard worker raised and whose degraded row
   cannot be built either (the meta is unreadable or not current, or building
   the degraded row raised too). The roster named the keeper, so it stays in
   the list under its name with the error. Dropping it left an [ok:true]
   response with a shorter list, which reads as a keeper that does not exist.

   This is the last step of [keeper_row_after_worker_failure], so it must not
   raise. It only wraps the name and [error] in constants and closed-variant
   wire strings ([Trust.degraded_keeper_trust_json] passes
   [receipt_operator_disposition = None]) and reads atomic counters
   ([Keeper_fd_pressure.projection_fields]). It reads no file and no registry. *)
let name_only_degraded_keeper_dashboard_row ~keeper_name ~(error : string) =
  let runtime_trust = Trust.degraded_keeper_trust_json ~error in
  let diagnostic = worker_failure_diagnostic ~error in
  `Assoc
    [ ("name", `String keeper_name)
    ; ("phase", `String "degraded")
    ; ("pipeline_stage", `String "degraded")
    ; ("status", `String "degraded")
    ; ("degraded", `Bool true)
    ; ("diagnostic", diagnostic)
    ; ("trust", runtime_trust)
    ; ("runtime_trust", runtime_trust)
    ]

(* Total: every keeper whose worker raised gets a row. The degraded row is the
   preferred shape; the name-only row is what remains when the meta cannot be
   read, is absent or not current, or when building the degraded row raises
   (for example [runtime_id_of_meta] finds no runtime assignment for the keeper
   and no default runtime). *)
let keeper_row_after_worker_failure
      (config : Workspace.config)
      ~(name : string)
      ~(error : string)
  =
  let name_only detail =
    name_only_degraded_keeper_dashboard_row ~keeper_name:name ~error:detail
  in
  try
    match Keeper_meta_store.read_meta_presence config name with
    | Ok (Keeper_meta_store.Meta_present meta) ->
        degraded_keeper_dashboard_row ~error meta
    | Ok Keeper_meta_store.Meta_absent ->
        name_only (error ^ "; no keeper meta file")
    | Ok (Keeper_meta_store.Meta_not_current detail) ->
        name_only
          (Printf.sprintf "%s; keeper meta is not current: %s" error detail)
    | Error detail ->
        name_only (Printf.sprintf "%s; keeper meta unreadable: %s" error detail)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | fallback_exn ->
      let detail = Printexc.to_string fallback_exn in
      Log.Dashboard.error
        "keeper dashboard degraded fallback failed (%s): %s"
        name
        detail;
      name_only (Printf.sprintf "%s; degraded row failed: %s" error detail)

let running_keeper_count (config : Workspace.config) : int =
  (match Keeper_meta_store.keeper_names_result config with
   | Ok names -> names
   | Error detail ->
     Log.Keeper.warn "running_keeper_count: keeper names unread: %s" detail;
     [])
  |> List.fold_left
       (fun count name ->
         match Keeper_meta_store.read_meta config name with
         | Ok (Some meta) when runtime_keepalive_running config meta -> count + 1
         | Ok (None) | Error _ | Ok (Some _) -> count)
       0

let execution_trust_row_of_dashboard_row row =
  let field key =
    (* sound-partial: invalid-profile and degraded rows intentionally omit
       inapplicable fields; the established execution-trust wire value for
       those absent fields is JSON null. *)
    match Json_util.assoc_member_opt key row with
    | Some value -> value
    | None -> `Null
  in
  `Assoc
    [ ("name", field "name")
    ; ("keeper_id", field "keeper_id")
    ; ("phase", field "phase")
    ; ("pipeline_stage", field "pipeline_stage")
    ; ("status", field "status")
    ; ("trace_id", field "trace_id")
    ; ("current_task_id", field "current_task_id")
    ; ("trust", field "trust")
    ]

let execution_trust_row_of_meta
      ~(now_ts : float)
      (config : Workspace.config)
      (m : Keeper_meta_contract.keeper_meta)
  =
  let registry_entry =
    Keeper_registry.get ~base_path:config.base_path m.name
  in
  let registry_phase =
    match registry_entry with
    | Some (entry : Keeper_registry.registry_entry) -> Some entry.phase
    | None -> None
  in
  let phase, pipeline_stage =
    match registry_entry with
    | Some entry ->
      ( `String (Keeper_state_machine.phase_to_string entry.phase)
      , Keeper_status_runtime.pipeline_stage_of_phase entry.phase )
    | None -> `Null, "offline"
  in
  (* [keeper_surface_status] depends only on the diagnostic health state. The
     reply-history fields in [keeper_diagnostic_json] do not participate in
     that state, so the trust surface must not read the conversation log. *)
  let diagnostic =
    Keeper_status_runtime.keeper_diagnostic_json
      ~meta:m
      ~phase:registry_phase
      ~history_items:[]
      ~now_ts
  in
  `Assoc
    [ ("name", `String m.name)
    ; ( "keeper_id"
      , match m.keeper_id with
        | Some keeper_id -> `String (Keeper_id.Uid.to_string keeper_id)
        | None -> `Null )
    ; ("phase", phase)
    ; ("pipeline_stage", `String pipeline_stage)
    ; ( "status"
      , `String
          (Keeper_status_runtime.keeper_surface_status ~diagnostic) )
    ; ("trace_id", `String (Keeper_id.Trace_id.to_string m.runtime.trace_id))
    ; ( "current_task_id"
      , Json_util.string_opt_to_json
          (Option.map Keeper_id.Task_id.to_string m.current_task_id) )
    ; ("trust", keeper_trust_json ~include_receipt:false config m)
    ]

let execution_trust_keeper_rows (config : Workspace.config) =
  let names =
    (match Keeper_meta_store.keeper_names_result config with
     | Ok names -> names
     | Error detail ->
       Log.Keeper.warn "keeper dashboard rows: keeper names unread: %s" detail;
       [])
    @ Keeper_meta_store.configured_keeper_names config
    |> List.sort_uniq String.compare
  in
  let now_ts = Time_compat.now () in
  let results = Array.make (List.length names) None in
  Eio.Fiber.all
    (List.mapi
       (fun idx name () ->
         let row =
           try
             match
               Keeper_types_profile.load_keeper_profile_defaults_result_for_base_path
                 ~base_path:config.base_path
                 name
             with
             | Error error ->
               Some
                 (invalid_profile_dashboard_row ~keeper_name:name error
                  |> execution_trust_row_of_dashboard_row)
             | Ok _ ->
               (match Keeper_meta_store.read_meta config name with
                | Error _ | Ok None -> None
                | Ok (Some meta) ->
                  Some (execution_trust_row_of_meta ~now_ts config meta))
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn ->
             let error = Printexc.to_string exn in
             Keeper_fd_pressure.note_exception
               ~site:"keeper_dashboard.worker"
               exn;
             Log.Dashboard.error
               "keeper dashboard worker error (%s): %s"
               name
               error;
             Some
               (keeper_row_after_worker_failure config ~name ~error
                |> execution_trust_row_of_dashboard_row)
         in
         results.(idx) <- row)
       names);
  Array.to_list results |> List.filter_map Fun.id

let execution_trust_dashboard_observation (config : Workspace.config) =
  (* Building this surface from the generalized
     Keeper dashboard projection used to scan metrics, histories, goals,
     profiles, crash logs, and runtime contracts only to discard all but these
     eleven fields. Keep the producer specialized so refresh work stays
     proportional to execution-trust evidence. *)
  let keepers = execution_trust_keeper_rows config in
  let now = Unix.gettimeofday () in
  let keeper_names =
    (match Keeper_meta_store.keeper_names_result config with
     | Ok names -> names
     | Error detail ->
       Log.Keeper.warn "execution_receipts: keeper names unread: %s" detail;
       [])
  in
  let keepers_root = Workspace.keepers_runtime_dir config in
  let exists = Sys.file_exists keepers_root in
  let entry_count = count_execution_receipt_entries config keeper_names in
  let latest_ts = latest_receipt_ts_of_keeper_rows keepers in
  let coverage_gaps = execution_receipt_coverage_gaps config in
  let coverage_gap = List.rev coverage_gaps |> List.find_opt (fun _ -> true) in
  let next_deadline =
    Dashboard_tool_source_freshness.next_health_change_unix ~now ~exists
      ~entry_count ~latest_ts ~freshness_slo_s:execution_trust_freshness_slo_s
      ?coverage_gap ()
  in
  let json = `Assoc
    ([
      ("source", `String execution_trust_source);
      ("producer", `String execution_trust_producer);
      ("durable_store", `String (execution_receipt_store_pattern config));
      ("dashboard_surface", `String execution_trust_dashboard_surface);
      ("freshness_slo_s", `Float execution_trust_freshness_slo_s);
      ("entry_count", `Int entry_count);
      ("exists", `Bool exists);
      ("generated_at", `String (Masc_domain.now_iso ()));
      ("keepers", `List keepers);
      ("total", `Int (List.length keepers));
      ("coverage_gaps", `List coverage_gaps);
      ("coverage_gap_count", `Int (List.length coverage_gaps));
    ]
    @ Dashboard_tool_source_freshness.freshness_fields ~now latest_ts
    @ Dashboard_tool_source_freshness.health_fields
        ~now ~exists ~entry_count ~latest_ts
        ~freshness_slo_s:execution_trust_freshness_slo_s ?coverage_gap ())
  in
  json, next_deadline
;;

let execution_trust_dashboard_json config =
  fst (execution_trust_dashboard_observation config)
;;

(* Per-keeper snapshot/config rendering extracted to
   [Dashboard_http_keeper_snapshot] (godfile decomp). *)
include Dashboard_http_keeper_snapshot

module For_test = struct
  let keeper_row_after_worker_failure = keeper_row_after_worker_failure
end
