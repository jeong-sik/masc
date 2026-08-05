module String_set = Set_util.StringSet

type mode =
  | Observe_only
  | Delete_previous_candidates

type error =
  | Clustered_durable_roots_uncoordinated of
      { path : string
      ; entries : int
      }
  | Durable_source_stat_failed of
      { path : string
      ; reason : string
      }
  | Durable_source_read_failed of
      { path : string
      ; reason : string
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
  | Scan_budget_exhausted of
      { path : string
      ; max_duration_sec : float
      ; elapsed_seconds : float
      ; files_examined : int
      ; bytes_examined : int64
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
  | Clustered_durable_roots_uncoordinated { path; entries } ->
    Printf.sprintf
      "tool blob maintenance requires cross-cluster writer coordination before \
       scanning shared blobs path=%s entries=%d"
      path
      entries
  | Durable_source_stat_failed { path; reason } ->
    Printf.sprintf "durable source stat failed path=%s: %s" path reason
  | Durable_source_read_failed { path; reason } ->
    Printf.sprintf "durable source read failed path=%s: %s" path reason
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
  | Scan_budget_exhausted
      { path
      ; max_duration_sec
      ; elapsed_seconds
      ; files_examined
      ; bytes_examined
      } ->
    Printf.sprintf
      "scan budget exhausted path=%s max_duration_seconds=%.3f \
       elapsed_seconds=%.3f files_examined=%d bytes_examined=%Ld"
      path
      max_duration_sec
      elapsed_seconds
      files_examined
      bytes_examined
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

type scan_budget =
  { started_at : Mtime.t
  ; max_duration_sec : float
  ; mutable files_examined : int
  ; mutable bytes_examined : int64
  }

let scan_elapsed_seconds budget =
  Mtime.Span.to_float_ns (Mtime.span budget.started_at (Mtime_clock.now ()))
  /. 1e9
;;

let check_scan_budget budget_opt ~path =
  match budget_opt with
  | None -> Ok ()
  | Some budget ->
    let elapsed_seconds = scan_elapsed_seconds budget in
    if elapsed_seconds < budget.max_duration_sec
    then Ok ()
    else
      Error
        (Scan_budget_exhausted
           { path
           ; max_duration_sec = budget.max_duration_sec
           ; elapsed_seconds
           ; files_examined = budget.files_examined
           ; bytes_examined = budget.bytes_examined
           })
;;

let note_file_examined budget_opt payload =
  match budget_opt with
  | None -> ()
  | Some budget ->
    budget.files_examined <- budget.files_examined + 1;
    budget.bytes_examined <-
      Int64.add budget.bytes_examined (Int64.of_int (String.length payload))
;;

let add_references ~path ~line references text =
  match Tool_output.artifact_refs_in_text text with
  | Ok found ->
    Ok
      (List.fold_left
         (fun acc reference ->
            String_set.add reference.Tool_output.sha256 acc)
         references
         found)
  | Error error ->
    Error
      (Malformed_artifact_reference
         { path
         ; line
         ; offset = error.offset
         ; detail = error.detail
         })
;;

let contains_substring ~needle text =
  let needle_length = String.length needle in
  let text_length = String.length text in
  let rec loop offset =
    if offset + needle_length > text_length
    then false
    else if String.sub text offset needle_length = needle
    then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0
;;

let rec references_in_json ~path ~line references = function
  | `String text -> add_references ~path ~line references text
  | (`Assoc fields as json) ->
    (match Tool_output.normalized_artifact_ref_of_json json with
     | Tool_output.Decoded_normalized_artifact_ref reference ->
       Ok (String_set.add reference.Tool_output.sha256 references)
     | Tool_output.Invalid_normalized_artifact_ref { detail } ->
       Error
         (Malformed_structured_artifact_reference
            { path; line; detail })
     | Tool_output.Not_normalized_artifact_ref ->
       List.fold_left
         (fun result (_, value) ->
            Result.bind result (fun current ->
              references_in_json ~path ~line current value))
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

let references_in_file ~scan_budget ~ownership_root path =
  let open Result.Syntax in
  let* () = check_scan_budget scan_budget ~path in
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
    note_file_examined scan_budget payload;
    let* () = check_scan_budget scan_budget ~path in
    let parsed =
      try
        references_in_json
          ~path
          ~line:1
          String_set.empty
          (Yojson.Safe.from_string payload)
      with
      | Yojson.Json_error _ ->
        payload
        |> String.split_on_char '\n'
        |> List.fold_left
             (fun (line_number, result) line ->
                let next =
                  let* references = result in
                  let* () = check_scan_budget scan_budget ~path in
                  try
                    references_in_json
                      ~path
                      ~line:line_number
                      references
                      (Yojson.Safe.from_string line)
                  with
                  | Yojson.Json_error detail ->
                    if contains_substring ~needle:"\"_blob\"" line
                    then
                      Error
                        (Malformed_structured_artifact_reference
                           { path
                           ; line = line_number
                           ; detail =
                               "unparseable durable row contains a _blob key: "
                               ^ detail
                           })
                    else
                      add_references
                        ~path
                        ~line:line_number
                        references
                        line
                in
                line_number + 1, next)
             (1, Ok String_set.empty)
        |> snd
    in
    let* references = parsed in
    let* () = check_scan_budget scan_budget ~path in
    Ok references
;;

let durable_consumer_basenames =
  [ "gate"
  ; Common.keepers_runtime_dirname
  ; "keeper_chat"
  ; "messages"
  ; "tool_calls"
  ; "traces"
  ; Common.keeper_runtime_store_dirname Common.Keeper_trajectories
  (* The bounded diagnostic store owns every blob reference for as long as
     its dated JSONL row remains inside wire-capture retention. *)
  ; "wire-capture"
  ]
;;

let durable_consumer_roots ~base_path =
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  List.map (Filename.concat runtime_root) durable_consumer_basenames
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

let reject_uncoordinated_cluster_roots ~base_path =
  let path =
    Filename.concat
      (Common.masc_dir_from_base_path ~base_path)
      "clusters"
  in
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
  | Ok Fs_compat.Owned_directory_missing -> Ok ()
  | Ok (Fs_compat.Owned_directory before) ->
    (try
       let entries = Sys.readdir path in
       match inspect () with
       | Error _ as error -> error
       | Ok Fs_compat.Owned_directory_missing ->
         Error
           (Durable_source_stat_failed
              { path; reason = "cluster root disappeared during scan" })
       | Ok (Fs_compat.Owned_directory after) ->
         if not (same_directory_snapshot before after)
         then
           Error
             (Durable_source_stat_failed
                { path; reason = "cluster root changed during scan" })
         else if Array.length entries = 0
         then Ok ()
         else
           Error
             (Clustered_durable_roots_uncoordinated
                { path; entries = Array.length entries })
     with
     | Sys_error reason ->
       Error (Durable_source_stat_failed { path; reason })
     | Unix.Unix_error (code, fn, arg) ->
       Error
         (Durable_source_stat_failed
            { path
            ; reason =
                Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
            }))
;;

let live_references ~scan_budget ~base_path =
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
    let open Result.Syntax in
    let* () = check_scan_budget scan_budget ~path in
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR -> scan_directory path references
      | Unix.S_REG ->
        Result.map
          (String_set.union references)
          (references_in_file ~scan_budget ~ownership_root:base_path path)
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
    | Sys_error reason ->
      Error (Durable_source_stat_failed { path; reason })
    | Unix.Unix_error (code, fn, arg) ->
      Error
        (Durable_source_stat_failed
           { path
           ; reason =
               Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
           })
  and scan_directory path references =
    let open Result.Syntax in
    let* () = check_scan_budget scan_budget ~path in
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
  durable_consumer_roots ~base_path
  |> List.fold_left
       (fun result root ->
          Result.bind result (fun references ->
            scan_directory root references))
       (Ok String_set.empty)
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

let run ?max_scan_seconds ~base_path ~mode =
  let open Result.Syntax in
  let* () = reject_uncoordinated_cluster_roots ~base_path in
  let store = Tool_blob_store.create ~base_path in
  let scan_budget =
    Option.map
      (fun max_duration_sec ->
         { started_at = Mtime_clock.now ()
         ; max_duration_sec
         ; files_examined = 0
         ; bytes_examined = 0L
         })
      max_scan_seconds
  in
  let* live = live_references ~scan_budget ~base_path in
  let* () =
    check_scan_budget scan_budget ~path:(candidate_snapshot_path ~base_path)
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
