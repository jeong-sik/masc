(* #9876 follow-up: [start_consolidation_fiber] runs one
   consolidation pass immediately on fork so [last_consolidation]
   never reads epoch zero on a live server.  This test exercises
   the extracted [run_consolidation_once] helper directly so it
   does not need a clock or switch — the same code path runs
   inside the fiber. *)

open Masc_mcp

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_masc_dir f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-9876-first-consol-%d-%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000000.)))
  in
  Unix.mkdir base 0o755;
  let config = Coord.default_config base in
  let _ = Coord.init config ~agent_name:None in
  Hebbian_eio.reset_lock_stats ();
  Fun.protect ~finally:(fun () ->
    let _ = Coord.reset config in
    rm_rf base)
    (fun () -> f config)

let load_consolidation_ts config =
  let g = Hebbian_eio.load_graph config in
  g.last_consolidation

let test_immediate_run_advances_last_consolidation () =
  with_temp_masc_dir (fun config ->
    (* Seed one synapse so the graph file exists with default
       last_consolidation = 0.0 *)
    Hebbian_eio.strengthen config
      ~from_agent:"sangsu" ~to_agent:"issue-king" ();
    Alcotest.(check (float 1e-9))
      "boot graph has last_consolidation = 0"
      0.0 (load_consolidation_ts config);
    let before = Time_compat.now () in
    Hebbian_eio.run_consolidation_once config ~decay_after_days:14;
    let after_ts = load_consolidation_ts config in
    Alcotest.(check bool)
      "last_consolidation advanced past boot 0.0"
      true (after_ts > 0.0);
    Alcotest.(check bool)
      "last_consolidation is recent (>= just before call)"
      true (after_ts >= before -. 0.001))

let test_idempotent_under_no_decay_horizon () =
  (* With decay_after_days=14 and synapses created seconds ago,
     no row meets the cutoff, so pruned=0 and the row data is
     unchanged.  Only [last_consolidation] advances. *)
  with_temp_masc_dir (fun config ->
    Hebbian_eio.strengthen config
      ~from_agent:"a" ~to_agent:"b" ();
    let (before_synapses, _) = Hebbian_eio.get_graph_data config in
    let s_before = List.hd before_synapses in
    Hebbian_eio.run_consolidation_once config ~decay_after_days:14;
    let (after_synapses, _) = Hebbian_eio.get_graph_data config in
    Alcotest.(check int) "synapse count unchanged"
      1 (List.length after_synapses);
    let s_after = List.hd after_synapses in
    Alcotest.(check int) "success_count preserved"
      s_before.Hebbian_eio.success_count s_after.Hebbian_eio.success_count;
    Alcotest.(check (float 1e-9)) "weight preserved"
      s_before.Hebbian_eio.weight s_after.Hebbian_eio.weight)

let () =
  Alcotest.run "hebbian_first_consolidation" [
    "first_pass", [
      Alcotest.test_case "immediate run advances last_consolidation" `Quick
        test_immediate_run_advances_last_consolidation;
      Alcotest.test_case "no-decay run is idempotent on rows" `Quick
        test_idempotent_under_no_decay_horizon;
    ];
  ]
