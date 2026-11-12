(* The Activity pane projects the feed the TUI already holds into a column
   beside any surface. These cases pin what a press on the column does: each
   row names what a press on it acts on, the keyboard cursor steps over rows
   a press does nothing on, every keeper stays reachable through the scroll
   windows, files open only from a current source, and the layout and the
   call order cycle. *)

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
  ; keeper_context = None
  ; approvals = [ { Pane.approval_keeper = "polisher"; approval_tool = "tool_execute" } ]
  ; chunks = chunks [ "quiet-one"; "tester"; "probe"; "polisher" ] fixture_entries
  ; changes = Pane.Changes_absent
  ; call_order = Pane.Oldest_first
  ; expanded = []
  ; ko = false
  }

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
  check bool "keeper navigation remains available" true
    (List.exists (function Pane.Target_keeper "tester" -> true | _ -> false) drawn.Pane.targets)

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

let roomy = Pane.wide_threshold_cols + 20
let middling = Pane.wide_threshold_cols - 1
let narrow = Pane.threshold_cols - 1

let layout =
  testable (fun ppf l -> Format.pp_print_string ppf (Pane.layout_label ~ko:false l)) ( = )

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

(* ── scroll ─────────────────────────────────────────────────────────── *)

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
        [ "polisher"; "tester"; "probe"; "quiet-one" ])
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
    ; authority = Pane.Changes_current
    ; refresh_failed = None
    }

let changes_fixture = { fixture with Pane.tab = Pane.Tab_changes; changes = ready }

let test_file_targets_require_current_authority () =
  let has_file_target authority =
    let changes = match ready with
      | Pane.Changes_ready value -> Pane.Changes_ready { value with authority }
      | Pane.Changes_absent | Pane.Changes_loading | Pane.Changes_failed _ ->
          fail "fixture has no file changes"
    in
    let view = Pane.lines ~rows:20 ~cols ~scroll:0 { changes_fixture with changes } in
    List.exists (function
      | Pane.Target_file _ -> true
      | Pane.Target_none | Pane.Target_next_tab | Pane.Target_keeper _ | Pane.Target_more
      | Pane.Target_calls _ | Pane.Target_call _ | Pane.Target_call_order -> false)
      view.targets
  in
  check bool "a current source can open files" true (has_file_target Pane.Changes_current);
  List.iter (fun authority ->
    check bool "a retained source cannot open files" false (has_file_target authority))
    [ Pane.Changes_workspace_unconfirmed; Pane.Changes_revalidating
    ; Pane.Changes_needs_revalidation ]

let test_changes_header_marks_its_tab () =
  check bool "next tab flips" true
    (Pane.next_tab Pane.Tab_fleet = Pane.Tab_changes
     && Pane.next_tab Pane.Tab_changes = Pane.Tab_fleet)

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
      over_budget = 0; malformed = 0; authority = Pane.Changes_current; refresh_failed = None } } in
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

(* Beside the roster the rows are: header, legend, focus header, calls
   heading, then the calls. *)
let first_call_row = 4

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

(* The cases below hold the click table by which targets a frame carries, not
   by where a row sits: a frame that moves a row keeps them passing, and a row
   that stops naming what a press acts on fails them. *)
let count_targets target (view : Pane.rendering) =
  List.length (List.filter (fun value -> value = target) view.Pane.targets)

let keeper_names (view : Pane.rendering) =
  List.filter_map
    (function Pane.Target_keeper name -> Some name | _ -> None)
    view.Pane.targets

let test_a_press_on_the_recent_tab_acts_on_what_each_row_names () =
  let view = Pane.lines ~rows ~cols ~scroll:0 fixture in
  check int "one target per row" rows (List.length view.Pane.targets);
  check int "the header turns the tab" 1 (count_targets Pane.Target_next_tab view);
  check int "the calls heading turns the order" 1
    (count_targets Pane.Target_call_order view);
  check (list string) "each fleet row names its keeper"
    [ "polisher"; "probe"; "quiet-one"; "tester" ]
    (List.sort String.compare (keeper_names view));
  check int "each call of the focus keeper opens that call" 2
    (List.length
       (List.filter
          (function Pane.Target_call ("tester", _) -> true | _ -> false)
          view.Pane.targets));
  check int "only the tab header, four fleet rows, the calls heading and two calls act" 8
    (List.length
       (List.filter (fun target -> target <> Pane.Target_none) view.Pane.targets));
  check int "everything fits: nothing is folded" 0
    (count_targets Pane.Target_more view);
  check int "everything fits: the wheel moves nothing" 0 view.Pane.scroll_max

let test_the_fold_line_scrolls_into_the_full_list () =
  let folded = Pane.lines ~rows:4 ~cols ~scroll:0 fixture in
  check bool "the fold line is a press target" true
    (List.mem Pane.Target_more folded.Pane.targets)

let test_the_largest_scroll_ends_on_the_last_call () =
  let rows = 6 in
  let first = Pane.lines ~rows ~cols ~scroll:0 fixture in
  let last = Pane.lines ~rows ~cols ~scroll:first.Pane.scroll_max fixture in
  check bool "no blank row is scrolled into below the last call" true
    (match List.nth last.Pane.targets (rows - 1) with
     | Pane.Target_call ("tester", _) -> true
     | _ -> false)

let test_a_press_on_the_changes_tab_opens_the_file_its_row_names () =
  let view = Pane.lines ~rows ~cols ~scroll:0 changes_fixture in
  check int "the header turns the tab" 1 (count_targets Pane.Target_next_tab view);
  let file_rows =
    List.filter_map
      (fun (row, target) ->
        match target with
        | Pane.Target_file index -> Some (index, text row)
        | _ -> None)
      (List.combine view.Pane.rows view.Pane.targets)
  in
  check (list int) "the file rows carry their index, in the order given" [ 0; 1; 2 ]
    (List.map fst file_rows);
  List.iter2
    (fun (index, row) name ->
      check bool (Printf.sprintf "the row of file %d names that file" index) true
        (contains name row))
    file_rows
    [ "masc_tui_acting_pane.ml"; "test_tui_acting_pane.ml"; "masc_tui.ml" ];
  check int "everything fits: the wheel moves nothing" 0 view.Pane.scroll_max

let test_an_open_calls_detail_rows_act_on_the_same_call () =
  let key = Acting.Call_by_id "second" in
  let view =
    Pane.lines ~rows ~cols ~scroll:0 (runner_input ~expanded:[ "runner", key ] ())
  in
  check int "the call row and its three detail rows act on that call" 4
    (count_targets (Pane.Target_call ("runner", key)) view)

let test_beside_the_roster_only_a_keeper_waiting_on_approval_keeps_a_fleet_row () =
  let beside input =
    Pane.lines ~rows ~cols ~scroll:0 { input with Pane.scope = Pane.Selected_only }
  in
  let nobody_waiting = beside { fixture with Pane.approvals = [] } in
  check (list string) "no approval, no fleet row" [] (keeper_names nobody_waiting);
  check int "the selected keeper's calls heading still turns the order" 1
    (count_targets Pane.Target_call_order nobody_waiting);
  check int "everything fits: the wheel moves nothing" 0 nobody_waiting.Pane.scroll_max;
  check (list string) "only the waiting keeper keeps a fleet row" [ "polisher" ]
    (keeper_names (beside fixture))

let test_failure_rows_leave_fleet_navigation_reachable () =
  let failures =
    List.init 20 (fun index ->
        Printf.sprintf "unbooted-%02d" index, Printf.sprintf "reason-%02d" index)
  in
  let input = { fixture with trace_unavailable = failures } in
  List.iter
    (fun (rows, cols) ->
      let view = Pane.lines ~rows ~cols ~scroll:0 input in
      check int "one target per row" rows (List.length view.Pane.targets);
      check bool "a press can still reach a keeper or the full list" true
        (List.exists
           (function Pane.Target_keeper _ | Pane.Target_more -> true | _ -> false)
           view.Pane.targets))
    [ 8, 42; 3, 30 ]

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

(* An age is read from the feed's stamp and the TUI's own clock. A stamp after
   the clock, or one that is not a number, has no age: the cell holds the
   no-value mark, not "0ms" (#38663). *)
let test_an_age_the_clocks_cannot_give_draws_the_no_value_mark () =
  let no_value = Masc_tui_theme.Glyph.no_value in
  List.iter
    (fun (what, stamp) ->
       check string what no_value (Pane.age_text ~now stamp))
    [ "a stamp after the clock", now +. 10.
    ; "a stamp that is not a number", Float.nan
    ];
  check bool "a stamp before the clock has an age" true
    (not (String.equal (Pane.age_text ~now (now -. 10.)) no_value));
  check bool "a stamp at the clock has an age" true
    (not (String.equal (Pane.age_text ~now now) no_value))

let test_keeper_waiting_context_preserves_evidence () =
  let module Model = Masc_tui_keeper_list_model in
  let context waiting = Pane.{keeper_name = "alpha"; task = Task_not_observed;
    waiting; waiting_stale = false; waiting_revalidating = false;
    waiting_failed = false} in
  let item source producer what : Masc.Tui_decode.waiting_item =
    {kwi_source = source; kwi_waiting_on = "item"; kwi_what = what;
     kwi_wake_producer = producer; kwi_since = None; kwi_due_at = None;
     kwi_next_action = "resume"} in
  let row name items : Masc.Tui_decode.keeper_waiting_row =
    {kwr_keeper_name = name; kwr_state = Keeper_waiting_blocked;
     kwr_waiting_count = List.length items; kwr_since = None; kwr_due_at = None;
     kwr_waiting_on = items} in
  check bool "an unread inventory is not an empty inventory" true
    (Pane.summarize_keeper_waiting (context Model.Waiting_unobserved) = Pane.Waiting_not_observed);
  let failed_before_first_row = { (context Model.Waiting_unobserved) with waiting_stale = true } in
  check bool "a failed read before the first row is unavailable" true
    (Pane.summarize_keeper_waiting failed_before_first_row = Pane.Waiting_read_unavailable);
  check bool "an unavailable inventory is not an empty inventory" true
    (Pane.summarize_keeper_waiting (context Model.Waiting_unavailable) = Pane.Waiting_read_unavailable);
  let other = row "beta" [] in
  check bool "another Keeper's inventory is refused" true
    (Pane.summarize_keeper_waiting (context (Model.Waiting_observed other)) = Pane.Waiting_read_unavailable);
  let schedule = item Waiting_source_schedule_waiting Wake_schedule_store "scheduled work" in
  let misleading = item Waiting_source_event_queue_pending Wake_keeper_owner_actor "delegate result" in
  let observed = Pane.summarize_keeper_waiting (context (Model.Waiting_observed (row "alpha" [schedule; misleading]))) in
  check bool "only typed sources establish schedules and delegate results" true
    (match observed with
     | Pane.Waiting_items {schedules; delegate_result_waiting = false; read_error = false} ->
         schedules = [schedule]
     | Waiting_items _ | Waiting_not_observed | Waiting_read_unavailable -> false);
  let result = item Waiting_source_event_queue_pending Wake_keeper_delegate "result" in
  check bool "the recorded delegate producer is observed" true
    (match Pane.summarize_keeper_waiting (context (Model.Waiting_observed (row "alpha" [result]))) with
     | Pane.Waiting_items {delegate_result_waiting = true; _} -> true
     | Waiting_items _ | Waiting_not_observed | Waiting_read_unavailable -> false);
  let error = item Waiting_source_read_error Wake_read_model_reader "unavailable" in
  check bool "a source read error stays visible in the observation" true
    (match Pane.summarize_keeper_waiting (context (Model.Waiting_observed (row "alpha" [error]))) with
     | Pane.Waiting_items {schedules = []; delegate_result_waiting = false; read_error = true} -> true
     | Waiting_items _ | Waiting_not_observed | Waiting_read_unavailable -> false)

let test_context_change_keeps_focus_in_pane () =
  check (option int) "unchanged context retains focus" (Some 4)
    (Pane.reconcile_context_cursor ~previous_rows:6 ~current_rows:6 (Some 4));
  check (option int) "context inserted moves focus to the pane header" (Some 0)
    (Pane.reconcile_context_cursor ~previous_rows:0 ~current_rows:6 (Some 4));
  check (option int) "context removed moves focus to the pane header" (Some 0)
    (Pane.reconcile_context_cursor ~previous_rows:6 ~current_rows:0 (Some 4));
  check (option int) "no focus remains absent" None
    (Pane.reconcile_context_cursor ~previous_rows:0 ~current_rows:6 None)

let test_task_source_preserves_failed_refresh () =
  let classify ~workspace_ready ~source ~metadata_failed ~task_id =
    Pane.summarize_keeper_task ~workspace_ready ~source ~metadata_failed ~task_id in
  check bool "unread metadata is unavailable" true
    (classify ~workspace_ready:true ~source:Task_source_unread ~metadata_failed:false
       ~task_id:(Some "old") = Task_unavailable);
  check bool "foreign workspace metadata is unavailable" true
    (classify ~workspace_ready:false ~source:Task_source_read ~metadata_failed:false
       ~task_id:(Some "old") = Task_unavailable);
  check bool "failed local read retains only last observed task" true
    (classify ~workspace_ready:true ~source:Task_source_failed ~metadata_failed:false
       ~task_id:(Some "old") = Task_observed { id = "old"; refresh_failed = true });
  check bool "partial metadata failure marks the retained task" true
    (classify ~workspace_ready:true ~source:Task_source_read ~metadata_failed:true
       ~task_id:(Some "old") = Task_observed { id = "old"; refresh_failed = true });
  check bool "failed read without a task is not a known empty read" true
    (classify ~workspace_ready:true ~source:Task_source_failed ~metadata_failed:false
       ~task_id:None = Task_refresh_failed)

let () =
  run "tui acting pane"
    [ ( "viewport allocation"
      , [ test_case "hidden Unicode rows remain reachable without layout allocation" `Quick
            test_hidden_rows_do_not_allocate_text_layout ] )
    ; ( "width"
      , [ test_case "Ctrl-L walks narrow, wide, hidden" `Quick
            test_ctrl_l_walks_narrow_wide_hidden
        ;] )
    ; ( "what the keeper is doing now"
      , [] )
    ; ( "a gone keeper"
      , [] )
    ; ( "targets"
      , [ test_case "an earlier turn row opens the keeper's calls" `Quick
            test_an_earlier_turn_row_opens_the_keepers_calls
        ; test_case "a call row names the call a press opens" `Quick
            test_a_call_row_names_the_call_a_press_opens
        ; test_case "a press on the Recent tab acts on what each row names" `Quick
            test_a_press_on_the_recent_tab_acts_on_what_each_row_names
        ; test_case "the fold line scrolls into the full list" `Quick
            test_the_fold_line_scrolls_into_the_full_list
        ; test_case "the largest scroll ends on the last call" `Quick
            test_the_largest_scroll_ends_on_the_last_call
        ; test_case "a press on the Changes tab opens the file its row names" `Quick
            test_a_press_on_the_changes_tab_opens_the_file_its_row_names
        ; test_case "an open call's detail rows act on the same call" `Quick
            test_an_open_calls_detail_rows_act_on_the_same_call
        ; test_case "beside the roster only a keeper waiting on approval keeps a fleet row"
            `Quick
            test_beside_the_roster_only_a_keeper_waiting_on_approval_keeps_a_fleet_row
        ; test_case "failure rows leave fleet navigation reachable" `Quick
            test_failure_rows_leave_fleet_navigation_reachable
        ] )
    ; ( "calls"
      , [ test_case "the order cycles through all four" `Quick
            test_the_order_cycles_through_all_four
        ] )
    ; ( "wide"
      , [] )
    ; ( "responses"
      , [] )
    ; ( "scroll"
      , [ test_case "legend preserves reachable targets" `Quick
            test_legend_preserves_reachable_targets_in_small_windows
        ;] )
    ; ( "changes tab"
      , [ test_case "header marks its tab" `Quick test_changes_header_marks_its_tab
        ; test_case "file opening requires current source authority" `Quick
            test_file_targets_require_current_authority
        ] )
    ; ( "text"
      , [ test_case "reused chunks keep presentation inputs live" `Quick
            test_reused_chunks_keep_presentation_inputs_live
        ;] )
    ; ( "offline"
      , [ test_case "identity failure preserves roster navigation" `Quick
            test_trace_failure_is_readable_without_hiding_roster
        ;] )
    ; ( "keyboard cursor"
      , [ test_case "the cursor steps over rows a press does nothing on" `Quick
            test_cursor_steps_over_rows_a_press_does_nothing_on
        ; test_case "the cursor stops at the frame's edge" `Quick
            test_cursor_stops_at_the_frames_edge
        ] )
    ; ( "beside the roster"
      , [ test_case "waiting context uses the selected Keeper's typed evidence" `Quick
            test_keeper_waiting_context_preserves_evidence
        ; test_case "a context change keeps keyboard focus in the pane" `Quick
            test_context_change_keeps_focus_in_pane
        ; test_case "task source keeps failed and unread states distinct" `Quick
            test_task_source_preserves_failed_refresh
        ;] )
    ; ( "ages"
      , [ test_case "an age the clocks cannot give draws the no-value mark" `Quick
            test_an_age_the_clocks_cannot_give_draws_the_no_value_mark
        ] )
    ]
