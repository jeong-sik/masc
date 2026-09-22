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

let test_clipped_header_preserves_spans_and_padding () =
  (* The count and the feed are two readings now, each carrying the
     separator that joins it to what is before: a live feed draws no words,
     so the separator cannot be left hanging off the count. *)
  let prefix =
    [ "│", "dim"; "[Recent]", "accent"; " ", "plain";
      "Changes", "dim"; " · 4 keepers", "dim" ]
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
    ; 29, prefix
    ; 32, prefix @ [ " · ", "bad" ]
    ; 45, prefix @ [ " · feed closed: \027[31m", "bad" ]
    ; 46, prefix @ [ " · feed closed: \027[31m", "bad"; " ", "plain" ]
    ; 47, prefix @ [ " · feed closed: \027[31m한\027[0m", "bad" ]
    ; 48, prefix @ [ " · feed closed: \027[31m한\027[0me\204\129", "bad" ]
    ; 49, prefix @ [ " · feed closed: \027[31m한\027[0me\204\129", "bad"; " ", "plain" ]
    ; 50, prefix @ [ " · feed closed: \027[31m한\027[0me\204\129🙂", "bad" ]
    ; 51, prefix @ [ " · feed closed: " ^ reason, "bad" ]
    ; 53, prefix @ [ " · feed closed: " ^ reason, "bad"; "  ", "plain" ]
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
  | Pane.Target_call (name, _) -> "call:" ^ name
  | Pane.Target_call_order -> "order"

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
  check bool "the state word is done" true (contains "done" header);
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
  check bool "and that the turn never ended" true (contains "no end" header);
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
  check bool "and says so in the state column" true (contains "open" row);
  check bool "the fleet row never borrows the phase word" false
    (contains "running" row)

(* ── what the keeper is doing now ────────────────────────────────────── *)

(* The header quotes the record only for a keeper the keepalive vouches
   for. These use tester's own entries: a Read that returned at 983 and an
   Execute still out since 990, with now at 1000. *)
let now_header ?(health = Some Masc.Tui_decode.Health_running) ?(name = "tester") entries_of =
  let input =
    { fixture with
      Pane.keepers = Some [ keeper ~health name ]
    ; selected = Some name
    ; approvals = []
    ; chunks = chunks [ name ] entries_of
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  List.nth texts (last_index_of_in texts name)

let test_a_running_keeper_names_the_call_that_is_out () =
  let header = now_header fixture_entries in
  check bool "the call that has not returned, aged from its own start" true
    (contains "running Execute 10.0s" header);
  check bool "and the row spends no second clock on it" false
    (contains "last event" header)

let test_a_running_keeper_between_calls_says_the_model_has_the_turn () =
  let entries_of =
    entries
      [ ( 980.
        , agent_core ~tool:"Read" ~turn:5 ~tool_use_id:"a" ~at:980.
            ~correlation:"trace-tester" lane )
      ; ( 983.
        , agent_core ~kind:Observer.Tool_completed ~tool:"Read" ~turn:5
            ~tool_use_id:"a" ~at:983. ~correlation:"trace-tester" lane )
      ; ( 985.
        , agent_core ~kind:Observer.Turn_started ~turn:6 ~at:985.
            ~correlation:"trace-tester" lane )
      ]
  in
  let header = now_header entries_of in
  check bool "the provider call is in flight, aged from its marker" true
    (contains "waiting on model 15.0s" header);
  check bool "the returned call is not called running" false (contains "running" header)

(* A lane that sends no turn markers -- a CLI runtime -- leaves the header
   as it was: the record's state word and the age of its newest event. *)
let test_a_record_without_markers_keeps_the_older_reading () =
  let entries_of =
    entries
      [ ( 990.
        , Observer.Keeper_tool_call
            { Observer.kt_keeper = "tester"
            ; kt_turn = Some 4
            ; kt_tool = "Read"
            ; kt_duration_ms = Some 5.
            ; kt_disposition = Some (Ok Masc.Tui_decode.Keeper_call_completed)
            ; kt_at = 990.
            ; kt_tool_use_id = Some "only"
            ; kt_schedule = None
            ; kt_tool_args = None
            ; kt_tool_result = None
            ; kt_tool_args_preview = None
            ; kt_tool_output_preview = None
            } )
      ]
  in
  let header = now_header entries_of in
  check bool "the state word stands" true (contains "open" header);
  check bool "with the age of the newest event" true (contains "last event 10.0s" header);
  check bool "nothing is claimed about the model" false (contains "waiting on model" header)

let test_an_idle_keepers_settled_record_says_how_long_it_has_been_quiet () =
  let header =
    now_header ~health:(Some Masc.Tui_decode.Health_idle) ~name:"prober"
      (entries [ 900., settled ~at:900. "prober" ])
  in
  check bool "quiet since the settle" true (contains "idle 1m40s" header);
  check bool "and the turn it closed" true (contains "turn 41" header)

let test_a_gone_keepers_focus_header_says_unfinished () =
  let header = last_index_of_in dead_texts "goner" in
  check bool "the focus header says no end is coming and why" true
    (contains "no end, process gone" (List.nth dead_texts header));
  check bool "the focus header does not say in turn" false
    (contains "in turn" (List.nth dead_texts header));
  check bool "an open turn does not borrow the session number" false
    (contains "turn 7" (List.nth dead_texts header))

(* A gone keeper with two turns that never ended: the focus header carries
   the long form and the earlier turn's own row the short one, each with the
   [!] mark rather than [~]. Only the header had a test, so the short form
   could have said anything. *)
let test_a_gone_keepers_earlier_turn_also_says_no_end () =
  let input =
    { fixture with
      Pane.keepers =
        Some
          [ keeper ~mark:"\xc3\x97" ~tone:Pane.Bad
              ~health:(Some Masc.Tui_decode.Health_offline) "goner" ]
    ; selected = Some "goner"
    ; approvals = []
    ; chunks = chunks [ "goner" ] @@ entries
        [ 990., agent_core ~kind:Observer.Turn_started ~turn:6 ~at:990.
            ~correlation:"trace-goner" lane
        ; 980., agent_core ~kind:Observer.Turn_started ~turn:5 ~at:980.
            ~correlation:"trace-goner" lane
        ]
    }
  in
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let header = List.nth texts (last_index_of_in texts "goner") in
  check bool "the header carries the long form" true
    (contains "no end, process gone" header);
  let prior = List.nth texts (last_index_of_in texts "no end") in
  check bool "the earlier row is not the header" false (contains "goner" prior);
  check bool "the earlier row carries the short form behind the gone mark" true
    (contains "! no end" prior);
  check bool "and not the open mark" false (contains "~ " prior)

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
    (contains "open" header);
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
  (* The header says open for the current record; the earlier one is
     the later row that says it again. *)
  let prior = List.nth texts (last_index_of_in texts "open") in
  check bool "the earlier row is not the header" false (contains "tester" prior);
  check bool "earlier missing settlement stays open" true (contains "~ open" prior);
  check bool "earlier record uses an observed count" true (contains "no calls yet" prior);
  check bool "no done marker is invented" false
    (contains (Acting.glyph_text Acting.Turn_done) prior)

(* ── width contract ─────────────────────────────────────────────────── *)

(* A terminal that holds either pane, one that holds only the narrow one,
   and one that holds neither. *)
let roomy = Pane.wide_threshold_cols + 20
let middling = Pane.wide_threshold_cols - 1
let narrow = Pane.threshold_cols - 1

let layout =
  testable (fun ppf l -> Format.pp_print_string ppf (Pane.layout_label l)) ( = )

let test_drawn_cols_follow_the_choice_and_the_room () =
  check int "narrow, with room" Pane.pane_cols (Pane.drawn_cols ~layout:Pane.Narrow ~cols:roomy);
  check int "wide, with room" Pane.wide_pane_cols
    (Pane.drawn_cols ~layout:Pane.Wide ~cols:roomy);
  check int "wide, room for the narrow pane only: drawn narrow" Pane.pane_cols
    (Pane.drawn_cols ~layout:Pane.Wide ~cols:middling);
  check int "hidden takes nothing" 0 (Pane.drawn_cols ~layout:Pane.Hidden ~cols:roomy);
  check int "no room, whatever the reader chose" 0
    (Pane.drawn_cols ~layout:Pane.Wide ~cols:narrow);
  check int "no room for the narrow pane either" 0
    (Pane.drawn_cols ~layout:Pane.Narrow ~cols:narrow);
  check int "exactly room for the wide pane" Pane.wide_pane_cols
    (Pane.drawn_cols ~layout:Pane.Wide ~cols:Pane.wide_threshold_cols);
  check int "exactly room for the narrow pane" Pane.pane_cols
    (Pane.drawn_cols ~layout:Pane.Wide ~cols:Pane.threshold_cols)

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

let test_content_cols_give_the_surface_the_rest () =
  check int "narrow takes the narrow pane" (roomy - Pane.pane_cols)
    (Pane.content_cols ~layout:Pane.Narrow ~cols:roomy);
  check int "wide takes the wide pane" (roomy - Pane.wide_pane_cols)
    (Pane.content_cols ~layout:Pane.Wide ~cols:roomy);
  check int "hidden takes nothing" roomy (Pane.content_cols ~layout:Pane.Hidden ~cols:roomy);
  check int "no room takes nothing" narrow (Pane.content_cols ~layout:Pane.Narrow ~cols:narrow)

let test_threshold_leaves_the_surface_the_roster_floor () =
  check int "surface floor is what the roster leaves"
    (Masc_tui_roster_pane.threshold_cols - Masc_tui_roster_pane.pane_cols)
    (Pane.threshold_cols - Pane.pane_cols);
  check int "the wide pane leaves the same floor" (Pane.threshold_cols - Pane.pane_cols)
    (Pane.wide_threshold_cols - Pane.wide_pane_cols)

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
  (* A live feed is what the rows below are evidence of, so the header says
     nothing about it; a feed that is not delivering is what a reader has to
     be told. *)
  check bool "a live feed takes no words" false (contains "feed" (nth 0));
  check bool "cumulative frame counts are omitted" false (contains "events" (nth 0));
  check bool "the legend row is drawn whole" true (contains (Pane.legend ~cols) (nth 1))

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
  check bool "working says open in the state column" true (contains "open" (find_row "tester"));
  check bool "done says so in the state column" true (contains "done" (find_row "probe"));
  check bool "settled counts its calls" true (contains "    3" (find_row "probe"));
  (* The fleet column carries the sum. The two figures apart are the focus
     block's job: nine cells cannot hold "in 73.9k · out 358". *)
  check bool "settled shows the token total" true
    (contains "    74.2k" (find_row "probe"));
  check bool "quiet says so" true (contains "no events" (find_row "quiet-one"))

let test_focus_block_names_the_latest_observed_record () =
  let header = last_index_of "tester" in
  check bool "the record has no observed settlement" true (contains "open" (nth header));
  check bool "the header carries the receipt age" true (contains "last event 10.0s" (nth header));
  check bool "the heading names the order" true
    (contains "calls \xc2\xb7 oldest first" (nth (header + 1)));
  check bool "first call returned" true (contains "Read" (nth (header + 2)));
  check bool "with its duration" true (contains "2.0s" (nth (header + 2)));
  check bool "second call still out" true (contains "Execute" (nth (header + 3)));
  check bool "a tool without a duration does not borrow the record clock" false
    (contains "10.0s" (nth (header + 3)));
  check bool "an unclosed tool record uses a neutral mark" true
    (contains "~ " (nth (header + 3)));
  check bool "the call line does not repeat the header's state" false
    (contains "in turn" (nth (header + 3)))

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
  check string "the calls heading turns the order" "order" (List.nth targets (header + 1));
  check string "a call row opens that call" "call:tester" (List.nth targets (header + 2));
  check string "so does the call still out" "call:tester" (List.nth targets (header + 3));
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
    (contains "\xe2\x86\x93 6 more" (List.nth texts (short_rows - 1)));
  check string "a visible fleet row still names its keeper" "keeper:tester"
    (target_text (List.nth scrolled.Pane.targets (header_rows + 1)));
  check string "indicators act on nothing" "none"
    (target_text (List.nth scrolled.Pane.targets header_rows));
  List.iteri
    (fun i line -> check int (Printf.sprintf "scrolled row %d width" i) cols (width line))
    scrolled.Pane.rows

let test_scroll_clamps_at_the_last_row () =
  let at_max = Pane.lines ~rows:short_rows ~cols ~scroll:6 fixture in
  let texts = List.map text at_max.Pane.rows in
  check bool "the top indicator counts everything above" true
    (contains "\xe2\x86\x91 6 more" (List.nth texts header_rows));
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
            (contains (Pane.legend ~cols) (text (List.nth value.Pane.rows 1))))
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
  let reading ?(cols = Pane.pane_cols) ~approval () =
    plain (Pane.keeper_state_text ~cols ~health:None ~approval None)
  in
  check bool "approval outranks a running turn" true
    (contains "approval" (reading ~approval:(Some "Write") ()));
  (* Every reading fills the reading area exactly, blank columns included, so
     a row cannot end early and let the next line's columns sit elsewhere. *)
  let width text = Masc_tui_message_layout.display_width text in
  check int "a reading with no record still spends every column" Pane.reading_cells
    (width (reading ~approval:None ()));
  check int "and one waiting on an approval" Pane.reading_cells
    (width (reading ~approval:(Some "Write") ()));
  check bool "the empty case names the reason" true
    (contains "no events" (reading ~approval:None ()));
  (* A tool name past the column is cut with a mark: cut silently it reads
     as another tool. The wide pane has cells for the names that outgrow the
     narrow one. *)
  let long = "masc_msx_press" in
  check bool "a cut tool name says it was cut" true
    (contains "\xe2\x80\xa6" (reading ~approval:(Some long) ()));
  check bool "the wide pane draws it whole" true
    (contains long (reading ~cols:Pane.wide_pane_cols ~approval:(Some long) ()))

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
  check bool "legend is whole" true (contains (Pane.legend ~cols) (nth 1))

(* An end event with a three-digit count and two large parts is the widest done reading;
   it fits the pane whole now that no clock shares the row. *)
let test_widest_done_reading_fits_whole () =
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

(* A sixteen-cell name, a four-digit settled turn and the clock share one
   row: the number already says the turn is done, so no word is drawn and
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
  check bool "no state word doubles the number" false
    (List.exists (fun word -> contains word header) [ "done"; "open"; "no end" ])

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

(* Beside the roster, a keeper with no record of its own leaves the pane one
   sentence -- "tester \xc2\xb7 no events on this feed yet" -- and the four
   column names have nothing under them. The names go, and the sentence sits
   under the header where the names were. With a record the names stay, which
   [test_beside_the_roster_only_the_selected_keepers_record_draws] holds. *)
let test_the_column_names_wait_for_a_row_that_uses_them () =
  let input =
    { fixture with
      Pane.scope = Pane.Selected_only
    ; keepers = Some [ keeper "tester" ]
    ; approvals = []
    ; chunks = chunks [ "tester" ] (entries [])
    }
  in
  let view = Pane.lines ~rows ~cols ~scroll:0 input in
  let texts = List.map text view.Pane.rows in
  check bool "no row uses the columns" false
    (List.exists (fun row -> contains (Pane.legend ~cols) row) texts);
  check bool "the sentence is under the header" true
    (contains "tester" (List.nth texts 1)
     && contains "no events on this feed yet" (List.nth texts 1));
  List.iteri
    (fun i line -> check int (Printf.sprintf "row %d width" i) cols (width line))
    view.Pane.rows

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
  let failed = header { fixture with Pane.keepers = Some [];
    keepers_error = Some "keeper metadata unavailable"; selected = None } in
  check bool "failed read says unavailable" true (contains "keepers unavailable" failed);
  check bool "failed read never counts zero" false (contains "0 keepers" failed);
  let cached = { fixture with keepers_error = Some "refresh failed" } in
  check bool "cached rows do not establish a complete count" true
    (contains "keepers unavailable" (header cached));
  check bool "failed refresh preserves retained keeper rows" true
    (List.exists (fun row -> contains "tester" (text row))
       (Pane.lines ~rows ~cols ~scroll:0 cached).Pane.rows);
  let empty = header { fixture with Pane.keepers = Some []; selected = None } in
  check bool "a read roster with no keepers still counts them" true
    (contains "0 keepers" empty)

(* Only Health_offline. An idle keeper has its keepalive running and has not
   turned yet, which is a row an operator wants to see. A keeper whose health
   did not read is not a keeper reading offline, and dropping those empties
   the pane whenever the roster fails to load. *)
let test_only_offline_is_dropped () =
  let with_health h name = keeper ~health:(Some h) name in
  let input =
    { fixture with
      Pane.keepers =
        Some
          [ with_health Masc.Tui_decode.Health_running "running-one"
          ; with_health Masc.Tui_decode.Health_idle "idle-one"
          ; keeper "unread-one"
          ; with_health Masc.Tui_decode.Health_offline "gone-one"
          ]
    ; selected = Some "running-one"
    }
  in
  let drawn = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let says name = List.exists (fun row -> contains name row) drawn in
  check bool "a running keeper draws" true (says "running-one");
  check bool "an idle one still draws" true (says "idle-one");
  check bool "and one whose health did not read" true (says "unread-one");
  check bool "only the offline one is gone" false (says "gone-one")

(* A failing keeper is still turning, and its turns are the ones an operator
   most needs to read, so it stays beside the offline row that is dropped.
   Its own mark and tone come from the roster, as every keeper's do. *)
let test_a_failing_keeper_is_not_dropped () =
  let input =
    { fixture with
      Pane.keepers =
        Some
          [ keeper ~health:(Some Masc.Tui_decode.Health_running) "running-one"
          ; keeper ~mark:"!" ~tone:Pane.Warn
              ~health:(Some Masc.Tui_decode.Health_failing) "failing-one"
          ; keeper ~health:(Some Masc.Tui_decode.Health_offline) "gone-one"
          ]
    ; selected = Some "running-one"
    }
  in
  let drawn = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let says name = List.exists (fun row -> contains name row) drawn in
  check bool "a failing keeper draws" true (says "failing-one");
  check bool "the offline one beside it is gone" false (says "gone-one")

(* ── calls: marks, order, an opened call ───────────────────────────── *)

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

(* Where the durations do not fit, their sum is the one figure a run has,
   and the count is never dropped to make room -- a row that lost it reads
   as a single call. The pane is drawn at the width the surface leaves it;
   this is one a long run outgrows. *)
let narrow_run_cols = 40

let test_a_narrow_run_says_its_total () =
  let run =
    run_row (Pane.lines ~rows ~cols:narrow_run_cols ~scroll:0 (repeated_input ()))
  in
  check bool ("the count survives: " ^ run) true (contains "\xc3\x975" run);
  check bool "the sum stands for the durations" true (contains "12.0s" run);
  check bool "the list of them is gone" false (contains "274ms" run)

let test_the_call_row_marks_a_batch_and_a_deferral () =
  let texts = List.map text (Pane.lines ~rows ~cols ~scroll:0 (runner_input ())).Pane.rows in
  check bool "a serial completed call wears no mark" true
    (contains "\xe2\x96\xa0    Read" (List.nth texts first_call_row));
  check bool "a call that ran three at once and deferred wears both" true
    (contains "\xe2\x96\xa0 &> masc_delegate" (List.nth texts (first_call_row + 1)));
  check bool "a failed call wears the failure glyph" true
    (contains "\xe2\x9c\x97    Execute" (List.nth texts (first_call_row + 2)));
  check bool "and does not borrow the open-record mark" false
    (contains "~" (List.nth texts (first_call_row + 2)))

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

(* The wire plane stands in with a name and a duration and nothing else,
   and the detail says so rather than drawing blanks. *)
let test_an_opened_wire_call_says_what_it_does_not_carry () =
  let view =
    Pane.lines ~rows ~cols ~scroll:0
      { fixture with
        Pane.scope = Pane.Selected_only
      ; approvals = []
      ; expanded = [ "tester", Acting.Call_by_id "a" ]
      }
  in
  let texts = List.map text view.Pane.rows in
  check bool "the receipt age alone" true (contains "19.0s ago" (List.nth texts 5));
  check bool "no schedule word" false (contains "step" (List.nth texts 5));
  check bool "no input" true (contains "in  not carried" (List.nth texts 6));
  check bool "no output" true (contains "out not carried" (List.nth texts 7));
  check bool "the call still out follows" true (contains "Execute" (List.nth texts 8))

(* The widest facts row the vocabulary can produce -- the longest
   disposition word, a minutes-and-seconds age, a two-digit batch -- is 47
   cells after the indent, inside the pane's 50. The first cut of this row
   put the disposition last, where a three-at-once batch left it five cells
   and "deferred" drew as "defer". *)
let test_the_widest_facts_row_keeps_every_word () =
  let wide =
    [ runner_call ~at:(now -. 725.) ~duration_ms:5. ~id:"wide"
        ~schedule:(schedule ~step:12 ~batch_index:3 ~at_once:12 Contract.Concurrent)
        ~disposition:(Ok Masc.Tui_decode.Keeper_call_completed) "Read"
    ]
  in
  let view =
    Pane.lines ~rows ~cols ~scroll:0
      { (runner_input ~expanded:[ "runner", Acting.Call_by_id "wide" ] ()) with
        Pane.chunks = chunks [ "runner" ] (entries wide)
      }
  in
  let facts = text (List.nth view.Pane.rows (first_call_row + 1)) in
  check bool "the whole row" true
    (contains "completed \xc2\xb7 12m05s ago \xc2\xb7 concurrent, 12 at once" facts);
  check int "at the pane's width" cols (width (List.nth view.Pane.rows (first_call_row + 1)))

(* A ledger row whose schedule or disposition did not parse keeps the error
   beside the call rather than a default: the call row wears no dispatch
   mark, and the opened row says which reading is missing. *)
let test_an_unparsed_schedule_or_disposition_is_said_not_defaulted () =
  let row =
    ( 960.
    , Observer.Keeper_tool_call
        { Observer.kt_keeper = "runner"
        ; kt_turn = Some 12
        ; kt_tool = "Read"
        ; kt_duration_ms = Some 5.
        ; kt_disposition = Some (Error "keeper call has unknown disposition delivered")
        ; kt_at = 960.
        ; kt_tool_use_id = Some "odd"
        ; kt_schedule = Some (Error "tool schedule batch_size must be positive")
        ; kt_tool_args = None
        ; kt_tool_result = None
        ; kt_tool_args_preview = None
        ; kt_tool_output_preview = None
        } )
  in
  let view =
    Pane.lines ~rows ~cols ~scroll:0
      { (runner_input ~expanded:[ "runner", Acting.Call_by_id "odd" ] ()) with
        Pane.chunks = chunks [ "runner" ] (entries [ row ])
      }
  in
  let texts = List.map text view.Pane.rows in
  check bool "no dispatch mark on the call row" true
    (contains "\xe2\x96\xa0    Read" (List.nth texts first_call_row));
  let facts = List.nth texts (first_call_row + 1) in
  check bool "the disposition is a question" true (contains "disposition ?" facts);
  check bool "so is the schedule" true (contains "schedule ?" facts)

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

(* One keeper turn, two model responses: the first asked for a Read, a Grep
   and a Glob, the second for an Execute. *)
let two_responses =
  [ observed ~at:940. 7
  ; runner_call ~at:950. ~duration_ms:5. ~id:"r1" ~session:(Some 7) "Read"
  ; runner_call ~at:953. ~duration_ms:5. ~id:"r2" ~session:(Some 7) "Grep"
  ; runner_call ~at:956. ~duration_ms:5. ~id:"r3" ~session:(Some 7) "Glob"
  ; observed ~at:960. 8
  ; runner_call ~at:970. ~duration_ms:5. ~id:"r4" ~session:(Some 8) "Execute"
  ]

let responses_view ?(cols = cols) ?(order = Pane.Newest_first) ?(expanded = []) calls =
  Pane.lines ~rows ~cols ~scroll:0
    { (runner_input ~order ~expanded ()) with
      Pane.chunks = chunks [ "runner" ] (entries calls)
    }

let opens = "\xe2\x94\x8c"
let inside = "\xe2\x94\x82"
let closes = "\xe2\x94\x94"

(* The border cell a row starts with, and its tone. *)
let rail (line : Pane.line) =
  match line with span :: _ -> (span.Pane.text, span.Pane.tone) | [] -> ("", Pane.Plain)

(* Every call row keeps the pane's dim edge: no bracket anywhere. *)
let no_bracket label view =
  let calls =
    List.combine view.Pane.rows view.Pane.targets
    |> List.filter_map (fun (row, target) ->
           match target with Pane.Target_call _ -> Some row | _ -> None)
  in
  check bool (label ^ ": the calls draw") true (calls <> []);
  check bool (label ^ ": the heading counts no responses") false
    (List.exists (fun row -> contains "responses" (text row)) view.Pane.rows);
  List.iteri
    (fun i row ->
      check bool
        (Printf.sprintf "%s: call row %d keeps the dim edge" label i)
        true
        (rail row = (inside, Pane.Dim)))
    calls

let test_each_model_response_gets_a_bracket_beside_its_calls () =
  List.iter
    (fun (order, label, expected) ->
      let view = responses_view ~order two_responses in
      (* The four calls take the four rows under the heading: the bracket
         added none. *)
      List.iteri
        (fun i (glyph, tone, tool) ->
          let row = List.nth view.Pane.rows (first_call_row + i) in
          check bool (Printf.sprintf "%s: row %d is %s" label i tool) true
            (contains tool (text row));
          check bool (Printf.sprintf "%s: %s wears its place" label tool) true
            (rail row = (glyph, tone));
          check int (Printf.sprintf "%s: row %d width" label i) cols (width row))
        expected;
      check bool (label ^ ": the heading counts the responses") true
        (contains "calls \xc2\xb7 " (text (List.nth view.Pane.rows (first_call_row - 1)))
         && contains "\xc2\xb7 2 responses" (text (List.nth view.Pane.rows (first_call_row - 1))));
      check bool (label ^ ": the heading keeps the dim edge") true
        (rail (List.nth view.Pane.rows (first_call_row - 1)) = (inside, Pane.Dim)))
    [ ( Pane.Oldest_first
      , "oldest first"
      , [ (opens, Pane.Plain, "Read")
        ; (inside, Pane.Plain, "Grep")
        ; (closes, Pane.Plain, "Glob")
        ; (inside, Pane.Dim, "Execute")
        ] )
    ; ( Pane.Newest_first
      , "newest first"
      , [ (inside, Pane.Dim, "Execute")
        ; (opens, Pane.Plain, "Glob")
        ; (inside, Pane.Plain, "Grep")
        ; (closes, Pane.Plain, "Read")
        ] )
    ]

(* An opened call's detail rows are the call's, not the response's: they
   keep the pane's edge and the next call picks the bracket up again. *)
let test_an_opened_call_inside_a_bracket_keeps_its_detail_on_the_edge () =
  let view =
    responses_view ~order:Pane.Oldest_first
      ~expanded:[ "runner", Acting.Call_by_id "r2" ]
      two_responses
  in
  let row i = List.nth view.Pane.rows (first_call_row + i) in
  check bool "Grep inside the bracket" true (rail (row 1) = (inside, Pane.Plain));
  List.iter
    (fun i ->
      check bool (Printf.sprintf "detail row %d on the dim edge" i) true
        (rail (row i) = (inside, Pane.Dim)))
    [ 2; 3; 4 ];
  check bool "Glob closes it after the detail" true
    (rail (row 5) = (closes, Pane.Plain) && contains "Glob" (text (row 5)))

(* The planned index is not the response. A concurrent batch settles in any
   order, so one response's calls arrive as steps 2, 1, 3; and a CLI lane
   runs the whole keeper turn as one provider call, counting its calls
   across the turn. Neither is two responses. *)
let test_one_ordinal_is_one_response_whatever_the_planned_index_says () =
  let concurrent step = schedule ~step ~batch_index:0 ~at_once:3 Contract.Concurrent in
  let serial step = schedule ~step ~batch_index:0 ~at_once:1 Contract.Serial in
  List.iter
    (fun (label, calls) -> no_bracket label (responses_view calls))
    [ ( "a batch settling out of plan order"
      , [ runner_call ~at:950. ~duration_ms:5. ~id:"b2" ~schedule:(concurrent 2) "Read"
        ; runner_call ~at:951. ~duration_ms:5. ~id:"b1" ~schedule:(concurrent 1) "Grep"
        ; runner_call ~at:952. ~duration_ms:5. ~id:"b3" ~schedule:(concurrent 3) "WebFetch"
        ] )
    ; ( "a CLI lane counting across the turn"
      , [ runner_call ~at:950. ~duration_ms:5. ~id:"c1" ~schedule:(serial 1) "Read"
        ; runner_call ~at:951. ~duration_ms:5. ~id:"c2" ~schedule:(serial 2) "Grep"
        ; runner_call ~at:952. ~duration_ms:5. ~id:"c3" ~schedule:(serial 3) "WebFetch"
        ] )
    ]

let test_the_sorts_draw_no_bracket () =
  List.iter
    (fun (order, label) -> no_bracket label (responses_view ~order two_responses))
    [ Pane.Longest_first, "longest first"; Pane.By_tool, "by tool" ]

(* A call that states no ordinal could belong to either response beside it,
   so the record says nothing about where responses end. *)
let test_a_call_without_an_ordinal_leaves_the_responses_unsaid () =
  let calls =
    two_responses
    @ [ runner_call ~at:980. ~duration_ms:5. ~id:"r5" ~session:None "Write" ]
  in
  let view = responses_view calls in
  let texts = List.map text view.Pane.rows in
  check bool "the unnumbered call draws in the same record" true
    (List.exists (contains "Write") texts && List.exists (contains "Read") texts);
  no_bracket "an unnumbered call" view

(* A runtime whose ledger is silent is drawn from the wire, and its frames
   carry the same ordinal. *)
let test_wire_calls_split_into_responses_too () =
  let wire ?(kind = Observer.Tool_called) ~at ~turn ~id tool =
    ( at
    , agent_core ~kind ~tool ~turn ~tool_use_id:id ~at ~correlation:"trace-runner" lane )
  in
  let calls =
    [ observed ~at:940. 7
    ; wire ~at:950. ~turn:7 ~id:"w1" "Read"
    ; wire ~kind:Observer.Tool_completed ~at:952. ~turn:7 ~id:"w1" "Read"
    ; observed ~at:960. 8
    ; wire ~at:970. ~turn:8 ~id:"w2" "Execute"
    ]
  in
  let view = responses_view ~order:Pane.Oldest_first calls in
  let row i = List.nth view.Pane.rows (first_call_row + i) in
  (* Two lone calls: no bracket anywhere, so the heading's count is the
     only thing that tells this record from one response. *)
  check bool "the heading counts two responses" true
    (contains "\xc2\xb7 2 responses" (text (List.nth view.Pane.rows (first_call_row - 1))));
  check bool "the first response, alone on the edge" true
    (rail (row 0) = (inside, Pane.Dim) && contains "Read" (text (row 0)));
  check bool "the second, alone on the edge" true
    (rail (row 1) = (inside, Pane.Dim) && contains "Execute" (text (row 1)))

(* ── the wide pane ──────────────────────────────────────────────────── *)

let wide_cols = Pane.wide_pane_cols

(* A bracketed call row in the wide pane keeps its bracket, its name and
   its age, and an opened call's facts row says the same age the same way
   as the row above it. The calls arrived at 950, 953, 956 and 970; now is
   1000. *)
let test_a_wide_bracketed_row_and_its_detail_say_one_age () =
  let view =
    responses_view ~cols:wide_cols ~order:Pane.Oldest_first
      ~expanded:[ "runner", Acting.Call_by_id "r2" ]
      two_responses
  in
  let row i = List.nth view.Pane.rows (first_call_row + i) in
  check bool "Read opens the bracket, ends with its age" true
    (rail (row 0) = (opens, Pane.Plain)
     && contains "Read" (text (row 0))
     && String.ends_with ~suffix:"5ms  50.0s" (text (row 0)));
  check bool "Grep inside it, with its age" true
    (rail (row 1) = (inside, Pane.Plain)
     && String.ends_with ~suffix:"5ms  47.0s" (text (row 1)));
  check bool "Grep's facts row says the same age" true
    (contains "47.0s ago" (text (row 2)));
  check bool "Execute alone, its age at the edge" true
    (rail (row 6) = (inside, Pane.Dim)
     && String.ends_with ~suffix:"5ms  30.0s" (text (row 6)))

(* The longest name on the live roster: the narrow pane cuts it, the wide
   one keeps it whole, and the column names move over with the name column. *)
let long_name = "kidsnote-slack-context-collector"

let test_the_wide_fleet_row_keeps_a_long_name_whole () =
  let input =
    { fixture with
      Pane.keepers = Some [ keeper long_name; keeper "tester" ]
    ; selected = Some "tester"
    ; chunks = chunks [ long_name; "tester" ] fixture_entries
    }
  in
  let texts cols = List.map text (Pane.lines ~rows ~cols ~scroll:0 input).Pane.rows in
  let keeper_row cols =
    let view = Pane.lines ~rows ~cols ~scroll:0 input in
    List.combine view.Pane.rows view.Pane.targets
    |> List.find_map (fun (row, target) ->
           match target with
           | Pane.Target_keeper name when String.equal name long_name -> Some (text row)
           | _ -> None)
  in
  (match keeper_row Pane.pane_cols, keeper_row wide_cols with
   | Some narrow_row, Some wide_row ->
       check bool "the narrow pane cuts the name" false (contains long_name narrow_row);
       check bool "the wide pane keeps it whole" true (contains long_name wide_row)
   | None, _ | _, None -> fail "the long-named keeper's fleet row is missing");
  let leading_spaces s =
    let n = String.length s in
    let rec go i = if i < n && s.[i] = ' ' then go (i + 1) else i in
    go 0
  in
  check int "the column names move over by the extra name cells"
    (leading_spaces (Pane.legend ~cols:Pane.pane_cols) + Pane.wide_name_extra_cells)
    (leading_spaces (Pane.legend ~cols:wide_cols));
  check bool "the wide legend is drawn whole" true
    (contains (Pane.legend ~cols:wide_cols) (List.nth (texts wide_cols) 1))

(* In the wide pane a call row ends with its age since receipt, padded to
   six cells, and the duration sits one gap before it, so both line up at
   the right edge. runner's calls arrived at 950, 960 and 970; now is 1000. *)
let test_a_wide_call_row_ends_with_its_age () =
  let view = Pane.lines ~rows ~cols:wide_cols ~scroll:0 (runner_input ()) in
  let row i = text (List.nth view.Pane.rows (first_call_row + i)) in
  check bool "Read: its duration, then its age" true
    (String.ends_with ~suffix:"5ms  50.0s" (row 0));
  check bool "masc_delegate: the same columns" true
    (String.ends_with ~suffix:"50ms  40.0s" (row 1));
  check bool "Execute, still out: the age alone" true
    (String.ends_with ~suffix:" 30.0s" (row 2) && not (contains "ms" (row 2)));
  let narrow_view = Pane.lines ~rows ~cols ~scroll:0 (runner_input ()) in
  check bool "the narrow pane draws no age" false
    (List.exists (contains "50.0s") (List.map text narrow_view.Pane.rows))

(* An age past ninety-nine minutes is wider than the six cells the column
   is padded to: the row widens the age and keeps every digit. *)
let test_an_old_call_keeps_every_digit_of_its_age () =
  let old = [ runner_call ~at:(now -. 7_205.) ~duration_ms:5. ~id:"old" "Read" ] in
  let view =
    Pane.lines ~rows ~cols:wide_cols ~scroll:0
      { (runner_input ()) with Pane.chunks = chunks [ "runner" ] (entries old) }
  in
  let row = List.nth view.Pane.rows first_call_row in
  check bool "120m05s whole at the edge" true (String.ends_with ~suffix:"5ms 120m05s" (text row));
  check int "the row still fits" wide_cols (width row)

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
      , [ test_case "drawn cols follow the choice and the room" `Quick
            test_drawn_cols_follow_the_choice_and_the_room
        ; test_case "Ctrl-L walks narrow, wide, hidden" `Quick
            test_ctrl_l_walks_narrow_wide_hidden
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
    ; ( "what the keeper is doing now"
      , [ test_case "a running keeper names the call that is out" `Quick
            test_a_running_keeper_names_the_call_that_is_out
        ; test_case "a running keeper between calls says the model has the turn" `Quick
            test_a_running_keeper_between_calls_says_the_model_has_the_turn
        ; test_case "a record without markers keeps the older reading" `Quick
            test_a_record_without_markers_keeps_the_older_reading
        ; test_case "an idle keeper's settled record says how long it has been quiet" `Quick
            test_an_idle_keepers_settled_record_says_how_long_it_has_been_quiet
        ] )
    ; ( "a gone keeper"
      , [ test_case "a gone keeper's turn is not read as running" `Quick
            test_a_gone_keepers_turn_is_not_read_as_running
        ; test_case "a gone keeper's focus header says no end, process gone" `Quick
            test_a_gone_keepers_focus_header_says_unfinished
        ; test_case "a gone keeper's earlier turn also says no end" `Quick
            test_a_gone_keepers_earlier_turn_also_says_no_end
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
        ; test_case "a call row names the call a press opens" `Quick
            test_a_call_row_names_the_call_a_press_opens
        ] )
    ; ( "calls"
      , [ test_case "the call row marks a batch and a deferral" `Quick
            test_the_call_row_marks_a_batch_and_a_deferral
        ; test_case "a run of one tool is one counted row" `Quick
            test_a_run_of_one_tool_is_one_counted_row
        ; test_case "a narrow run says its total" `Quick
            test_a_narrow_run_says_its_total
        ; test_case "an opened call draws its facts and previews" `Quick
            test_an_opened_call_draws_its_facts_and_previews
        ; test_case "an opened wire call says what it does not carry" `Quick
            test_an_opened_wire_call_says_what_it_does_not_carry
        ; test_case "the widest facts row keeps every word" `Quick
            test_the_widest_facts_row_keeps_every_word
        ; test_case "an unparsed schedule or disposition is said, not defaulted" `Quick
            test_an_unparsed_schedule_or_disposition_is_said_not_defaulted
        ; test_case "each order lists the calls as the heading says" `Quick
            test_each_order_lists_the_calls_as_the_heading_says
        ; test_case "the order cycles through all four" `Quick
            test_the_order_cycles_through_all_four
        ] )
    ; ( "wide"
      , [ test_case "a wide bracketed row and its detail say one age" `Quick
            test_a_wide_bracketed_row_and_its_detail_say_one_age
        ; test_case "the wide fleet row keeps a long name whole" `Quick
            test_the_wide_fleet_row_keeps_a_long_name_whole
        ; test_case "a wide call row ends with its age" `Quick
            test_a_wide_call_row_ends_with_its_age
        ; test_case "an old call keeps every digit of its age" `Quick
            test_an_old_call_keeps_every_digit_of_its_age
        ] )
    ; ( "responses"
      , [ test_case "each model response gets a bracket beside its calls" `Quick
            test_each_model_response_gets_a_bracket_beside_its_calls
        ; test_case "an opened call inside a bracket keeps its detail on the edge" `Quick
            test_an_opened_call_inside_a_bracket_keeps_its_detail_on_the_edge
        ; test_case "one ordinal is one response, whatever the planned index says" `Quick
            test_one_ordinal_is_one_response_whatever_the_planned_index_says
        ; test_case "the sorts draw no bracket" `Quick test_the_sorts_draw_no_bracket
        ; test_case "a call without an ordinal leaves the responses unsaid" `Quick
            test_a_call_without_an_ordinal_leaves_the_responses_unsaid
        ; test_case "wire calls split into responses too" `Quick
            test_wire_calls_split_into_responses_too
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
        ; test_case "widest done reading fits whole" `Quick
            test_widest_done_reading_fits_whole
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
        ; test_case "a failing keeper is not dropped" `Quick
            test_a_failing_keeper_is_not_dropped
        ] )
    ; ( "keyboard cursor"
      , [ test_case "the cursor steps over rows a press does nothing on" `Quick
            test_cursor_steps_over_rows_a_press_does_nothing_on
        ; test_case "the cursor stops at the frame's edge" `Quick
            test_cursor_stops_at_the_frames_edge
        ] )
    ; ( "beside the roster"
      , [ test_case "only the selected keeper's record draws" `Quick
            test_beside_the_roster_only_the_selected_keepers_record_draws
        ; Alcotest.test_case "the column names wait for a row that uses them"
            `Quick test_the_column_names_wait_for_a_row_that_uses_them
        ; test_case "a long record folds and scrolls" `Quick
            test_beside_the_roster_a_long_record_folds_and_scrolls
        ; test_case "keepers waiting on approval still draw" `Quick
            test_beside_the_roster_keepers_waiting_on_approval_still_draw
        ; test_case "focus header keeps its clock behind a wide name and a named turn" `Quick
            test_focus_header_keeps_its_clock_behind_a_wide_name_and_a_named_turn
        ] )
    ]
