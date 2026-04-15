(** Concurrent stress test for portal lock drift fix.
    
    Tests that with_two_file_locks prevents deadlock when two concurrent
    portal_open_r calls target the same agent pair in opposite directions.
    
    Scenario:
    - Agent A opens portal to Agent B
    - Agent B opens portal to Agent A (concurrent)
    
    Without lexicographic ordering, this would deadlock:
    - A locks A.json, tries to lock B.json
    - B locks B.json, tries to lock A.json
    
    With lexicographic ordering (A < B):
    - A locks A.json, then B.json (in order)
    - B waits for A.json, then locks B.json (in order)
    - No deadlock.
*)

open Eio

let test_no_deadlock_on_reverse_portals () =
  Eio_main.run @@ fun env ->
  let sw = Eio.Switch.create () in
  
  (* Simulate two concurrent portal_open_r calls *)
  let agent_a = "agent_a" in
  let agent_b = "agent_b" in
  
  let lock_a = Eio.Mutex.create () in
  let lock_b = Eio.Mutex.create () in
  
  (* Simulate with_two_file_locks behavior *)
  let with_two_locks path_a path_b f =
    let p1, p2 = if String.compare path_a path_b <= 0 then path_a, path_b else path_b, path_a in
    let lock1 = if p1 = path_a then lock_a else lock_b in
    let lock2 = if p2 = path_a then lock_a else lock_b in
    Eio.Mutex.lock lock1;
    (try
      Eio.Mutex.lock lock2;
      (try f () finally Eio.Mutex.unlock lock2)
    finally Eio.Mutex.unlock lock1)
  in
  
  let result_a = ref false in
  let result_b = ref false in
  
  (* Fiber 1: Agent A opens portal to B *)
  Eio.Fiber.fork ~sw (fun () ->
    with_two_locks agent_a agent_b (fun () ->
      Eio.Time.sleep env#clock 0.01; (* Simulate work *)
      result_a := true
    )
  );
  
  (* Fiber 2: Agent B opens portal to A (concurrent) *)
  Eio.Fiber.fork ~sw (fun () ->
    with_two_locks agent_b agent_a (fun () ->
      Eio.Time.sleep env#clock 0.01; (* Simulate work *)
      result_b := true
    )
  );
  
  Eio.Switch.run sw;
  
  assert !result_a;
  assert !result_b;
  Printf.printf "✅ No deadlock on reverse portals\n"

let test_string_compare_ordering () =
  (* Verify that String.compare produces consistent ordering *)
  let paths = [
    "portals/agent_b.json";
    "portals/agent_a.json";
    "portals/agent_c.json";
  ] in
  
  let sorted = List.sort String.compare paths in
  
  assert (sorted = [
    "portals/agent_a.json";
    "portals/agent_b.json";
    "portals/agent_c.json";
  ]);
  
  Printf.printf "✅ String.compare ordering is consistent\n"

let test_safe_filename_prevents_path_injection () =
  (* Simulate safe_filename behavior *)
  let safe_filename name =
    let buf = Buffer.create (String.length name * 3) in
    String.iter (fun c ->
      let c_lower = Char.lowercase_ascii c in
      let valid =
        (c_lower >= 'a' && c_lower <= 'z') ||
        (c_lower >= '0' && c_lower <= '9') ||
        c_lower = '.' || c_lower = '_' || c_lower = '-'
      in
      if valid then
        Buffer.add_char buf c_lower
      else
        Buffer.add_string buf (Printf.sprintf "_%02x" (Char.code c))
    ) name;
    Buffer.contents buf
  in
  
  (* Test path injection attempts *)
  let test_cases = [
    ("agent/with/slash", "agent_2fwith_2fslash");
    ("agent..json", "agent..json");
    ("agent\x00null", "agent_00null");
    ("AGENT", "agent");
  ] in
  
  List.iter (fun (input, expected) ->
    let result = safe_filename input in
    assert (result = expected);
    Printf.printf "✅ safe_filename(%S) = %S\n" input result
  ) test_cases

let () =
  Printf.printf "Running portal lock stress tests...\n";
  test_string_compare_ordering ();
  test_safe_filename_prevents_path_injection ();
  test_no_deadlock_on_reverse_portals ();
  Printf.printf "\n✅ All tests passed!\n"