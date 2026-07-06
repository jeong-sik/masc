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
  let continuity_summary = continuity_summary_of_messages messages in
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
    ; ( "continuity_summary", Json_util.string_opt_to_json continuity_summary )
    ; "file_stat", stat_json_of_path path
    ]
;;

let checkpoint_load_error_kind = function
  | Keeper_checkpoint_store.Not_found -> "not_found"
  | Keeper_checkpoint_store.Store_error _ -> "store_error"
  | Keeper_checkpoint_store.Parse_error _ -> "parse_error"
  | Keeper_checkpoint_store.Io_error _ -> "io_error"
  | Keeper_checkpoint_store.Sdk_other_error _ -> "sdk_other_error"
;;

let checkpoint_load_error_detail = function
  | Keeper_checkpoint_store.Not_found -> None
  | Keeper_checkpoint_store.Store_error detail
  | Keeper_checkpoint_store.Parse_error detail
  | Keeper_checkpoint_store.Io_error detail
  | Keeper_checkpoint_store.Sdk_other_error detail ->
    Some detail
;;

let checkpoint_read_error_json ~source_kind ~snapshot_id ~path error =
  `Assoc
    [ "source_kind", `String source_kind
    ; "snapshot_id", `String snapshot_id
    ; "path", `String path
    ; "error_kind", `String (checkpoint_load_error_kind error)
    ; "detail", Json_util.string_opt_to_json (checkpoint_load_error_detail error)
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
    let current_json, current_status, current_read_errors =
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
        |> fun json -> Some (json, current_history_snapshot_id), "present", []
      | Error Keeper_checkpoint_store.Not_found -> None, "missing", []
      | Error error ->
        ( None
        , "read_error"
        , [ checkpoint_read_error_json
              ~source_kind:"oas_current"
              ~snapshot_id:(Filename.basename current_path)
              ~path:current_path
              error
          ] )
    in
    let history_json, history_read_errors =
      Keeper_checkpoint_store.list_oas_history_files ~session_dir
      |> List.filter (fun snapshot_id ->
        match current_json with
        | Some (_json, current_history_snapshot_id) ->
          snapshot_id <> current_history_snapshot_id
        | None -> true)
      |> List.fold_left
           (fun (items, read_errors) snapshot_id ->
              let path =
                Keeper_checkpoint_store.oas_history_path ~session_dir ~snapshot_id
              in
        match
          Keeper_checkpoint_store.load_oas_history_file ~session_dir ~snapshot_id
        with
        | Ok checkpoint ->
          ( (oas_checkpoint_summary_json
               ~source_kind:"oas_history"
               ~snapshot_id
               ~path
               ~is_current:false
               ~fallback_generation:meta.runtime.generation
               checkpoint
             :: items)
          , read_errors )
        | Error error ->
          ( items
          , checkpoint_read_error_json
              ~source_kind:"oas_history"
              ~snapshot_id
              ~path
              error
            :: read_errors ))
           ([], [])
      |> fun (items, read_errors) -> List.rev items, List.rev read_errors
    in
    let read_errors = current_read_errors @ history_read_errors in
    let read_error_count = List.length read_errors in
    ( `OK
    , `Assoc
        [ "keeper", `String name
        ; "trace_id", `String trace_id
        ; "session_dir", `String session_dir
        ; "current_status", `String current_status
        ; ( "current"
          , match current_json with
            | Some (json, _snapshot_id) -> json
            | None -> `Null )
        ; "history", `List history_json
        ; "read_error_count", `Int read_error_count
        ; "read_errors", `List read_errors
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
