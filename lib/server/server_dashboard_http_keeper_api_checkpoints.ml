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
    ; "status", `String "available"
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

(* The fields, not the object: callers that splice this into a larger row need
   the association list, and taking it back apart from a [Yojson.Safe.t] forced
   them to handle a shape this function cannot produce. *)
let checkpoint_load_error_fields
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  : (string * Yojson.Safe.t) list
  =
  let status, kind, detail =
    match error with
    | Not_found -> "missing", "not_found", `Null
    | Store_error detail -> "unavailable", "store_error", `String detail
    | Parse_error detail -> "unavailable", "parse_error", `String detail
    | Io_error detail -> "unavailable", "io_error", `String detail
    | Sdk_other_error detail ->
      "unavailable", "sdk_other_error", `String detail
  in
  [ "status", `String status
  ; "error_kind", `String kind
  ; "error_detail", detail
  ]
;;

let checkpoint_load_error_json
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  =
  `Assoc (checkpoint_load_error_fields error)
;;

let current_checkpoint_error_json
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  =
  match error with
  | Not_found -> `Null
  | Store_error detail ->
    `Assoc [ "kind", `String "store_error"; "detail", `String detail ]
  | Parse_error detail ->
    `Assoc [ "kind", `String "parse_error"; "detail", `String detail ]
  | Io_error detail ->
    `Assoc [ "kind", `String "io_error"; "detail", `String detail ]
  | Sdk_other_error detail ->
    `Assoc [ "kind", `String "sdk_other_error"; "detail", `String detail ]
;;

let checkpoint_load_failure_json
      ~(source_kind : string)
      ~(snapshot_id : string)
      ~(path : string)
      ~(is_current : bool)
      (error : Keeper_checkpoint_store.checkpoint_load_error)
  =
  let identity_fields =
    [ "snapshot_id", `String snapshot_id
    ; "source_kind", `String source_kind
    ; "is_current", `Bool is_current
    ; "path", `String path
    ; "file_stat", stat_json_of_path path
    ]
  in
  `Assoc (identity_fields @ checkpoint_load_error_fields error)
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
    let current_json, current_history_snapshot_id, current_status, current_error =
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
          ~fallback_generation:meta.runtime.nonce
          checkpoint
        |> fun json -> Some json, current_history_snapshot_id, "available", `Null
      | Error error ->
        let status =
          match error with
          | Keeper_checkpoint_store.Not_found -> "missing"
          | Store_error _ | Parse_error _ | Io_error _ | Sdk_other_error _ ->
            "unavailable"
        in
        None, "", status, current_checkpoint_error_json error
    in
    let history_json, history_errors =
      Keeper_checkpoint_store.list_oas_history_files ~session_dir
      |> List.filter (fun snapshot_id ->
        snapshot_id <> current_history_snapshot_id)
      |> List.fold_left
           (fun (available, failures) snapshot_id ->
             let path =
               Keeper_checkpoint_store.oas_history_path ~session_dir ~snapshot_id
             in
             match
               Keeper_checkpoint_store.load_oas_history_file ~session_dir ~snapshot_id
             with
             | Ok checkpoint ->
               ( oas_checkpoint_summary_json
                   ~source_kind:"oas_history"
                   ~snapshot_id
                   ~path
                   ~is_current:false
                   ~fallback_generation:meta.runtime.nonce
                   checkpoint
                 :: available
               , failures )
             | Error error ->
               ( available
               , checkpoint_load_failure_json
                   ~source_kind:"oas_history"
                   ~snapshot_id
                   ~path
                   ~is_current:false
                   error
                 :: failures ))
           ([], [])
      |> fun (available, failures) -> List.rev available, List.rev failures
    in
    ( `OK
    , `Assoc
        [ "keeper", `String name
        ; "trace_id", `String trace_id
        ; "session_dir", `String session_dir
        ; ( "current"
          , match current_json with
            | Some json -> json
            | None -> `Null )
        ; "current_status", `String current_status
        ; "current_error", current_error
        ; "history", `List history_json
        ; "history_errors", `List history_errors
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
