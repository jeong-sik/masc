open Alcotest

module Observer = Masc_tui_observer
module Acting = Masc_tui_acting

let agent_core ?(kind = Observer.Tool_called) ?tool ?task ?turn ?tool_use_id ?batch
    ?(at = 100.) agent : Observer.event =
  Observer.Agent_core
    { Observer.kind
    ; agent = Some agent
    ; tool
    ; task
    ; turn
    ; tool_use_id
    ; batch
    ; at
    ; correlation = None
    ; parent = None
    }

let heartbeat keeper : Observer.event =
  Observer.Keeper_heartbeat
    { Observer.hb_keeper = keeper
    ; hb_phase = Some "turn_running"
    ; hb_in_turn = Some true
    ; hb_in_flight_ms = Some 2_189_925.4
    ; hb_since_progress_ms = None
    ; hb_at = 100.
    }

let settled keeper : Observer.event =
  Observer.Keeper_turn_complete
    { Observer.tc_keeper = keeper
    ; tc_turn = Some 2086
    ; tc_model = None
    ; tc_input_tokens = Some 73877
    ; tc_output_tokens = Some 358
    ; tc_cost_usd = Some 0.02581816
    ; tc_tool_calls = Some 0
    ; tc_at = 100.
    }

let text row =
  Printf.sprintf "%s %s %s | %s" (Acting.glyph_text row.Acting.glyph)
    row.Acting.keeper row.Acting.label row.Acting.detail

let test_actions_hide_what_says_nothing_a_row_can_act_on () =
  let events =
    [ agent_core ~tool:"read_file" "analyst"
    ; agent_core ~kind:Observer.Telemetry "analyst"
    ; heartbeat "bandleader"
    ; Observer.Keeper_composite_changed { keeper = "largo"; at = 100. }
    ; Observer.Snapshot "execution_snapshot"
    ; settled "largo"
    ; Observer.Keeper_chat_appended { keeper = "lane-smith"; connector = Some "agent"; at = 100. }
    ; Observer.Other "internal_agent_runs_changed"
    ; Observer.Keeper_chat_stream_frame
        { keeper = "test-keeper"; frame = Some "TEXT_MESSAGE_CONTENT"; at = 100. }
    ; Observer.Keeper_waiting_inventory_changed
        { keeper = "lane-smith"; queue_kind = Some "board"; at = 100. }
    ]
  in
  let under filter =
    List.filter (Acting.visible filter) events |> List.length
  in
  check int "actions keeps the call, the settlement, the chat, and the unknown" 4
    (under Acting.Actions);
  check int "everything keeps all ten" 10 (under Acting.Everything);
  check bool "an event this build was not taught always draws" true
    (Acting.visible Acting.Actions (Observer.Other "brand_new"))

(* A reply sends one stream frame per token, so a single keeper answering fills
   the retained ring on its own. Before these frames were decoded they arrived
   as Other, which the actions filter admits, and a screen asked for actions
   showed hundreds of rows with no time, no keeper and no detail -- two real
   actions among them. Counted here rather than described. *)
let test_one_reply_does_not_bury_the_actions_it_sits_between () =
  let frames =
    List.init 400 (fun index ->
        Observer.Keeper_chat_stream_frame
          { keeper = "test-keeper"
          ; frame = Some "TEXT_MESSAGE_CONTENT"
          ; at = 100. +. float_of_int index
          })
  in
  let events = (settled "largo" :: frames) @ [ agent_core ~tool:"read_file" "analyst" ] in
  check int "actions are the two the keeper took" 2
    (List.filter (Acting.visible Acting.Actions) events |> List.length);
  check int "everything still holds every frame" 402
    (List.filter (Acting.visible Acting.Everything) events |> List.length)

(* The row a stream frame draws: a real keeper and what the frame was, not the
   "server" placeholder with an empty detail that Other falls back to. The
   clock is the feed's, not the frame's -- the decoder still keeps the frame's
   own timestamp, and test_tui_observer pins that; it is the row that follows
   the order the screen scrolls through. *)
let test_a_stream_frame_draws_its_keeper_and_what_it_was () =
  let row =
    Acting.row_of_event ~at:100. ~duration_ms:None
      (Observer.Keeper_chat_stream_frame
         { keeper = "test-keeper"; frame = Some "CUSTOM KEEPER_TOOL_RESULT_READY"; at = 1787507570.5 })
  in
  check string "keeper" "test-keeper" row.Acting.keeper;
  check bool "the row wears the feed's clock, not the frame's" true
    (Float.equal row.Acting.at 100.);
  check string "detail names the frame" "CUSTOM KEEPER_TOOL_RESULT_READY"
    row.Acting.detail

(* A type this build was not taught puts its name in the Event column and its
   tool in Detail. [masc:audit_event] carries no tool, and the cell drew the
   [?] the default stood for -- which in a column of tool names reads as a
   failure marker and says nothing. Read on screen as:

     -                ? masc:audit_event ?

   The name is what the row has; an absent tool adds nothing to it. *)
let test_an_untaught_event_without_a_tool_says_only_its_name () =
  let row =
    Acting.row_of_event ~at:100. ~duration_ms:None
      (agent_core ~kind:(Observer.Agent_core_other "masc:audit_event") "-")
  in
  check string "the name is the label" "masc:audit_event" row.Acting.label;
  check string "and nothing stands in for the tool it has none of" ""
    row.Acting.detail

let test_an_untaught_event_with_a_tool_still_names_it () =
  let row =
    Acting.row_of_event ~at:100. ~duration_ms:None
      (agent_core ~kind:(Observer.Agent_core_other "masc:something")
         ~tool:"read_file" "analyst")
  in
  check string "a tool it does have is still the detail" "read_file"
    row.Acting.detail

(* The screen that prompted this: 927 rows held, two of them actions, and the
   whole page inside one second. A reply sends one frame per token, so 1,200
   frames arriving after two real events used to push both out of a ring
   trimmed by arrival. Budgeting per class keeps them. *)
let test_a_long_reply_does_not_evict_the_log_it_streams_into () =
  let stream index =
    Observer.Keeper_chat_stream_frame
      { keeper = "test-keeper"
      ; frame = Some "TEXT_MESSAGE_CONTENT"
      ; at = 200. +. float_of_int index
      }
  in
  (* Newest first, the order the ring holds. *)
  let ring = List.init 1_200 stream @ [ settled "largo"; agent_core ~tool:"read_file" "analyst" ] in
  let kept, dropped =
    Acting.retain ~actions:1_000 ~quiet:200 ~event_of:Fun.id ring
  in
  check int "both actions survive a reply twelve hundred frames long" 2
    (List.filter (Acting.visible Acting.Actions) kept |> List.length);
  check int "the quiet budget is spent, not the whole ring" 200
    (List.filter (fun e -> not (Acting.visible Acting.Actions e)) kept |> List.length);
  check int "everything dropped is counted" 1_000 dropped;
  check int "nothing is invented" (List.length kept + dropped) (List.length ring)

(* Trimming by arrival is what the budgets replace. Pinned so that a single
   shared budget cannot come back without this failing. *)
let test_the_old_arrival_trim_would_have_lost_them () =
  let stream index =
    Observer.Keeper_chat_stream_frame
      { keeper = "test-keeper"; frame = Some "TEXT_MESSAGE_CONTENT"; at = float_of_int index }
  in
  let ring = List.init 1_200 stream @ [ settled "largo" ] in
  let by_arrival = List.filteri (fun index _ -> index < 1_000) ring in
  check int "arrival order keeps no action at all" 0
    (List.filter (Acting.visible Acting.Actions) by_arrival |> List.length);
  let kept, _ = Acting.retain ~actions:1_000 ~quiet:200 ~event_of:Fun.id ring in
  check int "the class budget keeps it" 1
    (List.filter (Acting.visible Acting.Actions) kept |> List.length)

(* Order is what the screen scrolls through, so trimming must not reorder. *)
let test_trimming_keeps_the_order_it_was_given () =
  let ring = [ settled "a"; heartbeat "b"; settled "c"; heartbeat "d"; settled "e" ] in
  let kept, dropped = Acting.retain ~actions:2 ~quiet:1 ~event_of:Fun.id ring in
  check (list string) "newest of each class, in arrival order"
    [ "a"; "b"; "c" ]
    (List.map (fun e -> (Acting.row_of_event ~at:100. ~duration_ms:None e).Acting.keeper) kept);
  check int "the rest is counted" 2 dropped

(* The screen is a feed: rows are held and drawn in the order they arrived,
   so the clock the caller hands in is that arrival. Reading each event's own
   timestamp put two clocks on one screen, and the two kinds that carry none
   drew --:--:-- -- on 925 of the 927 rows that prompted this, which is the
   column an operator would have read to check the order. *)
let test_every_row_wears_the_clock_the_feed_ordered_it_by () =
  let received = 1787507570.5 in
  let at_of event = (Acting.row_of_event ~at:received ~duration_ms:None event).Acting.at in
  List.iter
    (fun (name, event) ->
       check bool (name ^ " wears the arrival clock") true
         (Float.equal (at_of event) received))
    [ ("an unknown type", Observer.Other "internal_agent_runs_changed")
    ; ("a snapshot", Observer.Snapshot "execution_snapshot")
      (* These two carried a clock of their own before, and it is no longer
         what the row shows -- the row shows the order it sits in. *)
    ; ("a settlement", settled "largo")
    ; ("a heartbeat", heartbeat "bandleader")
    ]

let test_a_call_and_its_return_read_as_one_pair () =
  let started =
    agent_core ~tool:"read_file" ~task:"task-494" ~turn:2086 ~tool_use_id:"tu-1"
      ~batch:(0, 2) ~at:100. "analyst"
  in
  let completed =
    { Observer.kind = Observer.Tool_completed
    ; agent = Some "analyst"
    ; tool = Some "read_file"
    ; task = Some "task-494"
    ; turn = Some 2086
    ; tool_use_id = Some "tu-1"
    ; batch = Some (0, 2)
    ; at = 100.032
    ; correlation = None
    ; parent = None
    }
  in
  check string "the call names its tool, batch slot, turn, and task"
    "\xe2\x96\xb6 analyst call | read_file [1/2] \xc2\xb7 turn 2086 \xc2\xb7 task-494"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None started));
  let duration =
    Acting.duration_of_completion ~before:[ heartbeat "x"; started ] completed
  in
  check (option (float 0.5)) "the return is paired with its start by tool-use id"
    (Some 32.) duration;
  check string "and the row carries the pairing"
    "\xe2\x9c\x93 analyst returned | read_file \xc2\xb7 32ms [1/2] \xc2\xb7 task-494"
    (text (Acting.row_of_event ~at:100. ~duration_ms:duration (Observer.Agent_core completed)))

let test_a_return_with_no_start_held_has_no_duration () =
  let completed =
    { Observer.kind = Observer.Tool_completed
    ; agent = Some "analyst"
    ; tool = Some "read_file"
    ; task = None
    ; turn = None
    ; tool_use_id = Some "tu-9"
    ; batch = None
    ; at = 100.
    ; correlation = None
    ; parent = None
    }
  in
  check (option (float 0.)) "another keeper's start with the same id does not pair"
    None
    (Acting.duration_of_completion
       ~before:[ agent_core ~tool_use_id:"tu-9" "someone-else" ]
       completed);
  check string "the row then shows the tool alone"
    "\xe2\x9c\x93 analyst returned | read_file"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None (Observer.Agent_core completed)))

let test_keeper_rows_say_what_the_keeper_did () =
  check string "a settlement carries tokens, cost, and calls"
    "\xe2\x96\xa0 largo turn settled | turn 2086 \xc2\xb7 in 73877 out 358 \xc2\xb7 $0.0258 \xc2\xb7 0 calls"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None (settled "largo")));
  check string "a heartbeat in a turn says how long it has been in it"
    "\xc2\xb7 bandleader heartbeat | turn_running \xc2\xb7 in turn for 36m29s"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None (heartbeat "bandleader")))

let test_agent_terminal_rows_keep_success_and_failure_distinct () =
  let completed =
    agent_core ~kind:Observer.Agent_completed ~task:"task-1" "analyst"
  in
  let failed = agent_core ~kind:Observer.Agent_failed ~task:"task-2" "analyst" in
  check string "a successful run is one completed row"
    "\xe2\x96\xa0 analyst agent done | task-1"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None completed));
  check string "a failed run is one failed row"
    "\xe2\x9c\x97 analyst agent failed | task-2"
    (text (Acting.row_of_event ~at:100. ~duration_ms:None failed))

let test_a_lane_named_event_is_attributed_by_its_trace () =
  let on_lane =
    Observer.Agent_core
      { Observer.kind = Observer.Tool_called
      ; agent = Some "agent_core-glm-coding.glm-5-turbo"
      ; tool = Some "Grep"
      ; task = None
      ; turn = Some 2135
      ; tool_use_id = None
      ; batch = None
      ; at = 100.
      ; correlation = Some "trace-1787333554989-0001e"
      ; parent = None
      }
  in
  let traces =
    [ ("polisher", "trace-1787333554796-0001d"); ("largo", "trace-1787333554989-0001e") ]
  in
  check string "the keeper whose trace the event carries" "largo"
    (Acting.keeper_of_event ~traces on_lane);
  check string "an unmatched trace keeps the lane name"
    "agent_core-glm-coding.glm-5-turbo"
    (Acting.keeper_of_event ~traces:[] on_lane);
  check string "a keeper-named event keeps its keeper" "bandleader"
    (Acting.keeper_of_event ~traces (heartbeat "bandleader"))

let test_elapsed_text_picks_a_unit () =
  check (list string) "ms, seconds, minutes"
    [ "32ms"; "1.2s"; "2m05s" ]
    (List.map Acting.elapsed_text [ 32.; 1200.; 125_000. ])

(* The feed used to render keeper_skill and keeper_compose_* as anonymous
   "call"/"returned" rows, so skill use was invisible in the chat-side surfaces
   and only the Tools screen knew. The label now says it is a skill. *)
let test_skill_tools_wear_a_skill_label () =
  let row event =
    Acting.row_of_entry ~duration_ms:None { Acting.ae_at = 100.; ae_event = event }
  in
  check string "skill body read is named" "skill call"
    (row (agent_core ~tool:"keeper_skill" "sangsu")).Acting.label;
  check string "composition run is named" "skill call"
    (row (agent_core ~tool:"keeper_compose_work-intake" "sangsu")).Acting.label;
  check string "a plain tool stays a call" "call"
    (row (agent_core ~tool:"masc_board_stats" "sangsu")).Acting.label;
  check string "completion keeps the tag" "skill returned"
    (row (agent_core ~kind:Observer.Tool_completed ~tool:"keeper_skill" "sangsu"))
      .Acting.label;
  let keeper_tool_call ?disposition tool : Observer.event =
    Observer.Keeper_tool_call
      { Observer.kt_keeper = "sangsu"
      ; kt_tool = tool
      ; kt_duration_ms = None
      ; kt_disposition = disposition
      ; kt_at = 100.
      }
  in
  check string "keeper skill call is named" "skill call"
    (row (keeper_tool_call "keeper_skill")).Acting.label;
  check string "a disposition keeps the tag beside it" "skill \xc2\xb7 delivered"
    (row (keeper_tool_call ~disposition:"delivered" "keeper_compose_work-intake"))
      .Acting.label;
  check string "a plain keeper tool stays a tool call" "tool call"
    (row (keeper_tool_call "masc_board_stats")).Acting.label
;;

let () =
  run "tui acting"
    [ ( "rows"
      , [ test_case "actions hide what says nothing a row can act on" `Quick
            test_actions_hide_what_says_nothing_a_row_can_act_on
        ; test_case "one reply does not bury the actions it sits between" `Quick
            test_one_reply_does_not_bury_the_actions_it_sits_between
        ; test_case "a stream frame draws its keeper and what it was" `Quick
            test_a_stream_frame_draws_its_keeper_and_what_it_was
        ; test_case "an untaught event without a tool says only its name" `Quick
            test_an_untaught_event_without_a_tool_says_only_its_name
        ; test_case "an untaught event with a tool still names it" `Quick
            test_an_untaught_event_with_a_tool_still_names_it
        ; test_case "a long reply does not evict the log it streams into" `Quick
            test_a_long_reply_does_not_evict_the_log_it_streams_into
        ; test_case "the old arrival trim would have lost them" `Quick
            test_the_old_arrival_trim_would_have_lost_them
        ; test_case "trimming keeps the order it was given" `Quick
            test_trimming_keeps_the_order_it_was_given
        ; test_case "every row wears the clock the feed ordered it by" `Quick
            test_every_row_wears_the_clock_the_feed_ordered_it_by
        ; test_case "a call and its return read as one pair" `Quick
            test_a_call_and_its_return_read_as_one_pair
        ; test_case "a return with no start held has no duration" `Quick
            test_a_return_with_no_start_held_has_no_duration
        ; test_case "keeper rows say what the keeper did" `Quick
            test_keeper_rows_say_what_the_keeper_did
        ; test_case "agent terminal rows keep success and failure distinct" `Quick
            test_agent_terminal_rows_keep_success_and_failure_distinct
        ; test_case "a lane-named event is attributed by its trace" `Quick
            test_a_lane_named_event_is_attributed_by_its_trace
        ; test_case "elapsed text picks a unit" `Quick test_elapsed_text_picks_a_unit
        ; test_case "skill tools wear a skill label in the feed" `Quick
            test_skill_tools_wear_a_skill_label
        ] )
    ]
