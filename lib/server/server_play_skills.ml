module Snapshot = Skill_catalog_snapshot

let prefix = "/play/skills/"
let document_file = "SKILL.md"
let references_directory = "references"
let markdown_extension = ".md"

type skill =
  { name : string
  ; description : string
  ; body : string
  ; ownership_root : string
  ; directory : string
  ; max_bytes : int
  }

type unavailable =
  | Skills_unpublished
  | Catalog_unreadable of string
  | Machine_not_attached
  | Skills_not_in_effect
  | Source_unavailable of string

type catalog = (skill list, unavailable) result

let machine_tool = Machine_controller_contract.(dos_tool_name Dos_screen)

(* Checked in this order because each answer is only true once the one before
   it holds: a snapshot, a machine serving the screen, a configuration in
   effect, then the machine's Skill source in that snapshot. The add-on
   source is composed only into a configuration that sets a read bound
   ([Skill_catalog_snapshot_service] refuses it otherwise), so a missing
   bound means the add-on's Skills were dropped, not that there are none. *)
let catalog ~config =
  match Server_skill_snapshot_runtime.lookup ~base_path:config.Workspace.base_path with
  | Error error ->
    Error (Catalog_unreadable (Server_skill_snapshot_runtime.error_to_string error))
  | Ok (Not_registered | Uninitialized) -> Error Skills_unpublished
  | Ok (Ready { snapshot; config_path = _ }) ->
    (match Machine_addon_host.shared_skill_owner ~config ~name:machine_tool with
     | None -> Error Machine_not_attached
     | Some owner ->
       (match Snapshot.config_state snapshot with
        | Config_rejected _ | Config_unreadable _
        | Configured { config = { resource_read_max_bytes = None; _ }; _ } ->
          Error Skills_not_in_effect
        | Configured { config = { resource_read_max_bytes = Some max_bytes; _ }; _ } ->
          let source_id = Lane_addon_runtime.skill_source_id owner in
          let from_machine id = String.equal (Skill_source_config.source_id_to_string id) source_id in
          (match
             List.find_opt
               (fun (scan : Snapshot.source_scan) -> from_machine scan.source.source.id)
               (Snapshot.sources snapshot)
           with
           | None -> Ok []
           | Some { observation = Snapshot.Source_ready { resolved_path; _ }; _ } ->
             Snapshot.effective_entries snapshot
             |> List.filter (fun (entry : Snapshot.entry) -> from_machine entry.identity.source_id)
             |> List.map (fun (entry : Snapshot.entry) ->
               { name = entry.document.name
               ; description = entry.document.description
               ; body = entry.document.body
               ; ownership_root = resolved_path
               ; directory = entry.directory
               ; max_bytes = Skill_source_config.resource_read_max_bytes_to_int max_bytes
               })
             |> List.sort (fun (a : skill) (b : skill) -> String.compare a.name b.name)
             |> Result.ok
           | Some { observation = Snapshot.Source_missing { resolved_path }; _ } ->
             Error (Source_unavailable (resolved_path ^ " is missing"))
           | Some { observation = Snapshot.Source_not_directory { resolved_path; kind }; _ } ->
             Error
               (Source_unavailable
                  (Printf.sprintf "%s is a %s, not a directory" resolved_path
                     (Fs_compat.file_kind_to_string kind)))
           | Some { observation = Snapshot.Source_unavailable { resolved_path; operation; detail }; _ }
             ->
             Error
               (Source_unavailable
                  (Printf.sprintf "%s: %s: %s" resolved_path
                     (Snapshot.source_operation_to_string operation) detail))
           | Some { observation = Snapshot.Source_unresolved _; _ } ->
             Error (Source_unavailable "the add-on Skill source path did not resolve"))))
;;

let unavailable_detail = function
  | Catalog_unreadable detail | Source_unavailable detail -> Some detail
  | Skills_unpublished | Machine_not_attached | Skills_not_in_effect -> None
;;

let segment value = Uri.pct_encode ~component:`Path value
let skill_url ~base name = base ^ prefix ^ segment name
let document_url ~base name = String.concat "/" [ skill_url ~base name; document_file ]

let reference_url ~base ~skill file =
  String.concat "/" [ skill_url ~base skill; references_directory; segment file ]
;;

let guide_section ~base = function
  | Ok (_ :: _ as skills) ->
    skills
    |> List.map (fun skill ->
      Printf.sprintf "- `%s`: %s\n  %s" skill.name skill.description
        (document_url ~base skill.name))
    |> String.concat "\n"
  | Ok [] -> "No game guides: the attached DOS machine add-on publishes none."
  | Error Skills_unpublished ->
    "No game guides yet: this server has not published its Skill catalog. Read this \
     guide again later."
  | Error (Catalog_unreadable _) -> "No game guides: this server could not read its Skill catalog."
  | Error Machine_not_attached -> "No game guides: no DOS machine add-on is attached to this server."
  | Error Skills_not_in_effect ->
    "No game guides: this server's Skill configuration is not in effect."
  | Error (Source_unavailable _) ->
    "No game guides right now: the DOS machine add-on's Skills cannot be read."
;;

(* The snapshot scanner's guard ([Skill_catalog_snapshot_service]): a path
   probe that fails is an answer with its reason, never an exception out of
   the request. Cancellation and fatal runtime exceptions still propagate. *)
let run_blocking operation =
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> operation ()
  | Eio_fiber -> Eio_unix.run_in_systhread ~label:"list play skill references" operation
;;

let protect_io operation =
  try Ok (run_blocking operation) with
  | Eio.Cancel.Cancelled _ as exn -> Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | (Out_of_memory | Stack_overflow | Sys.Break) as exn ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn -> Error (Printexc.to_string exn)
;;

type reference =
  { file : string
  ; path : string  (** Built from the listing, never from a request. *)
  }

(* A symbolic link, a subdirectory or anything else in [references/] is not
   offered; the read rechecks this without following links
   ([Fs_compat.load_owned_regular_file_prefix]). *)
let list_references skill =
  let dir =
    Filename.concat (Filename.concat skill.ownership_root skill.directory) references_directory
  in
  let classify file =
    let path = Filename.concat dir file in
    match protect_io (fun () -> Fs_compat.exact_path_kind ~follow:false path) with
    | Error detail -> Error detail
    | Ok (Fs_compat.Exact_kind Unix.S_REG) -> Ok (Some { file; path })
    | Ok
        ( Fs_compat.Exact_missing
        | Fs_compat.Exact_kind
            (Unix.S_DIR | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK) ) ->
      Ok None
    | Ok Fs_compat.Exact_unknown -> Error (path ^ " could not be inspected")
  in
  match protect_io (fun () -> Fs_compat.exact_path_kind ~follow:false dir) with
  | Error detail -> Error detail
  | Ok Fs_compat.Exact_missing -> Ok []
  | Ok Fs_compat.Exact_unknown -> Error (dir ^ " could not be inspected")
  | Ok
      (Fs_compat.Exact_kind
         (Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK)) ->
    Error (dir ^ " is not a directory")
  | Ok (Fs_compat.Exact_kind Unix.S_DIR) ->
    Result.bind (protect_io (fun () -> Fs_compat.read_dir dir)) (fun names ->
      names
      |> List.filter (fun file -> String.equal (Filename.extension file) markdown_extension)
      |> List.sort String.compare
      |> List.fold_left
           (fun listed file ->
              Result.bind listed (fun references ->
                Result.map
                  (function
                    | Some reference -> reference :: references
                    | None -> references)
                  (classify file)))
           (Ok [])
      |> Result.map List.rev)
;;

let with_reference_urls ~base skill = function
  | [] -> skill.body
  | _ :: _ as references ->
    String.concat "\n"
      ([ skill.body; ""; "## Reference files"; "" ]
       @ List.map
           (fun { file; _ } ->
              Printf.sprintf "- `%s/%s`: %s" references_directory file
                (reference_url ~base ~skill:skill.name file))
           references)
;;

type fetch =
  | Served of string
  | Served_without_references of
      { body : string
      ; detail : string
      }
  | Not_found
  | Unavailable of unavailable
  | References_unreadable of string
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
   and an encoded [..] is only a name nothing published holds. *)
let target_of_path path =
  if not (String.starts_with ~prefix path)
  then None
  else (
    let rest = String.sub path (String.length prefix) (String.length path - String.length prefix) in
    match String.split_on_char '/' rest with
    | [ skill; file ] when String.equal file document_file -> Some (Document (Uri.pct_decode skill))
    | [ skill; directory; file ] when String.equal directory references_directory ->
      Some (Reference { skill = Uri.pct_decode skill; file = Uri.pct_decode file })
    | [] | [ _ ] | [ _; _ ] | [ _; _; _ ] | _ :: _ :: _ :: _ :: _ -> None)
;;

let read_reference skill reference =
  match
    Fs_compat.load_owned_regular_file_prefix
      ~ownership_root:skill.ownership_root
      ~max_bytes:skill.max_bytes
      reference.path
  with
  | Ok None -> Not_found
  | Ok (Some { Fs_compat.truncated = true; file_size; _ }) ->
    Reference_too_large { file = reference.file; bytes = file_size; max_bytes = skill.max_bytes }
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

let fetch ~base catalog path =
  let find skills name = List.find_opt (fun skill -> String.equal skill.name name) skills in
  match target_of_path path with
  | None -> Not_found
  | Some target ->
    (match catalog, target with
     | Error unavailable, (Document _ | Reference _) -> Unavailable unavailable
     | Ok skills, Document name ->
       (match find skills name with
        | None -> Not_found
        | Some skill ->
          (match list_references skill with
           | Ok references -> Served (with_reference_urls ~base skill references)
           | Error detail -> Served_without_references { body = skill.body; detail }))
     | Ok skills, Reference { skill = name; file } ->
       (match find skills name with
        | None -> Not_found
        | Some skill ->
          (match list_references skill with
           | Error detail -> References_unreadable detail
           | Ok references ->
             (match List.find_opt (fun reference -> String.equal reference.file file) references with
              | None -> Not_found
              | Some reference -> read_reference skill reference))))
;;
