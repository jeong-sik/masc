(* What the Terminal tab decides before it draws: what each Execute output row
   is, when rows need a stream tag, and where a scroll key leaves the view.

   Nothing here looks at a screen. The rows are typed, and the view is a value
   that either follows the newest output or holds the reading the reader
   stopped on. *)

module T = Masc_tui_execute_terminal

let check = Alcotest.check

let show_status : T.status -> string = function
  | Process (Unix.WEXITED code) -> Printf.sprintf "exit %d" code
  | Process (Unix.WSIGNALED signal) -> Printf.sprintf "signal %d" signal
  | Process (Unix.WSTOPPED signal) -> Printf.sprintf "stopped %d" signal
  | Outcome (phase, outcome) ->
    Printf.sprintf "outcome %s %s"
      (match phase with Command -> "command" | Gate_observation -> "gate")
      (match outcome with
       | Result_unknown -> "unknown"
       | Request_not_sent -> "request_not_sent"
       | Observation_ended -> "observation_ended")
  | Rejected { why; reason } ->
    Printf.sprintf "rejected %s %s" why (Option.value reason ~default:"-")
  | Unrecognized text -> Printf.sprintf "unrecognized %s" text

let status = Alcotest.testable (fun ppf value -> Fmt.string ppf (show_status value)) ( = )

let show_kind : T.kind -> string = function
  | Command_start -> "command_start"
  | Command_more -> "command_more"
  | Stdout -> "stdout"
  | Stderr -> "stderr"
  | Status value -> "status " ^ show_status value
  | Foreign name -> "foreign " ^ name

let kinds rows = List.map (fun (row : T.row) -> show_kind row.kind) rows

let line ?(stream_id = Some 1) seq stream text : T.line = { seq; stream_id; stream; text }

(* The producer writes these four shapes and nothing else
   (keeper_tool_execute_runtime.ml, Exec_core). *)
let test_a_status_row_reads_back_what_the_server_wrote () =
  check status "a normal exit" (Process (Unix.WEXITED 0))
    (T.parse_status {|{"kind":"exit","code":0}|});
  check status "a failing exit keeps its code" (Process (Unix.WEXITED 2))
    (T.parse_status {|{"kind":"exit","code":2}|});
  check status "a kill" (Process (Unix.WSIGNALED 9))
    (T.parse_status {|{"kind":"signal","signal":9}|});
  check status "a stop" (Process (Unix.WSTOPPED 19))
    (T.parse_status {|{"kind":"stopped","signal":19}|});
  check status "a request that never left" (Outcome (Command, Request_not_sent))
    (T.parse_status {|{"outcome":"request_not_sent"}|});
  check status "a result nobody observed" (Outcome (Command, Result_unknown))
    (T.parse_status {|{"outcome":"unknown"}|});
  check status "the Gate's trial run ending is not a command ending"
    (Outcome (Gate_observation, Observation_ended))
    (T.parse_status {|{"phase":"gate_observation","outcome":"observation_ended"}|});
  check status "a rejection names why"
    (Rejected { why = "gate_reject"; reason = None })
    (T.parse_status {|{"rejected":"gate_reject"}|});
  check status "a rejection carries its reason when the server gave one"
    (Rejected { why = "too_complex"; reason = Some "pipeline_depth" })
    (T.parse_status {|{"rejected":"too_complex","reason":"pipeline_depth"}|})

(* A status this reader cannot place is shown as the server wrote it. Reading
   it as a success or a failure would be inventing the answer. *)
let test_a_status_nobody_wrote_is_shown_as_it_arrived () =
  List.iter
    (fun text -> check status text (Unrecognized text) (T.parse_status text))
    [ "not json"
    ; ""
    ; "[]"
    ; "7"
    ; "{}"
    ; {|{"kind":"mystery"}|}
    ; {|{"kind":"exit"}|}
    ; {|{"kind":"exit","code":"0"}|}
    ; {|{"outcome":"finished"}|}
    ; {|{"phase":"somewhere","outcome":"unknown"}|}
    ; {|{"rejected":3}|}
    ]

let test_each_stream_is_its_own_kind () =
  let rows =
    T.rows
      [ line 1 "cmd" "ls"
      ; line 2 "stdout" "a.txt"
      ; line 3 "stderr" "warning"
      ; line 4 "status" {|{"kind":"exit","code":0}|}
      ; line 5 "pty" "new stream"
      ]
  in
  check (Alcotest.list Alcotest.string) "kinds in order"
    [ "command_start"; "stdout"; "stderr"; "status exit 0"; "foreign pty" ]
    (kinds rows)

let test_a_row_keeps_what_the_server_numbered () =
  match T.rows [ line ~stream_id:(Some 7) 42 "stdout" "text" ] with
  | [ row ] ->
    check Alcotest.int "seq" 42 row.seq;
    check (Alcotest.option Alcotest.int) "stream id" (Some 7) row.stream_id;
    check Alcotest.string "text" "text" row.text
  | _ -> Alcotest.fail "one line is one row"

(* A command line of several lines is several rows with one stream id. *)
let test_a_command_continues_only_its_own_rows () =
  let kinds_of lines = kinds (T.rows lines) in
  check (Alcotest.list Alcotest.string) "a second line of the same command"
    [ "command_start"; "command_more"; "command_more" ]
    (kinds_of [ line 1 "cmd" "a \\"; line 2 "cmd" "b \\"; line 3 "cmd" "c" ]);
  check (Alcotest.list Alcotest.string) "another command starts again"
    [ "command_start"; "command_start" ]
    (kinds_of [ line 1 "cmd" "ls"; line ~stream_id:(Some 2) 2 "cmd" "pwd" ]);
  check (Alcotest.list Alcotest.string) "output between two commands ends the first"
    [ "command_start"; "stdout"; "command_start" ]
    (kinds_of [ line 1 "cmd" "ls"; line 2 "stdout" "x"; line 3 "cmd" "ls" ]);
  check (Alcotest.list Alcotest.string) "a window that opens inside a command reads as a start"
    [ "command_start"; "stdout" ]
    (kinds_of [ line 5 "cmd" "rest of the command"; line 6 "stdout" "x" ])

let test_rows_need_a_tag_only_when_commands_interleave () =
  let tagged lines = T.tagged (T.rows lines) in
  let other = Some 2 in
  check Alcotest.bool "no rows" false (tagged []);
  check Alcotest.bool "one command" false
    (tagged [ line 1 "cmd" "ls"; line 2 "stdout" "x"; line 3 "status" {|{"kind":"exit","code":0}|} ]);
  check Alcotest.bool "commands that take turns need no tag" false
    (tagged
       [ line 1 "cmd" "ls"
       ; line 2 "stdout" "x"
       ; line ~stream_id:other 3 "cmd" "pwd"
       ; line ~stream_id:other 4 "stdout" "/"
       ; line ~stream_id:(Some 3) 5 "cmd" "date"
       ]);
  check Alcotest.bool "a command heard from again after another spoke" true
    (tagged
       [ line 1 "cmd" "make"
       ; line ~stream_id:other 2 "cmd" "pwd"
       ; line 3 "stdout" "building"
       ]);
  check Alcotest.bool "rows with no stream say nothing about who owns them" false
    (tagged [ line ~stream_id:None 1 "stdout" "x"; line ~stream_id:None 2 "stdout" "y" ]);
  check Alcotest.bool "a row with no stream inside one command's run" false
    (tagged [ line 1 "stdout" "x"; line ~stream_id:None 2 "status" "{}"; line 3 "stdout" "y" ])

let test_unseen_counts_rows_past_the_newest_one_seen () =
  let seen = [ line 3 "stdout" "a"; line 5 "stdout" "b" ] in
  check Alcotest.int "nothing new" 0 (T.unseen ~seen ~latest:seen);
  check Alcotest.int "rows after the newest seen" 2
    (T.unseen ~seen ~latest:(seen @ [ line 6 "stdout" "c"; line 9 "stdout" "d" ]));
  check Alcotest.int "an older row is not new" 0
    (T.unseen ~seen ~latest:[ line 4 "stdout" "x" ]);
  check Alcotest.int "everything is new to a reader who saw nothing" 2
    (T.unseen ~seen:[] ~latest:seen);
  check Alcotest.int "nothing arrived" 0 (T.unseen ~seen ~latest:[])

(* A tab in output is a distance, not a character: it lands on the next stop
   whatever is before it, and the stops belong to the row, not to a run. *)
let test_a_tab_lands_on_the_next_stop () =
  let expanded ?(column = 0) text = T.expand_tabs ~column text in
  let check_expanded label (text, column) result =
    check (Alcotest.pair Alcotest.string Alcotest.int) label (text, column) result in
  check_expanded "no tab is no change" ("abc", 3) (expanded "abc");
  check_expanded "a tab after one cell" ("a       b", 9) (expanded "a\tb");
  check_expanded "a tab on a stop goes a whole stop" ("        x", 9) (expanded "\tx");
  check_expanded "the row's column carries into a run" ("     ", 8)
    (expanded ~column:3 "\t");
  check_expanded "two tabs" ("a       b       c", 17) (expanded "a\tb\tc");
  check_expanded "a trailing tab" ("ab      ", 8) (expanded "ab\t");
  check_expanded "a wide character fills two cells" ("\xea\xb0\x80      b", 9)
    (expanded "\xea\xb0\x80\tb");
  check Alcotest.int "the stops are eight cells apart" 8 T.tab_width

(* The reading is a string here; the tab keeps its snapshot. *)
let reading = Alcotest.option Alcotest.string

let hold =
  let show : string T.hold -> string = function
    | Following -> "following"
    | Paused { frozen; back } -> Printf.sprintf "paused %s %d" frozen back
  in
  Alcotest.testable (fun ppf value -> Fmt.string ppf (show value)) ( = )

(* The reason the view freezes: the output keeps arriving and a view that kept
   following the window would slide under a reader who scrolled up to read. *)
let test_scrolling_up_keeps_the_reading_that_was_on_screen () =
  let paused = T.older ~live:(Some "A") ~by:1 T.Following in
  check hold "the first row up freezes the live reading" (Paused { frozen = "A"; back = 1 })
    paused;
  check hold "more output arrived: the frozen reading stays"
    (Paused { frozen = "A"; back = 3 })
    (T.older ~live:(Some "B") ~by:2 paused);
  check reading "what is drawn is the frozen one" (Some "A") (T.shown ~live:(Some "B") paused);
  check reading "following draws the live one" (Some "B") (T.shown ~live:(Some "B") T.Following);
  check reading "following with nothing read draws nothing" None
    (T.shown ~live:None T.Following)

let test_the_bottom_is_where_following_resumes () =
  let paused = T.older ~live:(Some "A") ~by:5 T.Following in
  check hold "down part of the way stays paused" (Paused { frozen = "A"; back = 2 })
    (T.newer ~by:3 paused);
  check hold "down exactly to the bottom follows" T.Following (T.newer ~by:5 paused);
  check hold "down past the bottom follows" T.Following (T.newer ~by:50 paused);
  check hold "down while following changes nothing" T.Following
    (T.newer ~by:3 T.Following);
  check hold "End follows from anywhere" T.Following (T.newest paused)

let test_scrolling_with_no_reading_has_nothing_to_hold () =
  check hold "up before anything was read" T.Following
    (T.older ~live:None ~by:1 T.Following);
  check hold "to the oldest before anything was read" T.Following
    (T.oldest ~live:None T.Following)

let test_a_step_of_nothing_does_not_move_the_view () =
  let paused = T.older ~live:(Some "A") ~by:2 T.Following in
  check hold "up by zero" paused (T.older ~live:(Some "B") ~by:0 paused);
  check hold "up by a negative step" paused (T.older ~live:(Some "B") ~by:(-4) paused);
  check hold "down by zero" paused (T.newer ~by:0 paused);
  check hold "down by a negative step" paused (T.newer ~by:(-4) paused);
  check hold "up by zero from following" T.Following
    (T.older ~live:(Some "B") ~by:0 T.Following)

(* Home asks for as far as there is; the frame reports where that is. A second
   press on top of it must not wrap around to a negative count. *)
let test_the_oldest_row_is_reachable_and_the_count_does_not_wrap () =
  let top = T.oldest ~live:(Some "A") T.Following in
  check Alcotest.int "far from the bottom" max_int (T.back top);
  check Alcotest.int "another page up saturates" max_int (T.back (T.older ~live:(Some "A") ~by:30 top));
  check hold "the frame's clamp brings it back to a real row count"
    (Paused { frozen = "A"; back = 120 })
    (T.scroll_to ~live:(Some "B") ~back:120 top);
  check hold "a clamp to zero (the output fits) follows again" T.Following
    (T.scroll_to ~live:(Some "B") ~back:0 top)

let test_back_counts_from_the_bottom () =
  check Alcotest.int "following is the bottom" 0 (T.back T.Following);
  check Alcotest.int "paused three rows up" 3
    (T.back (T.older ~live:(Some "A") ~by:3 T.Following))

let test_stopped_window_preserves_hold_and_reaches_all_output () =
  let paused = T.older ~live:(Some "frozen") ~by:20 T.Following in
  let before = T.window ~content_height:9 ~total_rows:100 paused in
  let stopped = T.window ~content_height:9 ~total_rows:100 paused in
  check Alcotest.(pair int int) "the frozen first row and back stay put" (71, 20) stopped;
  check Alcotest.(pair int int) "the stopped notice does not move the frozen window" before stopped;
  let follows = T.window ~content_height:5 ~total_rows:100 T.Following in
  let up = T.older ~live:(Some "frozen") ~by:1 T.Following in
  let up_window = T.window ~content_height:5 ~total_rows:100 up in
  let down = T.newer ~by:1 up in
  check Alcotest.(pair int int) "the last five rows remain visible" (95, 0) follows;
  check Alcotest.(pair int int) "scrolling up moves one row" (94, 1) up_window;
  check Alcotest.(pair int int) "scrolling down returns to the last rows" follows
    (T.window ~content_height:5 ~total_rows:100 down);
  let six_up = T.older ~live:(Some "six") ~by:1 T.Following in
  check Alcotest.(pair int int) "six rows can scroll up in a five-row view" (0, 1)
    (T.window ~content_height:5 ~total_rows:6 six_up);
  check Alcotest.(pair int int) "and back down to the sixth row" (1, 0)
    (T.window ~content_height:5 ~total_rows:6 (T.newer ~by:1 six_up));
  let top = T.oldest ~live:(Some "frozen") T.Following in
  check Alcotest.(pair int int) "oldest remains clamped to the output" (0, 95)
    (T.window ~content_height:5 ~total_rows:100 top);
  check Alcotest.(pair int int) "short output stays anchored at the top" (0, 0)
    (T.window ~content_height:5 ~total_rows:3 paused)

let () =
  Alcotest.run "tui_execute_terminal"
    [ ( "status"
      , [ Alcotest.test_case "a status row reads back what the server wrote" `Quick
            test_a_status_row_reads_back_what_the_server_wrote
        ; Alcotest.test_case "a status nobody wrote is shown as it arrived" `Quick
            test_a_status_nobody_wrote_is_shown_as_it_arrived
        ] )
    ; ( "rows"
      , [ Alcotest.test_case "each stream is its own kind" `Quick
            test_each_stream_is_its_own_kind
        ; Alcotest.test_case "a row keeps what the server numbered" `Quick
            test_a_row_keeps_what_the_server_numbered
        ; Alcotest.test_case "a command continues only its own rows" `Quick
            test_a_command_continues_only_its_own_rows
        ; Alcotest.test_case "rows need a tag only when commands interleave" `Quick
            test_rows_need_a_tag_only_when_commands_interleave
        ; Alcotest.test_case "unseen counts rows past the newest one seen" `Quick
            test_unseen_counts_rows_past_the_newest_one_seen
        ; Alcotest.test_case "a tab lands on the next stop" `Quick
            test_a_tab_lands_on_the_next_stop
        ] )
    ; ( "hold"
      , [ Alcotest.test_case "scrolling up keeps the reading that was on screen" `Quick
            test_scrolling_up_keeps_the_reading_that_was_on_screen
        ; Alcotest.test_case "the bottom is where following resumes" `Quick
            test_the_bottom_is_where_following_resumes
        ; Alcotest.test_case "scrolling with no reading has nothing to hold" `Quick
            test_scrolling_with_no_reading_has_nothing_to_hold
        ; Alcotest.test_case "a step of nothing does not move the view" `Quick
            test_a_step_of_nothing_does_not_move_the_view
        ; Alcotest.test_case "the oldest row is reachable and the count does not wrap" `Quick
            test_the_oldest_row_is_reachable_and_the_count_does_not_wrap
        ; Alcotest.test_case "back counts from the bottom" `Quick
            test_back_counts_from_the_bottom
        ; Alcotest.test_case "a stopped window preserves hold and reaches all output" `Quick
            test_stopped_window_preserves_hold_and_reaches_all_output
        ] )
    ]
