(* [Trajectory.next_round] reads the existing entries of a cold
   (keeper, trace, turn) key from the trajectory file. The read suspends the
   calling fiber: it stats the file through Eio, which runs the stat on a
   worker thread. Every fiber of a domain shares one thread, so a [Stdlib.Mutex]
   held across that read makes the next fiber that asks for any round raise
   [Sys_error "Mutex.lock: Resource deadlock avoided"] instead of waiting. These
   cases put several fibers on cold keys at once. *)
open Alcotest
open Masc

let keeper_name = "round-keeper"

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

(* A trajectory row carrying the fields [next_round] reads; it mirrors a real
   tool-call entry. *)
let row ~turn ~round : Yojson.Safe.t =
  `Assoc
    [ ("ts", `Float 1000.0)
    ; ("ts_iso", `String "2026-07-01T00:00:00Z")
    ; ("turn", `Int turn)
    ; ("round", `Int round)
    ; ("tool_name", `String "tool_execute")
    ; ("args", `Assoc [])
    ; ("result", `String "ok")
    ; ("duration_ms", `Int 1)
    ; ("error", `Null)
    ]

(* Rows are planted before the scheduler starts, so the file is on disk and the
   counters are cold when the fibers ask. *)
let plant ~masc_root ~trace_id (rows : Yojson.Safe.t list) =
  Fs_compat.mkdir_p (Trajectory.trajectories_dir masc_root keeper_name);
  let path = Trajectory.trajectory_path masc_root keeper_name trace_id in
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      List.iter
        (fun json ->
          output_string oc (Yojson.Safe.to_string json);
          output_char oc '\n')
        rows)

let plant_turn ~masc_root ~trace_id ~turn ~count =
  plant ~masc_root ~trace_id (List.init count (fun round -> row ~turn ~round))

let with_cold_counters ~plant_rows f =
  let masc_root = Filename.temp_dir "trajectory-next-round-" "" in
  Fun.protect
    ~finally:(fun () ->
      Trajectory.reset_round_counters_for_testing ();
      rm_rf masc_root)
    (fun () ->
      Trajectory.reset_round_counters_for_testing ();
      plant_rows ~masc_root;
      Eio_main.run (fun env ->
        Fs_compat.set_fs (Eio.Stdenv.fs env);
        Fun.protect ~finally:Fs_compat.clear_fs (fun () -> f ~masc_root)))

let next_round ~masc_root ~trace_id ~turn =
  Trajectory.next_round ~masc_root ~keeper_name ~trace_id ~turn

let test_callers_of_one_cold_key_get_distinct_rounds () =
  let existing = 3 in
  let callers = 8 in
  let trace_id = "one-cold-key" in
  with_cold_counters
    ~plant_rows:(fun ~masc_root ->
      plant_turn ~masc_root ~trace_id ~turn:6 ~count:2;
      plant_turn ~masc_root ~trace_id ~turn:7 ~count:existing)
    (fun ~masc_root ->
      let asked = ref 0 in
      let asked_when_served = ref [] in
      let ask _ =
        incr asked;
        let round = next_round ~masc_root ~trace_id ~turn:7 in
        asked_when_served := !asked :: !asked_when_served;
        round
      in
      let rounds = Eio.Fiber.List.map ask (List.init callers Fun.id) in
      (* The first call suspends while it reads the file, so every other caller
         has asked before any caller is served. A read that never suspended
         would serve the first caller after one ask and the case would prove
         nothing. *)
      check (list int) "every caller asked before any was served"
        (List.init callers (fun _ -> callers))
        !asked_when_served;
      check (list int) "each round after the existing entries is issued once"
        (List.init callers (fun i -> existing + 1 + i))
        (List.sort Int.compare rounds))

let test_cold_keys_of_two_traces_do_not_wait_on_each_other () =
  let first = "first-cold-trace" in
  let second = "second-cold-trace" in
  with_cold_counters
    ~plant_rows:(fun ~masc_root ->
      plant_turn ~masc_root ~trace_id:first ~turn:1 ~count:2;
      plant_turn ~masc_root ~trace_id:second ~turn:1 ~count:5)
    (fun ~masc_root ->
      let rounds =
        Eio.Fiber.List.map
          (fun trace_id -> next_round ~masc_root ~trace_id ~turn:1)
          [ first; second ]
      in
      check (list int) "each trace continues after its own entries" [ 3; 6 ]
        rounds)

let test_issued_rounds_survive_eviction_while_callers_hydrate () =
  let trace_id = "evicted-key" in
  with_cold_counters
    ~plant_rows:(fun ~masc_root ->
      (* One entry on disk for turn 5, fewer than the rounds issued below. *)
      plant_turn ~masc_root ~trace_id ~turn:5 ~count:1)
    (fun ~masc_root ->
      let issued_before =
        List.init 3 (fun _ -> next_round ~masc_root ~trace_id ~turn:5)
      in
      check (list int) "turn 5 continues after its disk entry" [ 2; 3; 4 ]
        issued_before;
      check int "turn 6 starts at 1" 1 (next_round ~masc_root ~trace_id ~turn:6);
      (* Turn 6 evicted the active turn-5 counter. Two late callers hydrate
         turn 5 from a file that holds one entry, and must still continue after
         the rounds this process already issued. *)
      let late =
        Eio.Fiber.List.map
          (fun _ -> next_round ~masc_root ~trace_id ~turn:5)
          [ (); () ]
      in
      check (list int) "late callers continue after the issued high-water mark"
        [ 5; 6 ]
        (List.sort Int.compare late))

let test_cached_key_is_served_while_another_key_hydrates () =
  let warm = "warm-trace" in
  let cold = "cold-trace" in
  with_cold_counters
    ~plant_rows:(fun ~masc_root ->
      plant_turn ~masc_root ~trace_id:warm ~turn:1 ~count:1;
      plant_turn ~masc_root ~trace_id:cold ~turn:1 ~count:4)
    (fun ~masc_root ->
      check int "warming the cached key" 2
        (next_round ~masc_root ~trace_id:warm ~turn:1);
      let finished = ref [] in
      let serve label trace_id () =
        let round = next_round ~masc_root ~trace_id ~turn:1 in
        finished := (label, round) :: !finished
      in
      (* The cold caller suspends while it reads its file; the cached key is
         answered from memory meanwhile instead of waiting for that read. *)
      Eio.Fiber.both (serve "cold" cold) (serve "warm" warm);
      check (list (pair string int)) "the cached key finishes first"
        [ ("warm", 3); ("cold", 5) ]
        (List.rev !finished))

let () =
  run "trajectory next_round concurrent"
    [ ( "cold counters"
      , [ test_case "callers of one cold key get distinct rounds" `Quick
            test_callers_of_one_cold_key_get_distinct_rounds
        ; test_case "cold keys of two traces do not wait on each other" `Quick
            test_cold_keys_of_two_traces_do_not_wait_on_each_other
        ; test_case "issued rounds survive eviction while callers hydrate" `Quick
            test_issued_rounds_survive_eviction_while_callers_hydrate
        ; test_case "a cached key is served while another key hydrates" `Quick
            test_cached_key_is_served_while_another_key_hydrates
        ] )
    ]
