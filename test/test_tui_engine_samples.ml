(* What is checked is what the engine graphs' sampler decides, never what a
   graph looks like: when a [/health] read is sent and when an answer the TUI
   already has is taken instead, what the ring keeps, what a failed read
   leaves in it, and which kind of graph a sampler with nothing read hands
   over (RFC tui-one-screen-grammar section 5.6). *)

module Samples = Masc_tui_engine_samples

(* Instants on the loop's clock as seconds after a base far enough past
   the clock's start that the times before a view opens stay on it. *)
let base = Masc_tui_wake.Mono.after (Masc_tui_wake.Mono.now ()) 100.
let instant s = Masc_tui_wake.Mono.after base (s +. 100.)
module Braille = Masc_tui_braille
module Decode = Masc.Tui_decode

(* These tests read what a graph draws, not its colour. *)
let no_tint : Braille.tint = fun _ -> ""

(* The test runs a pass this often, one frame interval: more often than the
   sampler needs, so a sample is never late because of the step. *)
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

(* The axis column the graphs under test give their top. *)
let axis_cells = 4

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
       newest := Some { Samples.at = instant (!now); reading = answered_point };
       let next, _, _ = Samples.answered !sampler ~now:(instant !now) answered_point in
       sampler := next;
       pending := None
     | Some _ | None -> ());
    if visible !now then begin
      let shown = Samples.shown !sampler ~now:(instant !now) ~capacity in
      let next, decision = Samples.tick shown ~now:(instant !now) ~newest:!newest in
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
  let _, decision = Samples.tick off_screen ~now:(instant 100.) ~newest:None in
  Alcotest.check step "nothing is due once it closed" Samples.Nothing decision

let test_an_answer_within_two_seconds_is_taken_without_a_read () =
  (* A refresh read [/health] half a second before the view opened. *)
  let newest = Some { Samples.at = instant (-0.5); reading = answered_point } in
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let opened, decision = Samples.tick opened ~now:(instant 0.) ~newest in
  Alcotest.check step "the first sample takes it" Samples.Sampled decision;
  (* Another refresh answers a second and a half later. *)
  let newest = Some { Samples.at = instant (1.5); reading = answered_point } in
  let before_due, decision = Samples.tick opened ~now:(instant 1.9) ~newest in
  Alcotest.check step "nothing before the next sample is due" Samples.Nothing decision;
  let sampled, decision = Samples.tick before_due ~now:(instant 2.0) ~newest in
  Alcotest.check step "the next sample takes it too" Samples.Sampled decision;
  (* The same answer is not taken twice: the sample after asks. *)
  let _, decision = Samples.tick sampled ~now:(instant 4.0) ~newest in
  Alcotest.check step "an answer already taken is read again" Samples.Read decision

let test_an_answer_older_than_two_seconds_is_read_again () =
  let newest = Some { Samples.at = instant (-2.5); reading = answered_point } in
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let _, decision = Samples.tick opened ~now:(instant 0.) ~newest in
  Alcotest.check step "too old to stand for now" Samples.Read decision

let test_retry_wait_keeps_sample_slots_without_starting_a_read () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let blank, decision = Samples.tick ~allow_read:false opened ~now:(instant 0.) ~newest:None in
  Alcotest.check step "the first slot is recorded without a read" Samples.Sampled decision;
  Alcotest.(check (list sample)) "the slot is blank" [ Braille.Absent ]
    (Samples.samples Samples.Live_heap blank);
  let newest = Some { Samples.at = instant (1.5); reading = answered_point } in
  let recorded, decision = Samples.tick ~allow_read:false blank ~now:(instant 2.) ~newest in
  Alcotest.check step "an existing answer fills a due slot" Samples.Sampled decision;
  Alcotest.(check (list sample)) "the blank and the measured slot are kept"
    [ Braille.Absent; Braille.of_count a_heap ]
    (Samples.samples Samples.Live_heap recorded);
  let _, decision = Samples.tick recorded ~now:(instant 4.) ~newest:None in
  Alcotest.check step "a new read starts once the wait is over" Samples.Read decision

let test_one_read_is_out_at_a_time () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, decision = Samples.tick opened ~now:(instant 0.) ~newest:None in
  Alcotest.check step "the first sample asks" Samples.Read decision;
  (* Its answer takes ten seconds; the view closes and opens again. *)
  let reopened = Samples.shown (Samples.hidden asked) ~now:(instant 5.) ~capacity in
  let _, decision = Samples.tick reopened ~now:(instant 5.) ~newest:None in
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
      let shown = Samples.shown sampler ~now:(instant at) ~capacity:width in
      let newest = Some { Samples.at = instant at; reading = heap_at at } in
      let next, _ = Samples.tick shown ~now:(instant at) ~newest in
      every_interval next (at +. Samples.interval_s)
  in
  let sampler = every_interval Samples.stopped 0. in
  Alcotest.(check (list sample)) "the four newest samples"
    (List.map Braille.of_count [ 5; 7; 9; 11 ])
    (Samples.samples Samples.Live_heap sampler)

let test_a_failed_read_is_a_blank_and_said_once () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, _ = Samples.tick opened ~now:(instant 0.) ~newest:None in
  let failed, decision, report =
    Samples.answered asked ~now:(instant 0.03) (Samples.Failed "server identity load failed: refused")
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
  let asked, _ = Samples.tick failed ~now:(instant 2.0) ~newest:None in
  let _, _, report =
    Samples.answered asked ~now:(instant 2.03) (Samples.Failed "server identity load failed: refused")
  in
  Alcotest.(check bool) "the failure that follows is not said again" true
    (match report with
     | Samples.Quiet -> true
     | Samples.Failure_began _ -> false);
  Alcotest.(check bool) "a graph of failed reads is not one never read" true
    (match Samples.graph ~tint:no_tint ~width:32 ~axis_cells ~axis Samples.Live_heap failed with
     | Braille.Drawn _ -> true
     | Braille.Never_read | Braille.Too_narrow -> false)

let test_a_graph_never_read_is_the_unread_variant () =
  Alcotest.(check string) "closed" "Never_read"
    (graph_kind (Samples.graph ~tint:no_tint ~width:32 ~axis_cells ~axis Samples.Live_heap Samples.stopped));
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, _ = Samples.tick opened ~now:(instant 0.) ~newest:None in
  Alcotest.(check string) "opened, its read still out" "Never_read"
    (graph_kind (Samples.graph ~tint:no_tint ~width:32 ~axis_cells ~axis Samples.Scheduler_p95 asked));
  Alcotest.(check string) "narrower than four cells, still never read" "Never_read"
    (graph_kind (Samples.graph ~tint:no_tint ~width:2 ~axis_cells ~axis Samples.Scheduler_p95 asked));
  let read, _, _ = Samples.answered asked ~now:(instant 0.03) answered_point in
  Alcotest.(check string) "read" "Drawn"
    (graph_kind (Samples.graph ~tint:no_tint ~width:32 ~axis_cells ~axis Samples.Scheduler_p95 read));
  Alcotest.(check string) "read, with no room for dots" "Too_narrow"
    (graph_kind (Samples.graph ~tint:no_tint ~width:3 ~axis_cells ~axis Samples.Scheduler_p95 read))

let test_times_without_a_sample_are_blank () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, _ = Samples.tick opened ~now:(instant 0.) ~newest:None in
  (* The read takes five seconds: the samples due at 2 s and 4 s took
     nothing. *)
  let read, _, _ = Samples.answered asked ~now:(instant 5.) answered_point in
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

(* One sample every two seconds, each from the newest answer, in order. *)
let sampled_readings ~capacity readings =
  let sampler, _ =
    List.fold_left
      (fun (sampler, at) reading ->
        let newest = Some { Samples.at = instant at; reading } in
        let next, _ = Samples.tick (Samples.shown sampler ~now:(instant at) ~capacity) ~now:(instant at) ~newest in
        (next, at +. Samples.interval_s))
      (Samples.stopped, 0.) readings
  in
  sampler

let heap_reading heap = Samples.Answered (point ~heap ~p95:a_p95_us)
let sampled_heaps ~capacity heaps = sampled_readings ~capacity (List.map heap_reading heaps)

(* The top the graph hands its axis, or [None] when it asks for none. *)
let axis_top ~width series sampler =
  let top = ref None in
  ignore
    (Samples.graph ~tint:no_tint ~width ~axis_cells
       ~axis:(fun maximum -> top := Some maximum; axis maximum)
       series sampler);
  !top

let heap_top heaps = axis_top ~width:32 Samples.Live_heap (sampled_heaps ~capacity heaps)

(* Heaps, in words, well above the 1 MiB floor (131,072 words). *)
let steady = 1_000_000
let first_top = 1_300_000
let high = 2_000_000
let low = 100_000
let heap_floor_words = 131_072

let repeat count value = List.init count (fun _ -> value)

(* The ring sized as the graph draws keeps those times and no more. *)
let test_a_ring_as_wide_as_the_graph_keeps_only_the_times_drawn () =
  let width = 12 in
  let capacity = Braille.graph_times ~width ~axis_cells in
  let sampler = sampled_heaps ~capacity (high :: repeat capacity steady) in
  Alcotest.(check int) "the times the graph draws" capacity
    (List.length (Samples.samples Samples.Live_heap sampler))

let test_the_first_time_sets_the_top () =
  Alcotest.(check (option int)) "1.3 times the first time" (Some first_top) (heap_top [ steady ])

(* One time above the top draws at the top and leaves the axis where it was. *)
let test_one_time_above_does_not_move_the_top () =
  Alcotest.(check (option int)) "four times above" (Some first_top)
    (heap_top ((steady :: repeat 4 high) @ [ steady ]))

let test_five_times_above_raise_the_top () =
  Alcotest.(check (option int)) "1.3 times the average of the five newest" (Some 2_600_000)
    (heap_top (steady :: repeat 5 high))

(* A spike that left the graph does not hold the axis up for ever: five times
   under a tenth of the top bring it down to three times their average. *)
let test_five_low_times_lower_the_top () =
  Alcotest.(check (option int)) "under a tenth, four times" (Some 13_000_000)
    (heap_top (10_000_000 :: repeat 4 steady));
  Alcotest.(check (option int)) "3 times the average of the five newest" (Some 3_000_000)
    (heap_top (10_000_000 :: repeat 5 steady))

(* A time on the other side takes one off the count, so times that swing
   across the band do not move the axis. *)
let test_a_time_on_the_other_side_takes_one_off () =
  let swinging = steady :: (repeat 4 high @ [ low ] @ [ high ]) in
  Alcotest.(check (option int)) "four above, one low, one above: four" (Some first_top)
    (heap_top swinging);
  (* The five newest: four at 2,000,000 and one at 100,000, averaging
     1,620,000. *)
  Alcotest.(check (option int)) "the fifth then raises it" (Some 2_106_000)
    (heap_top (swinging @ [ high ]))

(* A failed read is a blank time, which counts for neither side. *)
let test_blanks_count_for_neither_side () =
  let failed = Samples.Failed "server identity load failed: refused" in
  let readings =
    heap_reading steady
    :: List.concat_map (fun _ -> [ heap_reading high; failed ]) (repeat 4 ())
  in
  let sampler = sampled_readings ~capacity readings in
  Alcotest.(check (option int)) "four above among four blanks" (Some first_top)
    (axis_top ~width:32 Samples.Live_heap sampler)

let test_the_top_never_goes_under_the_floor () =
  Alcotest.(check (option int)) "a measured zero tops the floor" (Some heap_floor_words)
    (heap_top [ 0 ]);
  Alcotest.(check (option int)) "a top at the floor counts no time as low" (Some heap_floor_words)
    (heap_top (repeat 12 0));
  Alcotest.(check (option int)) "lowering stops at the floor" (Some heap_floor_words)
    (heap_top (10_000_000 :: repeat 5 10))

(* A graph whose times were all blank measured nothing, so it has no top. *)
let test_a_graph_with_nothing_measured_has_no_top () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, _ = Samples.tick opened ~now:(instant 0.) ~newest:None in
  let failed, _, _ =
    Samples.answered asked ~now:(instant 0.03) (Samples.Failed "server identity load failed: refused")
  in
  Alcotest.(check (option int)) "failed reads ask for no top" None
    (axis_top ~width:32 Samples.Live_heap failed);
  let unreported =
    Samples.reading_of_identity
      (Ok (identity ~gc:None ~scheduler:(Some (scheduler ~samples:0 ~p95_ms:0.))))
  in
  let asked, _ = Samples.tick failed ~now:(instant 2.0) ~newest:None in
  let unreported, _, _ = Samples.answered asked ~now:(instant 2.03) unreported in
  Alcotest.(check (option int)) "an unreported p95 asks for no top" None
    (axis_top ~width:32 Samples.Scheduler_p95 unreported)

(* Closing the view forgets the top; the next opening starts from its first
   time. *)
let test_a_reopened_view_sets_its_top_again () =
  let sampler = sampled_heaps ~capacity (repeat 6 10_000_000) in
  let reopened = Samples.shown (Samples.hidden sampler) ~now:(instant 100.) ~capacity in
  let newest = Some { Samples.at = instant (100.); reading = heap_reading steady } in
  let reopened, _ = Samples.tick reopened ~now:(instant 100.) ~newest in
  Alcotest.(check (option int)) "1.3 times the first time after reopening" (Some first_top)
    (axis_top ~width:32 Samples.Live_heap reopened)

let count_sampled steps =
  List.length (List.filter (fun decision -> decision = Samples.Sampled) steps)

(* The loader records every [/health] answer as the newest before the loop
   applies the read's own message, and the loop ticks in between. That one
   answer is one sample. *)
let test_the_own_answer_seen_early_is_one_sample () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, decision = Samples.tick opened ~now:(instant 0.) ~newest:None in
  Alcotest.check step "the first sample asks" Samples.Read decision;
  let newest = Some { Samples.at = instant (0.02); reading = answered_point } in
  let between, early = Samples.tick asked ~now:(instant 0.025) ~newest in
  let applied, on_apply, _ = Samples.answered between ~now:(instant 0.03) answered_point in
  let after, late = Samples.tick applied ~now:(instant 0.035) ~newest in
  Alcotest.(check int) "one sample for one answer" 1 (count_sampled [ early; on_apply; late ]);
  Alcotest.(check int) "one time held" 1
    (List.length (Samples.samples Samples.Live_heap after));
  let _, next = Samples.tick after ~now:(instant 2.0) ~newest in
  Alcotest.check step "the answer taken is not taken again" Samples.Read next

(* Another reader's answer while the sampler's own read is out sends no
   second read. *)
let test_another_answer_while_the_read_is_out_sends_no_read () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, _ = Samples.tick opened ~now:(instant 0.) ~newest:None in
  let refresh = Some { Samples.at = instant (0.5); reading = answered_point } in
  let waiting, first = Samples.tick asked ~now:(instant 0.6) ~newest:refresh in
  let _, second = Samples.tick waiting ~now:(instant 1.9) ~newest:refresh in
  Alcotest.(check bool) "no read while one is out" false
    (List.exists (fun decision -> decision = Samples.Read) [ first; second ])

(* A read still out when the view closed does not hold the next opening's
   reads: its answer takes no sample, and the next due sample reads. *)
let test_a_read_out_when_the_view_closed_does_not_hold_the_next () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, _ = Samples.tick opened ~now:(instant 0.) ~newest:None in
  let answered, decision, _ =
    Samples.answered (Samples.hidden asked) ~now:(instant 0.03) answered_point
  in
  Alcotest.check step "a closed view takes no sample" Samples.Nothing decision;
  Alcotest.(check int) "and holds none" 0
    (List.length (Samples.samples Samples.Live_heap answered));
  let reopened = Samples.shown answered ~now:(instant 10.) ~capacity in
  let newest = Some { Samples.at = instant (0.03); reading = answered_point } in
  let _, decision = Samples.tick reopened ~now:(instant 10.) ~newest in
  Alcotest.check step "the next opening reads" Samples.Read decision

(* A view opened again within two seconds of an answer takes that answer. *)
let test_a_view_reopened_within_two_seconds_takes_the_answer () =
  let opened = Samples.shown Samples.stopped ~now:(instant 0.) ~capacity in
  let asked, _ = Samples.tick opened ~now:(instant 0.) ~newest:None in
  let read, _, _ = Samples.answered asked ~now:(instant 0.03) answered_point in
  let newest = Some { Samples.at = instant (0.03); reading = answered_point } in
  let reopened = Samples.shown (Samples.hidden read) ~now:(instant 1.0) ~capacity in
  let _, decision = Samples.tick reopened ~now:(instant 1.0) ~newest in
  Alcotest.check step "taken without a read" Samples.Sampled decision

(* Times under a tenth of the top pile up; a time above takes one off them,
   so the low time after it is the fifth only one sample later. *)
let test_a_time_above_takes_one_off_the_low_count () =
  let just_above = 13_000_001 in
  let swinging = 10_000_000 :: (repeat 4 steady @ [ just_above; steady ]) in
  Alcotest.(check (option int)) "four low, one above, one low: four" (Some 13_000_000)
    (heap_top swinging);
  (* The five newest: four at 1,000,000 and one at 13,000,001, averaging
     3,400,000. *)
  Alcotest.(check (option int)) "the fifth then lowers it" (Some 10_200_000)
    (heap_top (swinging @ [ steady ]))

(* A count with nothing on it stays at nothing: a time on the other side
   does not put it in debt. *)
let test_a_count_at_nothing_stays_at_nothing () =
  Alcotest.(check (option int)) "one above, then five low" (Some 3_000_000)
    (heap_top ((10_000_000 :: [ 13_000_001 ]) @ repeat 5 steady));
  Alcotest.(check (option int)) "one low, then five above" (Some 2_600_000)
    (heap_top ((steady :: [ low ]) @ repeat 5 high))

(* A time on the top, or on a tenth of it, is inside the band. *)
let test_a_time_on_the_band_edge_counts_for_neither_side () =
  Alcotest.(check (option int)) "five times at the top" (Some first_top)
    (heap_top (steady :: repeat 5 first_top));
  Alcotest.(check (option int)) "five times at a tenth of the top" (Some first_top)
    (heap_top (steady :: repeat 5 (first_top / 10)))

(* A top at the floor counts no time as low, so a low time there takes
   nothing off the times above. *)
let test_a_low_time_at_the_floor_takes_nothing_off () =
  let above_floor = 200_000 in
  (* The five newest: three at 200,000 and two at 0, averaging 120,000. *)
  Alcotest.(check (option int)) "five above among four zeros" (Some 156_000)
    (heap_top (0 :: (List.concat (repeat 4 [ above_floor; 0 ]) @ [ above_floor ])))

(* A move starts both counts again: one time above the raised top does not
   move it. *)
let test_a_moved_top_counts_from_nothing () =
  Alcotest.(check (option int)) "one time above the raised top" (Some 2_600_000)
    (heap_top ((steady :: repeat 5 high) @ [ 3_000_000 ]))

(* Blanks count for neither side and stand for no time in the average: the
   five newest measured times reach back past them. *)
let test_the_average_takes_the_five_newest_measured_times () =
  let failed = Samples.Failed "server identity load failed: refused" in
  let above = [ 2_000_000; 2_000_000; 2_000_000; 3_000_000; 4_000_000 ] in
  let readings =
    heap_reading steady
    :: List.concat_map (fun heap -> [ heap_reading heap; failed ]) above
  in
  (* Five above, a blank after each: 1.3 times their average of 2,600,000. *)
  Alcotest.(check (option int)) "five above among five blanks" (Some 3_380_000)
    (axis_top ~width:32 Samples.Live_heap (sampled_readings ~capacity readings))

(* A top past the integer range stands at the largest integer. *)
let test_a_top_past_the_integer_range_stands_at_the_largest () =
  Alcotest.(check (option int)) "1.3 times the largest integer" (Some max_int)
    (heap_top [ max_int ])

(* The graph's room changing is not the view closing: the top stays. *)
let test_a_resized_graph_keeps_its_top () =
  let sampler = sampled_heaps ~capacity [ steady ] in
  let at = Samples.interval_s in
  let narrower = Samples.shown sampler ~now:(instant at) ~capacity:8 in
  Alcotest.(check (option int)) "the same top in less room" (Some first_top)
    (axis_top ~width:32 Samples.Live_heap narrower);
  let newest = Some { Samples.at = instant at; reading = heap_reading 1_200_000 } in
  let sampled, _ = Samples.tick narrower ~now:(instant at) ~newest in
  Alcotest.(check (option int)) "a time inside the band leaves it" (Some first_top)
    (axis_top ~width:32 Samples.Live_heap sampled)

(* A held top whose times all left the graph has no time under it to stand
   for, so it is not written. *)
let test_a_top_over_blanks_only_is_not_written () =
  let width = 12 in
  let times = Braille.graph_times ~width ~axis_cells in
  let failed = Samples.Failed "server identity load failed: refused" in
  let sampler = sampled_readings ~capacity:times (heap_reading steady :: repeat times failed) in
  Alcotest.(check (option int)) "no top over blanks" None
    (axis_top ~width Samples.Live_heap sampler)

(* A time above the top draws at the top until the axis rises, so how far
   above it is moves no dot: two graphs that differ only there draw alike. *)
let test_how_far_above_the_top_moves_no_dot () =
  let graph heaps =
    Samples.graph ~tint:no_tint ~width:32 ~axis_cells ~axis Samples.Live_heap
      (sampled_heaps ~capacity heaps)
  in
  Alcotest.(check bool) "four times a little or far above" true
    (graph (steady :: repeat 4 1_400_000) = graph (steady :: repeat 4 10_000_000))

(* Times near the integer range average without wrapping: four at the
   largest and one in band rescale to the largest, not to a wrapped small
   sum. *)
let test_an_average_near_the_integer_range_does_not_wrap () =
  Alcotest.(check (option int)) "the fifth time above" (Some max_int)
    (heap_top ([ steady ] @ repeat 4 max_int @ [ steady; max_int ]))

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
        ; Alcotest.test_case "retry wait keeps the slots without new reads" `Quick
            test_retry_wait_keeps_sample_slots_without_starting_a_read
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
        ; Alcotest.test_case "a ring as wide as the graph keeps only the times drawn" `Quick
            test_a_ring_as_wide_as_the_graph_keeps_only_the_times_drawn
        ; Alcotest.test_case "a graph with nothing measured has no top" `Quick
            test_a_graph_with_nothing_measured_has_no_top
        ] )
    ; ( "axis"
      , [ Alcotest.test_case "the first time sets the top" `Quick test_the_first_time_sets_the_top
        ; Alcotest.test_case "one time above does not move the top" `Quick
            test_one_time_above_does_not_move_the_top
        ; Alcotest.test_case "five times above raise the top" `Quick
            test_five_times_above_raise_the_top
        ; Alcotest.test_case "five low times lower the top" `Quick test_five_low_times_lower_the_top
        ; Alcotest.test_case "a time on the other side takes one off" `Quick
            test_a_time_on_the_other_side_takes_one_off
        ; Alcotest.test_case "blanks count for neither side" `Quick
            test_blanks_count_for_neither_side
        ; Alcotest.test_case "the top never goes under the floor" `Quick
            test_the_top_never_goes_under_the_floor
        ; Alcotest.test_case "a reopened view sets its top again" `Quick
            test_a_reopened_view_sets_its_top_again
        ; Alcotest.test_case "a time above takes one off the low count" `Quick
            test_a_time_above_takes_one_off_the_low_count
        ; Alcotest.test_case "a count at nothing stays at nothing" `Quick
            test_a_count_at_nothing_stays_at_nothing
        ; Alcotest.test_case "a time on the band edge counts for neither side" `Quick
            test_a_time_on_the_band_edge_counts_for_neither_side
        ; Alcotest.test_case "a low time at the floor takes nothing off" `Quick
            test_a_low_time_at_the_floor_takes_nothing_off
        ; Alcotest.test_case "a moved top counts from nothing" `Quick
            test_a_moved_top_counts_from_nothing
        ; Alcotest.test_case "the average takes the five newest measured times" `Quick
            test_the_average_takes_the_five_newest_measured_times
        ; Alcotest.test_case "a top past the integer range stands at the largest" `Quick
            test_a_top_past_the_integer_range_stands_at_the_largest
        ; Alcotest.test_case "an average near the integer range does not wrap" `Quick
            test_an_average_near_the_integer_range_does_not_wrap
        ; Alcotest.test_case "a resized graph keeps its top" `Quick
            test_a_resized_graph_keeps_its_top
        ; Alcotest.test_case "a top over blanks only is not written" `Quick
            test_a_top_over_blanks_only_is_not_written
        ; Alcotest.test_case "how far above the top moves no dot" `Quick
            test_how_far_above_the_top_moves_no_dot
        ] )
    ]
