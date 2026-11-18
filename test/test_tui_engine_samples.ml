(* What is checked is what the engine graphs' sampler decides, never what a
   graph looks like: when a [/health] read is sent and when an answer the TUI
   already has is taken instead, what the ring keeps, what a failed read
   leaves in it, and which kind of graph a sampler with nothing read hands
   over (RFC tui-one-screen-grammar section 5.6). *)

module Samples = Masc_tui_engine_samples
module Braille = Masc_tui_braille
module Decode = Masc.Tui_decode

(* The loop polls input at most 16 ms apart. *)
let loop_step_s = 0.016

(* A read that answers this long after it is sent. *)
let read_latency_s = 0.03
let capacity = 64
let a_heap = 1_000
let a_p95_us = 250

let point ~heap ~p95 =
  { Samples.live_heap = Braille.of_count heap; scheduler_p95 = Braille.of_count p95 }

let answered_point = Samples.Answered (point ~heap:a_heap ~p95:a_p95_us)

let sample =
  Alcotest.testable
    (fun ppf sample ->
      Format.pp_print_string ppf
        (match sample with
         | Braille.Unread -> "Unread"
         | Braille.Absent -> "Absent"
         | Braille.Zero -> "Zero"
         | Braille.Value _ -> "Value"))
    ( = )

let step =
  Alcotest.testable
    (fun ppf step ->
      Format.pp_print_string ppf
        (match step with
         | Samples.Nothing -> "Nothing"
         | Samples.Sampled -> "Sampled"
         | Samples.Read -> "Read"))
    ( = )

let graph_kind = function
  | Braille.Never_read -> "Never_read"
  | Braille.Too_narrow -> "Too_narrow"
  | Braille.Drawn _ -> "Drawn"

let axis maximum = string_of_int maximum

(* Runs the loop from [from] to before [until], [loop_step_s] apart, and
   answers each read the sampler asks for after [read_latency_s]: the answer
   arrives as every [/health] answer does, as the newest one the TUI
   received, and its own read then delivers it. [visible] says whether the
   engine view is on screen at an instant. Counts the reads sent. *)
let run ?(visible = fun _ -> true) ~from ~until sampler newest =
  let reads = ref 0 in
  let pending = ref None in
  let sampler = ref sampler in
  let newest = ref newest in
  let now = ref from in
  while !now < until do
    (match !pending with
     | Some due when !now >= due ->
       newest := Some { Samples.at = !now; reading = answered_point };
       let next, _, _ = Samples.answered !sampler ~now:!now answered_point in
       sampler := next;
       pending := None
     | Some _ | None -> ());
    if visible !now then begin
      let shown = Samples.shown !sampler ~now:!now ~capacity in
      let next, decision = Samples.tick shown ~now:!now ~newest:!newest in
      sampler := next;
      match decision with
      | Samples.Read ->
        incr reads;
        pending := Some (!now +. read_latency_s)
      | Samples.Nothing | Samples.Sampled -> ()
    end
    else sampler := Samples.hidden !sampler;
    now := !now +. loop_step_s
  done;
  (!sampler, !newest, !reads)

let test_ten_seconds_on_screen_send_at_most_five_reads () =
  let sampler, _, reads = run ~from:0. ~until:10. Samples.stopped None in
  Alcotest.(check bool) "at most one read per two seconds" true (reads <= 5);
  Alcotest.(check int) "a sample every two seconds" 5
    (List.length (Samples.samples Samples.Live_heap sampler))

let test_no_read_while_the_view_is_off_screen () =
  let sampler, _, reads =
    run ~visible:(fun _ -> false) ~from:0. ~until:10. Samples.stopped None
  in
  Alcotest.(check int) "no read" 0 reads;
  Alcotest.(check int) "no sample" 0
    (List.length (Samples.samples Samples.Live_heap sampler));
  let on_screen, _, reads_on = run ~from:0. ~until:4. Samples.stopped None in
  Alcotest.(check bool) "the view read while on screen" true (reads_on > 0);
  let off_screen = Samples.hidden on_screen in
  Alcotest.(check int) "closing the view drops its samples" 0
    (List.length (Samples.samples Samples.Live_heap off_screen));
  let _, decision = Samples.tick off_screen ~now:100. ~newest:None in
  Alcotest.check step "nothing is due once it closed" Samples.Nothing decision

let test_an_answer_within_two_seconds_is_taken_without_a_read () =
  (* A refresh read [/health] half a second before the view opened. *)
  let newest = Some { Samples.at = -0.5; reading = answered_point } in
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let opened, decision = Samples.tick opened ~now:0. ~newest in
  Alcotest.check step "the first sample takes it" Samples.Sampled decision;
  (* Another refresh answers a second and a half later. *)
  let newest = Some { Samples.at = 1.5; reading = answered_point } in
  let before_due, decision = Samples.tick opened ~now:1.9 ~newest in
  Alcotest.check step "nothing before the next sample is due" Samples.Nothing decision;
  let sampled, decision = Samples.tick before_due ~now:2.0 ~newest in
  Alcotest.check step "the next sample takes it too" Samples.Sampled decision;
  (* The same answer is not taken twice: the sample after asks. *)
  let _, decision = Samples.tick sampled ~now:4.0 ~newest in
  Alcotest.check step "an answer already taken is read again" Samples.Read decision

let test_an_answer_older_than_two_seconds_is_read_again () =
  let newest = Some { Samples.at = -2.5; reading = answered_point } in
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let _, decision = Samples.tick opened ~now:0. ~newest in
  Alcotest.check step "too old to stand for now" Samples.Read decision

let test_one_read_is_out_at_a_time () =
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, decision = Samples.tick opened ~now:0. ~newest:None in
  Alcotest.check step "the first sample asks" Samples.Read decision;
  (* Its answer takes ten seconds; the view closes and opens again. *)
  let reopened = Samples.shown (Samples.hidden asked) ~now:5. ~capacity in
  let _, decision = Samples.tick reopened ~now:5. ~newest:None in
  Alcotest.check step "the read already out answers the new view" Samples.Nothing decision

let test_the_ring_keeps_the_graph_width_and_drops_the_oldest () =
  let ring =
    List.fold_left (fun ring item -> Samples.Ring.push item ring)
      (Samples.Ring.empty ~capacity:4) [ 1; 2; 3; 4; 5; 6 ]
  in
  Alcotest.(check (list int)) "the newest four, oldest first" [ 3; 4; 5; 6 ]
    (Samples.Ring.to_list ring);
  Alcotest.(check (list int)) "a narrower graph keeps the newest" [ 5; 6 ]
    (Samples.Ring.to_list (Samples.Ring.resize ~capacity:2 ring));
  (* Through the sampler: six samples, two seconds apart, in room for four. *)
  let heap_at at = Samples.Answered (point ~heap:(Float.to_int at + 1) ~p95:a_p95_us) in
  let width = 4 in
  let rec every_interval sampler at =
    if at > 10. then sampler
    else
      let shown = Samples.shown sampler ~now:at ~capacity:width in
      let newest = Some { Samples.at; reading = heap_at at } in
      let next, _ = Samples.tick shown ~now:at ~newest in
      every_interval next (at +. Samples.interval_s)
  in
  let sampler = every_interval Samples.stopped 0. in
  Alcotest.(check (list sample)) "the four newest samples"
    (List.map Braille.of_count [ 5; 7; 9; 11 ])
    (Samples.samples Samples.Live_heap sampler)

let test_a_failed_read_is_a_blank_and_said_once () =
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, _ = Samples.tick opened ~now:0. ~newest:None in
  let failed, decision, report =
    Samples.answered asked ~now:0.03 (Samples.Failed "server identity load failed: refused")
  in
  Alcotest.check step "the failure is a sample" Samples.Sampled decision;
  Alcotest.(check (list sample)) "a blank heap" [ Braille.Absent ]
    (Samples.samples Samples.Live_heap failed);
  Alcotest.(check (list sample)) "a blank p95" [ Braille.Absent ]
    (Samples.samples Samples.Scheduler_p95 failed);
  Alcotest.(check bool) "the first failure is said" true
    (match report with
     | Samples.Failure_began _ -> true
     | Samples.Quiet -> false);
  let asked, _ = Samples.tick failed ~now:2.0 ~newest:None in
  let _, _, report =
    Samples.answered asked ~now:2.03 (Samples.Failed "server identity load failed: refused")
  in
  Alcotest.(check bool) "the failure that follows is not said again" true
    (match report with
     | Samples.Quiet -> true
     | Samples.Failure_began _ -> false);
  Alcotest.(check bool) "a graph of failed reads is not one never read" true
    (match Samples.graph ~width:32 ~axis Samples.Live_heap failed with
     | Braille.Drawn _ -> true
     | Braille.Never_read | Braille.Too_narrow -> false)

let test_a_graph_never_read_is_the_unread_variant () =
  Alcotest.(check string) "closed" "Never_read"
    (graph_kind (Samples.graph ~width:32 ~axis Samples.Live_heap Samples.stopped));
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, _ = Samples.tick opened ~now:0. ~newest:None in
  Alcotest.(check string) "opened, its read still out" "Never_read"
    (graph_kind (Samples.graph ~width:32 ~axis Samples.Scheduler_p95 asked));
  Alcotest.(check string) "narrower than four cells, still never read" "Never_read"
    (graph_kind (Samples.graph ~width:2 ~axis Samples.Scheduler_p95 asked));
  let read, _, _ = Samples.answered asked ~now:0.03 answered_point in
  Alcotest.(check string) "read" "Drawn"
    (graph_kind (Samples.graph ~width:32 ~axis Samples.Scheduler_p95 read));
  Alcotest.(check string) "read, with no room for dots" "Too_narrow"
    (graph_kind (Samples.graph ~width:3 ~axis Samples.Scheduler_p95 read))

let test_times_without_a_sample_are_blank () =
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, _ = Samples.tick opened ~now:0. ~newest:None in
  (* The read takes five seconds: the samples due at 2 s and 4 s took
     nothing. *)
  let read, _, _ = Samples.answered asked ~now:5. answered_point in
  Alcotest.(check (list sample)) "two blanks before the answer"
    [ Braille.Absent; Braille.Absent; Braille.of_count a_heap ]
    (Samples.samples Samples.Live_heap read)

let identity ~gc ~scheduler =
  { Decode.sid_version = "0.0.0"
  ; sid_binary_commit = "deadbeef"
  ; sid_binary_commit_age_s = None
  ; sid_runtime_instance_id = None
  ; sid_base_path = Decode.Canonical_path.of_path "/tmp"
  ; sid_masc_root = Decode.Canonical_path.of_path "/tmp"
  ; sid_executable_in_worktree = None
  ; sid_state_ready = None
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = gc
  ; sid_scheduler = scheduler
  ; sid_operator_action = None
  }

let scheduler ~samples ~p95_ms =
  { Decode.ssch_probe = None
  ; ssch_samples = samples
  ; ssch_p50_ms = 0.
  ; ssch_p95_ms = p95_ms
  ; ssch_p99_ms = 0.
  ; ssch_max_ms = 0.
  ; ssch_mean_ms = 0.
  ; ssch_stalls = 0
  ; ssch_pool_domains = None
  }

let gc ~live_words =
  { Decode.sgc_heap_words = 2 * live_words
  ; sgc_live_words = live_words
  ; sgc_minor_heap_size = 0
  ; sgc_minor_collections = 0
  ; sgc_major_collections = 0
  ; sgc_forced_major_collections = 0
  ; sgc_compactions = 0
  ; sgc_minor_words = 0.
  ; sgc_promoted_words = 0.
  ; sgc_major_words = 0.
  }

let point_of = function
  | Samples.Answered point -> Some point
  | Samples.Failed _ -> None

let test_a_reading_holds_the_two_card_numbers () =
  let reported =
    Samples.reading_of_identity
      (Ok (identity ~gc:(Some (gc ~live_words:a_heap))
             ~scheduler:(Some (scheduler ~samples:3 ~p95_ms:0.25))))
  in
  Alcotest.(check (option sample)) "live heap" (Some (Braille.of_count a_heap))
    (Option.map (fun (p : Samples.point) -> p.live_heap) (point_of reported));
  Alcotest.(check (option sample)) "p95 in whole microseconds"
    (Some (Braille.of_count a_p95_us))
    (Option.map (fun (p : Samples.point) -> p.scheduler_p95) (point_of reported));
  let no_latency =
    Samples.reading_of_identity
      (Ok (identity ~gc:None ~scheduler:(Some (scheduler ~samples:0 ~p95_ms:0.))))
  in
  Alcotest.(check (option sample)) "a window with no latency sample is no p95"
    (Some Braille.Absent)
    (Option.map (fun (p : Samples.point) -> p.scheduler_p95) (point_of no_latency));
  Alcotest.(check (option sample)) "an unreported heap is no heap" (Some Braille.Absent)
    (Option.map (fun (p : Samples.point) -> p.live_heap) (point_of no_latency));
  Alcotest.(check bool) "a failed read is a failure" true
    (Option.is_none (point_of (Samples.reading_of_identity (Error "refused"))));
  Alcotest.(check (option sample)) "the account server reports no engine"
    (Some Braille.Absent)
    (Option.map (fun (p : Samples.point) -> p.live_heap)
       (point_of
          (Samples.reading_of_server
             (Ok (Decode.Account_server { account_server_version = "1" })))))

let count_sampled steps =
  List.length (List.filter (fun decision -> decision = Samples.Sampled) steps)

(* The loader records every [/health] answer as the newest before the loop
   applies the read's own message, and the loop ticks in between. That one
   answer is one sample. *)
let test_the_own_answer_seen_early_is_one_sample () =
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, decision = Samples.tick opened ~now:0. ~newest:None in
  Alcotest.check step "the first sample asks" Samples.Read decision;
  let newest = Some { Samples.at = 0.02; reading = answered_point } in
  let between, early = Samples.tick asked ~now:0.025 ~newest in
  let applied, on_apply, _ = Samples.answered between ~now:0.03 answered_point in
  let after, late = Samples.tick applied ~now:0.035 ~newest in
  Alcotest.(check int) "one sample for one answer" 1 (count_sampled [ early; on_apply; late ]);
  Alcotest.(check int) "one time held" 1
    (List.length (Samples.samples Samples.Live_heap after));
  let _, next = Samples.tick after ~now:2.0 ~newest in
  Alcotest.check step "the answer taken is not taken again" Samples.Read next

(* Another reader's answer while the sampler's own read is out sends no
   second read. *)
let test_another_answer_while_the_read_is_out_sends_no_read () =
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, _ = Samples.tick opened ~now:0. ~newest:None in
  let refresh = Some { Samples.at = 0.5; reading = answered_point } in
  let waiting, first = Samples.tick asked ~now:0.6 ~newest:refresh in
  let _, second = Samples.tick waiting ~now:1.9 ~newest:refresh in
  Alcotest.(check bool) "no read while one is out" false
    (List.exists (fun decision -> decision = Samples.Read) [ first; second ])

(* A read still out when the view closed does not hold the next opening's
   reads: its answer takes no sample, and the next due sample reads. *)
let test_a_read_out_when_the_view_closed_does_not_hold_the_next () =
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, _ = Samples.tick opened ~now:0. ~newest:None in
  let answered, decision, _ =
    Samples.answered (Samples.hidden asked) ~now:0.03 answered_point
  in
  Alcotest.check step "a closed view takes no sample" Samples.Nothing decision;
  Alcotest.(check int) "and holds none" 0
    (List.length (Samples.samples Samples.Live_heap answered));
  let reopened = Samples.shown answered ~now:10. ~capacity in
  let newest = Some { Samples.at = 0.03; reading = answered_point } in
  let _, decision = Samples.tick reopened ~now:10. ~newest in
  Alcotest.check step "the next opening reads" Samples.Read decision

(* A view opened again within two seconds of an answer takes that answer. *)
let test_a_view_reopened_within_two_seconds_takes_the_answer () =
  let opened = Samples.shown Samples.stopped ~now:0. ~capacity in
  let asked, _ = Samples.tick opened ~now:0. ~newest:None in
  let read, _, _ = Samples.answered asked ~now:0.03 answered_point in
  let newest = Some { Samples.at = 0.03; reading = answered_point } in
  let reopened = Samples.shown (Samples.hidden read) ~now:1.0 ~capacity in
  let _, decision = Samples.tick reopened ~now:1.0 ~newest in
  Alcotest.check step "taken without a read" Samples.Sampled decision

let () =
  Alcotest.run "tui_engine_samples"
    [ ( "requests"
      , [ Alcotest.test_case "ten seconds on screen send at most five reads" `Quick
            test_ten_seconds_on_screen_send_at_most_five_reads
        ; Alcotest.test_case "no read while the view is off screen" `Quick
            test_no_read_while_the_view_is_off_screen
        ; Alcotest.test_case "an answer within two seconds is taken without a read" `Quick
            test_an_answer_within_two_seconds_is_taken_without_a_read
        ; Alcotest.test_case "an answer older than two seconds is read again" `Quick
            test_an_answer_older_than_two_seconds_is_read_again
        ; Alcotest.test_case "one read is out at a time" `Quick test_one_read_is_out_at_a_time
        ; Alcotest.test_case "the own answer seen early is one sample" `Quick
            test_the_own_answer_seen_early_is_one_sample
        ; Alcotest.test_case "another answer while the read is out sends no read" `Quick
            test_another_answer_while_the_read_is_out_sends_no_read
        ; Alcotest.test_case "a read out when the view closed does not hold the next" `Quick
            test_a_read_out_when_the_view_closed_does_not_hold_the_next
        ; Alcotest.test_case "a view reopened within two seconds takes the answer" `Quick
            test_a_view_reopened_within_two_seconds_takes_the_answer
        ] )

    ; ( "samples"
      , [ Alcotest.test_case "the ring keeps the graph width and drops the oldest" `Quick
            test_the_ring_keeps_the_graph_width_and_drops_the_oldest
        ; Alcotest.test_case "a failed read is a blank, said once" `Quick
            test_a_failed_read_is_a_blank_and_said_once
        ; Alcotest.test_case "a graph never read is the unread variant" `Quick
            test_a_graph_never_read_is_the_unread_variant
        ; Alcotest.test_case "times without a sample are blank" `Quick
            test_times_without_a_sample_are_blank
        ; Alcotest.test_case "a reading holds the two card numbers" `Quick
            test_a_reading_holds_the_two_card_numbers
        ] )
    ]
