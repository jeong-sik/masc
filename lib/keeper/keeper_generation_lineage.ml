open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let identity_fields : (string * (keeper_meta -> string)) list =
  [ "instructions", (fun m -> m.instructions) ]


let generation_id ~keeper_name ~generation ~trace_id =
  Printf.sprintf "%s:%d:%s" keeper_name generation trace_id

let identity_pairs (meta : keeper_meta) =
  List.map (fun (field, getter) -> (field, getter meta)) identity_fields

let identity_snapshot_json (meta : keeper_meta) =
  `Assoc
    (identity_fields
    |> List.map (fun (field, getter) -> (field, `String (getter meta))))

let classify_identity_fields
    ~(previous : (string * string) list)
    ~(current : (string * string) list) =
  let current_map = List.to_seq current |> Hashtbl.of_seq in
  List.fold_left
    (fun (inherited, changed, dropped) (field, before) ->
      let after =
        match Hashtbl.find_opt current_map field with
        | Some value -> value
        | None -> ""
      in
      let before_trimmed = String.trim before in
      let after_trimmed = String.trim after in
      if String.equal before after then
        (field :: inherited, changed, dropped)
      else if before_trimmed <> "" && after_trimmed = "" then
        (inherited, changed, field :: dropped)
      else
        (inherited, field :: changed, dropped))
    ([], [], [])
    previous
  |> fun (inherited, changed, dropped) ->
  (List.rev inherited, List.rev changed, List.rev dropped)

let inheritance_delta_json ~(parent : keeper_meta) ~(child : keeper_meta) =
  let inherited_fields, changed_fields, dropped_fields =
    classify_identity_fields
      ~previous:(identity_pairs parent)
      ~current:(identity_pairs child)
  in
  `Assoc
    [
      ("mode", `String "identity_only");
      ("inherited_fields", Json_util.json_string_list inherited_fields);
      ("changed_fields", Json_util.json_string_list changed_fields);
      ("dropped_fields", Json_util.json_string_list dropped_fields);
    ]

let manifest_json
    ~(parent : keeper_meta)
    ~(child : keeper_meta)
    ~(parent_trace_id : string)
    ~(trigger_reason : string)
    ~(context_ratio : float) =
  (* RFC-0132 PR-2: lineage emit surface = external boundary; redact via SSOT. *)
  let model =
    Boundary_redaction.to_string Boundary_redaction.runtime_model_label
  in
  let child_trace_id = Keeper_id.Trace_id.to_string child.runtime.trace_id in
  let parent_generation = parent.runtime.generation in
  let child_generation = child.runtime.generation in
  let inheritance_delta = inheritance_delta_json ~parent ~child in
  `Assoc
    [
      ("schema_version", `String "keeper_generation_lineage_v1");
      ("keeper_name", `String child.name);
      ("generation", `Int child_generation);
      ("trace_id", `String child_trace_id);
      ( "generation_id",
        `String
          (generation_id
             ~keeper_name:child.name
             ~generation:child_generation
             ~trace_id:child_trace_id) );
      ("parent_generation", `Int parent_generation);
      ("parent_trace_id", `String parent_trace_id);
      ( "parent_generation_id",
        `String
          (generation_id
             ~keeper_name:child.name
             ~generation:parent_generation
             ~trace_id:parent_trace_id) );
      ("created_at", `String child.updated_at);
      ("trigger_reason", `String trigger_reason);
      ("context_ratio", `Float context_ratio);
      ("to_model", `String model);
      ("same_keeper_identity", `Bool true);
      ("identity_snapshot", identity_snapshot_json child);
      ("inheritance_delta", inheritance_delta);
    ]

let index_entry_json
    ~(manifest_path : string)
    ~(parent : keeper_meta)
    ~(child : keeper_meta)
    ~(parent_trace_id : string)
    ~(trigger_reason : string)
    ~(context_ratio : float) =
  (* RFC-0132 PR-2: lineage emit surface = external boundary; redact via SSOT. *)
  let model =
    Boundary_redaction.to_string Boundary_redaction.runtime_model_label
  in
  let child_trace_id = Keeper_id.Trace_id.to_string child.runtime.trace_id in
  let parent_generation = parent.runtime.generation in
  let child_generation = child.runtime.generation in
  let inherited_fields, changed_fields, dropped_fields =
    classify_identity_fields
      ~previous:(identity_pairs parent)
      ~current:(identity_pairs child)
  in
  `Assoc
    [
      ("timestamp", `Float (Time_compat.now ()));
      ("created_at", `String child.updated_at);
      ("keeper_name", `String child.name);
      ("generation", `Int child_generation);
      ("trace_id", `String child_trace_id);
      ( "generation_id",
        `String
          (generation_id
             ~keeper_name:child.name
             ~generation:child_generation
             ~trace_id:child_trace_id) );
      ("parent_generation", `Int parent_generation);
      ("parent_trace_id", `String parent_trace_id);
      ( "parent_generation_id",
        `String
          (generation_id
             ~keeper_name:child.name
             ~generation:parent_generation
             ~trace_id:parent_trace_id) );
      ("trigger_reason", `String trigger_reason);
      ("context_ratio", `Float context_ratio);
      ("to_model", `String model);
      ("identity_inherited_fields", Json_util.json_string_list inherited_fields);
      ("identity_changed_fields", Json_util.json_string_list changed_fields);
      ("identity_dropped_fields", Json_util.json_string_list dropped_fields);
      ("manifest_path", `String manifest_path);
    ]

let record_handoff_artifacts
    ~(config : Workspace.config)
    ~(parent : keeper_meta)
    ~(child : keeper_meta)
    ~(parent_trace_id : string)
    ~(trigger_reason : string)
    ~(context_ratio : float) =
  let child_trace_id = Keeper_id.Trace_id.to_string child.runtime.trace_id in
  let manifest_path =
    Keeper_types_support.keeper_generation_manifest_path config child_trace_id
  in
  let index_path = Keeper_types_support.keeper_generation_index_path config child.name in
  let manifest =
    manifest_json
      ~parent ~child ~parent_trace_id ~trigger_reason ~context_ratio
  in
  let index_entry =
    index_entry_json
      ~manifest_path
      ~parent ~child ~parent_trace_id ~trigger_reason ~context_ratio
  in
  ignore (Keeper_fs.ensure_dir (Filename.dirname manifest_path));
  match
    Fs_compat.save_file_atomic manifest_path (Yojson.Safe.pretty_to_string manifest)
  with
  | Ok () ->
      (try
         Keeper_types_support.append_jsonl_line index_path index_entry
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string GenerationLineageFailures)
             ~labels:[("keeper", child.name); ("site", Keeper_generation_lineage_failure_site.(to_label Index_append))]
             ();
           Log.Keeper.warn ~keeper_name:child.name
             "failed to append generation index %s: %s"
             index_path (Printexc.to_string exn))
  | Error err ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string GenerationLineageFailures)
        ~labels:[("keeper", child.name); ("site", Keeper_generation_lineage_failure_site.(to_label Manifest_save))]
        ();
      Log.Keeper.warn ~keeper_name:child.name
        "failed to save generation manifest %s: %s"
        manifest_path err

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
      ("current_generation", `Int meta.runtime.generation);
      ("current_trace_id", `String trace_id);
      ( "generation_id",
        `String
          (generation_id
             ~keeper_name:meta.name
             ~generation:meta.runtime.generation
             ~trace_id) );
      ("trace_history_count", `Int (List.length meta.runtime.trace_history));
      ("manifest_path", `String manifest_path);
      ("index_path", `String index_path);
      ("manifest_available", `Bool (Option.is_some manifest));
      ("manifest", Json_util.option_to_yojson Fun.id manifest);
      ("recent_count", `Int (List.length index_entries));
      ("recent", `List recent);
    ]
