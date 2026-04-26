(* test/test_hebbian_edge_update_counter.ml

   #9876 observability follow-up: verify that
   [Hebbian_eio.strengthen] and [weaken] surface edge-update
   outcomes via the new Prometheus counter

     masc_hebbian_edge_update_total{outcome}

   where [outcome] is one of [strengthened], [weakened], or
   [weaken_no_synapse].

   Motivation: the synapse graph stayed frozen for 7+ hours with
   432 turn outcomes recorded (issue body).  No counter
   distinguished "hook never fired" from "fired but silently
   did nothing" (the [weaken] [None] branch).  This test pins
   each outcome's label so Grafana can split
   [rate(...{outcome="strengthened"})] vs
   [rate(...{outcome="weaken_no_synapse"})] cleanly. *)

open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_temp_masc_dir f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-hebbian-counter-9876-%d-%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000000.)))
  in
  Unix.mkdir base 0o755;
  let config = Coord.default_config base in
  let _ = Coord.init config ~agent_name:None in
  Hebbian_eio.reset_lock_stats ();
  try
    let result = f config in
    let _ = Coord.reset config in
    rm_rf base;
    result
  with
  | e ->
    let _ = Coord.reset config in
    rm_rf base;
    raise e
;;

let counter_for ~outcome =
  Prometheus.metric_value_or_zero
    Hebbian_eio.edge_update_outcome_metric
    ~labels:[ "outcome", outcome ]
    ()
;;

let test_metric_name_stable () =
  Alcotest.(check string)
    "hebbian edge update counter canonical name"
    "masc_hebbian_edge_update_total"
    Hebbian_eio.edge_update_outcome_metric
;;

let test_strengthen_bumps_strengthened () =
  with_temp_masc_dir (fun cfg ->
    let before = counter_for ~outcome:"strengthened" in
    Hebbian_eio.strengthen cfg ~from_agent:"test-9876-a" ~to_agent:"test-9876-b" ();
    Alcotest.(check (float 0.0001))
      "strengthen counter +1"
      (before +. 1.0)
      (counter_for ~outcome:"strengthened"))
;;

let test_weaken_existing_edge_bumps_weakened () =
  with_temp_masc_dir (fun cfg ->
    (* Prime the graph by strengthening first so the edge exists. *)
    Hebbian_eio.strengthen cfg ~from_agent:"test-9876-c" ~to_agent:"test-9876-d" ();
    let before = counter_for ~outcome:"weakened" in
    Hebbian_eio.weaken cfg ~from_agent:"test-9876-c" ~to_agent:"test-9876-d" ();
    Alcotest.(check (float 0.0001))
      "weaken counter +1 when edge exists"
      (before +. 1.0)
      (counter_for ~outcome:"weakened"))
;;

let test_weaken_missing_edge_bumps_no_synapse () =
  with_temp_masc_dir (fun cfg ->
    (* Weaken a never-strengthened pair — ticks [weaken_no_synapse]
       label, not [weakened].  Surfaces the silent-drop failure
       mode from #9876. *)
    let before_no_synapse = counter_for ~outcome:"weaken_no_synapse" in
    let before_weakened = counter_for ~outcome:"weakened" in
    Hebbian_eio.weaken
      cfg
      ~from_agent:"test-9876-missing-x"
      ~to_agent:"test-9876-missing-y"
      ();
    Alcotest.(check (float 0.0001))
      "weaken_no_synapse counter +1"
      (before_no_synapse +. 1.0)
      (counter_for ~outcome:"weaken_no_synapse");
    Alcotest.(check (float 0.0001))
      "weakened counter unchanged"
      before_weakened
      (counter_for ~outcome:"weakened"))
;;

let () =
  Alcotest.run
    "hebbian_edge_update_counter_9876"
    [ ( "metric_name"
      , [ Alcotest.test_case "canonical name stable" `Quick test_metric_name_stable ] )
    ; ( "outcomes"
      , [ Alcotest.test_case
            "strengthen bumps strengthened"
            `Quick
            test_strengthen_bumps_strengthened
        ; Alcotest.test_case
            "weaken existing edge bumps weakened"
            `Quick
            test_weaken_existing_edge_bumps_weakened
        ; Alcotest.test_case
            "weaken missing edge bumps weaken_no_synapse"
            `Quick
            test_weaken_missing_edge_bumps_no_synapse
        ] )
    ]
;;
