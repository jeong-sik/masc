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
   The full list is eight rows: four fleet rows, the rule, and tester's
   three focus rows (its header, Read, Execute). *)
let fixture_entries =
  entries
        [ (900., settled ~at:900. "probe")
        ; ( 905.
          , Observer.Keeper_tool_call
              { Observer.kt_keeper = "probe"
              ; kt_turn = None
              ; kt_tool = "keeper_artifact_read"
              ; kt_duration_ms = Some 5.
              ; kt_disposition = Some "completed"
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

let span_values (line : Pane.line) =
  List.map (fun (span : Pane.span) ->
    let tone = match span.tone with
      | Pane.Plain -> "plain" | Pane.Dim -> "dim" | Pane.Accent -> "accent"
      | Pane.Ok -> "ok" | Pane.Warn -> "warn" | Pane.Bad -> "bad" | Pane.Info -> "info"
    in
    span.text, tone) line

let test_clipped_header_preserves_spans_and_padding () =
  let prefix =
    [ "│", "dim"; "[Recent]", "accent"; " ", "plain";
      "Changes", "dim"; " · 4 keepers · ", "dim" ]
  in
  let reason = "\027[31m한\027[0me\204\129🙂X" in
  let input = { fixture with Pane.feed = Pane.Feed_closed reason } in
  (* Explicit rendered spans pin ANSI bytes and tones, including a wide
     grapheme that leaves a one-cell gap filled by a separate Plain span. *)
  let cases =
    [ 0, []
    ; -1, []
    ; 1, [ "│", "dim" ]
    ; 4, [ "│", "dim"; "[Re", "accent" ]
    ; 9, [ "│", "dim"; "[Recent]", "accent" ]
    ; 10, [ "│", "dim"; "[Recent]", "accent"; " ", "plain" ]
    ; 17, [ "│", "dim"; "[Recent]", "accent"; " ", "plain"; "Changes", "dim" ]
    ; 32, prefix
    ; 45, prefix @ [ "feed closed: \027[31m", "bad" ]
    ; 46, prefix @ [ "feed closed: \027[31m", "bad"; " ", "plain" ]
    ; 47, prefix @ [ "feed closed: \027[31m한\027[0m", "bad" ]
    ; 48, prefix @ [ "feed closed: \027[31m한\027[0me\204\129", "bad" ]
    ; 49, prefix @ [ "feed closed: \027[31m한\027[0me\204\129", "bad"; " ", "plain" ]
    ; 50, prefix @ [ "feed closed: \027[31m한\027[0me\204\129🙂", "bad" ]
    ; 51, prefix @ [ "feed closed: " ^ reason, "bad" ]
    ; 53, prefix @ [ "feed closed: " ^ reason, "bad"; "  ", "plain" ]
    ]
  in
  List.iter (fun (cols, expected) ->
    let drawn = Pane.lines ~rows:1 ~cols ~scroll:0 input in
    let row = List.hd drawn.Pane.rows in
    check (list (pair string string)) (Printf.sprintf "header at %d cells" cols)
      expected (span_values row);
    check int "rendered cell budget" (max 0 cols) (width row)) cases

let test_full_width_row_retains_empty_toned_spans () =
  let drawn = Pane.lines ~rows:14 ~cols:Pane.pane_cols ~scroll:0 fixture in
  let row = List.find (fun row -> contains "Execute" (text row))
    (List.rev drawn.Pane.rows) in
  let trailing = List.rev (span_values row) in
  match trailing with
  | duration :: gap :: _ ->
    check (pair string string) "unknown duration retains its empty Dim span"
      ("", "dim") duration;
    check (pair string string) "absent duration gap retains its empty Plain span"
      ("", "plain") gap;
    check int "tool row still exactly fills the pane" Pane.pane_cols (width row)
  | _ -> fail "tool row lost its spans"

let target_text = function
  | Pane.Target_none -> "none"
  | Pane.Target_next_tab -> "next-tab"
  | Pane.Target_keeper name -> "keeper:" ^ name
  | Pane.Target_more -> "more"
  | Pane.Target_file index -> "file:" ^ string_of_int index
  | Pane.Target_calls name -> "calls:" ^ name

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

(* The focus header repeats a name the fleet row already used; its own row
   is the later one. *)
let last_index_of_in texts name =
  let rec go i best = function
    | [] -> Option.value ~default:0 best
    | row :: rest ->
        go (i + 1) (if contains name row then Some i else best) rest
  in
  go 0 None texts

let last_index_of name = last_index_of_in texts name

(* goner's process is gone: the mark says the keeper is not there, the
   health reading is Offline. Its last turn never settled — the end event
   died with the keeper — so neither the fleet row nor the focus block may
   read that turn as running. *)
let dead_fixture : Pane.input =
  { fixture with
    Pane.keepers =
      Some
      (keeper ~mark:"\xc3\x97" ~tone:Pane.Bad
        ~health:(Some Masc.Tui_decode.Health_offline) "goner"
      :: keeper "bare"
      :: keeper "mute"
      :: Option.value ~default:[] fixture.Pane.keepers)
  ; selected = Some "goner"
  ; chunks = chunks [ "goner"; "bare"; "mute"; "quiet-one"; "tester"; "probe"; "polisher" ]
      (fixture_entries
      @ entries
          [ ( 995.
            , agent_core ~kind:Observer.Turn_started ~turn:7 ~at:995.
                ~correlation:"trace-goner" lane )
          ; ( 996.
            , agent_core ~tool:"Read" ~turn:7 ~tool_use_id:"c" ~at:996.
                ~correlation:"trace-goner" lane )
          ; ( 997.
            , agent_core ~kind:Observer.Turn_started ~turn:9 ~at:997.
                ~correlation:"trace-bare" lane )
          ; ( 908.
            , Observer.Keeper_turn_complete
                { Observer.tc_keeper = "mute"
                ; tc_turn = None
                ; tc_model = None
                ; tc_input_tokens = Some 120
                ; tc_output_tokens = Some 30
                ; tc_cost_usd = Some 0.001
                ; tc_tool_calls = Some 2
                ; tc_at = 908.
                } )
          ])
  }

let dead_drawn = Pane.lines ~rows ~cols ~scroll:0 dead_fixture
let dead_texts = List.map text dead_drawn.Pane.rows

let test_a_settle_without_a_number_names_no_turn () =
  let drawn =
    Pane.lines ~rows ~cols ~scroll:0 { dead_fixture with Pane.selected = Some "mute" }
  in
  let texts = List.map text drawn.Pane.rows in
  let header = List.nth texts (last_index_of_in texts "mute") in
  check bool "settles with its state" true (contains "settled" header);
  check bool "no turn is named" false (contains "turn" header)

(* An offline keeper has no fleet row any more, but the operator can still
   select one and its focus block draws. That block is where the reading has to
   stay honest: the last turn never settled because the end event died with the
   keeper, so nothing here may read as running. *)
let test_a_gone_keepers_turn_is_not_read_as_running () =
  check bool "no fleet row for an offline keeper" false
    (List.exists
       (fun row -> contains "\xe2\x97\x8f" row && contains "goner" row)
       dead_texts);
  let header = find_row_in dead_texts "goner" in
  check bool "the focus header says the process is gone" true
    (contains "process gone" header);
  check bool "and that the turn never settled" true (contains "unsettled" header);
  check bool "the focus block does not say running" false
    (contains "running" header);
  let body = find_row_in dead_texts "Read" in
  check bool "what it saw is still named" true (contains "Read" body);
  check bool "under the gone glyph" true (contains "! " body)

let test_a_settled_row_counts_only_what_the_settle_confirmed () =
  (* The ledger row above landed after the settle and carries no turn
     number; before the fix it made the settled row count the running
     ledger total instead of the turn's confirmed calls. *)
  let row = find_row "probe" in
  check bool "the settle's count stands" true (contains "    3" row);
  check bool "no running total took the count" false (contains "    4" row);
  check bool "a fleet row carries no clock" false (contains "last event" row)

let test_an_open_record_without_a_tool_does_not_claim_a_current_turn () =
  let row = find_row_in dead_texts "bare" in
  check bool "a record with no call shows a dash, not a zero" true
    (contains "    -" row);
  check bool "and says so in the state column" true (contains "unsettled" row);
  check bool "the fleet row never borrows the phase word" false
    (contains "running" row)

let test_a_gone_keepers_focus_header_says_unfinished () =
  let header = last_index_of_in dead_texts "goner" in
  check bool "the focus header says the record is unsettled and why" true
    (contains "unsettled, process gone" (List.nth dead_texts header));
  check bool "the focus header does not say in turn" false
    (contains "in turn" (List.nth dead_texts header));
  check bool "an open turn does not borrow the session number" false
    (contains "turn 7" (List.nth dead_texts header))

let test_idle_health_does_not_turn_an_open_record_into_current_work () =
  let input =
    { fixture with
      Pane.keepers = Some [ keeper ~health:(Some Masc.Tui_decode.Health_idle) "tester" ]
    ; approvals = []
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let header = List.nth texts (last_index_of_in texts "tester") in
  check bool "idle health preserves the unresolved feed record" true
    (contains "unsettled" header);
  check bool "and does not blame the process" false (contains "gone" header);
  check bool "receipt clock remains visible" true (contains "last event 10.0s" header);
  check bool "no row asserts a current turn" false
    (List.exists (fun row -> contains "in turn" row || contains "running" row) texts)

let test_event_age_uses_local_receipt_not_producer_time () =
  let input =
    { fixture with
      Pane.keepers = Some [ keeper "tester" ]; approvals = []
    ; chunks = chunks [ "tester" ] @@ entries
        [ 990., agent_core ~kind:Observer.Turn_started ~turn:3 ~at:100.
            ~correlation:"trace-tester" lane ]
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let row = find_row_in texts "tester" in
  let header = List.nth texts (last_index_of_in texts "tester") in
  check bool "local receipt is ten seconds old" true (contains "last event 10.0s" header);
  check bool "no observed calls is explicit" true (contains "    -" row);
  check bool "producer's fifteen-minute age is not substituted" false
    (contains "15m" row || contains "15m" header)

let test_settled_unknown_call_total_stays_unknown () =
  let event =
    match settled ~at:990. "tester" with
    | Observer.Keeper_turn_complete value ->
      Observer.Keeper_turn_complete { value with tc_tool_calls = None }
    | _ -> fail "settled fixture must carry a turn completion"
  in
  let input =
    { fixture with
      Pane.keepers = Some [ keeper "tester" ]; approvals = []
    ; chunks = chunks [ "tester" ] @@ entries [ 990., event ]
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let row = find_row_in texts "tester" in
  check bool "unknown count is named" true (contains "    ?" row);
  check bool "unknown count is not zero" false (contains "    0" row)

let test_earlier_unclosed_record_is_not_presented_as_settled () =
  let input =
    { fixture with
      Pane.keepers = Some [ keeper "tester" ]; approvals = []
    ; chunks = chunks [ "tester" ] @@ entries
        [ 990., agent_core ~kind:Observer.Turn_started ~turn:6 ~at:990.
            ~correlation:"trace-tester" lane
        ; 980., agent_core ~kind:Observer.Turn_started ~turn:5 ~at:980.
            ~correlation:"trace-tester" lane
        ]
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  (* The header says unsettled for the current record; the earlier one is
     the later row that says it again. *)
  let prior = List.nth texts (last_index_of_in texts "unsettled") in
  check bool "the earlier row is not the header" false (contains "tester" prior);
  check bool "earlier missing settlement remains unsettled" true (contains "~ unsettled" prior);
  check bool "earlier record uses an observed count" true (contains "no calls yet" prior);
  check bool "no settled marker is invented" false
    (contains (Acting.glyph_text Acting.Turn_settled) prior)

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
  check bool "the fleet tab is up" true (contains "[Recent]" (nth 0));
  check bool "the changes tab is named" true (contains "Changes" (nth 0));
  check bool "the changes tab is not the one up" false (contains "[Changes]" (nth 0));
  check bool "counts the fleet" true (contains "4 keepers" (nth 0));
  check bool "states the live feed" true (contains "live" (nth 0));
  check bool "the transport is explicit" true (contains "feed live" (nth 0));
  check bool "cumulative frame counts are omitted" false (contains "events" (nth 0));
  check bool "the legend row is drawn whole" true (contains Pane.legend (nth 1))

let test_fleet_orders_waiting_then_working_then_settled_then_quiet () =
  let polisher = index_of "polisher" and tester = index_of "tester"
  and probe = index_of "probe" and quiet = index_of "quiet-one" in
  check bool "approval first" true (polisher < tester);
  check bool "working before settled" true (tester < probe);
  check bool "settled before quiet" true (probe < quiet)

let test_fleet_rows_read_the_state () =
  check bool "waiting names the tool" true (contains "approval" (find_row "polisher"));
  check bool "waiting names which tool" true (contains "tool_execute" (find_row "polisher"));
  check bool "working names the call out" true (contains "Execute" (find_row "tester"));
  check bool "working counts its calls as at least" true (contains "   2+" (find_row "tester"));
  check bool "settled counts its calls" true (contains "    3" (find_row "probe"));
  (* The fleet column carries the sum. The two figures apart are the focus
     block's job: nine cells cannot hold "in 73.9k · out 358". *)
  check bool "settled shows the token total" true
    (contains "    74.2k" (find_row "probe"));
  check bool "quiet says so" true (contains "no events" (find_row "quiet-one"))

let test_focus_block_names_the_latest_observed_record () =
  let header = last_index_of "tester" in
  check bool "the record has no observed settlement" true (contains "unsettled" (nth header));
  check bool "the header carries the receipt age" true (contains "last event 10.0s" (nth header));
  check bool "first call returned" true (contains "Read" (nth (header + 1)));
  check bool "with its duration" true (contains "2.0s" (nth (header + 1)));
  check bool "second call still out" true (contains "Execute" (nth (header + 2)));
  check bool "a tool without a duration does not borrow the record clock" false
    (contains "10.0s" (nth (header + 2)));
  check bool "an unclosed tool record uses a neutral mark" true
    (contains "~ " (nth (header + 2)));
  check bool "the call line does not repeat the header's state" false
    (contains "in turn" (nth (header + 2)))

let test_focus_falls_back_to_who_acted_last () =
  let drawn = Pane.lines ~rows ~cols ~scroll:0 { fixture with Pane.selected = None } in
  let texts = List.map text drawn.Pane.rows in
  check bool "tester acted last" true
    (List.exists (fun row -> contains "tester" row) texts)

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
  check string "a call row opens the keeper's calls" "calls:tester"
    (List.nth targets (header + 1));
  check string "so does the call still out" "calls:tester" (List.nth targets (header + 2));
  check string "padding acts on nothing" "none" (List.nth targets (rows - 1))

(* ── scroll ─────────────────────────────────────────────────────────── *)

let test_a_pane_that_fits_does_not_scroll () =
  check int "nothing to scroll into" 0 drawn.Pane.scroll_max;
  check bool "no fold" false (List.exists (fun row -> contains "more" row) texts);
  let scrolled = Pane.lines ~rows ~cols ~scroll:3 fixture in
  check (list string) "a scroll on a pane that fits draws the same rows" texts
    (List.map text scrolled.Pane.rows)

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
    (contains "\xe2\x86\x93 5 more" (List.nth texts (short_rows - 1)));
  check string "a visible fleet row still names its keeper" "keeper:tester"
    (target_text (List.nth scrolled.Pane.targets (header_rows + 1)));
  check string "indicators act on nothing" "none"
    (target_text (List.nth scrolled.Pane.targets header_rows));
  List.iteri
    (fun i line -> check int (Printf.sprintf "scrolled row %d width" i) cols (width line))
    scrolled.Pane.rows

let test_scroll_clamps_at_the_last_row () =
  let at_max = Pane.lines ~rows:short_rows ~cols ~scroll:5 fixture in
  let texts = List.map text at_max.Pane.rows in
  check bool "the top indicator counts everything above" true
    (contains "\xe2\x86\x91 5 more" (List.nth texts header_rows));
  check bool "the last row of the list is on screen" true
    (contains "Execute" (List.nth texts (short_rows - 1)));
  check bool "no bottom indicator when nothing is below" false
    (List.exists (fun row -> contains "\xe2\x86\x93" row) texts);
  let past = Pane.lines ~rows:short_rows ~cols ~scroll:99 fixture in
  check (list string) "a scroll past the end draws the last window" texts
    (List.map text past.Pane.rows)

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
            (contains Pane.legend (text (List.nth value.Pane.rows 1))))
        windows)
    [ 3; 4; 5; 6 ];
  List.iter
    (fun rows ->
      let value = Pane.lines ~rows ~cols ~scroll:99 fixture in
      check int "header-only height remains bounded" rows (List.length value.Pane.rows);
      check int "no body means no scroll destination" 0 value.Pane.scroll_max)
    [ 0; 1; 2 ]

let test_event_and_count_labels_fit_the_existing_width () =
  let input =
    { fixture with
      Pane.keepers = Some [ keeper "sixteen-charname" ]; selected = Some "sixteen-charname";
      approvals = [];
      chunks = chunks [ "sixteen-charname" ] @@ entries
        [ 987.6, agent_core ~tool:"network_read" ~turn:3 ~tool_use_id:"width"
            ~at:987.6 ~correlation:"trace-sixteen-charname" lane ]
    }
  in
  let value = Pane.lines ~rows ~cols ~scroll:0 input in
  let row = find_row_in (List.map text value.Pane.rows) "sixteen-charname" in
  check bool "tool name is whole" true (contains "network_read" row);
  check bool "observed count is whole" true (contains "   1+" row);
  check int "pane width remains unchanged" 56 Pane.pane_cols;
  check bool "settled count and its token total fit" true
    (contains "    3" (find_row "probe") && contains "    74.2k" (find_row "probe"))

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
    }

let changes_fixture = { fixture with Pane.tab = Pane.Tab_changes; changes = ready }
let changes_drawn = Pane.lines ~rows ~cols ~scroll:0 changes_fixture
let changes_texts = List.map text changes_drawn.Pane.rows

let test_changes_header_marks_its_tab () =
  let header = List.nth changes_texts 0 in
  check bool "the changes tab is up" true (contains "[Changes]" header);
  check bool "the fleet tab is named" true (contains "Recent" header);
  check bool "the fleet tab is not the one up" false (contains "[Recent]" header);
  check bool "the feed still shows" true (contains "feed live" header);
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
    (contains "changes not fetched" (status_of Pane.Changes_absent (Some "tester")));
  check bool "loading" true (contains "loading" (status_of Pane.Changes_loading (Some "tester")));
  check bool "failed says why" true
    (contains "failed" (status_of (Pane.Changes_failed "connection refused") (Some "tester"))
     && contains "connection refused"
          (status_of (Pane.Changes_failed "connection refused") (Some "tester")));
  let empty =
    Pane.Changes_ready
      { keeper = "tester"; files = []; fetched_at = 990.; window_hours = 24.; calls = 7
      ; over_budget = 0; malformed = 0 }
  in
  let drawn = Pane.lines ~rows ~cols ~scroll:0 { changes_fixture with Pane.changes = empty } in
  let texts = List.map text drawn.Pane.rows in
  check bool "no files says so with the call count" true
    (List.exists (fun row -> contains "no writes in 7 calls" row) texts);
  let dropped =
    Pane.Changes_ready
      { keeper = "tester"; files = []; fetched_at = 990.; window_hours = 24.; calls = 7
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
    (contains "approval"
       (plain (Pane.keeper_state_text ~health:None ~approval:(Some "Write") None)));
  (* Every reading fills the reading area exactly, blank columns included, so
     a row cannot end early and let the next line's columns sit elsewhere. *)
  let width spans = Masc_tui_message_layout.display_width (plain spans) in
  check int "a reading with no record still spends every column" Pane.reading_cells
    (width (Pane.keeper_state_text ~health:None ~approval:None None));
  check int "and one waiting on an approval" Pane.reading_cells
    (width (Pane.keeper_state_text ~health:None ~approval:(Some "Write") None));
  check bool "the empty case names the reason" true
    (contains "no events" (plain (Pane.keeper_state_text ~health:None ~approval:None None)))

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
  let changed = { input with Pane.now = now +. 20.; selected = Some "probe";
    keepers = Option.map (List.map (fun (keeper : Pane.keeper) ->
      (* Zombie, not offline: both read as an unfinished record and give the
         row the same glyph, and an offline keeper has no fleet row to read. *)
      if keeper.name = "tester" then { keeper with health = Some Masc.Tui_decode.Health_zombie }
      else keeper)) input.keepers } in
  let later = Pane.lines ~rows ~cols ~scroll:0 changed in
  check bool "age advances independently of chunks" true
    (contains "last event 1m55s" (header_of "probe" later));
  (* The state column, not a glyph: a record whose keeper is gone reads "gone"
     where a live one reads "unsettled". *)
  check bool "new health changes the state column" true
    (contains "gone" (row_for "tester" later));
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
      over_budget = 0; malformed = 0 } } in
  let measure rows input =
    ignore (Sys.opaque_identity (Pane.lines ~rows ~cols ~scroll:0 input));
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

let test_tokens_and_ages_are_compact () =
  check string "both sides as parts" "in 73.9k · out 358" (Pane.tokens_text (Some 73_877, Some 358));
  check string "both sides summed" "74.2k tok" (Pane.tokens_sum_text (Some 73_877, Some 358));
  check string "one side alone" "358 tok" (Pane.tokens_text (None, Some 358));
  check string "unknown is empty" "" (Pane.tokens_text (None, None));
  check string "age in the feed's shape" "10.0s" (Pane.age_text ~now 990.);
  check string "a clock behind now is zero" "0ms" (Pane.age_text ~now 2_000.)


(* Each legend row is drawn whole: a legend cut at the edge would define a
   word with half a sentence. *)
let test_legend_row_fits_whole () =
  check bool "legend is whole" true (contains Pane.legend (nth 1))

(* A three-digit settle with two large parts is the widest settled reading;
   it fits the pane whole now that no clock shares the row. *)
let test_widest_settled_reading_fits_whole () =
  let event =
    match settled ~at:990. "tester" with
    | Observer.Keeper_turn_complete value ->
      Observer.Keeper_turn_complete
        { value with
          tc_tool_calls = Some 123
        ; tc_input_tokens = Some 999_900
        ; tc_output_tokens = Some 999_900
        }
    | _ -> fail "settled fixture must carry a turn completion"
  in
  let input =
    { fixture with
      Pane.keepers = Some [ keeper "tester" ]; approvals = []
    ; chunks = chunks [ "tester" ] @@ entries [ 990., event ]
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let row = find_row_in texts "tester" in
  check bool "the count is whole" true (contains "  123" row);
  check bool "the summed figure is whole" true (contains "     2.0M" row)

(* tester's session turn 5 opened, settled as the keeper's turn 3141 twenty
   seconds ago, and session turn 6 has opened since: the earlier turn draws
   under the header. The order is the feed's own; a settle folded before its
   turn's start would take the later start into itself, since a settled
   chunk with no session number accepts any session-numbered member. The
   row carries no receipt age; with the fixture's tokens and cost it is 48
   cells against a 56-cell pane and keeps everything. *)
let settled_earlier ?(calls = 3) ?(input = 73_877) ?(output = 358) ?(cost = 0.0258) () =
  match settled ~at:980. "tester" with
  | Observer.Keeper_turn_complete value ->
    Observer.Keeper_turn_complete
      { value with
        tc_turn = Some 3141
      ; tc_tool_calls = Some calls
      ; tc_input_tokens = Some input
      ; tc_output_tokens = Some output
      ; tc_cost_usd = Some cost
      }
  | _ -> fail "settled fixture must carry a turn completion"

let earlier_turn_input ?calls ?input ?output ?cost () =
  { fixture with
    Pane.keepers = Some [ keeper "tester" ]; approvals = []
  ; chunks = chunks [ "tester" ] @@ entries
      [ 990., agent_core ~kind:Observer.Turn_started ~turn:6 ~at:990.
          ~correlation:"trace-tester" lane
      ; 980., settled_earlier ?calls ?input ?output ?cost ()
      ; 970., agent_core ~kind:Observer.Turn_started ~turn:5 ~at:970.
          ~correlation:"trace-tester" lane
      ]
  }

let earlier_turn_row input =
  find_row_in (List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows) "turn 3141"

let test_earlier_turn_row_carries_its_parts_and_cost_and_no_clock () =
  let row = earlier_turn_row (earlier_turn_input ()) in
  check bool "both token parts" true (contains "in 73.9k · out 358" row);
  check bool "the cost" true (contains "$0.0258" row);
  check bool "no receipt age" false (contains "last event" row);
  check bool "the count" true (contains "3 calls" row)

(* Three-digit calls, two large parts and a six-figure cost: 59 cells
   against a 56-cell pane, so the cost goes and the parts stay. *)
let test_earlier_turn_row_gives_up_its_cost_before_its_parts () =
  let row =
    earlier_turn_row
      (earlier_turn_input ~calls:123 ~input:999_900 ~output:999_900 ~cost:123456.789 ())
  in
  check bool "both token parts" true (contains "in 999.9k · out 999.9k" row);
  check bool "the cost is what it gave up" false (contains "$" row);
  check bool "the count" true (contains "123 calls" row)

(* Beside the roster every fleet row would be a roster row said twice. The
   pane then draws the selected keeper's record alone: no fleet rows, no
   rule, no keeper count in the header; the header's clock and the call
   rows' targets are as under the whole fleet. *)
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
  check bool "the header states the feed" true (contains "feed live" (List.nth texts 0));
  check bool "the header does not count the fleet" false (contains "keepers" (List.nth texts 0));
  check bool "the legend stays" true (contains Pane.legend (List.nth texts 1));
  check (list string) "no fleet row" [] (keeper_targets view);
  check bool "no rule" false (List.exists (fun row -> contains rule_glyphs row) texts);
  check bool "the selected keeper's header is first under the legend" true
    (contains "tester" (List.nth texts 2) && contains "last event 10.0s" (List.nth texts 2));
  check string "its call rows open its calls" "calls:tester" (target_text (List.nth view.Pane.targets 3));
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
  check string "its call rows still open its calls" "calls:tester"
    (target_text (List.nth view.Pane.targets 5))

(* A sixteen-cell name, a four-digit settled turn and the clock share one
   row: the number already says the turn settled, so no word is drawn and
   the clock stays whole. *)
let test_focus_header_keeps_its_clock_behind_a_wide_name_and_a_named_turn () =
  let name = "sixteen-charname" in
  let event =
    match settled ~at:990. name with
    | Observer.Keeper_turn_complete value ->
      Observer.Keeper_turn_complete { value with tc_turn = Some 3141 }
    | _ -> fail "settled fixture must carry a turn completion"
  in
  let input =
    { fixture with
      Pane.keepers = Some [ keeper name ]; selected = Some name; approvals = []
    ; chunks = chunks [ name ] @@ entries [ 990., event ]
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let header = List.nth texts (last_index_of_in texts name) in
  check bool "the turn is named" true (contains "turn 3141" header);
  check bool "the clock is whole" true (contains "last event 10.0s" header);
  check bool "no state word doubles the number" false (contains "settled" header)

let test_beside_the_roster_a_long_record_folds_and_scrolls () =
  let events =
    List.init 12 (fun i ->
      let at = 900. +. float_of_int i in
      at, agent_core ~tool:(Printf.sprintf "call-%02d" i) ~turn:5
        ~tool_use_id:(string_of_int i) ~at ~correlation:"trace-tester" lane)
  in
  let input =
    { fixture with
      Pane.scope = Pane.Selected_only; keepers = Some [ keeper "tester" ]; approvals = []
    ; chunks = chunks [ "tester" ] (entries events)
    }
  in
  let folded = Pane.lines ~rows:6 ~cols ~scroll:0 input in
  let texts = List.map text folded.Pane.rows in
  check bool "the bottom indicator counts what is hidden" true
    (List.exists (fun row -> contains "\xe2\x86\x93" row) texts);
  check bool "there is somewhere to scroll" true (folded.Pane.scroll_max > 0);
  let last = Pane.lines ~rows:6 ~cols ~scroll:folded.Pane.scroll_max input in
  check bool "the last call is reachable" true
    (List.exists (fun row -> contains "call-11" (text row)) last.Pane.rows)

let test_fleet_rows_carry_no_clock () =
  List.iter2
    (fun row target ->
      match target with
      | Pane.Target_keeper _ ->
          check bool "a fleet row has no clock" false (contains "last event" (text row))
      | _ -> ())
    drawn.Pane.rows drawn.Pane.targets;
  check bool "the focus header has the one clock" true
    (contains "last event" (nth (last_index_of "tester")))

let test_an_earlier_turn_row_opens_the_keepers_calls () =
  let value = Pane.lines ~rows ~cols ~scroll:0 (earlier_turn_input ()) in
  let texts = List.map text value.Pane.rows in
  let index = index_of_in texts "turn 3141" in
  check string "the turn row opens the calls surface" "calls:tester"
    (target_text (List.nth value.Pane.targets index))

(* The pane answers what every keeper is doing now, and a keeper with no agent
   present is doing nothing. Its row pushed working keepers past the fold. *)
let offline_fixture : Pane.input =
  { fixture with
    Pane.keepers =
      Some
        [ keeper "quiet-one" ~tone:Pane.Dim
        ; keeper ~tone:Pane.Bad ~health:(Some Masc.Tui_decode.Health_offline) "gone-one"
        ; keeper "tester"
        ; keeper ~tone:Pane.Bad ~health:(Some Masc.Tui_decode.Health_offline) "gone-two"
        ; keeper "probe"
        ]
  ; selected = Some "tester"
  }

let offline_texts () =
  List.map text (Pane.lines ~rows ~cols ~scroll:0 offline_fixture).Pane.rows

let test_offline_keepers_do_not_draw () =
  let drawn = offline_texts () in
  let says name = List.exists (fun row -> contains name row) drawn in
  check bool "an offline keeper has no row" false (says "gone-one");
  check bool "nor the second one" false (says "gone-two");
  check bool "the working ones still draw" true (says "tester");
  check bool "including a quiet one" true (says "quiet-one");
  check bool "and the last of them" true (says "probe")

(* Dropping rows without saying so makes a short list read as the whole fleet.
   The count is over what is drawn, and what was left out is named beside it. *)
let test_the_header_names_what_it_left_out () =
  let header = List.hd (offline_texts ()) in
  check bool "the count is of the drawn keepers" true (contains "3 keepers" header);
  check bool "and the hidden ones are named" true (contains "(2 offline)" header);
  let clean =
    List.hd (List.map text (Pane.lines ~rows ~cols ~scroll:0 fixture).Pane.rows)
  in
  check bool "no parenthetical when none are offline" false (contains "offline" clean)

(* A roster nobody has read is as empty as a workspace with no keepers, and the
   header is the one row that counts. Until the keeper files are read it says so
   instead of "0 keepers" (#35747). *)
let test_an_unread_roster_is_not_counted_as_none () =
  let header input =
    List.hd (List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows)
  in
  let unread = header { fixture with Pane.keepers = None; selected = None } in
  check bool "says the roster is not loaded" true
    (contains "keepers not loaded" unread);
  check bool "does not count it as none" false (contains "0 keepers" unread);
  let empty = header { fixture with Pane.keepers = Some []; selected = None } in
  check bool "a read roster with no keepers still counts them" true
    (contains "0 keepers" empty)

(* Only Health_offline. A zombie is a keeper that should be running and is not,
   which is the reading an operator most needs; a filter that took it too would
   hide the fleet's problems. A keeper whose health did not read is not a keeper
   reading offline, and dropping those empties the pane whenever the roster
   fails to load. *)
let test_only_offline_is_dropped () =
  let with_health h name = keeper ~health:(Some h) name in
  let input =
    { fixture with
      Pane.keepers =
        Some
          [ with_health Masc.Tui_decode.Health_zombie "zombie-one"
          ; with_health Masc.Tui_decode.Health_stale "stale-one"
          ; with_health Masc.Tui_decode.Health_degraded "degraded-one"
          ; keeper "unread-one"
          ; with_health Masc.Tui_decode.Health_offline "gone-one"
          ]
    ; selected = Some "zombie-one"
    }
  in
  let drawn = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let says name = List.exists (fun row -> contains name row) drawn in
  check bool "a zombie still draws" true (says "zombie-one");
  check bool "a stale keeper still draws" true (says "stale-one");
  check bool "a degraded one still draws" true (says "degraded-one");
  check bool "and one whose health did not read" true (says "unread-one");
  check bool "only the offline one is gone" false (says "gone-one")

let () =
  run "tui acting pane"
    [ ( "viewport allocation"
      , [ test_case "hidden Unicode rows remain reachable without layout allocation" `Quick
            test_hidden_rows_do_not_allocate_text_layout ] )
    ; ( "width"
      , [ test_case "shown needs room and consent" `Quick test_shown_needs_room_and_consent
        ; test_case "toggle changes only a visible preference" `Quick
            test_toggle_changes_only_a_visible_preference
        ; test_case "content cols give the surface the rest" `Quick
            test_content_cols_give_the_surface_the_rest
        ; test_case "threshold leaves the surface the roster floor" `Quick
            test_threshold_leaves_the_surface_the_roster_floor
        ; test_case "clipped header preserves styled Unicode spans" `Quick
            test_clipped_header_preserves_spans_and_padding
        ; test_case "full-width row retains empty toned spans" `Quick
            test_full_width_row_retains_empty_toned_spans
        ] )
    ; ( "rows"
      , [ test_case "every row is the pane width" `Quick test_every_row_is_the_pane_width
        ; test_case "header states tabs, fleet and feed" `Quick
            test_header_states_tabs_fleet_and_feed
        ; test_case "fleet orders waiting, working, settled, quiet" `Quick
            test_fleet_orders_waiting_then_working_then_settled_then_quiet
        ; test_case "fleet rows read the state" `Quick test_fleet_rows_read_the_state
        ; test_case "focus block names the latest observed record" `Quick
            test_focus_block_names_the_latest_observed_record
        ; test_case "focus falls back to who acted last" `Quick
            test_focus_falls_back_to_who_acted_last
        ; test_case "narrow budget folds the fleet" `Quick test_narrow_budget_folds_the_fleet
        ; test_case "folded and scrolled views preserve keeper row and focus" `Quick
            test_folded_and_scrolled_views_preserve_keeper_row_and_focus
        ] )
    ; ( "a gone keeper"
      , [ test_case "a gone keeper's turn is not read as running" `Quick
            test_a_gone_keepers_turn_is_not_read_as_running
        ; test_case "a gone keeper's focus header says unsettled, process gone" `Quick
            test_a_gone_keepers_focus_header_says_unfinished
        ; test_case "an open record does not claim a current turn" `Quick
            test_an_open_record_without_a_tool_does_not_claim_a_current_turn
        ; test_case "a settled row counts only what the settle confirmed" `Quick
            test_a_settled_row_counts_only_what_the_settle_confirmed
        ; test_case "a settle without a number names no turn" `Quick
            test_a_settle_without_a_number_names_no_turn
        ; test_case "idle health does not assert current work" `Quick
            test_idle_health_does_not_turn_an_open_record_into_current_work
        ; test_case "event age uses local receipt" `Quick
            test_event_age_uses_local_receipt_not_producer_time
        ; test_case "unknown settled total stays unknown" `Quick
            test_settled_unknown_call_total_stays_unknown
        ; test_case "earlier unclosed record remains unresolved" `Quick
            test_earlier_unclosed_record_is_not_presented_as_settled
        ] )
    ; ( "targets"
      , [ test_case "targets name the keeper under each fleet row" `Quick
            test_targets_name_the_keeper_under_each_fleet_row
        ; test_case "an earlier turn row opens the keeper's calls" `Quick
            test_an_earlier_turn_row_opens_the_keepers_calls
        ] )
    ; ( "scroll"
      , [ test_case "a pane that fits does not scroll" `Quick
            test_a_pane_that_fits_does_not_scroll
        ; test_case "scrolling walks the full list under the header" `Quick
            test_scrolling_walks_the_full_list_under_the_header
        ; test_case "scroll clamps at the last row" `Quick test_scroll_clamps_at_the_last_row
        ; test_case "legend preserves reachable targets" `Quick
            test_legend_preserves_reachable_targets_in_small_windows
        ; test_case "event and count labels fit unchanged width" `Quick
            test_event_and_count_labels_fit_the_existing_width
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
        ; test_case "reused chunks keep presentation inputs live" `Quick
            test_reused_chunks_keep_presentation_inputs_live
        ; test_case "tokens and ages are compact" `Quick test_tokens_and_ages_are_compact
        ; test_case "legend row fits whole" `Quick test_legend_row_fits_whole
        ; test_case "widest settled reading fits whole" `Quick
            test_widest_settled_reading_fits_whole
        ; test_case "earlier turn row carries its parts and cost and no clock" `Quick
            test_earlier_turn_row_carries_its_parts_and_cost_and_no_clock
        ; test_case "earlier turn row gives up its cost before its parts" `Quick
            test_earlier_turn_row_gives_up_its_cost_before_its_parts
        ; test_case "fleet rows carry no clock" `Quick test_fleet_rows_carry_no_clock
        ] )
    ; ( "offline"
      , [ test_case "offline keepers do not draw" `Quick
            test_offline_keepers_do_not_draw
        ; test_case "the header names what it left out" `Quick
            test_the_header_names_what_it_left_out
        ; test_case "an unread roster is not counted as none" `Quick
            test_an_unread_roster_is_not_counted_as_none
        ; test_case "only offline is dropped" `Quick
            test_only_offline_is_dropped
        ] )
    ; ( "beside the roster"
      , [ test_case "only the selected keeper's record draws" `Quick
            test_beside_the_roster_only_the_selected_keepers_record_draws
        ; test_case "a long record folds and scrolls" `Quick
            test_beside_the_roster_a_long_record_folds_and_scrolls
        ; test_case "keepers waiting on approval still draw" `Quick
            test_beside_the_roster_keepers_waiting_on_approval_still_draw
        ; test_case "focus header keeps its clock behind a wide name and a named turn" `Quick
            test_focus_header_keeps_its_clock_behind_a_wide_name_and_a_named_turn
        ] )
    ]
