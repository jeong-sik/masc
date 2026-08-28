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
  | Write_failed of Keeper_fs.durable_write_error

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
  | Ok (Some content) -> parse_content ~descriptors ~expected_id:proposal_id content
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

let save config proposal =
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
      (match
         Keeper_fs.save_bytes_durable_atomic
           ~ownership_root:(Workspace.masc_root_dir config)
           path
           (Proposal.canonical_bytes proposal)
       with
       | Ok () -> Ok Stored
       | Error error -> Error (Write_failed error)))
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
  | Write_failed error ->
    `Assoc
      [ "kind", `String "write_failed"
      ; "detail", `String (Keeper_fs.durable_write_error_to_string error)
      ]
;;
