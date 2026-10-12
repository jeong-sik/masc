(* The Activity pane projects the feed the TUI already holds into a column
   beside any surface. These cases pin what the column says: who acted last
   comes first, a keeper waiting on the reader outranks a working one, the
   focus block names the newest record's calls, every row is exactly the
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
    ; event_id = None
    ; run_id = None
    ; caused_by = None
    ; execution_id = None
    }

let settled ~at keeper : Observer.event =
  Observer.Keeper_turn_complete
    { Observer.tc_keeper = keeper
    ; tc_turn = Some 41
    ; tc_model = None
    ; tc_input_tokens = Some 73_877
    ; tc_cache_read_tokens = None
    ; tc_cache_creation_tokens = None
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

let keeper ?(mark = "\xe2\x97\x8f") ?(tone = Pane.Ok) ?(health = None) name : Pane.keeper =
  { Pane.name; mark; mark_tone = tone; health }

let chunks names values =
  Acting.chunks ~traces:(List.map (fun name -> name, "trace-" ^ name) names) values

let lane = "agent_core-glm-coding.glm-5.3"

(* tester is mid-turn: one call returned, a second still out. probe settled a
   turn earlier. polisher is waiting on an approval. quiet-one never acted.
   The full list is nine rows: four fleet rows, the rule, and tester's four
   focus rows (its header, the calls heading, Read, Execute). *)
let fixture_entries =
  entries
        [ (900., settled ~at:900. "probe")
        ; ( 905.
          , Observer.Keeper_tool_call
              { Observer.kt_keeper = "probe"
              ; kt_turn = None
              ; kt_tool = "keeper_artifact_read"
              ; kt_duration_ms = Some 5.
              ; kt_disposition = Some (Ok Masc.Tui_decode.Keeper_call_completed)
              ; kt_at = 905.
      ; kt_tool_use_id = None
      ; kt_schedule = None
      ; kt_tool_args = None
      ; kt_tool_result = None
      ; kt_tool_args_preview = None
      ; kt_tool_output_preview = None
              } )
        ; ( 980.
          , agent_core ~kind:Observer.Turn_started ~turn:5 ~at:980.
              ~correlation:"trace-tester" lane )
        ; ( 981.
          , agent_core ~tool:"Read" ~turn:5 ~tool_use_id:"a" ~at:981.
              ~correlation:"trace-tester" lane )
        ; ( 983.
          , agent_core ~kind:Observer.Tool_completed ~tool:"Read" ~turn:5
              ~tool_use_id:"a" ~at:983. ~correlation:"trace-tester" lane )
        ; ( 990.
          , agent_core ~tool:"Execute" ~turn:5 ~tool_use_id:"b" ~at:990.
              ~correlation:"trace-tester" lane )
        ]

let fixture : Pane.input =
  { Pane.now
  ; tab = Pane.Tab_fleet
  ; trace_unavailable = []
  ; keepers_error = None
  ; scope = Pane.Whole_fleet
  ; feed = Pane.Feed_live 1_234
  ; keepers =
      Some
        [ keeper "quiet-one" ~tone:Pane.Dim
        ; keeper "tester"
        ; keeper "probe"
        ; keeper "polisher"
        ]
  ; selected = Some "tester"
  ; approvals = [ { Pane.approval_keeper = "polisher"; approval_tool = "tool_execute" } ]
  ; chunks = chunks [ "quiet-one"; "tester"; "probe"; "polisher" ] fixture_entries
  ; changes = Pane.Changes_absent
  ; call_order = Pane.Oldest_first
  ; expanded = []
  }

let full_list_rows = 9

let text (line : Pane.line) = String.concat "" (List.map (fun s -> s.Pane.text) line)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0

let width (line : Pane.line) =
  List.fold_left
    (fun acc s -> acc + Masc_tui_message_layout.display_width s.Pane.text)
    0 line

let span_values (line : Pane.line) =
  List.map (fun (span : Pane.span) ->
    let tone = match span.tone with
      | Pane.Plain -> "plain" | Pane.Dim -> "dim" | Pane.Accent -> "accent"
      | Pane.Ok -> "ok" | Pane.Warn -> "warn" | Pane.Bad -> "bad" | Pane.Info -> "info"
    in
    span.text, tone) line

let test_trace_failure_is_readable_without_hiding_roster () =
  let input = { fixture with trace_unavailable = ["tester", "missing trace identity"] } in
  let drawn = Pane.lines ~rows:20 ~cols:90 ~scroll:0 input in
  let texts = List.map text drawn.Pane.rows in
  check bool "identity error is named" true
    (List.exists (contains "Trace unavailable: tester · missing trace identity") texts);
  check bool "independent roster count remains observed" true
    (List.exists (contains "4 keepers") texts);
  check bool "keeper navigation remains available" true
    (List.exists (function Pane.Target_keeper "tester" -> true | _ -> false) drawn.Pane.targets);
  let selected = Pane.lines ~rows:20 ~cols:90 ~scroll:0
    {input with scope = Pane.Selected_only; selected = Some "tester"} in
  check bool "selected keeper names its attribution failure" true
    (List.exists (fun line -> contains "missing trace identity" (text line)) selected.Pane.rows)

let test_many_trace_failures_keep_navigation_and_full_reading () =
  let failures = List.init 20 (fun index ->
      Printf.sprintf "unbooted-%02d" index, Printf.sprintf "reason-%02d" index) in
  let input = { fixture with trace_unavailable = failures } in
  check (option string) "one bounded summary points to full reasons"
    (Some "Trace unavailable: 20 Keepers · details in Keeper Info / Metadata")
    (Pane.trace_unavailable_summary failures);
  List.iter (fun (rows, cols) ->
      let overview = Pane.lines ~rows ~cols ~scroll:0 input in
      check int "pane stays inside its row budget" rows (List.length overview.Pane.rows);
      check bool "failure summaries leave fleet navigation visible" true
        (List.exists (function Pane.Target_keeper _ | Pane.Target_more -> true | _ -> false)
           overview.Pane.targets);
      List.iter (fun line -> check int "narrow rows stay fitted" cols (width line)) overview.Pane.rows)
    [8, 42; 3, 30];
  let compact = Pane.lines ~rows:3 ~cols:30 ~scroll:0 input in
  let compact_scrolled = Pane.lines ~rows:3 ~cols:30 ~scroll:1 input in
  check int "folding preserves the full body's scroll range"
    compact.Pane.scroll_max compact_scrolled.Pane.scroll_max;
  check bool "one-row viewport still scrolls through failures" true
    (List.exists (fun line -> contains "Trace unavailable:" (text line)) compact_scrolled.Pane.rows);
  let reading = Pane.lines ~rows:8 ~cols:90 ~scroll:1 input in
  check bool "first full failure reason is reachable after the overview" true
    (List.exists (fun line -> contains "unbooted-00 · reason-00" (text line)) reading.Pane.rows);
  List.iter (fun rows ->
    let first = Pane.lines ~rows ~cols:90 ~scroll:1 input in
    check bool "first detail survives even one body row" true
      (List.exists (fun line -> contains "unbooted-00 · reason-00" (text line)) first.Pane.rows);
    let all = List.init (first.Pane.scroll_max + 1) (fun scroll ->
      (Pane.lines ~rows ~cols:90 ~scroll input).Pane.rows)
      |> List.concat |> List.map text in
    List.iter (fun (name, reason) ->
      check bool (name ^ " detail is reachable") true
        (List.exists (contains (name ^ " · " ^ reason)) all)) failures)
    [3; 8]

let target_text = function
  | Pane.Target_none -> "none"
  | Pane.Target_next_tab -> "next-tab"
  | Pane.Target_keeper name -> "keeper:" ^ name
  | Pane.Target_more -> "more"
  | Pane.Target_file index -> "file:" ^ string_of_int index
  | Pane.Target_calls name -> "calls:" ^ name
  | Pane.Target_call (name, _) -> "call:" ^ name
  | Pane.Target_call_order -> "order"

let rows = 14
let cols = Pane.pane_cols
let drawn = Pane.lines ~rows ~cols ~scroll:0 fixture
let texts = List.map text drawn.Pane.rows
let index_of_in texts name =
  let rec go i = function
    | [] -> failf "no row names %s" name
    | row :: rest -> if contains name row then i else go (i + 1) rest
  in
  go 0 texts

let last_index_of_in texts name =
  let rec go i best = function
    | [] -> Option.value ~default:0 best
    | row :: rest ->
        go (i + 1) (if contains name row then Some i else best) rest
  in
  go 0 None texts

let last_index_of name = last_index_of_in texts name

let roomy = Pane.wide_threshold_cols + 20
let middling = Pane.wide_threshold_cols - 1
let narrow = Pane.threshold_cols - 1

let layout =
  testable (fun ppf l -> Format.pp_print_string ppf (Pane.layout_label l)) ( = )

let test_ctrl_l_walks_narrow_wide_hidden () =
  let step layout_now cols = Pane.next_layout ~layout:layout_now ~cols in
  check (option layout) "narrow to wide" (Some Pane.Wide) (step Pane.Narrow roomy);
  check (option layout) "wide to hidden" (Some Pane.Hidden) (step Pane.Wide roomy);
  check (option layout) "hidden to narrow" (Some Pane.Narrow) (step Pane.Hidden roomy);
  check (option layout) "no room for wide: narrow to hidden" (Some Pane.Hidden)
    (step Pane.Narrow middling);
  check (option layout) "no room at all leaves the choice" None (step Pane.Narrow narrow);
  check (option layout) "exactly room for wide: narrow to wide" (Some Pane.Wide)
    (step Pane.Narrow Pane.wide_threshold_cols);
  check (option layout) "exactly room for narrow: hidden to narrow" (Some Pane.Narrow)
    (step Pane.Hidden Pane.threshold_cols)

let test_every_row_is_the_pane_width () =
  check int "exactly the rows asked for" rows (List.length drawn.Pane.rows);
  check int "one target per row" rows (List.length drawn.Pane.targets);
  List.iteri
    (fun i line -> check int (Printf.sprintf "row %d width" i) cols (width line))
    drawn.Pane.rows

let test_narrow_budget_folds_the_fleet () =
  let drawn = Pane.lines ~rows:4 ~cols ~scroll:0 fixture in
  let texts = List.map text drawn.Pane.rows in
  check int "four rows" 4 (List.length drawn.Pane.rows);
  check bool "header stays" true (contains "[Recent]" (List.nth texts 0));
  check bool "the fold counts what it hid" true
    (List.exists (fun row -> contains "3 more" row) texts);
  check bool "the fold is what a press scrolls into" true
    (List.mem Pane.Target_more drawn.Pane.targets)

let test_folded_and_scrolled_views_preserve_keeper_row_and_focus () =
  let name = "한e\204\129🙂" in
  let input = { fixture with
    Pane.keepers = Some [ keeper "quiet"; keeper name; keeper "second"; keeper "approval" ];
    selected = Some name;
    approvals = [ { Pane.approval_keeper = "approval"; approval_tool = "검토🙂" } ];
    chunks = chunks [ name; "quiet"; "second"; "approval" ] @@ entries
      [ 990., agent_core ~tool:"Read한🙂" ~turn:5 ~tool_use_id:"unicode"
          ~at:990. ~correlation:("trace-" ^ name) lane;
        980., settled ~at:980. "second" ] } in
  let keeper_row view =
    List.combine view.Pane.rows view.Pane.targets
    |> List.find (fun (_, target) -> target = Pane.Target_keeper name)
    |> fst |> span_values
  in
  let full = Pane.lines ~rows:14 ~cols ~scroll:0 input in
  let folded = Pane.lines ~rows:8 ~cols ~scroll:0 input in
  let scrolled = Pane.lines ~rows:6 ~cols ~scroll:1 input in
  check (list (pair string string)) "folded keeper keeps text, tones and click target"
    (keeper_row full) (keeper_row folded);
  check (list (pair string string)) "scrolled keeper keeps text, tones and click target"
    (keeper_row full) (keeper_row scrolled);
  let folded_text = List.map text folded.Pane.rows in
  check bool "overview fold counts both hidden keepers" true
    (contains "2 more" (List.nth folded_text 4));
  check string "fold remains actionable" "more" (target_text (List.nth folded.targets 4));
  check bool "overview focus still belongs to selected Unicode keeper" true
    (contains name (List.nth folded_text 6));
  check bool "overview focus shows current receipt age" true
    (contains "last event 10.0s" (List.nth folded_text 6));
  let later = Pane.lines ~rows:8 ~cols ~scroll:0 { input with Pane.now = now +. 20. } in
  check bool "a later frame advances the receipt age on the header" true
    (contains "last event 30.0s" (text (List.nth later.Pane.rows 6)))

(* ── targets ────────────────────────────────────────────────────────── *)

let test_targets_name_the_keeper_under_each_fleet_row () =
  let targets = List.map target_text drawn.Pane.targets in
  check string "the header switches the tab" "next-tab" (List.nth targets 0);
  check string "the legend acts on nothing" "none" (List.nth targets 1);
  check string "first fleet row is the waiting keeper" "keeper:polisher" (List.nth targets 2);
  check string "then the working one" "keeper:tester" (List.nth targets 3);
  check string "then the settled one" "keeper:probe" (List.nth targets 4);
  check string "then the quiet one" "keeper:quiet-one" (List.nth targets 5);
  check string "the rule acts on nothing" "none" (List.nth targets 6);
  let header = last_index_of "tester" in
  check string "the focus header acts on nothing" "none" (List.nth targets header);
  check string "the calls heading turns the order" "order" (List.nth targets (header + 1));
  check string "a call row opens that call" "call:tester" (List.nth targets (header + 2));
  check string "so does the call still out" "call:tester" (List.nth targets (header + 3));
  check string "padding acts on nothing" "none" (List.nth targets (rows - 1))

(* ── scroll ─────────────────────────────────────────────────────────── *)

let short_rows = 6
let header_rows = 2

let test_scrolling_walks_the_full_list_under_the_header () =
  let below = short_rows - header_rows in
  let scrolled = Pane.lines ~rows:short_rows ~cols ~scroll:1 fixture in
  let texts = List.map text scrolled.Pane.rows in
  check int "the largest scroll shows the last row under the top indicator"
    (full_list_rows - (below - 1)) scrolled.Pane.scroll_max;
  check int "exactly the rows asked for" short_rows (List.length texts);
  check bool "header stays" true (contains "[Recent]" (List.nth texts 0));
  check bool "the top indicator counts what is above" true
    (contains "\xe2\x86\x91 1 more" (List.nth texts header_rows));
  check bool "the first visible row is the second fleet row" true
    (contains "tester" (List.nth texts (header_rows + 1)));
  check bool "the bottom indicator counts what is below" true
    (contains "\xe2\x86\x93 6 more" (List.nth texts (short_rows - 1)));
  check string "a visible fleet row still names its keeper" "keeper:tester"
    (target_text (List.nth scrolled.Pane.targets (header_rows + 1)));
  check string "indicators act on nothing" "none"
    (target_text (List.nth scrolled.Pane.targets header_rows));
  List.iteri
    (fun i line -> check int (Printf.sprintf "scrolled row %d width" i) cols (width line))
    scrolled.Pane.rows

let test_legend_preserves_reachable_targets_in_small_windows () =
  List.iter
    (fun rows ->
      let first = Pane.lines ~rows ~cols ~scroll:0 fixture in
      let windows = List.init (first.Pane.scroll_max + 1)
          (fun scroll -> Pane.lines ~rows ~cols ~scroll fixture) in
      let targets = List.concat_map (fun value -> value.Pane.targets) windows in
      List.iter
        (fun name ->
          check bool (Printf.sprintf "%d rows can reach %s" rows name) true
            (List.mem (Pane.Target_keeper name) targets))
        [ "polisher"; "tester"; "probe"; "quiet-one" ];
      List.iter
        (fun value ->
          check int "small window keeps row budget" rows (List.length value.Pane.rows);
          check int "small window keeps target budget" rows (List.length value.Pane.targets);
          List.iter (fun line -> check int "small row width" cols (width line)) value.Pane.rows;
          check bool "legend stays visible while scrolling" true
            (contains (Pane.legend ~cols) (text (List.nth value.Pane.rows 1))))
        windows)
    [ 3; 4; 5; 6 ];
  List.iter
    (fun rows ->
      let value = Pane.lines ~rows ~cols ~scroll:99 fixture in
      check int "header-only height remains bounded" rows (List.length value.Pane.rows);
      check int "no body means no scroll destination" 0 value.Pane.scroll_max)
    [ 0; 1; 2 ]

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
    { keeper = "tester"
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
    ; refresh_failed = None
    }

let changes_fixture = { fixture with Pane.tab = Pane.Tab_changes; changes = ready }
let changes_drawn = Pane.lines ~rows ~cols ~scroll:0 changes_fixture
let changes_texts = List.map text changes_drawn.Pane.rows

let test_changes_header_marks_its_tab () =
  let header = List.nth changes_texts 0 in
  check bool "the changes tab is up" true (contains "[Changes]" header);
  check bool "the fleet tab is named" true (contains "Recent" header);
  check bool "the fleet tab is not the one up" false (contains "[Recent]" header);
  check bool "a live feed still takes no words" false (contains "feed" header);
  check string "the header switches the tab" "next-tab"
    (target_text (List.nth changes_drawn.Pane.targets 0));
  check bool "next tab flips" true
    (Pane.next_tab Pane.Tab_fleet = Pane.Tab_changes
     && Pane.next_tab Pane.Tab_changes = Pane.Tab_fleet)

let test_changes_status_names_the_keeper_and_the_fetch () =
  let status = List.nth changes_texts 1 in
  check bool "names the keeper" true (contains "tester" status);
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

let test_reused_chunks_keep_presentation_inputs_live () =
  let traces = [ "tester", "trace-tester"; "probe", "trace-probe" ] in
  let projection = Acting.refresh_projection ~previous:None ~traces fixture_entries in
  let reused = Acting.refresh_projection ~previous:(Some projection)
    ~traces:(List.map Fun.id traces) fixture_entries in
  check bool "event projection is reused" true (projection == reused);
  let input = { fixture with Pane.chunks = Acting.projection_chunks reused } in
  let row_for name view = List.combine view.Pane.rows view.Pane.targets
    |> List.find (fun (_, target) -> target = Pane.Target_keeper name)
    |> fst |> text in
  let initial = Pane.lines ~rows ~cols ~scroll:0 input in
  let header_of name view =
    let texts = List.map text view.Pane.rows in
    List.nth texts (last_index_of_in texts name)
  in
  check bool "initial event age on the header" true
    (contains "last event 10.0s" (header_of "tester" initial));
  let changed = { input with Pane.now = now +. 20.; selected = Some "probe" } in
  let later = Pane.lines ~rows ~cols ~scroll:0 changed in
  check bool "age advances independently of chunks" true
    (contains "last event 1m55s" (header_of "probe" later));
  (* Health is read on every frame as well: over the same reused chunks, a
     keeper whose keepalive has gone loses its fleet row. Running and idle
     draw the same record state, so offline is the reading that shows. *)
  let gone = { changed with
    keepers = Option.map (List.map (fun (keeper : Pane.keeper) ->
      if keeper.name = "tester" then { keeper with health = Some Masc.Tui_decode.Health_offline }
      else keeper)) changed.keepers } in
  check bool "new health changes the fleet rows" false
    (List.mem (Pane.Target_keeper "tester") (Pane.lines ~rows ~cols ~scroll:0 gone).Pane.targets);
  let later_text = List.map text later.Pane.rows in
  check bool "new selection changes focus keeper" true
    (contains "turn 41" (List.nth later_text (last_index_of_in later_text "probe")));
  let pending = { changed with approvals =
    [ { Pane.approval_keeper = "tester"; approval_tool = "Write" } ] } in
  let approved_view = Pane.lines ~rows:6 ~cols ~scroll:0 pending in
  check bool "new approval is visible and takes ordering priority" true
    (contains "approval" (row_for "tester" approved_view));
  check string "click target follows newly prioritized keeper" "keeper:tester"
    (target_text (List.nth approved_view.Pane.targets 2));
  check int "viewport budget remains live" 6 (List.length approved_view.Pane.rows)

(* Hidden content must remain reachable without paying its Unicode layout
   allocation on every frame. Compare the same logical viewport with short
   and long hidden text, outside fixture construction; avoid wall-clock bounds. *)
let test_hidden_rows_do_not_allocate_text_layout () =
  let count = 64 in
  let long_text = String.concat "" (List.init 256 (fun _ -> "한🙂e\204\129")) in
  let label long i =
    Printf.sprintf "row-%03d%s" i (if long && i >= 2 then long_text else "")
  in
  let empty = { fixture with Pane.keepers = Some []; selected = None;
    approvals = []; chunks = [] } in
  let fleet long = { empty with Pane.keepers =
    Some (List.init count (fun i -> keeper (label long i))) } in
  let focus long =
    let events = List.init count (fun i ->
      let at = 900. +. float_of_int i in
      at, agent_core ~tool:(label long i) ~turn:5
        ~tool_use_id:(string_of_int i) ~at ~correlation:"trace-tester" lane) in
    { empty with Pane.selected = Some "tester";
      chunks = chunks ["tester"] (entries events) }
  in
  let changes long = { empty with Pane.tab = Pane.Tab_changes;
    selected = Some "tester";
    changes = Pane.Changes_ready {
      keeper = "tester";
      files = List.init count (fun i -> file ~at:990. (label long i));
      fetched_at = 990.; window_hours = 24.; calls = count;
      over_budget = 0; malformed = 0; refresh_failed = None } } in
  let measure rows input =
    ignore (Sys.opaque_identity (Pane.lines ~rows ~cols ~scroll:0 input));
    (* The warm-up laid these texts out in this frame, and a text laid out
       again in the same frame takes the pieces it kept. Two frames on, the
       measured call splits every text it lays out, as a frame that meets
       the rows for the first time does. *)
    Masc_tui_message_layout.begin_frame ();
    Masc_tui_message_layout.begin_frame ();
    let before = Gc.allocated_bytes () in
    let result = Sys.opaque_identity (Pane.lines ~rows ~cols ~scroll:0 input) in
    let allocated = Gc.allocated_bytes () -. before in
    result, allocated
  in
  List.iter (fun (name, rows, make) ->
    let short = make false and long = make true in
    let expected, short_bytes = measure rows short in
    let actual, long_bytes = measure rows long in
    check (list (list (pair string string))) (name ^ ": visible spans unchanged")
      (List.map span_values expected.Pane.rows) (List.map span_values actual.Pane.rows);
    check (list string) (name ^ ": visible targets unchanged")
      (List.map target_text expected.targets) (List.map target_text actual.targets);
    check int (name ^ ": all hidden rows still contribute to scroll range")
      expected.scroll_max actual.scroll_max;
    check bool (name ^ ": content beyond viewport remains reachable") true
      (actual.scroll_max > 0);
    (* A twofold allowance absorbs small bookkeeping differences. Formatting
       the hidden long graphemes allocates far more than this, independently
       of runner speed and without restricting the length of visible text. *)
    check bool
      (Printf.sprintf "%s: hidden text layout allocation bounded (short=%.0f long=%.0f)"
         name short_bytes long_bytes)
      true (long_bytes <= short_bytes *. 2.);
    let last = Pane.lines ~rows ~cols ~scroll:actual.scroll_max long in
    List.iter (fun row -> check int (name ^ ": revealed rows retain cell width") cols (width row))
      last.Pane.rows;
    match name with
    | "fleet" -> check bool "last hidden keeper retains its full click target" true
        (List.mem (Pane.Target_keeper (label true (count - 1))) last.targets)
    | "changes" -> check bool "last hidden file retains its original index" true
        (List.mem (Pane.Target_file (count - 1)) last.targets)
    | _ -> check bool "last hidden tool becomes visible" true
        (List.exists (fun row -> contains "row-063" (text row)) last.Pane.rows))
    ["fleet", 5, fleet; "focus", 6, focus; "changes", 4, changes]

let settled_earlier ?(turn = 3141) ?(calls = 3) ?(input = 73_877) ?(output = 358)
    ?(cost = 0.0258) ?cache_read ?cache_creation () =
  match settled ~at:980. "tester" with
  | Observer.Keeper_turn_complete value ->
    Observer.Keeper_turn_complete
      { value with
        tc_turn = Some turn
      ; tc_tool_calls = Some calls
      ; tc_input_tokens = Some input
      ; tc_cache_read_tokens = cache_read
      ; tc_cache_creation_tokens = cache_creation
      ; tc_output_tokens = Some output
      ; tc_cost_usd = Some cost
      }
  | _ -> fail "settled fixture must carry a turn completion"

let earlier_turn_input ?turn ?calls ?input ?output ?cost ?cache_read ?cache_creation () =
  { fixture with
    Pane.keepers = Some [ keeper "tester" ]; approvals = []
  ; chunks = chunks [ "tester" ] @@ entries
      [ 990., agent_core ~kind:Observer.Turn_started ~turn:6 ~at:990.
          ~correlation:"trace-tester" lane
      ; 980., settled_earlier ?turn ?calls ?input ?output ?cost ?cache_read
          ?cache_creation ()
      ; 970., agent_core ~kind:Observer.Turn_started ~turn:5 ~at:970.
          ~correlation:"trace-tester" lane
      ]
  }

let rule_glyphs = "\xe2\x94\x80\xe2\x94\x80"

let keeper_targets view =
  List.filter_map
    (function Pane.Target_keeper name -> Some name | _ -> None)
    view.Pane.targets

let test_beside_the_roster_only_the_selected_keepers_record_draws () =
  let view =
    Pane.lines ~rows ~cols ~scroll:0
      { fixture with Pane.scope = Pane.Selected_only; approvals = [] }
  in
  let texts = List.map text view.Pane.rows in
  check bool "the header names the tabs" true (contains "[Recent]" (List.nth texts 0));
  check bool "a live feed takes no words here either" false
    (contains "feed" (List.nth texts 0));
  check bool "the header does not count the fleet" false (contains "keepers" (List.nth texts 0));
  check bool "the legend stays" true (contains (Pane.legend ~cols) (List.nth texts 1));
  check (list string) "no fleet row" [] (keeper_targets view);
  check bool "no rule" false (List.exists (fun row -> contains rule_glyphs row) texts);
  check bool "the selected keeper's header is first under the legend" true
    (contains "tester" (List.nth texts 2) && contains "last event 10.0s" (List.nth texts 2));
  check string "the calls heading follows" "order" (target_text (List.nth view.Pane.targets 3));
  check string "its call rows open the call" "call:tester" (target_text (List.nth view.Pane.targets 4));
  check int "everything fits" 0 view.Pane.scroll_max;
  List.iteri
    (fun i line -> check int (Printf.sprintf "row %d width" i) cols (width line))
    view.Pane.rows

(* The roster does not say who is waiting on an approval, so beside it the
   pane keeps those rows and nothing else of the fleet. *)
let test_beside_the_roster_keepers_waiting_on_approval_still_draw () =
  let view = Pane.lines ~rows ~cols ~scroll:0 { fixture with Pane.scope = Pane.Selected_only } in
  let texts = List.map text view.Pane.rows in
  check (list string) "only the waiting keeper keeps a fleet row" [ "polisher" ] (keeper_targets view);
  check bool "and the row says what it waits on" true
    (contains "approval" (List.nth texts 2) && contains "tool_execute" (List.nth texts 2));
  check bool "a rule separates it from the record" true (contains rule_glyphs (List.nth texts 3));
  check bool "the selected keeper's header follows" true (contains "tester" (List.nth texts 4));
  check string "its call rows still open the call" "call:tester"
    (target_text (List.nth view.Pane.targets 6))

let test_an_earlier_turn_row_opens_the_keepers_calls () =
  let value = Pane.lines ~rows ~cols ~scroll:0 (earlier_turn_input ()) in
  let texts = List.map text value.Pane.rows in
  let index = index_of_in texts "turn 3141" in
  check string "the turn row opens the calls surface" "calls:tester"
    (target_text (List.nth value.Pane.targets index))

module Contract = Agent_core.Tool_contract

let schedule ~step ~batch_index ~at_once execution_mode : Contract.schedule =
  { Contract.planned_index = step - 1; batch_index; batch_size = at_once; execution_mode }

let runner_call ~at ?duration_ms ~id ?(session = Some 12) ?schedule ?disposition ?input
    ?output tool =
  ( at
  , Observer.Keeper_tool_call
      { Observer.kt_keeper = "runner"
      ; kt_turn = session
      ; kt_tool = tool
      ; kt_duration_ms = duration_ms
      ; kt_disposition = disposition
      ; kt_at = at
      ; kt_tool_use_id = Some id
      ; kt_schedule = Option.map Result.ok schedule
      ; kt_tool_args = None
      ; kt_tool_result = None
      ; kt_tool_args_preview = input
      ; kt_tool_output_preview = output
      } )

(* runner's turn: a serial read that completed, a delegation that ran in a
   batch of three and returned a deferral, and a failed execute still without
   a duration. Receipt order is Read, masc_delegate, Execute. *)
let runner_calls =
  [ runner_call ~at:950. ~duration_ms:5. ~id:"first"
      ~schedule:(schedule ~step:1 ~batch_index:0 ~at_once:1 Contract.Serial)
      ~disposition:(Ok Masc.Tui_decode.Keeper_call_completed)
      ~input:"{\"path\":\"lib/a.ml\"}" ~output:"12 lines" "Read"
  ; runner_call ~at:960. ~duration_ms:50. ~id:"second"
      ~schedule:(schedule ~step:2 ~batch_index:1 ~at_once:3 Contract.Concurrent)
      ~disposition:(Ok Masc.Tui_decode.Keeper_call_deferred)
      ~input:"{\"to\":\"probe\"}" ~output:"queued\nkmsg-1" "masc_delegate"
  ; runner_call ~at:970. ~id:"third"
      ~disposition:(Ok Masc.Tui_decode.Keeper_call_failed)
      ~input:"{\"cmd\":\"false\"}" "Execute"
  ]

let runner_input ?(order = Pane.Oldest_first) ?(expanded = []) () =
  { fixture with
    Pane.scope = Pane.Selected_only
  ; keepers = Some [ keeper "runner" ]
  ; selected = Some "runner"
  ; approvals = []
  ; chunks = chunks [ "runner" ] (entries runner_calls)
  ; call_order = order
  ; expanded
  }

let call_rows view =
  List.combine view.Pane.rows view.Pane.targets
  |> List.filter_map (fun (row, target) ->
         match target with
         | Pane.Target_call ("runner", _) -> Some (text row)
         | _ -> None)

(* Beside the roster the rows are: header, legend, focus header, calls
   heading, then the calls. *)
let first_call_row = 4

(* A turn that ran the same tool five times drew five rows saying the same
   word, in a list about twenty rows long (masc-pro-builder, 2026-09-22).
   The run is one row that counts it and says what the calls took; the
   Keeper Calls surface is where each one is read. *)
let repeated_calls =
  List.map
    (fun (index, duration) ->
      runner_call ~at:(950. +. float_of_int index) ~duration_ms:duration
        ~id:(Printf.sprintf "exec-%d" index)
        ~disposition:(Ok Masc.Tui_decode.Keeper_call_completed)
        ~input:"{\"cmd\":\"ls\"}" "Execute")
    [ 0, 2700.; 1, 274.; 2, 1400.; 3, 2900.; 4, 4700. ]

let repeated_input () =
  (* One other call before the run, so the rows are the other call and the
     run rather than the run alone. *)
  let other =
    runner_call ~at:900. ~duration_ms:5. ~id:"read"
      ~disposition:(Ok Masc.Tui_decode.Keeper_call_completed)
      ~input:"{\"path\":\"lib/a.ml\"}" ~output:"12 lines" "Read"
  in
  { (runner_input ()) with
    Pane.chunks = chunks [ "runner" ] (entries (other :: repeated_calls))
  }

let run_row view =
  match List.filter (fun row -> contains "Execute" row) (call_rows view) with
  | row :: _ -> row
  | [] -> fail "no Execute row"

let test_a_run_of_one_tool_is_one_counted_row () =
  let view = Pane.lines ~rows ~cols:Pane.wide_pane_cols ~scroll:0 (repeated_input ()) in
  check int "the run and the other call are two rows" 2 (List.length (call_rows view));
  let run = run_row view in
  check bool ("the run counts its calls: " ^ run) true (contains "Execute \xc3\x975" run);
  check bool "and says what each took" true
    (contains "2.7s 274ms 1.4s 2.9s 4.7s" run)

let test_an_opened_call_draws_its_facts_and_previews () =
  let view =
    Pane.lines ~rows ~cols ~scroll:0
      (runner_input ~expanded:[ "runner", Acting.Call_by_id "second" ] ())
  in
  let texts = List.map text view.Pane.rows in
  let facts = List.nth texts (first_call_row + 2) in
  check bool "the disposition first, then the receipt age" true
    (contains "deferred \xc2\xb7 40.0s ago" facts);
  check bool "the schedule in words" true (contains "concurrent, 3 at once" facts);
  check bool "no planned step: the list already shows the order" false
    (contains "step" facts);
  check bool "the input preview" true
    (contains "in  {\"to\":\"probe\"}" (List.nth texts (first_call_row + 3)));
  let out = List.nth texts (first_call_row + 4) in
  check bool "the output preview on one row" true
    (contains "out queued" out && contains "kmsg-1" out && not (contains "\n" out));
  check bool "the next call follows the detail" true
    (contains "Execute" (List.nth texts (first_call_row + 5)));
  List.iter
    (fun i ->
      check string (Printf.sprintf "detail row %d closes the same call" i) "call:runner"
        (target_text (List.nth view.Pane.targets (first_call_row + i))))
    [ 1; 2; 3; 4 ];
  check bool "the unopened calls draw no detail" false
    (List.exists (fun row -> contains "lib/a.ml" row) texts);
  List.iteri
    (fun i line -> check int (Printf.sprintf "row %d width" i) cols (width line))
    view.Pane.rows

let test_each_order_lists_the_calls_as_the_heading_says () =
  List.iter
    (fun (order, label, expected) ->
      let view = Pane.lines ~rows ~cols ~scroll:0 (runner_input ~order ()) in
      let texts = List.map text view.Pane.rows in
      check bool (label ^ ": the heading names it") true
        (contains ("calls \xc2\xb7 " ^ label) (List.nth texts 3));
      check string (label ^ ": the heading turns the order") "order"
        (target_text (List.nth view.Pane.targets 3));
      let names = List.map (fun row -> String.trim row) (call_rows view) in
      List.iter2
        (fun name row -> check bool (label ^ ": " ^ name) true (contains name row))
        expected names)
    [ Pane.Oldest_first, "oldest first", [ "Read"; "masc_delegate"; "Execute" ]
    ; Pane.Newest_first, "newest first", [ "Execute"; "masc_delegate"; "Read" ]
    ; Pane.Longest_first, "longest first", [ "masc_delegate"; "Read"; "Execute" ]
    ; Pane.By_tool, "by tool", [ "Execute"; "Read"; "masc_delegate" ]
    ]

let test_the_order_cycles_through_all_four () =
  let rec walk seen order =
    if List.mem order seen then List.rev seen
    else walk (order :: seen) (Pane.next_call_order order)
  in
  check int "four orders before it comes back" 4
    (List.length (walk [] Pane.Oldest_first));
  check bool "the first press from newest first turns time around" true
    (Pane.next_call_order Pane.Newest_first = Pane.Oldest_first)

(* ── calls: a bracket per model response ───────────────────────────── *)

(* The hook's per-call report: provider call [session] ran while runner had
   eleven keeper turns done, so it belongs to keeper turn 12. With it the
   fold files calls from two provider calls into one record, as the live
   feed does. *)
let observed ~at session =
  ( at
  , Observer.Keeper_turn_observation
      { Observer.to_keeper = "runner"
      ; to_session_turn = Some session
      ; to_total_turns = Some 11
      ; to_at = at
      } )

let opens = "\xe2\x94\x8c"
let inside = "\xe2\x94\x82"
let closes = "\xe2\x94\x94"

let test_a_call_row_names_the_call_a_press_opens () =
  let view = Pane.lines ~rows ~cols ~scroll:0 (runner_input ()) in
  check bool "by the provider's call id" true
    (List.nth view.Pane.targets first_call_row
     = Pane.Target_call ("runner", Acting.Call_by_id "first"))

(* Ctrl-W's cursor rests only where Enter would do something: the step
   skips legend, rule, and padding rows, in both directions, and finds the
   first row from before the frame. *)
let cursor_targets =
  [| Pane.Target_next_tab
   ; Pane.Target_none
   ; Pane.Target_keeper "pane-fixture-keeper"
   ; Pane.Target_none
   ; Pane.Target_none
   ; Pane.Target_call_order
   ; Pane.Target_none |]

let test_cursor_steps_over_rows_a_press_does_nothing_on () =
  let step ~row ~step = Pane.next_target_row ~targets:cursor_targets ~row ~step in
  check (option int) "first row from before the frame" (Some 0) (step ~row:(-1) ~step:1);
  check (option int) "down skips the blank row" (Some 2) (step ~row:0 ~step:1);
  check (option int) "down skips two blank rows" (Some 5) (step ~row:2 ~step:1);
  check (option int) "up skips two blank rows" (Some 2) (step ~row:5 ~step:(-1));
  check (option int) "up from a blank row lands above it" (Some 2) (step ~row:3 ~step:(-1))

let test_cursor_stops_at_the_frames_edge () =
  let step ~row ~step = Pane.next_target_row ~targets:cursor_targets ~row ~step in
  check (option int) "nothing below the last target" None (step ~row:5 ~step:1);
  check (option int) "nothing above the first target" None (step ~row:0 ~step:(-1));
  check (option int) "a zero step goes nowhere" None (step ~row:2 ~step:0);
  check (option int) "an empty frame has no row" None
    (Pane.next_target_row ~targets:[||] ~row:(-1) ~step:1)

let () =
  run "tui acting pane"
    [ ( "viewport allocation"
      , [ test_case "hidden Unicode rows remain reachable without layout allocation" `Quick
            test_hidden_rows_do_not_allocate_text_layout ] )
    ; ( "width"
      , [ test_case "Ctrl-L walks narrow, wide, hidden" `Quick
            test_ctrl_l_walks_narrow_wide_hidden
        ;] )
    ; ( "rows"
      , [ test_case "every row is the pane width" `Quick test_every_row_is_the_pane_width
        ; test_case "narrow budget folds the fleet" `Quick test_narrow_budget_folds_the_fleet
        ; test_case "folded and scrolled views preserve keeper row and focus" `Quick
            test_folded_and_scrolled_views_preserve_keeper_row_and_focus
        ] )
    ; ( "what the keeper is doing now"
      , [] )
    ; ( "a gone keeper"
      , [] )
    ; ( "targets"
      , [ test_case "targets name the keeper under each fleet row" `Quick
            test_targets_name_the_keeper_under_each_fleet_row
        ; test_case "an earlier turn row opens the keeper's calls" `Quick
            test_an_earlier_turn_row_opens_the_keepers_calls
        ; test_case "a call row names the call a press opens" `Quick
            test_a_call_row_names_the_call_a_press_opens
        ] )
    ; ( "calls"
      , [ test_case "a run of one tool is one counted row" `Quick
            test_a_run_of_one_tool_is_one_counted_row
        ; test_case "an opened call draws its facts and previews" `Quick
            test_an_opened_call_draws_its_facts_and_previews
        ; test_case "each order lists the calls as the heading says" `Quick
            test_each_order_lists_the_calls_as_the_heading_says
        ; test_case "the order cycles through all four" `Quick
            test_the_order_cycles_through_all_four
        ] )
    ; ( "wide"
      , [] )
    ; ( "responses"
      , [] )
    ; ( "scroll"
      , [ test_case "scrolling walks the full list under the header" `Quick
            test_scrolling_walks_the_full_list_under_the_header
        ; test_case "legend preserves reachable targets" `Quick
            test_legend_preserves_reachable_targets_in_small_windows
        ;] )
    ; ( "changes tab"
      , [ test_case "header marks its tab" `Quick test_changes_header_marks_its_tab
        ; test_case "status names the keeper and the fetch" `Quick
            test_changes_status_names_the_keeper_and_the_fetch
        ; test_case "rows list files newest first" `Quick
            test_changes_rows_list_files_newest_first
        ; test_case "overflow folds and scrolls" `Quick
            test_changes_overflow_folds_and_scrolls
        ] )
    ; ( "text"
      , [ test_case "reused chunks keep presentation inputs live" `Quick
            test_reused_chunks_keep_presentation_inputs_live
        ;] )
    ; ( "offline"
      , [ test_case "identity failure preserves roster navigation" `Quick
            test_trace_failure_is_readable_without_hiding_roster
        ; test_case "many identity failures retain navigation and detail" `Quick
            test_many_trace_failures_keep_navigation_and_full_reading
        ;] )
    ; ( "keyboard cursor"
      , [ test_case "the cursor steps over rows a press does nothing on" `Quick
            test_cursor_steps_over_rows_a_press_does_nothing_on
        ; test_case "the cursor stops at the frame's edge" `Quick
            test_cursor_stops_at_the_frames_edge
        ] )
    ; ( "beside the roster"
      , [ test_case "only the selected keeper's record draws" `Quick
            test_beside_the_roster_only_the_selected_keepers_record_draws
        ; test_case "keepers waiting on approval still draw" `Quick
            test_beside_the_roster_keepers_waiting_on_approval_still_draw
        ;] )
    ]
