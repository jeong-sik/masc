open Alcotest
module Cat = Masc.Keeper_memory_os_types
module Types = Masc_tui_types
module Decode = Masc.Tui_decode
module Layout = Masc_tui_message_layout
module Render_memory = Masc_tui_render_memory

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
;;

(* The browser open on the snapshot's keeper, with its facts answered the way
   the answer handler settles them. *)
let answer_memory_facts (state : Types.state) (snapshot : Masc.Tui_decode_memory_facts.memory_fact_snapshot) =
  let keeper = snapshot.Masc.Tui_decode_memory_facts.mfs_keeper in
  state.Types.memory_facts_keeper <- Some keeper;
  match Masc_tui_fetched.start ~equal:String.equal state.Types.memory_facts ~key:keeper with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
  | Masc_tui_fetched.Started (next, request) ->
      state.Types.memory_facts <-
        Masc_tui_fetched.complete ~equal:String.equal next request (Ok (snapshot, None))
;;

(* A refresh of the open keeper's facts that failed: the facts stay, stale. *)
let fail_memory_facts_refresh (state : Types.state) detail =
  let keeper = Option.get state.Types.memory_facts_keeper in
  match Masc_tui_fetched.start ~equal:String.equal state.Types.memory_facts ~key:keeper with
  | Masc_tui_fetched.Already_loading -> Alcotest.fail "fixture already loading"
  | Masc_tui_fetched.Started (next, request) ->
      state.Types.memory_facts <-
        Masc_tui_fetched.complete ~equal:String.equal next request (Error detail)
;;

let contains needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  go 0
;;

let multi_line_claim =
  "The chat pane keeps the model's reply verbatim.\n\n**Why**:\n1. first reason\n\
   2. second reason\x07 rings"

(* The claim's rows are those before the first labeled provenance field;
   detail wraps both prose and provenance to the frame width. *)
let claim_rows lines =
  let plain = List.map Masc_tui_theme.strip_sgr lines in
  let is_field line =
    List.exists (fun label -> contains label line) [ "Category:"; "Bound Path:" ]
  in
  let rec take = function
    | [] -> []
    | line :: rest -> if is_field line then [] else line :: take rest
  in
  match plain with [] -> [] | _heading :: body -> take body

let check_claim_rows ~what lines =
  let raw_rows = claim_rows lines in
  let rows = List.map String.trim raw_rows in
  check bool (what ^ ": the claim has rows") true (rows <> []);
  check bool (what ^ ": no newline is printed as \\x0A") false
    (List.exists (contains "\\x0A") rows);
  check bool (what ^ ": each line of the claim is its own row") true
    (List.mem "**Why**:" rows && List.mem "1. first reason" rows);
  check bool (what ^ ": the paragraph break stays a blank row") true
    (List.mem "" rows);
  check bool (what ^ ": other control bytes are still escaped") true
    (List.exists (contains "\\x07") rows);
  List.iter
    (fun line ->
      check bool (what ^ ": claim row bounded at 40 cells") true
        (Layout.display_width line <= 40))
    raw_rows;
  List.iter
    (fun word ->
      check bool (what ^ ": " ^ word ^ " is not cut at the edge") true
        (List.exists (contains word) rows))
    [ "verbatim."; "reply"; "second" ]

let test_detail_keeps_the_claim_line_breaks () =
  let fact : Masc.Tui_decode_memory_facts.memory_fact =
    { mf_claim = multi_line_claim
    ; mf_category = Cat.Constraint
    ; mf_origin = "manual"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-lines-1"
    ; mf_events = Masc.Tui_decode_memory_facts.no_memory_fact_events
    }
  in
  check_claim_rows ~what:"fact"
    (Render_memory.memory_fact_detail_lines ~cols:40 (Types.Memory_row_fact fact));
  let sfact : Masc.Tui_decode_memory_facts.memory_source_fact =
    { msf_claim = multi_line_claim
    ; msf_first_seen = 100.0
    ; msf_path = "config/runtime.toml"
    ; msf_sha256 = "abc123sha"
    }
  in
  check_claim_rows ~what:"source-bound fact"
    (Render_memory.memory_fact_detail_lines ~cols:40
       (Types.Memory_row_source_fact sfact))
;;

let make_keeper_health ~keeper_id ~facts ~snapshot_bytes : Masc.Tui_decode_memory_health.memory_keeper_health =
  { mkh_keeper_id = keeper_id
  ; mkh_revision = 1
  ; mkh_updated_at = Some 1700000000.
  ; mkh_facts = facts
  ; mkh_observed_facts = facts
  ; mkh_derived_facts = 0
  ; mkh_support_invalidations = 0
  ; mkh_snapshot_bytes = snapshot_bytes
  ; mkh_added = facts
  ; mkh_removed = 0
  ; mkh_snapshot_present = true
  ; mkh_context_cycle =
      { mcc_saved = None; mcc_saved_unreadable = false; mcc_read_position = None;
        mcc_read_position_unreadable = false; mcc_rewriting_through = None;
        mcc_prepared = None; mcc_synthesis = None }
  ; mkh_librarian =
      { Masc.Tui_decode_memory_health.mlh_state = Some Masc.Tui_decode_memory_health.Pass_drained
      ; mlh_measured_at = Some 1_775_000_000.0
      ; mlh_unread_atom_turns = Some 0
      ; mlh_unread_official_turns = Some 0
      ; mlh_continuity_unread_atoms = Some 0
      ; mlh_last_success_at = None
      ; mlh_last_failure_kind = None
      ; mlh_stalled = None
      }
  ; mkh_librarian_failures = 0
  ; mkh_vision_ingest_errors = 0
  ; mkh_vision_ingest_error_reasons = []
  ; mkh_read_error = None
  ; mkh_source_revision = 0
  ; mkh_source_facts = 0
  ; mkh_source_invalidations = 0
  ; mkh_source_snapshot_bytes = 0
  ; mkh_source_snapshot_present = false
  ; mkh_source_read_error = None
  ; mkh_alerts = []
  }
;;

let make_fleet_health keeper : Masc.Tui_decode_memory_health.memory_health_snapshot =
  { mhs_generated_at = 1000.0
  ; mhs_keepers = [ keeper ]
  ; mhs_refused_keepers = []
  ; mhs_total_facts = 10
  ; mhs_total_observed_facts = 10
  ; mhs_total_derived_facts = 0
  ; mhs_total_support_invalidations = 0
  ; mhs_total_snapshot_bytes = 1024
  ; mhs_total_source_facts = 0
  ; mhs_total_source_invalidations = 0
  ; mhs_total_source_snapshot_bytes = 0
  ; mhs_total_librarian_failures = 0
  ; mhs_total_librarian_unread_turns = Some 0
  ; mhs_total_librarian_continuity_unread_atoms = 0
  ; mhs_total_librarian_continuity_unmeasured = 0
  ; mhs_total_vision_ingest_errors = 0
  ; mhs_total_read_errors = 0
  ; mhs_total_source_read_errors = 0
  ; mhs_warn_alerts = 0
  ; mhs_error_alerts = 0
  ; mhs_starving_keepers = 0
  }

let rows_drawn ~cols ~budget state =
  let count = ref 0 in
  Render_memory.render_memory_body ~cols ~budget state
    ~push:(fun _ -> incr count)
    ~push_styled:(fun ~style:_ _ -> incr count)
    ~push_selected:(fun _ -> incr count)
    ~push_divider:(fun () -> incr count)
    ~push_empty:(fun () -> incr count);
  !count

let body_lines ~cols ~budget state =
  let lines = ref [] in
  let keep line = lines := Masc_tui_theme.strip_sgr line :: !lines in
  Render_memory.render_memory_body ~cols ~budget state
    ~push:keep
    ~push_styled:(fun ~style:_ line -> keep line)
    ~push_selected:keep
    ~push_divider:(fun () -> keep "")
    ~push_empty:(fun () -> keep "");
  List.rev !lines

let fleet_health : Masc.Tui_decode_memory_health.memory_health_snapshot =
  let with_lag (keeper : Masc.Tui_decode_memory_health.memory_keeper_health) lag =
    { keeper with
      mkh_librarian = { keeper.mkh_librarian with Masc.Tui_decode_memory_health.mlh_continuity_unread_atoms = lag } }
  in
  let unmeasured = with_lag (make_keeper_health ~keeper_id:"alpha" ~facts:10 ~snapshot_bytes:1024) None in
  let behind = with_lag (make_keeper_health ~keeper_id:"beta" ~facts:4 ~snapshot_bytes:512) (Some 3) in
  let health : Masc.Tui_decode_memory_health.memory_health_snapshot =
    { mhs_generated_at = 1000.0
    ; mhs_keepers = [ unmeasured; behind ]
    ; mhs_refused_keepers = []
    ; mhs_total_facts = 14
    ; mhs_total_observed_facts = 14
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 1536
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_librarian_unread_turns = Some 0
    ; mhs_total_librarian_continuity_unread_atoms = 3
    ; mhs_total_librarian_continuity_unmeasured = 1
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 0
    ; mhs_warn_alerts = 0
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    }
  in
  health

let test_the_librarian_line_names_a_stalled_gap () =
  let with_beta stalled =
    { fleet_health with
      Masc.Tui_decode_memory_health.mhs_keepers =
        List.map
          (fun (keeper : Masc.Tui_decode_memory_health.memory_keeper_health) ->
             if String.equal keeper.mkh_keeper_id "beta"
             then
               { keeper with
                 mkh_librarian = { keeper.mkh_librarian with Masc.Tui_decode_memory_health.mlh_stalled = Some stalled } }
             else keeper)
          fleet_health.mhs_keepers }
  in
  let render ?(stalled = Masc.Tui_decode_memory_health.Stalled_gap { mls_gap_start_atom = 2; mls_gap_end_atom = 8 })
      cursor =
    let state = make_state () in
    state.memory_health <- Some (with_beta stalled);
    state.memory_health_cursor <- cursor;
    let lines = ref [] in
    Render_memory.render_memory_body ~cols:100 ~budget:20 state
      ~push:(fun line -> lines := line :: !lines)
      ~push_styled:(fun ~style:_ line -> lines := line :: !lines)
      ~push_selected:(fun line -> lines := line :: !lines)
      ~push_divider:(fun () -> ())
      ~push_empty:(fun () -> ());
    String.concat "\n" (List.rev !lines)
  in
  let row = "Librarian stalled · atoms 2-7 are in neither the request nor memory" in
  check bool "the stalled keeper names the atoms its requests skip" true
    (contains row (render 1));
  check bool "a keeper with no gap prints none" false (contains "Librarian stalled" (render 0));
  (* The row is its own line, and at the 100 columns the PTY harness opens it
     fits whole: the frame cuts long lines, and a cut atom number is a wrong
     one. *)
  check bool "the row fits the frame at 100 columns" true
    (List.exists
       (fun line -> contains row line && String.length line <= 96)
       (String.split_on_char '\n' (render 1)));
  check bool "a gap of one atom names that atom, not a range" true
    (contains "Librarian stalled · atom 5 is in neither the request nor memory"
       (render ~stalled:(Masc.Tui_decode_memory_health.Stalled_gap { mls_gap_start_atom = 5; mls_gap_end_atom = 6 }) 1));
  (* A file the gap is read from that did not read is drawn, and drawn as
     not measured: a silent row would read as no gap. *)
  let unmeasured =
    render
      ~stalled:
        (Masc.Tui_decode_memory_health.Stalled_unmeasured
           { mls_cause = Masc.Tui_decode_memory_health.Stall_read_position_unreadable; mls_detail = "bad \027[31mjson" })
      1
  in
  check bool "an unreadable read position is drawn as not measured" true
    (contains "Librarian stalled · not measured, read position unreadable" unmeasured);
  check bool "the reader's message is escaped" false (contains "\027[31m" unmeasured)
;;

let facts_body_lines ?(cols = 100) ?(budget = 30) state =
  let lines = ref [] in
  let keep line = lines := Masc_tui_theme.strip_sgr line :: !lines in
  Render_memory.render_memory_facts_body ~cols ~budget state
    ~push:keep
    ~push_styled:(fun ~style:_ line -> keep line)
    ~push_selected:keep
    ~push_divider:(fun () -> ())
    ~push_empty:(fun () -> ());
  List.rev !lines

let make_memory_fact category claim : Masc.Tui_decode_memory_facts.memory_fact =
  { mf_claim = claim
  ; mf_category = category
  ; mf_origin = "manual"
  ; mf_first_seen = 100.0
  ; mf_last_seen = 200.0
  ; mf_memory_id = "mem-" ^ claim
  ; mf_events = Masc.Tui_decode_memory_facts.no_memory_fact_events
  }

let three_kinds_state ?(keeper = "alpha") ?(extra_ordinary = []) () =
  let state = make_state () in
  let fact = make_memory_fact in
  let ordinary : Masc.Tui_decode_memory_facts.memory_ordinary_store =
    { mos_revision = 1
    ; mos_updated_at = 1000.0
    ; mos_facts =
        [ fact Cat.Fact "The renderer draws the board"
        ; fact Cat.Preference "Roger reads for the tester"
        ] @ extra_ordinary
    }
  in
  let source : Masc.Tui_decode_memory_facts.memory_source_store =
    { mss_revision = 1
    ; mss_updated_at = 1000.0
    ; mss_facts =
        [ { msf_claim = "Config points at runtime.toml"
          ; msf_first_seen = 150.0
          ; msf_path = "config/rt.toml"
          ; msf_sha256 = "abc123sha"
          }
        ]
    ; mss_invalidations =
        [ { mi_source_path = "legacy_docs.md"
          ; mi_invalidated_at = 300.0
          ; mi_reason = "superseded"
          }
        ]
    }
  in
  answer_memory_facts state
       { mfs_keeper = keeper
       ; mfs_ordinary = Masc.Tui_decode_memory_facts.Memory_store_present ordinary
       ; mfs_source = Masc.Tui_decode_memory_facts.Memory_store_present source
       ; mfs_events_read_error = None
       };
  state.memory_facts_cursor <- 0;
  state

let test_category_rail_keeps_click_targets_and_frame_width () =
  let state = three_kinds_state () in
  check int "default gives the facts all available width" 140
    (Render_memory.memory_facts_pane_cols state 140);
  state.memory_facts_categories_open <- true;
  state.memory_facts_category <- Types.Category_ordinary Cat.Preference;
  let render cols =
    Masc_tui_hit.reset Masc_tui_press.press_marks;
    let lines = ref [] in
    let push line = lines := line :: !lines in
    Render_memory.render_memory_facts_body ~cols ~budget:24 state ~push
      ~push_styled:(fun ~style line -> push (style ^ line))
      ~push_selected:push ~push_divider:(fun () -> push "") ~push_empty:(fun () -> push "");
    Masc_tui_hit.extract Masc_tui_press.press_marks (List.rev !lines)
  in
  let wide, zones = render 140 in
  check bool "Category rail visible" true
    (List.exists (contains "CATEGORIES") wide);
  check bool "Category counts visible" true
    (List.exists (contains "preference (1)") wide);
  check bool "frame width preserved" true
    (List.for_all (fun line -> Layout.display_width line <= 140) wide);
  check bool "selected Category has clickable rail target" true
    (List.exists (fun (_, first, _, target) ->
      first <= Masc_tui_roster_pane.pane_cols &&
      target = Masc_tui_press.Press_memory_category (Types.Category_ordinary Cat.Preference))
      (Masc_tui_hit.to_list zones));
  List.iter (fun initially_open ->
    state.memory_facts_categories_open <- initially_open;
    let narrow, _ = render (Masc_tui_roster_pane.threshold_cols - 1) in
    check bool "hidden Category rail offers no toggle" false
      (List.exists (contains "d:") narrow);
    let wide, _ = render Masc_tui_roster_pane.threshold_cols in
    check bool "drawable Category rail offers its actual action" true
      (List.exists (contains (if initially_open then "d:접기" else "d:Category 펼치기")) wide)
  ) [false; true];
  let narrow, _ = render 80 in
  check bool "narrow frame keeps full fact width" false
    (List.exists (contains "CATEGORIES") narrow);
  state.memory_facts_categories_open <- false;
  let closed, _ = render 140 in
  check bool "closing Categories restores the fact reading" false
    (List.exists (contains "CATEGORIES") closed)

let test_category_rail_bounds_large_label_preview () =
  let name = "oversized_" ^ String.make 50_000 'a' in
  let category = Option.get (Cat.category_of_string name) in
  let filter = Types.Category_ordinary category in
  let state = three_kinds_state ~extra_ordinary:[make_memory_fact category "bounded preview"] () in
  state.memory_facts_categories_open <- true;
  state.memory_facts_category <- filter;
  Masc_tui_hit.reset Masc_tui_press.press_marks;
  let lines = ref [] in
  let push line = lines := line :: !lines in
  Render_memory.render_memory_facts_body ~cols:140 ~budget:7 state ~push
    ~push_styled:(fun ~style line -> push (style ^ line)) ~push_selected:push
    ~push_divider:(fun () -> push "") ~push_empty:(fun () -> push "");
  let lines, _ = Masc_tui_hit.extract Masc_tui_press.press_marks (List.rev !lines) in
  let rail = List.map (fun line -> Layout.take_cells (Masc_tui_theme.strip_sgr line)
    Masc_tui_roster_pane.pane_cols) lines in
  check bool "bounded preview exposes truncation and count in the visible rail" true
    (List.exists (contains "… (1)") rail);
  check bool "rendered rows fit the same terminal width" true
    (List.for_all (fun line -> Layout.display_width line <= 140) lines);
  check string "the category retained for detail is complete" name
    (Types.memory_category_filter_label state.memory_facts_category)

let test_category_rail_wrapped_range_and_overflow () =
  let long_cat_name = "custom_architecture_infrastructure_deployment_pipeline_specification" in
  let long_cat = Option.get (Cat.category_of_string long_cat_name) in
  let cat_filter = Types.Category_ordinary long_cat in
  let state =
    three_kinds_state
      ~extra_ordinary:[ make_memory_fact long_cat "Long category test claim" ]
      ()
  in
  state.memory_facts_category <- cat_filter;
  state.memory_facts_categories_open <- true;
  let render ~budget cols =
    Masc_tui_hit.reset Masc_tui_press.press_marks;
    let lines = ref [] in
    let push line = lines := line :: !lines in
    Render_memory.render_memory_facts_body ~cols ~budget state ~push
      ~push_styled:(fun ~style line -> push (style ^ line))
      ~push_selected:push ~push_divider:(fun () -> push "") ~push_empty:(fun () -> push "");
    Masc_tui_hit.extract Masc_tui_press.press_marks (List.rev !lines)
  in
  let lines_fit, zones_fit = render ~budget:7 140 in
  check bool "selected category start row visible when fitting in budget" true
    (List.exists (contains "custom_architecture_infrastructu") lines_fit);
  check bool "selected category end row with count visible when fitting in budget" true
    (List.exists (contains "tion (1)") lines_fit);
  check bool "clickable target exists when fitting" true
    (List.exists (fun (_, first, _, target) ->
      first <= Masc_tui_roster_pane.pane_cols &&
      target = Masc_tui_press.Press_memory_category cat_filter)
      (Masc_tui_hit.to_list zones_fit));
  let lines_small, zones_small = render ~budget:5 140 in
  check bool "selected category start anchored and visible under height overflow" true
    (List.exists (contains "custom_architecture_infrastructu") lines_small);
  check bool "clickable target exists on overflow" true
    (List.exists (fun (_, first, _, target) ->
      first <= Masc_tui_roster_pane.pane_cols &&
      target = Masc_tui_press.Press_memory_category cat_filter)
      (Masc_tui_hit.to_list zones_small));
  state.view <- Types.Memory;
  check bool "keeper is selected for detail access" true
    (Option.is_some state.memory_facts_keeper);
  state.memory_fact_detail_open <- true;
  state.memory_fact_detail_scroll <- 0;
  let rows = Types.memory_fact_rows state in
  check int "category filter isolates long category fact" 1 (List.length rows);
  let fact_row = List.hd rows in
  let compact text = String.split_on_char ' ' text |> String.concat "" in
  List.iter
    (fun cols ->
      let lines = Render_memory.memory_fact_detail_lines ~cols fact_row in
      let body = match lines with [] -> [] | _heading :: body -> body in
      List.iter
        (fun line ->
          check bool "detail body fits inner frame width" true
            (Layout.display_width line <= Masc_tui_frame.inner_width ~cols))
        body;
      let text =
        body |> List.map Masc_tui_theme.strip_sgr |> String.concat "" |> compact
      in
      check bool "wrapped detail lines preserve full category label" true
        (contains (compact long_cat_name) text))
    [ 80; 40; 30; 16 ];
  let detail_cols = 40 in
  let detail_lines = Render_memory.memory_fact_detail_lines ~cols:detail_cols fact_row in
  let count = List.length detail_lines in
  let small_height = 4 in
  check bool "detail lines overflow small viewport" true (count > small_height);
  let indexed = List.mapi (fun i line -> i, Masc_tui_theme.strip_sgr line) detail_lines in
  let first_cat_idx = indexed |> List.find (fun (_, line) -> contains "Category:" line) |> fst in
  let next_field_idx = indexed |> List.find (fun (i, line) -> i > first_cat_idx && contains "Origin:" line) |> fst in
  let last_cat_idx = next_field_idx - 1 in
  let initial_scroll = state.memory_fact_detail_scroll in
  check int "initial detail scroll starts at top" 0 initial_scroll;
  let scrolled =
    Masc_tui_scroll.ensure_visible ~cursor:last_cat_idx ~height:small_height
      initial_scroll
  in
  state.memory_fact_detail_scroll <- scrolled;
  check bool "scrolled window reaches final category line" true
    (scrolled <= last_cat_idx && last_cat_idx < scrolled + small_height);
  check bool "scroll position indicator reports window" true
    (Option.is_some
       (Masc_tui_scroll.position_row ~scroll:scrolled ~height:small_height count));
  let end_scroll = Masc_tui_scroll.normalize ~count ~height:small_height max_int in
  check bool "normalizing the final viewport reaches bottom of detail" true
    (end_scroll = Masc_tui_scroll.maximum ~count ~height:small_height)

let stats_row lines =
  match List.filter (contains "Sort [s]:") lines with
  | [ row ] -> row
  | [] -> fail "no row on the facts body names the sort"
  | _ :: _ -> fail "the sort is named on more than one row"

let test_memory_search_uses_the_filter_text_and_query () =
  let state = three_kinds_state () in
  state.view <- Types.Memory;
  state.memory_facts_keeper <- Some "alpha";
  let snapshot = Option.get (Types.memory_facts_snapshot state) in
  let ordinary = match snapshot.mfs_ordinary with
    | Masc.Tui_decode_memory_facts.Memory_store_present store -> store
    | _ -> fail "fixture ordinary store missing" in
  let original = List.hd ordinary.mos_facts in
  let fact = { original with mf_claim = "deploy"; mf_category = Cat.Fact;
                            mf_origin = "authored" } in
  answer_memory_facts state { snapshot with mfs_ordinary =
    Masc.Tui_decode_memory_facts.Memory_store_present { ordinary with mos_facts = [fact] } };
  let verify ~typing query expected =
    state.search <- if typing then Some query else None;
    state.search_last <- if typing then "unrelated committed query" else query;
    let rows = Types.memory_fact_rows state in
    check int "filter row count" expected (List.length rows);
    check (option int) "marker agrees with filter" (Some expected)
      (Masc_tui_surface_search.surface_search_count state Types.Memory ~query);
    let texts = Option.get (Masc_tui_surface_search.surface_row_texts state Types.Memory) in
    let effective = Types.surface_search_query Types.Memory query in
    check int "cursor matcher reaches every filtered row" expected
      (List.length (List.filter (Masc_tui_pick_list.lowercase_contains ~needle:effective) texts))
  in
  List.iter (fun typing ->
    List.iter (fun query -> verify ~typing query 1)
      (* The category is part of a fact's search text, and it is the
         taxonomy's word now: this read "deploy note" while the fixture's
         category was the invented "note". *)
      ["deploy fact"; "  deploy fact  "; "authored";
       "runtime.toml config/rt.toml"; "superseded legacy_docs.md"];
    verify ~typing "not-present" 0) [true; false];
  state.search <- Some "   ";
  check int "blank Memory query still shows all rows" 3
    (List.length (Types.memory_fact_rows state));
  check (option int) "blank query has no matches to jump" (Some 0)
    (Masc_tui_surface_search.surface_search_count state Types.Memory ~query:"   ");
  check string "other surfaces retain literal whitespace" "  deploy fact  "
    (Types.surface_search_query Types.Board "  deploy fact  ")
;;

let test_the_breakdown_counts_the_rows_the_screen_lists () =
  (* A filter narrows the rows; the title then says how many are left. A
     breakdown taken from the store would sum to four under a title saying
     one. *)
  let state = three_kinds_state () in
  state.search_last <- "Roger";
  let lines = facts_body_lines state in
  check string "one ordinary fact matched, and nothing else"
    "  (1 ord \xc2\xb7 0 src \xc2\xb7 0 drop) \xc2\xb7 Sort [s]: Recency (Newest)"
    (stats_row lines);
  check int "which is the number the title counts" 1
    (List.length (Types.memory_fact_rows state))

let test_render_memory_body_sorting () =
  let state = make_state () in
  let k1 = make_keeper_health ~keeper_id:"alpha" ~facts:10 ~snapshot_bytes:2048 in
  let k2 = make_keeper_health ~keeper_id:"beta" ~facts:50 ~snapshot_bytes:1024 in
  let health : Masc.Tui_decode_memory_health.memory_health_snapshot =
    { mhs_generated_at = 1000.0
    ; mhs_keepers = [ k1; k2 ]
    ; mhs_refused_keepers = []
    ; mhs_total_facts = 60
    ; mhs_total_observed_facts = 60
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 3072
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_librarian_unread_turns = Some 0
    ; mhs_total_librarian_continuity_unread_atoms = 0
    ; mhs_total_librarian_continuity_unmeasured = 0
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 0
    ; mhs_warn_alerts = 0
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    }
  in
  state.memory_health <- Some health;
  state.memory_overview_sort <- Types.Mem_overview_facts;
  let lines = ref [] in
  Render_memory.render_memory_body
    ~cols:100
    ~budget:20
    state
    ~push:(fun s -> lines := s :: !lines)
    ~push_styled:(fun ~style:_ s -> lines := s :: !lines)
    ~push_selected:(fun s -> lines := s :: !lines)
    ~push_divider:(fun () -> ())
    ~push_empty:(fun () -> ());
  check bool "render completed" true (List.length !lines > 0);
  let selected () = Option.map (fun k -> k.Masc.Tui_decode_memory_health.mkh_keeper_id) (Types.selected_memory_keeper state) in
  check (option string) "Enter opens the first visible fact-sorted row" (Some "beta") (selected ());
  check bool "total facts are readable" true (List.exists (contains "Total 60 facts") !lines);
  check bool "ready state has a mark" true (List.exists (contains "+") !lines);
  state.memory_overview_sort <- Types.Mem_overview_size;
  check (option string) "size order and Enter agree" (Some "alpha") (selected ());
  state.search_last <- "beta";
  state.memory_health_cursor <- 99;
  check (option string) "filter clamps Enter to the shown row" (Some "beta") (selected ());
  state.search_last <- "";
  state.memory_health_cursor <- 0;
  state.memory_health <- Some { health with mhs_keepers =
      [{ k1 with mkh_updated_at = None }; { k2 with mkh_updated_at = Some 1700000000. }] };
  state.memory_overview_sort <- Types.Mem_overview_updated;
  check (option string) "known dates sort before absent snapshots" (Some "beta") (selected ())
;;

let test_render_memory_overflow_selection () =
  let state = make_state () in
  state.memory_overview_detail <- true;  (* pins the [d] detail rows (#39831) *)
  state.view <- Types.Memory;
  let keepers = List.init 5 (fun index ->
      let keeper =
        make_keeper_health ~keeper_id:(Printf.sprintf "keeper-%d" index)
          ~facts:10 ~snapshot_bytes:1024
      in
      if index <> 4 then keeper
      else
        { keeper with
          mkh_source_read_error = Some "unreadable source snapshot"
        ; mkh_alerts =
            [{ ma_code = Masc.Tui_decode_memory_health.Source_snapshot_read_error
             ; ma_label = "source"
             ; ma_message = "unreadable source snapshot"
             }]
        })
  in
  state.memory_health <- Some
    { mhs_generated_at = 1700000000.
    ; mhs_keepers = keepers
    ; mhs_refused_keepers = []
    ; mhs_total_facts = 50
    ; mhs_total_observed_facts = 50
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 5120
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_librarian_unread_turns = Some 0
    ; mhs_total_librarian_continuity_unread_atoms = 0
    ; mhs_total_librarian_continuity_unmeasured = 0
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 1
    ; mhs_warn_alerts = 1
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    };
  (* The fleet header is as many rows as the frame wraps it to, and the list
     gets what is left; pin the rows the header takes at 100 columns so the
     list heights below stay the case this test is about. *)
  let rows =
    22 + List.length (Render_memory.memory_fleet_header_rows ~cols:100 state)
  in
  let budget = rows - Masc_tui_frame.chrome_rows in
  let height layout =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.Types.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  (* One of the two list rows went to the context block when the Librarian
     row started breaking at its clause mark rather than losing "failed N
     since server start" to the frame. The block is paid for out of the same
     rows as the list, and this fixture's frame is 22 rows: a terminal tall
     enough to show the roster spends the row against many more. *)
  check int "five keepers fit one list row beside their context" 1
    (height (Render_memory.memory_overview_scrolled ~cols:100 ~budget state));
  let assert_selected_visible () =
    let used = ref 0 and selected = ref None in
    let push _ = incr used in
    Render_memory.render_memory_body ~cols:100 ~budget state
      ~push ~push_styled:(fun ~style:_ line -> push line)
      ~push_selected:(fun line ->
        if !used < budget then selected := Some line;
        incr used)
      ~push_divider:(fun () -> push "") ~push_empty:(fun () -> push "");
    let expected = Option.get (Types.selected_memory_keeper state) in
    check bool "the selected keeper is inside the visible body" true
      (Option.fold ~none:false ~some:(contains expected.mkh_keeper_id) !selected);
    check bool "header, roster, overflow and detail fit their shared budget" true
      (rows_drawn ~cols:100 ~budget state <= budget)
  in
  (* Move through an overflowing list using the same target-row layout as
     keyboard input, including the context of the newly selected keeper. *)
  for cursor = 0 to 4 do
    let layout = Render_memory.memory_overview_scrolled ~cols:100 ~budget ~cursor state in
    state.memory_health_cursor <- cursor;
    state.memory_health_scroll <-
      Masc_tui_scroll.ensure_visible ~cursor ~height:(height layout)
        state.memory_health_scroll;
    assert_selected_visible ()
  done;
  check int "the final row's error and alert leave one list row" 1
    (height (Render_memory.memory_overview_scrolled ~cols:100 ~budget state));
  check int "the final row requires scrolling" 4 state.memory_health_scroll;
  state.search_last <- "keeper-4";
  state.memory_health_error <- Some "refresh failed";
  let layout = Render_memory.memory_overview_scrolled ~cols:100 ~budget state in
  check int "filter bounds the cursor to the one visible keeper" 1 layout.sc_count;
  check (option (list string)) "search names the same filtered row"
    (Some ["keeper-4 read-error"]) (Masc_tui_surface_search.surface_row_texts state Types.Memory);
  (* A refresh/filter can change the body before another keypress. *)
  assert_selected_visible ()
;;

let test_a_failed_facts_refresh_keeps_the_facts () =
  let state = three_kinds_state () in
  state.view <- Types.Memory;
  fail_memory_facts_refresh state "facts load failed: HTTP 503";
  check int "the facts stay listed" 4 (List.length (Types.memory_fact_rows state));
  let lines = facts_body_lines state in
  ignore (stats_row lines);
  check bool "the failure marks them stale" true
    (List.exists (contains "HTTP 503") lines)
;;

let test_memory_row_visibility () =
  let shown kind =
    match Render_memory.memory_row_visibility kind with
    | Render_memory.Shown_by_default -> true
    | Render_memory.Detail_only -> false
  in
  List.iter
    (fun (label, kind, expected) -> check bool label expected (shown kind))
    [ "an unread lag is shown, not folded to zero", Render_memory.Row_lag None, true
    ; "a lag of 3 is shown", Render_memory.Row_lag (Some 3), true
    ; "a lag of 0 waits for detail", Render_memory.Row_lag (Some 0), false
    ; "3 Librarian failures are shown", Render_memory.Row_librarian_failures 3, true
    ; "0 Librarian failures wait for detail", Render_memory.Row_librarian_failures 0, false
    ]
;;

let test_memory_state_tracks_current_pass_not_history () =
  let module H = Masc.Tui_decode_memory_health in
  let base = make_keeper_health ~keeper_id:"recovered" ~facts:10 ~snapshot_bytes:262144 in
  let recovered = { base with H.mkh_librarian_failures = 3 } in
  check bool "history does not keep a recovered snapshot degraded" true
    (Types.memory_state recovered = Types.Memory_ordinary);
  let stopped = { base with H.mkh_librarian =
      { base.mkh_librarian with H.mlh_state = Some (H.Pass_stopped "model unavailable") } } in
  check bool "current error is visible before a counter update" true
    (Types.memory_state stopped = Types.Memory_degraded);
  check bool "empty current failure is starving" true
    (Types.memory_state { stopped with H.mkh_snapshot_present = false } = Types.Memory_starving);
  check bool "empty recovered memory is not starving from historical failures" true
    (Types.memory_state { recovered with H.mkh_snapshot_present = false } = Types.Memory_no_current);
  check bool "store read error overrides a recovered pass" true
    (Types.memory_state { recovered with H.mkh_read_error = Some "EACCES" } = Types.Memory_read_error);
  let empty_recovered = { recovered with H.mkh_snapshot_present = false } in
  let source_only = { empty_recovered with H.mkh_source_snapshot_present = true } in
  let stopped_empty = { stopped with H.mkh_snapshot_present = false } in
  List.iter (fun (keeper, expected) ->
    check (option int) "fleet count follows current row state" (Some expected)
      (Types.current_memory_starving_count (make_fleet_health keeper)))
    [empty_recovered, 0; source_only, 0; stopped_empty, 1];
  check bool "failure-history alert does not color current memory as an error" true
    (H.memory_alert_is_history H.Librarian_starvation
     && H.memory_alert_is_history H.Librarian_failures);
  check bool "current store read errors retain error semantics" false
    (H.memory_alert_is_history H.Snapshot_read_error);
  let refused = { (make_fleet_health recovered) with H.mhs_refused_keepers =
      [{ H.mkr_keeper_id = Some "unread"; mkr_reason = "invalid payload" }] } in
  check (option int) "refused rows keep fleet count unknown" None
    (Types.current_memory_starving_count refused);
  let history_keeper = { recovered with H.mkh_alerts =
      [{ H.ma_code = H.Librarian_failures; ma_label = "Librarian failures";
         ma_message = "3 failures since server start" }] } in
  let state = make_state () in
  state.memory_health <- Some (make_fleet_health history_keeper);
  check bool "historical alert retains severity with an explicit history label" true
    (contains "[history warn]" (String.concat "\n" (body_lines ~cols:140 ~budget:40 state)));
  check string "storage uses observed byte units" "256.0 KiB" (Render_memory.storage_size 262144)
;;

let test_memory_refresh_keeps_the_selected_keeper () =
  let module H = Masc.Tui_decode_memory_health in
  let keeper name facts =
    make_keeper_health ~keeper_id:name ~facts ~snapshot_bytes:1024
  in
  let alpha = keeper "alpha" 20 in
  let health keepers = { (make_fleet_health alpha) with H.mhs_keepers = keepers } in
  List.iter (fun query ->
    let state = make_state () in
    state.memory_overview_sort <- Types.Mem_overview_facts;
    state.search_last <- query;
    Types.apply_memory_health_snapshot state
      (health [alpha; keeper "beta" 10; keeper "gamma" 5; keeper "hidden" 0]);
    let selected_id () =
      Option.map (fun row -> row.H.mkh_keeper_id) (Types.selected_memory_keeper state)
    in
    check (option string) "start on alpha" (Some "alpha") (selected_id ());
    let usage : Masc_tui_memory_usage.t =
      { records = 1
      ; tokens =
          { distribution = Some { samples = 1; mean = 100.; minimum = 100; maximum = 100 }
          ; last = Some 100 }
      ; bytes = { distribution = None; last = None }
      }
    in
    let request =
      match Masc_tui_fetched.start ~equal:String.equal state.memory_input ~key:"alpha" with
      | Already_loading -> fail "fresh fixture was loading"
      | Started (next, request) -> state.memory_input <- next; request
    in
    Types.apply_memory_health_snapshot state
      (health [alpha; keeper "beta" 30; keeper "gamma" 25; keeper "hidden" 100]);
    check (option string) "ranking changes keep the selected Keeper" (Some "alpha")
      (selected_id ());
    state.memory_input <-
      Masc_tui_fetched.complete ~equal:String.equal state.memory_input request (Ok usage);
    check bool "the pending input still belongs to the selected Keeper" true
      (Masc_tui_fetched.view_for ~equal:String.equal state.memory_input
         ~key:(Option.get (selected_id ())) = Ready usage);
    Types.apply_memory_health_snapshot state
      (health [keeper "beta" 30; keeper "gamma" 25; keeper "hidden" 100]);
    check (option string) "removal clamps to the last visible Keeper" (Some "gamma")
      (selected_id ());
    check int "removed selection leaves an in-range cursor"
      (List.length (Types.visible_memory_keepers state) - 1) state.memory_health_cursor;
    check bool "removed Keeper input cannot appear under the fallback selection" true
      (Masc_tui_fetched.view_for ~equal:String.equal state.memory_input ~key:"gamma" = Absent);
    Types.apply_memory_health_snapshot state (health []);
    check (option string) "empty refreshed roster has no selection" None (selected_id ());
    check int "empty refreshed roster resets the cursor" 0 state.memory_health_cursor)
    [""; "a"]
;;

let test_memory_input_summary_survives_units_and_detail_folding () =
  let module Usage = Masc_tui_memory_usage in
  let state = make_state () in
  state.memory_health <- Some (make_fleet_health
    (make_keeper_health ~keeper_id:"alpha" ~facts:10 ~snapshot_bytes:262144));
  let snapshot : Usage.t =
    { records = 4
    ; tokens = { distribution = Some { samples = 3; mean = 100.; minimum = 0; maximum = 300 }; last = None }
    ; bytes = { distribution = Some { samples = 2; mean = 1536.; minimum = 1024; maximum = 2048 }; last = Some 2048 }
    } in
  let answer result =
    match Masc_tui_fetched.start ~equal:String.equal state.memory_input ~key:"alpha" with
    | Already_loading -> fail "fixture was already loading"
    | Started (next, request) ->
      state.memory_input <- Masc_tui_fetched.complete ~equal:String.equal next request result in
  answer (Ok snapshot);
  check bool "token units by default" true (state.memory_unit = Usage.Tokens);
  List.iter (fun detail ->
    state.memory_overview_detail <- detail;
    List.iter (fun cols ->
      let text = String.concat "\n" (body_lines ~cols ~budget:20 state) in
      List.iter (fun needle -> check bool ("visible input " ^ needle) true (contains needle text))
        ["Input tok"; "avg 100"; "max 300"; "min 0"; "last unreported"; "3/4 recorded"])
      [80; 140]) [false; true];
  state.memory_unit <- Usage.next_unit state.memory_unit;
  let bytes = String.concat "\n" (body_lines ~cols:80 ~budget:20 state) in
  List.iter (fun needle -> check bool ("visible byte input " ^ needle) true (contains needle bytes))
    ["Request KiB"; "avg 1.5"; "max 2.0"; "min 1.0"; "last 2.0"; "2/4 recorded"];
  state.memory_unit <- Usage.next_unit state.memory_unit;
  answer (Error "read failed");
  let stale = String.concat "\n" (body_lines ~cols:80 ~budget:22 state) in
  check bool "failed refresh marks retained values stale" true (contains "stale" stale);
  check bool "failed refresh retains observed statistics" true (contains "avg 100" stale)
;;

let () =
  run "tui_render_memory"
    [ "input statistics",
      [ test_case "units and folded detail" `Quick test_memory_input_summary_survives_units_and_detail_folding
      ; test_case "refresh preserves Keeper selection" `Quick test_memory_refresh_keeps_the_selected_keeper
      ;]
    ; ( "age_label"
      , [] )
    ; ( "row_lines"
      , [] )
    ; ( "detail_lines"
      , [ test_case "the detail keeps the claim's line breaks" `Quick
            test_detail_keeps_the_claim_line_breaks
        ;] )
    ; ( "render_body"
      , [ test_case "memory recovery does not inherit historical failure state" `Quick
            test_memory_state_tracks_current_pass_not_history
        ; test_case "the row classifier keeps unread readings as actions" `Quick
            test_memory_row_visibility
        ; test_case "the librarian line names a stalled gap" `Quick
            test_the_librarian_line_names_a_stalled_gap
        ; test_case "memory_body_sorting" `Quick test_render_memory_body_sorting
        ; test_case "memory_overflow_selection" `Quick test_render_memory_overflow_selection
        ; test_case "Category rail keeps counts, click targets and frame width" `Quick
            test_category_rail_keeps_click_targets_and_frame_width
        ; test_case "Category rail wrapped range exposure and overflow" `Quick
            test_category_rail_wrapped_range_and_overflow
        ; test_case "category rail bounds oversized previews" `Quick
            test_category_rail_bounds_large_label_preview
        ; test_case "a failed facts refresh keeps the facts" `Quick
            test_a_failed_facts_refresh_keeps_the_facts
        ;] )
    ; ( "one place per fact"
      , [ test_case "search count and cursor share Memory filter text and query" `Quick
            test_memory_search_uses_the_filter_text_and_query
        ; test_case "the breakdown counts the rows the screen lists" `Quick
            test_the_breakdown_counts_the_rows_the_screen_lists
        ;] )
    ]
;;
