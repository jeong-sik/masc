(* The frame-time report, with numbers a test chooses.

   The clock and the file stay out: what is checked is that the summary says
   which phase, which surface, and which frames made the tail, and that a
   phase nobody sampled prints nothing. *)

module Timing = Masc_tui_frame_timing

let contains haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  at 0
;;

let line_starting_with prefix lines =
  List.find_opt
    (fun line ->
      let trimmed = String.trim line in
      String.length trimmed >= String.length prefix
      && String.sub trimmed 0 (String.length prefix) = prefix)
    lines
;;

let samples =
  Timing.Samples.empty
  |> fun t -> Timing.Samples.add t Timing.Build ~tag:(Some "overview") ~ms:1.0
  |> fun t -> Timing.Samples.add t Timing.Build ~tag:(Some "keeper-message") ~ms:64.0
  |> fun t -> Timing.Samples.add t Timing.Build ~tag:(Some "keeper-message") ~ms:133.0
  |> fun t -> Timing.Samples.add t Timing.Build ~tag:(Some "overview") ~ms:2.0
  |> fun t -> Timing.Samples.add t Timing.Build ~tag:None ~ms:5.0
;;

let test_phase_line_counts_every_sample () =
  let lines = Timing.Samples.summary_lines samples in
  match line_starting_with "build frames=" lines with
  | None -> Alcotest.fail "no build line"
  | Some line ->
      Alcotest.(check bool) "five frames" true (contains line "frames=5");
      Alcotest.(check bool) "max is the slowest" true (contains line "max=133.00")
;;

let test_tags_sort_by_frame_count () =
  let lines = Timing.Samples.summary_lines samples in
  let tagged = List.filter (fun l -> contains l "build[") lines in
  match tagged with
  | [ first; second ] ->
      (* Two surfaces with two frames each: the order among ties is the order
         of first appearance, and the untagged frame belongs to neither. *)
      Alcotest.(check bool) "overview first" true (contains first "build[overview] frames=2");
      Alcotest.(check bool) "chat second" true (contains second "build[keeper-message] frames=2");
      Alcotest.(check bool) "chat tail" true (contains second "p99=133.00")
  | other -> Alcotest.failf "expected two tag lines, got %d" (List.length other)
;;

let test_worst_frames_name_their_surface () =
  let lines = Timing.Samples.summary_lines samples in
  match line_starting_with "worst[0]" lines with
  | None -> Alcotest.fail "no worst line"
  | Some line ->
      Alcotest.(check bool) "ordinal" true (contains line "frame=3 ");
      Alcotest.(check bool) "tag" true (contains line "tag=keeper-message")
;;

let test_unsampled_phase_prints_nothing () =
  let lines = Timing.Samples.summary_lines samples in
  Alcotest.(check bool)
    "no present line"
    true
    (Option.is_none (line_starting_with "present" lines));
  Alcotest.(check (list string)) "empty is empty" []
    (Timing.Samples.summary_lines Timing.Samples.empty)
;;

let test_ordinals_count_per_phase () =
  let t =
    Timing.Samples.empty
    |> fun t -> Timing.Samples.add t Timing.Build ~tag:None ~ms:1.0
    |> fun t -> Timing.Samples.add t Timing.Present ~tag:None ~ms:9.0
    |> fun t -> Timing.Samples.add t Timing.Present ~tag:None ~ms:2.0
  in
  let lines = Timing.Samples.summary_lines t in
  let present_worst =
    List.filter (fun l -> contains l "worst[0]") lines |> List.rev
  in
  match present_worst with
  | last :: _ -> Alcotest.(check bool) "present ordinal 1" true (contains last "frame=1 9.00ms")
  | [] -> Alcotest.fail "no worst lines"
;;

let test_stages_keep_frame_and_outer_fetch_apart () =
  let stages =
    Timing.Stage_samples.empty
    |> fun t -> Timing.Stage_samples.add t ~frame:None ~name:"board.http_json" ~ms:(Some 7.0)
    |> fun t -> Timing.Stage_samples.add t ~frame:None ~name:"board.http_json" ~ms:(Some 13.0)
    |> fun t -> Timing.Stage_samples.add t ~frame:None ~name:"board.http_json" ~ms:(Some 19.0)
    |> fun t -> Timing.Stage_samples.add t ~frame:(Some 16)
      ~name:"board.thread.wrap" ~ms:(Some 2.0)
    |> fun t -> Timing.Stage_samples.add t ~frame:(Some 16)
      ~name:"board.thread.wrap" ~ms:(Some 3.0)
    |> fun t -> Timing.Stage_samples.add t ~frame:(Some 16)
      ~name:"board.cache.cold" ~ms:None
    |> fun t -> Timing.Stage_samples.add t ~frame:(Some 1)
      ~name:"overview.layout" ~ms:(Some 5.0)
    |> fun t -> Timing.Stage_samples.add t ~frame:(Some 2)
      ~name:"board.thread.wrap" ~ms:(Some 2.0)
    |> fun t -> Timing.Stage_samples.add t ~frame:(Some 3)
      ~name:"board.thread.wrap" ~ms:(Some 10.0)
  in
  let lines = Timing.Stage_samples.summary_lines stages in
  Alcotest.(check bool) "same-frame wrapping sums" true
    (List.exists (fun line ->
       contains line "frame=16 name=board.thread.wrap ms=5.000 calls=2") lines);
  Alcotest.(check bool) "stage percentile uses frame sum" true
    (List.exists (fun line ->
       contains line "stage[board.thread.wrap] frames=3 p50=5.000ms p95=10.000") lines);
  Alcotest.(check bool) "outside fetch counts calls, not frames" true
    (List.exists (fun line ->
       contains line "stage[board.http_json] calls=3 p50=13.000ms p95=19.000 max=19.000") lines);
  Alcotest.(check bool) "fetch is outside Build" true
    (List.exists (fun line ->
       contains line "outside-build name=board.http_json ms=39.000 calls=3") lines);
  Alcotest.(check bool) "cold is a note, not zero duration" true
    (List.exists (fun line ->
       contains line "frame=16 name=board.cache.cold note") lines);
  let builds =
    Timing.Samples.add Timing.Samples.empty Timing.Build
      ~tag:(Some "board-read") ~ms:10.0
  in
  let residual = Timing.Stage_samples.residual_lines stages builds in
  Alcotest.(check bool) "residual excludes outside-Build fetch" true
    (List.exists (fun line ->
       contains line "frame=1 name=unattributed ms=5.000") residual)
;;

let test_default_off_keeps_values_and_skips_names () =
  Alcotest.(check bool) "timing is off without an output path" false Timing.enabled;
  let named = ref false in
  let name _ =
    named := true;
    "unexpected"
  in
  let value = Timing.time_tagged Timing.Build ~tag:name (fun () -> 42) in
  let stage_value = Timing.time_stage_tagged ~name (fun () -> 17) in
  Alcotest.(check int) "frame value is unchanged" 42 value;
  Alcotest.(check int) "stage value is unchanged" 17 stage_value;
  Alcotest.(check bool) "name callbacks were skipped" false !named;
  Alcotest.(check bool) "no stage clock started" true
    (Option.is_none (Timing.start_stage ()))
;;

let test_opt_in_report_is_bounded () =
  Alcotest.(check int) "short-run frame limit" 512 Timing.max_frames_per_phase;
  Alcotest.(check int) "short-run stage limit" 4096 Timing.max_stage_samples;
  let builds =
    List.init (Timing.max_frames_per_phase + 1) (fun _ -> ())
    |> List.fold_left
         (fun t () -> Timing.Samples.add t Timing.Build ~tag:None ~ms:1.0)
         Timing.Samples.empty
  in
  let build_lines = Timing.Samples.summary_lines builds in
  Alcotest.(check bool) "only the bounded prefix is summarized" true
    (List.exists (fun line -> contains line "build frames=512") build_lines);
  Alcotest.(check bool) "the omitted frame is disclosed" true
    (List.exists (fun line -> contains line "build omitted=1") build_lines);
  let stages =
    List.init (Timing.max_stage_samples + 1) (fun _ -> ())
    |> List.fold_left
         (fun t () ->
           Timing.Stage_samples.add t ~frame:(Some 1) ~name:"bounded"
             ~ms:(Some 0.1))
         Timing.Stage_samples.empty
  in
  let stage_lines = Timing.Stage_samples.summary_lines stages in
  Alcotest.(check bool) "stage records stop at the cap" true
    (List.exists (fun line -> contains line "name=bounded ms=409.600 calls=4096")
       stage_lines);
  Alcotest.(check bool) "omitted stage records are disclosed" true
    (List.exists (fun line -> contains line "omitted=1 (caps: 4096 records, 512 Build frames)")
       stage_lines);
  Alcotest.(check (list string)) "partial residual is not reported" []
    (Timing.Stage_samples.residual_lines stages builds);
  let late_stage =
    Timing.Stage_samples.add Timing.Stage_samples.empty
      ~frame:(Some (Timing.max_frames_per_phase + 1)) ~name:"late" ~ms:(Some 1.0)
  in
  Alcotest.(check bool) "stage beyond the frame window is omitted" true
    (List.exists
       (fun line -> contains line "omitted=1 (caps: 4096 records, 512 Build frames)")
       (Timing.Stage_samples.summary_lines late_stage))
;;

let () =
  Alcotest.run
    "tui frame timing"
    [ ( "summary",
        [ Alcotest.test_case "phase line counts every sample" `Quick
            test_phase_line_counts_every_sample;
          Alcotest.test_case "tags sort by frame count" `Quick
            test_tags_sort_by_frame_count;
          Alcotest.test_case "worst frames name their surface" `Quick
            test_worst_frames_name_their_surface;
          Alcotest.test_case "unsampled phase prints nothing" `Quick
            test_unsampled_phase_prints_nothing;
          Alcotest.test_case "ordinals count per phase" `Quick
            test_ordinals_count_per_phase;
          Alcotest.test_case "stages retain the Build frame" `Quick
            test_stages_keep_frame_and_outer_fetch_apart;
          Alcotest.test_case "default off keeps values and skips names" `Quick
            test_default_off_keeps_values_and_skips_names;
          Alcotest.test_case "opt-in report has a short-run cap" `Quick
            test_opt_in_report_is_bounded
        ] )
    ]
;;
