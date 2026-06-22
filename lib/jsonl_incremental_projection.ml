(* Incremental, offset-tracked projection for large append-only JSONL logs.

   Keeper decision/memory logs grow without bound (multi-MB, streamed several
   times per second under active turns). The dashboard feeds previously re-read
   and re-parsed the file tail on every request; a whole-file mtime cache only
   helps while the file is idle and degrades to a full re-parse on every append.

   This projection instead tracks a per-key byte offset and folds only the bytes
   appended since the last read into a caller-supplied accumulator. Steady-state
   cost is O(bytes appended since last read), not O(tail size), so an actively
   written log is never re-parsed in full.

   Boundaries handled:
   - Partial trailing line: only bytes up to the last newline are consumed; the
     remainder is re-read once the writer completes the line.
   - First read / cold key: seeks to the last [initial_tail_bytes] and aligns to
     the next newline (a mid-file seek lands inside a line, which is dropped),
     so the feed starts from a bounded recent window rather than the whole file.
   - Truncation / rotation: a file shorter than the consumed offset resets the
     key and re-seeds from the tail.

   The accumulator type and its bound are the caller's: [add] folds one complete
   line and is where a feed enforces a most-recent-N ring. [add] runs only on
   genuinely new lines.

   Concurrency: single serving domain. [add] / file reads may yield; a racing
   rebuild of the same key re-folds the same new bytes into the same result and
   the later [Hashtbl.replace] wins, costing only repeated work. *)

type 'a t = (string, int * int * 'a) Hashtbl.t
(* key -> (consumed byte offset at a line boundary, file inode, accumulator).
   The inode guards rotation/recreation: a same-path file with a new inode
   resets the key even when its size exceeds the consumed offset. *)

let create () : 'a t = Hashtbl.create 16

(* Stable file identity for rotation detection. A path whose inode changed since
   the last read is a different physical file (deleted+recreated or rotated), so
   its consumed offset must not carry over. [-1] when the file cannot be stat'd,
   which never matches a stored inode (guarded by [>= 0]) and forces a cold
   reseed. *)
let file_inode path : int =
  match Unix.stat path with
  | s -> s.Unix.st_ino
  | exception Unix.Unix_error _ -> -1

(* Read bytes [start, upto) from [path]. Robust to the file having grown since
   the size was sampled: never reads past the channel's own length. *)
let read_range path ~start ~upto : string =
  if upto <= start then ""
  else
    In_channel.with_open_bin path (fun ic ->
        let len = Int64.to_int (In_channel.length ic) in
        let start = if start < 0 then 0 else min start len in
        let upto = min upto len in
        if upto <= start then ""
        else begin
          In_channel.seek ic (Int64.of_int start);
          match In_channel.really_input_string ic (upto - start) with
          | Some s -> s
          | None ->
              In_channel.seek ic (Int64.of_int start);
              In_channel.input_all ic
        end)

let last_newline (s : string) : int option =
  let rec loop i = if i < 0 then None else if s.[i] = '\n' then Some i else loop (i - 1) in
  loop (String.length s - 1)

let first_newline (s : string) : int option =
  String.index_opt s '\n'

let lines_of (s : string) : string list =
  (* Match the legacy [read_file_tail_lines_result] normalization: drop lines
     that are empty after trimming, so a whitespace-only line never reaches a
     downstream JSON parser. The returned line itself is left untrimmed. *)
  String.split_on_char '\n' s |> List.filter (fun l -> String.trim l <> "")

let read (t : 'a t) ~(key : string) ~(path : string) ~(empty : 'a)
    ~(add : 'a -> string -> 'a) ~(initial_tail_bytes : int) : 'a =
  match Fs_compat.file_size path with
  | None ->
      (* Missing file: keep whatever was last projected, else empty. *)
      (match Hashtbl.find_opt t key with Some (_, _, acc) -> acc | None -> empty)
  | Some size ->
      let inode = file_inode path in
      (* Resolve the starting offset and whether it is already line-aligned.
         Reuse the cached offset only when the file is the same physical file
         (inode unchanged) and has not been truncated below it; otherwise — cold
         key, truncation ([c > size]), or rotation/recreation (inode changed) —
         reseed from the tail. *)
      let consumed, base_acc, aligned =
        match Hashtbl.find_opt t key with
        | Some (c, ino, acc) when ino = inode && ino >= 0 && c <= size ->
            (c, acc, true)
        | _ ->
            let s = max 0 (size - initial_tail_bytes) in
            (s, empty, s = 0)
      in
      if consumed >= size then (
        Hashtbl.replace t key (size, inode, base_acc);
        base_acc)
      else
        let buf = read_range path ~start:consumed ~upto:size in
        (* Align a mid-file cold start to the next line boundary. *)
        let buf, consumed =
          if aligned then (buf, consumed)
          else
            match first_newline buf with
            | Some f ->
                ( String.sub buf (f + 1) (String.length buf - f - 1),
                  consumed + f + 1 )
            | None -> ("", size)
        in
        (match last_newline buf with
        | None ->
            (* No complete line yet; hold the offset and wait for the writer. *)
            Hashtbl.replace t key (consumed, inode, base_acc);
            base_acc
        | Some p ->
            let complete = String.sub buf 0 (p + 1) in
            let new_consumed = consumed + p + 1 in
            let acc = List.fold_left add base_acc (lines_of complete) in
            Hashtbl.replace t key (new_consumed, inode, acc);
            acc)

let recent_lines (t : string list t) ~(key : string) ~(path : string)
    ~(window : int) ~(initial_tail_bytes : int) : string list =
  (* [add] prepends, so the accumulator is newest-first; cap it to [window]
     by dropping the oldest (tail) entries, then reverse to oldest-first so
     the result is byte-for-byte the order a plain tail read would yield. *)
  let newest_first =
    read t ~key ~path ~empty:[]
      ~add:(fun acc line ->
        let acc = line :: acc in
        if List.length acc <= window then acc
        else List.filteri (fun idx _ -> idx < window) acc)
      ~initial_tail_bytes
  in
  List.rev newest_first

let peek (t : 'a t) ~(key : string) : 'a option =
  match Hashtbl.find_opt t key with Some (_, _, acc) -> Some acc | None -> None
