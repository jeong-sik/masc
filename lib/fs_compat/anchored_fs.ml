type t = Unix.file_descr

module Segment = struct
  type t = string

  type error =
    | Empty
    | Dot
    | Dot_dot
    | Contains_separator
    | Contains_nul

  let of_string = function
    | "" -> Error Empty
    | "." -> Error Dot
    | ".." -> Error Dot_dot
    | value when String.contains value '/' -> Error Contains_separator
    | value when String.contains value '\000' -> Error Contains_nul
    | value -> Ok value
  ;;

  let to_string value = value

  let error_to_string = function
    | Empty -> "path segment is empty"
    | Dot -> "path segment is dot"
    | Dot_dot -> "path segment is dot-dot"
    | Contains_separator -> "path segment contains a separator"
    | Contains_nul -> "path segment contains NUL"
  ;;
end

type kind =
  | Regular_file
  | Directory
  | Symbolic_link
  | Other

type stat =
  { kind : kind
  ; size : int64
  ; device : int64
  ; inode : int64
  ; link_count : int64
  }

type mutation_error =
  | Not_committed of
      { cause : exn
      ; cleanup_error : exn option
      }
  | Committed_not_durable of exn

external open_root_fd : string -> Unix.file_descr = "masc_anchored_open_root"

external open_dir_fd
  :  Unix.file_descr
  -> string
  -> Unix.file_descr
  = "masc_anchored_open_dir"

external open_read_fd
  :  Unix.file_descr
  -> string
  -> Unix.file_descr
  = "masc_anchored_open_read"

external create_exclusive_fd
  :  Unix.file_descr
  -> string
  -> int
  -> Unix.file_descr
  = "masc_anchored_create_exclusive"

external mkdir_at : Unix.file_descr -> string -> int -> unit = "masc_anchored_mkdir"
external unlink_at : Unix.file_descr -> string -> unit = "masc_anchored_unlink"

external rename_at
  :  Unix.file_descr
  -> string
  -> Unix.file_descr
  -> string
  -> unit
  = "masc_anchored_rename"

external link_at
  :  Unix.file_descr
  -> string
  -> Unix.file_descr
  -> string
  -> unit
  = "masc_anchored_link"

external stat_at_raw
  :  Unix.file_descr
  -> string
  -> (int * int64 * int64 * int64 * int64) option
  = "masc_anchored_stat"

external fdopendir : Unix.file_descr -> Unix.dir_handle = "masc_anchored_fdopendir"

let segment_value = Segment.to_string

let mutation_error_to_string = function
  | Not_committed { cause; cleanup_error = None } ->
    Printf.sprintf "not committed: %s" (Printexc.to_string cause)
  | Not_committed { cause; cleanup_error = Some cleanup_error } ->
    Printf.sprintf
      "not committed: %s; cleanup failed: %s"
      (Printexc.to_string cause)
      (Printexc.to_string cleanup_error)
  | Committed_not_durable cause ->
    Printf.sprintf "committed but not durable: %s" (Printexc.to_string cause)
;;

let combine_close ~operation fd f =
  let outcome =
    try Ok (f ()) with
    | exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  let close_outcome =
    try
      Unix.close fd;
      Ok ()
    with
    | exn -> Error exn
  in
  match outcome, close_outcome with
  | Ok value, Ok () -> value
  | Error (exn, backtrace), Ok () -> Printexc.raise_with_backtrace exn backtrace
  | Ok _, Error close_error -> raise close_error
  | Error (primary, _), Error close_error ->
    raise
      (Failure
         (Printf.sprintf
            "%s failed (%s); descriptor close also failed (%s)"
            operation
            (Printexc.to_string primary)
            (Printexc.to_string close_error)))
;;

let with_open_root path f =
  let fd = open_root_fd path in
  combine_close ~operation:"anchored root transaction" fd (fun () -> f fd)
;;

let with_open_dir parent name f =
  let fd = open_dir_fd parent (segment_value name) in
  combine_close ~operation:"anchored directory transaction" fd (fun () -> f fd)
;;

let with_open_dir_opt parent name f =
  match open_dir_fd parent (segment_value name) with
  | fd ->
    Some
      (combine_close ~operation:"anchored optional-directory transaction" fd
         (fun () -> f fd))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
;;

let fsync fd = Unix.fsync fd

let close_after_primary ~operation fd primary backtrace =
  match Unix.close fd with
  | () -> Printexc.raise_with_backtrace primary backtrace
  | exception close_error ->
    raise
      (Failure
         (Printf.sprintf
            "%s failed (%s); descriptor close also failed (%s)"
            operation
            (Printexc.to_string primary)
            (Printexc.to_string close_error)))
;;

let open_ensured_child parent ~name ~perm ~enforce_perm =
  let name_value = segment_value name in
  let needs_publish, fd =
    match open_dir_fd parent name_value with
    | fd -> false, fd
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      (match mkdir_at parent name_value perm with
       | () -> ()
       | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      true, open_dir_fd parent name_value
  in
  (try
    if enforce_perm then Unix.fchmod fd perm;
    if needs_publish || enforce_perm then fsync fd;
    if needs_publish then fsync parent;
    fd
   with
   | exn ->
     close_after_primary
       ~operation:"anchored ensured-directory acquisition"
       fd
       exn
       (Printexc.get_raw_backtrace ()))
;;

let with_ensure_dir parent ~name ~perm ~enforce_perm f =
  let fd = open_ensured_child parent ~name ~perm ~enforce_perm in
  combine_close ~operation:"anchored ensured-directory transaction" fd (fun () ->
    f fd)
;;

type ensure_step =
  { name : Segment.t
  ; perm : int
  ; enforce_perm : bool
  }

let close_parent_before_descending ~parent ~child =
  match Unix.close parent with
  | () -> child
  | exception parent_close_error ->
    (match Unix.close child with
     | () -> raise parent_close_error
     | exception child_close_error ->
       raise
         (Failure
            (Printf.sprintf
               "ancestor close failed (%s); child close also failed (%s)"
               (Printexc.to_string parent_close_error)
               (Printexc.to_string child_close_error))))
;;

let with_ensure_path ~root steps f =
  let rec walk current = function
    | [] ->
      combine_close ~operation:"anchored ensured-path transaction" current
        (fun () -> f current)
    | { name; perm; enforce_perm } :: rest ->
      let next =
        try open_ensured_child current ~name ~perm ~enforce_perm with
        | exn ->
          close_after_primary
            ~operation:"anchored ensured-path acquisition"
            current
            exn
            (Printexc.get_raw_backtrace ())
      in
      walk (close_parent_before_descending ~parent:current ~child:next) rest
  in
  walk (open_root_fd root) steps
;;

let with_open_path_opt ~root steps f =
  let rec walk current = function
    | [] ->
      Some
        (combine_close ~operation:"anchored existing-path transaction" current
           (fun () -> f current))
    | name :: rest ->
      (match open_dir_fd current (segment_value name) with
       | next ->
         walk
           (close_parent_before_descending ~parent:current ~child:next)
           rest
       | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
         combine_close ~operation:"anchored missing-path close" current
           (fun () -> None)
       | exception exn ->
         close_after_primary
           ~operation:"anchored existing-path acquisition"
           current
           exn
           (Printexc.get_raw_backtrace ()))
  in
  walk (open_root_fd root) steps
;;

let kind_of_int = function
  | 0 -> Regular_file
  | 1 -> Directory
  | 2 -> Symbolic_link
  | 3 -> Other
  | value -> invalid_arg (Printf.sprintf "anchored stat returned invalid kind: %d" value)
;;

let stat dir name =
  Option.map
    (fun (kind, size, device, inode, link_count) ->
       { kind = kind_of_int kind; size; device; inode; link_count })
    (stat_at_raw dir (segment_value name))
;;

let same_identity left right =
  Int64.equal left.device right.device && Int64.equal left.inode right.inode
;;

let kind_of_unix = function
  | Unix.S_REG -> Regular_file
  | Unix.S_DIR -> Directory
  | Unix.S_LNK -> Symbolic_link
  | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK -> Other
;;

let stat_of_unix (metadata : Unix.stats) =
  { kind = kind_of_unix metadata.st_kind
  ; size = Int64.of_int metadata.st_size
  ; device = Int64.of_int metadata.st_dev
  ; inode = Int64.of_int metadata.st_ino
  ; link_count = Int64.of_int metadata.st_nlink
  }
;;

let read_from_fd ~name fd =
  let metadata = Unix.fstat fd in
  if metadata.Unix.st_kind <> Unix.S_REG
  then raise (Unix.Unix_error (Unix.EINVAL, "anchored_read", name));
  let buffer = Bytes.create 65536 in
  let content = Buffer.create (min metadata.Unix.st_size 65536) in
  let rec loop () =
    match Unix.read fd buffer 0 (Bytes.length buffer) with
    | 0 -> Buffer.contents content
    | count ->
      Buffer.add_subbytes content buffer 0 count;
      loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
  in
  loop ()
;;

let read_file_opt dir name =
  let name_value = segment_value name in
  match open_read_fd dir name_value with
  | fd ->
    Some
      (combine_close ~operation:"anchored read" fd (fun () ->
         read_from_fd ~name:name_value fd))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
;;

let read_file dir name =
  match read_file_opt dir name with
  | Some content -> content
  | None ->
    raise
      (Unix.Unix_error (Unix.ENOENT, "anchored_read", segment_value name))
;;

let fsync_file dir name =
  let name_value = segment_value name in
  let fd = open_read_fd dir name_value in
  combine_close ~operation:"anchored file fsync" fd (fun () ->
    let metadata = Unix.fstat fd in
    if metadata.Unix.st_kind <> Unix.S_REG
    then raise (Unix.Unix_error (Unix.EINVAL, "anchored_fsync_file", name_value));
    Unix.fsync fd;
    stat_of_unix metadata)
;;

let chmod_file dir name perm =
  let name_value = segment_value name in
  let fd = open_read_fd dir name_value in
  combine_close ~operation:"anchored file chmod" fd (fun () ->
    let metadata = Unix.fstat fd in
    if metadata.Unix.st_kind <> Unix.S_REG
    then raise (Unix.Unix_error (Unix.EINVAL, "anchored_chmod_file", name_value));
    Unix.fchmod fd perm;
    Unix.fsync fd)
;;

let write_all fd content =
  let rec loop offset =
    if offset < String.length content
    then
      match
        Unix.write_substring fd content offset (String.length content - offset)
      with
      | 0 -> raise (Unix.Unix_error (Unix.EIO, "anchored_write", ""))
      | count -> loop (offset + count)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
  in
  loop 0
;;

let temp_counter = Atomic.make 0

let rec create_temporary dir =
  let sequence = Atomic.fetch_and_add temp_counter 1 in
  let raw = Printf.sprintf ".atomic_%x_%x.tmp" (Unix.getpid ()) sequence in
  let name =
    match Segment.of_string raw with
    | Ok name -> name
    | Error error ->
      invalid_arg
        (Printf.sprintf
           "generated invalid atomic filename: %s"
           (Segment.error_to_string error))
  in
  match create_exclusive_fd dir (segment_value name) 0o600 with
  | fd -> name, fd
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> create_temporary dir
;;

let cleanup_temp dir name =
  try
    unlink_at dir (segment_value name);
    fsync dir;
    None
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> None
  | exn -> Some exn
;;

let atomic_replace dir ~name ~perm content =
  let temp_result =
    try Ok (create_temporary dir) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error exn
  in
  match temp_result with
  | Error cause -> Error (Not_committed { cause; cleanup_error = None })
  | Ok (temp_name, fd) ->
    let write_outcome =
      try
        write_all fd content;
        Unix.fchmod fd perm;
        Unix.fsync fd;
        Ok ()
      with
      | exn -> Error (exn, Printexc.get_raw_backtrace ())
    in
    let close_outcome =
      try
        Unix.close fd;
        Ok ()
      with
      | exn -> Error exn
    in
    let before_commit =
      match write_outcome, close_outcome with
      | Ok (), Ok () -> Ok ()
      | Error (exn, backtrace), Ok () -> Error (exn, backtrace)
      | Ok (), Error exn -> Error (exn, Printexc.get_raw_backtrace ())
      | Error (write_error, backtrace), Error close_error ->
        Error
          ( Failure
              (Printf.sprintf
                 "anchored atomic write failed (%s); close also failed (%s)"
                 (Printexc.to_string write_error)
                 (Printexc.to_string close_error))
          , backtrace )
    in
    (match before_commit with
     | Error ((Eio.Cancel.Cancelled _ as cause), backtrace) ->
       (match cleanup_temp dir temp_name with
        | None -> ()
        | Some cleanup_error ->
          Printf.eprintf
            "[fs_compat] cancelled anchored-write cleanup failed name=%s: %s\n%!"
            (segment_value temp_name)
            (Printexc.to_string cleanup_error));
       Printexc.raise_with_backtrace cause backtrace
     | Error (cause, _) ->
       Error
         (Not_committed
            { cause; cleanup_error = cleanup_temp dir temp_name })
     | Ok () ->
       (match
          rename_at
            dir
            (segment_value temp_name)
            dir
            (segment_value name)
        with
        | exception (Eio.Cancel.Cancelled _ as exn) ->
          let cleanup_error = cleanup_temp dir temp_name in
          (match cleanup_error with
           | None -> ()
           | Some error ->
             Printf.eprintf
               "[fs_compat] cancelled anchored-rename cleanup failed name=%s: %s\n%!"
               (segment_value temp_name)
               (Printexc.to_string error));
          raise exn
        | exception cause ->
          Error
            (Not_committed
               { cause; cleanup_error = cleanup_temp dir temp_name })
        | () ->
          (match fsync dir with
           | () -> Ok ()
           | exception cause -> Error (Committed_not_durable cause))))
;;

let unlink_if_exists dir name =
  match unlink_at dir (segment_value name) with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok `Missing
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception cause ->
    Error (Not_committed { cause; cleanup_error = None })
  | () ->
    (match fsync dir with
     | () -> Ok `Removed
     | exception cause -> Error (Committed_not_durable cause))
;;

let rename ~src_dir ~src ~dst_dir ~dst =
  match
    rename_at
      src_dir
      (segment_value src)
      dst_dir
      (segment_value dst)
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception cause ->
    Error (Not_committed { cause; cleanup_error = None })
  | () ->
    (try
       fsync dst_dir;
       if src_dir != dst_dir then fsync src_dir;
       Ok ()
     with
     | cause -> Error (Committed_not_durable cause))
;;

let link_no_replace ~src_dir ~src ~dst_dir ~dst =
  match
    link_at
      src_dir
      (segment_value src)
      dst_dir
      (segment_value dst)
  with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception cause ->
    Error (Not_committed { cause; cleanup_error = None })
  | () ->
    (match fsync dst_dir with
     | () -> Ok ()
     | exception cause -> Error (Committed_not_durable cause))
;;

let combine_closedir handle f =
  let outcome =
    try Ok (f ()) with
    | exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  let close_outcome =
    try
      Unix.closedir handle;
      Ok ()
    with
    | exn -> Error exn
  in
  match outcome, close_outcome with
  | Ok value, Ok () -> value
  | Error (exn, backtrace), Ok () -> Printexc.raise_with_backtrace exn backtrace
  | Ok _, Error close_error -> raise close_error
  | Error (primary, _), Error close_error ->
    raise
      (Failure
         (Printf.sprintf
            "anchored readdir failed (%s); closedir also failed (%s)"
            (Printexc.to_string primary)
            (Printexc.to_string close_error)))
;;

let read_dir dir =
  let duplicate = Unix.dup ~cloexec:true dir in
  let handle =
    try fdopendir duplicate with
    | exn ->
      let close_error =
        try
          Unix.close duplicate;
          None
        with
        | close_error -> Some close_error
      in
      (match close_error with
       | None -> raise exn
       | Some close_error ->
         raise
           (Failure
              (Printf.sprintf
                 "fdopendir failed (%s); duplicate close also failed (%s)"
                 (Printexc.to_string exn)
                 (Printexc.to_string close_error))))
  in
  combine_closedir handle (fun () ->
    let rec loop acc =
      match Unix.readdir handle with
      | "." | ".." -> loop acc
      | raw ->
        (match Segment.of_string raw with
         | Ok segment -> loop (segment :: acc)
         | Error error ->
           raise
             (Failure
                (Printf.sprintf
                   "filesystem returned invalid directory entry: %s"
                   (Segment.error_to_string error))))
      | exception End_of_file ->
        List.sort
          (fun left right ->
             String.compare (segment_value left) (segment_value right))
          acc
    in
    loop [])
