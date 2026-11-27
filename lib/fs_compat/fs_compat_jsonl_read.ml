open Fs_compat_internal
open Fs_compat_base_io

(** Parse pre-read string lines as JSONL.
    Use when lines come from typed tail readers such as
    [Keeper_memory_recall.read_file_tail_lines_result] or other non-file
    sources.  Logs malformed lines with [source] tag.

    Matches [fold_jsonl]'s line-tracking semantics: [line_no] is
    1-based, increments only on non-blank lines so it tracks the
    {b printed} JSONL row number an operator would see in [cat -n].
    Aligns with the file-level diagnostic at line 559 ("line %d") so
    a malformed log from either path uses the same orchestrate system. *)
(* One row, with the row number the warning prints. A caller that walks rows
   itself - to stop before the end of a window - parses through this so the
   warning it prints is the same one, in the same shape, as the whole-list
   parse below. *)
let parse_jsonl_line ~(source : string) ~(line_no : int) (line : string)
  : Yojson.Safe.t option
  =
  match Yojson.Safe.from_string line with
  | json -> Some json
  | exception Yojson.Json_error msg ->
    Stdlib.Printf.eprintf
      "[fs_compat] malformed JSONL (%s) line %d: %s\n%!"
      source
      line_no
      msg;
    None
;;

(* Blank lines do not take a number, matching what [cat -n] shows for the
   printed JSONL rows. A caller that needs those numbers without parsing
   uses this. *)
let number_jsonl_lines (lines : string list) : (int * string) list =
  let line_no = ref 0 in
  List.filter_map
    (fun line ->
       let trimmed = String.trim line in
       if String.equal trimmed ""
       then None
       else begin
         incr line_no;
         Some (!line_no, trimmed)
       end)
    lines
;;

let parse_jsonl_lines ~(source : string) (lines : string list) : Yojson.Safe.t list * int =
  let malformed = ref 0 in
  let parsed =
    List.filter_map
      (fun (line_no, trimmed) ->
         match parse_jsonl_line ~source ~line_no trimmed with
         | Some json -> Some json
         | None ->
           incr malformed;
           None)
      (number_jsonl_lines lines)
  in
  parsed, !malformed
;;

(** Load JSONL file, returning parsed values and count of malformed lines.
    Delegates to [parse_jsonl_lines] for the actual parsing.
    Serializes descriptor open/read/close through the per-path append mutex
    so an in-process reader cannot close an fd on the same inode while a
    durable writer holds a POSIX [lockf] record lock. *)
let read_file_under_append_mutex (path : string) : string option =
  let read () =
    with_append_path_mutex path (fun () ->
      match Unix.openfile path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
      | fd ->
        let ic =
          match Unix.in_channel_of_descr fd with
          | ic -> ic
          | exception exn ->
            let bt = Printexc.get_raw_backtrace () in
            (try Unix.close fd with Unix.Unix_error _ -> ());
            Printexc.raise_with_backtrace exn bt
        in
        Some (read_channel_and_close ~before_read:ignore path ic)
      | exception Unix.Unix_error (err, _, _) when err = Unix.ENOENT -> None
      | exception Unix.Unix_error (err, _, _) ->
        raise (Sys_error (Printf.sprintf "%s: %s" path (Unix.error_message err))))
  in
  with_fs_or_fallback
    ~path
    ~fallback:read
    (fun _fs -> on_systhread ~label:(labelled "fs-compat-load-jsonl" path) read)
;;

let load_jsonl_diagnostics (path : string) : Yojson.Safe.t list * int =
  match read_file_under_append_mutex path with
  | None -> [], 0
  | Some content ->
    let lines = String.split_on_char '\n' content in
    parse_jsonl_lines ~source:path lines
;;

(** Load JSONL file as list of JSON values.
    Malformed lines are logged and dropped. *)
let load_jsonl (path : string) : Yojson.Safe.t list = fst (load_jsonl_diagnostics path)

type slice_chunk =
  | Slice_missing
  | Slice_present of
      { file_size : int
      ; actual_from : int
      ; data : string
      }

(* Same ASCII whitespace set that [Stdlib.String.trim] strips. *)
let is_trim_space = function
  | ' ' | '\012' | '\n' | '\r' | '\t' -> true
  | _ -> false
;;

let has_non_trim_space s ofs len =
  let stop = ofs + len in
  let rec loop i =
    if i >= stop then false
    else if is_trim_space (String.unsafe_get s i) then loop (i + 1)
    else true
  in
  loop ofs
;;

(* Bounds [[l, r)] of [String.trim (String.sub s ofs len)] without allocating.
   Returns [None] when the slice is all ASCII whitespace. *)
let trimmed_bounds s ofs len =
  let stop = ofs + len in
  let rec scan_left i =
    if i < stop && is_trim_space (String.unsafe_get s i) then scan_left (i + 1)
    else i
  in
  let l = scan_left ofs in
  if l >= stop then None
  else
    let rec scan_right j =
      if j > l && is_trim_space (String.unsafe_get s (j - 1)) then scan_right (j - 1)
      else j
    in
    Some (l, scan_right stop)
;;

let read_chunk_under_append_mutex ~label ~path ~key_ref ~from ~clamp_beyond_eof ~max_len =
  let read () =
    let key, open_path =
      match key_ref with
      | None -> capture_append_path_mutex_key path, path
      | Some cached ->
        (match !cached with
         | Some key ->
           (* Reopen via the canonicalized pathname carried by [key] so chunks
              2..N always open the same parent directory that [key] locks,
              even if [Sys.chdir] or an ancestor symlink moves between chunks. *)
           key, append_path_mutex_key_path key
         | None ->
           let key = capture_append_path_mutex_key path in
           cached := Some key;
           key, path)
    in
    with_captured_append_path_mutex key (fun () ->
      match Unix.openfile open_path [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
      | exception Unix.Unix_error (err, _, _) when err = Unix.ENOENT ->
        Slice_missing
      | exception Unix.Unix_error (err, _, _) ->
        raise (Sys_error (Printf.sprintf "%s: %s" path (Unix.error_message err)))
      | fd ->
        let ic =
          match Unix.in_channel_of_descr fd with
          | ic -> ic
          | exception exn ->
            let bt = Printexc.get_raw_backtrace () in
            (try Unix.close fd with Unix.Unix_error _ -> ());
            Printexc.raise_with_backtrace exn bt
        in
        Stdlib.Fun.protect
          ~finally:(fun () -> Stdlib.close_in_noerr ic)
          (fun () ->
             let size = Stdlib.in_channel_length ic in
             let actual_from =
               if from < 0 then 0
               else if from > size then (if clamp_beyond_eof then size else 0)
               else from
             in
             let to_read = Int.min max_len (size - actual_from) in
             if to_read <= 0 then
               Slice_present { file_size = size; actual_from; data = "" }
             else (
               Stdlib.seek_in ic actual_from;
               let buf = Bytes.create to_read in
               let rec read_loop ofs =
                 if ofs >= to_read then ofs
                 else
                   let n = Stdlib.input ic buf ofs (to_read - ofs) in
                   if n = 0 then ofs else read_loop (ofs + n)
               in
               let n = read_loop 0 in
               let data =
                 if n = to_read then Bytes.unsafe_to_string buf
                 else Bytes.sub_string buf 0 n
               in
               Slice_present { file_size = size; actual_from; data })))
  in
  with_fs_or_fallback
    ~path
    ~fallback:read
    (fun _fs -> on_systhread ~label:(labelled label path) read)
;;

(* Bounded byte slice of a file. Clamps to the current size; a missing
   file or an empty clamped range returns "". Serialized under the per-path
   append mutex so closing the read fd never drops an in-process writer's
   POSIX record lock. *)
let read_slice ~path ~from ~len =
  if len <= 0 then ""
  else
    match
      read_chunk_under_append_mutex
        ~label:"fs-compat-read-slice"
        ~path
        ~key_ref:None
        ~from
        ~clamp_beyond_eof:true
        ~max_len:len
    with
    | Slice_missing -> ""
    | Slice_present { file_size = _; actual_from = _; data } -> data
;;

(* 1 MiB chunks reduce per-chunk open/seek/close and systhread-hop overhead 4x
   on multi-megabyte JSONL files (e.g. 147 MB boot logs) while keeping peak
   streaming memory O(1). *)
let streaming_jsonl_chunk_bytes = 1_048_576

(* Fold over newline-terminated lines appended after byte offset [from].
   Append-only JSONL stores never rewrite earlier bytes, so a (offset,
   accumulator) pair is a pure function of the file prefix — callers cache
   it and re-scan only the delta instead of the whole file. Bytes after the
   last '\n' (a partially flushed line) are excluded from both the fold and
   the returned boundary, so the next call re-reads them once the writer
   completes the line. A [from] beyond EOF (file truncated/rotated) falls
   back to a full scan from byte 0; callers detect shrinkage the same way
   via the returned boundary. Blank lines advance the boundary but are not
   folded. Each bounded chunk open/read/close is serialized under the
   per-path append mutex and released before calling [f]. *)
let fold_appended_lines ~path ~from ~init ~f =
  let key_ref = ref None in
  let line_buf = Buffer.create 256 in
  let acc = ref init in
  let boundary = ref 0 in
  let pos = ref 0 in
  let rec loop ~first =
    let req_from = if first then from else !pos in
    match
      read_chunk_under_append_mutex
        ~label:"fs-compat-fold-appended"
        ~path
        ~key_ref:(Some key_ref)
        ~from:req_from
        ~clamp_beyond_eof:(not first)
        ~max_len:streaming_jsonl_chunk_bytes
    with
    | Slice_missing ->
      if first then init, 0 else !acc, !boundary
    | Slice_present { file_size; actual_from; data } ->
      if first then (
        boundary := actual_from;
        pos := actual_from);
      let n = String.length data in
      if n > 0 then (
        let rec scan seg_start =
          if seg_start >= n then ()
          else
            match String.index_from_opt data seg_start '\n' with
            | None ->
              Buffer.add_substring line_buf data seg_start (n - seg_start)
            | Some nl ->
              let seg_len = nl - seg_start in
              boundary := !pos + nl + 1;
              if Buffer.length line_buf = 0 then (
                if has_non_trim_space data seg_start seg_len
                then acc := f !acc (String.sub data seg_start seg_len))
              else (
                Buffer.add_substring line_buf data seg_start seg_len;
                let line = Buffer.contents line_buf in
                Buffer.clear line_buf;
                if has_non_trim_space line 0 (String.length line)
                then acc := f !acc line);
              scan (nl + 1)
        in
        scan 0;
        pos := !pos + n;
        if !pos < file_size then loop ~first:false
        else !acc, !boundary)
      else !acc, !boundary
  in
  loop ~first:true
;;

(** Stream JSONL line-by-line, folding [f] over parsed values.

    Reads bounded chunks under the per-path append mutex (on a systhread
    when Eio is active) and releases both descriptor and mutex before
    invoking [f], preserving O(1) memory, non-blocking Eio scheduling,
    and POSIX [lockf] safety for concurrent in-process writers.

    [line_no] is 1-based and skips blank lines so it tracks the
    {b printed} JSONL row number rather than the raw byte stream
    position — matches {!load_jsonl_diagnostics} semantics.

    Malformed JSON lines are skipped after a stderr warning, like
    {!load_jsonl_diagnostics}.  Returns [init] when [path] does not
    exist (no read attempt).  Raises [Sys_error] on read failures of
    an existing file (e.g. permission denied, mid-stream IO error). *)
let fold_jsonl_lines ~init ~f path =
  let max_line_bytes = 16 * 1024 * 1024 in
  let key_ref = ref None in
  let line_buf = Buffer.create 256 in
  let line_idx = ref 0 in
  let acc = ref init in
  let pos = ref 0 in
  let raise_line_too_long () =
    raise
      (Sys_error
         (Printf.sprintf "%s: JSONL line exceeds %d bytes" path max_line_bytes))
  in
  let add_slice s ofs len =
    if Buffer.length line_buf + len > max_line_bytes then raise_line_too_long ();
    Buffer.add_substring line_buf s ofs len
  in
  let emit_trimmed_line trimmed =
    incr line_idx;
    match Yojson.Safe.from_string trimmed with
    | json -> acc := f !acc ~line_no:!line_idx json
    | exception Yojson.Json_error msg ->
      Stdlib.Printf.eprintf
        "[fs_compat] malformed JSONL (%s) line %d: %s\n%!"
        path
        !line_idx
        msg
  in
  let emit_buffered_line () =
    let raw = Buffer.contents line_buf in
    Buffer.clear line_buf;
    let raw_len = String.length raw in
    match trimmed_bounds raw 0 raw_len with
    | None -> ()
    | Some (l, r) ->
      let trimmed =
        if l = 0 && r = raw_len then raw else String.sub raw l (r - l)
      in
      emit_trimmed_line trimmed
  in
  let rec loop ~first =
    match
      read_chunk_under_append_mutex
        ~label:"fs-compat-fold-jsonl"
        ~path
        ~key_ref:(Some key_ref)
        ~from:!pos
        ~clamp_beyond_eof:true
        ~max_len:streaming_jsonl_chunk_bytes
    with
    | Slice_missing ->
      if first then init
      else (
        if Buffer.length line_buf > 0 then emit_buffered_line ();
        !acc)
    | Slice_present { file_size; actual_from = _; data } ->
      let n = String.length data in
      if n > 0 then (
        let rec scan seg_start =
          if seg_start >= n then ()
          else
            match String.index_from_opt data seg_start '\n' with
            | None -> add_slice data seg_start (n - seg_start)
            | Some nl ->
              let seg_len = nl - seg_start in
              if Buffer.length line_buf = 0 then (
                if seg_len > max_line_bytes then raise_line_too_long ();
                match trimmed_bounds data seg_start seg_len with
                | None -> ()
                | Some (l, r) -> emit_trimmed_line (String.sub data l (r - l)))
              else (
                add_slice data seg_start seg_len;
                emit_buffered_line ());
              scan (nl + 1)
        in
        scan 0;
        pos := !pos + n;
        if !pos < file_size then loop ~first:false
        else (
          if Buffer.length line_buf > 0 then emit_buffered_line ();
          !acc))
      else (
        if Buffer.length line_buf > 0 then emit_buffered_line ();
        !acc)
  in
  loop ~first:true
;;

(** Append JSON value as line to JSONL file.

    Atomic per record (in-process): the same [append_path_mutex_registry]
    used by {!append_file_unix} serializes callers against each
    other, and the record plus its newline goes to the path's cached
    descriptor in one append. Cross-domain safe. Records
    of any size are written without interleaving (the mutex spans
    the whole syscall sequence). Crash durability is not guaranteed
    (no fsync).

    PR #15936 introduced this helper with its own per-path
    registry. This commit unifies the registry with
    [append_file_unix] so a caller mixing the two helpers on a
    single path remains race-free. *)
(* RFC-0162 §3.4: per-path fd cache (single fd per path, cross-domain
   serialized by [append_path_mutex_registry]).

   Production evidence (RFC-0162 §1.3) on the open/close *churn*
   axis: 22,440 tool calls × fresh open+close per record was
   shifting host kernel filp_cachep slab pressure and contributing
   to the EMFILE/ENFILE trace.

   Design choice — Per-path (not per-domain) cache:
   - A single descriptor per path eliminates the cross-domain
     write interleave window that an early RFC draft's per-domain
     design opened up (POSIX O_APPEND+write atomicity is only
     guaranteed up to PIPE_BUF, ~4 KB, and tool-call records
     routinely exceed that).
   - The existing [append_path_mutex_registry] already holds a
     cross-domain [Stdlib.Mutex] per path. Wrapping the write
     inside it keeps any two records from interleaving.
   - The cache lookup uses a separate, microsecond-scoped mutex
     ([mu] in [Fd_cache]), released before the write, so two appends
     to *different* paths never wait on each other's writes. *)
let invalidate_cached_writer path =
  with_append_path_mutex path (fun () -> evict_inactive_cached_writer_for_path path)
;;

let reset_fd_cache_for_testing () = Fd_cache.reset_for_testing ()

let with_cached_writer_for_testing path f =
  Fd_cache.with_writer (canonical_append_mutex_path path) (fun target ->
    f (Fd_append_whole.descriptor target))

(* The rest of [fd], from its current position to its end. The buffer starts
   at the length the file reports and one chunk serves every read, so a file
   that does not change while it is read is copied once into the buffer and
   once out of it. A file that grows meanwhile is still read to its end: the
   buffer grows with it. *)
let read_fd_chunks fd =
  let position = Unix.lseek fd 0 Unix.SEEK_CUR in
  let buffer = Buffer.create (Int.max 1 ((Unix.fstat fd).Unix.st_size - position)) in
  let chunk = Bytes.create 65536 in
  let rec read () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buffer
    | count ->
      Buffer.add_subbytes buffer chunk 0 count;
      read ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read ()
  in
  read ()
;;
