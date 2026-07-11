type t = Unix.file_descr

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

external read_dir_raw : Unix.file_descr -> string list = "masc_anchored_readdir"

let is_single_segment value =
  (not (String.equal value ""))
  && not (String.equal value ".")
  && not (String.equal value "..")
  && String.equal (Filename.basename value) value
;;

let require_segment ~operation value =
  if not (is_single_segment value)
  then invalid_arg (Printf.sprintf "%s: expected one path segment: %S" operation value)
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
  require_segment ~operation:"with_open_dir" name;
  let fd = open_dir_fd parent name in
  combine_close ~operation:"anchored directory transaction" fd (fun () -> f fd)
;;

let fsync fd = Unix.fsync fd

let with_ensure_dir parent ~name ~perm ~enforce_perm f =
  require_segment ~operation:"with_ensure_dir" name;
  let created =
    match open_dir_fd parent name with
    | fd -> false, fd
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      (match mkdir_at parent name perm with
       | () -> ()
       | exception Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      let fd = open_dir_fd parent name in
      true, fd
  in
  let was_created, fd = created in
  combine_close ~operation:"anchored ensured-directory transaction" fd (fun () ->
    if was_created then fsync parent;
    if enforce_perm
    then (
      Unix.fchmod fd perm;
      fsync fd)
    else if was_created
    then fsync fd;
    f fd)
;;

let kind_of_int = function
  | 0 -> Regular_file
  | 1 -> Directory
  | 2 -> Symbolic_link
  | 3 -> Other
  | value -> invalid_arg (Printf.sprintf "anchored stat returned invalid kind: %d" value)
;;

let stat dir name =
  require_segment ~operation:"stat" name;
  Option.map
    (fun (kind, size, device, inode, link_count) ->
       { kind = kind_of_int kind; size; device; inode; link_count })
    (stat_at_raw dir name)
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

let read_file dir name =
  require_segment ~operation:"read_file" name;
  let fd = open_read_fd dir name in
  combine_close ~operation:"anchored read" fd (fun () ->
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
    loop ())
;;

let fsync_file dir name =
  require_segment ~operation:"fsync_file" name;
  let fd = open_read_fd dir name in
  combine_close ~operation:"anchored file fsync" fd (fun () ->
    let metadata = Unix.fstat fd in
    if metadata.Unix.st_kind <> Unix.S_REG
    then raise (Unix.Unix_error (Unix.EINVAL, "anchored_fsync_file", name));
    Unix.fsync fd;
    stat_of_unix metadata)
;;

let chmod_file dir name perm =
  require_segment ~operation:"chmod_file" name;
  let fd = open_read_fd dir name in
  combine_close ~operation:"anchored file chmod" fd (fun () ->
    let metadata = Unix.fstat fd in
    if metadata.Unix.st_kind <> Unix.S_REG
    then raise (Unix.Unix_error (Unix.EINVAL, "anchored_chmod_file", name));
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
  let name = Printf.sprintf ".atomic_%x_%x.tmp" (Unix.getpid ()) sequence in
  match create_exclusive_fd dir name 0o600 with
  | fd -> name, fd
  | exception Unix.Unix_error (Unix.EEXIST, _, _) -> create_temporary dir
;;

let unlink_if_exists dir name =
  require_segment ~operation:"unlink_if_exists" name;
  match unlink_at dir name with
  | () ->
    fsync dir;
    true
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> false
;;

let save_file_atomic dir ~name ~perm content =
  require_segment ~operation:"save_file_atomic" name;
  let temp_name, fd = create_temporary dir in
  let cleanup () =
    match unlink_if_exists dir temp_name with
    | true | false -> Ok ()
    | exception exn -> Error exn
  in
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
  let primary =
    match write_outcome, close_outcome with
    | Ok (), Ok () -> Ok ()
    | Error (exn, _), Ok () | Ok (), Error exn -> Error exn
    | Error (write_error, _), Error close_error ->
      Error
        (Failure
           (Printf.sprintf
              "anchored atomic write failed (%s); close also failed (%s)"
              (Printexc.to_string write_error)
              (Printexc.to_string close_error)))
  in
  match primary with
  | Error exn ->
    (match exn with
     | Eio.Cancel.Cancelled _ ->
       (match cleanup () with
        | Ok () -> ()
        | Error cleanup_error ->
          Printf.eprintf
            "[fs_compat] cancelled anchored-write cleanup failed name=%s: %s\n%!"
            temp_name
            (Printexc.to_string cleanup_error));
       raise exn
     | _ ->
       let detail =
         match cleanup () with
         | Ok () -> Printexc.to_string exn
         | Error cleanup_error ->
           Printf.sprintf
             "%s; temporary cleanup failed: %s"
             (Printexc.to_string exn)
             (Printexc.to_string cleanup_error)
       in
       Error (Printf.sprintf "save_file_atomic %s: %s" name detail))
  | Ok () ->
    (match rename_at dir temp_name dir name with
     | () ->
       (match fsync dir with
        | () -> Ok ()
        | exception exn ->
          Error
            (Printf.sprintf
               "save_file_atomic %s committed but directory fsync failed: %s"
               name
               (Printexc.to_string exn)))
     | exception exn ->
       let detail =
         match cleanup () with
         | Ok () -> Printexc.to_string exn
         | Error cleanup_error ->
           Printf.sprintf
             "%s; temporary cleanup failed: %s"
             (Printexc.to_string exn)
             (Printexc.to_string cleanup_error)
       in
       Error (Printf.sprintf "save_file_atomic %s: %s" name detail))
;;

let rename ~src_dir ~src ~dst_dir ~dst =
  require_segment ~operation:"rename source" src;
  require_segment ~operation:"rename destination" dst;
  rename_at src_dir src dst_dir dst;
  fsync dst_dir;
  if src_dir != dst_dir then fsync src_dir
;;

let link_no_replace ~src_dir ~src ~dst_dir ~dst =
  require_segment ~operation:"link source" src;
  require_segment ~operation:"link destination" dst;
  link_at src_dir src dst_dir dst;
  fsync dst_dir
;;

let read_dir dir = read_dir_raw dir |> List.sort String.compare
