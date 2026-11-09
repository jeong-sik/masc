let sanitize_name name =
  Workspace_utils_backend_setup.sanitize_namespace_segment name

let chat_dirname = "keeper_chat"

let chat_dir base_dir =
  Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) chat_dirname

let chat_path ~base_dir ~keeper_name =
  Filename.concat (chat_dir base_dir) (sanitize_name keeper_name ^ ".jsonl")

let persistence_surface = "keeper_chat_store"

let record_persistence_read_drop ~reason () =
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_persistence_read_drops
    ~labels:[("surface", persistence_surface); ("reason", reason)]
    ()

let report_persistence_read_drop ~reason ~path ~detail =
  let reason_wire = Read_drop_reason.to_wire reason in
  Safe_ops.report_persistence_read_drop
    ~on_drop:(fun () -> record_persistence_read_drop ~reason:reason_wire ())
    ~surface:persistence_surface
    ~reason
    ~path
    ~detail

let report_store_failure ~operation ~keeper_name ~what exn =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string ChatStoreFailures)
    ~labels:[ "operation", Keeper_chat_store_operation.to_label operation ]
    ();
  let detail = Printexc.to_string exn in
  Log.Keeper.warn "keeper_chat_store: %s failed for %s: %s" what
    (sanitize_name keeper_name) detail;
  detail

let ensure_dir_once ~base_dir =
  ignore (Keeper_fs.ensure_dir (chat_dir base_dir))
