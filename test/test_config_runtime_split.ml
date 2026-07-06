open Masc

let meta_read_failure_count ~keeper ~site =
  Otel_metric_store.metric_value_or_zero
    Keeper_metrics.(to_string MetaReadFailures)
    ~labels:[ "keeper", keeper; "site", site ]
    ()

let () =
  (* Test 1: Seed round-trip — minimal JSON should parse + serialize *)
  let seed = Yojson.Safe.from_string {|
{"name": "test-keeper", "agent_name": "test-agent", "trace_id": "trace-001",
 "tool_access": []}
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

  (* Test 2: Runtime JSON with legacy TOML-owned config fields is tolerated on
     read for compatibility, then scrubbed from the next write. *)
  let existing = Yojson.Safe.from_string {|
{"name": "analyst", "agent_name": "keeper-analyst", "trace_id": "trace-001",
 "goal": "test goal", "sandbox_profile": "docker", "network_mode": "inherit",
 "tool_access": ["masc_status"],
 "compaction_profile": "balanced",
 "total_turns": 42, "total_input_tokens": 1000}
|} in
  (match Keeper_meta_json_parse.meta_of_json existing with
   | Error msg ->
     Printf.printf "FAIL test2: legacy config field read failed: %s\n" msg;
     exit 1
   | Ok meta ->
     (match Keeper_meta_json.meta_to_json meta with
      | `Assoc fields ->
        let keys = List.map fst fields in
        let config_keys = Keeper_meta_json_scrub.config_field_names in
        let leaked = List.filter (fun k -> List.mem k config_keys) keys in
        if leaked <> [] then begin
          Printf.printf "FAIL test2: config keys in output: %s\n"
            (String.concat ", " leaked);
          exit 1
        end;
        Printf.printf "test2: PASS — legacy config fields scrubbed on write\n"
      | _ ->
        Printf.printf "FAIL test2: not Assoc\n";
        exit 1));

  (* Test 3: meta_to_json output has no config keys *)
  let existing = Yojson.Safe.from_string {|
{"name": "analyst", "agent_name": "keeper-analyst", "trace_id": "trace-001",
 "tool_access": ["masc_status"],
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

  (* Test 4: malformed optional persisted ids degrade to None, but are
     observable through the existing meta-read failure metric. *)
  let keeper = "meta-optional-id-observability" in
  let current_task_site = "current_task_id_parse" in
  let keeper_id_site = "keeper_id_parse" in
  let before_current_task =
    meta_read_failure_count ~keeper ~site:current_task_site
  in
  let before_keeper_id = meta_read_failure_count ~keeper ~site:keeper_id_site in
  let existing =
    Yojson.Safe.from_string
      {|
{"name": "meta-optional-id-observability",
 "agent_name": "keeper-meta-optional-id-observability",
 "trace_id": "trace-meta-optional-id-observability",
 "tool_access": [],
 "current_task_id": "",
 "keeper_id": "not-a-keeper-uid"}
|}
  in
  (match Keeper_meta_json_parse.meta_of_json existing with
   | Error msg ->
     Printf.printf "FAIL test4: parse: %s\n" msg;
     exit 1
   | Ok meta ->
     if Option.is_some meta.current_task_id then begin
       Printf.printf "FAIL test4: malformed current_task_id survived\n";
       exit 1
     end;
     if Option.is_some meta.keeper_id then begin
       Printf.printf "FAIL test4: malformed keeper_id survived\n";
       exit 1
     end;
     let after_current_task =
       meta_read_failure_count ~keeper ~site:current_task_site
     in
     let after_keeper_id = meta_read_failure_count ~keeper ~site:keeper_id_site in
     if after_current_task <> before_current_task +. 1.0 then begin
       Printf.printf
         "FAIL test4: current_task_id metric delta expected 1.0, got %.1f\n"
         (after_current_task -. before_current_task);
       exit 1
     end;
     if after_keeper_id <> before_keeper_id +. 1.0 then begin
       Printf.printf
         "FAIL test4: keeper_id metric delta expected 1.0, got %.1f\n"
         (after_keeper_id -. before_keeper_id);
       exit 1
     end;
     Printf.printf
       "test4: PASS — malformed optional ids are dropped with metrics\n");

  Printf.printf "\nAll 4 tests PASSED\n"
