open Fs_compat_internal
open Fs_compat_base_io
open Fs_compat_owned_file

(** Parse pre-read string lines as JSONL.
    Use when lines come from typed tail readers such as
    [Keeper_memory.read_file_tail_lines_result] or other non-file
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
    Delegates to [parse_jsonl_lines] for the actual parsing. *)
let load_jsonl_diagnostics (path : string) : Yojson.Safe.t list * int =
  if not (file_exists path)
  then [], 0
  else (
    let content = load_file path in
    let lines = String.split_on_char '\n' content in
    parse_jsonl_lines ~source:path lines)
;;

(** Load JSONL file as list of JSON values.
    Malformed lines are logged and dropped. *)
let load_jsonl (path : string) : Yojson.Safe.t list = fst (load_jsonl_diagnostics path)

(* Bounded byte slice of a file. Clamps to the current size; a missing
   file or an empty clamped range returns "". Stdlib-blocking like the
   other tail-readers — callers bound [len], so the read cost is fixed
   regardless of file size (RFC-0228 P1). *)
let read_slice ~path ~from ~len =
  if not (file_exists path) || len <= 0 then ""
  else begin
    let ic = Stdlib.open_in_bin path in
    Stdlib.Fun.protect
      ~finally:(fun () -> Stdlib.close_in_noerr ic)
      (fun () ->
         let size = Stdlib.in_channel_length ic in
         let from = if from < 0 then 0 else if from > size then size else from in
         let len = Stdlib.min len (size - from) in
         if len <= 0 then ""
         else begin
           Stdlib.seek_in ic from;
           Stdlib.really_input_string ic len
         end)
  end
;;

(* Fold over newline-terminated lines appended after byte offset [from].
   Append-only JSONL stores never rewrite earlier bytes, so a (offset,
   accumulator) pair is a pure function of the file prefix — callers cache
   it and re-scan only the delta instead of the whole file. Bytes after the
   last '\n' (a partially flushed line) are excluded from both the fold and
   the returned boundary, so the next call re-reads them once the writer
   completes the line. A [from] beyond EOF (file truncated/rotated) falls
   back to a full scan from byte 0; callers detect shrinkage the same way
   via the returned boundary. Blank lines advance the boundary but are not
   folded. *)
let fold_appended_lines ~path ~from ~init ~f =
  if not (file_exists path)
  then init, 0
  else begin
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
         let len = in_channel_length ic in
         let from = if from < 0 || from > len then 0 else from in
         seek_in ic from;
         let chunk = Bytes.create 65536 in
         let line_buf = Buffer.create 256 in
         let acc = ref init in
         let boundary = ref from in
         let pos = ref from in
         let rec loop () =
           let n = input ic chunk 0 (Bytes.length chunk) in
           if n > 0
           then begin
             for i = 0 to n - 1 do
               match Bytes.get chunk i with
               | '\n' ->
                 let line = Buffer.contents line_buf in
                 Buffer.clear line_buf;
                 boundary := !pos + i + 1;
                 if not (String.equal (String.trim line) "")
                 then acc := f !acc line
               | c -> Buffer.add_char line_buf c
             done;
             pos := !pos + n;
             loop ()
           end
         in
         loop ();
         !acc, !boundary)
  end
;;

(** Stream JSONL line-by-line, folding [f] over parsed values.

    Uses [Eio.Buf_read.lines] over [Eio.Path.with_open_in] when the
    global fs is registered ([set_fs] called at boot), giving O(1)
    memory regardless of file size and non-blocking IO inside
    the Eio scheduler.  Falls back to {!load_jsonl} + [List.fold_left]
    when no fs is available (tests, pre-boot helpers).

    [line_no] is 1-based and skips blank lines so it tracks the
    {b printed} JSONL row number rather than the raw byte stream
    position — matches {!load_jsonl_diagnostics} semantics.

    Malformed JSON lines are skipped after a stderr warning, like
    {!load_jsonl_diagnostics}.  Returns [init] when [path] does not
    exist (no read attempt).  Raises [Sys_error] on read failures of
    an existing file (e.g. permission denied, mid-stream IO error). *)
let fold_jsonl_lines ~init ~f path =
  if not (file_exists path)
  then init
  else
    (* 16 MiB per-line cap — protects [Eio.Buf_read.of_flow] from a
       corrupted/attacker-controlled JSONL with no newlines (which
       would otherwise force the buf_read to grow unbounded).  Real
       audit/metric rows are <1 KiB; 16 MiB is two orders of
       magnitude over expected and still bounds the OOM blast. *)
    let max_line_bytes = 16 * 1024 * 1024 in
    with_fs_or_fallback
      ~path
      ~fallback:(fun () ->
        (* Iterate raw lines so [line_no] reflects the same "non-blank
           index, malformed counted but skipped" semantics as the Eio
           branch; folding over [fst (load_jsonl_diagnostics ...)] alone
           would skip malformed rows and desync the index. *)
        let line_idx = ref 0 in
        let acc = ref init in
        let chan = Stdlib.open_in path in
        Fun.protect
          ~finally:(fun () -> Stdlib.close_in_noerr chan)
          (fun () ->
            try
              while true do
                let raw = Stdlib.input_line chan in
                let trimmed = String.trim raw in
                if not (String.equal trimmed "")
                then begin
                  incr line_idx;
                  match Yojson.Safe.from_string trimmed with
                  | json -> acc := f !acc ~line_no:!line_idx json
                  | exception Yojson.Json_error msg ->
                    Stdlib.Printf.eprintf
                      "[fs_compat] malformed JSONL (%s) line %d: %s\n%!"
                      path
                      !line_idx
                      msg
                end
              done
            with End_of_file -> ());
        !acc)
      (fun fs ->
         let eio_path = Eio.Path.(fs / path) in
         Eio.Path.with_open_in eio_path (fun flow ->
           let buf = Eio.Buf_read.of_flow ~max_size:max_line_bytes flow in
           let line_idx = ref 0 in
           let acc = ref init in
           Eio.Buf_read.lines buf
           |> Seq.iter (fun raw ->
             let trimmed = String.trim raw in
             if not (String.equal trimmed "")
             then begin
               incr line_idx;
               match Yojson.Safe.from_string trimmed with
               | json -> acc := f !acc ~line_no:!line_idx json
               | exception Yojson.Json_error msg ->
                 Stdlib.Printf.eprintf
                   "[fs_compat] malformed JSONL (%s) line %d: %s\n%!"
                   path
                   !line_idx
                   msg
             end);
           !acc))
;;

(** Append JSON value as line to JSONL file.

    Atomic per record (in-process): the same [append_path_mutex_registry]
    used by {!append_file_unix} serializes callers against each
    other, and a fresh fd is opened and closed around a single
    [output_string] of [record + "\n"]. Cross-domain safe. Records
    of any size are written without interleaving (the mutex spans
    the whole syscall sequence). Crash durability is not guaranteed
    (no fsync).

    PR #15936 introduced this helper with its own per-path
    registry. This commit unifies the registry with
    [append_file_unix] so a caller mixing the two helpers on a
    single path remains race-free. *)
(* RFC-0162 §3.4: per-path fd cache (single fd per path, cross-domain
   serialized by [append_path_mutex_registry]).

   RFC-0108 §3.3 declared cross-domain fd cache an explicit non-goal
   under the assumption that fd count ≈ keeper N (≤64). Production
   evidence (RFC-0162 §1.3) invalidated that on the open/close
   *churn* axis: 22,440 tool calls × fresh open+close per record was
   shifting host kernel filp_cachep slab pressure and contributing
   to the EMFILE/ENFILE trace.

   Design choice — Per-path (not per-domain) cache:
   - A single [out_channel] per path eliminates the cross-domain
     write interleave window that an early RFC draft's per-domain
     design opened up (POSIX O_APPEND+write atomicity is only
     guaranteed up to PIPE_BUF, ~4 KB, and tool-call records
     routinely exceed that).
   - The existing [get_append_path_mutex] is already a cross-domain
     [Stdlib.Mutex] per path. Wrapping [output_string + flush]
     inside it preserves RFC-0108 §3.2's Record-interleave-0
     guarantee verbatim.
   - The cache lookup uses a separate, microsecond-scoped mutex
     ([fd_cache_mu]) so two appends to *different* paths never
     contend on a global fd-cache lock. *)
let invalidate_cached_writer path =
  let path_mu = get_append_path_mutex path in
  Stdlib.Mutex.protect path_mu (fun () -> Fd_cache.invalidate path)
;;

let reset_fd_cache_for_testing () = Fd_cache.reset_for_testing ()

let with_cached_writer_for_testing path f = Fd_cache.with_writer path f

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
