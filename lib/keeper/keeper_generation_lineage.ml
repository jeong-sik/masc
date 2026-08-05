open Keeper_meta_contract

let generation_id ~keeper_name ~generation ~trace_id =
  Printf.sprintf "%s:%d:%s" keeper_name generation trace_id

let load_json_file_opt path =
  if not (Fs_compat.file_exists path) then None
  else
    let surface = "keeper_generation_lineage_manifest" in
    let report_drop ~reason ~detail =
      Safe_ops.report_persistence_read_drop
        ~on_drop:(fun () ->
          Otel_metric_store.inc_counter Otel_metric_store.metric_persistence_read_drops
            ~labels:[("surface", surface); ("reason", reason)]
            ())
        ~surface
        ~reason
        ~path
        ~detail
    in
    try
      let contents = Fs_compat.load_file path in
      try Some (Yojson.Safe.from_string contents)
      with Yojson.Json_error detail ->
        report_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~detail;
        None
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        report_drop
          ~reason:Safe_ops.persistence_read_drop_reason_entry_load_error
          ~detail:(Printexc.to_string exn);
        None

let load_jsonl_file path =
  if not (Fs_compat.file_exists path) then []
  else
    try Fs_compat.load_jsonl path
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> []

let rec take n xs =
  if n <= 0 then []
  else
    match xs with
    | [] -> []
    | x :: tl -> x :: take (n - 1) tl

let surface_json (config : Workspace.config) (meta : keeper_meta) ~recent_limit =
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let manifest_path = Keeper_types_support.keeper_generation_manifest_path config trace_id in
  let index_path = Keeper_types_support.keeper_generation_index_path config meta.name in
  let manifest = load_json_file_opt manifest_path in
  let index_entries = load_jsonl_file index_path in
  let recent =
    index_entries |> List.rev |> take (max 0 recent_limit)
  in
  `Assoc
    [
      ("current_generation", `Int meta.runtime.nonce);
      ("current_trace_id", `String trace_id);
      ( "generation_id",
        `String
          (generation_id
             ~keeper_name:meta.name
             ~generation:meta.runtime.nonce
             ~trace_id) );
      ("trace_history_count", `Int (List.length meta.runtime.trace_history));
      ("manifest_path", `String manifest_path);
      ("index_path", `String index_path);
      ("manifest_available", `Bool (Option.is_some manifest));
      ("manifest", Json_util.option_to_yojson Fun.id manifest);
      ("recent_count", `Int (List.length index_entries));
      ("recent", `List recent);
    ]
