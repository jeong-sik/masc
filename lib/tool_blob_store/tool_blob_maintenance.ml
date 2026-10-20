module String_set = Set_util.StringSet

module Artifact_reference_set = Set.Make (struct
  type t = Tool_output.artifact_ref

  let compare left right =
    match String.compare left.Tool_output.sha256 right.Tool_output.sha256 with
    | 0 -> String.compare left.mime right.mime
    | order -> order
end)

type mode =
  | Observe_only
  | Delete_previous_candidates

type error =
  | Durable_source_stat_failed of
      { path : string
      ; reason : string
      }
  | Durable_source_read_failed of
      { path : string
      ; reason : string
      }
  | Durable_source_parse_failed of
      { path : string
      ; line : int
      ; detail : string
      }
  | Malformed_artifact_reference of
      { path : string
      ; line : int
      ; offset : int
      ; detail : string
      }
  | Malformed_structured_artifact_reference of
      { path : string
      ; line : int
      ; detail : string
      }
  | Artifact_manifest_read_failed of
      { sha256 : string
      ; reason : string
      }
  | Artifact_manifest_invalid of
      { sha256 : string
      ; detail : string
      }
  | Candidate_snapshot_invalid of
      { path : string
      ; detail : string
      }
  | Candidate_snapshot_read_failed of
      { path : string
      ; detail : string
      }
  | Candidate_snapshot_write_failed of
      { path : string
      ; detail : string
      }
  | Blob_listing_failed of Tool_blob_store.list_error
  | Blob_delete_failed of Tool_blob_store.delete_error

type report =
  { live_references : int
  ; blobs_observed : int
  ; candidates_recorded : int
  ; deleted : int
  }

let error_to_string = function
  | Durable_source_stat_failed { path; reason } ->
    Printf.sprintf "durable source stat failed path=%s: %s" path reason
  | Durable_source_read_failed { path; reason } ->
    Printf.sprintf "durable source read failed path=%s: %s" path reason
  | Durable_source_parse_failed { path; line; detail } ->
    Printf.sprintf
      "durable source parse failed path=%s line=%d: %s"
      path
      line
      detail
  | Malformed_artifact_reference { path; line; offset; detail } ->
    Printf.sprintf
      "malformed artifact reference path=%s line=%d offset=%d: %s"
      path
      line
      offset
      detail
  | Malformed_structured_artifact_reference { path; line; detail } ->
    Printf.sprintf
      "malformed structured artifact reference path=%s line=%d: %s"
      path
      line
      detail
  | Artifact_manifest_read_failed { sha256; reason } ->
    Printf.sprintf "artifact manifest read failed sha256=%s: %s" sha256 reason
  | Artifact_manifest_invalid { sha256; detail } ->
    Printf.sprintf "artifact manifest invalid sha256=%s: %s" sha256 detail
  | Candidate_snapshot_invalid { path; detail } ->
    Printf.sprintf "blob maintenance candidate snapshot invalid path=%s: %s" path detail
  | Candidate_snapshot_read_failed { path; detail } ->
    Printf.sprintf
      "blob maintenance candidate snapshot read failed path=%s: %s"
      path
      detail
  | Candidate_snapshot_write_failed { path; detail } ->
    Printf.sprintf "blob maintenance candidate snapshot write failed path=%s: %s" path detail
  | Blob_listing_failed error ->
    Printf.sprintf
      "blob listing failed path=%s: %s"
      error.Tool_blob_store.path
      error.reason
  | Blob_delete_failed error ->
    Printf.sprintf
      "blob delete failed sha256=%s path=%s: %s"
      error.Tool_blob_store.sha256
      error.path
      error.reason
;;

let candidate_snapshot_path ~base_path =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       "tool_blob_maintenance")
    "candidates.json"
;;

let add_references ~path ~line references text =
  match Tool_output.decode_from_agent_core text with
  | Tool_output.Not_marker -> Ok references
  | Tool_output.Invalid_marker { detail } ->
    Error
      (Malformed_artifact_reference
         { path
         ; line
         ; offset = 0
         ; detail
         })
  | Tool_output.Decoded reference ->
    let canonical =
      Tool_output.encode_for_agent_core (Tool_output.Stored reference)
    in
    if String.equal text canonical
    then Ok (Artifact_reference_set.add reference references)
    else
      Error
        (Malformed_artifact_reference
           { path
           ; line
           ; offset = 0
           ; detail = "artifact marker is not in canonical wire form"
           })
;;

type reference_scan_context =
  | Durable_value
  | Route_evidence
  | Route_evidence_composable_output

let child_reference_scan_context context key =
  match context, key with
  | Durable_value, "route_evidence" -> Route_evidence
  | Route_evidence, "composable_output" -> Route_evidence_composable_output
  | ( Durable_value
    | Route_evidence
    | Route_evidence_composable_output ),
    _ ->
    Durable_value
;;

let rec references_in_json
          ?(context = Durable_value)
          ~path
          ~line
          references
  = function
  | `String text -> add_references ~path ~line references text
  | (`Assoc fields as json) ->
    (match Tool_output.normalized_artifact_ref_of_json json with
     | Tool_output.Decoded_normalized_artifact_ref reference ->
       Ok (Artifact_reference_set.add reference references)
     | Tool_output.Invalid_normalized_artifact_ref { detail } ->
       Error
         (Malformed_structured_artifact_reference
            { path; line; detail })
     | Tool_output.Not_normalized_artifact_ref ->
       List.fold_left
         (fun result (key, value) ->
            match context, key with
            | Route_evidence_composable_output, "schema" -> result
            | ( Durable_value
              | Route_evidence
              | Route_evidence_composable_output ),
              _ ->
              Result.bind result (fun current ->
                references_in_json
                  ~context:(child_reference_scan_context context key)
                  ~path
                  ~line
                  current
                  value))
         (Ok references)
         fields)
  | `List values ->
    List.fold_left
      (fun result value ->
         Result.bind result (fun current ->
           references_in_json ~path ~line current value))
      (Ok references)
      values
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _ ->
    Ok references
;;

let references_in_file ~ownership_root path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error ->
    Error
      (Durable_source_read_failed
         { path
         ; reason =
             Fs_compat.owned_regular_file_read_error_to_string error
         })
  | Ok None ->
    Error
      (Durable_source_read_failed
         { path; reason = "durable source disappeared during scan" })
  | Ok (Some payload) ->
    try
      references_in_json
        ~path
        ~line:1
        Artifact_reference_set.empty
        (Yojson.Safe.from_string payload)
    with
    | Yojson.Json_error _ ->
      payload
      |> String.split_on_char '\n'
      |> List.fold_left
           (fun (line_number, result) line ->
              let next =
                Result.bind result (fun references ->
                  if String.equal (String.trim line) "" then Ok references
                  else try
                    references_in_json
                      ~path
                      ~line:line_number
                      references
                      (Yojson.Safe.from_string line)
                  with
                  | Yojson.Json_error detail ->
                    (* The registered durable sources admit JSON documents,
                       JSONL rows, or an exact canonical marker row. A row we
                       cannot decode is not evidence of an empty reference set. *)
                    (match Tool_output.decode_from_agent_core line with
                     | Tool_output.Not_marker ->
                      Error
                        (Durable_source_parse_failed
                           { path
                           ; line = line_number
                           ; detail
                           })
                     | Tool_output.Decoded _ | Tool_output.Invalid_marker _ ->
                      add_references
                        ~path
                        ~line:line_number
                        references
                        line))
              in
               line_number + 1, next)
            (1, Ok Artifact_reference_set.empty)
       |> snd
;;

let references_in_chat_operation_store ~ownership_root path =
  match Fs_compat.load_owned_regular_file ~ownership_root path with
  | Error error ->
    Error
      (Durable_source_read_failed
         { path
         ; reason = Fs_compat.owned_regular_file_read_error_to_string error
         })
  | Ok None ->
    Error
      (Durable_source_read_failed
         { path; reason = "durable source disappeared during scan" })
  | Ok (Some _) ->
    (match Keeper_chat_operation_store.inspect_durable_records ~path with
     | Error error ->
       Error
         (Durable_source_parse_failed
            { path
            ; line = 1
            ; detail = Keeper_chat_operation_store.error_to_string error
            })
     | Ok Keeper_chat_operation_store.Missing_durable_store ->
       Error
         (Durable_source_read_failed
            { path; reason = "durable source disappeared during scan" })
     | Ok
         (Keeper_chat_operation_store.Stored_durable_records
           { chat_operations; batch_member_inputs; semantic_executions }) ->
       let fold_json result json =
         Result.bind result (fun references ->
           references_in_json ~path ~line:1 references json)
       in
       let with_operations =
         List.fold_left
           (fun result operation ->
              fold_json result (Keeper_chat_operation.to_json operation))
           (Ok Artifact_reference_set.empty)
           chat_operations
       in
       let with_batch_inputs =
         List.fold_left fold_json with_operations batch_member_inputs
       in
       List.fold_left
         (fun result (execution : Keeper_semantic_execution.t) ->
            let after_record =
              fold_json result (Keeper_semantic_execution.to_json execution)
            in
            match execution.phase with
            | Keeper_semantic_execution.Recovering { origin; _ } ->
              (match origin with
               | Keeper_semantic_execution.Gate_binding { preparation; _ } ->
                 (match preparation with
                  | Keeper_semantic_execution.Prepared_agent_core
                      { canonical_checkpoint_bytes; _ } ->
                    Result.bind after_record (fun references ->
                      match Yojson.Safe.from_string canonical_checkpoint_bytes with
                      | checkpoint_json ->
                        references_in_json ~path ~line:1 references checkpoint_json
                      | exception Yojson.Json_error detail ->
                        Error (Durable_source_parse_failed { path; line = 1; detail }))
                  | Keeper_semantic_execution.Prepared_official_client _ ->
                    after_record)
               | Keeper_semantic_execution.Unconfirmed_sources
               | Keeper_semantic_execution.Confirmed_undispatched
               | Keeper_semantic_execution.Checkpointed _
               | Keeper_semantic_execution.Official_checkpointed _
               | Keeper_semantic_execution.Interrupted_execution
               | Keeper_semantic_execution.Runtime_retry _
               | Keeper_semantic_execution.Gate_wait _ ->
                 after_record)
            | Keeper_semantic_execution.Preparing
            | Keeper_semantic_execution.Ready
            | Keeper_semantic_execution.Running
            | Keeper_semantic_execution.Resuming_runtime_retry _
            | Keeper_semantic_execution.Resuming_gate _
            | Keeper_semantic_execution.Suspended _
            | Keeper_semantic_execution.Settled _ ->
              after_record)
         with_batch_inputs
         semantic_executions)
;;

let durable_consumer_basenames =
  [ "gate"
  ; Common.keepers_runtime_dirname
  ; "keeper_chat"
  ; "messages"
  (* Prepared evidence remains owned even before its message commits. *)
  ; "lane-addons/broadcasts"
  ; "tool_calls"
  ; "traces"
  (* The bounded diagnostic store owns every blob reference for as long as
     its dated JSONL row remains inside wire-capture retention. *)
  ; "wire-capture"
  (* These stores can be the sole durable owners of a completed composition,
     independently of a surviving Keeper transcript or tool-call row. *)
  ; "skill-composition-evidence-v1"
  ; "keeper_msg_requests"
  (* Published reports own all revisions independently of chat/log retention. *)
  ; "published_artifacts"
  ]
;;

let same_directory_snapshot (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev
  && left.st_ino = right.st_ino
  && left.st_kind = Unix.S_DIR
  && right.st_kind = Unix.S_DIR
  && left.st_size = right.st_size
  && left.st_mtime = right.st_mtime
  && left.st_ctime = right.st_ctime
;;

(* Where blob references live, as data. Every durable consumer writes under
   the workspace root [<base>/.masc], the same BasePath the blob store
   belongs to. *)
type consumer_source =
  | Tree of string (* scanned recursively; an absent root holds no references *)
  | Optional_file of string (* a single file; absent means no references *)

(* The Board posts file comes from the caller ([Board_paths] in production):
   this library sits below Board, so it neither names the file nor depends on
   the module that does. *)
let workspace_sources ~board_posts_file ~workspace_masc_dir =
  List.map
    (fun basename -> Tree (Filename.concat workspace_masc_dir basename))
    durable_consumer_basenames
  @ [ Optional_file (board_posts_file ~workspace_masc_dir) ]
;;

let unix_reason fn arg code =
  Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
;;

let live_references ~base_path ~board_posts_file =
  let read_directory path =
    let inspect () =
      match
        Fs_compat.inspect_owned_directory_chain
          ~ownership_root:base_path
          path
      with
      | Ok observation -> Ok observation
      | Error rejection ->
        Error
          (Durable_source_stat_failed
            { path
             ; reason =
                 Fs_compat.owned_directory_chain_rejection_to_string
                   rejection
             })
    in
    match inspect () with
    | Error _ as error -> error
    | Ok Fs_compat.Owned_directory_missing -> Ok None
    | Ok (Fs_compat.Owned_directory before) ->
      try
        let entries = Sys.readdir path in
        match inspect () with
        | Error _ as error -> error
        | Ok Fs_compat.Owned_directory_missing ->
          Error
            (Durable_source_stat_failed
               { path; reason = "directory disappeared during scan" })
        | Ok (Fs_compat.Owned_directory after) ->
          if same_directory_snapshot before after
          then Ok (Some entries)
          else
            Error
              (Durable_source_stat_failed
                 { path; reason = "directory identity changed during scan" })
      with
      | Sys_error reason ->
        Error (Durable_source_stat_failed { path; reason })
      | Unix.Unix_error (code, fn, arg) ->
        Error
          (Durable_source_stat_failed
             { path
             ; reason =
                 Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
             })
  in
  let rec scan_entry path references =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR -> scan_directory path references
      | Unix.S_REG ->
        let basename = Filename.basename path in
        (* Offline maintenance holds the exclusive BasePath writer lease.
           Leftover [.atomic_*.tmp] staging bytes are unpublished, rather
           than authoritative durable-source rows; an incomplete payload
           must not fail their JSONL scan. This skip does not synchronize
           online writers or rescan a target renamed after [read_directory]. *)
        if Fs_compat.is_atomic_orphan_name basename
        then Ok references
        else if Common.is_tool_call_read_index_file basename
        then Ok references
        else if String.equal basename Common.chat_operation_store_basename
        then
          (* Keeper_chat_operation_store keeps its authoritative SQLite store
             at [keepers/<keeper>/chat-operations.sqlite3]. Inspect its active
             operations, semantic executions, and prepared Gate checkpoints
             through the SQLite store reader rather than raw JSONL text scan. *)
          Result.map
            (Artifact_reference_set.union references)
            (references_in_chat_operation_store ~ownership_root:base_path path)
        else if Common.is_chat_operation_store_sidecar_file basename
        then
          let db_path =
            Filename.concat
              (Filename.dirname path)
              Common.chat_operation_store_basename
          in
          if Sys.file_exists db_path
          then Ok references
          else
            (match
               Keeper_chat_operation_store.inspect_outstanding ~path:db_path
             with
             | Error error ->
               Error
                 (Durable_source_parse_failed
                    { path
                    ; line = 1
                    ; detail =
                        Keeper_chat_operation_store.error_to_string error
                    })
             | Ok
                 ( Keeper_chat_operation_store.Missing_store
                 | Keeper_chat_operation_store.Stored_operations _ ) ->
               Error
                 (Durable_source_parse_failed
                    { path
                    ; line = 1
                    ; detail = "operation journal exists without its database"
                    }))
        else
          Result.map
            (Artifact_reference_set.union references)
            (references_in_file ~ownership_root:base_path path)
        | Unix.S_LNK ->
          Error
            (Durable_source_stat_failed
               { path
               ; reason = "symbolic links are not durable maintenance sources"
               })
        | Unix.S_CHR
        | Unix.S_BLK
        | Unix.S_FIFO
        | Unix.S_SOCK ->
        Ok references
    with
    | Sys_error reason -> Error (Durable_source_stat_failed { path; reason })
    | Unix.Unix_error (code, fn, arg) ->
      Error
        (Durable_source_stat_failed
           { path
           ; reason =
               Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
           })
  and scan_directory path references =
    match read_directory path with
    | Error _ as error -> error
    | Ok None -> Ok references
    | Ok (Some entries) ->
      entries
      |> Array.to_list
      |> List.sort String.compare
      |> List.fold_left
           (fun result name ->
              Result.bind result (fun current ->
                scan_entry (Filename.concat path name) current))
           (Ok references)
  in
  let scan_source references = function
    | Tree root -> scan_directory root references
    | Optional_file path ->
      (match Unix.lstat path with
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok references
       | exception Unix.Unix_error (code, fn, arg) ->
         Error (Durable_source_stat_failed { path; reason = unix_reason fn arg code })
       | _ -> scan_entry path references)
  in
  workspace_sources
    ~board_posts_file
    ~workspace_masc_dir:(Common.masc_dir_from_base_path ~base_path)
  |> List.fold_left
       (fun result source ->
          Result.bind result (fun progress -> scan_source progress source))
       (Ok Artifact_reference_set.empty)
;;

let expand_artifact_manifests ~store references =
  let rec expand expanded references = function
    | [] -> Ok references
    | reference :: rest
      when not
             (String.equal
                reference.Tool_output.mime
                Tool_output.artifact_manifest_mime) ->
      expand expanded references rest
    | reference :: rest
      when String_set.mem reference.Tool_output.sha256 expanded ->
      expand expanded references rest
    | reference :: rest ->
      let sha256 = reference.Tool_output.sha256 in
      let expanded = String_set.add sha256 expanded in
      (match Tool_blob_store.fetch store ~sha256 with
       | Error error ->
         Error
           (Artifact_manifest_read_failed
              { sha256; reason = Tool_blob_store.fetch_error_to_string error })
       | Ok None ->
         Error
           (Artifact_manifest_read_failed
              { sha256; reason = "referenced manifest blob is absent" })
       | Ok (Some payload) ->
         let decoded =
           try
             Yojson.Safe.from_string payload
             |> Tool_output.artifact_manifest_of_json
           with
           | Yojson.Json_error detail ->
             Tool_output.Invalid_artifact_manifest { detail }
         in
         (match decoded with
          | Tool_output.Decoded_artifact_manifest { artifact_refs; _ } ->
            let references, added =
              List.fold_left
                (fun (references, added) child ->
                   if Artifact_reference_set.mem child references
                   then references, added
                   else Artifact_reference_set.add child references, child :: added)
                (references, [])
                artifact_refs
            in
            expand expanded references (List.rev_append added rest)
          | Tool_output.Not_artifact_manifest ->
            Error
              (Artifact_manifest_invalid
                 { sha256; detail = "manifest MIME requires the canonical schema" })
          | Tool_output.Invalid_artifact_manifest { detail } ->
            Error (Artifact_manifest_invalid { sha256; detail })))
  in
  expand String_set.empty references (Artifact_reference_set.elements references)
;;

let candidate_snapshot_to_json candidates =
  `Assoc
    [ "schema_version", `Int 1
    ; ( "unreferenced_candidates"
      , `List
          (String_set.elements candidates
           |> List.map (fun sha256 -> `String sha256)) )
    ]
;;

let candidate_snapshot_of_json ~path = function
  | `Assoc
      [ "schema_version", `Int 1
      ; "unreferenced_candidates", `List candidates
      ] ->
    let rec decode acc = function
      | [] -> Ok acc
      | `String sha256 :: rest ->
        (match Tool_blob_store.validate_sha256 sha256 with
         | Ok () -> decode (String_set.add sha256 acc) rest
         | Error invalid ->
           Error
             (Candidate_snapshot_invalid
                { path
                ; detail =
                    Tool_blob_store.invalid_sha256_to_string invalid
                }))
      | _ ->
        Error
          (Candidate_snapshot_invalid
             { path; detail = "candidate hashes must be strings" })
    in
    decode String_set.empty candidates
  | _ ->
    Error
      (Candidate_snapshot_invalid
         { path
         ; detail =
             "expected exact schema_version=1 and unreferenced_candidates"
         })
;;

let load_candidate_snapshot ~base_path =
  let path = candidate_snapshot_path ~base_path in
  match Fs_compat.load_owned_regular_file ~ownership_root:base_path path with
  | Ok None -> Ok String_set.empty
  | Ok (Some payload) ->
    (try
       Yojson.Safe.from_string payload |> candidate_snapshot_of_json ~path
     with
    | Yojson.Json_error detail ->
      Error (Candidate_snapshot_invalid { path; detail }))
  | Error error ->
    Error
      (Candidate_snapshot_read_failed
         { path
         ; detail =
             Fs_compat.owned_regular_file_read_error_to_string error
         })
;;

let save_candidate_snapshot ~base_path candidates =
  let path = candidate_snapshot_path ~base_path in
  let parent = Filename.dirname path in
  let payload =
    candidate_snapshot_to_json candidates
    |> Yojson.Safe.pretty_to_string
  in
  let inspect_parent () =
    match
      Fs_compat.inspect_owned_directory_chain
        ~ownership_root:base_path
        parent
    with
    | Ok observation -> Ok observation
    | Error rejection ->
      Error
        (Fs_compat.owned_directory_chain_rejection_to_string rejection)
  in
  let open Result.Syntax in
  let* before =
    match inspect_parent () with
    | Error detail ->
      Error (Candidate_snapshot_write_failed { path; detail })
    | Ok Fs_compat.Owned_directory_missing ->
      Safe_ops.handle
        (fun () ->
           Fs_compat.mkdir_p parent;
           match inspect_parent () with
           | Ok (Fs_compat.Owned_directory stats) -> Ok stats
           | Ok Fs_compat.Owned_directory_missing ->
             Error
               (Candidate_snapshot_write_failed
                  { path; detail = "candidate snapshot parent was not created" })
           | Error detail ->
             Error (Candidate_snapshot_write_failed { path; detail }))
        (fun exn ->
           Error
             (Candidate_snapshot_write_failed
                { path; detail = Printexc.to_string exn }))
    | Ok (Fs_compat.Owned_directory stats) -> Ok stats
  in
  let* () =
    match Fs_compat.save_file_atomic_strict path payload with
    | Ok () -> Ok ()
    | Error detail ->
      Error (Candidate_snapshot_write_failed { path; detail })
  in
  match inspect_parent () with
  | Ok (Fs_compat.Owned_directory after)
    when before.st_dev = after.st_dev && before.st_ino = after.st_ino ->
    Ok ()
  | Ok (Fs_compat.Owned_directory _) ->
    Error
      (Candidate_snapshot_write_failed
         { path; detail = "candidate snapshot parent identity changed" })
  | Ok Fs_compat.Owned_directory_missing ->
    Error
      (Candidate_snapshot_write_failed
         { path; detail = "candidate snapshot parent disappeared" })
  | Error detail ->
    Error (Candidate_snapshot_write_failed { path; detail })
;;

let run ~base_path ~board_posts_file ~mode =
  let open Result.Syntax in
  let store = Tool_blob_store.create ~base_path in
  let* direct_live = live_references ~base_path ~board_posts_file in
  let* live_references = expand_artifact_manifests ~store direct_live in
  let live =
    Artifact_reference_set.fold
      (fun reference hashes ->
         String_set.add reference.Tool_output.sha256 hashes)
      live_references
      String_set.empty
  in
  let* previous_candidates = load_candidate_snapshot ~base_path in
  let* blob_list =
    match Tool_blob_store.list_all_result store with
    | Ok blobs -> Ok blobs
    | Error error -> Error (Blob_listing_failed error)
  in
  let blobs =
    blob_list
    |> List.fold_left
         (fun acc sha256 -> String_set.add sha256 acc)
         String_set.empty
  in
  let current_candidates = String_set.diff blobs live in
  let* () = save_candidate_snapshot ~base_path current_candidates in
  let deletable =
    match mode with
    | Observe_only -> String_set.empty
    | Delete_previous_candidates ->
      String_set.inter previous_candidates current_candidates
  in
  let* deleted =
    String_set.fold
      (fun sha256 result ->
         let* count = result in
         match Tool_blob_store.delete store ~sha256 with
         | Ok true -> Ok (count + 1)
         | Ok false -> Ok count
         | Error error -> Error (Blob_delete_failed error))
      deletable
      (Ok 0)
  in
  Ok
    { live_references = String_set.cardinal live
    ; blobs_observed = String_set.cardinal blobs
    ; candidates_recorded = String_set.cardinal current_candidates
    ; deleted
    }
;;
