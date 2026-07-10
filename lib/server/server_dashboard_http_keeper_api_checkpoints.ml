open Server_dashboard_http_keeper_api_types

let stat_json_of_path (path : string) =
  try
    let stat = Unix.stat path in
    `Assoc [ "size_bytes", `Int stat.st_size; "mtime", `Float stat.st_mtime ]
  with
  | Unix.Unix_error _ -> `Null
;;

let oas_checkpoint_summary_json
      ~(source_kind : string)
      ~(snapshot_id : string)
      ~(path : string)
      ~(is_current : bool)
      ~(fallback_generation : int)
      (checkpoint : Agent_sdk.Checkpoint.t)
  =
  let generation =
    Keeper_context_core.checkpoint_generation checkpoint ~fallback:fallback_generation
  in
  let messages = checkpoint.messages in
  `Assoc
    [ "snapshot_id", `String snapshot_id
    ; "source_kind", `String source_kind
    ; "is_current", `Bool is_current
    ; "path", `String path
    ; "created_at", `Float checkpoint.created_at
    ; "generation", `Int generation
    ; "message_count", `Int (List.length messages)
    ; ( "system_prompt_present"
      , `Bool
          (match checkpoint.system_prompt with
           | Some prompt -> Option.is_some (String_util.trim_to_option prompt)
           | None -> false) )
    ; ( "latest_preview", Json_util.string_opt_to_json (latest_preview_of_messages messages) )
    ; "file_stat", stat_json_of_path path
    ]
;;

let inventory_json (config : Workspace.config) (name : string)
  : [ `OK | `Not_found ] * Yojson.Safe.t
  =
  match Keeper_meta_store.read_meta_resolved config name with
  | Error msg -> `Not_found, `Assoc [ "error", `String msg ]
  | Ok None ->
    ( `Not_found
    , `Assoc [ "error", `String (Printf.sprintf "keeper %S not found" name) ] )
  | Ok (Some (_, meta)) ->
    let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
    let session_dir = Keeper_types_support.keeper_session_dir config trace_id in
    let current_path =
      Keeper_checkpoint_store.oas_checkpoint_path ~session_dir ~session_id:trace_id
    in
    let current_json =
      match Keeper_checkpoint_store.load_oas ~session_dir ~session_id:trace_id with
      | Ok checkpoint ->
        let current_history_snapshot_id =
          Keeper_checkpoint_store.oas_history_snapshot_id_of_checkpoint checkpoint
        in
        oas_checkpoint_summary_json
          ~source_kind:"oas_current"
          ~snapshot_id:(Filename.basename current_path)
          ~path:current_path
          ~is_current:true
          ~fallback_generation:meta.runtime.generation
          checkpoint
        |> fun json -> Some (json, current_history_snapshot_id)
      | Error _ -> None
    in
    let history_json =
      Keeper_checkpoint_store.list_oas_history_files ~session_dir
      |> List.filter (fun snapshot_id ->
        match current_json with
        | Some (_json, current_history_snapshot_id) ->
          snapshot_id <> current_history_snapshot_id
        | None -> true)
      |> List.filter_map (fun snapshot_id ->
        match
          Keeper_checkpoint_store.load_oas_history_file ~session_dir ~snapshot_id
        with
        | Ok checkpoint ->
          Some
            (oas_checkpoint_summary_json
               ~source_kind:"oas_history"
               ~snapshot_id
               ~path:(Keeper_checkpoint_store.oas_history_path ~session_dir ~snapshot_id)
               ~is_current:false
               ~fallback_generation:meta.runtime.generation
               checkpoint)
        | Error _ -> None)
    in
    ( `OK
    , `Assoc
        [ "keeper", `String name
        ; "trace_id", `String trace_id
        ; "session_dir", `String session_dir
        ; ( "current"
          , match current_json with
            | Some (json, _snapshot_id) -> json
            | None -> `Null )
        ; "history", `List history_json
        ] )
;;

let linked_artifact_json ~kind path =
  `Assoc
    [ "kind", `String kind
    ; "path", `String path
    ; "present", `Bool (Fs_compat.file_exists path)
    ; "file_stat", stat_json_of_path path
    ]
;;
