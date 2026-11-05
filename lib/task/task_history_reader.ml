open Result.Syntax
open Task_history_types
open Task_history_inventory

(* The same 64 KiB transfer size used by Fs_compat's streaming file readers.
   This amortizes owned opens and systhread crossings without loading a dated
   file into memory. It is not a row/history limit: rows span arbitrary blocks. *)
let io_block_bytes=65536
module String_set = Set.Make (String)
module String_map = Map.Make (String)

type reader = {
  root : string;
  file : file;
  mutable fd : Unix.file_descr option;
  mutable parent_stat : Unix.stats option;
  mutable block_from : int;
  mutable block_len : int;
  mutable block : string;
  mutable top_block_from : int;
  mutable top_block_len : int;
  mutable top_block : string;
  mutable retained_blocks : (int * int * string) list;
}

let matches_file_ownership (s : Fs_compat.owned_regular_file_snapshot) (st : Unix.stats) =
  st.st_kind = Unix.S_REG
  && st.st_uid = s.owner_uid
  && (st.st_perm land 0o7777) = s.permissions
  && (st.st_perm land 0o022) = 0

let matches_file_snapshot (s : Fs_compat.owned_regular_file_snapshot) (st : Unix.stats) =
  matches_file_ownership s st
  && st.st_dev = s.device
  && st.st_ino = s.inode
  && (st.st_size > s.file_size
      || (st.st_size = s.file_size
          && Float.equal st.st_mtime s.modified_at
          && Float.equal st.st_ctime s.changed_at))

let inspect_parent_dir ~root path =
  inspect_owned_dir ~root (Filename.dirname path)

let inspect_leaf_path (file : file) =
  try
    let st = Unix.lstat file.path in
    if not (matches_file_ownership file.snapshot st) then Error Source_unavailable
    else if matches_file_snapshot file.snapshot st then Ok st
    else Error Source_changed
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Source_changed
  | Unix.Unix_error _ -> Error Source_unavailable

let verify_reader_current reader fd (parent_before : Unix.stats) =
  let* parent_now = inspect_parent_dir ~root:reader.root reader.file.path in
  if not (same_stat_identity parent_before parent_now) then Error Source_changed
  else
    let* _leaf = inspect_leaf_path reader.file in
    try
      let st = Unix.fstat fd in
      if not (matches_file_ownership reader.file.snapshot st) then Error Source_unavailable
      else if matches_file_snapshot reader.file.snapshot st then Ok ()
      else Error Source_changed
    with Unix.Unix_error _ -> Error Source_unavailable

let ensure_reader_fd reader =
  match reader.fd with
  | Some fd -> Ok fd
  | None ->
    let* parent_before = inspect_parent_dir ~root:reader.root reader.file.path in
    let* _leaf_before = inspect_leaf_path reader.file in
    let* fd =
      try
        Ok (Unix.openfile reader.file.path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0)
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Source_changed
      | Unix.Unix_error _ -> Error Source_unavailable
    in
    (match verify_reader_current reader fd parent_before with
     | Ok () ->
       reader.fd <- Some fd;
       reader.parent_stat <- Some parent_before;
       Ok fd
     | Error _ as err ->
       (try Unix.close fd with Unix.Unix_error _ -> ());
       err)

let with_reader ~root file fn =
  let r =
    {
      root;
      file;
      fd = None;
      parent_stat = None;
      block_from = -1;
      block_len = 0;
      block = "";
      top_block_from = -1;
      top_block_len = 0;
      top_block = "";
      retained_blocks = [];
    }
  in
  let close_quiet () =
    match r.fd with
    | None -> ()
    | Some fd ->
      r.fd <- None;
      (try Unix.close fd with Unix.Unix_error _ -> ())
  in
  Fun.protect ~finally:close_quiet (fun () ->
    let* result = fn r in
    match r.fd, r.parent_stat with
    | None, _ -> Ok result
    | Some fd, Some parent_before ->
      let* () = verify_reader_current r fd parent_before in
      r.fd <- None;
      (try Unix.close fd; Ok result with Unix.Unix_error _ -> Error Source_unavailable)
    | Some _, None -> Error Source_changed)

let reset_reader_block_memo reader =
  reader.block_from <- -1;
  reader.block_len <- 0;
  reader.block <- "";
  reader.top_block_from <- -1;
  reader.top_block_len <- 0;
  reader.top_block <- "";
  reader.retained_blocks <- []

let rec read_exact fd bytes offset remaining =
  if remaining = 0 then Ok ()
  else
    match Unix.read fd bytes offset remaining with
    | 0 -> Error Source_changed
    | n -> read_exact fd bytes (offset + n) (remaining - n)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_exact fd bytes offset remaining
    | exception Unix.Unix_error _ -> Error Source_unavailable

let load_block reader offset =
  if offset<0 || offset>=reader.file.snapshot.file_size then Error Source_changed
  else if offset>=reader.block_from && offset-reader.block_from<reader.block_len then Ok ()
  else
    let from=offset-(offset mod io_block_bytes) in
    if from=reader.top_block_from && offset-from<reader.top_block_len then (
      reader.block_from<-reader.top_block_from;
      reader.block_len<-reader.top_block_len;
      reader.block<-reader.top_block;
      Ok ()
    ) else
      match List.find_opt (fun (f, l, _) -> f=from && offset-f<l) reader.retained_blocks with
      | Some (f, l, b) ->
        reader.block_from<-f;
        reader.block_len<-l;
        reader.block<-b;
        Ok ()
      | None ->
        let length=min io_block_bytes (reader.file.snapshot.file_size-from) in
        let* fd=ensure_reader_fd reader in
        let* ()=
          try if Unix.lseek fd from Unix.SEEK_SET=from then Ok () else Error Source_changed
          with Unix.Unix_error _ -> Error Source_unavailable in
        let bytes=Bytes.create length in
        let* ()=read_exact fd bytes 0 length in
        let* ()=
          try
            let st=Unix.fstat fd in
            if not (matches_file_ownership reader.file.snapshot st) then Error Source_unavailable
            else if matches_file_snapshot reader.file.snapshot st then Ok () else Error Source_changed
          with Unix.Unix_error _ -> Error Source_unavailable in
        let block=Bytes.unsafe_to_string bytes in
        reader.block_from<-from;
        reader.block_len<-length;
        reader.block<-block;
        if reader.top_block_from<0 then (
          reader.top_block_from<-from;
          reader.top_block_len<-length;
          reader.top_block<-block);
        if reader.file.snapshot.file_size <= 8 * io_block_bytes then
          reader.retained_blocks <- (from, length, block) :: reader.retained_blocks;
        Ok ()

let byte reader offset =
  let* ()=load_block reader offset in
  Ok reader.block.[offset-reader.block_from]

type row_slice = {
  mutable row_offset : int;
  mutable row_buf : string;
  mutable row_pos : int;
  mutable row_len : int;
}

let slice_to_string (s : row_slice) =
  if s.row_pos = 0 && s.row_len = String.length s.row_buf then s.row_buf
  else String.sub s.row_buf s.row_pos s.row_len

let rec rindex_newline_scalar s i =
  if i < 0 then -1
  else if String.unsafe_get s i = '\n' then i
  else rindex_newline_scalar s (i - 1)

let rec rindex_newline s i =
  if i < 7 then rindex_newline_scalar s i
  else
    (* XOR makes each newline byte zero. The zero-byte test checks the whole
       word; a scalar search then finds the exact last byte in that word. *)
    let open Int64 in
    let bytes = logxor (String.get_int64_ne s (i - 7)) 0x0a0a0a0a0a0a0a0aL in
    let has_newline =
      logand (logand (sub bytes 0x0101010101010101L) (lognot bytes))
        0x8080808080808080L <> 0L in
    if has_newline then rindex_newline_scalar s i
    else rindex_newline s (i - 8)

let rec index_newline s limit i =
  if i >= limit then -1
  else if String.unsafe_get s i = '\n' then i
  else index_newline s limit (i + 1)

let rec previous_slice_walk reader (out : row_slice) offset chunks =
  if offset < 0 then (
    let line = match chunks with [ single ] -> single | _ -> String.concat "" chunks in
    out.row_offset <- 0;
    out.row_buf <- line;
    out.row_pos <- 0;
    out.row_len <- String.length line;
    Ok true)
  else
    let* () = load_block reader offset in
    let index = offset - reader.block_from in
    let ending = rindex_newline reader.block index in
    if ending >= 0 then
      let start_in_block = ending + 1 in
      let chunk_len = index - ending in
      match chunks with
      | [] ->
        out.row_offset <- reader.block_from + start_in_block;
        out.row_buf <- reader.block;
        out.row_pos <- start_in_block;
        out.row_len <- chunk_len;
        Ok true
      | _ ->
        let chunk = String.sub reader.block start_in_block chunk_len in
        let line = String.concat "" (chunk :: chunks) in
        out.row_offset <- reader.block_from + start_in_block;
        out.row_buf <- line;
        out.row_pos <- 0;
        out.row_len <- String.length line;
        Ok true
    else
      let chunk = String.sub reader.block 0 (index + 1) in
      previous_slice_walk reader out (reader.block_from - 1) (chunk :: chunks)

let previous_slice reader (out : row_slice) before =
  if before = 0 then Ok false
  else
    let* ending = byte reader (before - 1) in
    if ending <> '\n' then Error (Invalid_event { file = reader.file.relative; offset = before - 1 })
    else previous_slice_walk reader out (before - 2) []

let read_line_at reader offset =
  let buffer=Buffer.create 256 in
  let rec walk pos =
    if pos>=reader.file.snapshot.file_size then Error Source_changed
    else
      let* ()=load_block reader pos in
      let index=pos-reader.block_from in
      let ending = index_newline reader.block reader.block_len index in
      if ending >= 0 then
        if Buffer.length buffer=0 then
          Ok (String.sub reader.block index (ending-index))
        else (
          Buffer.add_substring buffer reader.block index (ending-index);
          Ok (Buffer.contents buffer))
      else (
        Buffer.add_substring buffer reader.block index (reader.block_len-index);
        walk (reader.block_from+reader.block_len)) in
  walk offset

let read_line_at_bounded reader ~limit offset =
  if offset < 0 || offset >= limit || limit > reader.file.snapshot.file_size then
    Ok None
  else
    let buffer = Buffer.create 256 in
    let rec walk pos =
      if pos >= limit then Ok None
      else
        let* () = load_block reader pos in
        let index = pos - reader.block_from in
        let avail = min reader.block_len (limit - reader.block_from) in
        if avail <= index then Ok None
        else
          let ending = index_newline reader.block avail index in
          if ending >= 0 then
            if Buffer.length buffer = 0 then
              Ok (Some (String.sub reader.block index (ending - index)))
            else (
              Buffer.add_substring buffer reader.block index (ending - index);
              Ok (Some (Buffer.contents buffer)))
          else (
            Buffer.add_substring buffer reader.block index (avail - index);
            walk (reader.block_from + avail))
    in
    walk offset

let anchor_matches reader position =
  let* () = if position.device=reader.file.snapshot.device && position.inode=reader.file.snapshot.inode
      && position.before<reader.file.snapshot.file_size then Ok () else Error Source_changed in
  let* () = if position.before=0 then Ok () else
    let* value=byte reader (position.before-1) in if value='\n' then Ok () else Error Source_changed in
  let* line = read_line_at reader position.before in
  if hash line=position.anchor then Ok () else Error Source_changed
