(** See [Dashboard_execute_output.mli]. *)

type entry = {
  task_id : string option;
  stdout : string;
  stderr : string;
  status : Yojson.Safe.t;
  generated_at : float;
}

type output_line = {
  seq : int;
  ts_ms : int;
  stream : string;
  text : string;
  ansi : bool;
}

type snapshot = {
  keeper : string;
  task_id : string option;
  task_count : int;
  lines : output_line list;
  last_seq : int;
  stdout_since : string;
  stderr_since : string;
  since_stdout : int;
  since_stderr : int;
  bytes_dropped_stdout : int;
  bytes_dropped_stderr : int;
  closed : bool;
  status : Yojson.Safe.t option;
  generated_at : float;
}

(* One numbered entry of a keeper's output log. A line's number is
   [line.seq]; the task markers carry theirs in [seq]. *)
type logged_event =
  | Task_opened_event of {
      keeper : string;
      seq : int;
      task_id : string option;
      generated_at : float;
    }
  | Line_event of {
      keeper : string;
      task_id : string option;
      line : output_line;
      generated_at : float;
    }
  | Task_closed_event of {
      keeper : string;
      seq : int;
      task_id : string option;
      status : Yojson.Safe.t;
      generated_at : float;
    }

type stream_event =
  | Logged of logged_event
  | Gap_event of {
      keeper : string;
      missing_from_seq : int;
      missing_to_seq : int;
      generated_at : float;
    }

(* The slot [seq mod event_log_capacity] holds the event numbered [seq]. The
   retained numbers are the last [event_log_capacity] before [next_seq]. *)
type keeper_log = {
  slots : logged_event array;
  mutable next_seq : int;
}

(* A subscriber owns no copy of the events. It keeps the number of the last
   event it was handed and reads the keeper's log from there, so producers
   never wait for it and never discard an event on its behalf. [wakeup]
   holds at most one pending signal that the log grew. *)
type subscriber = {
  id : int;
  keeper : string;
  mutable delivered_seq : int;
  wakeup : unit Eio.Stream.t;
}

let per_keeper_cap = 50
let retained_stream_bytes = 256 * 1024
let event_log_capacity = 5000
let max_line_bytes = 4096
let first_seq = 1

(* Stdlib.Mutex: producer callbacks can run outside an Eio context, and the
   critical section only mutates or snapshots small queues and arrays. *)
let mu = Mutex.create ()
let table : (string, entry Queue.t) Hashtbl.t = Hashtbl.create 16
let logs : (string, keeper_log) Hashtbl.t = Hashtbl.create 16
let subscribers : (string, subscriber list) Hashtbl.t = Hashtbl.create 16
let next_subscriber_id = ref 0

(* Open stream tracking so that live chunks carry the same task_id as the
   execution that produced them. *)
type open_stream_state = { task_id : string option }
let open_streams : (string, open_stream_state) Hashtbl.t = Hashtbl.create 16

let normalize_keeper keeper_name =
  keeper_name |> String.trim |> String.lowercase_ascii

let now_unix () =
  (* NDT-OK: runtime freshness timestamp only; not a deterministic input. *)
  Unix.gettimeofday ()

let with_lock f = Mutex.protect mu f

let queue_to_list q =
  Queue.fold (fun acc value -> value :: acc) [] q |> List.rev

let ts_ms_of_unix ts = int_of_float (ts *. 1000.0)

let strip_trailing_cr line =
  let len = String.length line in
  if len > 0 && Char.equal line.[len - 1] '\r'
  then String.sub line 0 (len - 1)
  else line

let split_chunk_lines chunk =
  if String.equal chunk ""
  then []
  else (
    let lines = String.split_on_char '\n' chunk in
    let rec drop_last = function
      | [] -> []
      | [ _ ] -> []
      | head :: tail -> head :: drop_last tail
    in
    let lines =
      if String.ends_with ~suffix:"\n" chunk then drop_last lines else lines
    in
    List.map strip_trailing_cr lines)

(* One row carries at most [max_line_bytes]. A longer line continues in the
   next row instead of losing its tail, cut between characters. The streamed
   path already delivers a long unterminated record as several bounded pieces
   ([Keeper_secret_redaction.redact_stream_chunk]), each its own row, so a
   completed entry now shows the same text a live tail showed. A row with no
   character boundary in its first [max_line_bytes] bytes is not UTF-8, and
   the byte cut stands so the split always advances. *)
let row_texts line =
  let len = String.length line in
  let rec loop acc start =
    if len - start <= max_line_bytes
    then List.rev (String.sub line start (len - start) :: acc)
    else (
      let byte_cut = start + max_line_bytes in
      let cut =
        let boundary = String_util.utf8_char_boundary line byte_cut in
        if boundary > start then boundary else byte_cut
      in
      loop (String.sub line start (cut - start) :: acc) cut)
  in
  loop [] 0

let line_texts chunk =
  split_chunk_lines chunk |> List.concat_map row_texts

let append_bounded q cap value =
  Queue.push value q;
  while Queue.length q > cap do
    let _dropped = Queue.pop q in
    ()
  done

let oldest_retained_seq log = max first_seq (log.next_seq - event_log_capacity)

let last_logged_seq_locked keeper =
  match Hashtbl.find_opt logs keeper with
  | Some log -> log.next_seq - 1
  | None -> first_seq - 1

let append_logged_locked ~keeper (make : int -> logged_event) =
  match Hashtbl.find_opt logs keeper with
  | Some log ->
    let seq = log.next_seq in
    log.slots.(seq mod event_log_capacity) <- make seq;
    log.next_seq <- seq + 1
  | None ->
    (* The first event also fills the slots no number has reached yet;
       readers stay between [oldest_retained_seq] and [next_seq], so those
       copies are never read. *)
    let first = make first_seq in
    Hashtbl.replace
      logs
      keeper
      { slots = Array.make event_log_capacity first; next_seq = first_seq + 1 }

let append_lines_locked ~keeper ~task_id ~generated_at ~stream texts =
  let ts_ms = ts_ms_of_unix generated_at in
  List.iter
    (fun text ->
       append_logged_locked ~keeper (fun seq ->
         Line_event
           { keeper
           ; task_id
           ; line = { seq; ts_ms; stream; text; ansi = false }
           ; generated_at
           }))
    texts

(* The capacity-1 wakeup stream is only added to under [mu] and only when
   empty, so [Eio.Stream.add] never waits here. *)
let wake_subscribers_locked keeper =
  (* DET-OK: missing subscriber list means no live clients for this keeper. *)
  Hashtbl.find_opt subscribers keeper
  |> Option.value ~default:[]
  |> List.iter (fun subscriber ->
    if Eio.Stream.length subscriber.wakeup = 0
    then Eio.Stream.add subscriber.wakeup ())

let append_entry_locked ~keeper (entry : entry) =
  let q =
    match Hashtbl.find_opt table keeper with
    | Some q -> q
    | None ->
      let q = Queue.create () in
      Hashtbl.add table keeper q;
      q
  in
  append_bounded q per_keeper_cap entry

let append_completed ~streamed ~keeper_name (entry : entry) =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then ()
  else if streamed
  then
    (* A streamed execution already logged its lines through
       [append_stream_chunk] and its close through [record_stream_end]. *)
    with_lock (fun () -> append_entry_locked ~keeper entry)
  else (
    let stdout_texts = line_texts entry.stdout in
    let stderr_texts = line_texts entry.stderr in
    let task_id = entry.task_id in
    let generated_at = entry.generated_at in
    with_lock (fun () ->
      append_entry_locked ~keeper entry;
      append_lines_locked ~keeper ~task_id ~generated_at ~stream:"stdout" stdout_texts;
      append_lines_locked ~keeper ~task_id ~generated_at ~stream:"stderr" stderr_texts;
      append_logged_locked ~keeper (fun seq ->
        Task_closed_event
          { keeper; seq; task_id; status = entry.status; generated_at });
      wake_subscribers_locked keeper))

let record_failure exn =
  Log.Dashboard.warn
    "dashboard execute output collector failed: %s"
    (Printexc.to_string exn)

let record_completed ~keeper_name ~task_id ~stdout ~stderr ~status ?(streamed = false) () =
  let entry =
    { task_id; stdout; stderr; status; generated_at = now_unix () }
  in
  try append_completed ~streamed ~keeper_name entry with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> record_failure exn

let record_stream_start ~keeper_name ~task_id =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then ()
  else (
    let generated_at = now_unix () in
    with_lock (fun () ->
      Hashtbl.replace open_streams keeper { task_id };
      append_logged_locked ~keeper (fun seq ->
        Task_opened_event { keeper; seq; task_id; generated_at });
      wake_subscribers_locked keeper))

let append_stream_chunk ~keeper_name ~stream chunk =
  let keeper = normalize_keeper keeper_name in
  if keeper = "" || String.equal chunk ""
  then ()
  else (
    let generated_at = now_unix () in
    let stream_label =
      match stream with
      | `Stdout -> "stdout"
      | `Stderr -> "stderr"
    in
    let texts = line_texts chunk in
    with_lock (fun () ->
      let task_id =
        match Hashtbl.find_opt open_streams keeper with
        | Some state -> state.task_id
        | None -> None
      in
      append_lines_locked ~keeper ~task_id ~generated_at ~stream:stream_label texts;
      wake_subscribers_locked keeper))

let record_stream_end ~keeper_name ~task_id ~status =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then ()
  else (
    let generated_at = now_unix () in
    with_lock (fun () ->
      Hashtbl.remove open_streams keeper;
      append_logged_locked ~keeper (fun seq ->
        Task_closed_event { keeper; seq; task_id; status; generated_at });
      wake_subscribers_locked keeper))

let retained_lines_locked keeper =
  match Hashtbl.find_opt logs keeper with
  | None -> []
  | Some log ->
    let rec collect seq acc =
      if seq < oldest_retained_seq log
      then acc
      else (
        match log.slots.(seq mod event_log_capacity) with
        | Line_event { line; _ } -> collect (seq - 1) (line :: acc)
        | Task_opened_event _ | Task_closed_event _ -> collect (seq - 1) acc)
    in
    collect (log.next_seq - 1) []

let snapshot_state keeper_name =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then "", [], [], first_seq - 1
  else
    with_lock (fun () ->
      let entries =
        match Hashtbl.find_opt table keeper with
        | None -> []
        | Some q -> queue_to_list q
      in
      keeper, entries, retained_lines_locked keeper, last_logged_seq_locked keeper)

let add_stream_chunks entries select =
  let buffer =
    Exec_buffer.create ~head_cap:0 ~tail_cap:retained_stream_bytes
  in
  List.iter
    (fun entry -> Exec_buffer.add_string buffer (select entry))
    entries;
  (* Once older output is dropped, the ring's first byte can be the middle of
     a character. Start at the next character and count the skipped bytes as
     dropped, so [bytes_dropped] still covers everything not shown. *)
  let ring_tail = Exec_buffer.tail buffer in
  let tail = String_util.utf8_suffix ~max_bytes:retained_stream_bytes ring_tail in
  ( tail
  , Exec_buffer.total_bytes buffer
  , Exec_buffer.bytes_dropped buffer + (String.length ring_tail - String.length tail) )

let snapshot ~keeper_name =
  let keeper, entries, lines, last_seq = snapshot_state keeper_name in
  match List.rev entries with
  | [] -> None
  | latest :: _ ->
    let stdout_since, since_stdout, bytes_dropped_stdout =
      add_stream_chunks entries (fun entry -> entry.stdout)
    in
    let stderr_since, since_stderr, bytes_dropped_stderr =
      add_stream_chunks entries (fun entry -> entry.stderr)
    in
    Some
      { keeper
      ; task_id = latest.task_id
      ; task_count = List.length entries
      ; lines
      ; last_seq
      ; stdout_since
      ; stderr_since
      ; since_stdout
      ; since_stderr
      ; bytes_dropped_stdout
      ; bytes_dropped_stderr
      ; closed = true
      ; status = Some latest.status
      ; generated_at = latest.generated_at
      }

let option_json f = function
  | Some value -> f value
  | None -> `Null

let output_line_json line =
  `Assoc
    [ "seq", `Int line.seq
    ; "ts_ms", `Int line.ts_ms
    ; "stream", `String line.stream
    ; "text", `String line.text
    ; "ansi", `Bool line.ansi
    ]

let snapshot_json (s : snapshot) =
  `Assoc
    [ "type", `String "snapshot"
    ; "kind", `String "snapshot"
    ; "keeper", `String s.keeper
    ; "keeper_id", `String s.keeper
    ; "task_id", option_json (fun value -> `String value) s.task_id
    ; "task_count", `Int s.task_count
    ; "lines", `List (List.map output_line_json s.lines)
    ; "last_seq", `Int s.last_seq
    ; "since_stdout", `Int s.since_stdout
    ; "since_stderr", `Int s.since_stderr
    ; "stdout_since", `String s.stdout_since
    ; "stderr_since", `String s.stderr_since
    ; "closed", `Bool s.closed
    ; "status", option_json (fun value -> value) s.status
    ; "bytes_dropped_stdout", `Int s.bytes_dropped_stdout
    ; "bytes_dropped_stderr", `Int s.bytes_dropped_stderr
    ; "generated_at", `Float s.generated_at
    ]

let no_task_json keeper_name =
  `Assoc
    [ "type", `String "no_task"
    ; "kind", `String "no_task"
    ; "keeper", `String (normalize_keeper keeper_name)
    ; "keeper_id", `String (normalize_keeper keeper_name)
    ; "task_count", `Int 0
    ; "lines", `List []
    ; "closed", `Bool true
    ; "generated_at", `Float (now_unix ())
    ]

let event_json ~keeper_name =
  match snapshot ~keeper_name with
  | Some s -> snapshot_json s
  | None -> no_task_json keeper_name

let logged_event_json = function
  | Task_opened_event { keeper; seq; task_id; generated_at } ->
    `Assoc
      [ "type", `String "task_opened"
      ; "kind", `String "task_opened"
      ; "keeper", `String keeper
      ; "keeper_id", `String keeper
      ; "seq", `Int seq
      ; "task_id", option_json (fun value -> `String value) task_id
      ; "closed", `Bool false
      ; "generated_at", `Float generated_at
      ]
  | Line_event { keeper; task_id; line; generated_at } ->
    `Assoc
      [ "type", `String "line"
      ; "kind", `String "line"
      ; "keeper", `String keeper
      ; "keeper_id", `String keeper
      ; "seq", `Int line.seq
      ; "task_id", option_json (fun value -> `String value) task_id
      ; "line", output_line_json line
      ; "closed", `Bool false
      ; "generated_at", `Float generated_at
      ]
  | Task_closed_event { keeper; seq; task_id; status; generated_at } ->
    `Assoc
      [ "type", `String "task_closed"
      ; "kind", `String "task_closed"
      ; "keeper", `String keeper
      ; "keeper_id", `String keeper
      ; "seq", `Int seq
      ; "task_id", option_json (fun value -> `String value) task_id
      ; "closed", `Bool true
      ; "status", status
      ; "generated_at", `Float generated_at
      ]

let stream_event_json = function
  | Logged event -> logged_event_json event
  | Gap_event { keeper; missing_from_seq; missing_to_seq; generated_at } ->
    `Assoc
      [ "type", `String "gap"
      ; "kind", `String "gap"
      ; "keeper", `String keeper
      ; "keeper_id", `String keeper
      ; "missing_from_seq", `Int missing_from_seq
      ; "missing_to_seq", `Int missing_to_seq
      ; "missing_count", `Int (missing_to_seq - missing_from_seq + 1)
      ; "generated_at", `Float generated_at
      ]

let sse_frame json =
  Printf.sprintf "event: output\ndata: %s\n\n" (Yojson.Safe.to_string json)

let subscribe ~keeper_name =
  let keeper = normalize_keeper keeper_name in
  if String.equal keeper ""
  then None
  else
    let wakeup = Eio.Stream.create 1 in
    with_lock (fun () ->
      let id = !next_subscriber_id in
      incr next_subscriber_id;
      let subscriber =
        { id; keeper; delivered_seq = last_logged_seq_locked keeper; wakeup }
      in
      let current =
        (* DET-OK: missing subscriber list means this is the first client. *)
        Hashtbl.find_opt subscribers keeper |> Option.value ~default:[]
      in
      Hashtbl.replace subscribers keeper (subscriber :: current);
      Some subscriber)

let unsubscribe subscriber =
  with_lock (fun () ->
    match Hashtbl.find_opt subscribers subscriber.keeper with
    | None -> ()
    | Some current ->
      let remaining =
        List.filter (fun candidate -> candidate.id <> subscriber.id) current
      in
      if remaining = []
      then Hashtbl.remove subscribers subscriber.keeper
      else Hashtbl.replace subscribers subscriber.keeper remaining)

let initial_event_json subscriber =
  match snapshot ~keeper_name:subscriber.keeper with
  | None -> no_task_json subscriber.keeper
  | Some s ->
    (* The snapshot holds every retained line up to [s.last_seq], so the live
       tail starts after it and no line reaches the viewer twice. *)
    with_lock (fun () -> subscriber.delivered_seq <- s.last_seq);
    snapshot_json s

let next_event_locked subscriber =
  match Hashtbl.find_opt logs subscriber.keeper with
  | None -> None
  | Some log ->
    let wanted = subscriber.delivered_seq + 1 in
    let oldest = oldest_retained_seq log in
    if wanted >= log.next_seq
    then None
    else if wanted < oldest
    then (
      (* The log moved past this subscriber: the numbers it has not read
         are gone from the server too, so it is told which ones. *)
      subscriber.delivered_seq <- oldest - 1;
      Some
        (Gap_event
           { keeper = subscriber.keeper
           ; missing_from_seq = wanted
           ; missing_to_seq = oldest - 1
           ; generated_at = now_unix ()
           }))
    else (
      subscriber.delivered_seq <- wanted;
      Some (Logged log.slots.(wanted mod event_log_capacity)))

let rec take_event subscriber =
  match with_lock (fun () -> next_event_locked subscriber) with
  | Some event -> event
  | None ->
    Eio.Stream.take subscriber.wakeup;
    take_event subscriber

let reset_for_testing () =
  with_lock (fun () ->
    Hashtbl.clear table;
    Hashtbl.clear logs;
    Hashtbl.clear subscribers;
    Hashtbl.clear open_streams;
    next_subscriber_id := 0)

let output_lines_for_testing ~keeper_name =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then []
  else with_lock (fun () -> retained_lines_locked keeper)

let inject_for_testing
      ~keeper_name
      ?task_id
      ?(generated_at = now_unix ())
      ~stdout
      ~stderr
      ~status
      ()
  =
  append_completed
    ~streamed:false
    ~keeper_name
    { task_id; stdout; stderr; status; generated_at }

let () =
  Keeper_keepalive_signal.register_record_execute_output
    (fun ~keeper_name ~task_id ~stdout ~stderr ~status ~streamed ->
       record_completed ~streamed ~keeper_name ~task_id ~stdout ~stderr ~status ())
;;

let () =
  Keeper_keepalive_signal.register_record_execute_stream_chunk
    (fun ~keeper_name ~stream chunk ->
       append_stream_chunk ~keeper_name ~stream chunk)
;;

let () =
  Keeper_keepalive_signal.register_record_execute_stream_start
    (fun ~keeper_name ~task_id -> record_stream_start ~keeper_name ~task_id)
;;

let () =
  Keeper_keepalive_signal.register_record_execute_stream_end
    (fun ~keeper_name ~task_id ~status -> record_stream_end ~keeper_name ~task_id ~status)
;;
