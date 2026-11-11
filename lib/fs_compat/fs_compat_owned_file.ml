open Fs_compat_internal
open Fs_compat_base_io

(** Append string to file.
    Appended on a system thread inside Eio, inline otherwise; both go
    through the per-path mutex of [append_file_unix], so two appends to one
    path from two threads stay whole.
    @raises Sys_error on all I/O failures. *)
let append_file (path : string) (content : string) : unit =
  test_exec_home_guard ~op:"append_file" path;
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> append_file_unix path content)
    (fun _fs ->
       on_systhread
         ~label:(labelled "fs-compat-append-file" path)
         (fun () -> append_file_unix path content))
;;

(** Check if file exists.
    Uses Stdlib.Sys.file_exists (works in both Eio and non-Eio contexts). *)
let file_exists (path : string) : bool =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () -> Stdlib.Sys.file_exists path)
    (fun fs ->
       try
         let _ = Eio.Path.stat ~follow:true Eio.Path.(fs / path) in
         true
       with
       | Eio.Io _ -> false)
;;

type path_kind =
  | Missing
  | Directory
  | Other

type exact_path_kind =
  | Exact_missing
  | Exact_kind of Unix.file_kind
  | Exact_unknown

let exact_path_kind ?(follow = true) (path : string) : exact_path_kind =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      try
        let stats = if follow then Unix.stat path else Unix.lstat path in
        Exact_kind stats.Unix.st_kind
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Exact_missing
      | Unix.Unix_error (Unix.ENOTDIR, _, _) -> Exact_unknown)
    (fun fs ->
       match Eio.Path.kind ~follow Eio.Path.(fs / path) with
       | `Not_found -> Exact_missing
       | `Directory -> Exact_kind Unix.S_DIR
       | `Fifo -> Exact_kind Unix.S_FIFO
       | `Character_special -> Exact_kind Unix.S_CHR
       | `Block_device -> Exact_kind Unix.S_BLK
       | `Regular_file -> Exact_kind Unix.S_REG
       | `Symbolic_link -> Exact_kind Unix.S_LNK
       | `Socket -> Exact_kind Unix.S_SOCK
       | `Unknown -> Exact_unknown)
;;

let path_kind ?(follow = true) (path : string) : path_kind =
  match exact_path_kind ~follow path with
  | Exact_missing -> Missing
  | Exact_kind Unix.S_DIR -> Directory
  | Exact_kind
      (Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
      | Unix.S_SOCK)
  | Exact_unknown -> Other
;;

type owned_directory_chain_rejection = Owned_directory_chain.rejection =
  | Owned_path_outside_root of
      { ownership_root : string
      ; path : string
      }
  | Owned_path_non_directory of
      { path : string
      ; kind : Unix.file_kind
      }

type owned_directory_chain_observation = Owned_directory_chain.observation =
  | Owned_directory_missing
  | Owned_directory of Unix.stats

let inspect_owned_directory_chain = Owned_directory_chain.inspect
let owned_directory_paths = Owned_directory_chain.paths

let owned_directory_chain_rejection_to_string =
  Owned_directory_chain.rejection_to_string
;;

type owned_regular_file_read_operation =
  | Inspect_parent
  | Inspect_path
  | Open_path
  | Inspect_descriptor
  | Read_contents
  | Close_descriptor

type owned_regular_file_read_failure =
  | Ownership_boundary_rejected of
      { path : string
      ; rejection : owned_directory_chain_rejection
      }
  | Path_is_not_regular_file of
      { path : string
      ; kind : Unix.file_kind
      }
  | Filesystem_identity_changed of { path : string }
  | Owned_path_owner_mismatch of { path : string; expected_uid : int; actual_uid : int }
  | Owned_path_writable_by_others of { path : string; permissions : int }
  | Owned_file_operation_failed of
      { path : string
      ; operation : owned_regular_file_read_operation
      ; cause : exn
      }

type owned_regular_file_read_error =
  { failure : owned_regular_file_read_failure
  ; close_failure : exn option
  }

let owned_regular_file_read_operation_to_string = function
  | Inspect_parent -> "inspect_parent"
  | Inspect_path -> "inspect_path"
  | Open_path -> "open_path"
  | Inspect_descriptor -> "inspect_descriptor"
  | Read_contents -> "read_contents"
  | Close_descriptor -> "close_descriptor"
;;

let file_kind_to_string = Owned_directory_chain.file_kind_to_string

let owned_regular_file_read_failure_to_string = function
  | Ownership_boundary_rejected { path; rejection } ->
    Printf.sprintf
      "owned file boundary rejected path=%s reason=%s"
      path
      (owned_directory_chain_rejection_to_string rejection)
  | Path_is_not_regular_file { path; kind } ->
    Printf.sprintf
      "owned file path is not a regular file path=%s kind=%s"
      path
      (file_kind_to_string kind)
  | Filesystem_identity_changed { path } ->
    Printf.sprintf "owned file identity changed during read path=%s" path
  | Owned_path_owner_mismatch {path; expected_uid; actual_uid} ->
    Printf.sprintf "owned path UID mismatch path=%s expected=%d actual=%d" path expected_uid actual_uid
  | Owned_path_writable_by_others {path; permissions} ->
    Printf.sprintf "owned path writable by group/other path=%s permissions=%04o" path permissions
  | Owned_file_operation_failed { path; operation; cause } ->
    Printf.sprintf
      "owned file operation failed path=%s operation=%s reason=%s"
      path
      (owned_regular_file_read_operation_to_string operation)
      (Printexc.to_string cause)
;;

let owned_regular_file_read_error_to_string { failure; close_failure } =
  let primary = owned_regular_file_read_failure_to_string failure in
  match close_failure with
  | None -> primary
  | Some cause ->
    Printf.sprintf
      "%s; descriptor close also failed: %s"
      primary
      (Printexc.to_string cause)
;;

let same_file_identity (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino
;;

let same_file_snapshot (left : Unix.stats) (right : Unix.stats) =
  same_file_identity left right
  && left.st_kind = right.st_kind
  && left.st_size = right.st_size
  && left.st_mtime = right.st_mtime
  && left.st_ctime = right.st_ctime
;;

type owned_regular_file_snapshot =
  { device : int
  ; inode : int
  ; owner_uid : int
  ; permissions : int
  ; file_size : int
  ; modified_at : float
  ; changed_at : float
  }

let owned_regular_file_snapshot_of_stats (stats : Unix.stats) =
  { device = stats.st_dev
  ; inode = stats.st_ino
  ; owner_uid = stats.st_uid
  ; permissions = stats.st_perm land 0o7777
  ; file_size = stats.st_size
  ; modified_at = stats.st_mtime
  ; changed_at = stats.st_ctime
  }
;;

let equal_owned_regular_file_snapshot left right =
  Int.equal left.device right.device
  && Int.equal left.inode right.inode
  && Int.equal left.owner_uid right.owner_uid
  && Int.equal left.permissions right.permissions
  && Int.equal left.file_size right.file_size
  && Float.equal left.modified_at right.modified_at
  && Float.equal left.changed_at right.changed_at
;;

let owned_file_error failure = Error { failure; close_failure = None }

let owned_file_operation_error ~path operation cause =
  owned_file_error (Owned_file_operation_failed { path; operation; cause })
;;

let reraise_current exn =
  Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
;;

let read_exact_file_descriptor ~path fd length =
  try
    let bytes = Bytes.create length in
    let rec read offset =
      if offset = length
      then Ok (Bytes.unsafe_to_string bytes)
      else
        match Unix.read fd bytes offset (length - offset) with
        | 0 -> owned_file_error (Filesystem_identity_changed { path })
        | count -> read (offset + count)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> read offset
    in
    read 0
  with
  | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
  | cause -> owned_file_operation_error ~path Read_contents cause
;;

let load_owned_regular_file_blocking_with ?owner_uid ?(single_link = false) ?(parent_lstat = Unix.lstat)
    ~ownership_root ~read_descriptor path =
  let parent = Filename.dirname path in
  let check_owner path (stat : Unix.stats) =
    match owner_uid with
    | Some expected_uid when stat.st_uid <> expected_uid ->
      owned_file_error (Owned_path_owner_mismatch {path; expected_uid; actual_uid=stat.st_uid})
    | None | Some _ -> Ok () in
  let check_owned_parent path stat =
    match check_owner path stat with
    | Error _ as error -> error
    | Ok () when stat.Unix.st_perm land 0o022 <> 0 ->
      owned_file_error (Owned_path_writable_by_others
        {path; permissions=stat.st_perm land 0o7777})
    | Ok () -> Ok () in
  let link_error () =
    owned_file_error (Owned_file_operation_failed
      {path;operation=Inspect_descriptor;cause=Sys_error "owned record has multiple hard links"}) in
  let check_file stat =
    match check_owner path stat with
    | Error _ as error -> error
    | Ok () -> if single_link && stat.Unix.st_nlink<>1 then link_error () else Ok () in
  let inspect_parent () =
    try
      match owner_uid with
      | None ->
        (match inspect_owned_directory_chain ~ownership_root parent with
         | Ok Owned_directory_missing -> Ok None
         | Ok (Owned_directory stat) -> Ok (Some [stat])
         | Error rejection -> owned_file_error (Ownership_boundary_rejected {path; rejection}))
      | Some _ ->
        (match owned_directory_paths ~ownership_root parent with
         | Error rejection -> owned_file_error (Ownership_boundary_rejected {path; rejection})
         | Ok descendants ->
           let rec inspect observed = function
             | [] -> Ok (Some (List.rev observed))
             | directory :: rest ->
               (match parent_lstat directory with
                | stat when stat.Unix.st_kind <> Unix.S_DIR ->
                  owned_file_error (Ownership_boundary_rejected {path;
                    rejection=Owned_path_non_directory {path=directory; kind=stat.st_kind}})
                | stat ->
                  (match check_owned_parent directory stat with
                   | Error _ as error -> error
                   | Ok () -> inspect (stat :: observed) rest)
                | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None) in
           inspect [] (ownership_root :: descendants))
    with
    | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
    | cause -> owned_file_operation_error ~path Inspect_parent cause
  in
  let inspect_current parent_before fd descriptor =
    match inspect_parent () with
    | Error _ as error -> error
    | Ok None -> Ok false
    | Ok (Some parent_now) ->
      if not (List.length parent_before = List.length parent_now
        && List.for_all2 same_file_identity parent_before parent_now)
      then Ok false
      else
        (try
           let current = Unix.lstat path in
           Ok
             (current.st_kind = Unix.S_REG
              && (not single_link || (current.st_nlink=1 && (Unix.fstat fd).st_nlink=1))
              && same_file_identity descriptor current)
         with
         | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
         | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
         | cause -> owned_file_operation_error ~path Inspect_path cause)
  in
  match inspect_parent () with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some parent_before) ->
    let before_open =
      try Ok (Some (Unix.lstat path)) with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
      | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
      | cause -> owned_file_operation_error ~path Inspect_path cause
    in
    (match before_open with
     | Error _ as error -> error
     | Ok None -> Ok None
     | Ok (Some stat) when stat.st_kind <> Unix.S_REG ->
       owned_file_error (Path_is_not_regular_file { path; kind = stat.st_kind })
     | Ok (Some stat) when single_link && stat.st_nlink<>1 -> link_error ()
     | Ok (Some before_open) ->
       let opened =
         try
           Ok
             (Unix.openfile
                path
                [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ]
                0)
         with
         | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
         | cause -> owned_file_operation_error ~path Open_path cause
       in
       (match opened with
        | Error _ as error -> error
        | Ok fd ->
          let result =
            match Unix.fstat fd with
            | exception cause -> (* cancel-guard-ok: Unix.fstat performs no Eio operation. *)
              owned_file_operation_error ~path Inspect_descriptor cause
            | descriptor
              when descriptor.st_kind <> Unix.S_REG
                   || not (same_file_identity before_open descriptor) ->
              owned_file_error (Filesystem_identity_changed { path })
            | descriptor ->
              (match check_file descriptor with
               | Error _ as error -> error
               | Ok () ->
              (match inspect_current parent_before fd descriptor with
               | Error _ as error -> error
               | Ok false ->
                 owned_file_error (Filesystem_identity_changed { path })
               | Ok true ->
                 (match read_descriptor ~path fd descriptor with
                  | Error _ as error -> error
                  | Ok content ->
                    (match Unix.fstat fd with
                     | after_read when same_file_snapshot descriptor after_read
                         && (not single_link || after_read.st_nlink=1)
                         && (match owner_uid with None -> true | Some uid -> after_read.st_uid = uid) ->
                       (match inspect_current parent_before fd descriptor with
                        | Error _ as error -> error
                        | Ok true -> Ok (Some content)
                        | Ok false ->
                          owned_file_error
                            (Filesystem_identity_changed { path }))
                     | _ ->
                       owned_file_error (Filesystem_identity_changed { path })
                     | exception cause -> (* cancel-guard-ok: Unix.fstat performs no Eio operation. *)
                       owned_file_operation_error
                         ~path
                         Inspect_descriptor
                         cause))))
          in
          let close_result =
            try Unix.close fd; Ok () with
            | Eio.Cancel.Cancelled _ as cancellation ->
              reraise_current cancellation
            | cause -> Error cause
          in
          (match close_result, result with
           | Ok (), result -> result
           | Error cause, Ok _ ->
             owned_file_operation_error ~path Close_descriptor cause
           | Error cause, Error error ->
             Error { error with close_failure = Some cause })))
;;

type owned_regular_file_contents =
  { content : string
  ; snapshot : owned_regular_file_snapshot
  }

let load_owned_regular_file_with_snapshot_blocking ?owner_uid ?single_link ?parent_lstat ~ownership_root path =
  load_owned_regular_file_blocking_with
    ?owner_uid ?single_link ?parent_lstat ~ownership_root
    ~read_descriptor:(fun ~path fd descriptor ->
      match read_exact_file_descriptor ~path fd descriptor.Unix.st_size with
      | Error _ as error -> error
      | Ok content ->
        Ok
          { content
          ; snapshot = owned_regular_file_snapshot_of_stats descriptor
          })
    path
;;

let load_owned_regular_file_with_snapshot ?owner_uid ?single_link ~ownership_root path =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      load_owned_regular_file_with_snapshot_blocking ?owner_uid ?single_link ~ownership_root path)
    (fun _fs ->
       let result =
         Fs_compat_internal.Systhread_host.run ~label:(labelled "fs-compat-load-owned-file" path) (fun () ->
           load_owned_regular_file_with_snapshot_blocking
             ?owner_uid ?single_link ~ownership_root
             path)
       in
       Eio.Fiber.check ();
       result)
;;

module Owned_read_for_testing = struct
  let load_with_snapshot ?single_link ~parent_lstat ~owner_uid ~ownership_root path =
    load_owned_regular_file_with_snapshot_blocking ?single_link ~parent_lstat ~owner_uid ~ownership_root path
end

let load_owned_regular_file ~ownership_root path =
  load_owned_regular_file_with_snapshot ~ownership_root path
  |> Result.map (Option.map (fun contents -> contents.content))
;;
