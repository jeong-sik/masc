open Masc_mcp

let () =
  (* Test 1: Seed round-trip — minimal JSON should parse + serialize *)
  let seed = Yojson.Safe.from_string {|
{"name": "test-keeper", "agent_name": "test-agent", "trace_id": "trace-001"}
|} in
  let result = Keeper_types.meta_of_json seed in
  match result with
  | Error msg ->
    Printf.printf "FAIL test1: meta_of_json: %s\n" msg; exit 1
  | Ok meta ->
    let json = Keeper_types.meta_to_json meta in
    (match json with
     | `Assoc fields ->
       let keys = List.map fst fields in
       Printf.printf "test1: seed round-trip OK (%d keys)\n" (List.length keys);
       let config_keys = Keeper_types.config_field_names in
       let leaked = List.filter (fun k -> List.mem k config_keys) keys in
       if leaked <> [] then begin
         Printf.printf "FAIL test1: config keys leaked: %s\n" (String.concat ", " leaked);
         exit 1
       end;
       Printf.printf "test1: PASS — no config keys in output\n"
     | _ -> Printf.printf "FAIL test1: not Assoc\n"; exit 1);

  (* Test 2: Existing JSON with config fields should still parse *)
  let existing = Yojson.Safe.from_string {|
{"name": "analyst", "agent_name": "keeper-analyst", "trace_id": "trace-001",
 "goal": "test goal", "sandbox_profile": "docker", "network_mode": "inherit",
 "tool_access": {"kind": "preset", "preset": "full"},
 "compaction_profile": "balanced",
 "total_turns": 42, "total_input_tokens": 1000}
|} in
  (match Keeper_types.meta_of_json existing with
   | Error msg ->
     Printf.printf "FAIL test2: legacy JSON parse: %s\n" msg; exit 1
   | Ok meta ->
     let rt = meta.runtime in
     Printf.printf "test2: legacy JSON parse OK (turns=%d)\n" rt.usage.total_turns;
     if rt.usage.total_turns <> 42 then begin
       Printf.printf "FAIL test2: wrong turns\n"; exit 1
     end;
     Printf.printf "test2: PASS — legacy config fields accepted, runtime preserved\n");

  (* Test 3: meta_to_json output has no config keys *)
  let existing = Yojson.Safe.from_string {|
{"name": "analyst", "agent_name": "keeper-analyst", "trace_id": "trace-001",
 "sandbox_profile": "docker", "network_mode": "inherit",
 "total_turns": 100}
|} in
  (match Keeper_types.meta_of_json existing with
   | Ok meta ->
     (match Keeper_types.meta_to_json meta with
      | `Assoc fields ->
        let keys = List.map fst fields in
        let config_keys = Keeper_types.config_field_names in
        let leaked = List.filter (fun k -> List.mem k config_keys) keys in
        if leaked <> [] then begin
          Printf.printf "FAIL test3: config keys in output: %s\n" (String.concat ", " leaked);
          exit 1
        end;
        Printf.printf "test3: PASS — output has 0 config keys\n"
      | _ -> Printf.printf "FAIL test3: not Assoc\n"; exit 1)
   | Error msg ->
     Printf.printf "FAIL test3: parse: %s\n" msg; exit 1);

  Printf.printf "\nAll 3 tests PASSED\n"
