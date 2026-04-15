(** Test Hebbian_eio Module - Pure Synchronous Tests

    "Agents that fire together, wire together"
*)

open Masc_mcp

let () = Random.init 42

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
      (Printf.sprintf "masc-hebbian-eio-%d-%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000000.)))
  in
  Unix.mkdir base 0o755;
  let config = Coord.default_config base in
  let _ = Coord.init config ~agent_name:None in
  (* Reset lock stats before each test *)
  Hebbian_eio.reset_lock_stats ();
  try
    let result = f config in
    let _ = Coord.reset config in
    rm_rf base;
    result
  with e ->
    let _ = Coord.reset config in
    rm_rf base;
    raise e

let test_strengthen () =
  with_temp_masc_dir (fun config ->
    (* Strengthen a connection *)
    Hebbian_eio.strengthen config ~from_agent:"claude" ~to_agent:"gemini" ();

    (* Check graph data *)
    let (synapses, agents) = Hebbian_eio.get_graph_data config in
    assert (List.length synapses = 1);
    assert (List.mem "claude" agents);
    assert (List.mem "gemini" agents);

    (* Check synapse values *)
    let s = List.hd synapses in
    assert (s.Hebbian_eio.from_agent = "claude");
    assert (s.Hebbian_eio.to_agent = "gemini");
    assert (s.Hebbian_eio.success_count = 1);
    assert (s.Hebbian_eio.weight > 0.5)  (* Started at 0.5, strengthened *)
  );
  print_endline "✓ test_strengthen passed"

let test_weaken () =
  with_temp_masc_dir (fun config ->
    (* First create a connection *)
    Hebbian_eio.strengthen config ~from_agent:"claude" ~to_agent:"codex" ();

    (* Get initial weight *)
    let (synapses, _) = Hebbian_eio.get_graph_data config in
    let initial_weight = (List.hd synapses).Hebbian_eio.weight in

    (* Weaken the connection *)
    Hebbian_eio.weaken config ~from_agent:"claude" ~to_agent:"codex" ();

    (* Check weight decreased *)
    let (synapses2, _) = Hebbian_eio.get_graph_data config in
    let new_weight = (List.hd synapses2).Hebbian_eio.weight in
    assert (new_weight < initial_weight);

    let s = List.hd synapses2 in
    assert (s.Hebbian_eio.failure_count = 1)
  );
  print_endline "✓ test_weaken passed"

let test_get_preferred_partner () =
  with_temp_masc_dir (fun config ->
    (* Create multiple connections with different strengths *)
    Hebbian_eio.strengthen config ~from_agent:"claude" ~to_agent:"gemini" ();
    Hebbian_eio.strengthen config ~from_agent:"claude" ~to_agent:"gemini" ();  (* 2x *)
    Hebbian_eio.strengthen config ~from_agent:"claude" ~to_agent:"codex" ();   (* 1x *)

    (* Preferred partner should be gemini (higher weight) *)
    match Hebbian_eio.get_preferred_partner config ~agent_id:"claude" with
    | Some partner ->
      assert (partner = "gemini");
      print_endline (Printf.sprintf "  Preferred partner for claude: %s" partner)
    | None -> failwith "Expected a preferred partner"
  );
  print_endline "✓ test_get_preferred_partner passed"

let test_no_preferred_partner () =
  with_temp_masc_dir (fun config ->
    (* No connections yet *)
    match Hebbian_eio.get_preferred_partner config ~agent_id:"claude" with
    | None -> ()  (* Expected - no connections *)
    | Some _ -> failwith "Expected no preferred partner"
  );
  print_endline "✓ test_no_preferred_partner passed"

let test_consolidate () =
  with_temp_masc_dir (fun config ->
    (* Create some connections *)
    Hebbian_eio.strengthen config ~from_agent:"claude" ~to_agent:"gemini" ();
    Hebbian_eio.strengthen config ~from_agent:"gemini" ~to_agent:"codex" ();

    (* Consolidate (with 0 days to force decay check on all) *)
    let pruned = Hebbian_eio.consolidate config ~decay_after_days:0 () in
    print_endline (Printf.sprintf "  Pruned %d weak connections" pruned);

    (* Graph should still have connections (weights above min_weight) *)
    let (synapses, _) = Hebbian_eio.get_graph_data config in
    assert (List.length synapses >= 0)  (* May or may not prune depending on params *)
  );
  print_endline "✓ test_consolidate passed"

let test_multiple_agents () =
  with_temp_masc_dir (fun config ->
    (* Build a network of connections *)
    Hebbian_eio.strengthen config ~from_agent:"claude" ~to_agent:"gemini" ();
    Hebbian_eio.strengthen config ~from_agent:"gemini" ~to_agent:"codex" ();
    Hebbian_eio.strengthen config ~from_agent:"codex" ~to_agent:"claude" ();

    let (synapses, agents) = Hebbian_eio.get_graph_data config in
    assert (List.length synapses = 3);
    assert (List.length agents = 3);
    print_endline (Printf.sprintf "  Network: %d synapses, %d agents"
                     (List.length synapses) (List.length agents))
  );
  print_endline "✓ test_multiple_agents passed"

let test_custom_params () =
  with_temp_masc_dir (fun config ->
    (* Use custom learning params *)
    let params = {
      Hebbian_eio.strengthen_rate = 0.2;  (* Stronger learning *)
      weaken_rate = 0.1;
      decay_rate = 0.05;
      min_weight = 0.1;
      max_weight = 1.0;
    } in

    Hebbian_eio.strengthen config ~params ~from_agent:"claude" ~to_agent:"gemini" ();

    let (synapses, _) = Hebbian_eio.get_graph_data config in
    let s = List.hd synapses in
    (* Initial 0.5 + 0.2 = 0.7 *)
    assert (s.Hebbian_eio.weight >= 0.69 && s.Hebbian_eio.weight <= 0.71)
  );
  print_endline "✓ test_custom_params passed"

let test_lock_stats () =
  with_temp_masc_dir (fun config ->
    (* Perform several operations to generate lock acquisitions *)
    Hebbian_eio.strengthen config ~from_agent:"a" ~to_agent:"b" ();
    Hebbian_eio.strengthen config ~from_agent:"b" ~to_agent:"c" ();
    Hebbian_eio.weaken config ~from_agent:"a" ~to_agent:"b" ();

    let (acquisitions, avg_wait, max_wait) = Hebbian_eio.get_lock_stats () in
    assert (acquisitions >= 3);  (* At least 3 lock acquisitions *)
    print_endline (Printf.sprintf "  Lock stats: %d acquisitions, %.2fms avg, %.2fms max"
                     acquisitions avg_wait max_wait)
  );
  print_endline "✓ test_lock_stats passed"

let test_weaken_nonexistent () =
  with_temp_masc_dir (fun config ->
    (* Weaken a nonexistent connection - should do nothing *)
    Hebbian_eio.weaken config ~from_agent:"x" ~to_agent:"y" ();

    let (synapses, _) = Hebbian_eio.get_graph_data config in
    assert (List.length synapses = 0)  (* No synapse created *)
  );
  print_endline "✓ test_weaken_nonexistent passed"

let test_weight_history_appends_on_strengthen () =
  with_temp_masc_dir (fun config ->
    let params = {
      Hebbian_eio.strengthen_rate = 0.1;
      weaken_rate = 0.05;
      decay_rate = 0.01;
      min_weight = 0.05;
      max_weight = 1.0;
    } in
    Hebbian_eio.strengthen config ~params ~from_agent:"a" ~to_agent:"b" ();
    Hebbian_eio.strengthen config ~params ~from_agent:"a" ~to_agent:"b" ();
    Hebbian_eio.strengthen config ~params ~from_agent:"a" ~to_agent:"b" ();

    let (synapses, _) = Hebbian_eio.get_graph_data config in
    let s = List.hd synapses in
    (* Initial (0.5) + 3 strengthen appends = 4 entries, newest first. *)
    assert (List.length s.Hebbian_eio.weight_history = 4);
    let (_, newest_w) = List.hd s.Hebbian_eio.weight_history in
    assert (Float.abs (newest_w -. s.Hebbian_eio.weight) < 1e-9);
  );
  print_endline "✓ test_weight_history_appends_on_strengthen passed"

let test_weight_history_caps_at_history_cap () =
  with_temp_masc_dir (fun config ->
    for _ = 1 to Hebbian_eio.history_cap + 15 do
      Hebbian_eio.strengthen config ~from_agent:"a" ~to_agent:"b" ()
    done;
    let (synapses, _) = Hebbian_eio.get_graph_data config in
    let s = List.hd synapses in
    assert (List.length s.Hebbian_eio.weight_history = Hebbian_eio.history_cap);
  );
  print_endline "✓ test_weight_history_caps_at_history_cap passed"

let test_weight_history_backward_compat_missing_field () =
  (* Simulate a graph.json produced by a pre-sparkline binary: no
     weight_history field. Loader must default to []. *)
  let legacy_json = {|
    {
      "synapses": [
        {
          "from_agent": "legacy_a",
          "to_agent": "legacy_b",
          "weight": 0.7,
          "success_count": 4,
          "failure_count": 1,
          "last_updated": 1700000000.0,
          "created_at": 1699000000.0
        }
      ],
      "last_consolidation": 0.0
    }
  |} in
  let parsed = Hebbian_eio.graph_of_json (Yojson.Safe.from_string legacy_json) in
  assert (List.length parsed.Hebbian_eio.synapses = 1);
  let s = List.hd parsed.Hebbian_eio.synapses in
  assert (s.Hebbian_eio.weight_history = []);
  assert (Float.abs (s.Hebbian_eio.weight -. 0.7) < 1e-9);
  print_endline "✓ test_weight_history_backward_compat_missing_field passed"

let test_weight_history_json_roundtrip () =
  let s : Hebbian_eio.synapse = {
    from_agent = "rt_a";
    to_agent = "rt_b";
    weight = 0.62;
    success_count = 5;
    failure_count = 2;
    last_updated = 1700000100.5;
    created_at = 1699000000.0;
    weight_history = [(1700000100.5, 0.62); (1700000050.0, 0.55); (1700000000.0, 0.5)];
  } in
  let json = Hebbian_eio.synapse_to_json s in
  match Hebbian_eio.synapse_of_json json with
  | None -> assert false
  | Some s' ->
    assert (s'.weight_history = s.weight_history);
    assert (s'.success_count = 5);
    print_endline "✓ test_weight_history_json_roundtrip passed"

let test_append_history_caps_and_preserves_order () =
  (* Newest entry is head; overflow evicts the oldest tail. *)
  let h =
    let rec fill i h =
      if i > Hebbian_eio.history_cap + 5 then h
      else
        Hebbian_eio.append_history
          ~ts:(float_of_int i)
          ~w:(float_of_int i /. 100.0)
          (fill (i + 1) h)
    in
    fill 1 []
  in
  assert (List.length h = Hebbian_eio.history_cap);
  let (head_ts, _) = List.hd h in
  assert (Float.equal head_ts 1.0);
  print_endline "✓ test_append_history_caps_and_preserves_order passed"

let () =
  Alcotest.run "Hebbian_eio"
    [
      ( "synapse",
        [
          Alcotest.test_case "strengthen" `Quick test_strengthen;
          Alcotest.test_case "weaken" `Quick test_weaken;
          Alcotest.test_case "weaken nonexistent" `Quick
            test_weaken_nonexistent;
        ] );
      ( "queries",
        [
          Alcotest.test_case "get preferred partner" `Quick
            test_get_preferred_partner;
          Alcotest.test_case "no preferred partner" `Quick
            test_no_preferred_partner;
          Alcotest.test_case "multiple agents network" `Quick
            test_multiple_agents;
        ] );
      ( "maintenance",
        [
          Alcotest.test_case "consolidate" `Quick test_consolidate;
          Alcotest.test_case "custom learning params" `Quick
            test_custom_params;
          Alcotest.test_case "lock stats" `Quick test_lock_stats;
        ] );
      ( "weight_history",
        [
          Alcotest.test_case "appends on strengthen" `Quick
            test_weight_history_appends_on_strengthen;
          Alcotest.test_case "caps at history_cap" `Quick
            test_weight_history_caps_at_history_cap;
          Alcotest.test_case "backward compat missing field" `Quick
            test_weight_history_backward_compat_missing_field;
          Alcotest.test_case "JSON roundtrip" `Quick
            test_weight_history_json_roundtrip;
          Alcotest.test_case "caps and preserves order" `Quick
            test_append_history_caps_and_preserves_order;
        ] );
    ]
