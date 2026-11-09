(* The wakes a page of a Keeper's schedule rows gives, and the order the story
   page's past group tells them in beside the Keeper's turns and its last digest
   (RFC-0515 section 2.5). The screen text is not tested; which wakes the page
   lets the story page call the newest, and the order of the events, are. *)

let make_row ?wake_started_at_iso id : Masc_tui_types.schedule_row =
  { sch_schedule_id = id
  ; sch_schedule_instance_id = "inst-" ^ id
  ; sch_status = "scheduled"
  ; sch_source = "operator_request"
  ; sch_requested_by = "operator"
  ; sch_scheduled_by = "operator"
  ; sch_requested_at_iso = "2026-11-07T00:00:00Z"
  ; sch_due_at_iso = None
  ; sch_next_due_at_iso = None
  ; sch_expires_at_iso = None
  ; sch_recurrence_summary = ""
  ; sch_recurrence = `Assoc []
  ; sch_payload_digest = "digest"
  ; sch_payload = `Assoc []
  ; sch_payload_kind = None
  ; sch_payload_support = "supported"
  ; sch_payload_dispatch_tool = None
  ; sch_payload_target = None
  ; sch_payload_keeper_name = None
  ; sch_payload_summary = None
  ; sch_last_wake_status =
      Option.map (fun _ -> Schedule_contract_values.Wake_succeeded) wake_started_at_iso
  ; sch_last_wake_started_at_iso = wake_started_at_iso
  ; sch_last_wake_error = None
  ; sch_queue_projection_status = None
  ; sch_queue_pending_count = None
  ; sch_reaction_projection_status = None
  ; sch_reaction_latest_at_iso = None
  ; sch_reaction_kind = None
  ; sch_reaction_keeper_name = None
  ; sch_reaction_stimulus_id = None
  ; sch_reaction_post_id = None
  ; sch_reaction_reason = None
  ; sch_wake_seen = None
  ; sch_turn_started = None
  ; sch_turn_finished = None
  ; sch_queue_ack_seen = None
  ; sch_wake_cancelled = None
  ; sch_stimulus_recorded_at_iso = None
  ; sch_turn_started_recorded_at_iso = None
  ; sch_turn_finished_recorded_at_iso = None
  ; sch_queue_ack_recorded_at_iso = None
  ; sch_wake_cancelled_recorded_at_iso = None
  ; sch_reaction_quarantined = None
  ; sch_occurrence =
      { Masc.Tui_schedule_observation.stage = Masc.Tui_schedule_observation.No_occurrence
      ; due_at_iso = None
      }
  ; sch_runner_hold = None
  }
;;

(* {1 The wakes of a page} *)

let schedule_id wake = (Masc_tui_keeper_wakes.row wake).Masc_tui_types.sch_schedule_id

let describe = function
  | Masc_tui_keeper_wakes.Wakes { newest_first; coverage } ->
      let coverage =
        match coverage with
        | Masc_tui_keeper_wakes.Whole_page -> "whole"
        | Masc_tui_keeper_wakes.First_page -> "first page"
      in
      Printf.sprintf "%s [%s]" coverage (String.concat " " (List.map schedule_id newest_first))
  | Masc_tui_keeper_wakes.Unplaced -> "unplaced"
;;

let reading ?(truncated = false) rows =
  describe (Masc_tui_keeper_wakes.of_page ~truncated rows)
;;

let test_no_rows () =
  Alcotest.check Alcotest.string "no rows, no wake" "whole []" (reading [])
;;

let test_rows_without_a_wake () =
  Alcotest.check Alcotest.string "rows that never woke are not candidates" "whole []"
    (reading [ make_row "a"; make_row "b" ])
;;

let test_wakes_come_newest_first_wherever_they_sit () =
  Alcotest.check Alcotest.string "the later wake leads, rows without a wake are left out"
    "whole [b a]"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T10:00:00Z" "b"
       ; make_row "c"
       ]);
  Alcotest.check Alcotest.string "every wake the page holds is kept" "whole [b c a]"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T11:00:00Z" "b"
       ; make_row ~wake_started_at_iso:"2026-11-07T10:00:00Z" "c"
       ])
;;

let test_equal_instants_keep_row_order () =
  Alcotest.check Alcotest.string "on a tie the server's order decides" "whole [a b]"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "b"
       ])
;;

let test_offsets_compare_as_instants () =
  (* 10:00+09:00 is 01:00Z, earlier than 02:00Z although its text sorts later. *)
  Alcotest.check Alcotest.string "instants, not text" "whole [utc seoul]"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T10:00:00+09:00" "seoul"
       ; make_row ~wake_started_at_iso:"2026-11-07T02:00:00Z" "utc"
       ])
;;

let test_unreadable_time_leaves_the_newest_wakes_unknown () =
  (* The wake with the unreadable time may be among the newest, so the readable
     one beside it cannot be called the newest. *)
  Alcotest.check Alcotest.string "a wake without a readable time cannot be placed" "unplaced"
    (reading
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"zzz" "b"
       ]);
  Alcotest.check Alcotest.string "an unreadable time alone is not a wake of no time"
    "unplaced"
    (reading [ make_row ~wake_started_at_iso:"zzz" "b" ]);
  Alcotest.check Alcotest.string "a status without a start time is a wake too" "unplaced"
    (reading
       [ { (make_row "r") with
           sch_last_wake_status = Some Schedule_contract_values.Wake_running
         }
       ])
;;

let test_a_cut_page_says_so () =
  Alcotest.check Alcotest.string "a cut page with no wake leaves a later page open"
    "first page []"
    (reading ~truncated:true [ make_row "a" ]);
  Alcotest.check Alcotest.string
    "the wakes of a cut page are the first page's, not the Keeper's newest"
    "first page [b a]"
    (reading ~truncated:true
       [ make_row ~wake_started_at_iso:"2026-11-07T09:00:00Z" "a"
       ; make_row ~wake_started_at_iso:"2026-11-07T10:00:00Z" "b"
       ]);
  Alcotest.check Alcotest.string "an unplaced wake outranks the cut" "unplaced"
    (reading ~truncated:true [ make_row ~wake_started_at_iso:"zzz" "b" ])
;;

(* {1 The feed} *)

let seconds iso =
  match Time_codec.parse_rfc3339_opt iso with
  | Some at -> at
  | None -> Alcotest.fail ("fixture time is not RFC 3339: " ^ iso)
;;

(* A wake placed in time, made through the one door that makes them. *)
let wake_at id iso =
  match
    Masc_tui_keeper_wakes.of_page ~truncated:false
      [ make_row ~wake_started_at_iso:iso id ]
  with
  | Masc_tui_keeper_wakes.Wakes { newest_first = [ wake ]; coverage = _ } -> wake
  | Masc_tui_keeper_wakes.Wakes _ | Masc_tui_keeper_wakes.Unplaced ->
      Alcotest.fail ("fixture wake was not placed: " ^ id)
;;

let turn_at reason iso =
  { Masc_tui_keeper_turns.at = seconds iso; stop = Masc_tui_keeper_turns.Stopped reason }
;;

let name = function
  | Masc_tui_keeper_feed.Wake wake -> "wake " ^ schedule_id wake
  | Masc_tui_keeper_feed.Turn { Masc_tui_keeper_turns.stop; at = _ } ->
      (match stop with
       | Masc_tui_keeper_turns.Stopped reason -> "turn " ^ reason
       | Masc_tui_keeper_turns.No_stop_reason -> "turn without a reason")
  | Masc_tui_keeper_feed.Digest _ -> "digest"
;;

let told ~turns ~wakes ~digest_at =
  List.map name (Masc_tui_keeper_feed.of_sources ~turns ~wakes ~digest_at)
;;

let names = Alcotest.(list string)

let test_the_three_sources_come_oldest_first () =
  let items =
    Masc_tui_keeper_feed.of_sources
      ~turns:
        [ turn_at "t1" "2026-11-09T09:00:00Z"
        ; turn_at "t2" "2026-11-09T09:30:00Z"
        ; turn_at "t3" "2026-11-09T11:00:00Z"
        ]
      ~wakes:[ wake_at "w-new" "2026-11-09T10:30:00Z"; wake_at "w-old" "2026-11-09T08:00:00Z" ]
      ~digest_at:(Some (seconds "2026-11-09T10:00:00Z"))
  in
  Alcotest.check names "every source lands where its time puts it"
    [ "wake w-old"; "turn t1"; "turn t2"; "digest"; "wake w-new"; "turn t3" ]
    (List.map name items);
  let times = List.map Masc_tui_keeper_feed.at items in
  Alcotest.check Alcotest.bool "the times never go back" true
    (times = List.sort Float.compare times)
;;

let test_the_feed_reads_each_events_own_time () =
  let at = seconds "2026-11-09T09:00:00Z" in
  Alcotest.check (Alcotest.float 0.) "a wake's start" at
    (Masc_tui_keeper_feed.at (Masc_tui_keeper_feed.Wake (wake_at "w" "2026-11-09T09:00:00Z")));
  Alcotest.check (Alcotest.float 0.) "a turn's record time" at
    (Masc_tui_keeper_feed.at
       (Masc_tui_keeper_feed.Turn (turn_at "t" "2026-11-09T09:00:00Z")));
  Alcotest.check (Alcotest.float 0.) "a digest's time" at
    (Masc_tui_keeper_feed.at (Masc_tui_keeper_feed.Digest at))
;;

let test_equal_times_keep_the_order_things_happen_in () =
  let noon = "2026-11-09T12:00:00Z" in
  Alcotest.check names "a wake starts a turn and a digest follows the turns"
    [ "wake w"; "turn t"; "digest" ]
    (told ~turns:[ turn_at "t" noon ] ~wakes:[ wake_at "w" noon ]
       ~digest_at:(Some (seconds noon)));
  Alcotest.check names "events of one kind keep the order they came in"
    [ "turn first"; "turn second" ]
    (told ~turns:[ turn_at "first" noon; turn_at "second" noon ] ~wakes:[] ~digest_at:None)
;;

let test_only_the_newest_wakes_enter () =
  Alcotest.check names "the third newest is left out, the rest keep their order"
    [ "wake w2"; "wake w3" ]
    (told ~turns:[]
       ~wakes:
         [ wake_at "w3" "2026-11-09T12:00:00Z"
         ; wake_at "w2" "2026-11-09T11:00:00Z"
         ; wake_at "w1" "2026-11-09T10:00:00Z"
         ]
       ~digest_at:None)
;;

let test_no_source_no_event () =
  Alcotest.check names "nothing read, nothing told" [] (told ~turns:[] ~wakes:[] ~digest_at:None);
  Alcotest.check names "a turn without a stop reason is still a turn"
    [ "turn without a reason" ]
    (told
       ~turns:
         [ { Masc_tui_keeper_turns.at = seconds "2026-11-09T09:00:00Z"
           ; stop = Masc_tui_keeper_turns.No_stop_reason
           }
         ]
       ~wakes:[] ~digest_at:None)
;;

let () =
  Alcotest.run "tui_keeper_feed"
    [ ( "wakes of a page"
      , [ Alcotest.test_case "no rows" `Quick test_no_rows
        ; Alcotest.test_case "rows without a wake" `Quick test_rows_without_a_wake
        ; Alcotest.test_case "wakes come newest first" `Quick
            test_wakes_come_newest_first_wherever_they_sit
        ; Alcotest.test_case "tie keeps row order" `Quick test_equal_instants_keep_row_order
        ; Alcotest.test_case "offsets compare as instants" `Quick
            test_offsets_compare_as_instants
        ; Alcotest.test_case "unreadable time leaves the newest wakes unknown" `Quick
            test_unreadable_time_leaves_the_newest_wakes_unknown
        ; Alcotest.test_case "a cut page says so" `Quick test_a_cut_page_says_so
        ] )
    ; ( "feed"
      , [ Alcotest.test_case "three sources, oldest first" `Quick
            test_the_three_sources_come_oldest_first
        ; Alcotest.test_case "each event's own time" `Quick
            test_the_feed_reads_each_events_own_time
        ; Alcotest.test_case "equal times" `Quick
            test_equal_times_keep_the_order_things_happen_in
        ; Alcotest.test_case "only the newest wakes enter" `Quick
            test_only_the_newest_wakes_enter
        ; Alcotest.test_case "no source, no event" `Quick test_no_source_no_event
        ] )
    ]
;;
