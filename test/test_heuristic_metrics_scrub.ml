(* #9919: verify init-time scrub drops legacy degenerate rows
   matching the exact signature diagnosed in the issue
   (site=post_tool_use_failure, raw=1.0, threshold=0.0, triggered=true)
   and preserves every other row — including near-misses that differ
   in any single field. *)

module HM = Masc_mcp.Heuristic_metrics

let make_row ~site ~raw ~threshold ~triggered =
  Printf.sprintf
    "{\"site\":%S,\"module\":\"m\",\"raw_value\":%.6f,\"threshold\":%.6f,\"triggered\":%b,\"timestamp\":1.0,\"provenance\":{\"type\":\"pipeline_stage\",\"detail\":\"d\"}}"
    site
    raw
    threshold
    triggered
;;

let mk_temp_file contents =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "9919-scrub-%d-%06x.jsonl" (Unix.getpid ()) (Random.bits ()))
  in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path
;;

let read_lines path =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | line -> loop (line :: acc)
    | exception End_of_file ->
      close_in ic;
      List.rev acc
  in
  loop []
;;

let degenerate =
  make_row ~site:"post_tool_use_failure" ~raw:1.0 ~threshold:0.0 ~triggered:true
;;

let test_drops_exact_degenerate_signature () =
  let contents = degenerate ^ "\n" ^ degenerate ^ "\n" in
  let path = mk_temp_file contents in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       let dropped = HM.scrub_legacy_degenerate_rows path in
       Alcotest.(check int) "both rows dropped" 2 dropped;
       Alcotest.(check int) "file empty after scrub" 0 (List.length (read_lines path)))
;;

let test_preserves_same_site_different_value () =
  (* Same site but raw ≠ 1.0 — real data, not the degenerate tuple. *)
  let live_row =
    make_row ~site:"post_tool_use_failure" ~raw:0.5 ~threshold:0.0 ~triggered:true
  in
  let contents = degenerate ^ "\n" ^ live_row ^ "\n" in
  let path = mk_temp_file contents in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       let dropped = HM.scrub_legacy_degenerate_rows path in
       Alcotest.(check int) "only the degenerate row dropped" 1 dropped;
       let remaining = read_lines path in
       Alcotest.(check int) "one row kept" 1 (List.length remaining);
       Alcotest.(check bool)
         "kept row is the live data"
         true
         (List.hd remaining = live_row))
;;

let test_preserves_unrelated_sites () =
  let rows =
    String.concat
      "\n"
      [ make_row ~site:"drift_guard" ~raw:0.9 ~threshold:0.7 ~triggered:false
      ; make_row ~site:"keeper_alert_signal" ~raw:0.3 ~threshold:0.5 ~triggered:false
      ; make_row ~site:"verify" ~raw:1.0 ~threshold:0.5 ~triggered:false
      ]
    ^ "\n"
  in
  let path = mk_temp_file rows in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       let dropped = HM.scrub_legacy_degenerate_rows path in
       Alcotest.(check int) "nothing dropped" 0 dropped;
       Alcotest.(check int) "all three rows kept" 3 (List.length (read_lines path)))
;;

let test_no_rewrite_when_nothing_to_drop () =
  (* When the file contains zero degenerate rows, the scrub must leave
     the file untouched (no needless rewrite that would bump mtime
     and race with the running server's flusher). *)
  let live = make_row ~site:"verify" ~raw:1.0 ~threshold:0.5 ~triggered:false in
  let path = mk_temp_file (live ^ "\n") in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       let before = (Unix.stat path).st_mtime in
       Unix.sleep 1;
       let _ = HM.scrub_legacy_degenerate_rows path in
       let after = (Unix.stat path).st_mtime in
       Alcotest.(check (float 1e-9)) "mtime unchanged when no drops" before after)
;;

let test_missing_file_returns_zero () =
  let path =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "9919-scrub-missing-%06x" (Random.bits ()))
  in
  (* file does not exist *)
  Alcotest.(check int) "zero dropped" 0 (HM.scrub_legacy_degenerate_rows path)
;;

let () =
  Random.self_init ();
  Alcotest.run
    "heuristic_metrics_scrub"
    [ ( "scrub"
      , [ Alcotest.test_case
            "drops exact degenerate signature"
            `Quick
            test_drops_exact_degenerate_signature
        ; Alcotest.test_case
            "preserves same site different value"
            `Quick
            test_preserves_same_site_different_value
        ; Alcotest.test_case
            "preserves unrelated sites"
            `Quick
            test_preserves_unrelated_sites
        ; Alcotest.test_case
            "no rewrite when nothing to drop"
            `Slow
            test_no_rewrite_when_nothing_to_drop
        ; Alcotest.test_case
            "missing file returns zero"
            `Quick
            test_missing_file_returns_zero
        ] )
    ]
;;
