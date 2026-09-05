(* The Activity pane projects the feed the TUI already holds into a column
   beside any surface. These cases pin what the column says: who acted last
   comes first, a keeper waiting on the reader outranks a working one, the
   focus block names the current turn's calls, and every row is exactly the
   pane's width so the surface beside it never shifts. *)

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
   turn earlier. polisher is waiting on an approval. quiet-one never acted. *)
let fixture : Pane.input =
  { Pane.now
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

let rows = 14
let cols = Pane.pane_cols
let drawn = Pane.lines ~rows ~cols fixture
let texts = List.map text drawn
let nth i = List.nth texts i

let find_row name =
  match List.find_opt (fun row -> contains name row) texts with
  | Some row -> row
  | None -> failf "no row names %s in:\n%s" name (String.concat "\n" texts)

let index_of name =
  let rec go i = function
    | [] -> failf "no row names %s" name
    | row :: rest -> if contains name row then i else go (i + 1) rest
  in
  go 0 texts

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
  check int "exactly the rows asked for" rows (List.length drawn);
  List.iteri
    (fun i line -> check int (Printf.sprintf "row %d width" i) cols (width line))
    drawn

let test_header_states_fleet_and_feed () =
  check bool "names the pane" true (contains "Activity" (nth 0));
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
  let drawn = Pane.lines ~rows ~cols { fixture with Pane.selected = None } in
  let texts = List.map text drawn in
  check bool "sangsu acted last" true
    (List.exists (fun row -> contains "turn 5" row) texts)

let test_narrow_budget_folds_the_fleet () =
  let drawn = Pane.lines ~rows:4 ~cols fixture in
  let texts = List.map text drawn in
  check int "four rows" 4 (List.length drawn);
  check bool "header stays" true (contains "Activity" (List.nth texts 0));
  check bool "the fold counts what it hid" true
    (List.exists (fun row -> contains "2 more" row) texts)

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
        ; test_case "header states fleet and feed" `Quick test_header_states_fleet_and_feed
        ; test_case "fleet orders waiting, working, settled, quiet" `Quick
            test_fleet_orders_waiting_then_working_then_settled_then_quiet
        ; test_case "fleet rows read the state" `Quick test_fleet_rows_read_the_state
        ; test_case "focus block names the current turn" `Quick
            test_focus_block_names_the_current_turn
        ; test_case "focus falls back to who acted last" `Quick
            test_focus_falls_back_to_who_acted_last
        ; test_case "narrow budget folds the fleet" `Quick test_narrow_budget_folds_the_fleet
        ] )
    ; ( "text"
      , [ test_case "state text reads each case" `Quick test_state_text_reads_each_case
        ; test_case "tokens and ages are compact" `Quick test_tokens_and_ages_are_compact
        ] )
    ]
