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

  (* Test 2: removed keeper fields are rejected on read. There is no runtime
     compatibility or scrub-on-write migration for retired authorities. *)
  let expect_removed_field key value =
    let existing =
      `Assoc
        [ "name", `String "analyst"
        ; "agent_name", `String "keeper-analyst"
        ; "trace_id", `String "trace-001"
        ; key, value
        ]
    in
    match Keeper_meta_json_parse.meta_of_json existing with
    | Error msg when Astring.String.is_infix ~affix:key msg ->
      Printf.printf "test2: PASS — removed %s rejected\n" key
    | Error msg ->
      Printf.printf "FAIL test2: rejection did not name %s: %s\n" key msg;
      exit 1
    | Ok _ ->
      Printf.printf "FAIL test2: removed %s was accepted\n" key;
      exit 1
  in
  expect_removed_field "goal" (`String "test goal");
  expect_removed_field "compaction_mode" (`String "deterministic");

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

  Printf.printf "\nAll 3 tests PASSED\n"
