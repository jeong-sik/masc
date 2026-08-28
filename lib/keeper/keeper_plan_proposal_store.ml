module Proposal = Keeper_plan_proposal

type save_result =
  | Stored
  | Already_present

type error =
  | Invalid_proposal of Proposal.error
  | Invalid_proposal_id of string
  | Proposal_not_found of Proposal.Proposal_id.t
  | Tampered_existing_file of Proposal.Proposal_id.t
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Capability_filesystem_unavailable
  | Exclusive_write_failed of Fs_compat.capability_write_error

let store_dir config =
  Filename.concat (Workspace.masc_root_dir config) "keeper-plan-proposals"
;;

let proposal_path config proposal_id =
  Filename.concat
    (store_dir config)
    (Proposal.Proposal_id.to_string proposal_id ^ ".json")
;;

let with_path_lock path ~access f =
  let lock = Keeper_fs.acquire_path_lock path in
  Fun.protect
    ~finally:(fun () -> Keeper_fs.release_path_lock path lock)
    (fun () ->
       match access with
       | `Read -> Eio.Mutex.use_ro (Keeper_fs.path_lock_mutex lock) f
       | `Write ->
         Eio.Mutex.use_rw ~protect:true (Keeper_fs.path_lock_mutex lock) f)
;;

let parse_content ~descriptors ~expected_id content =
  try
    Yojson.Safe.from_string content
    |> Proposal.of_stored_yojson ~descriptors ~expected_id
    |> Result.map_error (fun error -> Invalid_proposal error)
  with
  | Yojson.Json_error detail ->
    Error
      (Invalid_proposal
         (Proposal.Invalid_payload (Proposal.Invalid_json_syntax detail)))
;;

let load_path ~descriptors config proposal_id =
  let masc_root = Workspace.masc_root_dir config in
  let path = proposal_path config proposal_id in
  match Fs_compat.load_owned_regular_file ~ownership_root:masc_root path with
  | Error error -> Error (Read_failed error)
  | Ok None -> Error (Proposal_not_found proposal_id)
  | Ok (Some content) ->
    (match parse_content ~descriptors ~expected_id:proposal_id content with
     | Error _ as error -> error
     | Ok proposal ->
       if String.equal content (Proposal.canonical_bytes proposal)
       then Ok proposal
       else Error (Tampered_existing_file proposal_id))
;;

let load ~descriptors config proposal_id =
  with_path_lock (proposal_path config proposal_id) ~access:`Read (fun () ->
    load_path ~descriptors config proposal_id)
;;

let load_string_id ~descriptors config raw_id =
  match Proposal.Proposal_id.of_string raw_id with
  | Error Proposal.Proposal_id.Not_lowercase_sha256 ->
    Error (Invalid_proposal_id raw_id)
  | Ok proposal_id -> load ~descriptors config proposal_id
;;

let prepare_store_directory config =
  Keeper_fs_durable_directory.ensure
    ~before_prepare:(fun () -> ())
    ~before_directory_fsync:(fun _ -> ())
    ~ownership_root:(Workspace.masc_root_dir config)
    (store_dir config)
  |> Result.map_error (fun error -> Directory_prepare_failed error)
;;

let reread_collision config proposal =
  let proposal_id = Proposal.id proposal in
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:(Workspace.masc_root_dir config)
      (proposal_path config proposal_id)
  with
  | Error error -> Error (Read_failed error)
  | Ok None -> Error (Proposal_not_found proposal_id)
  | Ok (Some content) ->
    if String.equal content (Proposal.canonical_bytes proposal)
    then Ok Already_present
    else Error (Tampered_existing_file proposal_id)
;;

let save_with ~before_exclusive_create config proposal =
  let proposal_id = Proposal.id proposal in
  let path = proposal_path config proposal_id in
  with_path_lock path ~access:`Write (fun () ->
    match
      Fs_compat.load_owned_regular_file
        ~ownership_root:(Workspace.masc_root_dir config)
        path
    with
    | Error error -> Error (Read_failed error)
    | Ok (Some content) ->
      if String.equal content (Proposal.canonical_bytes proposal)
      then Ok Already_present
      else Error (Tampered_existing_file proposal_id)
    | Ok None ->
      (match Fs_compat.get_fs_opt () with
       | None -> Error Capability_filesystem_unavailable
       | Some fs ->
         (match prepare_store_directory config with
          | Error _ as error -> error
          | Ok _directory_lease ->
            before_exclusive_create ~path;
            let parent = Eio.Path.(fs / store_dir config) in
            (match
               Fs_compat.create_capability_file_exclusive
                 ~parent
                 ~leaf:(Filename.basename path)
                 ~permissions:0o600
                 (Proposal.canonical_bytes proposal)
             with
             | Ok () -> Ok Stored
             | Error ({ Fs_compat.target_effect = Target_unchanged; _ } as error) ->
               (match reread_collision config proposal with
                | Error (Proposal_not_found _) ->
                  Error (Exclusive_write_failed error)
                | reread -> reread)
             | Error error -> Error (Exclusive_write_failed error)))))
;;

let save = save_with ~before_exclusive_create:(fun ~path:_ -> ())

module For_testing = struct
  let save_after_absence_observed = save_with
end

let directory_chain_error_to_string = function
  | Keeper_fs_durable_directory.Non_directory_ancestor { path } ->
    Printf.sprintf "non-directory ancestor: %s" path
  | Outside_ownership_root { ownership_root; path } ->
    Printf.sprintf "path %s is outside ownership root %s" path ownership_root
  | Missing_root { path } -> Printf.sprintf "missing ownership root: %s" path
  | Creation_not_observed { path } ->
    Printf.sprintf "directory creation not observed: %s" path
;;

let directory_prepare_failure_to_string = function
  | Keeper_fs_durable_directory.Directory_chain_failed error ->
    directory_chain_error_to_string error
  | Operation_failed (exn, _) -> Printexc.to_string exn
;;

let error_to_yojson = function
  | Invalid_proposal error ->
    `Assoc
      [ "kind", `String "invalid_proposal"
      ; "error", Proposal.error_to_yojson error
      ]
  | Invalid_proposal_id value ->
    `Assoc
      [ "kind", `String "invalid_proposal_id"; "value", `String value ]
  | Proposal_not_found proposal_id ->
    `Assoc
      [ "kind", `String "proposal_not_found"
      ; "proposal_id", `String (Proposal.Proposal_id.to_string proposal_id)
      ]
  | Tampered_existing_file proposal_id ->
    `Assoc
      [ "kind", `String "tampered_existing_file"
      ; "proposal_id", `String (Proposal.Proposal_id.to_string proposal_id)
      ]
  | Read_failed error ->
    `Assoc
      [ "kind", `String "read_failed"
      ; "detail", `String (Fs_compat.owned_regular_file_read_error_to_string error)
      ]
  | Directory_prepare_failed error ->
    `Assoc
      [ "kind", `String "directory_prepare_failed"
      ; "detail", `String (directory_prepare_failure_to_string error)
      ]
  | Capability_filesystem_unavailable ->
    `Assoc [ "kind", `String "capability_filesystem_unavailable" ]
  | Exclusive_write_failed error ->
    `Assoc
      [ "kind", `String "exclusive_write_failed"
      ; "detail", `String (Fs_compat.capability_write_error_to_string error)
      ]
;;
