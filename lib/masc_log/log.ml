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
  | Tool
  | Routine
  | Boundary
  | Turn
  | Broadcast

let category_to_string : category -> string = function
  | Fsm -> "fsm"
  | Lifecycle -> "lifecycle"
  | Directive -> "directive"
  | Heartbeat -> "heartbeat"
  | Tool -> "tool"
  | Routine -> "routine"
  | Boundary -> "boundary"
  | Turn -> "turn"
  | Broadcast -> "broadcast"

let category_of_string_opt s : category option =
  match String.lowercase_ascii (String.trim s) with
  | "fsm" -> Some Fsm
  | "lifecycle" -> Some Lifecycle
  | "directive" -> Some Directive
  | "heartbeat" -> Some Heartbeat
  | "tool" -> Some Tool
  | "routine" -> Some Routine
  | "boundary" -> Some Boundary
  | "turn" -> Some Turn
  | "broadcast" -> Some Broadcast
  | _ -> None

(** A closed diagnostic classification for the few entries a dashboard
    projection re-reads by meaning instead of by log wording. Kept in
    memory only: the JSONL sink and the dashboard wire schema
    (LogEntryRawSchema) are untouched, so rows restored from disk carry
    no kind and are classified once at the load boundary. *)
type diagnostic_kind =
  | External_signal of string  (* "SIGTERM" | "SIGINT" — set by the server signal handler *)
  | Agent_decode_failure       (* an agent record failed to decode (workspace / gRPC paths) *)

type category_selector =
  | Category of category
  | Uncategorized

let category_selector_to_string = function
  | Category category -> category_to_string category
  | Uncategorized -> "uncategorized"

let category_selector_of_string_opt s =
  match String.lowercase_ascii (String.trim s) with
  | "uncategorized" -> Some Uncategorized
  | name -> Option.map (fun category -> Category category) (category_of_string_opt name)

let selects selector (category : category option) =
  match selector, category with
  | Uncategorized, None -> true
  | Category wanted, Some actual -> wanted = actual
  | Uncategorized, Some _ | Category _, None -> false

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

let format_localtime tm =
  let year = tm.Unix.tm_year + 1900 in
  if year >= 0 && year <= 9999 then begin
    let buf = Bytes.create 19 in
    let yq = year / 100 in
    let yr = year - (yq * 100) in
    Bytes.unsafe_set buf 0 (Char.unsafe_chr (48 + (yq / 10)));
    Bytes.unsafe_set buf 1 (Char.unsafe_chr (48 + (yq mod 10)));
    Bytes.unsafe_set buf 2 (Char.unsafe_chr (48 + (yr / 10)));
    Bytes.unsafe_set buf 3 (Char.unsafe_chr (48 + (yr mod 10)));
    Bytes.unsafe_set buf 4 '-';
    let mon = tm.Unix.tm_mon + 1 in
    Bytes.unsafe_set buf 5 (Char.unsafe_chr (48 + (mon / 10)));
    Bytes.unsafe_set buf 6 (Char.unsafe_chr (48 + (mon mod 10)));
    Bytes.unsafe_set buf 7 '-';
    let day = tm.Unix.tm_mday in
    Bytes.unsafe_set buf 8 (Char.unsafe_chr (48 + (day / 10)));
    Bytes.unsafe_set buf 9 (Char.unsafe_chr (48 + (day mod 10)));
    Bytes.unsafe_set buf 10 ' ';
    let hour = tm.Unix.tm_hour in
    Bytes.unsafe_set buf 11 (Char.unsafe_chr (48 + (hour / 10)));
    Bytes.unsafe_set buf 12 (Char.unsafe_chr (48 + (hour mod 10)));
    Bytes.unsafe_set buf 13 ':';
    let min = tm.Unix.tm_min in
    Bytes.unsafe_set buf 14 (Char.unsafe_chr (48 + (min / 10)));
    Bytes.unsafe_set buf 15 (Char.unsafe_chr (48 + (min mod 10)));
    Bytes.unsafe_set buf 16 ':';
    let sec = tm.Unix.tm_sec in
    Bytes.unsafe_set buf 17 (Char.unsafe_chr (48 + (sec / 10)));
    Bytes.unsafe_set buf 18 (Char.unsafe_chr (48 + (sec mod 10)));
    Bytes.unsafe_to_string buf
  end else
    Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
      year
      (tm.Unix.tm_mon + 1)
      tm.Unix.tm_mday
      tm.Unix.tm_hour
      tm.Unix.tm_min
      tm.Unix.tm_sec
;;

(** Get current timestamp *)
let timestamp () =
  let t = Time_compat.now () in
  let tm = Unix.localtime t in
  format_localtime tm
;;

(** ISO 8601 timestamp for JSON *)
let timestamp_iso () = Time_codec.rfc3339_of_unix (Time_compat.now ())

(** #10392: pure helper that formats the UTC date for filename
    construction.  Both [Ring.date_string] and the yesterday/cutoff
    computations in [Ring.load_from_file] / [Ring.cleanup_old_files]
    feed through this helper so the UTC convention is pinned at a
    single site.  Exposed for unit tests that need to verify the
    KST/UTC boundary case (KST midnight = UTC 15:00) without
    depending on the host clock. *)
(* The ring's date files sit in the same YYYY-MM/DD.jsonl layout every other
   .masc store uses, and [Jsonl_writer.utc_calendar_day] picks the day.
   Rebuilding the key here meant the reader could drift from the writer that
   named the file; [day_key] is the writer's own key (#27143). *)
let format_utc_date_of (t : float) = Jsonl_writer.day_key ~ts:t

(* A log line is read by people and by models, and both pay per token. A field
   the producer did not measure carries no fact, so it is left out rather than
   rendered as a placeholder: [cache_n=-] on every turn of a lane that never
   reports a cache says nothing that its absence does not (2026-09-09). [false]
   and [0] are values, not absences, and are rendered. Only the message text is
   shaped here; the ring entry's typed fields are untouched. *)
module Kv = struct
  type field = string * string option

  let str key value : field = key, Some value
  let int key value : field = key, Some (string_of_int value)
  let bool key value : field = key, Some (string_of_bool value)
  let opt key value : field = key, value
  let opt_map key render value : field = key, Option.map render value

  let render (fields : field list) =
    fields
    |> List.filter_map (fun (key, value) ->
         Option.map (fun value -> key ^ "=" ^ value) value)
    |> String.concat " "
end

(** In-memory ring buffer for dashboard log viewer.
    Fixed capacity, oldest entries evicted on overflow.
    Writers on any domain or systhread take [ring_mutex] to install an
    entry; readers (API) take no lock.
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
    diagnostic_kind : diagnostic_kind option;
  }

  (** Live-window bounds of the ring: sequences in
      [[start_seq, total)] are answerable; anything below [start_seq]
      has been evicted ([dropped_before]) and lives only in the daily
      JSONL sink. *)
  type bounds = {
    start_seq : int;
    total : int;
    dropped_before : bool;
  }

  type entry_change = {entry : entry; overwritten : entry option}
  type publication_listener = {published : entry_change -> unit}
  let publication_listeners : publication_listener list Atomic.t = Atomic.make []
  let publication_notification_failures = Atomic.make 0

  let subscribe_published published =
    let listener = {published} in
    Lockfree_atomic.update publication_listeners (fun listeners -> listener :: listeners);
    fun () -> Lockfree_atomic.update publication_listeners
      (List.filter (fun current -> current != listener))

  let failed_publication_notifications () = Atomic.get publication_notification_failures

  let notify_published change =
    List.iter (fun listener ->
      try listener.published change with
      (* cancel-guard-ok: observers of an installed ring slot cannot replace
         the original log operation, including its cancellation. *)
      | _ -> ignore (Atomic.fetch_and_add publication_notification_failures 1))
      (Atomic.get publication_listeners)

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
      diagnostic_kind = None;
    }
  (* Next sequence to hand out. A writer stores its entry in the slot first
     and raises [total] after, so a reader that sees [total = t] reads slots
     whose writes come before that [Atomic.set]: every sequence below [t]
     has landed. The other order (number first, slot after) let a reader on
     another domain find the row from [capacity] entries ago in a slot whose
     number was already out (#51304). *)
  let total = Atomic.make 0

  (* One writer at a time takes a sequence, fills its slot and raises
     [total], so [total] rises in sequence order. Held for those three steps
     only; no I/O and no listener runs under it. *)
  let ring_mutex = Stdlib.Mutex.create ()

  (* Sequence of the oldest entry the ring can answer for.  Zero for a
     process that started with an empty log directory; after
     [load_from_file] it is the sequence handed to the first restored
     entry, which resumes above every sequence already on disk (see
     [load_from_file]).  Without it the window math below would derive a
     lower bound of [total - capacity] and scan ring slots that this
     process never filled. *)
  let first_seq = Atomic.make 0

  (* Broadcast after every entry lands in its slot. [Eio.Condition.broadcast]
     takes no lock and needs no Eio context, so a push from any domain or
     systhread wakes the fibers waiting in [await_newer_than]. *)
  let appended = Eio.Condition.create ()

  (* File sink state *)
  let file_channel : out_channel option ref = ref None
  let file_current_date : string ref = ref ""
  let file_base_dir : string ref = ref ""

  (* One lock owns channel open/swap/close and complete append+flush batches.
     Stdlib.Mutex also works before Eio starts and during [at_exit]. Helpers
     below run with this lock held and never call back into the log ring. *)
  let sink_mutex = Stdlib.Mutex.create ()

  (* Sink-identity recheck throttle. The dev/ino check in [sink_matches_path]
     exists to catch external unlink/rename of the live log file — a rare
     event — but it sits on the emit path, so unthrottled it cost three
     stat-family syscalls per record (measured as 27% of main-thread samples;
     issue #25003). Records emitted inside the window after an external
     unlink land on the unlinked inode and are lost with it; the loss window
     is bounded by the interval. Date-roll rotation is not throttled. *)
  let default_sink_identity_recheck_interval_s = 5.0

  let sink_identity_recheck_interval_s : float ref =
    ref default_sink_identity_recheck_interval_s

  let last_sink_identity_check_at : float ref = ref neg_infinity

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

  let seal_regular_file_tail path oc =
    let writer_stat = Unix.LargeFile.fstat (Unix.descr_of_out_channel oc) in
    if writer_stat.st_kind = Unix.S_REG && writer_stat.st_size > 0L then begin
      (* Keep the output channel write-only: a FIFO must still fail with
         EPIPE when its reader disappears. Nonblocking open also avoids
         waiting if an external rename replaces this path with a FIFO. *)
      let reader = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK] 0 in
      Fun.protect ~finally:(fun () -> Unix.close reader) (fun () ->
        let reader_stat = Unix.LargeFile.fstat reader in
        if reader_stat.st_dev <> writer_stat.st_dev
           || reader_stat.st_ino <> writer_stat.st_ino
           || reader_stat.st_kind <> Unix.S_REG then
          raise (Sys_error (path ^ ": sink changed during tail inspection"));
        if reader_stat.st_size > 0L then begin
          ignore
            (Unix.LargeFile.lseek reader (Int64.pred reader_stat.st_size) Unix.SEEK_SET);
          let tail = Bytes.create 1 in
          if Unix.read reader tail 0 1 <> 1 then
            raise (Sys_error (path ^ ": sink shrank during tail inspection"));
          if Bytes.get tail 0 <> '\n' then begin
            (* Do not truncate or replay ambiguous failed bytes. Separate
               their row from future records; [fold_jsonl_lines] warns and
               skips malformed JSON but still strictly decodes valid rows. *)
            output_char oc '\n';
            flush oc
          end
        end)
    end

  let open_channel dir =
    ensure_dir dir;
    let date = date_string () in
    let path = log_file_path dir date in
    (* [O_NONBLOCK] is only for the open: a write-only FIFO open without a
       reader fails ENXIO at once instead of blocking under the sink lock.
       Clear it again so writes keep their normal semantics — a full pipe
       still applies backpressure and a vanished reader still raises EPIPE.
       Regular files ignore the flag either way. An open failure reaches
       [try_open_channel]'s guard, which keeps the previous channel and
       retries later. *)
    let fd =
      Unix.openfile path
        [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; Unix.O_NONBLOCK ]
        0o644 in
    Unix.clear_nonblock fd;
    let oc = Unix.out_channel_of_descr fd in
    match seal_regular_file_tail path oc with
    | () -> (oc, date)
    | exception exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        close_out_noerr oc;
        Printexc.raise_with_backtrace exn backtrace

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
    protect ~default:None (fun () -> Some (open_channel dir))

  (* RFC-0079: typed encoder. Exhaustive match on [level] / [source] means
     adding a new variant fails to compile here until the wire format is
     extended deliberately. The wire shape (field set + key order) is the
     [LogEntryRawSchema] contract in [dashboard/src/api/schemas/logs.ts]. *)
  let entry_to_json e =
    (* The dashboard schema requires a non-empty keeper_name string, so
       [None] encodes as "system". That is also a valid Keeper name: the
       decoder preserves literal names, and this wire format cannot
       distinguish those two original option values. *)
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
            if today <> !file_current_date then true
            else begin
              (* The sink lock also owns the identity-check throttle. A backward wall-clock
                 jump delays the next check by at most the jump size, which
                 only widens the unlink-detection window. *)
              let now = Time_compat.now () in
              if
                now -. !last_sink_identity_check_at
                < !sink_identity_recheck_interval_s
              then false
              else begin
                last_sink_identity_check_at := now;
                not (sink_matches_path (log_file_path !file_base_dir today) oc)
              end
            end
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

  (* Append [lines] (each already ends in a newline) and flush once. The
     writer thread passes a batch; a synchronous producer passes one line. *)
  let write_lines_now lines =
    Stdlib.Mutex.protect sink_mutex
      (fun () ->
        rotate_if_needed ();
        match !file_channel with
        | Some oc ->
            (try
               List.iter (output_string oc) lines;
               flush oc
             with
             | Eio.Cancel.Cancelled _ as exn -> close_sink (); raise exn
             | exn ->
               Printf.eprintf
                 "[%s] [ERROR] [Log] file-sink write failed: %s; \
                  dropping channel for next-emit re-open\n%!"
                 (timestamp ())
                 (Printexc.to_string exn);
               close_sink ())
        | None -> ())

  (* RFC async-log-sink-durable-append-offload §3. Once [start_writer] runs,
     producers append serialized lines to a bounded queue and one OS thread
     writes them, so a slow write() stops that thread instead of the
     producer's domain. A full queue makes the producer wait: the file is the
     authoritative record, unlike the console mirror, which drops. Before
     [start_writer] and after [stop_writer] producers write synchronously. *)
  type writer_mode = Synchronous | Queued

  (* §4: 213 records/s at the busiest measured second fills this in 38 s;
     the largest measured record (4,022 B) bounds it at 33 MB. *)
  let file_writer_capacity = 8192

  let writer_mutex = Stdlib.Mutex.create ()
  let writer_nonempty = Condition.create ()
  let writer_nonfull = Condition.create ()
  let writer_queue : string Queue.t = Queue.create ()

  (* All guarded by [writer_mutex]. [writer_in_flight] counts the lines the
     writer took and has not written yet; they still count against
     [file_writer_capacity], so the capacity bounds every buffered line. *)
  let writer_mode = ref Synchronous
  let writer_thread : Thread.t option ref = ref None
  let writer_in_flight = ref 0

  let writer_exit_registered = Atomic.make false

  (* [true] when the queue took [line]; [false] when the mode is (or became,
     while this producer waited for room) [Synchronous]. *)
  let enqueue line =
    Stdlib.Mutex.protect writer_mutex (fun () ->
      let rec admit () =
        match !writer_mode with
        | Synchronous -> false
        | Queued
          when Queue.length writer_queue + !writer_in_flight >= file_writer_capacity ->
            Condition.wait writer_nonfull writer_mutex;
            admit ()
        | Queued ->
            Queue.add line writer_queue;
            Condition.signal writer_nonempty;
            true
      in
      admit ())

  let write_to_sink entry_json =
    let line = Yojson.Safe.to_string entry_json ^ "\n" in
    if not (enqueue line) then write_lines_now [ line ]

  (* Every queued line, and the mode they were taken under. Waits while the
     queue is empty and the writer is still wanted. *)
  let take_batch () =
    Stdlib.Mutex.protect writer_mutex (fun () ->
      let rec wait () =
        match !writer_mode with
        | Queued when Queue.is_empty writer_queue ->
            Condition.wait writer_nonempty writer_mutex;
            wait ()
        | Queued | Synchronous -> ()
      in
      wait ();
      let batch = List.of_seq (Queue.to_seq writer_queue) in
      Queue.clear writer_queue;
      writer_in_flight := List.length batch;
      (batch, !writer_mode))

  (* The written batch gives its room back to waiting producers. *)
  let finish_batch () =
    Stdlib.Mutex.protect writer_mutex (fun () ->
      writer_in_flight := 0;
      Condition.broadcast writer_nonfull)

  (* Ends once [stop_writer] set [Synchronous] and the queue is empty. *)
  let rec writer_loop () =
    let batch, mode = take_batch () in
    (match batch with
     | [] -> ()
     | _ :: _ -> write_lines_now batch);
    finish_batch ();
    match mode, batch with
    | Synchronous, [] -> ()
    | Synchronous, _ :: _ | Queued, _ -> writer_loop ()

  (* A writer that ended on an exception would leave producers waiting on a
     full queue for good. It hands the queue back to the synchronous path,
     says so on stderr, and writes what was queued. The batch being written
     when the exception came is not retried. *)
  let run_writer () =
    match writer_loop () with
    | () -> ()
    | exception exn ->
        let residue =
          Stdlib.Mutex.protect writer_mutex (fun () ->
            writer_mode := Synchronous;
            let residue = List.of_seq (Queue.to_seq writer_queue) in
            Queue.clear writer_queue;
            writer_in_flight := 0;
            Condition.broadcast writer_nonfull;
            residue)
        in
        Printf.eprintf
          "[%s] [ERROR] [Log] file-sink writer stopped: %s; producers write \
           synchronously again\n%!"
          (timestamp ()) (Printexc.to_string exn);
        (match residue with
         | [] -> ()
         | _ :: _ -> write_lines_now residue)

  let stop_writer () =
    let thread =
      Stdlib.Mutex.protect writer_mutex (fun () ->
        writer_mode := Synchronous;
        Condition.broadcast writer_nonempty;
        Condition.broadcast writer_nonfull;
        let thread = !writer_thread in
        writer_thread := None;
        thread)
    in
    Option.iter Thread.join thread

  let start_writer () =
    Stdlib.Mutex.protect writer_mutex (fun () ->
      match !writer_mode, !writer_thread with
      | Queued, _ | Synchronous, Some _ -> ()
      | Synchronous, None ->
          writer_mode := Queued;
          writer_thread := Some (Thread.create run_writer ()));
    if Atomic.compare_and_set writer_exit_registered false true then
      at_exit stop_writer

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
          diagnostic_kind = None;
        }
    | _ ->
        raise
          (Entry_decode_error
             (Printf.sprintf "expected JSON object, got %s"
                (Yojson.Safe.to_string json)))

  (* The diagnostic kind is in memory only: the sink wire has no key for it,
     so every row read back from disk arrives with [diagnostic_kind = None]
     and only its message text. This fold boundary is the one place string
     matching is allowed: decoding wire where a string is all that remains
     (the same rule RFC-0371 §6.1(3) applies to rehydrated provider wire).
     The signal row's text comes from a format string, so the literal
     "Received SIGTERM" does not appear at its emission site. If the JSONL
     sink writes the kind, restored rows carry it and this function goes
     away. *)
  let classify_restored_diagnostic (e : entry) : entry =
    match e.diagnostic_kind with
    | Some _ -> e
    | None ->
      let signal =
        if String_util.contains_substring e.message "Received SIGTERM" then Some "SIGTERM"
        else if String_util.contains_substring e.message "Received SIGINT" then Some "SIGINT"
        else None
      in
      match signal with
      | Some name -> { e with diagnostic_kind = Some (External_signal name) }
      | None ->
        if String_util.contains_substring e.message "invalid agent JSON"
        then { e with diagnostic_kind = Some Agent_decode_failure }
        else e
  ;;

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
       under Eio and max-line-size enforcement via the [~max_size:16 MiB]
       cap on [Eio.Buf_read.of_flow] (which [Buf_read.lines] then
       streams under).

       A row that does not decode raises [Entry_decode_error] here, the
       same as at every other boundary. This fold used to swallow that so
       rows written before the typed encoder ([raw_level] /
       [normalized_level] / [legacy_classified]) could pass through as a
       WARN; those schemas are gone and nothing writes them. *)
    let buf_ring : entry Queue.t = Queue.create () in
    (* Highest sequence any row on disk carries, counted over every decoded
       row rather than the [capacity]-bounded tail the queue keeps: a file
       whose tail comes from a short-lived run can hold a lower maximum
       than an earlier run wrote. *)
    let max_seq_on_disk = ref (-1) in
    let push_file path =
      Fs_compat.fold_jsonl_lines
        ~init:()
        ~f:(fun () ~line_no:_ json ->
          let e = classify_restored_diagnostic (entry_of_json json) in
          if e.seq > !max_seq_on_disk then max_seq_on_disk := e.seq;
          Queue.add e buf_ring;
          if Queue.length buf_ring > capacity then ignore (Queue.pop buf_ring))
        path
    in
    push_file (log_file_path dir yesterday);
    push_file (log_file_path dir today);
    (* [total] is process-local but the JSONL sink is per-UTC-day and
       append-only, so a restart used to re-issue sequences that rows
       already in the file carry.  Measured on
       [.masc/logs/system_log_2026-08-21.jsonl]: 130,102 rows, 35,068
       distinct [seq], one value reused ten times across twelve restarts —
       [seq] identified no row, and a dashboard cursor taken before a
       restart landed in the middle of the reissued range, silently
       skipping or replaying records.  Resuming above the on-disk maximum
       keeps the sequence a key for the whole file. *)
    let base_seq = !max_seq_on_disk + 1 in
    Stdlib.Mutex.protect ring_mutex (fun () ->
      let next = ref base_seq in
      Queue.iter
        (fun e ->
          buf.(!next mod capacity) <- { e with seq = !next };
          incr next)
        buf_ring;
      Atomic.set first_seq base_seq;
      Atomic.set total !next);
    Queue.length buf_ring

  let init_file_sink
      ?(identity_recheck_interval_s = default_sink_identity_recheck_interval_s)
      dir =
    Stdlib.Mutex.protect sink_mutex (fun () ->
      sink_identity_recheck_interval_s := identity_recheck_interval_s;
      last_sink_identity_check_at := neg_infinity;
      close_sink ();
      (* A failed load must not resume appends with unconfirmed sequence
         state. Once loaded, retries belong to B even if its open fails;
         the previous directory A is no longer an authorized destination. *)
      file_base_dir := "";
      file_current_date := "";
      let loaded = load_from_file dir in
      file_base_dir := dir;
      let oc, date = open_channel dir in
      file_channel := Some oc;
      file_current_date := date;
      if loaded > 0 then
        Printf.eprintf "[%s] [INFO] [Log] Restored %d log entries from disk\n%!" (timestamp ()) loaded)

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
        if String.starts_with ~prefix:"system_log_" fname
           && Filename.check_suffix fname ".jsonl" then begin
          (* Extract date from system_log_YYYY-MM-DD.jsonl *)
          let date_part = String.sub fname 11 10 in
          if date_part < cutoff then
            protect ~default:() (fun () -> Sys.remove (Filename.concat dir fname))
        end
      ) files
    end

  (* The file sink is a JSONL contract: [dashboard/src/api/schemas/logs.ts]
     and every operator tool decode it as UTF-8, line by line. A message is
     assembled from external text (a provider error body, a Yojson lexer
     message quoting the first bytes of a token) and can carry a multibyte
     character cut in half; [Yojson.Safe.to_string] copies bytes without
     validating, so one such entry made a whole day file undecodable for
     every reader (system_log_2026-09-11.jsonl seq 33886532). The sink owns
     the format, so it enforces it at write: a malformed sequence becomes
     U+FFFD here, once, for every recording path. *)
  let rec sanitize_json_strings (json : Yojson.Safe.t) : Yojson.Safe.t =
    match json with
    | `String s -> `String (String_util.sanitize_utf8 s)
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) ->
               (String_util.sanitize_utf8 key, sanitize_json_strings value))
             fields)
    | `List items -> `List (List.map sanitize_json_strings items)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as leaf -> leaf

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
      ?diagnostic_kind
      ~level
      ~module_name
      ~message
      () =
    (* Sink-level structural secret masking (#28925 gap 3). The ring is the
       single record source for both the dashboard log API and the JSONL
       file sink ([entry_to_json] reads the stored entry), so masking here
       covers every recording path regardless of which emit wrapper was
       used. Exact keeper-secret values cannot be masked at this layer —
       masc_log is a leaf and never sees keeper secret roots; those are
       masked upstream by [Keeper_secret_redaction]. *)
    let message =
      Secret_patterns.redact_text message |> String_util.sanitize_utf8
    in
    let details =
      Secret_patterns.redact_json_strings details |> sanitize_json_strings
    in
    let ts = timestamp_iso () in
    let entry, overwritten =
      Stdlib.Mutex.protect ring_mutex (fun () ->
        let seq = Atomic.get total in
        let idx = seq mod capacity in
        let overwritten =
          let previous = buf.(idx) in
          if seq >= capacity && previous.seq >= Atomic.get first_seq
          then Some previous else None in
        let entry = {
            seq;
            ts;
            level;
            source;
            module_name;
            keeper_name;
            turn_id;
            message;
            details;
            category;
            diagnostic_kind;
          } in
        buf.(idx) <- entry;
        Atomic.set total (seq + 1);
        (entry, overwritten))
    in
    Eio.Condition.broadcast appended;
    notify_published {entry; overwritten};
    (* A failed append closes the channel. Keep sending later entries to the
       configured sink so its next write can reopen it. *)
    if !file_base_dir <> "" then
      write_to_sink (entry_to_json entry)

  let recent ?(limit = 200) ?(min_level = 0) ?(module_filter = "")
      ?since_seq
      ?before_seq
      ?(order = `Newest_first)
      ?categories
      ?exclude_categories
      () : entry list =
    let t = Atomic.get total in
    if t = 0 then []
    else begin
      let start = max (Atomic.get first_seq) (t - capacity) in
      (* [since_seq] raises the lower bound (entries strictly newer than the
         cursor); [before_seq] lowers the upper bound (entries strictly older
         than the cursor). The slot of scan index [i] holds the entry of
         sequence [i] (see [total]) unless writers went [capacity] entries
         further while this scan ran and put a newer entry there. The scan
         leaves such a slot out: sequence [i] is gone from the ring. So seq
         comparisons reduce to index bounds. The two cursors compose into a
         bounded window. *)
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
        let retained = e.seq = !i in
        let level_ok = level_to_int e.level >= min_level in
        let module_ok = module_filter = "" ||
          String.lowercase_ascii e.module_name =
          String.lowercase_ascii module_filter in
        let category_ok =
          match categories with
          | None -> true
          | Some selectors ->
              List.exists (fun selector -> selects selector e.category) selectors
        in
        let exclude_ok =
          match exclude_categories with
          | None -> true
          | Some selectors ->
              not (List.exists (fun selector -> selects selector e.category) selectors)
        in
        if retained && level_ok && module_ok && category_ok && exclude_ok then begin
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

  (* The live ring can only answer for the last [capacity] sequences.
     A query that returns nothing (or thin results) is ambiguous
     without these bounds: "it never happened" and "it happened before
     the window" look identical (2026-08-17 source audit,
     feature-matrix Log row). The bounds ride on every logs query
     response so the operator sees the cut, not silence. *)
  let await_newer_than seq =
    Eio.Condition.loop_no_mutex appended (fun () ->
      if Atomic.get total - 1 > seq then Some () else None)

  let bounds () =
    let t = Atomic.get total in
    let first = Atomic.get first_seq in
    { start_seq = max first (t - capacity)
    ; total = t
    ; dropped_before = t - first > capacity
    }

  let summary_json () =
    (* Counts, not sequences: [total] is the next sequence to hand out and
       starts above the on-disk maximum after a restore, so subtracting
       [first_seq] is what turns it back into "records this process holds". *)
    let total_entries = Atomic.get total - Atomic.get first_seq in
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

let info ?ctx ?category fmt = log Info ?ctx ?category fmt
let warn ?ctx ?category fmt = log Warn ?ctx ?category fmt
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
    ?diagnostic_kind:diagnostic_kind ->
    string ->
    unit

  val emit_lazy :
    level -> ?keeper_name:string -> ?turn_id:int -> ?category:category ->
    (unit -> string * Yojson.Safe.t) -> unit

  val routine_lazy :
    ?details:Yojson.Safe.t ->
    ?keeper_name:string ->
    ?turn_id:int ->
    ?category:category ->
    (unit -> string) -> unit

  val routine :
    ?details:Yojson.Safe.t ->
    ?keeper_name:string ->
    ?turn_id:int ->
    ?category:category ->
    ('a, unit, string, unit) format4 ->
    'a

  val debug :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a

  val info :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a

  val warn :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a

  val error :
    ?keeper_name:string -> ?turn_id:int -> ?category:category -> ?diagnostic_kind:diagnostic_kind -> ('a, unit, string, unit) format4 -> 'a
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

  let write_event level ?keeper_name ?turn_id ?category ?diagnostic_kind ~details message =
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
    Ring.push ?keeper_name ?turn_id ?category ?diagnostic_kind
      ~level ~module_name:M.name ~message ~details ()

  let emit level ?(details = `Null) ?keeper_name ?turn_id ?category ?diagnostic_kind message =
    if should_log_module level then
      write_event level ?keeper_name ?turn_id ?category ?diagnostic_kind ~details message

  let emit_lazy level ?keeper_name ?turn_id ?category build =
    if should_log_module level then begin
      let message, details = build () in
      write_event level ?keeper_name ?turn_id ?category ~details message
    end

  let log_module level ?keeper_name ?turn_id ?category ?diagnostic_kind fmt =
    Printf.ksprintf (fun msg -> emit level ?keeper_name ?turn_id ?category ?diagnostic_kind msg) fmt

  let routine_lazy ?(details = `Null) ?keeper_name ?turn_id ?category message =
    match routine_level () with
    | Some level when should_log_module level ->
        emit level ~details:(details_with_event_class Routine details)
          ?keeper_name ?turn_id ?category (message ())
    | Some _ | None -> ()

  let routine ?(details = `Null) ?keeper_name ?turn_id ?category fmt =
    Printf.ksprintf
      (fun msg ->
         match routine_level () with
         | None -> ()
         | Some level ->
             emit level ~details:(details_with_event_class Routine details)
               ?keeper_name ?turn_id ?category msg)
      fmt

  let debug ?keeper_name ?turn_id ?category ?diagnostic_kind fmt = log_module Debug ?keeper_name ?turn_id ?category ?diagnostic_kind fmt
  let info ?keeper_name ?turn_id ?category ?diagnostic_kind fmt = log_module Info ?keeper_name ?turn_id ?category ?diagnostic_kind fmt
  let warn ?keeper_name ?turn_id ?category ?diagnostic_kind fmt = log_module Warn ?keeper_name ?turn_id ?category ?diagnostic_kind fmt
  let error ?keeper_name ?turn_id ?category ?diagnostic_kind fmt = log_module Error ?keeper_name ?turn_id ?category ?diagnostic_kind fmt
end

(** Pre-defined module loggers *)
module Workspace = Make(struct let name = "Workspace" end)
module Mcp = Make(struct let name = "MCP" end)
module Auth = Make(struct let name = "Auth" end)
module Backend = Make(struct let name = "Backend" end)
module Session = Make(struct let name = "Session" end)
module Sub = Make(struct let name = "Subscriptions" end)
module Pulse = Make(struct let name = "Pulse" end)
module BoardLog = Make(struct let name = "Board" end)
module MsxLog = Make(struct let name = "Msx" end)
module DosLog = Make(struct let name = "Dos" end)
module Metrics = Make(struct let name = "Metrics" end)
module Dashboard = Make(struct let name = "Dashboard" end)
module Telemetry = Make(struct let name = "Telemetry" end)
module Gate = Make(struct let name = "Gate" end)
module Transport = Make(struct let name = "Transport" end)
module Keeper = Make(struct let name = "Keeper" end)
(* RFC-0058 Phase 8.1.5: dedicated runtime namespace so partial-catalog
   warnings and other runtime-domain events route through a stable
   channel that alerting/dashboard filters can target without false
   positives from the Keeper namespace. *)
module Runtime = Make(struct let name = "Runtime" end)
module Mention = Make(struct let name = "Mention" end)
module Misc = Make(struct let name = "Misc" end)
module Identity = Make(struct let name = "Identity" end)
module Pages = Make(struct let name = "Pages" end)
module Config = Make(struct let name = "Config" end)
module Task = Make(struct let name = "Task" end)
module Http = Make(struct let name = "Http" end)
module Server = Make(struct let name = "Server" end)
module TaskState = Make(struct let name = "TaskState" end)
module KeeperExec = Make(struct let name = "KeeperExec" end)
module Harness = Make(struct let name = "Harness" end)
module Candle = Make(struct let name = "Candle" end)

(* Logging-consistency migration (refactor/logging-consistency-harness):
   modules added so that former top-level [Log.info ~ctx:"<name>"] call sites
   route through a dedicated per-module logger while preserving the exact
   component string operators see in [ts] [LEVEL] [<name>] output. The [name]
   string is the original [~ctx] value verbatim; the module identifier is its
   Capitalized form. See docs/LOGGING.md. *)
module Otel = Make(struct let name = "otel" end)
module Runtime_verify = Make(struct let name = "runtime_verify" end)
module Mcp_transport = Make(struct let name = "mcp_transport" end)
module Startup = Make(struct let name = "startup" end)
module Model_inference_metrics = Make(struct let name = "model_inference_metrics" end)
module Runtime_agent = Make(struct let name = "runtime_agent" end)
module Agent_core_event = Make(struct let name = "agent_core:event" end)
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
module Ide = Make(struct let name = "Ide" end)
