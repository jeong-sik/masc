open Fs_compat_base_io
open Fs_compat_owned_file

module Retention_directory = struct
  include Fs_compat_internal.Retention_directory
  let blocking_io = { run = (fun f ->
    match execution_context () with
    | Non_eio -> f ()
    | Eio_fiber -> Fs_compat_internal.Systhread_host.run ~label:"retention-directory" f) }
  let with_root ?(io = blocking_io) path f = with_root ~io path f
end

external open_owned_directory_root : string -> Unix.file_descr
  = "caml_masc_owned_directory_root"
external open_owned_directory_child : Unix.file_descr -> string -> Unix.file_descr
  = "caml_masc_owned_directory_open"
external owned_directory_names : Unix.file_descr -> string list
  = "caml_masc_owned_directory_names"

type owned_inventory_root =
  { inventory_path : string
  ; requested_path : string
  ; inventory_fd : Unix.file_descr
  ; inventory_stat : Unix.stats
  }

let owned_inventory_root_path root = root.inventory_path
let owned_inventory_root_stat root = root.inventory_stat

let inventory_root_current root =
  try
    String.equal (Unix.realpath root.requested_path) root.inventory_path
    && same_file_identity (Unix.lstat root.inventory_path) root.inventory_stat
  with Unix.Unix_error _ -> false
;;

let with_owned_inventory_root path fn =
  try
    let initial = Unix.stat path in
    let canonical = Unix.realpath path in
    let fd = open_owned_directory_root canonical in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
      let observed = Unix.fstat fd in
      let root = { inventory_path=canonical; requested_path=path;
        inventory_fd=fd; inventory_stat=observed } in
      if initial.Unix.st_kind <> Unix.S_DIR
         || not (same_file_identity initial observed)
         || not (inventory_root_current root)
      then owned_file_error (Filesystem_identity_changed {path})
      else
        let result = fn root in
        if inventory_root_current root then result
        else owned_file_error (Filesystem_identity_changed {path}))
  with
  | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
  | cause -> owned_file_operation_error ~path Read_contents cause
;;

exception Owned_directory_read_rejected of owned_regular_file_read_failure
exception Owned_directory_descendant_missing of exn

type 'a owned_directory_listing =
  | Owned_directory_absent of owned_regular_file_read_error
  | Owned_directory_entries of 'a

let read_owned_directory_blocking ?owner_uid ?inventory_root ?sync_directory ~allow_initial_absence
    ~before_read ~after_read ~visit_directory ~ownership_root path =
  match owned_directory_paths ~ownership_root path with
  | Error rejection ->
    owned_file_error (Ownership_boundary_rejected { path; rejection })
  | Ok descendants ->
    let opened = ref [] in
    let descriptors = ref [] in
    let close_all () =
      let close_failure = ref None in
      List.iter (fun fd ->
        try Unix.close fd with
        | Unix.Unix_error _ as ex ->
          if !close_failure = None then close_failure := Some ex) !descriptors;
      !close_failure
    in
    let check_owner directory (stat : Unix.stats) =
      match owner_uid with
      | None -> ()
      | Some expected_uid ->
          if stat.st_uid <> expected_uid then
            raise (Owned_directory_read_rejected (Owned_path_owner_mismatch
              {path=directory; expected_uid; actual_uid=stat.st_uid}));
          if stat.st_perm land 0o022 <> 0 then
            raise (Owned_directory_read_rejected (Owned_path_writable_by_others
              {path=directory; permissions=stat.st_perm land 0o7777})) in
    let current () =
      List.for_all (fun (directory, fd, descriptor) ->
        let observed = Unix.lstat directory in
        check_owner directory observed;
        let descriptor_current = match owner_uid with
          | None -> descriptor
          | Some _ ->
              let current = Unix.fstat fd in
              check_owner directory current;
              current in
        observed.Unix.st_kind = Unix.S_DIR
        && same_file_identity observed descriptor
        && same_file_identity descriptor_current descriptor) !opened
    in
    let settle () = Option.iter (fun sync ->
      List.iter (fun (_path,fd,_stat) -> sync fd) !opened) sync_directory in
    let result =
      try
        let bind ~allow_absence directory open_fd =
          let before = match Unix.lstat directory with
            | stat -> Some stat
            | exception Unix.Unix_error (Unix.ENOENT, _, _) when allow_absence -> None in
          Option.iter (check_owner directory) before;
          let fd = try open_fd () with
            | (Unix.Unix_error (Unix.ENOENT, _, _) as cause) when allow_absence ->
                raise (Owned_directory_descendant_missing cause) in
          descriptors := fd :: !descriptors;
          let stat = Unix.fstat fd in
          opened := (directory, fd, stat) :: !opened;
          (match before with
           | None -> raise (Owned_directory_read_rejected (Filesystem_identity_changed {path=directory}))
           | Some before ->
               if before.Unix.st_kind <> Unix.S_DIR || not (same_file_identity before stat)
               then raise (Unix.Unix_error (Unix.EAGAIN, "directory identity", directory)));
          check_owner directory stat;
          fd
        in
        let root_fd = match inventory_root with
          | None -> bind ~allow_absence:false ownership_root (fun () -> open_owned_directory_root ownership_root)
          | Some root ->
            if not (String.equal root.inventory_path ownership_root)
               || not (inventory_root_current root)
            then raise (Unix.Unix_error (Unix.EAGAIN, "inventory root identity", path));
            check_owner ownership_root root.inventory_stat;
            opened := (ownership_root, root.inventory_fd, root.inventory_stat) :: !opened;
            root.inventory_fd
        in
        let fd = List.fold_left (fun parent directory ->
          bind ~allow_absence:allow_initial_absence directory (fun () ->
            open_owned_directory_child parent (Filename.basename directory))) root_fd descendants in
        if not (current ()) then owned_file_error (Filesystem_identity_changed { path })
        else begin
          before_read path;
          let names = owned_directory_names fd |> List.filter (fun name -> name <> "." && name <> "..")
            |> List.sort String.compare in
          let held = {inventory_path=path;requested_path=path;inventory_fd=fd;inventory_stat=Unix.fstat fd} in
          let value = visit_directory held names in
          after_read path;
          settle ();
          if current () then
            Ok (Owned_directory_entries value)
          else owned_file_error (Filesystem_identity_changed { path })
        end
      with
      | Eio.Cancel.Cancelled _ as cancellation ->
        ignore (close_all ()); reraise_current cancellation
      | Owned_directory_read_rejected failure -> owned_file_error failure
      | Owned_directory_descendant_missing cause ->
          (try
             settle ();
             if current () then Ok (Owned_directory_absent
               {failure=Owned_file_operation_failed {path; operation=Read_contents; cause}; close_failure=None})
             else owned_file_error (Filesystem_identity_changed {path})
           with
           | Eio.Cancel.Cancelled _ as cancellation ->
               ignore (close_all ()); reraise_current cancellation
           | Owned_directory_read_rejected failure -> owned_file_error failure
           | cause -> owned_file_operation_error ~path Read_contents cause)
      | (Unix.Unix_error (Unix.ENOENT, _, _) as cause) when Option.is_some owner_uid ->
          (* Before reporting a missing descendant, revalidate every parent
             already bound. Missing is not permission to trust an unsafe parent. *)
          (try
             if current () then owned_file_operation_error ~path Read_contents cause
             else owned_file_error (Filesystem_identity_changed {path})
           with
           | Eio.Cancel.Cancelled _ as cancellation ->
               ignore (close_all ()); reraise_current cancellation
           | Owned_directory_read_rejected failure -> owned_file_error failure
           | cause -> owned_file_operation_error ~path Read_contents cause)
      | cause -> owned_file_operation_error ~path Read_contents cause
    in
    match close_all (), result with
    | None, result -> result
    | Some cause, Ok _ -> owned_file_operation_error ~path Close_descriptor cause
    | Some cause, Error error -> Error { error with close_failure = Some cause }
;;

let read_owned_directory_listing ?owner_uid ?inventory_root
    ?(before_read = fun _ -> ()) ?(after_read = fun _ -> ())
    ?sync_directory ~visit_directory
    ~allow_initial_absence ~ownership_root path =
  with_fs_or_fallback ~path
    ~fallback:(fun () -> read_owned_directory_blocking ?owner_uid ?inventory_root
      ?sync_directory ~allow_initial_absence ~before_read ~after_read ~visit_directory ~ownership_root path)
    (fun _fs ->
      let result = Fs_compat_internal.Systhread_host.run
        ~label:(labelled "fs-compat-read-owned-directory" path)
        (fun () -> read_owned_directory_blocking ?owner_uid ?inventory_root
          ?sync_directory ~allow_initial_absence ~before_read ~after_read ~visit_directory ~ownership_root path) in
      Eio.Fiber.check ();
      result)
;;

let read_owned_directory ?owner_uid ?inventory_root ?before_read ?after_read ~ownership_root path =
  match read_owned_directory_listing ?owner_uid ?inventory_root ?before_read ?after_read
      ~visit_directory:(fun _ names -> names) ~allow_initial_absence:false ~ownership_root path with
  | Ok (Owned_directory_entries names) -> Ok names
  | Ok (Owned_directory_absent error) -> Error error
  | Error _ as error -> error
;;

let read_owned_directory_if_present ~owner_uid ?inventory_root ?before_read ?after_read ~ownership_root path =
  read_owned_directory_listing ~owner_uid ?inventory_root ?before_read ?after_read
    ~visit_directory:(fun _ names -> names) ~allow_initial_absence:true ~ownership_root path
  |> Result.map (function
    | Owned_directory_entries names -> Some names
    | Owned_directory_absent _ -> None)
;;

let with_owned_directory_inventory_if_present ~owner_uid ~inventory_root ~sync_directory path visit_directory =
  read_owned_directory_blocking ~owner_uid ~inventory_root ~sync_directory
    ~allow_initial_absence:true ~before_read:(fun _ -> ()) ~after_read:(fun _ -> ())
    ~visit_directory ~ownership_root:inventory_root.inventory_path path
  |> Result.map (function
    | Owned_directory_entries value -> Some value
    | Owned_directory_absent _ -> None)
;;

type owned_regular_file_prefix =
  { content : string
  ; file_size : int
  ; modified_at : float
  ; truncated : bool
  }

let load_owned_regular_file_prefix_blocking
    ~ownership_root ~max_bytes path =
  if max_bytes < 0
  then
    owned_file_operation_error
      ~path
      Read_contents
      (Invalid_argument "max_bytes must be non-negative")
  else
    load_owned_regular_file_blocking_with
      ~ownership_root
      ~read_descriptor:(fun ~path fd descriptor ->
        let length = min max_bytes descriptor.Unix.st_size in
        match read_exact_file_descriptor ~path fd length with
        | Error _ as error -> error
        | Ok content ->
          Ok
            { content
            ; file_size = descriptor.Unix.st_size
            ; modified_at = descriptor.Unix.st_mtime
            ; truncated = descriptor.Unix.st_size > length
            })
      path
;;

let load_owned_regular_file_prefix ~ownership_root ~max_bytes path =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      load_owned_regular_file_prefix_blocking
        ~ownership_root ~max_bytes path)
    (fun _fs ->
       let result =
         Fs_compat_internal.Systhread_host.run ~label:(labelled "fs-compat-load-owned-prefix" path) (fun () ->
           load_owned_regular_file_prefix_blocking
             ~ownership_root ~max_bytes path)
       in
       Eio.Fiber.check ();
       result)
;;

type owned_regular_file_range =
  { content : string
  ; snapshot : owned_regular_file_snapshot
  }

let load_owned_regular_file_range_blocking
    ~ownership_root ~offset ~max_bytes path =
  if offset < 0 || max_bytes < 0
  then
    owned_file_operation_error
      ~path
      Read_contents
      (Invalid_argument "offset and max_bytes must be non-negative")
  else
    load_owned_regular_file_blocking_with
      ~ownership_root
      ~read_descriptor:(fun ~path fd descriptor ->
        let available = max 0 (descriptor.Unix.st_size - offset) in
        let length = min max_bytes available in
        try
          let positioned = Unix.lseek fd offset Unix.SEEK_SET in
          if positioned <> offset
          then owned_file_error (Filesystem_identity_changed { path })
          else
            match read_exact_file_descriptor ~path fd length with
            | Error _ as error -> error
            | Ok content ->
              Ok
                { content
                ; snapshot =
                    owned_regular_file_snapshot_of_stats descriptor
                }
        with
        | Eio.Cancel.Cancelled _ as cancellation ->
          reraise_current cancellation
        | cause -> owned_file_operation_error ~path Read_contents cause)
      path
;;

let load_owned_regular_file_range
    ~ownership_root ~offset ~max_bytes path =
  with_fs_or_fallback
    ~path
    ~fallback:(fun () ->
      load_owned_regular_file_range_blocking
        ~ownership_root ~offset ~max_bytes path)
    (fun _fs ->
       let result =
         Fs_compat_internal.Systhread_host.run ~label:(labelled "fs-compat-load-owned-range" path) (fun () ->
           load_owned_regular_file_range_blocking
             ~ownership_root ~offset ~max_bytes path)
       in
       Eio.Fiber.check ();
       result)
;;

(* One descriptor serves both the window and the whole-file digest, so the
   bytes returned are the bytes hashed by construction (#38972): there is no
   second open whose file state could differ. The digest streams through a
   fixed buffer; only the window is copied out, so memory is bounded by
   [max_bytes] plus the buffer, never by the file size. *)
type owned_regular_file_range_digest =
  { content : string
  ; sha256 : string
  ; snapshot : owned_regular_file_snapshot
  }

let read_owned_range_digest_descriptor ~offset ~max_bytes ~path fd descriptor =
        let size = descriptor.Unix.st_size in
        let window_start = min offset size in
        let window_stop = window_start + min max_bytes (size - window_start) in
        let window = Bytes.create (window_stop - window_start) in
        try
          let buffer = Bytes.create 65536 in
          let rec feed context position =
            if position = size
            then
              Ok
                { content = Bytes.to_string window
                ; sha256 = Agent_core_sha256.(to_hex (get context))
                ; snapshot = owned_regular_file_snapshot_of_stats descriptor
                }
            else
              match
                Unix.read fd buffer 0 (min (size - position) (Bytes.length buffer))
              with
              | 0 -> owned_file_error (Filesystem_identity_changed { path })
              | count ->
                let chunk_stop = position + count in
                let copy_start = max position window_start in
                let copy_stop = min chunk_stop window_stop in
                if copy_start < copy_stop
                then
                  Bytes.blit
                    buffer
                    (copy_start - position)
                    window
                    (copy_start - window_start)
                    (copy_stop - copy_start);
                feed
                  (Agent_core_sha256.feed_bytes context ~off:0 ~len:count buffer)
                  chunk_stop
              | exception Unix.Unix_error (Unix.EINTR, _, _) -> feed context position
          in
          feed Agent_core_sha256.empty 0
        with
        | Eio.Cancel.Cancelled _ as cancellation ->
          reraise_current cancellation
        | cause -> owned_file_operation_error ~path Read_contents cause
;;

let load_owned_regular_file_range_with_sha256_blocking
    ~ownership_root ~offset ~max_bytes path =
  if offset < 0 || max_bytes < 0
  then
    owned_file_operation_error
      ~path
      Read_contents
      (Invalid_argument "offset and max_bytes must be non-negative")
  else
    load_owned_regular_file_blocking_with
      ~ownership_root
      ~read_descriptor:(read_owned_range_digest_descriptor ~offset ~max_bytes)
      path
;;

external open_owned_inventory_entry : Unix.file_descr -> string -> Unix.file_descr
  = "caml_masc_owned_entry_open"

exception No_exactly_named_entry

let with_owned_inventory_entry
      ?owner_uid ?(single_link = false) ?(exact_names = false) ?excluded_stat root path fn =
  let ownership_root = root.inventory_path in
  match owned_directory_paths ~ownership_root (Filename.dirname path) with
  | Error rejection -> owned_file_error (Ownership_boundary_rejected {path; rejection})
  | Ok descendants ->
    let descriptors = ref [] in
    let opened = ref [] in
    let check_owner path (stat : Unix.stats) =
      (match owner_uid with
       | None -> ()
       | Some expected_uid ->
         if stat.st_uid <> expected_uid then
           raise (Owned_directory_read_rejected (Owned_path_owner_mismatch
             {path;expected_uid;actual_uid=stat.st_uid}));
         if stat.st_perm land 0o022 <> 0 then
           raise (Owned_directory_read_rejected (Owned_path_writable_by_others
             {path;permissions=stat.st_perm land 0o7777})));
      if single_link && stat.st_kind = Unix.S_REG && stat.st_nlink <> 1 then
        raise (Owned_directory_read_rejected (Owned_file_operation_failed
          {path;operation=Inspect_descriptor;cause=Sys_error "owned record has multiple hard links"})) in
    let check_excluded path stat = match excluded_stat with
      | Some excluded when same_file_identity excluded stat ->
        raise (Owned_directory_read_rejected (Owned_file_operation_failed
          {path;operation=Inspect_descriptor;cause=Sys_error "excluded directory"}))
      | Some _ | None -> () in
    let current_entry path fd initial =
      let observed = Unix.lstat path in
      check_owner path observed;
      let descriptor = match owner_uid with
        | None -> initial
        | Some _ -> let descriptor = Unix.fstat fd in check_owner path descriptor; descriptor in
      observed.Unix.st_kind = initial.Unix.st_kind
      && descriptor.Unix.st_kind = initial.Unix.st_kind
      && same_file_identity observed initial && same_file_identity descriptor initial in
    (* HIGH-RISK-UNREVIEWED: decides which request names reach a file.
       [openat] resolves a name by the rules of the file system, so on one
       that folds case or Unicode form many spellings open one entry. Under
       [exact_names] a component is opened only when the held parent lists a
       name of the same bytes. *)
    let require_listed parent name =
      if exact_names && not (List.exists (String.equal name) (owned_directory_names parent))
      then raise No_exactly_named_entry in
    (* Under [exact_names] an ancestor is opened as the leaf is, without
       [O_DIRECTORY], and its kind is read from the descriptor: the errno of a
       refused [O_DIRECTORY] open does not tell a regular file from a symbolic
       link on every platform. *)
    let open_ancestor parent directory =
      let name = Filename.basename directory in
      require_listed parent name;
      let fd = if exact_names then open_owned_inventory_entry parent name
        else open_owned_directory_child parent name in
      descriptors := fd :: !descriptors;
      let stat = Unix.fstat fd in
      (match stat.Unix.st_kind with
       | Unix.S_DIR -> ()
       | Unix.S_REG -> raise No_exactly_named_entry
       | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK ->
         raise (Owned_directory_read_rejected (Owned_file_operation_failed
           {path=directory;operation=Inspect_descriptor;
            cause=Sys_error "owned path ancestor is not a directory"})));
      fd, stat in
    let close_all () =
      let failure = ref None in
      List.iter (fun fd ->
        try Unix.close fd with Unix.Unix_error _ as ex ->
          if !failure = None then failure := Some ex) !descriptors;
      match !failure with None -> () | Some ex -> raise ex
    in
    try
      Fun.protect ~finally:close_all (fun () ->
        if not (inventory_root_current root)
        then owned_file_error (Filesystem_identity_changed {path})
        else begin
          check_owner ownership_root (Unix.fstat root.inventory_fd);
          check_excluded ownership_root root.inventory_stat;
          let parent = List.fold_left (fun parent directory ->
            let fd, stat = open_ancestor parent directory in
            check_owner directory stat;
            check_excluded directory stat;
            opened := (directory, fd, stat) :: !opened;
            fd) root.inventory_fd descendants in
          require_listed parent (Filename.basename path);
          let fd = open_owned_inventory_entry parent (Filename.basename path) in
          descriptors := fd :: !descriptors;
          let stat = Unix.fstat fd in
          check_owner path stat;
          check_excluded path stat;
          let ancestors_current () = inventory_root_current root
            && current_entry ownership_root root.inventory_fd root.inventory_stat
            && List.for_all (fun (directory, fd, stat) -> current_entry directory fd stat) !opened in
          let current () = ancestors_current () && current_entry path fd stat in
          if not (current ()) then owned_file_error (Filesystem_identity_changed {path})
          else
            let result = fn fd stat parent in
            if ancestors_current ()
               && current_entry path fd stat && same_file_snapshot stat (Unix.fstat fd)
            then result
            else owned_file_error (Filesystem_identity_changed {path})
        end)
    with
    | Eio.Cancel.Cancelled _ as cancellation -> reraise_current cancellation
    | Owned_directory_read_rejected failure -> owned_file_error failure
    | cause -> owned_file_operation_error ~path Read_contents cause
;;

type owned_relative_path = string list
