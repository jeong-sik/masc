open Alcotest
module Types = Masc_tui_types
module Decode = Masc.Tui_decode
module Layout = Masc_tui_message_layout
module Render_memory = Masc_tui_render_memory

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
;;

let contains needle haystack =
  let n = String.length needle
  and h = String.length haystack in
  let rec go i = i + n <= h && (String.equal (String.sub haystack i n) needle || go (i + 1)) in
  go 0
;;


(* Two things this had wrong, and CI could see neither: the check here is
   [dune build @check] and runs no tests.

   [memory_fact_age_label] takes the moment a fact was last seen, not its
   age -- its caller hands it [fact.mf_last_seen] -- so passing 10.0 asked
   what 1970 looks like. And "just now" / "5m ago" are not spellings this
   renderer produces; it answers the compact form the rest of the TUI uses
   for idle time. *)
let test_age_label () =
  let seconds_ago age = Unix.gettimeofday () -. age in
  check string "seconds" "10s" (Render_memory.memory_fact_age_label (seconds_ago 10.0));
  check string "minutes" "5m" (Render_memory.memory_fact_age_label (seconds_ago 300.0));
  check string "hours" "2h" (Render_memory.memory_fact_age_label (seconds_ago 7200.0));
  check string "days" "3d" (Render_memory.memory_fact_age_label (seconds_ago 259200.0))
;;

let test_fact_row_line () =
  let fact : Decode.memory_fact =
    { mf_claim = "System uses Roger voice for Tester"
    ; mf_category = "persona"
    ; mf_origin = "manual"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-1"
    ; mf_events = Decode.no_memory_fact_events
    }
  in
  let row = Types.Memory_row_fact fact in
  let line = Render_memory.memory_fact_row_line ~cols:80 row in
  check bool "fact row line bounded" true (Layout.display_width line <= 80);
  check bool "fact row line not empty" true (String.length line > 0)
;;

let test_source_fact_row_line () =
  let sfact : Decode.memory_source_fact =
    { msf_claim = "Config points to runtime.toml"
    ; msf_first_seen = 150.0
    ; msf_path = "config/runtime.toml"
    ; msf_sha256 = "abc123sha"
    }
  in
  let row = Types.Memory_row_source_fact sfact in
  let line = Render_memory.memory_fact_row_line ~cols:80 row in
  check bool "source fact row line bounded" true (Layout.display_width line <= 80)
;;

let test_invalidation_row_line () =
  let inv : Decode.memory_invalidation =
    { mi_source_path = "legacy_docs.md"
    ; mi_invalidated_at = 300.0
    ; mi_reason = "superseded by new spec"
    }
  in
  let row = Types.Memory_row_invalidation inv in
  let line = Render_memory.memory_fact_row_line ~cols:80 row in
  check bool "invalidation row line bounded" true (Layout.display_width line <= 80)
;;

(* RFC-0418: the detail names what the keeper did with the fact, straight
   from the record; nothing is scored. *)
let test_detail_names_the_use_record () =
  let fact : Decode.memory_fact =
    { mf_claim = "the deploy needs assets"
    ; mf_category = "lesson"
    ; mf_origin = "authored"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-1"
    ; mf_events =
        { mfe_retrieved_count = 4
        ; mfe_retrieved_distinct_days = 2
        ; mfe_last_retrieved_at = Some (Unix.gettimeofday () -. 7200.0)
        ; mfe_cited_count = 1
        ; mfe_revised_from = [ "mem-0" ]
        }
    }
  in
  let lines =
    Render_memory.memory_fact_detail_lines ~cols:120 (Types.Memory_row_fact fact)
    |> List.map Masc_tui_theme.strip_sgr
  in
  match List.find_opt (fun line -> contains "Use:" line) lines with
  | None -> fail "the detail has no Use line"
  | Some line ->
    check bool "retrieval count and days" true (contains "Retrieved 4 · 2 day(s)" line);
    check bool "last retrieval as an age" true (contains "last 2h" line);
    check bool "citations and predecessors" true (contains "Cited 1 · Revised from 1" line)
;;

let test_detail_lines () =
  let fact : Decode.memory_fact =
    { mf_claim = "Constitution requires evidence for claims"
    ; mf_category = "rule"
    ; mf_origin = "docs/constitution.xml"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-rule-1"
    ; mf_events = Decode.no_memory_fact_events
    }
  in
  let row = Types.Memory_row_fact fact in
  let lines = Render_memory.memory_fact_detail_lines ~cols:80 row in
  check bool "detail lines non-empty" true (List.length lines > 0);
  List.iter
    (fun line ->
      check bool "detail line bounded" true (Layout.display_width line <= 80))
    lines
;;

let test_detail_lines_source_and_invalidation () =
  let sfact : Decode.memory_source_fact =
    { msf_claim = "Config specifies runtime ports"
    ; msf_first_seen = 100.0
    ; msf_path = "config/runtime.toml"
    ; msf_sha256 = "abc123sha"
    }
  in
  let row_src = Types.Memory_row_source_fact sfact in
  let lines_src = Render_memory.memory_fact_detail_lines ~cols:80 row_src in
  check bool "source detail lines non-empty" true (List.length lines_src > 0);
  List.iter
    (fun line ->
      check bool "source detail line bounded" true (Layout.display_width line <= 80))
    lines_src;
  let inv : Decode.memory_invalidation =
    { mi_source_path = "config/old.toml"
    ; mi_invalidated_at = 200.0
    ; mi_reason = "deprecated"
    }
  in
  let row_inv = Types.Memory_row_invalidation inv in
  let lines_inv = Render_memory.memory_fact_detail_lines ~cols:80 row_inv in
  check bool "invalidation detail lines non-empty" true (List.length lines_inv > 0);
  List.iter
    (fun line ->
      check bool "invalidation detail line bounded" true (Layout.display_width line <= 80))
    lines_inv
;;

let make_keeper_health ~keeper_id ~facts ~snapshot_bytes : Decode.memory_keeper_health =
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
  ; mkh_librarian_lane_busy = 0
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

let test_render_memory_body () =
  let state = make_state () in
  let count = ref 0 in
  Render_memory.render_memory_body
    ~cols:80
    ~budget:20
    state
    ~push:(fun _ -> incr count)
    ~push_styled:(fun ~style:_ _ -> incr count)
    ~push_selected:(fun _ -> incr count)
    ~push_divider:(fun () -> incr count)
    ~push_empty:(fun () -> incr count);
  check bool "memory body rendered" true (!count > 0 && !count <= 20)
;;

let test_render_memory_body_with_keepers () =
  let state = make_state () in
  let keeper = make_keeper_health ~keeper_id:"alpha" ~facts:10 ~snapshot_bytes:1024 in
  let health : Decode.memory_health_snapshot =
    { mhs_generated_at = 1000.0
    ; mhs_keepers = [ keeper ]
    ; mhs_total_facts = 10
    ; mhs_total_observed_facts = 10
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 1024
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 0
    ; mhs_warn_alerts = 0
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    }
  in
  state.memory_health <- Some health;
  state.memory_health_cursor <- 0;
  let selected_called = ref false in
  let selected_str = ref "" in
  let count = ref 0 in
  Render_memory.render_memory_body
    ~cols:100
    ~budget:20
    state
    ~push:(fun _ -> incr count)
    ~push_styled:(fun ~style:_ _ -> incr count)
    ~push_selected:(fun s -> selected_called := true; selected_str := s; incr count)
    ~push_divider:(fun () -> incr count)
    ~push_empty:(fun () -> incr count);
  check bool "selected row was called" true !selected_called;
  check string "push_selected received stripped string" (Masc_tui_theme.strip_sgr !selected_str) !selected_str;
  check bool "rows rendered" true (!count > 0 && !count <= 20)
;;

let test_render_memory_body_cursor_clamping () =
  let state = make_state () in
  let keeper = make_keeper_health ~keeper_id:"alpha" ~facts:5 ~snapshot_bytes:512 in
  let health : Decode.memory_health_snapshot =
    { mhs_generated_at = 1000.0
    ; mhs_keepers = [ keeper ]
    ; mhs_total_facts = 5
    ; mhs_total_observed_facts = 5
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 512
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 0
    ; mhs_warn_alerts = 0
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    }
  in
  state.memory_health <- Some health;
  state.memory_health_cursor <- 999;
  let selected_called = ref false in
  let count = ref 0 in
  Render_memory.render_memory_body
    ~cols:100
    ~budget:20
    state
    ~push:(fun _ -> incr count)
    ~push_styled:(fun ~style:_ _ -> incr count)
    ~push_selected:(fun _ -> selected_called := true; incr count)
    ~push_divider:(fun () -> incr count)
    ~push_empty:(fun () -> incr count);
  check bool "selected row was clamped and called" true !selected_called
;;

let test_render_memory_facts_body () =
  let state = make_state () in
  let fact : Decode.memory_fact =
    { mf_claim = "Architecture uses modular TUI components"
    ; mf_category = "architecture"
    ; mf_origin = "manual"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-fact-1"
    ; mf_events = Decode.no_memory_fact_events
    }
  in
  let store : Decode.memory_ordinary_store =
    { mos_revision = 1
    ; mos_updated_at = 1000.0
    ; mos_facts = [ fact ]
    }
  in
  let snapshot : Decode.memory_fact_snapshot =
    { mfs_keeper = "alpha"
    ; mfs_ordinary = Decode.Memory_store_present store
    ; mfs_source = Decode.Memory_store_absent
    }
  in
  state.memory_facts <- Some snapshot;
  state.memory_facts_cursor <- 0;
  let selected_called = ref false in
  let count = ref 0 in
  Render_memory.render_memory_facts_body
    ~cols:100
    ~budget:20
    state
    ~push:(fun _ -> incr count)
    ~push_styled:(fun ~style:_ _ -> incr count)
    ~push_selected:(fun _ -> selected_called := true; incr count)
    ~push_divider:(fun () -> incr count)
    ~push_empty:(fun () -> incr count);
  check bool "selected fact row was called" true !selected_called;
  check bool "facts body rendered" true (!count > 0 && !count <= 20)
;;

(* The three row kinds and the column header share one grid: badge in cells
   2-13, age right-aligned in cells 15-20, text from cell 22. #33237 removed the
   reinforcement column from fact rows but left its five cells and a "-"
   placeholder in the source and dropped rows and a REINF label in the header,
   so the same list drew two grids. The bounded-width checks above cannot see
   that; this one reads the cells. *)
let test_rows_and_header_share_one_grid () =
  let cols = 120 in
  let fact : Decode.memory_fact =
    { mf_claim = "System uses Roger voice for Tester"
    ; mf_category = "persona"
    ; mf_origin = "manual"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-1"
    ; mf_events = Decode.no_memory_fact_events
    }
  in
  let sfact : Decode.memory_source_fact =
    { msf_claim = "Config points to runtime.toml"
    ; msf_first_seen = 150.0
    ; msf_path = "config/rt.toml" (* 16 cells or fewer: longer paths are shortened *)
    ; msf_sha256 = "abc123sha"
    }
  in
  let inv : Decode.memory_invalidation =
    { mi_source_path = "legacy_docs.md"; mi_invalidated_at = 300.0; mi_reason = "superseded" }
  in
  let cells row = Masc_tui_theme.strip_sgr (Render_memory.memory_fact_row_line ~cols row) in
  let grid what line text_at_22 =
    check char (what ^ ": badge opens at cell 2") '[' line.[2];
    check char (what ^ ": badge closes at cell 13") ']' line.[13];
    check char (what ^ ": one space before the age") ' ' line.[14];
    let age = String.sub line 15 6 in
    check bool (what ^ ": age is right-aligned in cells 15-20 and not blank") true
      (String.equal age (Printf.sprintf "%6s" (String.trim age)) && String.trim age <> "");
    check char (what ^ ": one space after the age") ' ' line.[21];
    check string (what ^ ": text starts at cell 22") text_at_22
      (String.sub line 22 (String.length text_at_22))
  in
  grid "fact row" (cells (Types.Memory_row_fact fact)) fact.mf_claim;
  grid "source row" (cells (Types.Memory_row_source_fact sfact)) sfact.msf_path;
  grid "dropped row" (cells (Types.Memory_row_invalidation inv)) inv.mi_source_path;
  let state = make_state () in
  let store : Decode.memory_ordinary_store =
    { mos_revision = 1; mos_updated_at = 1000.0; mos_facts = [ fact ] }
  in
  state.memory_facts
  <- Some
       { mfs_keeper = "alpha"
       ; mfs_ordinary = Decode.Memory_store_present store
       ; mfs_source = Decode.Memory_store_absent
       };
  state.memory_facts_cursor <- 0;
  let styled = ref [] in
  Render_memory.render_memory_facts_body
    ~cols
    ~budget:30
    state
    ~push:(fun _ -> ())
    ~push_styled:(fun ~style:_ line -> styled := line :: !styled)
    ~push_selected:(fun _ -> ())
    ~push_divider:(fun () -> ())
    ~push_empty:(fun () -> ());
  match List.find_opt (contains "CATEGORY") (List.map Masc_tui_theme.strip_sgr !styled) with
  | None -> fail "the facts body has no column header"
  | Some header ->
    check string "header names the age over cells 15-20" "   AGE" (String.sub header 15 6);
    check string "header names the text from cell 22" "CLAIM" (String.sub header 22 5)
;;

(* The row under the facts title. Each fact on this screen is written in one
   place: the title carries the total and the filters, this row carries the
   breakdown and the sort. The title is the row that runs out of width first --
   at 140 columns against a live server it has 80 cells, and the clock and the
   connection badge sit at its end. *)
let facts_body_lines ?(cols = 120) ?(budget = 30) state =
  let lines = ref [] in
  let keep line = lines := Masc_tui_theme.strip_sgr line :: !lines in
  Render_memory.render_memory_facts_body ~cols ~budget state
    ~push:keep
    ~push_styled:(fun ~style:_ line -> keep line)
    ~push_selected:keep
    ~push_divider:(fun () -> ())
    ~push_empty:(fun () -> ());
  List.rev !lines

let three_kinds_state ?(keeper = "alpha") () =
  let state = make_state () in
  let fact category claim : Decode.memory_fact =
    { mf_claim = claim
    ; mf_category = category
    ; mf_origin = "manual"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-" ^ claim
    ; mf_events = Decode.no_memory_fact_events
    }
  in
  let ordinary : Decode.memory_ordinary_store =
    { mos_revision = 1
    ; mos_updated_at = 1000.0
    ; mos_facts =
        [ fact "architecture" "The renderer draws the board"
        ; fact "persona" "Roger reads for the tester"
        ]
    }
  in
  let source : Decode.memory_source_store =
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
  state.memory_facts
  <- Some
       { mfs_keeper = keeper
       ; mfs_ordinary = Decode.Memory_store_present ordinary
       ; mfs_source = Decode.Memory_store_present source
       };
  state.memory_facts_cursor <- 0;
  state

let stats_row lines =
  match List.filter (contains "Sort [s]:") lines with
  | [ row ] -> row
  | [] -> fail "no row on the facts body names the sort"
  | _ :: _ -> fail "the sort is named on more than one row"

(* What the facts title actually has to spend. A terminal is not a surface: the
   Activity pane keeps its own columns beside every surface that is not Activity,
   and the frame spends its border and its padding on what is left. Counting the
   terminal gave 136 at 140 columns; the title really has 80. *)
let facts_title_cells ~terminal_cols =
  let pane =
    if Masc_tui_acting_pane.shown ~hidden:false ~cols:terminal_cols
    then Masc_tui_acting_pane.pane_cols
    else 0
  in
  Masc_tui_frame.inner_width ~cols:(terminal_cols - pane)

let live_title ?(keeper = Some "*") ?(total = 2316) ?(filter_label = "All")
    ?(query_label = "") () =
  Render_memory.facts_title ~screen:" MASC Memory"
    ~keeper:(Render_memory.facts_keeper_label keeper)
    ~reading:(Render_memory.Facts_loaded { total; filter_label; query_label })
    ~timestamp:"23:41:50" ~badge:"HTTP [refresh failed]"

let test_the_title_and_the_row_each_say_one_fact () =
  (* The two rows of the facts header, asserted together: the title carries the
     total and the filters, the row under it the breakdown and the sort. Each
     fact on one of them, never both. *)
  let title = live_title () in
  let rows = facts_body_lines (three_kinds_state ~keeper:"*" ()) in
  check bool "the title counts what is listed" true (contains "2316 facts" title);
  check bool "and reads the fleet view as words" true
    (contains "all keepers" title);
  check bool "the sort is not on the title" false (contains "Sort" title);
  check bool "nor is the breakdown" false (contains " ord " title);
  check bool "the clock survives to the end" true (contains "23:41:50" title);
  check bool "and so does the connection badge" true
    (contains "HTTP [refresh failed]" title);
  check int "the title fits what a 140-column terminal leaves it" 0
    (max 0 (Masc_tui_message_layout.display_width title
            - facts_title_cells ~terminal_cols:140));
  let row = stats_row rows in
  check bool "the row carries the sort" true (contains "Sort [s]:" row);
  check bool "and the total is not repeated on it" false (contains "facts" row)

let test_a_read_in_flight_says_so_and_keeps_the_clock () =
  let title =
    Render_memory.facts_title ~screen:" MASC Memory"
      ~keeper:(Render_memory.facts_keeper_label (Some "analyst"))
      ~reading:(Render_memory.Facts_unread { reading = "(not loaded)" })
      ~timestamp:"23:41:50"
      ~badge:"HTTP [refresh failed]"
  in
  check bool "it carries the reading the caller handed it" true
    (contains "(not loaded)" title);
  check bool "it does not invent a total" false (contains "facts" title);
  check bool "the clock and the badge are still last" true
    (contains "23:41:50  HTTP [refresh failed]" title)

let test_the_clock_and_the_badge_keep_a_fixed_tail () =
  (* The title's last two fields are a fixed cost, so what the counts and the
     filters may spend is the rest. 80 cells at a 140-column terminal, of which
     the clock and the badge take 33 -- which is why the sort, spelled here as
     well as on the row below, was what pushed them off the screen.

     A filter long enough to pass that budget still cuts the tail, and the tail
     is the badge. The title is not the one that has to carry the query: the body
     draws it again under [Filter [/]:]. The remaining defect is #35575. *)
  let tail = "  00:41:00  HTTP [refresh failed]" in
  check int "the clock and the badge cost the same whatever is read" 33
    (Masc_tui_message_layout.display_width tail);
  let room = facts_title_cells ~terminal_cols:140 in
  check int "a live fleet reading fits it" 0
    (max 0 (Masc_tui_message_layout.display_width (live_title ()) - room));
  check bool "and a query long enough does not" true
    (Masc_tui_message_layout.display_width
       (live_title ~query_label:" \xc2\xb7 filter \"a phrase long enough to crowd the row\"" ())
     > room)

let test_the_breakdown_and_the_sort_sit_on_one_row () =
  let state = three_kinds_state () in
  let lines = facts_body_lines state in
  check string "the breakdown, then the sort that ordered it"
    "  (2 ord \xc2\xb7 1 src \xc2\xb7 1 drop) \xc2\xb7 Sort [s]: Recency (Newest)"
    (stats_row lines);
  check bool "and the total the title already draws is not repeated" false
    (List.exists (contains "Total:") lines)

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

let test_the_narrowest_body_spends_its_row_on_the_sort () =
  (* One body row, and the sort is the one fact nothing else on screen carries:
     not the title, not the category pills. So the first body row is the row
     under the title, whatever else the fleet view could say about itself. *)
  let state = three_kinds_state ~keeper:"*" () in
  state.memory_facts_keeper <- Some "*";
  let lines = facts_body_lines ~budget:1 state in
  check string "the first body row is the one carrying the sort"
    (stats_row lines) (List.hd lines)

let test_fleet_fact_row_line () =
  let fact : Decode.memory_fact =
    { mf_claim = "System uses Roger voice for Tester"
    ; mf_category = "persona"
    ; mf_origin = "tester · manual"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_memory_id = "mem-1"
    ; mf_events = Decode.no_memory_fact_events
    }
  in
  let row = Types.Memory_row_fact fact in
  let line = Render_memory.memory_fact_row_line ~is_fleet:true ~cols:120 row in
  check bool "fleet fact row line bounded" true (Layout.display_width line <= 120);
  let stripped = Masc_tui_theme.strip_sgr line in
  check bool "fleet fact row has tester tag" true (contains "tester" stripped);
  check bool "fleet fact row has IDENTITY badge" true (contains "IDENTITY" stripped)
;;

let test_render_memory_body_sorting () =
  let state = make_state () in
  let k1 = make_keeper_health ~keeper_id:"alpha" ~facts:10 ~snapshot_bytes:2048 in
  let k2 = make_keeper_health ~keeper_id:"beta" ~facts:50 ~snapshot_bytes:1024 in
  let health : Decode.memory_health_snapshot =
    { mhs_generated_at = 1000.0
    ; mhs_keepers = [ k1; k2 ]
    ; mhs_total_facts = 60
    ; mhs_total_observed_facts = 60
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 3072
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
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
  let selected () = Option.map (fun k -> k.Decode.mkh_keeper_id) (Types.selected_memory_keeper state) in
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
            [{ ma_code = Decode.Source_snapshot_read_error
             ; ma_label = "source"
             ; ma_message = "unreadable source snapshot"
             }]
        })
  in
  state.memory_health <- Some
    { mhs_generated_at = 1700000000.
    ; mhs_keepers = keepers
    ; mhs_total_facts = 50
    ; mhs_total_observed_facts = 50
    ; mhs_total_derived_facts = 0
    ; mhs_total_support_invalidations = 0
    ; mhs_total_snapshot_bytes = 5120
    ; mhs_total_source_facts = 0
    ; mhs_total_source_invalidations = 0
    ; mhs_total_source_snapshot_bytes = 0
    ; mhs_total_librarian_failures = 0
    ; mhs_total_vision_ingest_errors = 0
    ; mhs_total_read_errors = 0
    ; mhs_total_source_read_errors = 1
    ; mhs_warn_alerts = 1
    ; mhs_error_alerts = 0
    ; mhs_starving_keepers = 0
    };
  let rows = 21 in
  let budget = rows - Masc_tui_frame.chrome_rows in
  let height layout =
    Masc_tui_scroll.content_height ~rows ~chrome:layout.Types.sc_chrome
      ~count:layout.sc_count ~preview_keep:layout.sc_preview_keep
      ~overflow_takes_row:layout.sc_overflow_takes_row
  in
  check int "five keepers fit two list rows beside their context" 2
    (height (Types.memory_overview_scrolled state));
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
      (Option.fold ~none:false ~some:(contains expected.mkh_keeper_id) !selected)
  in
  (* Move through an overflowing list using the same target-row layout as
     keyboard input, including the context of the newly selected keeper. *)
  for cursor = 0 to 4 do
    let layout = Types.memory_overview_scrolled ~cursor state in
    state.memory_health_cursor <- cursor;
    state.memory_health_scroll <-
      Masc_tui_scroll.ensure_visible ~cursor ~height:(height layout)
        state.memory_health_scroll;
    assert_selected_visible ()
  done;
  check int "the final row's error and alert leave one list row" 1
    (height (Types.memory_overview_scrolled state));
  check int "the final row requires scrolling" 4 state.memory_health_scroll;
  state.search_last <- "keeper-4";
  state.memory_health_error <- Some "refresh failed";
  let layout = Option.get (Types.scrolled_surface state Types.Memory) in
  check int "filter bounds the cursor to the one visible keeper" 1 layout.sc_count;
  check (option (list string)) "search names the same filtered row"
    (Some ["keeper-4 read-error"]) (Types.surface_row_texts state Types.Memory);
  (* A refresh/filter can change the body before another keypress. *)
  assert_selected_visible ()
;;

let () =
  run "tui_render_memory"
    [ ( "age_label"
      , [ test_case "age_label_formatting" `Quick test_age_label ] )
    ; ( "row_lines"
      , [ test_case "fact_row" `Quick test_fact_row_line
        ; test_case "fleet_fact_row" `Quick test_fleet_fact_row_line
        ; test_case "source_fact_row" `Quick test_source_fact_row_line
        ; test_case "invalidation_row" `Quick test_invalidation_row_line
        ; test_case "rows_and_header_share_one_grid" `Quick test_rows_and_header_share_one_grid
        ; test_case "detail_names_the_use_record" `Quick test_detail_names_the_use_record
        ] )
    ; ( "detail_lines"
      , [ test_case "detail_lines_bounded" `Quick test_detail_lines
        ; test_case "detail_lines_source_and_invalidation" `Quick test_detail_lines_source_and_invalidation
        ] )
    ; ( "render_body"
      , [ test_case "memory_body_budget" `Quick test_render_memory_body
        ; test_case "memory_body_with_keepers" `Quick test_render_memory_body_with_keepers
        ; test_case "memory_body_sorting" `Quick test_render_memory_body_sorting
        ; test_case "memory_overflow_selection" `Quick test_render_memory_overflow_selection
        ; test_case "memory_body_cursor_clamping" `Quick test_render_memory_body_cursor_clamping
        ; test_case "memory_facts_body" `Quick test_render_memory_facts_body
        ] )
    ; ( "one place per fact"
      , [ test_case "the title and the row each say one fact" `Quick
            test_the_title_and_the_row_each_say_one_fact
        ; test_case "a read in flight says so and keeps the clock" `Quick
            test_a_read_in_flight_says_so_and_keeps_the_clock
        ; test_case "the clock and the badge keep a fixed tail" `Quick
            test_the_clock_and_the_badge_keep_a_fixed_tail
        ; test_case "the breakdown and the sort sit on one row" `Quick
            test_the_breakdown_and_the_sort_sit_on_one_row
        ; test_case "the breakdown counts the rows the screen lists" `Quick
            test_the_breakdown_counts_the_rows_the_screen_lists
        ; test_case "the narrowest body spends its row on the sort" `Quick
            test_the_narrowest_body_spends_its_row_on_the_sort
        ] )
    ]
;;
