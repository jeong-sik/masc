(* The transport tail of the Overview's cluster row. It named the path
   carrying the traffic in the wire's words and then named those same paths in
   its own, so one path wore two spellings on one row. *)

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec scan i = i + n <= h && (String.sub haystack i n = needle || scan (i + 1)) in
  n = 0 || scan 0

let mark = Masc_tui_theme.Glyph.current_entry

let reading ?(sse = 0) ?websocket ?grpc ?(dropped = 0)
    ?(pressure = Masc.Transport_metrics.Steady) primary :
    Masc.Tui_decode.transport_health =
  { th_primary_path = primary
  ; th_queue_pressure = pressure
  ; th_sse_sessions = sse
  ; th_websocket_sessions = websocket
  ; th_grpc_port = grpc
  ; th_events_dropped = dropped
  }

(* One entry per path, the mark on the one carrying the traffic, and the
   queue's pressure beside the dropped count it belongs with. *)
let test_the_path_in_use_wears_the_mark () =
  Alcotest.(check string) "the row"
    (" " ^ mark ^ "sse 1  ws off  grpc off  steady")
    (Masc_tui_render_prim.transport_summary
       (reading ~sse:1 Masc.Transport_metrics.Sse))

(* The row said "websocket" and then "ws 1" two fields later. *)
let test_the_row_never_says_a_path_twice () =
  let row =
    Masc_tui_render_prim.transport_summary
      (reading ~sse:3 ~websocket:1 ~grpc:8936 Masc.Transport_metrics.Websocket)
  in
  Alcotest.(check bool) "the path in use is marked" true (contains (mark ^ "ws 1") row);
  List.iter
    (fun wire ->
      Alcotest.(check bool) (wire ^ " is not on the row") false (contains wire row))
    [ "websocket"; "grpc_subscribe"; "streamable_http" ];
  Alcotest.(check bool) "the other paths keep their entries" true
    (contains "sse 3" row && contains "grpc :8936" row)

(* The reading has no session count for streamable HTTP, so an entry for it
   would be a name with nothing to say -- except while it is the path in use,
   which is the one thing the row would otherwise fail to report. *)
let test_streamable_http_appears_only_while_it_carries_the_traffic () =
  Alcotest.(check bool) "named while in use" true
    (contains (mark ^ "http")
       (Masc_tui_render_prim.transport_summary
          (reading Masc.Transport_metrics.Streamable_http)));
  Alcotest.(check bool) "absent otherwise" false
    (contains "http"
       (Masc_tui_render_prim.transport_summary
          (reading ~sse:1 Masc.Transport_metrics.Sse)))

(* Pressure and the dropped count are two readings of the same queue. *)
let test_the_queue_readings_sit_together () =
  let row =
    Masc_tui_render_prim.transport_summary
      (reading ~sse:1 ~dropped:4 ~pressure:Masc.Transport_metrics.High
         Masc.Transport_metrics.Sse)
  in
  Alcotest.(check bool) "pressure then drops" true (contains "high  dropped 4" row)

let () =
  Alcotest.run "tui_overview_transport_row"
    [ ( "transport tail"
      , [ Alcotest.test_case "the path in use wears the mark" `Quick
            test_the_path_in_use_wears_the_mark
        ; Alcotest.test_case "the row never says a path twice" `Quick
            test_the_row_never_says_a_path_twice
        ; Alcotest.test_case "streamable http appears only while it carries the traffic"
            `Quick test_streamable_http_appears_only_while_it_carries_the_traffic
        ; Alcotest.test_case "the queue readings sit together" `Quick
            test_the_queue_readings_sit_together
        ] )
    ]
