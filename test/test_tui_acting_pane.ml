(* The Activity pane projects the feed the TUI already holds into a column
   beside any surface. These cases pin what the column says: who acted last
   comes first, a keeper waiting on the reader outranks a working one, the
   focus block names the current turn's calls, every row is exactly the
   pane's width so the surface beside it never shifts, each row names what a
   press on it acts on, scrolling walks the full list under the header, and
   the changes tab lists the selected keeper's files newest first. *)

open Alcotest
module Observer = Masc_tui_observer
module Acting = Masc_tui_acting
module Pane = Masc_tui_acting_pane

let now = 1_000.

let agent_core ?(kind = Observer.Tool_called) ?tool ?turn ?tool_use_id ~at
    ~correlation agent : Observer.event =
  Observer.Agent_core
    { Observer.kind
    ; agent = Some agent
    ; tool
    ; task = None
    ; turn
    ; tool_use_id
    ; batch = None
    ; at
    ; correlation = Some correlation
    ; parent = None
    }

let settled ~at keeper : Observer.event =
  Observer.Keeper_turn_complete
    { Observer.tc_keeper = keeper
    ; tc_turn = Some 41
    ; tc_model = None
    ; tc_input_tokens = Some 73_877
    ; tc_output_tokens = Some 358
    ; tc_cost_usd = Some 0.0258
    ; tc_tool_calls = Some 3
    ; tc_at = at
    }

(* Newest first, as the TUI holds them; each event arrives at its own [at]. *)
let entries events =
  events
  |> List.map (fun (at, event) -> { Acting.ae_at = at; ae_event = event })
  |> List.sort (fun a b -> Float.compare b.Acting.ae_at a.Acting.ae_at)

let keeper ?(mark = "\xe2\x97\x8f") ?(tone = Pane.Ok) name : Pane.keeper =
  { Pane.name; mark; mark_tone = tone; trace_id = "trace-" ^ name }

let lane = "agent_core-glm-coding.glm-5.3"

(* sangsu is mid-turn: one call returned, a second still out. rondo settled a
   turn earlier. polisher is waiting on an approval. quiet-one never acted.
   The full list is eight rows: four fleet rows, the rule, and sangsu's
   three focus rows (its header, Read, Execute). *)
let fixture : Pane.input =
  { Pane.now
  ; tab = Pane.Tab_fleet
  ; feed = Pane.Feed_live 1_234
  ; keepers =
      [ keeper "quiet-one" ~tone:Pane.Dim
      ; keeper "sangsu"
      ; keeper "rondo"
      ; keeper "polisher"
      ]
  ; selected = Some "sangsu"
  ; approvals = [ { Pane.approval_keeper = "polisher"; approval_tool = "tool_execute" } ]
  ; entries =
      entries
        [ (900., settled ~at:900. "rondo")
        ; ( 980.
          , agent_core ~kind:Observer.Turn_started ~turn:5 ~at:980.
              ~correlation:"trace-sangsu" lane )
        ; ( 981.
          , agent_core ~tool:"Read" ~turn:5 ~tool_use_id:"a" ~at:981.
              ~correlation:"trace-sangsu" lane )
        ; ( 983.
          , agent_core ~kind:Observer.Tool_completed ~tool:"Read" ~turn:5
              ~tool_use_id:"a" ~at:983. ~correlation:"trace-sangsu" lane )
        ; ( 990.
          , agent_core ~tool:"Execute" ~turn:5 ~tool_use_id:"b" ~at:990.
              ~correlation:"trace-sangsu" lane )
        ]
  ; changes = Pane.Changes_absent
  }

let full_list_rows = 8

let text (line : Pane.line) = String.concat "" (List.map (fun s -> s.Pane.text) line)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

let width (line : Pane.line) =
  List.fold_left
    (fun acc s -> acc + Masc_tui_message_layout.display_width s.Pane.text)
    0 line

let target_text = function
  | Pane.Target_none -> "none"
  | Pane.Target_next_tab -> "next-tab"
  | Pane.Target_keeper name -> "keeper:" ^ name
  | Pane.Target_more -> "more"
  | Pane.Target_file index -> "file:" ^ string_of_int index

let rows = 14
let cols = Pane.pane_cols
let drawn = Pane.lines ~rows ~cols ~scroll:0 fixture
let texts = List.map text drawn.Pane.rows
let nth i = List.nth texts i

let find_row_in texts name =
  match List.find_opt (fun row -> contains name row) texts with
  | Some row -> row
  | None -> failf "no row names %s in:\n%s" name (String.concat "\n" texts)

let find_row name = find_row_in texts name

let index_of_in texts name =
  let rec go i = function
    | [] -> failf "no row names %s" name
    | row :: rest -> if contains name row then i else go (i + 1) rest
  in
  go 0 texts

let index_of name = index_of_in texts name

(* ── width contract ─────────────────────────────────────────────────── *)

let wide = Pane.threshold_cols + 20
let narrow = Pane.threshold_cols - 1

let test_shown_needs_room_and_consent () =
  check bool "wide and wanted" true (Pane.shown ~hidden:false ~cols:wide);
  check bool "wide but put away" false (Pane.shown ~hidden:true ~cols:wide);
  check bool "narrow, whatever the reader wants" false (Pane.shown ~hidden:false ~cols:narrow)

let test_toggle_changes_only_a_visible_preference () =
  check (option bool) "wide can hide" (Some true) (Pane.toggle_hidden ~hidden:false ~cols:wide);
  check (option bool) "wide can show" (Some false) (Pane.toggle_hidden ~hidden:true ~cols:wide);
  check (option bool) "narrow leaves the preference" None
    (Pane.toggle_hidden ~hidden:false ~cols:narrow)

let test_content_cols_give_the_surface_the_rest () =
  check int "shown takes the pane" (wide - Pane.pane_cols)
    (Pane.content_cols ~hidden:false ~cols:wide);
  check int "hidden takes nothing" wide (Pane.content_cols ~hidden:true ~cols:wide);
  check int "narrow takes nothing" narrow (Pane.content_cols ~hidden:false ~cols:narrow)

let test_threshold_leaves_the_surface_the_roster_floor () =
  check int "surface floor is what the roster leaves"
    (Masc_tui_roster_pane.threshold_cols - Masc_tui_roster_pane.pane_cols)
    (Pane.threshold_cols - Pane.pane_cols)

(* ── rows ───────────────────────────────────────────────────────────── *)

let test_every_row_is_the_pane_width () =
  check int "exactly the rows asked for" rows (List.length drawn.Pane.rows);
  check int "one target per row" rows (List.length drawn.Pane.targets);
  List.iteri
    (fun i line -> check int (Printf.sprintf "row %d width" i) cols (width line))
    drawn.Pane.rows

let test_header_states_tabs_fleet_and_feed () =
  check bool "the fleet tab is up" true (contains "[Fleet]" (nth 0));
  check bool "the changes tab is named" true (contains "Changes" (nth 0));
  check bool "the changes tab is not the one up" false (contains "[Changes]" (nth 0));
  check bool "counts the fleet" true (contains "4 keepers" (nth 0));
  check bool "states the live feed" true (contains "live" (nth 0));
  check bool "counts the frames compactly" true (contains "1.2k events" (nth 0))

let test_fleet_orders_waiting_then_working_then_settled_then_quiet () =
  let polisher = index_of "polisher" and sangsu = index_of "sangsu"
  and rondo = index_of "rondo" and quiet = index_of "quiet-one" in
  check bool "approval first" true (polisher < sangsu);
  check bool "working before settled" true (sangsu < rondo);
  check bool "settled before quiet" true (rondo < quiet)

let test_fleet_rows_read_the_state () =
  check bool "waiting names the tool" true (contains "approval" (find_row "polisher"));
  check bool "waiting names which tool" true (contains "tool_execute" (find_row "polisher"));
  check bool "working names the call out" true (contains "Execute" (find_row "sangsu"));
  check bool "working counts its calls" true (contains "2 calls" (find_row "sangsu"));
  check bool "settled counts its calls" true (contains "3 calls" (find_row "rondo"));
  check bool "settled totals tokens compactly" true (contains "74.2k tok" (find_row "rondo"));
  check bool "quiet says so" true (contains "quiet" (find_row "quiet-one"))

let test_focus_block_names_the_current_turn () =
  let header = index_of "turn 5" in
  check bool "the turn is in flight" true (contains "in turn" (nth header));
  check bool "first call returned" true (contains "Read" (nth (header + 1)));
  check bool "with its duration" true (contains "2.0s" (nth (header + 1)));
  check bool "second call still out" true (contains "Execute" (nth (header + 2)));
  check bool "marked running" true (contains "running" (nth (header + 2)))

let test_focus_falls_back_to_who_acted_last () =
  let drawn = Pane.lines ~rows ~cols ~scroll:0 { fixture with Pane.selected = None } in
  let texts = List.map text drawn.Pane.rows in
  check bool "sangsu acted last" true
    (List.exists (fun row -> contains "turn 5" row) texts)

let test_narrow_budget_folds_the_fleet () =
  let drawn = Pane.lines ~rows:4 ~cols ~scroll:0 fixture in
  let texts = List.map text drawn.Pane.rows in
  check int "four rows" 4 (List.length drawn.Pane.rows);
  check bool "header stays" true (contains "[Fleet]" (List.nth texts 0));
  check bool "the fold counts what it hid" true
    (List.exists (fun row -> contains "2 more" row) texts);
  check bool "the fold is what a press scrolls into" true
    (List.mem Pane.Target_more drawn.Pane.targets)

(* ── targets ────────────────────────────────────────────────────────── *)

let test_targets_name_the_keeper_under_each_fleet_row () =
  let targets = List.map target_text drawn.Pane.targets in
  check string "the header switches the tab" "next-tab" (List.nth targets 0);
  check string "first fleet row is the waiting keeper" "keeper:polisher" (List.nth targets 1);
  check string "then the working one" "keeper:sangsu" (List.nth targets 2);
  check string "then the settled one" "keeper:rondo" (List.nth targets 3);
  check string "then the quiet one" "keeper:quiet-one" (List.nth targets 4);
  check string "the rule acts on nothing" "none" (List.nth targets 5);
  check string "focus rows act on nothing" "none" (List.nth targets (index_of "turn 5"));
  check string "padding acts on nothing" "none" (List.nth targets (rows - 1))

(* ── scroll ─────────────────────────────────────────────────────────── *)

let test_a_pane_that_fits_does_not_scroll () =
  check int "nothing to scroll into" 0 drawn.Pane.scroll_max;
  check bool "no fold" false (List.exists (fun row -> contains "more" row) texts);
  let scrolled = Pane.lines ~rows ~cols ~scroll:3 fixture in
  check (list string) "a scroll on a pane that fits draws the same rows" texts
    (List.map text scrolled.Pane.rows)

let short_rows = 6

let test_scrolling_walks_the_full_list_under_the_header () =
  let below = short_rows - 1 in
  let scrolled = Pane.lines ~rows:short_rows ~cols ~scroll:1 fixture in
  let texts = List.map text scrolled.Pane.rows in
  check int "the largest scroll shows the last row under the top indicator"
    (full_list_rows - (below - 1)) scrolled.Pane.scroll_max;
  check int "exactly the rows asked for" short_rows (List.length texts);
  check bool "header stays" true (contains "[Fleet]" (List.nth texts 0));
  check bool "the top indicator counts what is above" true
    (contains "\xe2\x86\x91 1 more" (List.nth texts 1));
  check bool "the first visible row is the second fleet row" true
    (contains "sangsu" (List.nth texts 2));
  check bool "the bottom indicator counts what is below" true
    (contains "\xe2\x86\x93 4 more" (List.nth texts (short_rows - 1)));
  check string "a visible fleet row still names its keeper" "keeper:sangsu"
    (target_text (List.nth scrolled.Pane.targets 2));
  check string "indicators act on nothing" "none"
    (target_text (List.nth scrolled.Pane.targets 1));
  List.iteri
    (fun i line -> check int (Printf.sprintf "scrolled row %d width" i) cols (width line))
    scrolled.Pane.rows

let test_scroll_clamps_at_the_last_row () =
  let at_max = Pane.lines ~rows:short_rows ~cols ~scroll:4 fixture in
  let texts = List.map text at_max.Pane.rows in
  check bool "the top indicator counts everything above" true
    (contains "\xe2\x86\x91 4 more" (List.nth texts 1));
  check bool "the last row of the list is on screen" true
    (contains "Execute" (List.nth texts (short_rows - 1)));
  check bool "no bottom indicator when nothing is below" false
    (List.exists (fun row -> contains "\xe2\x86\x93" row) texts);
  let past = Pane.lines ~rows:short_rows ~cols ~scroll:99 fixture in
  check (list string) "a scroll past the end draws the last window" texts
    (List.map text past.Pane.rows)

(* ── changes tab ────────────────────────────────────────────────────── *)

let file ?(kind = Pane.File_edited) ?(succeeded = true) ?where ~at path : Pane.file_row =
  { Pane.file_path = path
  ; file_kind = kind
  ; file_succeeded = succeeded
  ; file_at = at
  ; file_where = where
  }

(* Three files newest first: an edit with its range, a file written whole,
   and an edit that did not land. Fetched ten seconds ago. *)
let ready : Pane.changes =
  Pane.Changes_ready
    { keeper = "sangsu"
    ; files =
        [ file ~at:990. ~where:"L12-40" "masc:bin/masc_tui_acting_pane.ml"
        ; file ~at:985. ~kind:Pane.File_written ~where:"L1-80" "masc:test/test_tui_acting_pane.ml"
        ; file ~at:970. ~succeeded:false "masc:bin/masc_tui.ml"
        ]
    ; fetched_at = 990.
    ; window_hours = 24.
    ; calls = 12
    ; over_budget = 0
    ; malformed = 0
    }

let changes_fixture = { fixture with Pane.tab = Pane.Tab_changes; changes = ready }
let changes_drawn = Pane.lines ~rows ~cols ~scroll:0 changes_fixture
let changes_texts = List.map text changes_drawn.Pane.rows

let test_changes_header_marks_its_tab () =
  let header = List.nth changes_texts 0 in
  check bool "the changes tab is up" true (contains "[Changes]" header);
  check bool "the fleet tab is named" true (contains "Fleet" header);
  check bool "the fleet tab is not the one up" false (contains "[Fleet]" header);
  check bool "the feed still shows" true (contains "1.2k events" header);
  check string "the header switches the tab" "next-tab"
    (target_text (List.nth changes_drawn.Pane.targets 0));
  check bool "next tab flips" true
    (Pane.next_tab Pane.Tab_fleet = Pane.Tab_changes
     && Pane.next_tab Pane.Tab_changes = Pane.Tab_fleet)

let test_changes_status_names_the_keeper_and_the_fetch () =
  let status = List.nth changes_texts 1 in
  check bool "names the keeper" true (contains "sangsu" status);
  check bool "counts the files" true (contains "3 files" status);
  check bool "states the window" true (contains "24h" status);
  check bool "states how old the answer is" true (contains "10.0s ago" status);
  check string "the status acts on nothing" "none"
    (target_text (List.nth changes_drawn.Pane.targets 1))

let test_changes_rows_list_files_newest_first () =
  check bool "the newest edit first" true
    (contains "masc_tui_acting_pane.ml" (List.nth changes_texts 2));
  check bool "the edit shows its range" true (contains "L12-40" (List.nth changes_texts 2));
  check bool "the edit shows its age" true (contains "10.0s" (List.nth changes_texts 2));
  check bool "the write next" true
    (contains "test_tui_acting_pane.ml" (List.nth changes_texts 3));
  check bool "the write wears the written mark" true
    (contains "+ " (List.nth changes_texts 3));
  check bool "the failed edit last" true (contains "masc_tui.ml" (List.nth changes_texts 4));
  check bool "the failed edit wears the failed mark" true
    (contains "! " (List.nth changes_texts 4));
  check string "each row names its file" "file:0"
    (target_text (List.nth changes_drawn.Pane.targets 2));
  check string "in the order given" "file:2"
    (target_text (List.nth changes_drawn.Pane.targets 4));
  check string "padding acts on nothing" "none"
    (target_text (List.nth changes_drawn.Pane.targets (rows - 1)));
  List.iteri
    (fun i line -> check int (Printf.sprintf "changes row %d width" i) cols (width line))
    changes_drawn.Pane.rows

let status_of changes selected =
  let drawn =
    Pane.lines ~rows ~cols ~scroll:0
      { changes_fixture with Pane.changes; selected }
  in
  text (List.nth drawn.Pane.rows 1)

let test_changes_status_reads_each_state () =
  check bool "no keeper" true
    (contains "no keeper selected" (status_of ready None));
  check bool "not fetched" true
    (contains "changes not fetched" (status_of Pane.Changes_absent (Some "sangsu")));
  check bool "loading" true (contains "loading" (status_of Pane.Changes_loading (Some "sangsu")));
  check bool "failed says why" true
    (contains "failed" (status_of (Pane.Changes_failed "connection refused") (Some "sangsu"))
     && contains "connection refused"
          (status_of (Pane.Changes_failed "connection refused") (Some "sangsu")));
  let empty =
    Pane.Changes_ready
      { keeper = "sangsu"; files = []; fetched_at = 990.; window_hours = 24.; calls = 7
      ; over_budget = 0; malformed = 0 }
  in
  let drawn = Pane.lines ~rows ~cols ~scroll:0 { changes_fixture with Pane.changes = empty } in
  let texts = List.map text drawn.Pane.rows in
  check bool "no files says so with the call count" true
    (List.exists (fun row -> contains "no writes in 7 calls" row) texts);
  let dropped =
    Pane.Changes_ready
      { keeper = "sangsu"; files = []; fetched_at = 990.; window_hours = 24.; calls = 7
      ; over_budget = 2; malformed = 1 }
  in
  let drawn = Pane.lines ~rows ~cols ~scroll:0 { changes_fixture with Pane.changes = dropped } in
  let texts = List.map text drawn.Pane.rows in
  check bool "counts the changes the log kept no text for" true
    (List.exists (fun row -> contains "2 without text" row && contains "1 malformed" row) texts)

let test_changes_overflow_folds_and_scrolls () =
  (* header, status, three files: five rows. Four rows leave three below. *)
  let folded = Pane.lines ~rows:4 ~cols ~scroll:0 changes_fixture in
  let texts = List.map text folded.Pane.rows in
  check int "the largest scroll shows the last file under the top indicator" 2
    folded.Pane.scroll_max;
  check bool "status stays" true (contains "3 files" (List.nth texts 1));
  check bool "the first file shows" true (contains "masc_tui_acting_pane.ml" (List.nth texts 2));
  check bool "the bottom indicator counts what is hidden" true
    (contains "\xe2\x86\x93 2 more" (List.nth texts 3));
  let scrolled = Pane.lines ~rows:4 ~cols ~scroll:2 changes_fixture in
  let texts = List.map text scrolled.Pane.rows in
  check bool "the top indicator counts what is above" true
    (contains "\xe2\x86\x91 2 more" (List.nth texts 1));
  check bool "the last file is on screen" true (contains "masc_tui.ml" (List.nth texts 3));
  check string "a scrolled file row still names its file" "file:2"
    (target_text (List.nth scrolled.Pane.targets 3))

(* ── text ───────────────────────────────────────────────────────────── *)

let test_state_text_reads_each_case () =
  let plain spans = String.concat "" (List.map (fun s -> s.Pane.text) spans) in
  check bool "approval outranks a running turn" true
    (contains "approval" (plain (Pane.keeper_state_text ~now ~approval:(Some "Write") None)));
  check string "no chunk is quiet" "\xc2\xb7 quiet"
    (plain (Pane.keeper_state_text ~now ~approval:None None))

let test_tokens_and_ages_are_compact () =
  check string "both sides summed" "74.2k tok" (Pane.tokens_text (Some 73_877, Some 358));
  check string "one side alone" "358 tok" (Pane.tokens_text (None, Some 358));
  check string "unknown is empty" "" (Pane.tokens_text (None, None));
  check string "age in the feed's shape" "10.0s" (Pane.age_text ~now 990.);
  check string "a clock behind now is zero" "0ms" (Pane.age_text ~now 2_000.)

let () =
  run "tui acting pane"
    [ ( "width"
      , [ test_case "shown needs room and consent" `Quick test_shown_needs_room_and_consent
        ; test_case "toggle changes only a visible preference" `Quick
            test_toggle_changes_only_a_visible_preference
        ; test_case "content cols give the surface the rest" `Quick
            test_content_cols_give_the_surface_the_rest
        ; test_case "threshold leaves the surface the roster floor" `Quick
            test_threshold_leaves_the_surface_the_roster_floor
        ] )
    ; ( "rows"
      , [ test_case "every row is the pane width" `Quick test_every_row_is_the_pane_width
        ; test_case "header states tabs, fleet and feed" `Quick
            test_header_states_tabs_fleet_and_feed
        ; test_case "fleet orders waiting, working, settled, quiet" `Quick
            test_fleet_orders_waiting_then_working_then_settled_then_quiet
        ; test_case "fleet rows read the state" `Quick test_fleet_rows_read_the_state
        ; test_case "focus block names the current turn" `Quick
            test_focus_block_names_the_current_turn
        ; test_case "focus falls back to who acted last" `Quick
            test_focus_falls_back_to_who_acted_last
        ; test_case "narrow budget folds the fleet" `Quick test_narrow_budget_folds_the_fleet
        ] )
    ; ( "targets"
      , [ test_case "targets name the keeper under each fleet row" `Quick
            test_targets_name_the_keeper_under_each_fleet_row
        ] )
    ; ( "scroll"
      , [ test_case "a pane that fits does not scroll" `Quick
            test_a_pane_that_fits_does_not_scroll
        ; test_case "scrolling walks the full list under the header" `Quick
            test_scrolling_walks_the_full_list_under_the_header
        ; test_case "scroll clamps at the last row" `Quick test_scroll_clamps_at_the_last_row
        ] )
    ; ( "changes tab"
      , [ test_case "header marks its tab" `Quick test_changes_header_marks_its_tab
        ; test_case "status names the keeper and the fetch" `Quick
            test_changes_status_names_the_keeper_and_the_fetch
        ; test_case "rows list files newest first" `Quick
            test_changes_rows_list_files_newest_first
        ; test_case "status reads each state" `Quick test_changes_status_reads_each_state
        ; test_case "overflow folds and scrolls" `Quick
            test_changes_overflow_folds_and_scrolls
        ] )
    ; ( "text"
      , [ test_case "state text reads each case" `Quick test_state_text_reads_each_case
        ; test_case "tokens and ages are compact" `Quick test_tokens_and_ages_are_compact
        ] )
    ]
