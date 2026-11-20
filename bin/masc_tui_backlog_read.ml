(* What a backlog read cost before this reader (#53568, measured on a copy
   of the live file, 5,278,018 bytes and 1,487 tasks): the full reader read
   the file into a fresh string, parsed it into a tree and decoded the tree,
   1.3 M words allocated on the TUI's worker domain and six minor
   collections at the runtime's 256k-word heap per read. The string alone, a
   major allocation, cost two of them. A minor collection stops every
   domain, and a commit moves the file's version on almost every refresh of
   a busy fleet while it changes a task or two.

   Here the file is read into a buffer kept across reads. Yojson's own lexer
   finds where each task row starts and ends and skips it without building
   it. A row whose bytes equal the bytes of a row the last read decoded is
   the task that row decoded to: [Masc_domain.task_of_yojson] reads nothing
   but the row. Only the other rows are parsed and decoded.

   The rest of the document is decoded by [Masc_domain.backlog_of_yojson]
   with an empty task list, and the rows are put in after. That equals the
   full decode: [backlog_of_yojson] decodes each element of [tasks] on its
   own with [task_of_yojson], in order, and nothing else it checks reads an
   element. This reader answers only when every row decoded and the rest of
   the document did. Everything else is
   [Workspace_backlog.read_backlog_observation_with_source_r]'s own answer:
   a missing or unreadable file, a document that is not one object with one
   [tasks] list, a row that does not parse or decode, invalid UTF-8 (the full
   reader repairs it before it parses), and so the recovery copy. *)

type row = { start : int; length : int; task : Masc_domain.task }

(* The bytes one read took apart, and the task each of their rows decoded
   to, found by [row_key]. A key can stand for several rows; a row is taken
   only when all its bytes are equal. *)
type rows = { bytes : Bytes.t; by_key : (int, row) Hashtbl.t }

(* [version] is [None] when the file moved while it was read: its rows are
   still the rows of the bytes read, but no later read takes the
   observation without reading. [spare] is the buffer the next read reads
   into, so the bytes [rows] points into stay as they are. *)
type kept = {
  version : File_version_cache.version option;
  observation : Workspace_backlog.backlog_observation;
  rows : rows;
  spare : Bytes.t;
}

(* A read takes the kept value out and puts one back, so two reads never
   write into one buffer. *)
let kept : kept option Atomic.t = Atomic.make None

let put_back taken = ignore (Atomic.compare_and_set kept None taken)

let full_read config = Workspace_backlog.read_backlog_observation_with_source_r config

let version_of path =
  match Unix.stat path with
  | stats -> Some (File_version_cache.version_of_stats stats)
  | exception Unix.Unix_error _ -> None

(* An eighth more than the file, so a backlog that grows by a task per
   commit is not given a new buffer on every read. *)
let capacity_for length = length + (length / 8) + 1

let read_file buffer path =
  match
    In_channel.with_open_bin path (fun channel ->
      let rec fill buffer filled =
        if filled = Bytes.length buffer then
          fill (Bytes.extend buffer 0 (capacity_for filled - filled)) filled
        else
          match In_channel.input channel buffer filled (Bytes.length buffer - filled) with
          | 0 -> buffer, filled
          | read -> fill buffer (filled + read)
      in
      let length = Int64.to_int (In_channel.length channel) in
      fill
        (if Bytes.length buffer > length then buffer
         else Bytes.create (capacity_for length))
        0)
  with
  | read -> Some read
  | exception Sys_error _ -> None

let valid_utf_8 bytes ~first ~stop =
  let rec from index =
    index >= stop
    ||
    let decoded = Bytes.get_utf_8_uchar bytes index in
    let next = index + Uchar.utf_decode_length decoded in
    Uchar.utf_decode_is_valid decoded && next <= stop && from next
  in
  from first

let lexbuf_of bytes ~first ~stop =
  let next = ref first in
  Lexing.from_function (fun buffer room ->
    let length = Int.min room (stop - !next) in
    Bytes.blit bytes !next buffer 0 length;
    next := !next + length;
    length)

let offset (lexbuf : Lexing.lexbuf) = lexbuf.lex_abs_pos + lexbuf.lex_curr_pos

type spans =
  | No_rows
  | Rows of (int * int) list
  | Repeated_rows

(* The document's members with [tasks] as an empty list, and where each
   task row starts and how long it is, the last row first. *)
let take_apart bytes ~length =
  let lexbuf = lexbuf_of bytes ~first:0 ~stop:length in
  let lexer = Yojson.init_lexer () in
  let at () = offset lexbuf in
  let span spans lexer lexbuf =
    let start = at () in
    Yojson.Safe.skip_json lexer lexbuf;
    (start, at () - start) :: spans
  in
  let member (members, spans) name lexer lexbuf =
    match name, spans with
    | "tasks", No_rows when at () < length && Char.equal (Bytes.get bytes (at ())) '[' ->
        ( ("tasks", `List []) :: members,
          Rows (Yojson.Safe.read_sequence span [] lexer lexbuf) )
    | "tasks", (Rows _ | Repeated_rows) ->
        Yojson.Safe.skip_json lexer lexbuf;
        members, Repeated_rows
    | _, (No_rows | Rows _ | Repeated_rows) ->
        (name, Yojson.Safe.read_json lexer lexbuf) :: members, spans
  in
  match
    Yojson.Safe.read_space lexer lexbuf;
    let members, spans = Yojson.Safe.read_fields member ([], No_rows) lexer lexbuf in
    Yojson.Safe.read_space lexer lexbuf;
    members, spans, Yojson.Safe.read_eof lexbuf
  with
  | members, Rows spans, true -> Some (List.rev members, spans)
  | _, Rows _, false | _, (No_rows | Repeated_rows), _ -> None
  | exception
      (Yojson.Json_error _ | Yojson.End_of_array | Yojson.End_of_object
      | Yojson.End_of_input) ->
      None

(* A row's length and its first bytes, where a writer puts the task's id.
   Hashing the whole row cost a pass over the file on top of the comparison
   that has to read it anyway. FNV-1a, its 64-bit constants cut to OCaml's
   63-bit int. *)
let key_prefix_bytes = 64
let fnv_offset_basis = Int64.to_int 0xcbf29ce484222325L
let fnv_prime = 0x100000001b3

let row_key bytes ~start ~length =
  let key = ref ((fnv_offset_basis lxor length) * fnv_prime) in
  for index = start to start + Int.min length key_prefix_bytes - 1 do
    key := (!key lxor Char.code (Bytes.get bytes index)) * fnv_prime
  done;
  !key

let same_bytes left ~left_start right ~right_start ~length =
  let rec from index =
    index = length
    || Char.equal
         (Bytes.get left (left_start + index))
         (Bytes.get right (right_start + index))
       && from (index + 1)
  in
  from 0

let kept_task previous bytes ~start ~length ~key =
  match previous with
  | None -> None
  | Some previous ->
      List.find_map
        (fun row ->
          if row.length = length
             && same_bytes previous.bytes ~left_start:row.start bytes ~right_start:start
                  ~length
          then Some row.task
          else None)
        (Hashtbl.find_all previous.by_key key)

let decode_row bytes lexer ~start ~length =
  match Yojson.Safe.from_lexbuf lexer (lexbuf_of bytes ~first:start ~stop:(start + length)) with
  | json -> Result.to_option (Masc_domain.task_of_yojson json)
  | exception
      (Yojson.Json_error _ | Yojson.End_of_array | Yojson.End_of_object
      | Yojson.End_of_input) ->
      None

let decode bytes ~length ~previous =
  match take_apart bytes ~length with
  | None -> None
  | Some (members, spans) -> (
      let lexer = Yojson.init_lexer () in
      let by_key = Hashtbl.create (List.length spans) in
      let rec tasks_from decoded = function
        | [] -> Some decoded
        | (start, length) :: earlier -> (
            let key = row_key bytes ~start ~length in
            let task =
              match kept_task previous bytes ~start ~length ~key with
              | Some _ as task -> task
              | None -> decode_row bytes lexer ~start ~length
            in
            match task with
            | None -> None
            | Some task ->
                Hashtbl.add by_key key { start; length; task };
                tasks_from (task :: decoded) earlier)
      in
      match tasks_from [] spans with
      | None -> None
      | Some tasks -> (
          match Masc_domain.backlog_of_yojson (`Assoc members) with
          | Ok backlog -> Some ({ backlog with tasks }, { bytes; by_key })
          | Error _ -> None))

let read_rows spare path ~previous =
  match read_file spare path with
  | None -> None
  | Some (bytes, length) ->
      (* The full reader trims [String.trim]'s spaces before it parses. The
         lexer skips the same spaces, and on one it does not take or on a
         blank file it raises, so the full reader answers. *)
      if valid_utf_8 bytes ~first:0 ~stop:length then decode bytes ~length ~previous
      else None

(* The decode runs on the CPU pool when one is installed, as the full
   reader's does, and the stats stay on the calling fiber. *)
let read config =
  match config.Workspace_utils_backend_setup.backend with
  | Memory _ -> full_read config
  | FileSystem _ -> (
      let path = Workspace_backlog.backlog_path config in
      let taken = Atomic.exchange kept None in
      match version_of path, taken with
      | None, _ ->
          put_back taken;
          full_read config
      | Some before, Some ({ version = Some version; _ } as reading)
        when File_version_cache.same_version before version ->
          put_back taken;
          Ok reading.observation
      | Some before, (Some _ | None) -> (
          let previous, spare =
            match taken with
            | Some reading -> Some reading.rows, reading.spare
            | None -> None, Bytes.empty
          in
          match
            Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
              read_rows spare path ~previous)
          with
          | exception exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              (* A job its caller stopped waiting for may still be writing
                 into [spare], so the next read gets a buffer of its own. *)
              put_back (Option.map (fun reading -> { reading with spare = Bytes.empty }) taken);
              Printexc.raise_with_backtrace exn backtrace
          | None ->
              put_back taken;
              full_read config
          | Some (backlog, rows) ->
              let observation =
                { Workspace_backlog.observed_backlog = backlog; recovered_from = None }
              in
              let version =
                match version_of path with
                | Some after when File_version_cache.same_version before after ->
                    Some before
                | Some _ | None -> None
              in
              let spare =
                match previous with Some previous -> previous.bytes | None -> Bytes.empty
              in
              Atomic.set kept (Some { version; observation; rows; spare });
              Ok observation))
