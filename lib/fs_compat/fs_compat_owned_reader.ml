open Fs_compat_base_io
open Fs_compat_owned_file
open Fs_compat_owned_inventory

let owned_relative_path components =
  let invalid component =
    String.equal component ""
    || String.equal component Filename.current_dir_name
    || String.equal component Filename.parent_dir_name
    || String.contains component '/'
  in
  match components with
  | [] -> Error "owned relative path has no component"
  | _ :: _ ->
    (match List.find_opt invalid components with
     | Some component -> Error (Printf.sprintf "owned relative path component %S is not a name" component)
     | None -> Ok components)
;;

let owned_relative_path_to_string components = String.concat Filename.dir_sep components

(* Spelled from the canonical held root, which the entry chain compares with. *)
let owned_inventory_path root relative = List.fold_left Filename.concat root.inventory_path relative

let owned_inventory_entry_kind root relative =
  with_owned_inventory_entry root (owned_inventory_path root relative)
    (fun _fd stat _parent -> Ok stat.Unix.st_kind)
;;

type owned_regular_file_reread =
  | Same_file
  | Read of owned_regular_file_contents

(* The checks of one regular file beneath an owned root, shared by the load
   and the reload: [of_regular_file] decides what to take from the opened
   file, and its result is returned only when the entry chain and the file
   still have the identity they were opened with. *)
let with_single_link_regular_file_beneath ~root ?excluded_directory ~of_regular_file relative =
  let missing error = match error.close_failure with
    | Some _ -> false
    | None ->
      (match error.failure with
       | Owned_file_operation_failed {cause;_} ->
         (match cause with Unix.Unix_error (code, _, _) -> code = Unix.ENOENT | _ -> false)
       | Ownership_boundary_rejected _ | Path_is_not_regular_file _
       | Filesystem_identity_changed _ | Owned_path_owner_mismatch _
       | Owned_path_writable_by_others _ -> false) in
  let read () =
    with_owned_inventory_root root (fun inventory_root ->
      let path = owned_inventory_path inventory_root relative in
      let read_entry ?excluded_stat () =
        match with_owned_inventory_entry ~single_link:true ?excluded_stat inventory_root path
          (fun fd stat _parent ->
            if stat.Unix.st_kind <> Unix.S_REG then
              owned_file_error (Path_is_not_regular_file {path;kind=stat.st_kind})
            else Result.map Option.some (of_regular_file ~path fd stat)) with
        | Error error when missing error -> Ok None
        | Error error -> Error error
        | Ok body -> Ok body in
      match excluded_directory with
      | None -> read_entry ()
      | Some excluded ->
        let excluded_path = owned_inventory_path inventory_root excluded in
        let bound = ref false in
        (match with_owned_inventory_entry inventory_root excluded_path
          (fun _fd stat _parent ->
            bound := true;
            if stat.Unix.st_kind <> Unix.S_DIR then
              owned_file_operation_error ~path:excluded_path Inspect_descriptor
                (Sys_error "excluded path is not a directory")
            else read_entry ~excluded_stat:stat ()) with
         | Error error when not !bound && missing error ->
           let result = read_entry () in
           (match result with
            | Error _ -> result
            | Ok _ ->
              (match with_owned_inventory_entry inventory_root excluded_path
                (fun _fd _stat _parent -> Ok ()) with
               | Error error when missing error -> result
               | Error error -> Error error
               | Ok () -> owned_file_error (Filesystem_identity_changed {path=excluded_path})))
         | Error error -> Error error
         | Ok body -> Ok body))
  in
  match execution_context (), get_fs_opt () with
  | Non_eio, (Some _ | None) | Eio_fiber, None -> read ()
  | Eio_fiber, Some _ ->
    let result = Fs_compat_internal.Systhread_host.run ~label:"fs-compat-read-beneath" read in
    Eio.Fiber.check ();
    result
;;

let read_regular_file_contents ~path fd (stat : Unix.stats) =
  Result.map
    (fun content : owned_regular_file_contents ->
       { content; snapshot = owned_regular_file_snapshot_of_stats stat })
    (read_exact_file_descriptor ~path fd stat.st_size)
;;

let load_single_link_regular_file_beneath ~root ?excluded_directory relative =
  with_single_link_regular_file_beneath
    ~root
    ?excluded_directory
    ~of_regular_file:read_regular_file_contents
    relative
;;

let reload_single_link_regular_file_beneath ~root ?excluded_directory ~held relative =
  with_single_link_regular_file_beneath
    ~root
    ?excluded_directory
    ~of_regular_file:(fun ~path fd stat ->
      if equal_owned_regular_file_snapshot held (owned_regular_file_snapshot_of_stats stat)
      then Ok Same_file
      else Result.map (fun contents -> Read contents) (read_regular_file_contents ~path fd stat))
    relative
;;

let with_owned_inventory_regular_file ~owner_uid root relative fn =
  let path = owned_inventory_path root relative in
  with_owned_inventory_entry ~owner_uid ~single_link:true root path (fun file stat parent ->
    if stat.Unix.st_kind <> Unix.S_REG then
      owned_file_error (Path_is_not_regular_file {path;kind=stat.st_kind})
    else Ok (fn ~file ~parent ~stat))
;;

type owned_reader = Eio_unix.Fd.t
external owned_reader_pread_unix : Unix.file_descr -> int64 -> int -> string
  = "caml_masc_owned_reader_pread"

let owned_reader_root_matches (expected : Eio.File.Stat.t) (stat : Unix.stats) =
  stat.st_kind=Unix.S_DIR && Int64.of_int stat.st_dev=expected.dev && Int64.of_int stat.st_ino=expected.ino
  && Int64.of_int stat.st_uid=expected.uid && stat.st_perm land 0o7777=expected.perm land 0o7777
let owned_reader_parent_unchanged (expected : Eio.File.Stat.t) (current : Eio.File.Stat.t) =
  current.kind=`Directory && current.dev=expected.dev && current.ino=expected.ino
  && current.uid=expected.uid && current.perm=expected.perm

let open_owned_reader ~sw ~parent ~leaf =
  Eio.Switch.check sw;
  try
  let result=Eio.Cancel.protect (fun () ->
    let unowned=ref None in
    Fun.protect ~finally:(fun () -> Option.iter Unix.close !unowned) (fun () ->
      let relative=match owned_relative_path [leaf] with
        | Ok relative -> relative
        | Error detail -> invalid_arg detail in
      let expected=Eio.Path.stat ~follow:false parent in
      let path=Eio.Path.native_exn parent in
      let opened=Fs_compat_internal.Systhread_host.run ~label:"owned-reader-open" (fun () ->
        with_owned_inventory_root path (fun root ->
          if not (owned_reader_root_matches expected (owned_inventory_root_stat root))
          then owned_file_error (Filesystem_identity_changed {path})
          else with_owned_inventory_regular_file ~owner_uid:(Unix.geteuid ()) root relative
            (fun ~file ~parent:_ ~stat:_ ->
              let fd=Unix.dup ~cloexec:true file in unowned:=Some fd;fd))) in
      match opened with
      | Error _ as error -> error
      | Ok fd ->
        let current=Eio.Path.stat ~follow:false parent in
        if not (owned_reader_parent_unchanged expected current)
        then owned_file_error (Filesystem_identity_changed {path})
        else (
          Eio.Switch.check sw;
          let reader=Eio_unix.Fd.of_unix ~sw ~blocking:false ~seekable:true ~close_unix:true fd in
          unowned:=None;
          Ok reader))) in
  Eio.Switch.check sw;
  result
  with
  | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
  | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _) as cause ->
    owned_file_operation_error ~path:leaf Read_contents cause
;;

let owned_reader_stat reader =
  let stat=Fs_compat_internal.Systhread_host.run ~label:"owned-reader-stat" (fun () ->
    Eio_unix.Fd.use_exn "owned reader stat" reader Unix.LargeFile.fstat) in
  let kind=match stat.st_kind with
    | Unix.S_REG -> `Regular_file | S_DIR -> `Directory | S_CHR -> `Character_special
    | S_BLK -> `Block_device | S_LNK -> `Symbolic_link | S_FIFO -> `Fifo | S_SOCK -> `Socket in
  { Eio.File.Stat.dev=Int64.of_int stat.st_dev;ino=Int64.of_int stat.st_ino;kind;
    perm=stat.st_perm;nlink=Int64.of_int stat.st_nlink;uid=Int64.of_int stat.st_uid;
    gid=Int64.of_int stat.st_gid;rdev=Int64.of_int stat.st_rdev;
    size=Optint.Int63.of_int64 stat.st_size;atime=stat.st_atime;mtime=stat.st_mtime;ctime=stat.st_ctime }
;;

let owned_reader_pread reader ~offset ~length =
  if offset<0L || length<0 || length>Sys.max_string_length then invalid_arg "owned reader range";
  Fs_compat_internal.Systhread_host.run ~label:"owned-reader-pread" (fun () ->
    Eio_unix.Fd.use_exn "owned reader pread" reader (fun fd -> owned_reader_pread_unix fd offset length))
;;

module Owned_reader_sync_stage = struct
  type t = Sync_file | Sync_parent
end
let sync_owned_reader_with_hook ~before_sync ~parent ~leaf reader =
  try
    let result=Eio.Cancel.protect (fun () ->
      let relative=match owned_relative_path [leaf] with
        | Ok relative -> relative | Error detail -> invalid_arg detail in
      let expected=Eio.Path.stat ~follow:false parent in
      let path=Eio.Path.native_exn parent in
      let synced=Fs_compat_internal.Systhread_host.run ~label:"owned-reader-sync" (fun () ->
        Eio_unix.Fd.use_exn "owned reader sync" reader (fun held ->
          let initial=Unix.fstat held in
          let same (stat : Unix.stats) = same_file_snapshot initial stat
            && initial.st_uid=stat.st_uid && initial.st_gid=stat.st_gid
            && initial.st_perm=stat.st_perm && initial.st_nlink=stat.st_nlink
            && initial.st_rdev=stat.st_rdev in
          with_owned_inventory_root path (fun root ->
            if not (owned_reader_root_matches expected (owned_inventory_root_stat root))
            then owned_file_error (Filesystem_identity_changed {path})
            else
              let checked=with_owned_inventory_regular_file ~owner_uid:(Unix.geteuid ()) root relative
                (fun ~file ~parent ~stat ->
                  if not (same stat) then owned_file_error (Filesystem_identity_changed {path})
                  else (
                    before_sync Owned_reader_sync_stage.Sync_file;Unix.fsync file;
                    before_sync Owned_reader_sync_stage.Sync_parent;Unix.fsync parent;
                    if same (Unix.fstat held) then Ok ()
                    else owned_file_error (Filesystem_identity_changed {path}))) in
              Result.join checked))) in
      match synced with
      | Error _ as error -> error
      | Ok () ->
        let current=Eio.Path.stat ~follow:false parent in
        if owned_reader_parent_unchanged expected current then Ok ()
        else owned_file_error (Filesystem_identity_changed {path})) in
    Eio.Fiber.check ();
    result
  with
  | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
  | (Eio.Io _ | Unix.Unix_error _ | Sys_error _ | Invalid_argument _) as cause ->
    owned_file_operation_error ~path:leaf Read_contents cause
;;

let sync_owned_reader ~parent ~leaf reader =
  sync_owned_reader_with_hook ~before_sync:(fun _ -> ()) ~parent ~leaf reader
;;
module Owned_reader_for_testing = struct
  type sync_stage = Owned_reader_sync_stage.t = Sync_file | Sync_parent
  let sync_owned_reader = sync_owned_reader_with_hook
end

let owned_inventory_entry_digest root relative =
  let path = owned_inventory_path root relative in
  with_owned_inventory_entry root path (fun fd stat _parent ->
    if stat.Unix.st_kind <> Unix.S_REG
    then owned_file_error (Path_is_not_regular_file {path; kind=stat.st_kind})
    else read_owned_range_digest_descriptor ~offset:0 ~max_bytes:0 ~path fd stat)
;;

let load_owned_regular_file_range_with_sha256
    ~ownership_root ~offset ~max_bytes path =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      load_owned_regular_file_range_with_sha256_blocking
        ~ownership_root ~offset ~max_bytes path)
    (fun _fs ->
       let result =
         Fs_compat_internal.Systhread_host.run
           ~label:(labelled "fs-compat-load-owned-range-digest" path)
           (fun () ->
              load_owned_regular_file_range_with_sha256_blocking
                ~ownership_root ~offset ~max_bytes path)
       in
       Eio.Fiber.check ();
       result)
;;

(* The whole-file digest is the range read with an empty window, so one feed
   loop serves both callers and the two cannot drift. *)
let sha256_owned_regular_file_blocking ~ownership_root path =
  load_owned_regular_file_range_with_sha256_blocking
    ~ownership_root ~offset:0 ~max_bytes:0 path
  |> Result.map
       (Option.map (fun (digest : owned_regular_file_range_digest) ->
          digest.sha256))
;;

let sha256_owned_regular_file ~ownership_root path =
  with_fs_or_fallback ~path
    ~fallback:(fun () -> sha256_owned_regular_file_blocking ~ownership_root path)
    (fun _fs ->
      let result = Fs_compat_internal.Systhread_host.run ~label:(labelled "fs-compat-hash-owned-file" path)
        (fun () -> sha256_owned_regular_file_blocking ~ownership_root path) in
      Eio.Fiber.check ();
      result)
;;

(* Not [Eio.Path.read_dir]. eio_posix makes its result with [Array.of_list]
   over the names it read, and the first name is a young string. For more
   than 256 names (Max_young_wosize) the runtime then empties every domain's
   minor heap before it allocates the array ([caml_uniform_array_make] in
   runtime/array.c): one stop-the-world minor collection per listing, however
   large the minor heap is. [Sys.readdir] allocates its array in C and forces
   none. *)
let read_dir (path : string) : string list =
  let read () = Stdlib.Sys.readdir path |> Array.to_list |> List.sort String.compare in
  with_fs_or_fallback ~path ~fallback:read (fun _fs ->
    on_systhread ~label:(labelled "fs-compat-read-dir" path) read)
;;
