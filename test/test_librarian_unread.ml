(* Reading a Keeper's turn log on from where its commit log stands
   (RFC librarian-call-only-proposes §5.3, §5.4, §9.2, §16): where each unit
   starts and ends, the faults in the order the reader looks for them, a
   unit with no item, reading that starts inside a turn, and a read whose
   cost is the new lines only. *)

open Alcotest
module Log = Masc.Keeper_turn_log
module Store = Masc.Keeper_turn_log_store
module Commit_log = Masc.Librarian_log
module Unread = Masc.Librarian_unread

let ok_or_fail label = function
  | Ok value -> value
  | Error detail -> failf "%s: %s" label detail
;;

let log_id_of fill =
  match Log.Log_id.of_string (String.make 32 fill) with
  | Some id -> id
  | None -> fail "the test log id is not 32 hexadecimal characters"
;;

let log_id = log_id_of 'a'
let digest fill = ok_or_fail "digest" (Agent_core.Checkpoint_objects.digest_of_hex (String.make 64 fill))

(* Every store at a place named by one number, so a range reads as the
   numbers of the two marks around it. *)
let mark ?(session = "session-1") n : Log.mark =
  { trace = session
  ; closed_messages = n
  ; session
  ; history_bytes = 10 * n
  ; internal_bytes = 20 * n
  ; chat_bytes = 30 * n
  ; external_rows = n
  }
;;

(* Where an announced reset leaves the stores: only the history count moves. *)
let cleared n = { (mark n) with closed_messages = 0 }
let slice skip take : Log.slice = { bundle = digest 'c'; skip; take }
let started = Log.Log_started { id = log_id; at = 100.0; mark = mark 1 }

let opened baseline =
  Log.Opened
    { at = 101.0
    ; turn_ref = Ids.Turn_ref.make ~trace_id:"trace-1" ~absolute_turn:7
    ; runtime = "glm-main"
    ; task = No_task
    ; stimuli = []
    ; baseline
    }
;;

let closed ?(unattributed = []) ?(own = []) turn after =
  Log.Closed { turn; at = 102.0; outcome = Completed; after; unattributed; own }
;;

let announced ?(closed_before = []) before after =
  Log.Reset { at = 103.0; cause = Announced Recovered; before; after; closed_before }
;;

let unannounced before after =
  Log.Reset { at = 104.0; cause = Unannounced; before; after; closed_before = [] }
;;

type log =
  { path : string
  ; mutable rows_end : int
  }

let new_log () =
  { path =
      Store.path_for_keepers_dir ~keepers_dir:(Filename.temp_dir "turn-log" "") ~keeper_id:"keeper-a"
  ; rows_end = 0
  }
;;

let append_error_text : Store.append_error -> string = function
  | End_moved { expected; actual } -> Printf.sprintf "end moved from %d to %d" expected actual
  | Directory_unavailable { detail; _ } -> "directory unavailable: " ^ detail
  | Write_failed { detail; _ } -> "write failed: " ^ detail
;;

(* Appends one line and gives the offset it starts at. *)
let append log line =
  match Store.append ~path:log.path ~at_end:log.rows_end (line, []) with
  | Ok { new_end; last_at } ->
    log.rows_end <- new_end;
    last_at
  | Error error -> failf "append at %d: %s" log.rows_end (append_error_text error)
;;

let write_raw log text =
  Out_channel.with_open_gen [ Open_wronly; Open_append; Open_creat; Open_binary ] 0o600 log.path
    (fun channel -> Out_channel.output_string channel text);
  log.rows_end <- log.rows_end + String.length text
;;

let started_tail : Commit_log.line =
  Started
    { at = 100.0
    ; turn_log = log_id
    ; snapshot = digest 'a'
    ; revision = 0
    ; turn_log_offset = 0
    ; covered = mark 1
    }
;;

let committed ?(turn_log = log_id) ~offset ~covered ~through () : Commit_log.line =
  Committed
    { seq = 1
    ; at = 200.0
    ; basis = digest 'a'
    ; after = digest 'a'
    ; revision = 1
    ; cause = Adopt { by = "operator-1"; observed = digest 'a' }
    ; effects = Masc.Librarian_effects.empty
    ; turn_log
    ; turn_log_offset = offset
    ; covers_through = through
    ; covered
    ; working_state = None
    }
;;

(* The tail a commit leaves that read [span] whole. *)
let committed_through span =
  let ({ line; within; covered; turn_log_offset } : Masc.Librarian_read_result.reach) =
    Unread.reach_whole span
  in
  committed ~offset:turn_log_offset ~covered ~through:(Through { line; within }) ()
;;

(* The tail a commit leaves that read the first item of the unit at [span]
   and not the rest: reading stands on the unit's line, covered where the
   unit starts. *)
let committed_inside ~starts_at (span : Unread.span) =
  committed ~offset:span.line ~covered:starts_at ~through:(Through { line = span.line; within = Item 0 }) ()
;;

let last_span (reading : Unread.reading) =
  match List.rev reading.spans with
  | last :: _ -> last
  | [] -> fail "nothing was read"
;;

let range_text ({ from; until } : Masc.Librarian_unit.range) = Printf.sprintf "%d-%d" from until

let record_text : Unread.record -> string = function
  | Checkpoint slices ->
    Printf.sprintf "checkpoint [%s]"
      (String.concat " "
         (List.map (fun ({ skip; take; _ } : Log.slice) -> Printf.sprintf "%d+%d" skip take) slices))
  | Official_files { history; internal } ->
    Printf.sprintf "files history %s internal %s" (range_text history) (range_text internal)
;;

let segment_text ({ record; chat; external_rows } : Unread.segment) =
  Printf.sprintf "%s chat %s external %s" (record_text record) (range_text chat) (range_text external_rows)
;;

(* Offsets are counted from [base], so readings of logs with more lines
   before them read the same. *)
let span_text ?(base = 0) (span : Unread.span) =
  let next = Printf.sprintf "next %d/%d" span.next.closed_messages span.next.history_bytes in
  match span.source with
  | Turn { turn; unattributed; own; _ } ->
    Printf.sprintf "turn %d closed at %d: unattributed %s; own %s; %s" (turn - base)
      (span.line - base) (segment_text unattributed) (segment_text own) next
  | Announced_reset { segment; _ } ->
    Printf.sprintf "reset at %d: %s; %s" (span.line - base) (segment_text segment) next
;;

let stop_text : Unread.stop -> string = function
  | Log_end -> "log end"
  | Limit_reached -> "limit reached"
  | Unannounced_reset { line; past_line; _ } ->
    Printf.sprintf "unannounced reset at %d, read on from %d" line past_line
  | Unreadable_line { offset; reason = Undecodable Not_json } -> Printf.sprintf "line %d is not JSON" offset
  | Unreadable_line { offset; reason = Undecodable (Malformed _) } ->
    Printf.sprintf "line %d is malformed" offset
  | Unreadable_line { offset; reason = Out_of_order _ } -> Printf.sprintf "line %d is out of order" offset
;;

let reading_lines ?base (reading : Unread.reading) =
  List.map (span_text ?base) reading.spans @ [ stop_text reading.stop ]
;;

let error_text : Unread.read_error -> string = function
  | Fault (Turn_log_replaced { expected; observed = Some observed }) ->
    Printf.sprintf "%s replaced by %s" (Log.Log_id.to_string expected) (Log.Log_id.to_string observed)
  | Fault (Turn_log_replaced { expected; observed = None }) ->
    Printf.sprintf "%s replaced by a file with no log start" (Log.Log_id.to_string expected)
  | Fault (Position_lost { offset; length }) ->
    Printf.sprintf "offset %d lost in %d bytes" offset length
  | Fault (Line_unreadable { offset }) -> Printf.sprintf "line %d unreadable" offset
  | Fault (Content_unreadable { line }) -> Printf.sprintf "content of %d unreadable" line
  | Unread { detail } -> "unread: " ^ detail
;;

let read ?(until = Unread.To_end) log tail = Unread.read ~turns_path:log.path ~until tail

let read_ok ?until log tail =
  match read ?until log tail with
  | Ok reading -> reading
  | Error error -> failf "read: %s" (error_text error)
;;

(* §5.3: [Log_started] starts the first unit at its mark, a [Closed] ends
   its unit at [after] and the next starts there, a [Reset] ends its unit at
   [before] and the next starts at [after]. A turn splits at its baseline. *)
let test_unit_boundaries () =
  let log = new_log () in
  let (_ : int) = append log started in
  let first_reset = append log (announced (mark 2) (cleared 2)) in
  let turn = append log (opened (mark 3)) in
  let turn_closed = append log (closed ~unattributed:[ slice 0 1 ] ~own:[ slice 1 2 ] turn (mark 4)) in
  let last_reset =
    append log (announced ~closed_before:[ slice 3 1 ] (mark 5) { (mark 5) with closed_messages = 2 })
  in
  check (list string) "each unit runs from where the one before it left to its own end"
    [ Printf.sprintf
        "reset at %d: files history 10-20 internal 20-40 chat 30-60 external 1-2; next 0/20"
        first_reset
    ; Printf.sprintf
        "turn %d closed at %d: unattributed checkpoint [0+1] chat 60-90 external 2-3; own \
         checkpoint [1+2] chat 90-120 external 3-4; next 4/40"
        turn turn_closed
    ; Printf.sprintf
        "reset at %d: checkpoint [3+1] chat 120-150 external 4-5; next 2/50"
        last_reset
    ; "log end"
    ]
    (reading_lines (read_ok log started_tail))
;;

(* §5.4: the id first, then the stored offset, then the lines. *)
let test_faults_in_order () =
  let log = new_log () in
  let (_ : int) = append log started in
  let turn = append log (opened (mark 1)) in
  let turn_closed = append log (closed ~own:[ slice 0 1 ] turn (mark 2)) in
  let undecodable = log.rows_end in
  write_raw log "not json\n";
  let length = log.rows_end in
  let through = Commit_log.Through { line = turn_closed; within = Whole } in
  let at offset = committed ~offset ~covered:(mark 2) ~through () in
  let results =
    [ read log (committed ~turn_log:(log_id_of 'b') ~offset:(length + 1) ~covered:(mark 2) ~through ())
    ; read log (at (length + 1))
    ; read log (at (turn + 1))
    ; read log started_tail
    ]
  in
  check (list string) "each fault hides the ones after it"
    [ Printf.sprintf "%s replaced by %s" (String.make 32 'b') (String.make 32 'a')
    ; Printf.sprintf "offset %d lost in %d bytes" (length + 1) length
    ; Printf.sprintf "offset %d lost in %d bytes" (turn + 1) length
    ; Printf.sprintf "1 unit, then line %d is not JSON" undecodable
    ]
    (List.map
       (function
         | Ok (reading : Unread.reading) ->
           Printf.sprintf "%d unit, then %s" (List.length reading.spans) (stop_text reading.stop)
         | Error error -> error_text error)
       results);
  let no_start = new_log () in
  Unix.mkdir (Filename.dirname no_start.path) 0o700;
  write_raw no_start "not json\n";
  let no_start_result = read no_start started_tail in
  check string "a file whose first line starts no log"
    (Printf.sprintf "%s replaced by a file with no log start" (String.make 32 'a'))
    (match no_start_result with
     | Ok reading -> String.concat "\n" (reading_lines reading)
     | Error error -> error_text error);
  check (list bool) "each of them is something unread" [ true; true; true; true; true ]
    (List.map Unread.has_unread (results @ [ no_start_result ]))
;;

(* §5.3, §9.2: a unit with no item is not asked on its own. It is read
   with the next unit that has items, and before an unannounced reset it is
   read with the skip of that reset. *)
let test_unit_with_no_item () =
  let log = new_log () in
  let (_ : int) = append log started in
  let empty_reset = append log (announced (mark 1) (cleared 1)) in
  let empty_reset_text =
    Printf.sprintf "reset at %d: files history 10-10 internal 20-20 chat 30-30 external 1-1; next 0/10"
      empty_reset
  in
  let alone = read_ok log started_tail in
  check (list string) "a reset that closed nothing" [ empty_reset_text; "log end" ] (reading_lines alone);
  check bool "is nothing to ask" false (Unread.has_unread (Ok alone));
  let turn = append log (opened (cleared 1)) in
  let (_ : int) = append log (closed ~own:[ slice 0 1 ] turn (mark 2)) in
  let with_turn = read_ok ~until:(First_with_items 1) log started_tail in
  check (list string) "with the turn after it"
    [ "reset"; "turn"; "limit reached" ]
    (List.map
       (fun (span : Unread.span) ->
          match span.source with
          | Turn _ -> "turn"
          | Announced_reset _ -> "reset")
       with_turn.spans
     @ [ stop_text with_turn.stop ]);
  check bool "it is something to ask" true (Unread.has_unread (Ok with_turn));
  let after_commit = read_ok log (committed_through (last_span with_turn)) in
  check (list string) "one commit passes both" [ "log end" ] (reading_lines after_commit);
  check bool "and leaves nothing unread" false (Unread.has_unread (Ok after_commit));
  let second_empty = append log (announced (mark 2) (cleared 2)) in
  let unannounced_at = append log (unannounced (cleared 2) { (cleared 2) with trace = "session-2" }) in
  let before_unannounced = read_ok log (committed_through (last_span with_turn)) in
  check (list string) "before an unannounced reset"
    [ Printf.sprintf
        "reset at %d: files history 20-20 internal 40-40 chat 60-60 external 2-2; next 0/20"
        second_empty
    ; Printf.sprintf "unannounced reset at %d, read on from %d" unannounced_at log.rows_end
    ]
    (reading_lines before_unannounced);
  check bool "it is read with the skip of that reset" true (Unread.has_unread (Ok before_unannounced))
;;

(* §5.4, §9.2: reading that starts inside a turn reads that turn's lines
   again from its [Opened], so the turn splits as the first reading split
   it: all unattributed after a reset, at the baseline without one. *)
let test_reading_that_starts_inside_a_turn () =
  let log = new_log () in
  let (_ : int) = append log started in
  let first = append log (opened (mark 1)) in
  let (_ : int) = append log (announced ~closed_before:[ slice 0 1 ] (mark 2) (cleared 2)) in
  let (_ : int) = append log (closed ~unattributed:[ slice 0 2 ] first (mark 3)) in
  let second = append log (opened (mark 4)) in
  let (_ : int) = append log (closed ~unattributed:[ slice 2 1 ] ~own:[ slice 3 1 ] second (mark 5)) in
  let reading = read_ok log started_tail in
  let reset_span, first_span, second_span =
    match reading.spans with
    | [ reset_span; first_span; second_span ] -> reset_span, first_span, second_span
    | spans -> failf "expected three units, read %d" (List.length spans)
  in
  check (list string) "from the first turn's line, after the reset inside it was read"
    (List.map span_text [ first_span; second_span ] @ [ "log end" ])
    (reading_lines (read_ok log (committed_through reset_span)));
  check (list string) "from the second turn's line, its first item read"
    [ span_text second_span; "log end" ]
    (reading_lines (read_ok log (committed_inside ~starts_at:first_span.next second_span)));
  check string "the first reading split the turn with a reset in it as no turn's"
    (Printf.sprintf
       "turn %d closed at %d: unattributed checkpoint [0+2] chat 60-90 external 2-3; own files \
        history 30-30 internal 60-60 chat 90-90 external 3-3; next 3/30"
       first first_span.line)
    (span_text first_span)
;;

(* §5.2, §5.3: a reset written when the head moved to another session keeps
   the other stores where the last line left them. The unit after it holds
   the new session's official-client files from their first byte. *)
let test_unit_after_a_session_change () =
  let log = new_log () in
  let (_ : int) = append log started in
  let first = append log (opened (mark 1)) in
  let (_ : int) = append log (closed ~own:[ slice 0 1 ] first (mark 2)) in
  let first_unit = last_span (read_ok log started_tail) in
  let moved = { (mark 2) with trace = "session-2"; closed_messages = 0 } in
  let reset = append log (unannounced (mark 2) moved) in
  let in_session_2 n ~history =
    { (mark ~session:"session-2" n) with history_bytes = history; internal_bytes = history + 2 }
  in
  let second = append log (opened (in_session_2 3 ~history:5)) in
  let second_closed = append log (closed ~own:[ slice 0 1 ] second (in_session_2 4 ~history:15)) in
  let stopped = read_ok log (committed_through first_unit) in
  check (list string) "reading stops at the reset"
    [ Printf.sprintf "unannounced reset at %d, read on from %d" reset second ]
    (reading_lines stopped);
  let skipped =
    committed ~offset:second ~covered:moved ~through:(Through { line = reset; within = Whole }) ()
  in
  check (list string) "the next turn holds the new session's files from their start"
    [ Printf.sprintf
        "turn %d closed at %d: unattributed files history 0-5 internal 0-7 chat 60-90 external 2-3; \
         own checkpoint [0+1] chat 90-120 external 3-4; next 4/15"
        second second_closed
    ; "log end"
    ]
    (reading_lines (read_ok log skipped))
;;

(* §16, F10: whether ten lines or a hundred thousand come before them, a
   read goes through the new lines and no other. The lines before do not
   decode, so a reader that went through them would stop there. A [Closed]
   names its [Opened] by offset, so the new lines are longer after the
   longer prefix. *)
let test_cost_follows_the_new_lines () =
  let reading_after lines_before =
    let log = new_log () in
    let (_ : int) = append log started in
    write_raw log (String.concat "" (List.init lines_before (fun (_ : int) -> "x\n")));
    let offset = log.rows_end in
    let turn = append log (opened (mark 1)) in
    let (_ : int) = append log (closed ~own:[ slice 0 1 ] turn (mark 2)) in
    let tail =
      committed ~offset ~covered:(mark 1) ~through:(Through { line = offset - 2; within = Whole }) ()
    in
    let reading = read_ok log tail in
    reading_lines ~base:offset reading, reading.bytes, log.rows_end - offset
  in
  let few, few_read, few_new = reading_after 10 in
  let many, many_read, many_new = reading_after 100_000 in
  check (list string) "the same units" few many;
  check int "after ten lines, the new lines are read" few_new few_read;
  check int "after a hundred thousand, the new lines are read" many_new many_read
;;

let () =
  run "librarian_unread"
    [ ( "units"
      , [ test_case "where each unit starts and ends" `Quick test_unit_boundaries
        ; test_case "a unit with no item" `Quick test_unit_with_no_item
        ; test_case "reading that starts inside a turn" `Quick test_reading_that_starts_inside_a_turn
        ; test_case "a unit after a session change" `Quick test_unit_after_a_session_change
        ] )
    ; "faults", [ test_case "in the order the reader looks" `Quick test_faults_in_order ]
    ; "cost", [ test_case "follows the new lines" `Quick test_cost_follows_the_new_lines ]
    ]
;;
