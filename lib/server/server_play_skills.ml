module Snapshot = Skill_catalog_snapshot

let dos_machine_declaration = "dos-machine"
let prefix = "/play/skills/"
let references_directory = "references"
let markdown_extension = ".md"

type reference =
  { file : string
  ; path : string
  }

type references =
  | Listed of
      { ownership_root : string
      ; max_bytes : int
      ; files : reference list
      }
  | References_unreadable of string

type skill =
  { name : string
  ; description : string
  ; body : string
  ; references : references
  }

type unavailable =
  | Skills_unpublished
  | Catalog_unreadable of string
  | Not_attached

type catalog = (skill list, unavailable) result

(* The files a guide offers are the regular [.md] files the listing names. A
   symbolic link, a subdirectory or anything else in [references/] is not
   offered; the read rechecks this without following links
   ([Fs_compat.load_owned_regular_file_prefix]). *)
let list_references ~ownership_root ~directory ~max_bytes =
  let dir =
    Filename.concat (Filename.concat ownership_root directory) references_directory
  in
  let listed files = Listed { ownership_root; max_bytes; files } in
  match Fs_compat.exact_path_kind ~follow:false dir with
  | Fs_compat.Exact_missing -> listed []
  | Fs_compat.Exact_unknown -> References_unreadable (dir ^ " could not be inspected")
  | Fs_compat.Exact_kind
      (Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK) ->
    References_unreadable (dir ^ " is not a directory")
  | Fs_compat.Exact_kind Unix.S_DIR ->
    (match Fs_compat.read_owned_directory ~ownership_root dir with
     | Error error ->
       References_unreadable (Fs_compat.owned_regular_file_read_error_to_string error)
     | Ok names ->
       let classify file =
         let path = Filename.concat dir file in
         match Fs_compat.exact_path_kind ~follow:false path with
         | Fs_compat.Exact_kind Unix.S_REG -> Ok (Some { file; path })
         | Fs_compat.Exact_missing
         | Fs_compat.Exact_kind
             (Unix.S_DIR | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK)
           -> Ok None
         | Fs_compat.Exact_unknown -> Error (path ^ " could not be inspected")
       in
       let classified =
         names
         |> List.filter (fun file ->
           String.equal (Filename.extension file) markdown_extension)
         |> List.sort String.compare
         |> List.fold_left
              (fun acc file ->
                 Result.bind acc (fun files ->
                   Result.map
                     (function
                       | Some reference -> reference :: files
                       | None -> files)
                     (classify file)))
              (Ok [])
       in
       (match classified with
        | Ok files -> listed (List.rev files)
        | Error detail -> References_unreadable detail))
;;

(* The same two values a Keeper's resource read takes from the snapshot
   ([Keeper_skill_catalog] provenance): the scanned source root and the
   workspace's read bound. *)
let references_of ~snapshot (scan : Snapshot.source_scan) (entry : Snapshot.entry) =
  match scan.observation, Snapshot.config_state snapshot with
  | ( Source_ready { resolved_path; _ }
    , Configured { config = { resource_read_max_bytes = Some max_bytes; _ }; _ } ) ->
    list_references
      ~ownership_root:resolved_path
      ~directory:entry.directory
      ~max_bytes:(Skill_source_config.resource_read_max_bytes_to_int max_bytes)
  | Source_ready _, Configured { config = { resource_read_max_bytes = None; _ }; _ } ->
    References_unreadable "the workspace Skill configuration sets no resource read bound"
  | Source_ready _, (Config_rejected _ | Config_unreadable _) ->
    References_unreadable "the workspace Skill configuration is not in effect"
  | ( ( Source_missing _ | Source_not_directory _ | Source_unavailable _
      | Source_unresolved _ )
    , _ ) ->
    References_unreadable "the DOS machine add-on Skill source was not scanned"
;;

let catalog ~base_path =
  match Server_skill_snapshot_runtime.lookup ~base_path with
  | Error error ->
    Error (Catalog_unreadable (Server_skill_snapshot_runtime.error_to_string error))
  | Ok (Not_registered | Uninitialized) -> Error Skills_unpublished
  | Ok (Ready { snapshot; config_path = _ }) ->
    let source_id =
      Lane_addon_runtime.skill_source_id
        (Lane_addon_runtime.Declaration dos_machine_declaration)
    in
    let published_by_add_on id =
      String.equal (Skill_source_config.source_id_to_string id) source_id
    in
    (match
       List.find_opt
         (fun (scan : Snapshot.source_scan) -> published_by_add_on scan.source.source.id)
         (Snapshot.sources snapshot)
     with
     | None -> Error Not_attached
     | Some scan ->
       Snapshot.entries snapshot
       |> List.filter (fun (entry : Snapshot.entry) ->
         published_by_add_on entry.identity.source_id)
       |> List.map (fun (entry : Snapshot.entry) ->
         { name = entry.document.name
         ; description = entry.document.description
         ; body = entry.document.body
         ; references = references_of ~snapshot scan entry
         })
       |> List.sort (fun (a : skill) (b : skill) -> String.compare a.name b.name)
       |> Result.ok)
;;

let unreadable_details = function
  | Error (Catalog_unreadable detail) -> [ detail ]
  | Error (Skills_unpublished | Not_attached) -> []
  | Ok skills ->
    List.filter_map
      (fun skill ->
         match skill.references with
         | References_unreadable detail -> Some (skill.name ^ ": " ^ detail)
         | Listed _ -> None)
      skills
;;

let segment value = Uri.pct_encode ~component:`Path value
let document_url ~base name = base ^ prefix ^ segment name ^ markdown_extension

let reference_url ~base ~skill file =
  String.concat "/" [ base ^ prefix ^ segment skill; references_directory; segment file ]
;;

let skill_item ~base skill =
  let head =
    Printf.sprintf "- `%s`: %s\n  %s" skill.name skill.description
      (document_url ~base skill.name)
  in
  let reference_lines =
    match skill.references with
    | Listed { files; _ } ->
      List.map
        (fun { file; _ } ->
           Printf.sprintf "  - `%s/%s`: %s" references_directory file
             (reference_url ~base ~skill:skill.name file))
        files
    | References_unreadable _ -> [ "  - Its reference files cannot be read right now." ]
  in
  String.concat "\n" (head :: reference_lines)
;;

let guide_section ~base = function
  | Ok (_ :: _ as skills) -> String.concat "\n" (List.map (skill_item ~base) skills)
  | Ok [] -> "The DOS machine add-on is attached and publishes no game guides."
  | Error Skills_unpublished ->
    "No game guides yet: this server has not published its Skill catalog. Read this \
     guide again later."
  | Error (Catalog_unreadable _) -> "No game guides: this server could not read its Skill catalog."
  | Error Not_attached -> "No game guides: the DOS machine add-on is not attached to this server."
;;

type fetch =
  | Served of string
  | Not_found
  | Unavailable of unavailable
  | References_unavailable of string
  | Reference_too_large of
      { file : string
      ; bytes : int
      ; max_bytes : int
      }
  | Reference_unreadable of string

type target =
  | Document of string
  | Reference of
      { skill : string
      ; file : string
      }

(* Splitting comes before decoding, so an encoded [/] never makes a segment
   and an encoded [..] is only a name the catalog does not hold. *)
let target_of_path path =
  if not (String.starts_with ~prefix path)
  then None
  else (
    let rest = String.sub path (String.length prefix) (String.length path - String.length prefix) in
    match String.split_on_char '/' rest with
    | [ document ] ->
      Option.map
        (fun name -> Document (Uri.pct_decode name))
        (Filename.chop_suffix_opt ~suffix:markdown_extension document)
    | [ skill; directory; file ] when String.equal directory references_directory ->
      Some (Reference { skill = Uri.pct_decode skill; file = Uri.pct_decode file })
    | [] | [ _; _ ] | [ _; _; _ ] | _ :: _ :: _ :: _ :: _ -> None)
;;

let read_reference ~ownership_root ~max_bytes reference =
  match Fs_compat.load_owned_regular_file_prefix ~ownership_root ~max_bytes reference.path with
  | Ok None -> Not_found
  | Ok (Some { Fs_compat.truncated = true; file_size; _ }) ->
    Reference_too_large { file = reference.file; bytes = file_size; max_bytes }
  | Ok (Some { Fs_compat.content; truncated = false; _ }) -> Served content
  (* The listed file became a link, a directory or a path through one after
     the listing: it is no longer a file of this guide. *)
  | Error
      { Fs_compat.failure = Path_is_not_regular_file _ | Ownership_boundary_rejected _
      ; close_failure = _
      } ->
    Not_found
  | Error
      ({ Fs_compat.failure =
           ( Filesystem_identity_changed _ | Owned_path_owner_mismatch _
           | Owned_path_writable_by_others _ | Owned_file_operation_failed _ )
       ; close_failure = _
       } as error) ->
    Reference_unreadable (Fs_compat.owned_regular_file_read_error_to_string error)
;;

let fetch catalog path =
  let find skills name = List.find_opt (fun skill -> String.equal skill.name name) skills in
  match target_of_path path, catalog with
  | None, _ -> Not_found
  | Some _, Error unavailable -> Unavailable unavailable
  | Some (Document name), Ok skills ->
    (match find skills name with
     | None -> Not_found
     | Some skill -> Served skill.body)
  | Some (Reference { skill; file }), Ok skills ->
    (match find skills skill with
     | None -> Not_found
     | Some { references = References_unreadable detail; _ } -> References_unavailable detail
     | Some { references = Listed { ownership_root; max_bytes; files }; _ } ->
       (match List.find_opt (fun reference -> String.equal reference.file file) files with
        | None -> Not_found
        | Some reference -> read_reference ~ownership_root ~max_bytes reference))
;;
