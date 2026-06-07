(** See [Dashboard_execute_output.mli]. *)

type entry = {
  task_id : string option;
  stdout : string;
  stderr : string;
  status : Yojson.Safe.t;
  generated_at : float;
}

type output_line = {
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

type stream_event =
  | Task_opened_event of {
      keeper : string;
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
      task_id : string option;
      status : Yojson.Safe.t;
      generated_at : float;
    }

type subscriber = {
  id : int;
  keeper : string;
  events : stream_event Eio.Stream.t;
}

let per_keeper_cap = 50
let retained_stream_bytes = 256 * 1024
let line_ring_cap = 5000
let subscriber_capacity = 256
let max_line_bytes = 4096

(* Stdlib.Mutex: producer callbacks can run outside an Eio context, and the
   critical section only mutates or snapshots small queues. *)
let mu = Mutex.create ()
let table : (string, entry Queue.t) Hashtbl.t = Hashtbl.create 16
let line_table : (string, output_line Queue.t) Hashtbl.t = Hashtbl.create 16
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

let with_lock f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f

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

let output_lines_for_chunk ~ts_ms ~stream chunk =
  split_chunk_lines chunk
  |> List.map (fun text ->
    { ts_ms
    ; stream
    ; text = Masc_exec.Exec_buffer.utf8_truncate text max_line_bytes
    ; ansi = false
    })

let output_lines_for_entry (entry : entry) =
  let ts_ms = ts_ms_of_unix entry.generated_at in
  output_lines_for_chunk ~ts_ms ~stream:"stdout" entry.stdout
  @ output_lines_for_chunk ~ts_ms ~stream:"stderr" entry.stderr

let append_bounded q cap value =
  Queue.push value q;
  while Queue.length q > cap do
    let _dropped = Queue.pop q in
    ()
  done

let append_completed_locked ~keeper (entry : entry) lines =
  let q =
    match Hashtbl.find_opt table keeper with
    | Some q -> q
    | None ->
      let q = Queue.create () in
      Hashtbl.add table keeper q;
      q
  in
  append_bounded q per_keeper_cap entry;
  let line_q =
    match Hashtbl.find_opt line_table keeper with
    | Some q -> q
    | None ->
      let q = Queue.create () in
      Hashtbl.add line_table keeper q;
      q
  in
  List.iter (append_bounded line_q line_ring_cap) lines;
  (* DET-OK: missing subscriber list means no live clients for this keeper. *)
  Hashtbl.find_opt subscribers keeper |> Option.value ~default:[]

let enqueue_subscriber_event subscriber event =
  while Eio.Stream.length subscriber.events >= subscriber_capacity do
    match Eio.Stream.take_nonblocking subscriber.events with
    | Some _ -> ()
    | None -> ()
  done;
  Eio.Stream.add subscriber.events event

let broadcast_events subscribers events =
  List.iter
    (fun event ->
       List.iter
         (fun subscriber ->
            try enqueue_subscriber_event subscriber event with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Dashboard.warn
                "dashboard execute output subscriber enqueue failed: %s"
                (Printexc.to_string exn))
         subscribers)
    events

let append_completed ?(emit_events = true) ~keeper_name (entry : entry) =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then ()
  else (
    let lines = output_lines_for_entry entry in
    let current_subscribers =
      with_lock (fun () -> append_completed_locked ~keeper entry lines)
    in
    if emit_events
    then (
      let events =
        List.map
          (fun line ->
             Line_event { keeper; task_id = entry.task_id; line; generated_at = entry.generated_at })
          lines
        @ [ Task_closed_event
              { keeper
              ; task_id = entry.task_id
              ; status = entry.status
              ; generated_at = entry.generated_at
              }
          ]
      in
      broadcast_events current_subscribers events)
  )

let record_failure exn =
  Log.Dashboard.warn
    "dashboard execute output collector failed: %s"
    (Printexc.to_string exn)

let record_completed ~keeper_name ~task_id ~stdout ~stderr ~status ?(streamed = false) () =
  let entry =
    { task_id; stdout; stderr; status; generated_at = now_unix () }
  in
  try append_completed ~emit_events:(not streamed) ~keeper_name entry with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> record_failure exn

let record_stream_start ~keeper_name ~task_id =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then ()
  else (
    let generated_at = now_unix () in
    let current_subscribers =
      with_lock (fun () ->
        Hashtbl.replace open_streams keeper { task_id };
        Hashtbl.find_opt subscribers keeper |> Option.value ~default:[])
    in
    broadcast_events current_subscribers [ Task_opened_event { keeper; task_id; generated_at } ])

let append_stream_chunk ~keeper_name ~stream chunk =
  let keeper = normalize_keeper keeper_name in
  if keeper = "" || String.equal chunk ""
  then ()
  else (
    let generated_at = now_unix () in
    let ts_ms = ts_ms_of_unix generated_at in
    let stream_label =
      match stream with
      | `Stdout -> "stdout"
      | `Stderr -> "stderr"
    in
    let lines = output_lines_for_chunk ~ts_ms ~stream:stream_label chunk in
    let task_id, current_subscribers =
      with_lock (fun () ->
        let task_id =
          match Hashtbl.find_opt open_streams keeper with
          | Some state -> state.task_id
          | None -> None
        in
        let line_q =
          match Hashtbl.find_opt line_table keeper with
          | Some q -> q
          | None ->
            let q = Queue.create () in
            Hashtbl.add line_table keeper q;
            q
        in
        List.iter (append_bounded line_q line_ring_cap) lines;
        task_id, Hashtbl.find_opt subscribers keeper |> Option.value ~default:[])
    in
    let events =
      List.map
        (fun line -> Line_event { keeper; task_id; line; generated_at })
        lines
    in
    broadcast_events current_subscribers events)

let record_stream_end ~keeper_name ~task_id ~status =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then ()
  else (
    let generated_at = now_unix () in
    let current_subscribers =
      with_lock (fun () ->
        Hashtbl.remove open_streams keeper;
        Hashtbl.find_opt subscribers keeper |> Option.value ~default:[])
    in
    broadcast_events current_subscribers
      [ Task_closed_event { keeper; task_id; status; generated_at } ])

let snapshot_state keeper_name =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then "", [], []
  else
    with_lock (fun () ->
      let entries =
        match Hashtbl.find_opt table keeper with
        | None -> []
        | Some q -> queue_to_list q
      in
      let lines =
        match Hashtbl.find_opt line_table keeper with
        | None -> []
        | Some q -> queue_to_list q
      in
      keeper, entries, lines)

let add_stream_chunks entries select =
  let buffer =
    Masc_exec.Exec_buffer.create ~head_cap:0 ~tail_cap:retained_stream_bytes
  in
  List.iter
    (fun entry -> Masc_exec.Exec_buffer.add_string buffer (select entry))
    entries;
  ( Masc_exec.Exec_buffer.tail buffer
  , Masc_exec.Exec_buffer.total_bytes buffer
  , Masc_exec.Exec_buffer.bytes_dropped buffer )

let snapshot ~keeper_name =
  let keeper, entries, lines = snapshot_state keeper_name in
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
    [ "ts_ms", `Int line.ts_ms
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

let stream_event_json = function
  | Task_opened_event { keeper; task_id; generated_at } ->
    `Assoc
      [ "type", `String "task_opened"
      ; "kind", `String "task_opened"
      ; "keeper", `String keeper
      ; "keeper_id", `String keeper
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
      ; "task_id", option_json (fun value -> `String value) task_id
      ; "line", output_line_json line
      ; "closed", `Bool false
      ; "generated_at", `Float generated_at
      ]
  | Task_closed_event { keeper; task_id; status; generated_at } ->
    `Assoc
      [ "type", `String "task_closed"
      ; "kind", `String "task_closed"
      ; "keeper", `String keeper
      ; "keeper_id", `String keeper
      ; "task_id", option_json (fun value -> `String value) task_id
      ; "closed", `Bool true
      ; "status", status
      ; "generated_at", `Float generated_at
      ]

let sse_frame json =
  Printf.sprintf "event: output\ndata: %s\n\n" (Yojson.Safe.to_string json)

let subscribe ~keeper_name =
  let keeper = normalize_keeper keeper_name in
  if String.equal keeper ""
  then None
  else
    let events = Eio.Stream.create subscriber_capacity in
    with_lock (fun () ->
      let id = !next_subscriber_id in
      incr next_subscriber_id;
      let subscriber = { id; keeper; events } in
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

let take_event subscriber = Eio.Stream.take subscriber.events

let reset_for_testing () =
  with_lock (fun () ->
    Hashtbl.clear table;
    Hashtbl.clear line_table;
    Hashtbl.clear subscribers;
    Hashtbl.clear open_streams;
    next_subscriber_id := 0)

let output_lines_for_testing ~keeper_name =
  let keeper = normalize_keeper keeper_name in
  if keeper = ""
  then []
  else
    with_lock (fun () ->
      match Hashtbl.find_opt line_table keeper with
      | None -> []
      | Some q -> queue_to_list q)

let inject_for_testing
      ~keeper_name
      ?task_id
      ?(generated_at = now_unix ())
      ~stdout
      ~stderr
      ~status
      ()
  =
  append_completed ~keeper_name { task_id; stdout; stderr; status; generated_at }

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
