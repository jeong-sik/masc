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
  | Cluster_workspace_rejected of
      { path : string
      ; reason : string
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
  ; skipped_cluster_files : string list
  }

let error_to_string = function
  | Cluster_workspace_rejected { path; reason } ->
    Printf.sprintf
      "tool blob maintenance cannot read cluster workspace path=%s: %s"
      path
      reason
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
                  try
                    references_in_json
                      ~path
                      ~line:line_number
                      references
                      (Yojson.Safe.from_string line)
                  with
                  | Yojson.Json_error detail ->
                    if String_util.contains_substring line "\"_blob\""
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
                        line)
              in
              line_number + 1, next)
           (1, Ok Artifact_reference_set.empty)
      |> snd
;;

let durable_consumer_basenames =
  [ "gate"
  ; Common.keepers_runtime_dirname
  ; "keeper_chat"
  ; "messages"
  ; "tool_calls"
  ; "traces"
  (* The bounded diagnostic store owns every blob reference for as long as
     its dated JSONL row remains inside wire-capture retention. *)
  ; "wire-capture"
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

(* Where blob references live, as data. Every durable consumer writes under the
   workspace root of its own cluster: [.masc] for the default cluster and
   [.masc/clusters/<name>] for every other one
   ([Workspace_utils_paths_backend.masc_root_dir_from]; tool-call logs, for
   one, follow [Workspace.masc_root_dir config]). The blob store itself is one
   per BasePath, so a hash is live when any workspace references it, and the
   scan reads the same consumer list in every workspace (#38919). *)
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

let clusters_root ~base_path = Common.clusters_dir_from_base_path ~base_path
;;

let unix_reason fn arg code =
  Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
;;

(* What one entry under [clusters] is. A regular file (Finder's [.DS_Store],
   a stray note) cannot be a workspace root, so it holds no references and is
   skipped by name. A symlink can point at a real workspace and a special
   file is never expected there, so both reject the pass: skipping a
   workspace would make its references look dead. *)
type cluster_entry =
  | Workspace of string
  | Skipped_file of string

(* The cluster set as one observation: the [clusters] directory snapshot, the
   workspace roots it held and the regular files it skipped. *)
let observe_cluster_workspaces ~base_path =
  let path = clusters_root ~base_path in
  let reject ?(path = path) reason =
    Error (Cluster_workspace_rejected { path; reason })
  in
  let inspect target =
    match
      Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path target
    with
    | Ok observation -> Ok observation
    | Error rejection ->
      reject
        ~path:target
        (Fs_compat.owned_directory_chain_rejection_to_string rejection)
  in
  let workspace entry =
    let root = Filename.concat path entry in
    match (Unix.lstat root).Unix.st_kind with
    | Unix.S_DIR ->
      (match inspect root with
       | Error _ as error -> error
       | Ok (Fs_compat.Owned_directory _) -> Ok (Workspace root)
       | Ok Fs_compat.Owned_directory_missing ->
         reject ~path:root "cluster workspace disappeared during scan")
    | Unix.S_LNK -> reject ~path:root "a symbolic link is not a cluster workspace"
    | Unix.S_REG -> Ok (Skipped_file root)
    | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK ->
      reject ~path:root "a special file is not a cluster workspace"
    | exception Unix.Unix_error (code, fn, arg) ->
      reject ~path:root (unix_reason fn arg code)
  in
  match inspect path with
  | Error _ as error -> error
  | Ok Fs_compat.Owned_directory_missing -> Ok (None, [], [])
  | Ok (Fs_compat.Owned_directory before) ->
    (match Sys.readdir path with
     | exception Sys_error reason -> reject reason
     | entries ->
       entries
       |> Array.to_list
       |> List.sort String.compare
       |> List.fold_left
            (fun result entry ->
               Result.bind result (fun classified ->
                 Result.map (fun kind -> kind :: classified) (workspace entry)))
            (Ok [])
       |> Result.map (fun classified ->
         let roots, skipped =
           List.partition_map
             (function
               | Workspace root -> Either.Left root
               | Skipped_file file -> Either.Right file)
             (List.rev classified)
         in
         Some before, roots, skipped))
;;

(* A cluster created, removed or renamed while the scan ran would leave a
   workspace half read, so the [clusters] snapshot must be the same after the
   scan as before it. *)
let confirm_cluster_set_unchanged ~base_path before =
  let path = clusters_root ~base_path in
  let changed () =
    Error
      (Cluster_workspace_rejected
         { path; reason = "the cluster set changed during the scan" })
  in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:base_path path with
  | Error rejection ->
    Error
      (Cluster_workspace_rejected
         { path
         ; reason = Fs_compat.owned_directory_chain_rejection_to_string rejection
         })
  | Ok observed ->
    (match before, observed with
     | None, Fs_compat.Owned_directory_missing -> Ok ()
     | Some before, Fs_compat.Owned_directory after ->
       if same_directory_snapshot before after then Ok () else changed ()
     | None, Fs_compat.Owned_directory _
     | Some _, Fs_compat.Owned_directory_missing -> changed ())
;;

let live_references ~after_scan ~base_path ~board_posts_file =
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
  let open Result.Syntax in
  let* cluster_snapshot, cluster_roots, skipped_cluster_files =
    observe_cluster_workspaces ~base_path
  in
  let* references =
    Common.masc_dir_from_base_path ~base_path :: cluster_roots
    |> List.concat_map (fun workspace_masc_dir ->
      workspace_sources ~board_posts_file ~workspace_masc_dir)
    |> List.fold_left
         (fun result source ->
            Result.bind result (fun progress -> scan_source progress source))
         (Ok Artifact_reference_set.empty)
  in
  after_scan ();
  let* () = confirm_cluster_set_unchanged ~base_path cluster_snapshot in
  Ok (references, skipped_cluster_files)
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

let run_with ~after_scan ~base_path ~board_posts_file ~mode =
  let open Result.Syntax in
  let store = Tool_blob_store.create ~base_path in
  let* direct_live, skipped_cluster_files =
    live_references ~after_scan ~base_path ~board_posts_file
  in
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
    ; skipped_cluster_files
    }
;;

let run ~base_path ~board_posts_file ~mode =
  run_with ~after_scan:(fun () -> ()) ~base_path ~board_posts_file ~mode
;;

module For_testing = struct
  let run = run_with
end
