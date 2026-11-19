open Alcotest

module Bands = Masc_tui_overview_bands
module Layout = Masc_tui_message_layout

let test_plan_thresholds () =
  check bool "narrow terminal keeps cards only" true
    (Bands.plan ~available:24 ~cols:(Bands.min_cols - 1) ~keeper_count:4
     = Bands.Cards_only);
  check bool "short terminal keeps cards only" true
    (Bands.plan ~available:(Bands.min_rows - 1) ~cols:120 ~keeper_count:4
     = Bands.Cards_only);
  List.iter
    (fun (available, cols, keeper_count) ->
       match Bands.plan ~available ~cols ~keeper_count with
       | Bands.Cards_only ->
           fail
             (Printf.sprintf "expected With_bands for available=%d cols=%d keepers=%d"
                available cols keeper_count)
       | Bands.With_bands { telemetry_rows; keeper_rows; card_rows } ->
           check int "budget sums to available" available
             (telemetry_rows + keeper_rows + card_rows);
           check bool "telemetry_rows >= 4" true (telemetry_rows >= 4);
           check bool "keeper_rows is 0 or >= 3" true
             (keeper_rows = 0 || keeper_rows >= 3);
           check bool "card_rows >= 8" true (card_rows >= 8);
           if keeper_count = 0 then
             check int "no keeper table when keeper_count = 0" 0 keeper_rows)
    [ (18, 88, 0); (18, 88, 1); (18, 88, 2); (24, 100, 6); (36, 140, 20) ]

let sample_snapshot : Bands.telemetry_snapshot =
  { fleet_running = 3
  ; fleet_bootable = 6
  ; capacity_avail = 4
  ; capacity_target = 6
  ; capacity_shortfall = 2
  ; fleet_status = None
  ; heap_live_words = Some 12_000_000
  ; heap_total_words = Some 24_000_000
  ; heap_live_text = Some "96 MB"
  ; heap_total_text = Some "192 MB"
  ; sched_p95_ms = Some 1.42
  ; sched_stalls = Some 1
  ; tool_calls_summary = Some "24h: 120 calls"
  }

let empty_snapshot : Bands.telemetry_snapshot =
  { fleet_running = 0
  ; fleet_bootable = 0
  ; capacity_avail = 0
  ; capacity_target = 0
  ; capacity_shortfall = 0
  ; fleet_status = None
  ; heap_live_words = None
  ; heap_total_words = None
  ; heap_live_text = None
  ; heap_total_text = None
  ; sched_p95_ms = None
  ; sched_stalls = None
  ; tool_calls_summary = None
  }

let sample_keepers : Bands.keeper_entry list =
  [ { name = "code-reviewer"
    ; mark = "●"
    ; mark_tone = ""
    ; state_label = "running"
    ; context_ratio = Some 0.42
    ; detail = "task-101"
    ; needs_attention = false
    }
  ; { name = "very-long-keeper-name-that-must-be-fitted"
    ; mark = "!"
    ; mark_tone = ""
    ; state_label = "paused"
    ; context_ratio = Some 0.91
    ; detail = "waiting for approval on a long task title"
    ; needs_attention = true
    }
  ; { name = "idle-keeper"
    ; mark = "·"
    ; mark_tone = ""
    ; state_label = "idle"
    ; context_ratio = None
    ; detail = ""
    ; needs_attention = false
    }
  ]

let test_telemetry_rectangle_invariants () =
  List.iter
    (fun ko ->
       List.iter
         (fun snap ->
            List.iter
              (fun width ->
                 let rows = Bands.render_telemetry ~ko ~width ~height:4 snap in
                 check int "exact telemetry row count" 4 (List.length rows);
                 List.iter
                   (fun row ->
                      check int
                        (Printf.sprintf "telemetry row width at %d" width)
                        width (Layout.display_width row))
                   rows)
              [ 60; 88; 110; 140 ])
         [ sample_snapshot; empty_snapshot ])
    [ true; false ]

let test_keepers_rectangle_invariants () =
  List.iter
    (fun ko ->
       List.iter
         (fun entries ->
            List.iter
              (fun (width, height) ->
                 let rows =
                   Bands.render_keepers ~ko ~width ~height
                     ~total_keepers:(List.length entries) entries
                 in
                 check int "exact keeper table row count" height (List.length rows);
                 List.iter
                   (fun row ->
                      check int
                        (Printf.sprintf "keeper row width at %d" width)
                        width (Layout.display_width row))
                   rows)
              [ (60, 4); (88, 5); (120, 6) ])
         [ sample_keepers; [] ])
    [ true; false ]

let () =
  run "tui overview bands"
    [ ( "plan"
      , [ test_case "plan enforces thresholds and exact row budget" `Quick
            test_plan_thresholds
        ] )
    ; ( "geometry"
      , [ test_case "telemetry card preserves exact rectangle geometry" `Quick
            test_telemetry_rectangle_invariants
        ; test_case "keepers mini-table preserves exact rectangle geometry" `Quick
            test_keepers_rectangle_invariants
        ] )
    ]
