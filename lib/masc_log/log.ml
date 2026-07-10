(* MASC Logging System - Structured logging with levels *)

(** Log levels *)
type level =
  | Debug
  | Info
  | Warn
  | Error

type source =
  | Structured
  | Legacy_stderr
  | Legacy_traceln
  | Client_tool_host

type event_class = Routine

type category =
  | Fsm
  | Lifecycle
  | Directive
  | Heartbeat
  | Presence
  | Task
  | Tool
  | Memory
  | Telemetry
  | Routine
  | Boundary
  | Uncategorized

let category_to_string : category -> string = function
  | Fsm -> "fsm"
  | Lifecycle -> "lifecycle"
  | Directive -> "directive"
  | Heartbeat -> "heartbeat"
  | Presence -> "presence"
  | Task -> "task"
  | Tool -> "tool"
  | Memory -> "memory"
  | Telemetry -> "telemetry"
  | Routine -> "routine"
  | Boundary -> "boundary"
  | Uncategorized -> "uncategorized"

let category_of_string_opt s : category option =
  match String.lowercase_ascii (String.trim s) with
  | "fsm" -> Some Fsm
  | "lifecycle" -> Some Lifecycle
  | "directive" -> Some Directive
  | "heartbeat" -> Some Heartbeat
  | "presence" -> Some Presence
  | "task" -> Some Task
  | "tool" -> Some Tool
  | "memory" -> Some Memory
  | "telemetry" -> Some Telemetry
  | "routine" -> Some Routine
  | "boundary" -> Some Boundary
  | "uncategorized" -> Some Uncategorized
  | _ -> None

(** Current log level (Atomic for thread safety in OCaml 5) *)
let current_level = Atomic.make 1 (* Info = 1 *)

(** Level to string *)
let level_to_string = function
  | Debug -> "DEBUG"
  | Info -> "INFO"
  | Warn -> "WARN"
  | Error -> "ERROR"

(** Level to int for comparison *)
let level_to_int = function
  | Debug -> 0
  | Info -> 1
  | Warn -> 2
  | Error -> 3

(** Parse level from string without a fallback.  Returns [None] when the
    input does not match any known level — callers that originate from
    user input (env vars, config files) should treat [None] as an error
    rather than silently collapsing it to a default. *)
let level_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "debug" -> Some Debug
  | "info" -> Some Info
  | "warn" | "warning" -> Some Warn
  | "error" -> Some Error
  | _ -> None

let protect ~default f =
  try f () with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> default

let source_to_string = function
  | Structured -> "structured"
  | Legacy_stderr -> "legacy_stderr"
  | Legacy_traceln -> "legacy_traceln"
  | Client_tool_host -> "client_tool_host"

let event_class_to_string : event_class -> string = function
  | Routine -> "routine"

let has_prefix ~prefix value = String.starts_with ~prefix value

(* RFC-0079: [infer_legacy_level] (a string-prefix classifier on the
   message body) was deleted along with the [?level] option on
   [legacy_stderr] / [legacy_traceln]. All callers now pass typed [~level]
   explicitly; see [Log.legacy_stderr] / [Log.legacy_traceln] below. *)

(** Check if level should be logged *)
let should_log level =
  level_to_int level >= Atomic.get current_level

(** Set log level *)
let set_level level =
  Atomic.set current_level (level_to_int level)

let routine_level_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "off" | "none" | "silent" -> Some None
  | _ -> Option.map (fun level -> Some level) (level_of_string_opt s)

let routine_level_cache : level option option Atomic.t = Atomic.make None

let routine_level () =
  match Atomic.get routine_level_cache with
  | Some level -> level
  | None ->
      let parsed =
        match Sys.getenv_opt "MASC_LOG_ROUTINE_LEVEL" with
        | None -> Some Debug
        | Some s -> (
            match routine_level_of_string_opt s with
            | Some level -> level
            | None ->
                Printf.eprintf
                  "[masc_log] WARN: MASC_LOG_ROUTINE_LEVEL=%S is not a valid level/off; defaulting to Debug\n%!"
                  s;
                Some Debug)
      in
      Atomic.set routine_level_cache (Some parsed);
      parsed

(** Set log level from string (e.g., from env var).  Emits a stderr
    warning when the input is not a recognised level, so operator
    typos (e.g. [MASC_LOG_LEVEL=debg]) surface instead of silently
    collapsing to [Info]. *)
let set_level_from_string s =
  let lvl =
    match level_of_string_opt s with
    | Some lvl -> lvl
    | None ->
      Printf.eprintf
        "[masc_log] WARN: unrecognised log level %S, defaulting to Info\n%!"
        s;
      Info
  in
  Atomic.set current_level (level_to_int lvl)

(** Initialize from MASC_LOG_LEVEL env var *)
let init_from_env () =
  match Sys.getenv_opt "MASC_LOG_LEVEL" with
  | Some s -> set_level_from_string s
  | None -> ()

(** Get current timestamp *)
let timestamp () =
  let t = Time_compat.now () in
  let tm = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(** ISO 8601 timestamp for JSON *)
let timestamp_iso () =
  let t = Time_compat.now () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(** #10392: pure helper that formats the UTC date for filename
    construction.  Both [Ring.date_string] and the yesterday/cutoff
    computations in [Ring.load_from_file] / [Ring.cleanup_old_files]
    feed through this helper so the UTC convention is pinned at a
    single site.  Exposed for unit tests that need to verify the
    KST/UTC boundary case (KST midnight = UTC 15:00) without
    depending on the host clock. *)
let format_utc_date_of (t : float) =
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

(** In-memory ring buffer for dashboard log viewer.
    Fixed capacity, oldest entries evicted on overflow.
    Lock-free: single-writer (log functions), multi-reader (API).
    Optional file sink persists entries across restarts. *)
module Ring = struct
  (* RFC-0079: [entry] is the typed record produced by the write-side encoder.
     [level] and [source] are typed closed sums — see [type level] / [type
     source] at the top of this module. Wire format (the JSON emitted by
     [entry_to_json]) renders them as their canonical strings; the dashboard
     reads those strings back. Decode failures raise — silent skipping of
     malformed rows is gone, which is the F1 / RFC-0079 root-fix. *)
  type entry = {
    seq : int;
    ts : string;
    level : level;
    source : source;
    module_name : string;
    keeper_name : string option;
    turn_id : int option;
    message : string;
    details : Yojson.Safe.t;
    category : category option;
  }

  (* Dashboard operators commonly inspect tool-call history over hours, not
     minutes.  5k entries was too small for high-volume keeper/MCP traffic and
     made recent MCP calls appear to disappear despite JSONL persistence. *)
  let capacity = 50000
  let buf : entry array = Array.make capacity
    {
      seq = 0;
      ts = "";
      level = Info;
      source = Structured;
      module_name = "";
      keeper_name = None;
      turn_id = None;
      message = "";
      details = `Null;
      category = None;
    }
  let total = Atomic.make 0 (* total entries ever written *)

  (* File sink state *)
  let file_channel : out_channel option ref = ref None
  let file_current_date : string ref = ref ""
  let file_base_dir : string ref = ref ""

  let date_string () = format_utc_date_of (Time_compat.now ())

  let log_file_path dir date =
    Filename.concat dir (Printf.sprintf "system_log_%s.jsonl" date)

  let ensure_dir dir =
    if not (Sys.file_exists dir) then
      protect ~default:() (fun () -> Sys.mkdir dir 0o755)

  let close_sink () =
    match !file_channel with
    | Some oc ->
        close_out_noerr oc;
        file_channel := None
    | None -> ()

  let open_sink dir =
    ensure_dir dir;
    let date = date_string () in
    let path = log_file_path dir date in
    let oc = open_out_gen [Open_append; Open_creat; Open_wronly] 0o644 path in
    file_channel := Some oc;
    file_current_date := date;
    file_base_dir := dir

  (* Atomic rotate: open the new sink first, swap only on success. The
     previous [close_sink (); open_sink ()] pair left [file_channel := None]
     if [open_out_gen] raised (e.g. EMFILE, transient FS race), and never
     re-attempted; the file-channel stayed [None] for the rest of the
     process's life and every subsequent emit silently fell through the
     [None] arm of [write_to_sink]. Observed on 2026-05-25 (rotation-time
     stop after 18h) and 2026-05-29 (25 min after midnight UTC rotation):
     [system_log_*.jsonl] ended at [00:25:09Z] while [/private/tmp/masc-server.log]
     continued for hours from the same process. Atomic swap + a no-throw
     [protect] guard turns an [open_out_gen] failure into a logged warning
     plus retained old channel, instead of permanent silent loss. *)
  let try_open_channel dir =
    ensure_dir dir;
    let date = date_string () in
    let path = log_file_path dir date in
    protect ~default:None (fun () ->
      Some
        ( open_out_gen [Open_append; Open_creat; Open_wronly] 0o644 path
        , date ))

  (* RFC-0079: typed encoder. Exhaustive match on [level] / [source] means
     adding a new variant fails to compile here until the wire format is
     extended deliberately. The wire shape (field set + key order) is the
     [LogEntryRawSchema] contract in [dashboard/src/api/schemas/logs.ts]. *)
  let entry_to_json e =
    let keeper_name_json = match e.keeper_name with
      | Some s -> `String s
      | None -> `String "system"
    in
    let turn_id_json = match e.turn_id with
      | Some i -> `Int i
      | None -> `Null
    in
    let category_json = match e.category with
      | Some c -> `String (category_to_string c)
      | None -> `Null
    in
    `Assoc [
      ("seq", `Int e.seq);
      ("ts", `String e.ts);
      ("level", `String (level_to_string e.level));
      ("source", `String (source_to_string e.source));
      ("module", `String e.module_name);
      ("keeper_name", keeper_name_json);
      ("turn_id", turn_id_json);
      ("message", `String e.message);
      ("details", e.details);
      ("category", category_json);
    ]

  let sink_matches_path path oc =
    protect ~default:false (fun () ->
      if not (Sys.file_exists path) then
        false
      else
        let path_stat = Unix.stat path in
        let chan_stat = Unix.fstat (Unix.descr_of_out_channel oc) in
        path_stat.st_dev = chan_stat.st_dev && path_stat.st_ino = chan_stat.st_ino)

  let rotate_if_needed () =
    let today = date_string () in
    if !file_base_dir <> "" then begin
      let needs_reopen =
        match !file_channel with
        | Some oc ->
            today <> !file_current_date
            || not (sink_matches_path (log_file_path !file_base_dir today) oc)
        | None -> true
      in
      if needs_reopen then begin
        match try_open_channel !file_base_dir with
        | Some (new_oc, date) ->
            (match !file_channel with
             | Some old_oc -> close_out_noerr old_oc
             | None -> ());
            file_channel := Some new_oc;
            file_current_date := date
        | None ->
            (* open_out_gen raised. Keep the existing channel (if any)
               so emits continue landing in the previous day's file
               until the next rotation attempt succeeds. *)
            Printf.eprintf
              "[%s] [WARN] [Log] file-sink rotate failed (target %s); \
               retaining previous channel\n%!"
              (timestamp ())
              (log_file_path !file_base_dir today)
      end
    end

  (* RFC-0108: serialize the JSONL append under a single mutex
     critical section so concurrent fibers (or domains) cannot
     interleave bytes from different records.  Pre-fix, the three-
     call sequence [output_string oc json; output_char oc '\n';
     flush oc] left a race window between the JSON and the newline —
     observed on 2026-05-17 as ["}{"]-concat lines in
     [.masc/logs/system_log_2026-05-17.jsonl:3498] and [:4635].

     [Stdlib.Mutex] is sufficient here because [Ring.init_file_sink]
     runs before [Eio_main.run] (see [bin/main_eio.ml]); the writer
     therefore cannot assume an Eio scheduler is available and must
     work from non-Eio contexts (e.g. [at_exit]).  The mutex protects
     the single global [file_channel], so one lock covers the whole
     write path. Building the [json + "\n"] payload as a single
     string before [output_string] also keeps the kernel-visible
     write boundary at record granularity (the channel buffer is
     flushed once per record).

     [rotate_if_needed] runs outside the mutex on purpose — it only
     mutates [file_channel] when the date rolls, and recursing into
     the mutex there would deadlock.  Reading [!file_channel] inside
     the lock means a rotate racing with a write sees whichever
     channel is current; the worst case is one record on the
     about-to-rotate channel, which is harmless. *)
  let sink_mutex = Stdlib.Mutex.create ()

  let write_to_sink entry_json =
    rotate_if_needed ();
    Stdlib.Mutex.protect sink_mutex
      (fun () ->
        (* Self-heal: if a prior rotate left [file_channel = None]
           (open failure) but the base dir is still configured, try
           to reopen now. Bounded: at most one attempt per write, no
           backoff loop. Failure is silent here because [rotate_if_needed]
           already emitted the WARN; logging again per emit would spam. *)
        if !file_channel = None && !file_base_dir <> "" then begin
          match try_open_channel !file_base_dir with
          | Some (oc, date) ->
              file_channel := Some oc;
              file_current_date := date
          | None -> ()
        end;
        match !file_channel with
        | Some oc ->
            let line = Yojson.Safe.to_string entry_json ^ "\n" in
            (try output_string oc line
             with exn ->
               Printf.eprintf
                 "[%s] [ERROR] [Log] file-sink write failed: %s; \
                  dropping channel for next-emit re-open\n%!"
                 (timestamp ())
                 (Printexc.to_string exn);
               close_sink ());
            protect ~default:() (fun () -> flush oc)
        | None -> ())

  exception Entry_decode_error of string

  (* RFC-0079: explicit source decoder. New source variants must be added
     here AND in [source_to_string] — adjacent functions are colocated so a
     drift between encoder and decoder is visible to the reviewer. *)
  let source_of_string = function
    | "structured" -> Structured
    | "legacy_stderr" -> Legacy_stderr
    | "legacy_traceln" -> Legacy_traceln
    | "client_tool_host" -> Client_tool_host
    | s -> raise (Entry_decode_error (Printf.sprintf "unknown source: %S" s))

  (* RFC-0079: total decoder. Missing required fields or unknown variants
     raise [Entry_decode_error] instead of returning [None]. Callers that
     reload historical JSONL ([load_from_file]) decide whether to skip a
     bad line at the file-fold boundary; the decoder itself never silently
     drops. *)
  let entry_of_json json =
    let require_string field =
      match Yojson.Safe.Util.member field json with
      | `String s -> s
      | `Null ->
          raise (Entry_decode_error (Printf.sprintf "missing field: %s" field))
      | other ->
          raise
            (Entry_decode_error
               (Printf.sprintf "field %s: expected string, got %s" field
                  (Yojson.Safe.to_string other)))
    in
    let require_int field =
      match Yojson.Safe.Util.member field json with
      | `Int i -> i
      | `Null ->
          raise (Entry_decode_error (Printf.sprintf "missing field: %s" field))
      | other ->
          raise
            (Entry_decode_error
               (Printf.sprintf "field %s: expected int, got %s" field
                  (Yojson.Safe.to_string other)))
    in
    match json with
    | `Assoc _ ->
        let seq = require_int "seq" in
        let ts = require_string "ts" in
        let level =
          match level_of_string_opt (require_string "level") with
          | Some l -> l
          | None ->
              raise
                (Entry_decode_error
                   (Printf.sprintf "unknown level: %S" (require_string "level")))
        in
        let source = source_of_string (require_string "source") in
        let module_name = require_string "module" in
        let message = require_string "message" in
        let keeper_name =
          match Yojson.Safe.Util.member "keeper_name" json with
          | `String s -> Some s
          | `Null -> None
          | other ->
              raise
                (Entry_decode_error
                   (Printf.sprintf "field keeper_name: expected string or null, got %s"
                      (Yojson.Safe.to_string other)))
        in
        let turn_id =
          match Yojson.Safe.Util.member "turn_id" json with
          | `Int i -> Some i
          | `Null -> None
          | other ->
              raise
                (Entry_decode_error
                   (Printf.sprintf "field turn_id: expected int or null, got %s"
                      (Yojson.Safe.to_string other)))
        in
        let category =
          match Yojson.Safe.Util.member "category" json with
          | `String s -> category_of_string_opt s
          | _ -> None
        in
        {
          seq; ts; level; source; module_name;
          keeper_name; turn_id; message;
          details = Yojson.Safe.Util.member "details" json;
          category;
        }
    | _ ->
        raise
          (Entry_decode_error
             (Printf.sprintf "expected JSON object, got %s"
                (Yojson.Safe.to_string json)))

  let load_from_file dir =
    ensure_dir dir;
    let today = date_string () in
    (* Load today's and yesterday's logs *)
    (* #10392: yesterday's filename uses the same UTC convention as
       [date_string] so [load_from_file] re-reads what was actually
       written.  Pre-fix this used [Unix.localtime] which on KST hosts
       loaded a file 9 hours skewed from the today computation. *)
    let yesterday = format_utc_date_of (Time_compat.now () -. 86400.0) in
    (* Drive the fold into a bounded [Queue.t] sized to [capacity].
       Each new entry pushes onto the tail; if the queue overflows
       past [capacity] we drop the head (oldest seen).  Combined with
       the yesterday-then-today fold order this keeps the last
       [capacity] entries across both files in O(capacity) live
       memory — the previous accumulator built an unbounded
       per-file list and only trimmed *after* concatenation, so a
       full daily log allocated O(line_count) entry records on
       boot even when [capacity] was much smaller.

       [Fs_compat.fold_jsonl_lines] also gives us non-blocking IO
       under Eio, max-line-size enforcement via the [~max_size:16 MiB]
       cap on [Eio.Buf_read.of_flow] (which [Buf_read.lines] then
       streams under), and consistent malformed-line handling (stderr
       warning + skip) in place of the prior silent drop on
       [Yojson.Json_error]. *)
    let buf_ring : entry Queue.t = Queue.create () in
    let push_file path =
      Fs_compat.fold_jsonl_lines
        ~init:()
        ~f:(fun () ~line_no json ->
          (* RFC-0079: file-fold is the one boundary that tolerates legacy
             rows written before the typed encoder. Older JSONL files (with
             [raw_level] / [normalized_level] / [legacy_classified]) fail
             [entry_of_json] because their schema is gone; the cleanup_old
             rotation deletes them within [keep_days], so the WARN here is
             load-bearing only during that window. Anywhere else, a decode
             error propagates as [Entry_decode_error]. *)
          match entry_of_json json with
          | exception Entry_decode_error msg ->
              Printf.eprintf
                "[%s] [WARN] [Log] skip legacy/malformed JSONL row %s:%d: %s\n%!"
                (timestamp ()) path line_no msg
          | e ->
            Queue.add e buf_ring;
            if Queue.length buf_ring > capacity then ignore (Queue.pop buf_ring))
        path
    in
    push_file (log_file_path dir yesterday);
    push_file (log_file_path dir today);
    Queue.iter
      (fun e ->
        let seq = Atomic.fetch_and_add total 1 in
        let idx = seq mod capacity in
        buf.(idx) <- { e with seq })
      buf_ring

  let init_file_sink dir =
    close_sink ();
    load_from_file dir;
    let loaded = Atomic.get total in
    open_sink dir;
    if loaded > 0 then
      Printf.eprintf "[%s] [INFO] [Log] Restored %d log entries from disk\n%!" (timestamp ()) loaded

  let cleanup_old_files ?(keep_days = 7) dir =
    if Sys.file_exists dir then begin
      let files = protect ~default:[||] (fun () -> Sys.readdir dir) in
      (* #10392: cutoff date uses UTC because [date_string] now writes
         filenames in UTC.  Mixed timezones here would cause [keep_days]
         retention to be off by ~1 day at the KST/UTC boundary and
         occasionally delete a file that is still within retention. *)
      let cutoff =
        format_utc_date_of
          (Time_compat.now () -. (float_of_int keep_days *. 86400.0))
      in
      Array.iter (fun fname ->
        if has_prefix ~prefix:"system_log_" fname
           && Filename.check_suffix fname ".jsonl" then begin
          (* Extract date from system_log_YYYY-MM-DD.jsonl *)
          let date_part = String.sub fname 11 10 in
          if date_part < cutoff then
            protect ~default:() (fun () -> Sys.remove (Filename.concat dir fname))
        end
      ) files
    end

  (* RFC-0079: typed [push]. [~level] and [?source] are typed values, not
     strings. Legacy options [?raw_level] / [~normalized_level] /
     [?legacy_classified] are gone — they only existed to carry the
     pre-typed mirror state through the wire. *)
  let push
      ?(source = Structured)
      ?(details = `Null)
      ?keeper_name
      ?turn_id
      ?category
      ~level
      ~module_name
      ~message
      () =
    let seq = Atomic.fetch_and_add total 1 in
    let idx = seq mod capacity in
    let entry = {
        seq;
        ts = timestamp_iso ();
        level;
        source;
        module_name;
        keeper_name;
        turn_id;
        message;
        details;
        category;
      } in
    buf.(idx) <- entry;
    if !file_channel <> None then
      write_to_sink (entry_to_json entry)

  let recent ?(limit = 200) ?(min_level = 0) ?(module_filter = "")
      ?since_seq
      ?before_seq
      ?(order = `Newest_first)
      ?category_filter
      ?exclude_category
      () : entry list =
    let t = Atomic.get total in
    if t = 0 then []
    else begin
      let start = max 0 (t - capacity) in
      (* [since_seq] raises the lower bound (entries strictly newer than the
         cursor); [before_seq] lowers the upper bound (entries strictly older
         than the cursor). For retained slots in [start, t-1] the entry seq
         equals its scan index [i] (seq is assigned monotonically and the ring
         only retains the last [capacity] entries), so seq comparisons reduce
         to index bounds. The two cursors compose into a bounded window. *)
      let start =
        match since_seq with
        | Some seq -> max start (seq + 1)
        | None -> start
      in
      let upper =
        match before_seq with
        | Some seq -> min (t - 1) (seq - 1)
        | None -> t - 1
      in
      let entries = ref [] in
      let count = ref 0 in
      let i = ref upper in
      while !i >= start && !count < limit do
        let e = buf.(!i mod capacity) in
        let level_ok = level_to_int e.level >= min_level in
        let module_ok = module_filter = "" ||
          String.lowercase_ascii e.module_name =
          String.lowercase_ascii module_filter in
        let category_ok =
          match category_filter with
          | None -> true
          | Some filter ->
              let filter_lower = String.lowercase_ascii filter in
              if String.equal filter_lower "uncategorized" then
                Option.is_none e.category
              else
                match e.category with
                | Some c -> String.equal (category_to_string c) filter_lower
                | None -> false
        in
        let exclude_ok =
          match exclude_category with
          | None -> true
          | Some cats ->
              match e.category with
              | None -> true
              | Some c ->
                  let c_lower = String.lowercase_ascii (category_to_string c) in
                  not (List.exists (fun ex ->
                    String.equal c_lower (String.lowercase_ascii ex)) cats)
        in
        if level_ok && module_ok && category_ok && exclude_ok then begin
          entries := e :: !entries;
          incr count
        end;
        decr i
      done;
      (* Prepend builds oldest-first; reverse for newest-first *)
      match order with
      | `Oldest_first -> !entries
      | `Newest_first -> List.rev !entries
    end

  let to_json entries =
    `Assoc [
      ("total", `Int (Atomic.get total));
      ("entries", `List (List.map entry_to_json entries));
    ]

  let latest_metadata_json = function
    | None -> `Null
    | Some e ->
        `Assoc
          [
            ("seq", `Int e.seq);
            ("ts", `String e.ts);
            ("level", `String (level_to_string e.level));
            ("source", `String (source_to_string e.source));
            ("module", `String e.module_name);
            ( "keeper_name",
              (match e.keeper_name with
              | Some name -> `String name
              | None -> `String "system") );
            ( "turn_id",
              (match e.turn_id with
              | Some turn_id -> `Int turn_id
              | None -> `Null) );
          ]

  let summary_json () =
    let total_entries = Atomic.get total in
    let retained_entries = min total_entries capacity in
    let recent_window = recent ~limit:200 () in
    let recent_errors =
      List.fold_left
        (fun count e -> if e.level = Error then count + 1 else count)
        0 recent_window
    in
    let recent_warnings =
      List.fold_left
        (fun count e -> if e.level = Warn then count + 1 else count)
        0 recent_window
    in
    let file_sink_dir =
      if String.equal !file_base_dir "" then `Null else `String !file_base_dir
    in
    let latest =
      match recent_window with
      | latest :: _ -> Some latest
      | [] -> None
    in
    `Assoc
      [
        ("status", `String (if total_entries = 0 then "empty" else "active"));
        ("capacity", `Int capacity);
        ("total_entries", `Int total_entries);
        ("retained_entries", `Int retained_entries);
        ("recent_window", `Int (List.length recent_window));
        ("recent_errors", `Int recent_errors);
        ("recent_warnings", `Int recent_warnings);
        ("latest", latest_metadata_json latest);
        ( "file_sink",
          `Assoc
            [
              ("enabled", `Bool (!file_channel <> None));
              ("dir", file_sink_dir);
              ( "current_date",
                if String.equal !file_current_date "" then `Null
                else `String !file_current_date );
            ] );
      ]
end

(** Log a message at given level with optional context *)
let log level ?(ctx : string option) ?category fmt =
  Printf.ksprintf (fun msg ->
    if should_log level then begin
      let level_str = level_to_string level in
      let module_name = match ctx with Some c -> c | None -> "" in
      let prefix = match ctx with
        | Some c -> Printf.sprintf "[%s] [%s] [%s]" (timestamp ()) level_str c
        | None -> Printf.sprintf "[%s] [%s]" (timestamp ()) level_str
      in
      Console_sink.write (prefix ^ " " ^ msg);
      Ring.push ~level ~module_name ~message:msg ?category ()
    end
  ) fmt

let emit level ?(module_name = "") ?(details = `Null) ?category message =
  if should_log level then begin
    let level_str = level_to_string level in
    let prefix =
      if module_name = "" then
        Printf.sprintf "[%s] [%s]" (timestamp ()) level_str
      else
        Printf.sprintf "[%s] [%s] [%s]" (timestamp ()) level_str module_name
    in
    Console_sink.write (prefix ^ " " ^ message);
    Ring.push ~level ~module_name ~message ~details ?category ()
  end

let details_with_event_class event_class details =
  let event_class_field =
    ("event_class", `String (event_class_to_string event_class))
  in
  match details with
  | `Null -> `Assoc [ event_class_field ]
  | `Assoc fields ->
      let fields =
        List.filter (fun (key, _) -> not (String.equal key "event_class")) fields
      in
      `Assoc (event_class_field :: fields)
  | payload -> `Assoc [ event_class_field; ("payload", payload) ]

let emit_event event_class level ?module_name ?(details = `Null) ?category message =
  emit level ?module_name ~details:(details_with_event_class event_class details)
    ?category message

let emit_routine ?module_name ?(details = `Null) ?category message =
  match routine_level () with
  | None -> ()
  | Some level -> emit_event Routine level ?module_name ~details ?category message

(** Convenience functions *)
let debug ?ctx ?category fmt = log Debug ?ctx ?category fmt
let info ?ctx ?category fmt = log Info ?ctx ?category fmt
let warn ?ctx ?category fmt = log Warn ?ctx ?category fmt
let error ?ctx ?category fmt = log Error ?ctx ?category fmt

(* RFC-0079: [~level] is now required for the mirror functions. The old
   [?level] option backed [infer_legacy_level], a string-prefix classifier
   over the message body — every existing caller already passed
   [~level:Log.Error/Warn/Debug] explicitly, so the option was dead code
   masquerading as flexibility. *)
let emit_legacy_raw ~level ?(module_name = "") ~source message =
  Console_sink.write message;
  Ring.push ~level ~source ~module_name ~message ()

let legacy_stderr ~level ?module_name message =
  emit_legacy_raw ~level ?module_name ~source:Legacy_stderr message

let legacy_traceln ~level ?module_name message =
  emit_legacy_raw ~level ?module_name ~source:Legacy_traceln message

let client_tool_host_error ?(module_name = "ToolHost") ?(details = `Null) message =
  Console_sink.write message;
  Ring.push ~level:Error ~source:Client_tool_host
    ~module_name ~message ~details ()

module type LOGGER = sig
  val emit :
    level ->
    ?details:Yojson.Safe.t ->
    ?keeper_name:string ->
    ?turn_id:int ->
    ?category:category ->
    string ->
    unit

  val routine :
    ?details:Yojson.Safe.t ->
    ?keeper_name:string ->
    ?turn_id:int ->
    ?category:category ->
    ('a, unit, string, unit) format4 ->
    'a

  val debug :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a

  val info :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a

  val warn :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a

  val warning :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a

  val error :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ('a, unit, string, unit) format4 -> 'a
end

(** Module-specific loggers.
    Each module checks MASC_LOG_{NAME}_LEVEL env var for per-module override,
    falling back to the global level. *)
module Make (M : sig val name : string end) = struct
  let module_level : int option =
    let env_key = Printf.sprintf "MASC_LOG_%s_LEVEL"
      (String.uppercase_ascii M.name) in
    match Sys.getenv_opt env_key with
    | None -> None
    | Some s ->
      match level_of_string_opt s with
      | Some lvl -> Some (level_to_int lvl)
      | None ->
        Printf.eprintf
          "[masc_log] WARN: %s=%S is not a valid level; ignoring override\n%!"
          env_key s;
        None

  let should_log_module level =
    let threshold = match module_level with
      | Some l -> l
      | None -> Atomic.get current_level
    in
    level_to_int level >= threshold

  let emit level ?(details = `Null) ?keeper_name ?turn_id ?category message =
    if should_log_module level then begin
      let level_str = level_to_string level in
      let prefix = match keeper_name with
        | Some kn ->
            Printf.sprintf "[%s] [%s] [%s/%s]"
              (timestamp ()) level_str M.name kn
        | None ->
            Printf.sprintf "[%s] [%s] [%s]"
              (timestamp ()) level_str M.name
      in
      Console_sink.write (prefix ^ " " ^ message);
      Ring.push ?keeper_name ?turn_id ?category
        ~level ~module_name:M.name ~message ~details ()
    end

  let log_module level ?keeper_name ?turn_id ?category fmt =
    Printf.ksprintf (fun msg -> emit level ?keeper_name ?turn_id ?category msg) fmt

  let routine ?(details = `Null) ?keeper_name ?turn_id ?category fmt =
    Printf.ksprintf
      (fun msg ->
         match routine_level () with
         | None -> ()
         | Some level ->
             emit level ~details:(details_with_event_class Routine details)
               ?keeper_name ?turn_id ?category msg)
      fmt

  let debug ?keeper_name ?turn_id ?category fmt = log_module Debug ?keeper_name ?turn_id ?category fmt
  let info ?keeper_name ?turn_id ?category fmt = log_module Info ?keeper_name ?turn_id ?category fmt
  let warn ?keeper_name ?turn_id ?category fmt = log_module Warn ?keeper_name ?turn_id ?category fmt
  let warning = warn
  let error ?keeper_name ?turn_id ?category fmt = log_module Error ?keeper_name ?turn_id ?category fmt
end

(** Pre-defined module loggers *)
module Workspace = Make(struct let name = "Workspace" end)
module Mcp = Make(struct let name = "MCP" end)
module Auth = Make(struct let name = "Auth" end)
module Retry = Make(struct let name = "Retry" end)
module Backend = Make(struct let name = "Backend" end)
module Session = Make(struct let name = "Session" end)
module Cancel = Make(struct let name = "Cancellation" end)
module Sub = Make(struct let name = "Subscriptions" end)
module Spawn = Make(struct let name = "Spawn" end)
module Pulse = Make(struct let name = "Pulse" end)
module ModelClient = Make(struct let name = "ModelClient" end)
module Orchestrator = Make(struct let name = "Orchestrator" end)
module BoardLog = Make(struct let name = "Board" end)
module Metrics = Make(struct let name = "Metrics" end)
module Dashboard = Make(struct let name = "Dashboard" end)
module Trpg = Make(struct let name = "Trpg" end)
module Feed = Make(struct let name = "Feed" end)
module Telemetry = Make(struct let name = "Telemetry" end)
module Noosphere = Make(struct let name = "Noosphere" end)
module CmdPlane = Make(struct let name = "CmdPlane" end)
module Governance = Make(struct let name = "Governance" end)
module Social = Make(struct let name = "Social" end)
module Transport = Make(struct let name = "Transport" end)
module Gc = Make(struct let name = "GC" end)
module Reputation = Make(struct let name = "Reputation" end)
module Keeper = Make(struct let name = "Keeper" end)
(* RFC-0058 Phase 8.1.5: dedicated runtime namespace so partial-catalog
   warnings and other runtime-domain events route through a stable
   channel that alerting/dashboard filters can target without false
   positives from the Keeper namespace. *)
module Runtime = Make(struct let name = "Runtime" end)
module Memory = Make(struct let name = "Memory" end)
module Mention = Make(struct let name = "Mention" end)
module Misc = Make(struct let name = "Misc" end)
module Identity = Make(struct let name = "Identity" end)
module Institution = Make(struct let name = "Institution" end)
module Pages = Make(struct let name = "Pages" end)
module Thompson = Make(struct let name = "Thompson" end)
module Config = Make(struct let name = "Config" end)
module Task = Make(struct let name = "Task" end)
module Http = Make(struct let name = "Http" end)
module Langfuse = Make(struct let name = "Langfuse" end)
module Server = Make(struct let name = "Server" end)
module Dispatch = Make(struct let name = "Dispatch" end)
module BoardPg = Make(struct let name = "BoardPg" end)
module MemoryPg = Make(struct let name = "MemoryPg" end)
module MemoryJsonl = Make(struct let name = "MemoryJsonl" end)
module AutoResponder = Make(struct let name = "AutoResponder" end)
module Env = Make(struct let name = "Env" end)
module Level2 = Make(struct let name = "Level2" end)
module TaskState = Make(struct let name = "TaskState" end)
module Inline = Make(struct let name = "Inline" end)
module Protocol = Make(struct let name = "Protocol" end)
module AlwaysOn = Make(struct let name = "AlwaysOn" end)
module KeeperExec = Make(struct let name = "KeeperExec" end)
module LocalWorker = Make(struct let name = "LocalWorker" end)
module Worker = Make(struct let name = "Worker" end)
module Sse = Make(struct let name = "SSE" end)
module Verifier = Make(struct let name = "Verifier" end)
module Planner = Make(struct let name = "Planner" end)
module Compact = Make(struct let name = "Compact" end)
module Harness = Make(struct let name = "Harness" end)
module Discovery = Make(struct let name = "Discovery" end)

(* Logging-consistency migration (refactor/logging-consistency-harness):
   modules added so that former top-level [Log.info ~ctx:"<name>"] call sites
   route through a dedicated per-module logger while preserving the exact
   component string operators see in [ts] [LEVEL] [<name>] output. The [name]
   string is the original [~ctx] value verbatim; the module identifier is its
   Capitalized form. See docs/LOGGING.md. *)
module Otel = Make(struct let name = "otel" end)
module Agent_health = Make(struct let name = "agent_health" end)
module Relay = Make(struct let name = "relay" end)
module Runtime_verify = Make(struct let name = "runtime_verify" end)
module Checkpoint = Make(struct let name = "checkpoint" end)
module Jsonl_atomic = Make(struct let name = "jsonl_atomic" end)
module Mcp_transport = Make(struct let name = "mcp_transport" end)
module Startup = Make(struct let name = "startup" end)
module Model_inference_metrics = Make(struct let name = "model_inference_metrics" end)
module Oas_worker_exec = Make(struct let name = "oas_worker_exec" end)
module Oas_event = Make(struct let name = "oas:event" end)
module H2_gateway = Make(struct let name = "h2_gateway" end)

(* Modules added for former raw-stderr / [Logs.*] server-runtime call sites
   that carried no [~ctx]. Domain-named (no prior component string to
   preserve); the migration adds a single [ts] [LEVEL] [<name>] prefix where
   there was previously none. *)
module Voice = Make(struct let name = "Voice" end)
module Exec_tap = Make(struct let name = "ExecTap" end)
module Tool_validation = Make(struct let name = "ToolValidation" end)
module Discord = Make(struct let name = "Discord" end)
module Slack = Make(struct let name = "Slack" end)
