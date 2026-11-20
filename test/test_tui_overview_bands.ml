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
           check bool "card_rows >= 8" true (card_rows >= 8))
    [ (18, 88, 0); (18, 88, 1); (18, 88, 2); (24, 100, 6); (36, 140, 20) ];
  List.iter
    (fun (available, cols) ->
       let baseline = Bands.plan ~available ~cols ~keeper_count:0 in
       List.iter
         (fun count ->
            check bool
              (Printf.sprintf "plan invariant at avail=%d cols=%d count=%d"
                 available cols count)
              true
              (Bands.plan ~available ~cols ~keeper_count:count = baseline))
         [ 1; 2; 6; 20 ])
    [ (24, 100); (36, 140) ]

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
    ; activity_summary = "42t · 18.2k"
    ; detail = "task-101"
    ; needs_attention = false
    }
  ; { name = "very-long-keeper-name-that-must-be-fitted"
    ; mark = "!"
    ; mark_tone = ""
    ; state_label = "paused"
    ; activity_summary = "9t · 4.1k"
    ; detail = "waiting for approval on a long task title"
    ; needs_attention = true
    }
  ; { name = "idle-keeper"
    ; mark = "·"
    ; mark_tone = ""
    ; state_label = "idle"
    ; activity_summary = ""
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
    [ true; false ];
  let rendered =
    Bands.render_keepers ~ko:false ~width:100 ~height:5
      ~total_keepers:(List.length sample_keepers) sample_keepers
    |> String.concat "\n"
  in
  let has_substring needle =
    let nlen = String.length needle in
    let hlen = String.length rendered in
    let rec scan i =
      if i + nlen > hlen then false
      else if String.sub rendered i nlen = needle then true
      else scan (i + 1)
    in
    scan 0
  in
  check bool "populated activity summary reaches rendered rows" true
    (has_substring "42t \xc2\xb7 18.2k");
  check bool "unread activity renders no-value glyph" true
    (has_substring "\xe2\x80\x94")

let test_attention_state_uses_mark_tone () =
  let failing_tone = "\027[31m" in
  let calm_tone = "\027[32m" in
  let entries : Bands.keeper_entry list =
    [ { name = "broken-keeper"
      ; mark = "✕"
      ; mark_tone = failing_tone
      ; state_label = "failing"
      ; activity_summary = "3t"
      ; detail = "provider error"
      ; needs_attention = true
      }
    ; { name = "calm-keeper"
      ; mark = "●"
      ; mark_tone = calm_tone
      ; state_label = "running"
      ; activity_summary = "10t"
      ; detail = ""
      ; needs_attention = false
      }
    ]
  in
  let rendered =
    Bands.render_keepers ~ko:false ~width:100 ~height:4 ~total_keepers:2 entries
    |> String.concat "\n"
  in
  let contains needle =
    let nlen = String.length needle and hlen = String.length rendered in
    let rec scan i =
      if i + nlen > hlen then false
      else if String.sub rendered i nlen = needle then true
      else scan (i + 1)
    in
    scan 0
  in
  check bool "attention state_label wears entry.mark_tone" true
    (contains (failing_tone ^ "failing"));
  check bool "non-attention state_label does not wear mark_tone" false
    (contains (calm_tone ^ "running"))

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
        ; test_case "attention keeper row matches state tone to mark_tone" `Quick
            test_attention_state_uses_mark_tone
        ] )
    ]
