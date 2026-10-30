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
      ~name:"overview.layout.note" ~ms:None
    |> fun t -> Timing.Stage_samples.add_timed t ~frame:(Some 1)
      ~name:"overview.layout" ~started_ns:1000000L ~completed_ns:6000000L
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
    Timing.Samples.add_timed Timing.Samples.empty Timing.Build
      ~tag:(Some "board-read") ~started_ns:0L ~completed_ns:10000000L
      ~home_questions:None ~output:None
  in
  let residual = Timing.Stage_samples.build_residuals stages builds in
  Alcotest.(check (list (pair int int64))) "residual excludes outside-Build fetch"
    [1, 5000000L]
    (List.map (fun (row : Timing.Stage_samples.build_residual) -> row.frame, row.uncovered_ns) residual)
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

let test_output_stays_with_its_present () =
  let t =
    Timing.Samples.empty
    |> fun t -> Timing.Samples.add t Timing.Build ~tag:None ~ms:200.0
    |> fun t -> Timing.Samples.add_present t ~tag:"keeper-detail" ~ms:150.0
         ~output:{ write_ms = 10.0; flush_ms = 135.0;
                   bytes = 12345; writes = 1; flushes = 1 }
    |> fun t -> Timing.Samples.add_present t ~tag:"unchanged" ~ms:0.1
         ~output:{ write_ms = 0.0; flush_ms = 0.0;
                   bytes = 0; writes = 0; flushes = 0 }
    |> fun t -> Timing.Samples.add_present t ~tag:"keeper-list" ~ms:20.0
         ~output:{ write_ms = 18.0; flush_ms = 1.0;
                   bytes = 800; writes = 2; flushes = 1 }
  in
  let lines = Timing.Samples.summary_lines t in
  let detail = List.find (fun l -> contains l "tag=keeper-detail") lines in
  Alcotest.(check bool) "original present ordinal" true
    (contains detail "frame=1 150.00ms");
  Alcotest.(check bool) "same frame output breakdown" true
    (contains detail
       "write=10.000ms flush=135.000ms other=5.000ms bytes=12345 writes=1 flushes=1");
  let unchanged = List.find (fun l -> contains l "tag=unchanged") lines in
  Alcotest.(check bool) "unchanged has its own ordinal" true
    (contains unchanged "frame=2 0.10ms");
  Alcotest.(check bool) "unchanged does not reuse preceding output" true
    (contains unchanged
       "write=0.000ms flush=0.000ms other=0.100ms bytes=0 writes=0 flushes=0");
  let list = List.find (fun l -> contains l "tag=keeper-list") lines in
  Alcotest.(check bool) "third sample keeps its counts" true
    (contains list "frame=3 20.00ms"
     && contains list "bytes=800 writes=2 flushes=1")
;;

exception Output_failed

let test_present_keeps_callback_semantics () =
  Alcotest.(check bool) "stanza enables real recording path" true Timing.enabled;
  let calls = ref [] in
  let write text = calls := text :: !calls in
  let flush () = calls := "flush" :: !calls in
  let result = Timing.time_present ~tag:"callback-test" ~write ~flush
    (fun ~write ~flush -> write "first"; write "second"; flush (); 42)
  in
  Alcotest.(check int) "result" 42 result;
  Alcotest.(check (list string)) "write and flush order"
    ["first"; "second"; "flush"] (List.rev !calls);
  calls := [];
  ignore (Timing.time_present ~tag:"unchanged-test" ~write ~flush
    (fun ~write:_ ~flush:_ -> ()));
  Alcotest.(check (list string)) "unchanged does no IO" [] !calls;
  Alcotest.check_raises "original output failure" Output_failed (fun () ->
    Timing.time_present ~tag:"failure-test"
      ~write:(fun _ -> raise Output_failed) ~flush
      (fun ~write ~flush -> write "fails"; flush ()));
  Alcotest.(check (list string)) "failure does not flush" [] !calls;
  Alcotest.check_raises "original flush failure" Output_failed (fun () ->
    Timing.time_present ~tag:"flush-failure-test" ~write
      ~flush:(fun () -> calls := "flush-fails" :: !calls; raise Output_failed)
      (fun ~write ~flush -> write "written"; flush ()));
  Alcotest.(check (list string)) "write precedes failing flush"
    ["written"; "flush-fails"] (List.rev !calls)
;;

let test_raw_nanoseconds_and_original_owners () =
  let first = 9_007_199_254_740_993L in
  let last = Int64.add first 100_001L in
  let asks = Timing.Ask_samples.add Timing.Ask_samples.empty ~at_ns:1L ~before_build:1
    (Timing.Applied {open_count=2;rows=[
      {owner=Timing.Keeper "keeper";ask_id="shared";source_turn_ref=Some "trace#7";is_open=true};
      {owner=Timing.Installation "installation";ask_id="shared";source_turn_ref=None;is_open=true}]}) in
  let samples = Timing.Samples.add_timed Timing.Samples.empty Timing.Build ~tag:(Some "overview")
    ~started_ns:first ~completed_ns:last ~home_questions:(Some Timing.Questions_current) ~output:None in
  let json = Timing.Samples.raw_lines ~asks samples |> List.hd |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "exact start beyond float integer precision"
    (Int64.to_string first) (json |> member "started_ns" |> to_string);
  Alcotest.(check string) "exact end" (Int64.to_string last) (json |> member "completed_ns" |> to_string);
  Alcotest.(check string) "no rounded reconstruction" "100001" (json |> member "elapsed_ns" |> to_string);
  Alcotest.(check bool) "actual Home force" true (json |> member "home_forced" |> to_bool);
  Alcotest.(check int) "same Build applied event" 1 (json |> member "asks" |> member "epoch" |> to_int);
  let application = Timing.Ask_samples.raw_lines asks |> List.hd |> Yojson.Safe.from_string
    |> member "application" in
  let rows = application |> member "rows" |> to_list in
  Alcotest.(check int) "same ID keeps distinct original owners" 2 (List.length rows);
  Alcotest.(check string) "original source turn" "trace#7"
    (List.hd rows |> member "source_turn_ref" |> to_string);
  Alcotest.(check bool) "installation keeps explicit absent turn" true
    ((List.nth rows 1 |> member "source_turn_ref") = `Null)
;;

let test_reset_and_dropped_application_identity () =
  let applied = Timing.Applied {open_count=0;rows=[]} in
  let asks = Timing.Ask_samples.empty
    |> fun t -> Timing.Ask_samples.add t ~at_ns:1L ~before_build:1 applied
    |> fun t -> Timing.Ask_samples.add t ~at_ns:1L ~before_build:2 Timing.Reset
    |> fun t -> Timing.Ask_samples.add t ~at_ns:1L ~before_build:3 applied in
  let view frame = match Timing.Ask_samples.for_build asks frame with
    | Timing.Ask_samples.Unknown -> "unknown"
    | Timing.Ask_samples.Cleared epoch -> "reset:" ^ string_of_int epoch
    | Timing.Ask_samples.Current epoch -> "applied:" ^ string_of_int epoch in
  Alcotest.(check (list string)) "clock ties use successful Build boundaries"
    ["unknown";"applied:1";"reset:2";"applied:3"] (List.map view [0;1;2;3]);
  let rec fill n t = if n=0 then t else fill (n-1)
    (Timing.Ask_samples.add t ~at_ns:1L ~before_build:1 Timing.Reset) in
  let full = fill Timing.max_frames_per_phase Timing.Ask_samples.empty in
  let dropped = Timing.Ask_samples.add full ~at_ns:1L ~before_build:2 applied in
  Alcotest.(check bool) "dropped payload cannot lend stale identity" true
    (Timing.Ask_samples.for_build dropped 2 = Timing.Ask_samples.Unknown);
  Alcotest.(check bool) "earlier Build keeps its original reset" true
    (Timing.Ask_samples.for_build dropped 1 = Timing.Ask_samples.Cleared Timing.max_frames_per_phase)
;;

let test_stale_reading_keeps_snapshot_identity () =
  let asks = Timing.Ask_samples.add Timing.Ask_samples.empty ~at_ns:1L ~before_build:1
    (Timing.Applied {open_count=1;rows=[{owner=Timing.Keeper "owner";ask_id="original";
      source_turn_ref=Some "seed#1";is_open=true}]}) in
  let add samples home_questions = Timing.Samples.add_timed samples Timing.Build
    ~tag:(Some "overview") ~started_ns:1L ~completed_ns:2L ~home_questions ~output:None in
  (* Successful read, failed refresh, and recovery force different actual
     readings. No new application is fabricated for the failed refresh. *)
  let samples = add Timing.Samples.empty (Some Timing.Questions_current)
    |> fun t -> add t (Some Timing.Questions_stale)
    |> fun t -> add t (Some Timing.Questions_current)
    |> fun t -> add t None in
  let open Yojson.Safe.Util in
  let rows = Timing.Samples.raw_lines ~asks samples |> List.map Yojson.Safe.from_string in
  Alcotest.(check (list int)) "failure does not advance application epoch" [1;1;1;1]
    (List.map (fun row -> row |> member "asks" |> member "epoch" |> to_int) rows);
  Alcotest.(check (list string)) "actual reading excludes stale and unforced Home" ["current";"stale";"current";"unforced"]
    (List.map (fun row -> match member "home_questions_reading" row with
       | `Null -> "unforced" | value -> to_string value) rows)
;;

let test_raw_frame_and_stage_prefix_caps () =
  let rec add n t = if n=0 then t else add (n-1)
    (Timing.Samples.add_timed t Timing.Build ~tag:None ~started_ns:1L ~completed_ns:2L
       ~home_questions:None ~output:None) in
  let frames = add (Timing.max_frames_per_phase+1) Timing.Samples.empty in
  Alcotest.(check int) "all retained raw frames, no extra cap" Timing.max_frames_per_phase
    (Timing.Samples.raw_lines ~asks:Timing.Ask_samples.empty frames |> List.length);
  let stage = Timing.Stage_samples.add_timed Timing.Stage_samples.empty
    ~frame:(Some 1) ~name:"numeric" ~started_ns:7L ~completed_ns:8L in
  let stage = Timing.Stage_samples.add_timed stage ~frame:(Some (Timing.max_frames_per_phase+1))
    ~name:"omitted" ~started_ns:7L ~completed_ns:8L in
  let json = Timing.Stage_samples.raw_lines stage |> List.hd |> Yojson.Safe.from_string in
  Alcotest.(check int) "late stage omitted under existing cap" 1
    (Timing.Stage_samples.raw_lines stage |> List.length);
  Alcotest.(check string) "one nanosecond stage preserved" "1"
    Yojson.Safe.Util.(json |> member "elapsed_ns" |> to_string)
;;

let timed_build frames started_ns completed_ns =
  Timing.Samples.add_timed frames Timing.Build ~tag:None
    ~started_ns ~completed_ns ~home_questions:None ~output:None

let timed_stage stages frame (started_ns, completed_ns) =
  Timing.Stage_samples.add_timed stages ~frame:(Some frame) ~name:"measured"
    ~started_ns ~completed_ns

let residual_values stages frames =
  Timing.Stage_samples.build_residuals stages frames
  |> List.map (fun (row : Timing.Stage_samples.build_residual) -> row.frame, row.uncovered_ns)

let test_residual_interval_union () =
  let check windows expected =
    let stages = List.fold_left (fun t window -> timed_stage t 1 window)
      Timing.Stage_samples.empty windows in
    Alcotest.(check (list (pair int int64))) "exact uncovered wall"
      [1, expected] (residual_values stages (timed_build Timing.Samples.empty 100L 200L))
  in
  check [110L,190L; 120L,180L] 20L;
  check [170L,180L; 110L,150L; 130L,170L] 30L;
  check [110L,120L; 110L,120L; 180L,190L] 80L;
  check [100L,200L; 110L,120L] 0L;
  check [150L,150L] 100L;
  let origin = Int64.sub Int64.max_int 100L in
  let stages = timed_stage Timing.Stage_samples.empty 1
    (Int64.add origin 10L, Int64.add origin 70L) in
  Alcotest.(check (list (pair int int64))) "integer precision near signed clock bound"
    [1, 40L] (residual_values stages
      (timed_build Timing.Samples.empty origin Int64.max_int))

let test_residual_rejects_incomplete_windows () =
  let frames = timed_build Timing.Samples.empty 100L 200L in
  let stage = timed_stage Timing.Stage_samples.empty 1 (110L,120L) in
  let check stages = Alcotest.(check (list (pair int int64)))
    "no fabricated residual" [] (residual_values stages frames) in
  List.iter (fun window -> check (timed_stage stage 1 window))
    [90L,110L; 190L,210L; 140L,130L; -1L,110L];
  check (Timing.Stage_samples.add stage ~frame:(Some 1) ~name:"no-window" ~ms:(Some 1.0));
  check (Timing.Stage_samples.add Timing.Stage_samples.empty ~frame:(Some 1) ~name:"note" ~ms:None);
  List.iter (fun frames ->
    Alcotest.(check (list (pair int int64))) "invalid or untimed Build omitted" []
      (residual_values stage frames))
    [timed_build Timing.Samples.empty (-1L) 200L;
     timed_build Timing.Samples.empty 200L 100L;
     Timing.Samples.add Timing.Samples.empty Timing.Build ~tag:None ~ms:1.0];
  let stages = Timing.Stage_samples.add_timed stage ~frame:None ~name:"outside"
    ~started_ns:0L ~completed_ns:1000L
    |> fun t -> Timing.Stage_samples.add t ~frame:(Some 1) ~name:"note" ~ms:None in
  let frames = timed_build frames 300L 400L in
  Alcotest.(check (list (pair int int64))) "only complete matching Build contributes"
    [1,90L] (residual_values stages frames);
  let dropped_later = List.init Timing.max_stage_samples (fun _ -> ())
    |> List.fold_left (fun t () -> timed_stage t 2 (310L,320L)) stages in
  Alcotest.(check (list (pair int int64))) "dropped later frame preserves earlier residual"
    [1,90L] (residual_values dropped_later frames);
  let dropped_first = timed_stage stages 2 (310L,320L)
    |> fun stages -> List.init Timing.max_stage_samples (fun _ -> ())
      |> List.fold_left (fun t () -> timed_stage t 1 (110L,120L)) stages in
  Alcotest.(check (list (pair int int64))) "drop withdraws that and later Build residuals"
    [] (residual_values dropped_first frames)

let test_residual_matches_cell_oracle () =
  (* An independent occupancy oracle: each integer cell is covered if any
     input interval contains it. No interval sorting or merging in the oracle. *)
  let width = 12 in
  let intervals = List.init (width+1) (fun first ->
    List.init (width-first+1) (fun delta -> first, first+delta)) |> List.concat in
  let frames = timed_build Timing.Samples.empty 1000L 1012L in
  List.iter (fun left -> List.iter (fun right ->
    let windows = [left;right] in
    let expected = List.init width Fun.id |> List.fold_left (fun total cell ->
      if List.exists (fun (first,last) -> first <= cell && cell < last) windows
      then total else total+1) 0 in
    let stages = List.fold_left (fun t (first,last) -> timed_stage t 1
      (Int64.of_int (1000+first), Int64.of_int (1000+last))) Timing.Stage_samples.empty windows in
    Alcotest.(check (list (pair int int64))) "occupancy oracle"
      [1,Int64.of_int expected] (residual_values stages frames)
  ) intervals) intervals

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
          Alcotest.test_case "opt-in report has a short-run cap" `Quick
            test_opt_in_report_is_bounded;
          Alcotest.test_case "output stays with its present" `Quick
            test_output_stays_with_its_present;
          Alcotest.test_case "presentation keeps callback semantics" `Quick
            test_present_keeps_callback_semantics;
          Alcotest.test_case "raw time and original owner identities" `Quick
            test_raw_nanoseconds_and_original_owners;
          Alcotest.test_case "reset and dropped identity" `Quick
            test_reset_and_dropped_application_identity;
          Alcotest.test_case "stale reading retains snapshot identity" `Quick test_stale_reading_keeps_snapshot_identity;
          Alcotest.test_case "raw frame and stage prefix caps" `Quick
            test_raw_frame_and_stage_prefix_caps;
          Alcotest.test_case "nested and overlapping stage coverage" `Quick
            test_residual_interval_union;
          Alcotest.test_case "incomplete timer windows stay unknown" `Quick
            test_residual_rejects_incomplete_windows;
          Alcotest.test_case "coverage agrees with occupancy oracle" `Quick
            test_residual_matches_cell_oracle
        ] )
    ]
;;
