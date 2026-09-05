open Alcotest
module Types = Masc_tui_types
module Decode = Masc.Tui_decode
module Layout = Masc_tui_message_layout
module Render_memory = Masc_tui_render_memory

let make_state () =
  Types.create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()
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
    { mf_claim = "System uses Roger voice for Sangsu"
    ; mf_category = "persona"
    ; mf_origin = "manual"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_reinforcement = 3
    ; mf_memory_id = "mem-1"
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

let test_detail_lines () =
  let fact : Decode.memory_fact =
    { mf_claim = "Constitution requires evidence for claims"
    ; mf_category = "rule"
    ; mf_origin = "docs/constitution.xml"
    ; mf_first_seen = 100.0
    ; mf_last_seen = 200.0
    ; mf_reinforcement = 5
    ; mf_memory_id = "mem-rule-1"
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
    ; mf_reinforcement = 4
    ; mf_memory_id = "mem-fact-1"
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

let () =
  run "tui_render_memory"
    [ ( "age_label"
      , [ test_case "age_label_formatting" `Quick test_age_label ] )
    ; ( "row_lines"
      , [ test_case "fact_row" `Quick test_fact_row_line
        ; test_case "source_fact_row" `Quick test_source_fact_row_line
        ; test_case "invalidation_row" `Quick test_invalidation_row_line
        ] )
    ; ( "detail_lines"
      , [ test_case "detail_lines_bounded" `Quick test_detail_lines
        ; test_case "detail_lines_source_and_invalidation" `Quick test_detail_lines_source_and_invalidation
        ] )
    ; ( "render_body"
      , [ test_case "memory_body_budget" `Quick test_render_memory_body
        ; test_case "memory_body_with_keepers" `Quick test_render_memory_body_with_keepers
        ; test_case "memory_body_cursor_clamping" `Quick test_render_memory_body_cursor_clamping
        ; test_case "memory_facts_body" `Quick test_render_memory_facts_body
        ] )
    ]
;;
