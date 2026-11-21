(* A Keeper's Memory writer as its memory-health row carries it under
   [writer], and the words the Memory screen draws for it (RFC
   librarian-call-only-proposes §12.1, §12.3). Each constructor has a case
   that decodes it, and a token this build does not know fails the decode. *)

open Alcotest
open Masc.Tui_decode_memory_writer
module Level = Masc.Librarian_level
module Text = Masc_tui_memory_writer

let obj fields : Yojson.Safe.t = `Assoc fields
let str value : Yojson.Safe.t = `String value
let strs values : Yojson.Safe.t = `List (List.map str values)

(* The fields a made writer carries on an open store and a stopped one. *)
let kept_wire ?(lane = true) ?(last_read = `Null) ?(last_room = `Null) ?(read_alone = false) () =
  [ "lane", `Bool lane; "last_read", last_read; "last_room", last_room; "read_alone", `Bool read_alone ]
;;

let last_line_at = 1_700_000_000.

let open_wire
      ?(state = "idle")
      ?(level = "ok")
      ?(alarms = [])
      ?(unread = false)
      ?(asking = `Null)
      ?(last_line = [ "last_line", str "started" ])
      ?(covers_through = str "before_first")
      ?(kept = kept_wire ())
      ()
  =
  obj
    ([ "state", str state
     ; "level", str level
     ; "alarms", strs alarms
     ; "unread", `Bool unread
     ; "asking", asking
     ]
     @ kept
     @ last_line
     @ [ "last_line_at", `Float last_line_at
       ; "turn_log", str "log-1"
       ; "covers_through", covers_through
       ; "memory", obj [ "snapshot", str "sha-memory"; "facts", `Int 3 ]
       ])
;;

let stopped_wire ?(stop = "store_stopped_log_diverged") ?(unread = `Null) snapshot_file =
  obj
    ([ "state", str "stopped"
     ; "level", str "error"
     ; "alarms", strs [ "E1" ]
     ; "unread", unread
     ; "asking", `Null
     ]
     @ kept_wire ()
     @ [ "stop", str stop; "snapshot_file", snapshot_file ])
;;

let member row = obj [ "kind", str "writer"; "row", row ]

let kept ?(lane = true) ?last_read ?last_room ?(read_alone = false) () =
  { lane; last_read; last_room; read_alone }
;;

let open_row
      ?(activity = Idle)
      ?(unread = false)
      ?(kept = kept ())
      ?(last_line = Line_started)
      ?(covers_through = Before_first)
      ()
  =
  Open
    { activity
    ; unread
    ; kept
    ; last_line
    ; last_line_at
    ; turn_log = "log-1"
    ; covers_through
    ; snapshot = "sha-memory"
    ; facts = 3
    }
;;

let shown ?(level = Level.Ok) ?(alarms = []) row = Writer { level; alarms; row }

let decoded : (t, string) result testable =
  result (testable (fun ppf (_ : t) -> Format.pp_print_string ppf "<writer>") ( = )) string
;;

let reads name wire expected = check decoded name (Ok expected) (decode wire)

let refuses name wire =
  check bool name true
    (match decode wire with
     | Error (_ : string) -> true
     | Ok (_ : t) -> false)
;;

let test_kinds () =
  reads "a process that runs no writer" (obj [ "kind", str "none_in_process" ]) None_in_process;
  reads "a Keeper outside the registry" (obj [ "kind", str "no_writer" ]) No_writer;
  reads "a made writer" (member (open_wire ())) (shown (open_row ()));
  refuses "a kind this build does not know" (obj [ "kind", str "later" ]);
  refuses "a row on a Keeper without a writer" (obj [ "kind", str "no_writer"; "row", open_wire () ]);
  refuses "a writer without its row" (obj [ "kind", str "writer" ])
;;

let test_booting_and_retired () =
  reads "a writer that has not read its tail"
    (member (obj [ "state", str "booting"; "level", str "warn"; "alarms", strs [ "W1" ]; "unread", `Null ]))
    (shown ~level:Level.Warn ~alarms:[ Level.W1 ] Booting);
  reads "a retired writer"
    (member (obj [ "state", str "retired"; "level", str "ok"; "alarms", strs [] ]))
    (shown Retired);
  refuses "a booting writer that says what is unread"
    (member
       (obj [ "state", str "booting"; "level", str "warn"; "alarms", strs [ "W1" ]; "unread", `Bool true ]));
  refuses "a state this build does not know" (member (open_wire ~state:"paused" ()))
;;

let asking_wire asked = obj [ "ask", `Int 7; "since", `Float 1_700_000_100.; "asked", str asked ]

let test_activities () =
  reads "idle" (member (open_wire ())) (shown (open_row ()));
  reads "resting" (member (open_wire ~state:"resting" ())) (shown (open_row ~activity:Resting ()));
  reads "refused at the bottom"
    (member (open_wire ~state:"refused_at_bottom" ~level:"error" ~alarms:[ "E2" ] ()))
    (shown ~level:Level.Error ~alarms:[ Level.E2 ] (open_row ~activity:Refused_at_bottom ()));
  List.iter
    (fun (token, asked) ->
       reads ("asking " ^ token)
         (member (open_wire ~state:"asking" ~asking:(asking_wire token) ()))
         (shown (open_row ~activity:(Asking { ask = 7; since = 1_700_000_100.; asked }) ())))
    [ "range", Asked_range; "item_alone", Asked_item_alone; "room", Asked_room ];
  refuses "a question this build does not know"
    (member (open_wire ~state:"asking" ~asking:(asking_wire "summary") ()));
  refuses "an asking writer that names no ask" (member (open_wire ~state:"asking" ()));
  refuses "an idle writer that names an ask" (member (open_wire ~asking:(asking_wire "range") ()))
;;

let slot_outcomes =
  [ "input_too_large", Input_too_large
  ; "output_over_reserve", Output_over_reserve
  ; "window_reached", Window_reached
  ; "refused", Refused
  ; "not_called", Not_called
  ; "unavailable", Unavailable
  ; "busy", Busy
  ; "lost", Lost
  ; "unusable", Unusable
  ]
;;

let lane_wire slots =
  obj
    [ "ended", str "lane"
    ; "one_item", `Bool true
    ; "silent", `Bool false
    ; "about_memory_now", `Bool true
    ; ( "slots"
      , `List (List.map (fun (slot, outcome) -> obj [ "slot", str slot; "outcome", str outcome ]) slots) )
    ]
;;

let input_faults =
  [ obj [ "kind", str "line_unreadable"; "offset", `Int 120 ], Line_unreadable { offset = 120 }
  ; ( obj [ "kind", str "turn_log_replaced"; "expected", str "log-1"; "observed", str "log-2" ]
    , Turn_log_replaced { expected = "log-1"; observed = Some "log-2" } )
  ; ( obj [ "kind", str "turn_log_replaced"; "expected", str "log-1"; "observed", `Null ]
    , Turn_log_replaced { expected = "log-1"; observed = None } )
  ; ( obj [ "kind", str "position_lost"; "offset", `Int 900; "length", `Int 400 ]
    , Position_lost { offset = 900; length = 400 } )
  ; obj [ "kind", str "content_unreadable"; "line", `Int 14 ], Content_unreadable { line = 14 }
  ]
;;

let ask_failures = [ "raised", Raised; "flow_stopped", Flow_stopped; "read_failed", Read_failed ]

let reads_last_read name wire expected =
  reads name
    (member (open_wire ~kept:(kept_wire ~last_read:wire ()) ()))
    (shown (open_row ~kept:(kept ~last_read:expected ()) ()))
;;

let test_last_read () =
  reads "no reading ask ended since the boot" (member (open_wire ())) (shown (open_row ()));
  reads_last_read "committed" (obj [ "ended", str "committed" ]) Read_committed;
  reads_last_read "no slot answered"
    (lane_wire (List.map (fun (token, (_ : slot_outcome)) -> "slot." ^ token, token) slot_outcomes))
    (Read_lane
       { one_item = true
       ; silent = false
       ; about_memory_now = true
       ; slots = List.map (fun (token, outcome) -> "slot." ^ token, outcome) slot_outcomes
       });
  List.iter
    (fun (wire, fault) ->
       reads_last_read "an input fault" (obj [ "ended", str "input_fault"; "fault", wire ]) (Read_input_fault fault))
    input_faults;
  List.iter
    (fun (token, failure) ->
       reads_last_read ("the ask failed: " ^ token)
         (obj [ "ended", str "ask_failed"; "failed", str token ])
         (Read_ask_failed failure))
    ask_failures;
  let refuses_last_read name wire =
    refuses name (member (open_wire ~kept:(kept_wire ~last_read:wire ()) ()))
  in
  refuses_last_read "an ending this build does not know" (obj [ "ended", str "skipped" ]);
  refuses_last_read "a slot outcome this build does not know" (lane_wire [ "slot.a", "throttled" ]);
  refuses_last_read "an input fault this build does not know"
    (obj [ "ended", str "input_fault"; "fault", obj [ "kind", str "line_too_long" ] ]);
  refuses_last_read "an ask failure this build does not know"
    (obj [ "ended", str "ask_failed"; "failed", str "timed_out" ])
;;

let test_last_room () =
  let reads_last_room name wire expected =
    reads name
      (member (open_wire ~kept:(kept_wire ~last_room:wire ()) ()))
      (shown (open_row ~kept:(kept ~last_room:expected ()) ()))
  in
  List.iter
    (fun (token, room) -> reads_last_room token (obj [ "ended", str token ]) room)
    [ "made", Room_made; "unchanged", Room_unchanged; "stale", Room_stale; "not_judged", Room_not_judged ];
  reads_last_room "fits none"
    (obj [ "ended", str "fits_none"; "about_memory_now", `Bool true; "about_lane_now", `Bool false ])
    (Room_fits_none { about_memory_now = true; about_lane_now = false });
  refuses "a room ending this build does not know"
    (member (open_wire ~kept:(kept_wire ~last_room:(obj [ "ended", str "deferred" ]) ()) ()))
;;

let test_where_reading_stands () =
  reads "a commit as the last line"
    (member (open_wire ~last_line:[ "last_line", str "commit"; "last_seq", `Int 12 ] ()))
    (shown (open_row ~last_line:(Line_commit { seq = 12 }) ()));
  reads "read through a whole unit"
    (member (open_wire ~covers_through:(obj [ "line", `Int 40; "within", str "whole" ]) ()))
    (shown (open_row ~covers_through:(Through { line = 40; within_item = false }) ()));
  reads "read part of a unit"
    (member (open_wire ~covers_through:(obj [ "line", `Int 41; "within", str "item" ]) ()))
    (shown (open_row ~covers_through:(Through { line = 41; within_item = true }) ()));
  refuses "a last line this build does not know"
    (member (open_wire ~last_line:[ "last_line", str "rewound" ] ()));
  refuses "a commit without its number" (member (open_wire ~last_line:[ "last_line", str "commit" ] ()));
  refuses "a start line that carries a number"
    (member (open_wire ~last_line:[ "last_line", str "started"; "last_seq", `Int 1 ] ()));
  refuses "a position this build does not know"
    (member (open_wire ~covers_through:(obj [ "line", `Int 40; "within", str "half" ]) ()));
  refuses "a position that is another word" (member (open_wire ~covers_through:(str "after_last") ()))
;;

let stops =
  [ "store_stopped_log_diverged", Log_diverged
  ; "store_stopped_memory_unreadable", Memory_unreadable
  ; "store_stopped_log_unreadable", Log_unreadable
  ; "store_stopped_store_unwritable", Store_unwritable
  ; "store_stopped_raised", Store_raised
  ]
;;

let snapshot_files =
  [ obj [ "sha", str "sha-file"; "bytes", `Int 2048 ], File { sha = "sha-file"; bytes = 2048 }
  ; obj [ "fault", str "absent" ], File_absent
  ; obj [ "fault", str "not_a_snapshot_file" ], File_not_a_snapshot
  ; obj [ "fault", str "not_read" ], File_not_read
  ]
;;

let test_stopped () =
  let stopped stop snapshot_file =
    shown ~level:Level.Error ~alarms:[ Level.E1 ] (Stopped { stop; snapshot_file; kept = kept () })
  in
  List.iter
    (fun (token, stop) ->
       reads token
         (member (stopped_wire ~stop:token (obj [ "fault", str "absent" ])))
         (stopped stop File_absent))
    stops;
  List.iter
    (fun (wire, file) -> reads "the snapshot file on disk" (member (stopped_wire wire)) (stopped Log_diverged file))
    snapshot_files;
  refuses "a stop this build does not know"
    (member (stopped_wire ~stop:"store_stopped_disk_full" (obj [ "fault", str "absent" ])));
  refuses "a snapshot file fault this build does not know"
    (member (stopped_wire (obj [ "fault", str "locked" ])));
  refuses "a stopped store that says what is unread"
    (member (stopped_wire ~unread:(`Bool true) (obj [ "fault", str "absent" ])))
;;

let alarm_tokens =
  [ "E1", Level.E1
  ; "E2", Level.E2
  ; "E3", Level.E3
  ; "E4", Level.E4
  ; "E5", Level.E5
  ; "W1", Level.W1
  ; "W3", Level.W3
  ]
;;

let test_alarms_and_level () =
  reads "every alarm"
    (member (open_wire ~level:"error" ~alarms:(List.map fst alarm_tokens) ()))
    (shown ~level:Level.Error ~alarms:(List.map snd alarm_tokens) (open_row ()));
  reads "warnings alone are a warning"
    (member (open_wire ~level:"warn" ~alarms:[ "W1"; "W3" ] ()))
    (shown ~level:Level.Warn ~alarms:[ Level.W1; Level.W3 ] (open_row ()));
  refuses "an alarm this build does not know" (member (open_wire ~level:"warn" ~alarms:[ "W2" ] ()));
  refuses "a level this build does not know" (member (open_wire ~level:"fine" ()));
  refuses "a level that is not the level of its alarms"
    (member (open_wire ~level:"ok" ~alarms:[ "E3" ] ()));
  refuses "a field this build does not know"
    (match open_wire () with
     | `Assoc fields -> member (`Assoc (fields @ [ "waiting_for_seat", `Bool true ]))
     | other -> other)
;;

(* One sentence for each constructor, in both languages, and no two
   constructors of a type share theirs. *)
let each_has_its_own name texts =
  List.iter (fun text -> check bool (name ^ ": not empty") false (String.equal text "")) texts;
  check int (name ^ ": one sentence each") (List.length texts)
    (List.length (List.sort_uniq String.compare texts))
;;

let test_every_constructor_has_its_words () =
  List.iter
    (fun ko ->
       let lang = if ko then "ko " else "en " in
       each_has_its_own (lang ^ "level")
         (List.map (Text.level_text ~ko) [ Level.Ok; Level.Warn; Level.Error ]);
       each_has_its_own (lang ^ "alarm") (List.map (fun (_, alarm) -> Text.alarm_text ~ko alarm) alarm_tokens);
       each_has_its_own (lang ^ "state")
         (List.map (Text.state_text ~ko)
            ([ Booting; Retired ]
             @ List.map
                 (fun activity -> open_row ~activity ())
                 [ Idle
                 ; Resting
                 ; Refused_at_bottom
                 ; Asking { ask = 1; since = 0.; asked = Asked_range }
                 ; Asking { ask = 1; since = 0.; asked = Asked_item_alone }
                 ; Asking { ask = 1; since = 0.; asked = Asked_room }
                 ]
             @ List.map
                 (fun (_, stop) -> Stopped { stop; snapshot_file = File_absent; kept = kept () })
                 stops));
       each_has_its_own (lang ^ "slot outcome")
         (List.map (fun (_, outcome) -> Text.slot_outcome_text ~ko outcome) slot_outcomes);
       each_has_its_own (lang ^ "input fault")
         (List.map (fun (_, fault) -> Text.input_fault_text ~ko fault) input_faults);
       each_has_its_own (lang ^ "ask failure")
         (List.map (fun (_, failure) -> Text.ask_failure_text ~ko failure) ask_failures);
       each_has_its_own (lang ^ "last read")
         (List.map (Text.last_read_text ~ko)
            [ None
            ; Some Read_committed
            ; Some (Read_lane { one_item = false; silent = false; about_memory_now = true; slots = [] })
            ; Some (Read_input_fault (Line_unreadable { offset = 1 }))
            ; Some (Read_ask_failed Raised)
            ]);
       each_has_its_own (lang ^ "last room")
         (List.map (Text.last_room_text ~ko)
            [ None
            ; Some Room_made
            ; Some Room_unchanged
            ; Some Room_stale
            ; Some Room_not_judged
            ; Some (Room_fits_none { about_memory_now = true; about_lane_now = true })
            ]);
       each_has_its_own (lang ^ "position")
         (List.map (Text.position_text ~ko)
            [ Before_first
            ; Through { line = 4; within_item = false }
            ; Through { line = 4; within_item = true }
            ]);
       each_has_its_own (lang ^ "last line")
         (List.map (Text.last_line_text ~ko) [ Line_started; Line_commit { seq = 4 } ]);
       each_has_its_own (lang ^ "snapshot file")
         (List.map (fun (_, file) -> Text.snapshot_file_text ~ko file) snapshot_files);
       each_has_its_own (lang ^ "unread")
         (List.filter_map (Text.unread_text ~ko)
            [ Booting
            ; open_row ~unread:true ()
            ; open_row ~unread:false ()
            ; Stopped { stop = Log_diverged; snapshot_file = File_absent; kept = kept () }
            ]);
       check (option string) (lang ^ "a retired writer reads nothing more") None (Text.unread_text ~ko Retired))
    [ true; false ]
;;

let booting = shown ~level:Level.Warn ~alarms:[ Level.W1 ] Booting

let tones rows =
  List.map
    (fun ((tone : Text.tone), (_ : string)) ->
       match tone with
       | Text.Tone_warn -> "warn"
       | Text.Tone_error -> "error")
    rows
;;

(* A process that runs no writer and a writer that has not started are two
   readings: the first is not a writer on its way. *)
let test_no_writer_in_the_process_is_not_a_starting_writer () =
  check (list string) "the process runs none" [ "서버가 띄우지 않음" ] (Text.card_clauses ~ko:true None_in_process);
  check (list string) "the writer is starting" [ "시작 중"; "안 읽은 것은 시작이 끝나야 앎" ]
    (Text.card_clauses ~ko:true booting);
  check (list string) "in English too" [ "not started by the server" ]
    (Text.card_clauses ~ko:false None_in_process);
  check (list string) "starting, in English" [ "starting"; "unread is known once it has started" ]
    (Text.card_clauses ~ko:false booting);
  check (list (pair string string)) "a process without writers asks for a look"
    [ "warn", "기억 쓰는 쪽 · 서버가 띄우지 않음" ]
    (List.combine (tones (Text.attention_rows ~ko:true None_in_process))
       (List.map snd (Text.attention_rows ~ko:true None_in_process)));
  check (list string) "a starting writer shows its alarm" [ "warn" ] (tones (Text.attention_rows ~ko:true booting))
;;

let test_attention_rows () =
  check (list string) "a Keeper without a writer asks for none" [] (tones (Text.attention_rows ~ko:true No_writer));
  check (list string) "a writer with no alarm asks for none" []
    (tones (Text.attention_rows ~ko:true (shown (open_row ()))));
  check (list string) "one row for each alarm, in the alarm's tone" [ "error"; "warn"; "warn" ]
    (tones
       (Text.attention_rows ~ko:true
          (shown ~level:Level.Error ~alarms:[ Level.E3; Level.W1; Level.W3 ] (open_row ~unread:true ()))));
  List.iter
    (fun ko ->
       List.iter
         (fun ((_ : Text.tone), row) ->
            check bool "each row names the writer" true
              (String.starts_with ~prefix:(Text.heading ~ko) row))
         (Text.attention_rows ~ko (shown ~level:Level.Error ~alarms:(List.map snd alarm_tokens) (open_row ()))))
    [ true; false ]
;;

let moment at = Printf.sprintf "t%.0f" at

let test_detail_rows () =
  check (list (list string)) "a process without writers" [ [ "Memory writer"; "not started by the server" ] ]
    (Text.detail_rows ~ko:false ~moment None_in_process);
  check (list (list string)) "a Keeper without a writer"
    [ [ "기억 쓰는 쪽"; "없음 · 등록되지 않은 Keeper" ] ]
    (Text.detail_rows ~ko:true ~moment No_writer);
  check (list (list string)) "a starting writer: its state and its alarm"
    [ [ "Memory writer"; "warn"; "starting"; "unread is known once it has started" ]
    ; [ "Memory writer alarm"; Text.alarm_text ~ko:false Level.W1 ]
    ]
    (Text.detail_rows ~ko:false ~moment booting);
  check (list (list string)) "an idle writer: state, last asks, where reading stands"
    [ [ "Memory writer"; "ok"; "idle"; "nothing unread" ]
    ; [ "Memory writer last read"; "committed" ]
    ; [ "Memory writer last room ask"; "none ended since the start" ]
    ; [ "Memory writer reading stands"
      ; "read through turn log line 40"
      ; "commit #12 t1700000000"
      ; "3 facts"
      ; "snapshot " ^ Masc_tui_value.Hash.short "sha-memory"
      ; "turn log log-1"
      ]
    ]
    (Text.detail_rows ~ko:false ~moment
       (shown
          (open_row
             ~kept:(kept ~last_read:Read_committed ())
             ~last_line:(Line_commit { seq = 12 })
             ~covers_through:(Through { line = 40; within_item = false })
             ())));
  check (list (list string)) "a resting writer without a lane value names every slot's outcome"
    [ [ "기억 쓰는 쪽"; "오류"; "쉼 · 다음 pulse 에 다시 물음"; "안 읽은 것 있음"; "lane 값 없음" ]
    ; [ "기억 쓰는 쪽 경보"; Text.alarm_text ~ko:true Level.E4 ]
    ; [ "기억 쓰는 쪽 마지막 읽기"
      ; "답한 slot 없음"
      ; "항목 하나를 물음"
      ; "그 뒤 Memory 가 바뀜"
      ; "slot.a 크기 사실 없이 거절"
      ; "slot.b 바쁨"
      ]
    ; [ "기억 쓰는 쪽 마지막 자리 내기"; "시작 뒤 끝난 것 없음" ]
    ; [ "기억 쓰는 쪽 읽은 자리"
      ; "아직 읽은 것 없음"
      ; "시작 줄 t1700000000"
      ; "fact 3개"
      ; "스냅샷 " ^ Masc_tui_value.Hash.short "sha-memory"
      ; "턴 기록 log-1"
      ]
    ]
    (Text.detail_rows ~ko:true ~moment
       (shown ~level:Level.Error ~alarms:[ Level.E4 ]
          (open_row ~activity:Resting ~unread:true
             ~kept:
               (kept ~lane:false
                  ~last_read:
                    (Read_lane
                       { one_item = true
                       ; silent = false
                       ; about_memory_now = false
                       ; slots = [ "slot.a", Refused; "slot.b", Busy ]
                       })
                  ())
             ())));
  check (list (list string)) "a stopped store: why, and the snapshot file an adoption names"
    [ [ "Memory writer"
      ; "error"
      ; "stopped · the commit log does not read"
      ; "unread cannot be told while stopped"
      ]
    ; [ "Memory writer alarm"; Text.alarm_text ~ko:false Level.E1 ]
    ; [ "Memory writer snapshot file"; "sha " ^ Masc_tui_value.Hash.short "sha-file" ^ " · " ^ Masc_tui_value.Count.grouped 2048 ^ " B" ]
    ; [ "Memory writer last read"; "none ended since the start" ]
    ; [ "Memory writer last room ask"; "none ended since the start" ]
    ]
    (Text.detail_rows ~ko:false ~moment
       (shown ~level:Level.Error ~alarms:[ Level.E1 ]
          (Stopped
             { stop = Log_unreadable
             ; snapshot_file = File { sha = "sha-file"; bytes = 2048 }
             ; kept = kept ()
             })));
  check (list (list string)) "an asking writer names the question and when it began"
    [ [ "Memory writer"; "ok"; "asking · one item alone"; "unread" ]
    ; [ "Memory writer asking"; "one item alone"; "since t1700000100"; "ask #7" ]
    ; [ "Memory writer last read"; "input fault"; "a turn log line does not parse (offset 120)" ]
    ; [ "Memory writer last room ask"; "made room" ]
    ; [ "Memory writer reading stands"
      ; "reading the unit at turn log line 41"
      ; "start line t1700000000"
      ; "3 facts"
      ; "snapshot " ^ Masc_tui_value.Hash.short "sha-memory"
      ; "turn log log-1"
      ]
    ]
    (Text.detail_rows ~ko:false ~moment
       (shown
          (open_row
             ~activity:(Asking { ask = 7; since = 1_700_000_100.; asked = Asked_item_alone })
             ~unread:true
             ~kept:
               (kept
                  ~last_read:(Read_input_fault (Line_unreadable { offset = 120 }))
                  ~last_room:Room_made
                  ())
             ~covers_through:(Through { line = 41; within_item = true })
             ())))
;;

let () =
  run "tui_memory_writer"
    [ ( "decode"
      , [ test_case "the three kinds" `Quick test_kinds
        ; test_case "booting and retired" `Quick test_booting_and_retired
        ; test_case "what an open store is doing" `Quick test_activities
        ; test_case "how the last reading ask ended" `Quick test_last_read
        ; test_case "how the last room ask ended" `Quick test_last_room
        ; test_case "where reading stands" `Quick test_where_reading_stands
        ; test_case "a stopped store" `Quick test_stopped
        ; test_case "alarms and their level" `Quick test_alarms_and_level
        ] )
    ; ( "words"
      , [ test_case "every constructor has its words" `Quick test_every_constructor_has_its_words
        ; test_case "no writer in the process is not a starting writer" `Quick
            test_no_writer_in_the_process_is_not_a_starting_writer
        ; test_case "rows that ask for a look" `Quick test_attention_rows
        ; test_case "every reading in the detail" `Quick test_detail_rows
        ] )
    ]
;;
