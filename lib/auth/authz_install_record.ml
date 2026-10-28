(* HIGH-RISK-UNREVIEWED: this module reads and writes the file that tells a
   boot where the external store is. A record that reads as absent when it
   should not lets a boot treat a reverted installation as a new one. *)

let ( let* ) = Result.bind

(* The file name carries the start of the hash of the canonical base path. The
   record repeats the canonical base path, so a collision of the short hash is
   a [Base_path_differs] and never a silent mix of two base paths. 16 hex
   digits are 64 bits: a collision is unlikely, and it is refused when it
   happens. *)
let name_hex_length = 16
let name_prefix = "authz-install-"
let name_suffix = ".json"
let base_path_member = "base_path"
let external_store_member = "external_store"
let directory_mode = 0o700

(* The permission bits that let the group or others write a directory. *)
let group_other_write_bits = 0o022

type t =
  { config_dir : string
  ; canonical_base_path : string
  ; file : string
  }

type located =
  | No_config_dir
  | Located of t

type locate_error =
  | Base_path_unresolved of
      { base_path : string
      ; detail : string
      }
  | Base_path_not_utf8 of { canonical : string }
  | Config_dir_not_absolute of { config_dir : string }

let locate_error_to_string = function
  | Base_path_unresolved { base_path; detail } ->
    Printf.sprintf "the base path %s cannot be resolved: %s" base_path detail
  | Base_path_not_utf8 { canonical } ->
    Printf.sprintf "the canonical base path %S is not valid UTF-8" canonical
  | Config_dir_not_absolute { config_dir } ->
    Printf.sprintf
      "the config directory %S is not an absolute path, so it would name another file for every working directory"
      config_dir
;;

let file_name canonical_base_path =
  let hex =
    Agent_core_sha256.to_hex (Agent_core_sha256.digest_string canonical_base_path)
  in
  name_prefix ^ String.sub hex 0 name_hex_length ^ name_suffix
;;

let locate ~config_dir ~base_path =
  match config_dir with
  | None -> Ok No_config_dir
  | Some config_dir when Filename.is_relative config_dir ->
    Error (Config_dir_not_absolute { config_dir })
  | Some config_dir ->
    (match Unix.realpath base_path with
     | exception Unix.Unix_error (error, _, _) ->
       Error (Base_path_unresolved { base_path; detail = Unix.error_message error })
     | canonical_base_path ->
       if String.is_valid_utf_8 canonical_base_path
       then
         Ok
           (Located
              { config_dir
              ; canonical_base_path
              ; file = Filename.concat config_dir (file_name canonical_base_path)
              })
       else Error (Base_path_not_utf8 { canonical = canonical_base_path }))
;;

let file_path t = t.file

type corruption =
  | Not_json
  | Wrong_members
  | Base_path_differs of { recorded : string }
  | Store_path_not_absolute

type read_error =
  | Unreadable of
      { path : string
      ; detail : string
      }
  | Corrupt of
      { path : string
      ; reason : corruption
      }

let corruption_to_string = function
  | Not_json -> "the text is not JSON"
  | Wrong_members ->
    Printf.sprintf
      "the record is not an object with exactly the members %s and %s, both strings"
      base_path_member
      external_store_member
  | Base_path_differs { recorded } ->
    Printf.sprintf "the record was written for the base path %s" recorded
  | Store_path_not_absolute -> "the path of the external store is not absolute"
;;

let read_error_to_string = function
  | Unreadable { path; detail } ->
    Printf.sprintf "the install record %s cannot be read: %s" path detail
  | Corrupt { path; reason } ->
    Printf.sprintf "the install record %s is corrupt: %s" path (corruption_to_string reason)
;;

(* Both members, nothing else. With exactly two members that carry the two
   names, no name can repeat. *)
let members_of_json = function
  | `Assoc [ (first_name, `String first); (second_name, `String second) ] ->
    if String.equal first_name base_path_member && String.equal second_name external_store_member
    then Some (first, second)
    else if
      String.equal first_name external_store_member && String.equal second_name base_path_member
    then Some (second, first)
    else None
  | `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> None
;;

let decode ~path ~canonical_base_path text =
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error _ -> Error (Corrupt { path; reason = Not_json })
  | json ->
    (match members_of_json json with
     | None -> Error (Corrupt { path; reason = Wrong_members })
     | Some (recorded, external_store) ->
       if not (String.equal recorded canonical_base_path)
       then Error (Corrupt { path; reason = Base_path_differs { recorded } })
       else if String.equal external_store "" || Filename.is_relative external_store
       then Error (Corrupt { path; reason = Store_path_not_absolute })
       else Ok (Some external_store))
;;

(* Files and directories this process creates belong to its effective uid. *)
let process_owner_uid () = Unix.geteuid ()

(* The one test that a config directory passes before a record is written into
   it and before a record is read from it. [dir] has no symbolic link left, so
   [lstat] sees the directory itself. The owner-checked read of [Fs_compat]
   applies the same test to the directory of the file: it must belong to the
   effective uid of this process and the group and others must not be able to
   write it. [write] runs this test first, so a record that [write] puts in a
   directory is a record that [read] accepts there. *)
let check_config_dir dir =
  match Unix.lstat dir with
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ } ->
    if st_uid <> process_owner_uid ()
    then
      Error
        (Printf.sprintf
           "it is owned by uid %d and this process runs as uid %d"
           st_uid
           (process_owner_uid ()))
    else if st_perm land group_other_write_bits <> 0
    then Error (Printf.sprintf "its mode %04o lets the group or others write it" st_perm)
    else Ok ()
  | { Unix.st_kind = Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Error "it is not a directory"
;;

(* [Unix.realpath] fails with ENOENT when nothing is there, and also when a
   symbolic link on the way is dangling. Only the first is an absent record.
   A dangling link may hide the record, for instance when the config directory
   lives on a volume that is not mounted. The walk goes up to the nearest
   component that [lstat] finds and demands that a link there is not
   dangling. *)
let rec absent_config_dir dir =
  match Unix.lstat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    let parent = Filename.dirname dir in
    if String.equal parent dir then Ok () else absent_config_dir parent
  | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    (match Unix.stat dir with
     | _ -> Ok ()
     | exception Unix.Unix_error (error, _, _) ->
       Error
         (Printf.sprintf "the symbolic link %s is dangling: %s" dir (Unix.error_message error)))
  | { Unix.st_kind = Unix.S_REG | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Ok ()
;;

let read_file t dir =
  let path = Filename.concat dir (Filename.basename t.file) in
  match
    Fs_compat.load_owned_regular_file_with_snapshot
      ~owner_uid:(process_owner_uid ())
      ~single_link:true
      ~ownership_root:dir
      path
  with
  | Ok None -> Ok None
  | Error error ->
    Error (Unreadable { path; detail = Fs_compat.owned_regular_file_read_error_to_string error })
  | Ok (Some contents) ->
    let ({ Fs_compat.content; _ } : Fs_compat.owned_regular_file_contents) = contents in
    decode ~path ~canonical_base_path:t.canonical_base_path content
;;

let read = function
  | No_config_dir -> Ok None
  | Located t ->
    let unreadable detail = Error (Unreadable { path = t.file; detail }) in
    (match Unix.realpath t.config_dir with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
       (match absent_config_dir t.config_dir with
        | Ok () -> Ok None
        | Error detail -> unreadable detail)
     | exception Unix.Unix_error (error, _, _) -> unreadable (Unix.error_message error)
     | dir ->
       (match check_config_dir dir with
        | Ok () -> read_file t dir
        | Error reason ->
          unreadable (Printf.sprintf "the config directory %s cannot be used: %s" dir reason)))
;;

type write_error =
  | No_config_dir_to_write
  | Store_path_invalid of { external_store : string }
  | Config_dir_unusable of
      { dir : string
      ; detail : string
      }
  | Not_replaced of
      { path : string
      ; detail : string
      }
  | Replaced_but_not_durable of
      { path : string
      ; detail : string
      }

let write_error_to_string = function
  | No_config_dir_to_write ->
    "there is no config directory for the install record (neither XDG_CONFIG_HOME nor HOME is set)"
  | Store_path_invalid { external_store } ->
    Printf.sprintf
      "the path of the external store %S is not an absolute path in valid UTF-8"
      external_store
  | Config_dir_unusable { dir; detail } ->
    Printf.sprintf "the config directory %s cannot hold the install record: %s" dir detail
  | Not_replaced { path; detail } ->
    Printf.sprintf "the install record %s was not replaced: %s" path detail
  | Replaced_but_not_durable { path; detail } ->
    Printf.sprintf "the install record %s was replaced and is not known to be durable: %s" path detail
;;

(* Creates the missing directories, parents first, with mode 0700, as the XDG
   Base Directory Specification asks. A directory that is already there is left
   as it is, a symbolic link to a directory included: [check_config_dir]
   decides afterwards whether the record may go into it. *)
let rec ensure_private_directory dir =
  match Sys.is_directory dir with
  | true -> Ok ()
  | false -> Error "it exists and is not a directory"
  | exception Sys_error _ ->
    let parent = Filename.dirname dir in
    let* () = if String.equal parent dir then Ok () else ensure_private_directory parent in
    (match Unix.mkdir dir directory_mode with
     | () -> Ok ()
     | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
       if (try Sys.is_directory dir with Sys_error _ -> false)
       then Ok ()
       else Error "it exists and is not a directory"
     | exception Unix.Unix_error (error, _, _) -> Error (Unix.error_message error))
;;

let encode ~canonical_base_path ~external_store =
  Yojson.Safe.to_string
    (`Assoc
        [ base_path_member, `String canonical_base_path
        ; external_store_member, `String external_store
        ])
  ^ "\n"
;;

let write located ~external_store =
  match located with
  | No_config_dir -> Error No_config_dir_to_write
  | Located t ->
    if String.equal external_store ""
       || Filename.is_relative external_store
       || not (String.is_valid_utf_8 external_store)
    then Error (Store_path_invalid { external_store })
    else (
      let unusable detail = Config_dir_unusable { dir = t.config_dir; detail } in
      let* () = Result.map_error unusable (ensure_private_directory t.config_dir) in
      let* dir =
        match Unix.realpath t.config_dir with
        | dir -> Ok dir
        | exception Unix.Unix_error (error, _, _) -> Error (unusable (Unix.error_message error))
      in
      let* () = Result.map_error unusable (check_config_dir dir) in
      let path = Filename.concat dir (Filename.basename t.file) in
      match
        Fs_compat.save_file_atomic_strict_staged
          path
          (encode ~canonical_base_path:t.canonical_base_path ~external_store)
      with
      | Ok () -> Ok ()
      | Error failure ->
        let detail = Fs_compat.atomic_replace_failure_to_string failure in
        (match failure.Fs_compat.stage with
         | Fs_compat.Before_rename -> Error (Not_replaced { path; detail })
         | Fs_compat.After_rename -> Error (Replaced_but_not_durable { path; detail })))
;;
