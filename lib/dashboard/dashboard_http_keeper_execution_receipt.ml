(** Execution-receipt path resolution + dashboard diagnostics, extracted
    from [dashboard_http_keeper.ml] (godfile decomp).

    Four helpers around the per-keeper execution-receipt JSONL store
    layout at `<masc_root>/keepers/<keeper_name>/execution-receipts/`:

    - [execution_receipt_dir config keeper_name] — canonical directory
      path for a single keeper's receipts.
    - [execution_receipt_store_pattern config] — glob pattern
      (`<masc_root>/keepers/*/execution-receipts`) used in dashboard
      surface metadata.
    - [count_execution_receipt_entries config keeper_names] — sums
      [Dated_jsonl.count_entries] across the provided keeper list,
      tolerating missing dirs (skip) and read failures (WARN log +
      contribute 0). Cancellation re-raises.
    - [execution_receipt_coverage_gaps config] — surfaces recent
      [Telemetry_coverage_gap] entries filtered to the
      [execution_trust_source] producer (50 most-recent entries).

    Pure helper move — sibling uses `include Dashboard_http_keeper_types`
    for [execution_trust_source]. All other references reach external
    modules. *)

include Dashboard_http_keeper_types

let execution_receipt_dir config keeper_name =
  Filename.concat
    (Filename.concat (Workspace.keepers_runtime_dir config)
       keeper_name)
    "execution-receipts"

let execution_receipt_store_pattern config =
  Filename.concat
    (Workspace.keepers_runtime_dir config)
    "*/execution-receipts"

let count_execution_receipt_entries config keeper_names =
  keeper_names
  |> List.fold_left
       (fun acc keeper_name ->
         let dir = execution_receipt_dir config keeper_name in
         if not (Sys.file_exists dir) then acc
         else
           acc
           +
           (match Dated_jsonl.create ~base_dir:dir () with
            | store -> Dated_jsonl.count_entries store
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn ->
              Log.Dashboard.warn
                "execution_trust receipt count failed for %s: %s"
                dir
                (Printexc.to_string exn);
              0))
       0

let execution_receipt_coverage_gaps_with_read_errors config =
  let gaps, read_errors =
    Telemetry_coverage_gap.read_recent_with_read_errors
    ~masc_root:(Workspace.masc_root_dir config)
    ~n:50
  in
  ( gaps
    |> List.filter (fun gap ->
         String.equal execution_trust_source
           (Safe_ops.json_string ~default:"" "source" gap)),
    read_errors )

let execution_receipt_coverage_gaps config =
  fst (execution_receipt_coverage_gaps_with_read_errors config)
