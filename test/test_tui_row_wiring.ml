(* Rows the compiler cannot hold. Every binding asserted here lives in the TUI
   executable, so nothing links it (task-550) -- and every fact asserted is one
   that typechecks either way: which field a cell reads, whether a mark carries
   what a colour carries, whether a column measures itself.

   It began with the Approvals surface, where an operator authorises a command
   and three facts about the row were wrong at once. The other surfaces joined
   as the same shapes turned up on them.

   The measurement that found them, at 80, 140 and 200 columns with seven Gate
   rows waiting: the cell opened with the request schema name, then the
   absolute working directory, and ran out of row. It now opens with

     git clone --depth 1 https://github.com/jeong-sik/masc.git repos/masc

   which fits at every one of those widths, because a command is short and an
   envelope is not. *)

let render = "bin/masc_tui_render.ml"

(* The Memory surface draws itself from here. Only the screen title stayed
   behind in [render]; the state, the row and the context moved out with the
   table cell that carries its own colour (#32870). *)
let render_memory_module = "bin/masc_tui_render_memory.ml"

let reads_in ~module_path ~binding_name ~fields =
  Ast_grep.count_field_accesses_outside_calls_in_value_binding
    ~module_path ~binding_name ~callees:[] ~fields

let reads ~binding_name ~fields =
  reads_in ~module_path:render ~binding_name ~fields

(* A row two surfaces share is drawn by the primitives, not by either of
   them, so the guard over it names that file. *)
let reads_prim ~binding_name ~fields =
  reads_in ~module_path:"bin/masc_tui_render_prim.ml" ~binding_name ~fields

(* The detail under the list is three rows, and [boxed_surface_chrome_rows]
   budgets one for the selected row's own line. Every kind takes that one
   except a held tool call, which answers two questions -- what is being asked,
   and why it was held -- and the ask runs the width of the pane, so at eighty
   columns they cannot share a row.

   That second row used to be spelled as a literal ["\\n"]: backslash and n,
   printed to the operator as those two characters, because a real newline
   would have drawn a row nobody had counted. Both halves live in one place
   now -- the budget asks [approval_detail_line] how tall its line is before
   spending the rows on it -- and this pins that they stay one place. A height
   declared beside the drawing instead of read off it is how the footer floats
   a row, which is the defect the queue rows already taught the chat pane
   (#29818). *)
let test_the_detail_height_is_read_off_the_line_it_draws () =
  let calls callee =
    Ast_grep.count_calls_in_value_binding ~module_path:render
      ~binding_name:"render_approvals" ~callee
  in
  Alcotest.(check int) "the surface builds the detail line once" 1
    (calls "approval_detail_line");
  Alcotest.(check int) "and asks that same line for its height" 1
    (calls "approval_detail_rows")

(* Whether the reading is live. Forty-two surface renderers in this file end
   their title with [connection_badge]; the roster was the one that did not,
   and it is the surface an operator watches to see which keepers are up. "1
   healthy · 1 idle" read the same over a dead coordinator as over a live one,
   and the badge also carries the workspace mismatch, which this screen could
   not report at all. *)
(* A title brackets the words that say a reading is missing, because it has no
   label to hang them on; a labelled field has one, and the brackets inside it
   say a second time what the label already said. [Masc_tui_types] carries both
   spellings for that reason.

   Two rows reached for the title's helper from behind a label -- Overview drew
   "Pulse: (load failed)" and Lanes "Lane Add-ons: (not loaded)". That
   typechecks either way, so there was nothing to catch it but a screen. The
   words themselves are pinned by scripts/check-ssot.sh; which of the two a row
   asks for is pinned here. *)
let test_a_labelled_field_does_not_bracket_its_missing_reading () =
  let asks ~module_path ~binding_name ~callee =
    Ast_grep.count_calls_in_value_binding ~module_path ~binding_name ~callee
  in
  let prim = "bin/masc_tui_render_prim.ml" in
  Alcotest.(check int) "the Pulse field asks for the field spelling" 1
    (asks ~module_path:prim ~binding_name:"overview_pulse_text"
       ~callee:"field_missing_reading");
  Alcotest.(check int) "and not the title's" 0
    (asks ~module_path:prim ~binding_name:"overview_pulse_text"
       ~callee:"title_missing_reading");
  (* The Lanes overview draws both kinds on one screen -- its own title, which
     brackets, and the add-ons count behind a label, which does not -- so this
     one reads "at least one of each" rather than a pair of exact counts. *)
  Alcotest.(check bool) "the add-ons field asks for the field spelling" true
    (asks ~module_path:render ~binding_name:"render_lanes_overview"
       ~callee:"field_missing_reading"
     > 0);
  Alcotest.(check bool) "and the surface title still brackets its own" true
    (asks ~module_path:render ~binding_name:"render_lanes_overview"
       ~callee:"title_missing_reading"
     > 0)

let test_the_roster_title_says_whether_the_reading_is_live () =
  (* Asked as "at least once", because a surface whose title has two branches
     -- one for the reading, one for the failure -- draws it in each. *)
  let draws binding_name =
    Ast_grep.count_calls_in_value_binding ~module_path:render ~binding_name
      ~callee:"connection_badge"
    > 0
  in
  Alcotest.(check bool) "the roster title carries the badge" true
    (draws "render_keeper_list");
  (* Beside neighbours that already carried it, so the case says a rule rather
     than one surface's habit. *)
  List.iter
    (fun binding_name ->
      Alcotest.(check bool)
        (binding_name ^ " carries the badge")
        true (draws binding_name))
    [ "render_schedule_list"; "render_repository_list"; "render_fusion_list" ]

(* Where a command runs decides what it means: [git clone] into a container is
   not [git clone] onto the host. The decoder carries both, and the detail
   pane is the only surface with room for them. *)
let test_the_detail_pane_says_where_the_command_would_run () =
  Alcotest.(check bool)
    "the detail pane reads the sandbox it was granted against" true
    (reads ~binding_name:"render_approvals" ~fields:[ "gp_execution_sandbox" ]
     > 0);
  Alcotest.(check bool) "and the directory it would run in" true
    (reads ~binding_name:"render_approvals" ~fields:[ "gp_execution_cwd" ] > 0)

(* A blocked Gate row exposes a short reason under the list, where the frame
   has to fit it to one line. Enter promises the whole ask, so that pane must
   carry the producer's exact reason and whether this attempt can be retried;
   otherwise the operator still decides from the prefix before […]. *)
let test_the_detail_pane_keeps_the_blocked_gate_reason () =
  Alcotest.(check bool) "the whole-ask pane reads the exact reason" true
    (reads ~binding_name:"approval_detail_pane"
       ~fields:[ "gp_auto_judge_detail" ]
     > 0);
  Alcotest.(check bool) "and says whether retry is possible" true
    (reads ~binding_name:"approval_detail_pane" ~fields:[ "gp_retry_request" ]
     > 0)

(* The title counted the pending-confirm queue, which is one of the three lists
   this screen draws. With seven Gate rows waiting and that queue empty, the
   title read "(0/0, hidden 0)" while the tab beside it read "7". The hidden
   count stays -- an actor filter really does hide confirm entries -- but the
   pair that looked like the screen's count is gone. *)
let test_the_title_does_not_count_another_queue () =
  Alcotest.(check int)
    "no visible/total pair from the confirm queue in the title" 0
    (reads ~binding_name:"render_approvals"
       ~fields:[ "aps_visible_count"; "aps_total_count" ]);
  Alcotest.(check bool) "the filter note it keeps is still read" true
    (reads ~binding_name:"render_approvals" ~fields:[ "aps_hidden_count" ] > 0)

(* The surface's own title, the tab badge and the Overview row answer the
   same question, so they count the same population. The title counted the
   approval rows alone: with one open question and no approvals the tab read
   "Approvals\xc2\xb71" and the screen it opened read "MASC Approvals (0)",
   with the question block further down the pane. *)
let test_the_approvals_title_counts_what_the_badge_counts () =
  Alcotest.(check int) "the title walks the shared pending helper" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"render_approvals"
       ~callee:"approvals_surface_pending"
     + Ast_grep.count_calls_in_value_binding ~module_path:render
         ~binding_name:"render_approvals"
         ~callee:"Masc_tui_types.approvals_surface_pending");
  (* And names every kind it counted. A total with an unnamed part reads as
     an arithmetic error on screen. *)
  Alcotest.(check int) "the four kinds the surface answers" 4
    (Ast_grep.count_string_literals_in_value_binding ~module_path:render
       ~binding_name:"render_approvals"
       ~literals:[ "held"; "gate"; "op"; "question" ]);
  (* And takes the question count from the same place the block heading and
     the badge take it, rather than reading the asks snapshot a third time. *)
  Alcotest.(check int) "the questions come off the shared reading" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"render_approvals"
       ~callee:"Masc_tui_types.approvals_open_question_count");
  Alcotest.(check int) "and the surface reads the asks snapshot nowhere else" 0
    (reads ~binding_name:"render_approvals" ~fields:[ "asks_snapshot" ])

(* The Overview summary row wears the same word as the tab badge beside it,
   and for a while they counted different things: the badge walked all three
   approval lists, the row read the confirm queue's own visible count. A
   runtime holding one keeper tool call drew "Approvals: 0" under a tab
   reading "Approvals·1". One name, one population. *)
let test_the_overview_row_counts_every_approval_list () =
  Alcotest.(check int)
    "no confirm-queue count of its own in the Overview summary" 0
    (reads ~binding_name:"render_overview"
       ~fields:[ "aps_visible_count"; "aps_total_count" ]);
  (* The row and the ring must use the same population. The helper owns
     the approval rows plus open questions, so the overview must call it
     rather than rebuilding only one source. *)
  Alcotest.(check int) "the row walks the shared pending helper" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"render_overview"
       ~callee:"approvals_surface_pending"
     + Ast_grep.count_calls_in_value_binding ~module_path:render
         ~binding_name:"render_overview"
         ~callee:"Masc_tui_types.approvals_surface_pending");
  (* Every list the walk can come up short or long on has to be able to mark
     the count unreliable. The gate poll was the one left out: a failed fetch
     fills gate_error and leaves the previous rows standing, so the row drew a
     bare number over a list the server no longer holds. *)
  Alcotest.(check int) "every approval source can mark the count unreliable" 6
    (reads ~binding_name:"render_overview"
       ~fields:
         [ "approvals_error"
         ; "keeper_tool_approvals_error"
         ; "asks_snapshot"
         ; "asks_error"
         ; "gate_error"
         ; "gate_queue_unavailable"
         ])

(* The briefing answers with two lists that carry the same incidents, and the
   loader folds them into one. It also read a third key, "attention_items",
   that the briefing has never sent -- so that read was always the empty list,
   and nothing about the screen would change if the briefing started sending
   it. A read nobody can make produce anything is not a fallback.

   The count that rode the summary row is gone with it: it stood three lines
   above an Attention panel drawing those same incidents one per row. The
   panel's own title carries it now, and only says a number when some did not
   fit. *)
let test_the_summary_row_does_not_count_the_panel_below_it () =
  Alcotest.(check int) "the surface names no incident count of its own" 0
    (Ast_grep.count_string_literals ~module_path:render ~needle:"Incidents");
  Alcotest.(check int) "the loader stops reading a key nobody sends" 0
    (Ast_grep.count_string_literals_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml" ~binding_name:"load_overview"
       ~literals:[ "attention_items" ])

(* The briefing's command_focus repeats the first incident under
   "top_attention". The loader decoded it into a field of its own, and no
   screen ever drew that field: the Attention panel lists the incidents
   themselves, first one first, so the repeat had no row to go to.

   It was not free. [decode_attention_item] refuses an item that is missing a
   required field, and that refusal came back as the whole overview load
   failing -- the fleet counts, the health word and the panel itself, blanked
   over a value nothing reads. The load now stops opening command_focus at
   all. *)
let test_the_overview_load_stops_reading_a_field_no_screen_draws () =
  Alcotest.(check int) "the load no longer opens command_focus" 0
    (Ast_grep.count_string_literals_in_value_binding
       ~module_path:"bin/masc_tui_loader.ml" ~binding_name:"load_overview"
       ~literals:[ "command_focus"; "top_attention" ])

(* The briefing has always carried a liveness word per Keeper, written through
   the control plane's own printer. The Overview row read only how many rows
   there were, so a fleet with two Keepers that had stopped doing anything and
   one an operator had paused read the same as nine running ones.

   Two facts here. The row reads the counts, and the counts come from
   [Keeper_status_runtime]'s strict reader rather than from comparing the word
   against text -- the producer writes through that module's printer, and a
   second spelling of the same vocabulary is how the two ends drift apart. A
   word this build does not know is counted apart, never folded into the
   nearest state. *)
let loader = "bin/masc_tui_loader.ml"

(* The schedule store's dispositions are named once, by the shared contract
   the server builds this object from. The decoder walks that list instead of
   spelling the seven words again, so a status the contract gains is asked for
   here without this file changing -- and cannot be quietly dropped from the
   Automation tab's count line. *)
let test_the_schedule_counts_are_read_from_the_shared_status_list () =
  Alcotest.(check bool) "the decoder walks the contract's own list" true
    (Ast_grep.count_calls_in_value_binding ~module_path:loader
       ~binding_name:"decode_schedule_snapshot"
       ~callee:"Schedule_domain.schedule_status_to_string"
     > 0);
  Alcotest.(check int) "and spells no disposition of its own" 0
    (Ast_grep.count_string_literals_in_value_binding ~module_path:loader
       ~binding_name:"decode_schedule_snapshot"
       ~literals:
         [ "scheduled"; "due"; "running"; "succeeded"; "failed"; "cancelled"
         ; "expired" ])

let test_the_fleet_row_reads_the_control_planes_own_word () =
  Alcotest.(check int) "the liveness word is parsed, not matched as text" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:loader
       ~binding_name:"keeper_liveness_of_briefs"
       ~callee:"Keeper_status_runtime.control_plane_status_of_string_opt");
  Alcotest.(check int) "no second spelling of that vocabulary" 0
    (Ast_grep.count_string_literals_in_value_binding ~module_path:loader
       ~binding_name:"keeper_liveness_of_briefs"
       ~literals:
         [ "active"; "offline"; "idle"; "paused" ]);
  Alcotest.(check bool) "and the summary row reads the counts" true
    (reads ~binding_name:"render_overview" ~fields:[ "ov_keeper_liveness" ] > 0)

(* [operation=] is the right-hand side of the line directly above whenever the
   two agree, which is every operation but an identity call. The detail line
   compares them rather than printing it unconditionally, because at eighty
   columns that repetition cost the sandbox its place. *)
let test_the_detail_pane_compares_before_repeating_the_operation () =
  Alcotest.(check bool) "the operation is weighed against what is already shown"
    true
    (reads ~binding_name:"render_approvals"
       ~fields:[ "gp_display_tool"; "gp_operation" ]
     > 1)

(* The subject column took [cols - 76] -- everything the fixed parts did not
   use. On rows whose subject is a keeper name, that spent ninety cells on
   [edgar.a.poe] and left the recurrence past it reading [daily 08:00:00 A~]:
   the timezone, which is the part of a recurrence a reader cannot infer.

   Measured from the rows now, the way the Approvals and Fusion tables measure
   theirs. The rule that builds the subject moved out of the row loop for it,
   so the width and the cell cannot read different strings. *)
(* A wake that fired and a wake that was acted on read the same. [LAST WAKE]
   reports the dispatch and [DELIVERY EVIDENCE] one word of verdict, and the
   reaction ledger folds four separate observations into that word -- so a
   Keeper that took the wake and never started a turn looked like one that
   did.

   The four are on the wire on every row that has evidence at all (5/5 in the
   live workspace, with reaction_kind and the quarantine count beside them).
   This pins that the detail reads them rather than the verdict alone. *)
let test_the_schedule_detail_says_what_became_of_the_wake () =
  let steps =
    [ "sch_wake_seen"
    ; "sch_turn_started"
    ; "sch_queue_ack_seen"
    ; "sch_wake_cancelled"
    ]
  in
  List.iter
    (fun step ->
      Alcotest.(check bool)
        (Printf.sprintf "the turn block reads %s" step)
        true
        (reads ~binding_name:"schedule_turn_rows" ~fields:[ step ] > 0))
    steps;
  List.iter
    (fun field ->
      Alcotest.(check bool)
        (Printf.sprintf "the durable trace reads %s" field)
        true
        (reads ~binding_name:"schedule_turn_rows" ~fields:[ field ] > 0))
    [ "sch_reaction_keeper_name"
    ; "sch_reaction_stimulus_id"
    ; "sch_reaction_post_id"
    ; "sch_reaction_reason"
    ; "sch_stimulus_recorded_at_iso"
    ; "sch_turn_started_recorded_at_iso"
    ; "sch_queue_ack_recorded_at_iso"
    ; "sch_wake_cancelled_recorded_at_iso"
    ];
  Alcotest.(check bool) "and the detail draws that block" true
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"schedule_detail_lines" ~callee:"schedule_turn_rows"
     > 0)

(* #38205: [/health] reported which occurrence the schedule runner held back
   and no screen read it. The schedule row carries the hold now; this pins
   that the loader decodes it and that both the list's summary line and the
   detail pane draw it through the one reading. *)
let test_the_schedules_screen_draws_the_runner_hold () =
  Alcotest.(check bool) "the loader decodes the row's hold" true
    (Ast_grep.count_calls_in_value_binding ~module_path:loader
       ~binding_name:"decode_schedule_row"
       ~callee:"Tui_decode.decode_schedule_runner_hold"
     > 0);
  List.iter
    (fun (binding_name, callee) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s reads the hold" binding_name)
        true
        (reads ~binding_name ~fields:[ "sch_runner_hold" ] > 0);
      Alcotest.(check bool)
        (Printf.sprintf "%s words it through %s" binding_name callee)
        true
        (Ast_grep.count_calls_in_value_binding ~module_path:render ~binding_name
           ~callee
         > 0))
    [ "schedule_delivery_summary", "Render_schedule.schedule_hold_tag"
    ; "schedule_detail_lines", "Render_schedule.schedule_hold_reading"
    ]

let test_the_schedule_subject_is_measured_not_given_the_line () =
  (* Twice: once to measure the column, once to fill the cell. One call would
     mean the width came from somewhere else, which is the state this replaced. *)
  Alcotest.(check int) "one rule builds the subject, and the width reads it" 2
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"render_schedule_list" ~callee:"schedule_row_subject");
  Alcotest.(check bool) "the column is measured against the rows" true
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"render_schedule_list" ~callees:[]
       ~identifiers:[ "subject_width" ]
     > 0)

(* The repository declaration stores a path that may be relative to the
   workspace base.  The server owns that base path; a TUI running from a
   different cwd cannot safely resolve the declaration itself.  Pin both
   halves of the seam: the route publishes the resolved value, and the table
   plus selected-row context read it while Keeper assignment moves out of the
   space-constrained table column. *)
(* The Logs header carries the floor the reader set with [l] and [v]. Both
   keys write the one field and refetch, so on a read that brought nothing
   back the rows -- the only other thing that moves -- are not there: pressing
   either redrew a frame identical to the one before it. The note was computed
   for both arms and reached only the arm that had a snapshot.

   Two halves. The failed-read arm names the note, and the note says the floor
   once: [verbose] was the floor being DEBUG, spelled a second time on the row
   that drops the connection badge below eighty columns. *)
let test_the_logs_header_says_the_floor_the_reader_set () =
  Alcotest.(check bool) "the read that failed still carries what was set" true
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"render_system_logs" ~callees:[]
       ~identifiers:[ "set_filter_note" ]
     > 0);
  (* Twice, one per arm: the loaded header names it directly and the failed
     one through [set_filter_note]. A count of one is the state this replaced
     -- computed for both, reaching the arm that had a snapshot. *)
  Alcotest.(check int) "both arms reach the note" 2
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"render_system_logs" ~callees:[]
       ~identifiers:[ "filter_note" ])

(* Config / params draws one row of prose above its list, and it used to
   spend its first forty cells on two key phrases the footer already carried:
   "Enter edits by type \xc2\xb7 E is advanced JSON \xc2\xb7 overrides persist in
   .masc/runtime_params.json". The row is cut to the frame, so what went
   first was the part with no other home -- at eighty columns ".masc/run\xe2\x80\xa6",
   at sixty-four "overrides pers\xe2\x80\xa6".

   [Enter] is pinned into the footer at every width, so naming it here was the
   footer's hint a second time; [E] is dropped from the footer at eighty, so
   this row is where it lives below that. The store leads. *)
let test_the_params_row_leads_with_what_only_it_says () =
  Alcotest.(check int) "the row the pane draws, in this order" 1
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"render_runtime_params"
       ~needle:
         "  overrides persist in .masc/runtime_params.json \xc2\xb7 E is advanced JSON");
  (* And the phrase it stopped saying is gone rather than moved. The footer
     is pinned to keep [Enter] at every width, which is what made the row's
     copy of it dead weight; [Masc_tui_footer.never_dropped_keys] is where
     that pin lives and test_tui_keys is what holds it. *)
  Alcotest.(check int) "the footer's own hint is not said here twice" 0
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"render_runtime_params"
       ~needle:
         "  Enter edits by type \xc2\xb7 E is advanced JSON \xc2\xb7 overrides persist in .masc/runtime_params.json")

(* Detail panes draw section headings and field labels bold at the same
   indent, so caps are the only thing that tells a heading from a label. Two
   panes broke that: the schedule detail put "Summary" straight under "Digest
   digest-..." with nothing beside it, which reads as a field whose value is
   missing, and the log detail called one section "Details" when it was empty
   and "Structured details" when it was not.

   Fifteen other headings in this file are caps -- SCHEDULE, PAYLOAD, TURN,
   WAKES, VERIFICATION REQUEST, DECISION, RUN and the rest -- so the rule is
   the file's own, and these two are what did not follow it. *)
let test_a_detail_heading_is_spelled_the_way_a_heading_is () =
  List.iter
    (fun (binding_name, needle) ->
      Alcotest.(check int)
        (Printf.sprintf "%s draws %S" binding_name needle)
        1
        (Ast_grep.count_exact_string_literals_in_value_binding
           ~module_path:render ~binding_name ~needle))
    [ "schedule_detail_lines", "  SUMMARY"
    ; "system_log_detail_lines", "  STRUCTURED DETAILS"
    ; "system_log_detail_lines", "  STRUCTURED DETAILS  none"
    ];
  (* And the spellings they replaced are gone rather than joined. *)
  List.iter
    (fun (binding_name, needle) ->
      Alcotest.(check int)
        (Printf.sprintf "%s no longer draws %S" binding_name needle)
        0
        (Ast_grep.count_exact_string_literals_in_value_binding
           ~module_path:render ~binding_name ~needle))
    [ "schedule_detail_lines", "  Summary"
    ; "system_log_detail_lines", "  Structured details"
    ; "system_log_detail_lines", "  Details: none"
    ]

(* The Lanes list and the detail under it draw the same [sl_p50_elapsed_s] on
   one screen, and they drew it to different precisions: the P50 column "8.0s"
   and the detail "p50 latency 8.00s". A reader comparing the two is left
   deciding whether they are the same figure. The column is the constrained
   one -- [standalone_lane_p50_cells] is six -- so the detail follows it. *)
let test_the_two_p50s_on_the_lanes_screen_agree () =
  Alcotest.(check int) "the column draws one decimal" 1
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"standalone_lane_row" ~needle:"%.1fs");
  Alcotest.(check int) "and the detail draws the same" 1
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"standalone_lane_detail_lines"
       ~needle:" \xc2\xb7 p50 latency %.1fs");
  Alcotest.(check int) "the two-decimal spelling is gone" 0
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"standalone_lane_detail_lines"
       ~needle:" \xc2\xb7 p50 latency %.2fs")

(* The configuration clause is written once, in [Tui_decode]. This line used
   to introduce it with a noun of its own -- "configuration " ^ a word that
   three of the four states already give a subject -- so an unconfigured lane
   read "configuration not configured". The caller draws the clause as it
   comes. *)
let test_the_lane_line_writes_no_noun_of_its_own () =
  Alcotest.(check int) "the line takes the clause whole" 1
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"standalone_lane_detail_lines"
       ~needle:"%s lane \xc2\xb7 %s \xc2\xb7 %s");
  Alcotest.(check int) "and no longer names the subject itself" 0
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:render
       ~binding_name:"standalone_lane_detail_lines"
       ~needle:"%s lane \xc2\xb7 configuration %s \xc2\xb7 %s")

let test_board_lane_detail_draws_typed_jev_readiness () =
  Alcotest.(check int) "the detail reads the decoded JEV field" 1
    (reads ~binding_name:"standalone_lane_detail_lines" ~fields:[ "sl_jev" ]);
  Alcotest.(check int) "the off state is explicit" 1
    (Ast_grep.count_exact_string_literals_in_value_binding
       ~module_path:render ~binding_name:"standalone_lane_detail_lines"
       ~needle:"JEV OFF");
  Alcotest.(check int) "the configured state includes the model" 1
    (Ast_grep.count_exact_string_literals_in_value_binding
       ~module_path:render ~binding_name:"standalone_lane_detail_lines"
       ~needle:"JEV CONFIGURED \xc2\xb7 %s")

(* The Code tree draws one arrow on a row that opens rather than reads, and
   it drew it from two places a branch apart: the selected row reached for
   [Masc_tui_theme.Glyph.current_entry] -- the same byte under another name --
   and the row beside it spelled the bytes. Either moving would have left the
   column showing two marks for one thing depending on where the cursor was.

   Both now read [Masc_tui_file_icon.folder_glyph], which is also what the
   help sheet prints; test_tui_keys holds the sheet half. *)
let test_the_code_tree_draws_one_folder_arrow () =
  Alcotest.(check int) "both rows read the arrow from the mark module" 2
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"render_code" ~callees:[]
       ~identifiers:[ "File_icon.folder_glyph" ]);
  Alcotest.(check int) "and neither borrows the current-entry glyph" 0
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"render_code" ~callees:[]
       ~identifiers:[ "Masc_tui_theme.Glyph.current_entry" ])

(* The keeper chat draws two failure rows a few lines apart. The history one
   draws the loader's sentence and nothing else -- "Cause first", its comment
   says. The memory one put "memory journal unavailable: " in front of a
   sentence that already opened "memory journal:", so thirty cells went on the
   subject a second time before the part that differs, which the box then cut.

   The rule is written down at the gate lanes row: a prefix is for a detail
   that does not name itself. Every failure of this read does. *)
let chat = "bin/masc_tui_render_chat.ml"

let test_the_chat_failure_rows_say_the_subject_once () =
  Alcotest.(check int) "the memory row no longer names the subject twice" 0
    (Ast_grep.count_exact_string_literals_in_value_binding ~module_path:chat
       ~binding_name:"render_keeper_message"
       ~needle:"  memory journal unavailable: ");
  (* And the one failure path that did not name itself now does. The refusal,
     the decode and the transport all open with the subject or the URL; the
     exception catch-all handed the row a bare Printexc string, which without
     the prefix would have reached the screen with nothing saying what it was
     about. *)
  Alcotest.(check int) "the exception path names the read it failed" 1
    (Ast_grep.count_exact_string_literals_in_value_binding
       ~module_path:"bin/masc_tui.ml"
       ~binding_name:"launch_keeper_history_load" ~needle:"memory journal: ")

let test_repositories_show_the_server_resolved_checkout_path () =
  let producer = "lib/server/server_routes_http_routes_repositories.ml" in
  Alcotest.(check int) "the route names one resolved path field" 1
    (Ast_grep.count_string_literals_in_value_binding ~module_path:producer
       ~binding_name:"repository_json" ~literals:[ "resolved_local_path" ]);
  Alcotest.(check int) "the route resolves it against the server base" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:producer
       ~binding_name:"repository_json" ~callee:"Repo_store.local_path");
  Alcotest.(check bool) "the repository context reads the resolved path" true
    (reads ~binding_name:"repository_context_lines"
       ~fields:[ "rp_resolved_local_path" ]
     > 0);
  Alcotest.(check bool) "and keeps assignment in the selected-row context" true
    (reads ~binding_name:"repository_context_lines" ~fields:[ "rp_keepers" ] > 0);
  (* The status column has room for the word and not for the cause a failed
     clone or fetch leaves behind, so the cause belongs in the selected row's
     context. The route wrote it to the wire and nothing read it. *)
  Alcotest.(check int) "the route names the cause it writes" 1
    (Ast_grep.count_string_literals_in_value_binding ~module_path:producer
       ~binding_name:"repository_json" ~literals:[ "error_message" ]);
  Alcotest.(check int) "and the context asks for it" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"repository_context_lines"
       ~callee:"Masc.Tui_decode.repository_status_reason")

let test_memory_surface_keeps_the_starvation_axes () =
  (* Starvation depends on ordinary absence and failed Librarian runs, while a
     source-bound snapshot changes the truthful row label from memoryless to
     source-only. Keep all three axes in the renderer. *)
  List.iter
    (fun field ->
      Alcotest.(check bool) ("memory_state reads " ^ field) true
        (reads_in ~module_path:"bin/masc_tui_types.ml" ~binding_name:"memory_state"
           ~fields:[ field ]
         > 0))
    [ "mkh_snapshot_present"
    ; "mkh_source_snapshot_present"
    ; "mkh_librarian_failures"
    ];
  Alcotest.(check bool) "the title names the starving count" true
    (reads ~binding_name:"render_memory" ~fields:[ "mhs_starving_keepers" ] > 0);
  Alcotest.(check bool) "the title keeps source facts separate" true
    (reads_in ~module_path:render_memory_module ~binding_name:"memory_fleet_header_rows" ~fields:[ "mhs_total_source_facts" ] > 0);
  Alcotest.(check bool) "the title keeps derived facts separate" true
    (reads_in ~module_path:render_memory_module ~binding_name:"memory_fleet_header_rows" ~fields:[ "mhs_total_derived_facts" ] > 0);
  Alcotest.(check bool) "the title exposes support retractions" true
    (reads_in ~module_path:render_memory_module ~binding_name:"memory_fleet_header_rows"
       ~fields:[ "mhs_total_support_invalidations" ]
     > 0);
  (* The source snapshot has four numbers and the row has one cell for them,
     so it carries the three that identify the snapshot -- which revision, how
     stale, how big -- and the fact count goes to the context pane below,
     which has a line to spell all four out. *)
  List.iter
    (fun field ->
      Alcotest.(check bool) ("memory row reads " ^ field) true
        (reads_in ~module_path:render_memory_module
           ~binding_name:"memory_row_line" ~fields:[ field ]
         > 0))
    [ "mkh_source_revision"; "mkh_source_invalidations"; "mkh_source_snapshot_bytes" ];
  List.iter
    (fun field ->
      Alcotest.(check bool) ("memory context reads " ^ field) true
        (reads_in ~module_path:render_memory_module
           ~binding_name:"memory_context_lines" ~fields:[ field ]
         > 0))
    [ "mkh_source_revision"
    ; "mkh_source_facts"
    ; "mkh_source_invalidations"
    ; "mkh_source_snapshot_bytes"
    ];
  List.iter
    (fun field ->
      Alcotest.(check bool) ("memory context reads " ^ field) true
        (reads_in ~module_path:render_memory_module
           ~binding_name:"memory_context_lines" ~fields:[ field ]
         > 0))
    [ "mkh_vision_ingest_errors"
    ; "mkh_vision_ingest_error_reasons"
    ; (* RFC librarian-lifecycle §4.9: the header says how far behind the
         keeper's Librarian is standing. *)
      "mkh_librarian"
    ; "mkh_observed_facts"
    ; "mkh_derived_facts"
    ; "mkh_support_invalidations"
    ]

let test_repository_changes_keep_the_git_axes () =
  let producer = "lib/server/server_routes_http_routes_repositories.ml" in
  Alcotest.(check int) "the route reads exact Git status rows" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:producer
       ~binding_name:"handle_list_repository_changes"
       ~callee:"Repo_git.status_files");
  List.iter
    (fun field ->
      Alcotest.(check bool) ("renderer reads " ^ field) true
        (reads_prim ~binding_name:"repository_change_status" ~fields:[ field ]
         > 0))
    [ "rc_staged"; "rc_unstaged"; "rc_untracked"; "rc_conflicted" ]

let test_project_changes_use_the_requested_workspace_root () =
  let producer = "lib/server/server_routes_http_routes_workspace.ml" in
  Alcotest.(check int) "the project route reads status at the resolved root" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:producer
       ~binding_name:"add_routes" ~callee:"Repo_git.status_files_at")

(* The Lanes summary drew one mark for four states while the style beside it
   was green, red or grey. On a column of identical marks the lane failing 133
   of 1095 runs looked exactly like the four that were fine, and the only two
   channels that separated them were a colour and a word.

   [standalone_lane_row] is in the same unlinkable executable, so the marks are
   asserted here: three distinct ones, matching the three the style makes. *)
let test_a_lane_mark_says_what_its_colour_says () =
  (* Each mark separately, not three occurrences of any of them: folding two
     states back onto one mark leaves the total at three and a count would
     still pass. This failed to catch exactly that before it was written this
     way. *)
  List.iter
    (fun (mark, what) ->
      Alcotest.(check bool)
        (Printf.sprintf "the %s class has its own mark" what)
        true
        (Ast_grep.count_string_literals_in_value_binding ~module_path:render
           ~binding_name:"standalone_lane_row" ~literals:[ mark ]
         > 0))
    [ ("\xe2\x97\x8f", "running or idle")
    ; ("\xe2\x9c\x97", "degraded or unavailable")
    ; ("\xc2\xb7", "nothing retained")
    ]

(* Why a lane cannot admit belongs to one place, and it is not the table.

   The cell used to draw it. It is a sentence, and SLOTS is a column of slot
   names measured by the widest of them, so at the live width a reader got
   the first few words of it under a header promising slot names -- and that
   string set every other row's slot column too. It was drawn there because
   when that was written (#31395) nothing else drew it; the detail pane has
   drawn it whole since #32194, and STATUS beside the cell says [unavailable]
   or [degraded] -- the projection reads a lane that could not admit as
   degraded, whatever its slot list holds.

   So the table's cell binds no reason, and the detail pane reads the field.
   What the cell draws instead is checked in test_tui_lane_table, where the
   text itself now lives. *)
let test_why_a_lane_cannot_admit_is_the_detail_panes_to_say () =
  Alcotest.(check int) "the table's cell binds no reason" 0
    (Ast_grep.count_identifiers_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"standalone_lane_slots_text"
       ~callees:[] ~identifiers:[ "reason" ]);
  Alcotest.(check bool) "the detail pane reads the projection's reason" true
    (Ast_grep.count_field_accesses_outside_calls_in_value_binding
       ~module_path:render ~binding_name:"standalone_lane_detail_lines"
       ~callees:[] ~fields:[ "sl_admission_error" ]
     > 0)

(* A turn whose keeper the health reading calls offline was never closed and
   nothing works it: the row keeps the elapsed time and stops the mark.
   [Masc_tui_keeper_mark.open_turn] says which reading that is, and
   test_tui_keeper_mark checks it. What the row has to do is ask it and draw
   the stopped case it answers. *)
let test_a_turn_on_a_keeper_that_is_not_running_stops_moving () =
  Alcotest.(check bool) "the row asks what its open turn draws" true
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"keeper_row_content"
       ~callee:"Masc_tui_keeper_mark.open_turn"
     > 0);
  Alcotest.(check bool) "the row draws the turn nothing works" true
    (Ast_grep.count_constructors_in_value_binding ~module_path:render
       ~binding_name:"keeper_row_content"
       ~constructors:[ "Masc_tui_keeper_mark.Left_open" ]
     > 0)

(* The preview's em dash once appeared as double-encoded UTF-8. Running
   marks belong to Masc_tui_answering and are exercised as rendered rows by
   test_tui_answering, including their terminal-cell width. *)
let test_visible_navigation_glyphs_are_not_mojibake () =
  let count literals =
    Ast_grep.count_string_literals_in_value_binding ~module_path:render
      ~binding_name:"render_answering" ~literals
  in
  Alcotest.(check int) "Answering draws the real em dash" 1
    (count [ "live preview \xe2\x80\x94 none for this row" ]);
  Alcotest.(check int) "preview has no double-encoded em dash" 0
    (count [ "live preview \xc3\xa2\xc2\x80\xc2\x94 none for this row" ])

(* The Attention panel's badge. Critical and bad share a colour, so the word
   is the only thing that tells those two rows apart -- and the badge fitted
   that word to five fixed cells, which cut "critical" to [crit~] and padded
   the shorter levels inside their own brackets as [bad  ].

   Asserted at the source because nothing links the TUI executable, and
   because both failures typecheck: a label one cell too long and a column one
   cell too narrow are the same well-typed program. Two facts carry it -- the
   vocabulary fits, and nothing cuts it. *)
let test_the_attention_badge_cannot_cut_its_own_level () =
  let literals binding names =
    Ast_grep.count_string_literals_in_value_binding ~module_path:render
      ~binding_name:binding ~literals:names
  in
  Alcotest.(check int) "every level is named and every name is short" 4
    (literals "attention_severity_label" [ "crit"; "bad"; "warn"; "info" ]);
  Alcotest.(check int) "the level that did not fit its column is gone" 0
    (literals "attention_severity_label" [ "critical" ]);
  let calls binding callee =
    Ast_grep.count_calls_in_value_binding ~module_path:render
      ~binding_name:binding ~callee
  in
  Alcotest.(check int) "the column measures the names" 1
    (calls "attention_severity_badge_cells" "Message_layout.display_width");
  Alcotest.(check int) "and the badge cuts nothing" 0
    (calls "attention_severity_badge" "fit_width")

(* Three facts about a surface's row list -- how many rows, which one the
   cursor is on, how to put the cursor elsewhere -- used to live in three
   separate matches over [surface], each naming every variant so a new one
   could not be added without touching it. Naming is not agreeing: the Keeper
   detail's context inspector had a landing and searchable rows and no cursor
   reading, so n and N restarted from the first row every press.

   They are one record now, and the keys that need any of the three ask it.
   Counted here because nothing links the TUI executable, and because the
   failure this prevents typechecks either way. *)
let test_the_row_cursor_has_one_source () =
  let asks binding_name =
    Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui.ml"
      ~binding_name ~callee:"row_list"
  in
  Alcotest.(check int) "the cursor reading asks the record" 1
    (asks "search_row_cursor");
  Alcotest.(check int) "the landing asks the record" 1
    (asks "place_row_cursor");
  Alcotest.(check int) "Home and End ask the record" 1
    (asks "move_list_to_edge");
  Alcotest.(check int) "the page keys ask the record" 1
    (asks "move_list_by_rows")

(* The cursor and the window have to be measured against the same layout, and
   on the Memory overview that layout depends on which keeper the cursor is
   on: the selected row spends rows on its own alerts and read errors. The
   step key recomputed it and the landing did not, so a jump could put the
   cursor outside the window it had just measured. One helper answers both. *)
let test_the_window_is_measured_where_the_cursor_lands () =
  let asks binding_name =
    Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui.ml"
      ~binding_name ~callee:"surface_body_height_at"
  in
  Alcotest.(check int) "a step measures where it lands" 1
    (asks "move_row_cursor");
  Alcotest.(check int) "and so does a landing" 1 (asks "row_list");
  Alcotest.(check int)
    "the cursor-dependent layout is read in one place" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:"bin/masc_tui.ml"
       ~binding_name:"surface_body_height_at"
       ~callee:"Masc_tui_render_memory.memory_overview_scrolled")

(* A lookup in the body of a drawing loop is paid once per visible row. The
   count is over the whole renderer rather than one binding, because the
   shape returns wherever a loop draws rows; a call to the same function
   outside a loop runs once a frame and is fine, which is why this is not
   [count_calls].

   What it does not see: a helper defined beside the loop and called from
   inside it, which is where the Code diff pane kept its own walk. Nothing
   lexically inside the loop named [List.nth_opt] there. That one is held by
   the type instead -- the open file is an array, so there is no list left to
   walk -- and the compiler is the stronger guard of the two. This one earns
   its place on the sites where the index really is written in the loop:
   three stood when it was added. *)
let test_no_row_of_a_drawing_loop_walks_a_list () =
  (* Every render module, not only the big one: the tab strip was in
     [render] when this was written and moved to [render_prim] the same day
     (#35333). A count over one file lets the shape leave by moving.

     Read from the tree rather than typed out. The hand-written list had
     already missed the chat renderer, and a list only records which modules
     existed the day someone last remembered to edit it. Everything named
     bin/masc_tui_render*.ml is a render module, and the stanza's deps glob
     the same shape so a change to any of them reruns this. *)
  let render_modules =
    let dir = Filename.concat (Ast_grep.source_root ()) "bin" in
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun name ->
         String.starts_with ~prefix:"masc_tui_render" name
         && Filename.check_suffix name ".ml")
    |> List.sort String.compare
    |> List.map (fun name -> Filename.concat "bin" name)
  in
  (* A guard that lost its subject passes for the wrong reason. *)
  Alcotest.(check bool)
    "the render modules were found" true
    (List.length render_modules > 1);
  let inside_for callee =
    List.fold_left
      (fun total module_path ->
        total + Ast_grep.count_calls_inside_for ~module_path ~callee)
      0 render_modules
  in
  Alcotest.(check int) "no row walks a list to find itself" 0
    (inside_for "List.nth_opt");
  Alcotest.(check int) "and none walks one unguarded either" 0
    (inside_for "List.nth")

(* Both strips that a reader walks -- the surface strip across the top and the
   keeper detail tabs -- mark where they are with one value. The mark is style
   plus a glyph, and style is the half that does not survive: a monochrome
   terminal, a terminal that drops underline, and every text capture keep the
   glyph and lose the bold. So the glyph is the answer, and it has to come from
   the shared binding rather than a literal spelled twice.

   The keeper detail tabs are drawn by [tab_strip], the one drawing every
   in-screen strip shares, so the mark is read there: the pane calls the
   strip, and the strip reads the glyph.

   Asserted here because the screen this draws has no other gate: the frame is
   pinned in test/test_tui_keyboard_input.py, which is Python, and no CI path
   runs Python. Re-inlining the literal in either strip typechecks and draws
   the same thing today, then drifts the first time one of them changes. *)
let test_both_strips_mark_where_they_are_from_one_value () =
  let mark binding module_path =
    Ast_grep.count_identifiers_outside_calls_in_value_binding ~module_path
      ~binding_name:binding ~callees:[]
      ~identifiers:[ "Masc_tui_theme.Glyph.current_entry" ]
  in
  Alcotest.(check bool) "the keeper detail tabs draw through the shared strip" true
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"keeper_detail_pane" ~callee:"tab_strip"
     >= 1);
  Alcotest.(check bool) "the shared strip marks the entry it is on" true
    (mark "tab_strip" "bin/masc_tui_ansi.ml" > 0);
  Alcotest.(check bool) "the surface strip reads the same mark" true
    (mark "surface_strip" "bin/masc_tui_render_prim.ml" > 0)

(* The Board title's count. The listing is one server page and the board can
   hold more, so the count beside the name has to be the one that knows both
   numbers. A title that goes back to printing the page length typechecks and
   says nothing on screen but a smaller board. *)
let test_the_board_title_counts_through_the_helper_that_knows_the_board () =
  let asks callee =
    Ast_grep.count_calls_in_value_binding ~module_path:render
      ~binding_name:"render_board_list" ~callee
  in
  Alcotest.(check int) "the title asks what the board holds" 1
    (asks "board_list_count_text")

(* The slot history and the run total sit one line apart in the lane detail,
   and the slots cover only the runs that named one -- on the live Board
   Attention lane, 357 of 489, most of the rest Vendor System One answers.
   The runs without a slot are drawn by the one function that reads the
   server's reasons, rather than spelled again beside the line. *)
let test_the_lane_slot_history_says_what_it_does_not_cover () =
  Alcotest.(check int) "the detail asks for the runs that named no slot" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"standalone_lane_detail_lines"
       ~callee:"standalone_lane_runs_without_slot_parts")

(* A stamp that can be older than today is drawn as a span, not as a clock.

   Both of these sit beside the screen's own clock and used to draw the hour
   alone, on the reading that the header gives them a distance. That holds
   only while the two are the same day: the Clients roster drew a session last
   seen on 2026-09-21 as "11:49:28" under a 2026-09-23 header, and the
   planning baseline is the first read of the process and is never replaced,
   so a screen left open overnight named a moment on a day nobody could
   identify.

   Counted rather than read off a screen, because the two are days apart from
   the clock a test would have to wait for. *)
let test_a_stamp_that_can_outlive_today_is_drawn_as_a_span () =
  let asks ~binding_name ~callee =
    Ast_grep.count_calls_in_value_binding ~module_path:render ~binding_name
      ~callee
  in
  List.iter
    (fun binding_name ->
      Alcotest.(check bool)
        (Printf.sprintf "%s asks for the span" binding_name)
        true
        (asks ~binding_name ~callee:"Masc_tui_wire_age.text" > 0);
      Alcotest.(check int)
        (Printf.sprintf "%s draws no bare clock" binding_name)
        0
        (asks ~binding_name ~callee:"Terminal_text.clock_timestamp"))
    [ "render_clients"; "render_planning_list" ]

(* The runtime detail opens from two doors: a lane's candidate row and the
   catalog row. Both answer "Used by lanes", and the lane door used to answer
   it with the one lane the reader arrived through -- a runtime seven lanes
   fall back to said it was used by one. Both doors now ask
   [runtime_lanes_using], which reads the resolved projection, so neither can
   answer with a shorter list than the other. *)
let test_both_doors_into_the_runtime_detail_ask_the_same_lane_list () =
  let asks ~callee =
    Ast_grep.count_calls_in_value_binding ~module_path:render
      ~binding_name:"runtime_detail_lines" ~callee
  in
  Alcotest.(check int) "the lane door asks the projection for the lanes" 1
    (asks ~callee:"runtime_lanes_using");
  Alcotest.(check int) "the catalog door keeps reading the same rows" 1
    (asks ~callee:"runtime_all_rows")

(* The list is drawn in the order the server sent, and the column beside it is
   only a reading of that order when it holds the time the order was made
   from. The column used to hold the last move under every sort, so under
   "newest post first" a post replied to a minute ago sat sixth reading "25s".
   The sort is read once for the whole list: the header word and every row's
   number name the same time only while one reading feeds both. *)
let test_the_board_age_column_reads_the_sort_once () =
  let asks ~callee =
    Ast_grep.count_calls_in_value_binding ~module_path:render
      ~binding_name:"render_board_list" ~callee
  in
  Alcotest.(check int) "the list asks which time the sort ordered by" 1
    (asks ~callee:"board_sort_time");
  Alcotest.(check int) "and names that time over the column once" 1
    (asks ~callee:"board_age_header")


(* Six values the loader read and no screen drew.

   [count] was the one that cost something: the tool-call snapshot required
   it, so a server that stopped sending it failed the whole decode and blanked
   the pane over a number nothing reads -- the same shape as the overview
   field #38224 took out, and the rows carry their own length anyway. The
   other five were free to decode and just as unread: a call's [model] is the
   redaction label "runtime" by boundary design and never a model name, a
   call's [task_id] comes through null, the harness evaluator's
   [last_signal_at] is already folded into the status word the server sends
   (it answers "stale" past its own threshold), a gate rule's [created_by]
   sits beside a row that draws the keeper and the tool, and [space_overhead]
   is a GC setting rather than a reading.

   Each binding is checked twice: the key it no longer opens, and a key it
   still does, so a renamed binding cannot make this pass by matching
   nothing. *)
let test_the_loader_stops_opening_keys_no_screen_draws () =
  let decode = "lib/tui_decode.ml" in
  let dropped =
    [ ("decode_keeper_call", "task_id")
    ; ("decode_keeper_call", "model")
    ; ("decode_keeper_calls_snapshot", "count")
    ; ("decode_harness_overview", "last_signal_at")
    ; ("decode_gate_rule", "created_by")
    ; ("decode_server_identity", "space_overhead")
    ]
  in
  let still_read =
    [ ("decode_keeper_call", "turn")
    ; ("decode_keeper_calls_snapshot", "health")
    ; ("decode_harness_overview", "evaluator_status")
    ; ("decode_gate_rule", "expires_at")
    ; ("decode_server_identity", "minor_heap_size")
    ]
  in
  List.iter
    (fun (binding, key) ->
      Alcotest.(check int)
        (Printf.sprintf "%s no longer opens %S" binding key)
        0
        (Ast_grep.count_exact_string_literals_in_value_binding
           ~module_path:decode ~binding_name:binding ~needle:key))
    dropped;
  List.iter
    (fun (binding, key) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s still opens %S" binding key)
        true
        (Ast_grep.count_exact_string_literals_in_value_binding
           ~module_path:decode ~binding_name:binding ~needle:key
        > 0))
    still_read
;;

(* The keeper detail's Automation rows drew a status, a recurrence and a
   summary, and a Keeper's store keeps every request it ever took. On the
   live roster code-reviewer holds 91 rows: twenty of them share one status
   and one summary, ten more share another. Twenty identical lines say the
   same thing twenty times and tell a reader nothing about which is which.

   [sch_requested_at_iso] is on every row and was drawn nowhere. The three
   that read "#36319 리뷰 등기 (dispatch 결과 확인 후)" were asked for at
   13:39:53, 13:43:50 and 13:45:04 on 2026-09-14, so the clock is what parts
   them. It is drawn with the terminal's own short timestamp, the helper the
   other row clocks read, rather than a format of its own. *)
let test_an_automation_row_says_when_it_was_asked_for () =
  Alcotest.(check int) "the row reads the request clock" 1
    (Ast_grep.count_field_reads_in_value_binding ~module_path:render
       ~binding_name:"automation_lines" ~field_name:"sch_requested_at_iso");
  Alcotest.(check int) "and spells it with the shared stamp" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"automation_lines" ~callee:"Terminal_text.short_timestamp")
;;

(* The two wire values beside the clock sat in [%-12s] and [%-18s]. Printf
   pads such a column to its width and never cuts it, so a longer value pushes
   everything after it to the right on that row alone. Measured on the live
   fleet's 676 schedule requests: geek-scout's "daily 09:25:00 +09:00" is 21
   cells and polisher's "cron 0 */2 * * * UTC" is 20, both in the 18-cell
   recurrence column. [%-Ns] also counts bytes, so any non-ASCII value would
   miss its width even inside the column.

   Both cells are now cut to a width measured in cells: the status to the
   widest word the schedule contract names, the recurrence to a declared
   budget. *)
let test_the_automation_row_cuts_the_columns_it_draws () =
  Alcotest.(check int) "both wire cells are cut to a width" 2
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"automation_lines" ~callee:"fit_width");
  Alcotest.(check int) "and no column is padded by Printf" 0
    (Ast_grep.count_string_literals_containing_in_value_binding
       ~module_path:render ~binding_name:"automation_lines" ~needle:"%-");
  (* The status column is the contract's vocabulary, not a number typed here,
     so a new status word moves the column with it. *)
  Alcotest.(check int) "the status width is read off the contract" 1
    (Ast_grep.count_calls_in_value_binding ~module_path:render
       ~binding_name:"schedule_status_word_cells" ~callee:"List.fold_left")
;;

let () =
  Alcotest.run "masc_tui_row_wiring"
    [ ( "approvals"
      , [ Alcotest.test_case "the detail pane says where the command would run"
            `Quick test_the_detail_pane_says_where_the_command_would_run
        ; Alcotest.test_case "the detail pane keeps a blocked Gate reason"
            `Quick test_the_detail_pane_keeps_the_blocked_gate_reason
        ; Alcotest.test_case "the detail height is read off the line it draws"
            `Quick test_the_detail_height_is_read_off_the_line_it_draws
        ; Alcotest.test_case "the title does not count another queue" `Quick
            test_the_title_does_not_count_another_queue
        ; Alcotest.test_case "the Overview row counts every approval list"
            `Quick test_the_overview_row_counts_every_approval_list
        ; Alcotest.test_case "the summary row does not count the panel below"
            `Quick test_the_summary_row_does_not_count_the_panel_below_it
        ; Alcotest.test_case "the load stops reading a field no screen draws"
            `Quick test_the_overview_load_stops_reading_a_field_no_screen_draws
        ; Alcotest.test_case "the loader stops opening keys no screen draws"
            `Quick test_the_loader_stops_opening_keys_no_screen_draws
        ; Alcotest.test_case "the schedule counts read the shared status list"
            `Quick test_the_schedule_counts_are_read_from_the_shared_status_list
        ; Alcotest.test_case "the fleet row reads the control plane's word"
            `Quick test_the_fleet_row_reads_the_control_planes_own_word
        ; Alcotest.test_case "the operation is compared before repeating"
            `Quick
            test_the_detail_pane_compares_before_repeating_the_operation
        ; Alcotest.test_case "a lane mark says what its colour says" `Quick
            test_a_lane_mark_says_what_its_colour_says
        ; Alcotest.test_case "the schedule subject is measured" `Quick
            test_the_schedule_subject_is_measured_not_given_the_line
        ; Alcotest.test_case "the params row leads with what only it says" `Quick
            test_the_params_row_leads_with_what_only_it_says
        ; Alcotest.test_case "a detail heading is spelled like a heading" `Quick
            test_a_detail_heading_is_spelled_the_way_a_heading_is
        ; Alcotest.test_case "the two p50s on the Lanes screen agree" `Quick
            test_the_two_p50s_on_the_lanes_screen_agree
        ; Alcotest.test_case "the lane line writes no noun of its own" `Quick
            test_the_lane_line_writes_no_noun_of_its_own
        ; Alcotest.test_case "Board lane detail draws typed JEV readiness" `Quick
            test_board_lane_detail_draws_typed_jev_readiness
        ; Alcotest.test_case "the Code tree draws one folder arrow" `Quick
            test_the_code_tree_draws_one_folder_arrow
        ; Alcotest.test_case "the chat failure rows say the subject once" `Quick
            test_the_chat_failure_rows_say_the_subject_once
        ; Alcotest.test_case "the Logs header says the floor that was set" `Quick
            test_the_logs_header_says_the_floor_the_reader_set
        ; Alcotest.test_case "a labelled field does not bracket its reading" `Quick
            test_a_labelled_field_does_not_bracket_its_missing_reading
        ; Alcotest.test_case "the roster title says whether it is live" `Quick
            test_the_roster_title_says_whether_the_reading_is_live
        ; Alcotest.test_case "the schedule detail says what became of the wake"
            `Quick test_the_schedule_detail_says_what_became_of_the_wake
        ; Alcotest.test_case "the Schedules screen draws the runner hold"
            `Quick test_the_schedules_screen_draws_the_runner_hold
        ; Alcotest.test_case "Repositories show the server-resolved path"
            `Quick test_repositories_show_the_server_resolved_checkout_path
        ; Alcotest.test_case "Repository changes keep the Git axes" `Quick
            test_repository_changes_keep_the_git_axes
        ; Alcotest.test_case "Memory surface keeps the starvation axes" `Quick
            test_memory_surface_keeps_the_starvation_axes
        ; Alcotest.test_case "Project changes use the workspace root" `Quick
            test_project_changes_use_the_requested_workspace_root
        ; Alcotest.test_case "a turn on a keeper that is not running stops"
            `Quick test_a_turn_on_a_keeper_that_is_not_running_stops_moving
        ; Alcotest.test_case "why a lane cannot admit is the detail pane's"
            `Quick test_why_a_lane_cannot_admit_is_the_detail_panes_to_say
        ; Alcotest.test_case "visible navigation glyphs are not mojibake"
            `Quick test_visible_navigation_glyphs_are_not_mojibake
        ; Alcotest.test_case "the attention badge cannot cut its own level"
            `Quick test_the_attention_badge_cannot_cut_its_own_level
        ; Alcotest.test_case "the row cursor has one source" `Quick
            test_the_row_cursor_has_one_source
        ; Alcotest.test_case "the window is measured where the cursor lands"
            `Quick test_the_window_is_measured_where_the_cursor_lands
        ; Alcotest.test_case "no row of a drawing loop walks a list" `Quick
            test_no_row_of_a_drawing_loop_walks_a_list
        ; Alcotest.test_case "both strips mark where they are from one value"
            `Quick test_both_strips_mark_where_they_are_from_one_value
        ; Alcotest.test_case "the Approvals title counts what the badge does"
            `Quick test_the_approvals_title_counts_what_the_badge_counts
        ; Alcotest.test_case "the Board title counts through the helper" `Quick
            test_the_board_title_counts_through_the_helper_that_knows_the_board
        ; Alcotest.test_case "a stamp that can outlive today is a span" `Quick
            test_a_stamp_that_can_outlive_today_is_drawn_as_a_span
        ; Alcotest.test_case
            "the lane slot history says what it does not cover" `Quick
            test_the_lane_slot_history_says_what_it_does_not_cover
        ; Alcotest.test_case
            "both doors into the runtime detail ask the same lane list" `Quick
            test_both_doors_into_the_runtime_detail_ask_the_same_lane_list
        ; Alcotest.test_case "the Board age column reads the sort once" `Quick
            test_the_board_age_column_reads_the_sort_once
        ; Alcotest.test_case "an automation row says when it was asked for"
            `Quick test_an_automation_row_says_when_it_was_asked_for
        ; Alcotest.test_case "the automation row cuts the columns it draws"
            `Quick test_the_automation_row_cuts_the_columns_it_draws
        ] )
    ]
