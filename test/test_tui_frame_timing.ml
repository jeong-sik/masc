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
            test_ordinals_count_per_phase
        ] )
    ]
;;
