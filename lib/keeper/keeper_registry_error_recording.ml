(** Keeper error recording (Log + Otel_metric_store dedup + last_error persistence).

    Extracted from keeper_registry.ml (lines 456-506) as part of the
    godfile decomp campaign. The MASC/OAS Error-Warn Reduction Goal §P6
    deduplication logic + first/repeated emit policy lives here; the
    final CAS write to [last_error] goes through
    [Keeper_registry.set_last_error_entry] so this module does not need
    to know about the central Atomic. *)

let record_common ~base_path ?details name err persist =
  let details =
    match details with
    | Some _ as details -> details
    | None ->
      Keeper_sandbox_runtime.docker_mount_failure_details
        ~base_path_hash:(Keeper_sandbox_runtime.base_path_hash base_path)
        ~keeper_name:name
        ~output:err
        ()
  in
  (* MASC/OAS Error-Warn Reduction Goal §P6: same (keeper, error) was
     emitting at ERROR up to 96× in 30-min slices on production
     (system_log_2026-05-16 sample, 299 events/day; verifier
     sandbox_docker ~48%). First occurrence keeps ERROR — operators
     must still see *new* failure modes. Repeated occurrences log at
     ERROR again (symptom suppression removed). *)
  let kind, outcome =
    Keeper_recording_error_state.classify_outcome ~keeper:name ~error:err
  in
  let kind_label = Keeper_recording_error_state.error_kind_to_string kind in
  (match details with
   | Some details ->
     Log.Keeper.emit
       Log.Error
       ~details
       (Printf.sprintf "registry: recording error name=%s error=%s" name err)
   | None ->
     Log.Keeper.error "registry: recording error name=%s error=%s" name err);
  if outcome <> `First then
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string RecordingErrorDedup)
      ~labels:[ "keeper", name; "error_kind", kind_label ]
      ();
  persist ()
;;

let record ~base_path ?details name err =
  record_common ~base_path ?details name err (fun () ->
    Keeper_registry.set_last_error_entry ~base_path ~name err)
;;

let record_exact ?details (entry : Keeper_registry.registry_entry) err =
  record_common ~base_path:entry.base_path ?details entry.name err (fun () ->
    match Keeper_registry.set_last_error_exact entry err with
    | Keeper_registry.Exact_updated -> ()
    | Keeper_registry.Exact_update_missing ->
      Log.Keeper.warn
        "registry: exact error record skipped because lane is no longer registered name=%s"
        entry.name
    | Keeper_registry.Exact_update_replaced ->
      Log.Keeper.warn
        "registry: exact error record retained newer same-name lane name=%s"
        entry.name
    | Keeper_registry.Exact_update_invalid validation_error ->
      Log.Keeper.warn
        "registry: exact error record validation failed name=%s error=%s"
        entry.name
        (Keeper_registry.registry_entry_validation_error_to_string validation_error))
;;
