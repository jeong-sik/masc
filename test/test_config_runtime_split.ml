open Masc

let () =
  (* Test 1: Seed round-trip — minimal JSON should parse + serialize *)
  let seed = Yojson.Safe.from_string {|
{"name": "test-keeper", "agent_name": "test-agent", "trace_id": "trace-001"}
|} in
  let result = Keeper_meta_json_parse.meta_of_json seed in
  match result with
  | Error msg ->
    Printf.printf "FAIL test1: meta_of_json: %s\n" msg; exit 1
  | Ok meta ->
    let json = Keeper_meta_json.meta_to_json meta in
    (match json with
     | `Assoc fields ->
       let keys = List.map fst fields in
       Printf.printf "test1: seed round-trip OK (%d keys)\n" (List.length keys);
       let config_keys = Keeper_meta_json_scrub.config_field_names in
       let leaked = List.filter (fun k -> List.mem k config_keys) keys in
       if leaked <> [] then begin
         Printf.printf "FAIL test1: config keys leaked: %s\n" (String.concat ", " leaked);
         exit 1
       end;
       Printf.printf "test1: PASS — no config keys in output\n"
     | _ -> Printf.printf "FAIL test1: not Assoc\n"; exit 1);

  (* Test 2: the removed keeper goal is rejected on read. There is no runtime
     compatibility or scrub-on-write migration for this retired field. *)
  let existing = Yojson.Safe.from_string {|
{"name": "analyst", "agent_name": "keeper-analyst", "trace_id": "trace-001",
 "goal": "test goal"}
|} in
  (match Keeper_meta_json_parse.meta_of_json existing with
   | Error msg when Astring.String.is_infix ~affix:"goal" msg ->
     Printf.printf "test2: PASS — removed goal rejected\n"
   | Error msg ->
     Printf.printf "FAIL test2: rejection did not name goal: %s\n" msg;
     exit 1
   | Ok _ ->
     Printf.printf "FAIL test2: removed goal was accepted\n";
     exit 1);

  (* Test 3: meta_to_json output has no config keys *)
  let existing = Yojson.Safe.from_string {|
{"name": "analyst", "agent_name": "keeper-analyst", "trace_id": "trace-001",
 "total_turns": 100}
|} in
  (match Keeper_meta_json_parse.meta_of_json existing with
   | Ok meta ->
     (match Keeper_meta_json.meta_to_json meta with
      | `Assoc fields ->
        let keys = List.map fst fields in
        let config_keys = Keeper_meta_json_scrub.config_field_names in
        let leaked = List.filter (fun k -> List.mem k config_keys) keys in
        if leaked <> [] then begin
          Printf.printf "FAIL test3: config keys in output: %s\n" (String.concat ", " leaked);
          exit 1
        end;
        Printf.printf "test3: PASS — output has 0 config keys\n"
      | _ -> Printf.printf "FAIL test3: not Assoc\n"; exit 1)
   | Error msg ->
     Printf.printf "FAIL test3: parse: %s\n" msg; exit 1);

  (* Test 4: a persisted typo in compaction_mode must fail closed. *)
  let invalid_compaction_mode = Yojson.Safe.from_string {|
{"name": "analyst", "agent_name": "keeper-analyst", "trace_id": "trace-001",
 "compaction_mode": "aggressive",
 "total_turns": 100}
|} in
  (match Keeper_meta_json_parse.meta_of_json invalid_compaction_mode with
   | Ok _ ->
     Printf.printf "FAIL test4: invalid compaction_mode parsed successfully\n";
     exit 1
   | Error msg ->
     if
       String_util.string_contains_substring
         ~needle:"invalid persisted compaction_mode"
         msg
     then Printf.printf "test4: PASS — invalid compaction_mode fails closed\n"
     else begin
       Printf.printf "FAIL test4: unexpected parse error: %s\n" msg;
       exit 1
     end);

  Printf.printf "\nAll 4 tests PASSED\n"
