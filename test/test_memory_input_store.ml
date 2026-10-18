open Alcotest
open Turn_record

let turn_ref trace turn = Ids.Turn_ref.make ~trace_id:trace ~absolute_turn:turn

let record ?(blocks = []) ?input_components ?(usage_scope = Runtime_usage_scope.Per_request)
    ~trace ~turn () : Turn_record.t =
  { execution_ids = []
  ; keeper = "omega"
  ; agent_name = "keeper-omega"
  ; turn_kind = Direct
  ; trace_id = trace
  ; absolute_turn = turn
  ; turn_ref = turn_ref trace turn
  ; blocks
  ; input_components
  ; tool_surface_ref = None
  ; runtime_profile = "glm-coding"
  ; selected_model = Some "glm-5.3"
  ; finish_reason = Some "stop"
  ; context_window = Some 200_000
  ; provider_context_window = None
  ; price_input_per_million = None
  ; price_output_per_million = None
  ; request_latency_ms = Some 1200
  ; ttfrc_ms = Some 80.
  ; request_wire_observation =
      Some { runtime_profile = "glm-coding"; body_bytes = 4096 }
  ; model_input_window =
      Some
        { transmitted_atoms = 3
        ; total_atoms = 4
        ; measurement = Wire_shape
        ; model_input_front = Model_input_front.At_atom (String.make 64 'c')
        }
  ; response_observed_model_input = None
  ; raw_trace_run_ref = None
  ; sampling =
      { temperature = Some 0.2
      ; top_p = None
      ; max_tokens = None
      ; enable_thinking = Some true
      }
  ; usage =
      { input_tokens = Some 1000
      ; output_tokens = Some 200
      ; cache_creation_input_tokens = None
      ; cache_read_input_tokens = Some 500
      ; scope = usage_scope
      }
  ; turn_output_tokens = None
  ; ts = 1_787_600_000.
  }

(* The turn record store of keeper "omega" under a temporary root. *)
let with_store fn =
  let root = Filename.temp_dir "memory-input-store-" "" in
  let location =
    Dated_jsonl.Store.keeper (Dated_jsonl.Store.root_of_masc_dir root) ~keeper:"omega" Turn_records
  in
  let dir = Dated_jsonl.Store.dir location in
  let month = Filename.concat dir "2026-10" in
  (* [root/keepers/omega/turn-records/2026-10], made and removed one level at a time. *)
  let made = [ Filename.dirname (Filename.dirname dir); Filename.dirname dir; dir; month ] in
  List.iter (fun d -> Unix.mkdir d 0o700) made;
  let path = Filename.concat month "04.jsonl" in
  let store = Dated_jsonl.open_store location in
  Fun.protect ~finally:(fun () ->
    if Sys.file_exists path then
      if Sys.is_directory path then Unix.rmdir path else Sys.remove path;
    List.iter Unix.rmdir (List.rev made); Unix.rmdir root)
    (fun () -> fn store path)

let write path text =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel text)

(* Use the API's production reader and its existing page fields, then the
   actual TUI decoder. The filesystem failure must survive that boundary. *)
let page store limit =
  match Server_keeper_turn_records.read ~store ~limit with
  | Error error -> Error error
  | Ok (records, skipped) ->
    Ok (`Assoc ["keeper", `String "omega"; "skipped_rows", `Int skipped;
      "entries", `List (List.map (fun r -> `Assoc ["record", Turn_record.to_json r]) records)])

let test_corrupt_latest_is_not_an_older_input () =
  with_store (fun store path ->
    let valid = Turn_record.to_json (record ~trace:"trace-store" ~turn:1 ())
      |> Yojson.Safe.to_string in
    write path (valid ^ "\n{\"absolute_turn\":2,\"input_tokens\":");
    check int "old permissive route silently substitutes a valid row" 1
      (List.length (Dated_jsonl.read_recent store 50));
    List.iter (fun limit ->
      match page store limit with
      | Error e -> fail (Dated_jsonl.read_error_to_string e)
      | Ok json ->
        match Masc_tui_memory_usage.decode ~keeper:"omega" json with
        | Error _ -> ()
        | Ok _ -> fail "truncated latest row became apparently current statistics") [1; 50])

let test_storage_failure_is_not_empty_memory () =
  with_store (fun store path ->
    Unix.mkdir path 0o700;
    match page store 50 with
    | Error _ -> ()
    | Ok _ -> fail "unreadable turn store became a successful empty page")

let test_valid_store_reaches_input_summary () =
  with_store (fun store path ->
    let first = record ~trace:"trace-store" ~turn:1 () in
    let last = { first with absolute_turn = 2; turn_ref = turn_ref "trace-store" 2;
      usage = { first.usage with input_tokens = Some 3000 } } in
    write path (String.concat "\n" (List.map (fun r -> Yojson.Safe.to_string (Turn_record.to_json r)) [first; last]) ^ "\n");
    match page store 50 with
    | Error e -> fail (Dated_jsonl.read_error_to_string e)
    | Ok json ->
      match Masc_tui_memory_usage.decode ~keeper:"omega" json with
      | Error e -> fail e
      | Ok summary ->
        check (option int) "latest physical request" (Some 3000) summary.tokens.last;
        let distribution = Option.get summary.tokens.distribution in
        check (float 0.001) "whole recent input mean" 2000. distribution.mean;
        check int "all valid requests counted" 2 distribution.samples)

module Inspector = Masc_tui_context_inspector
module Api = Server_dashboard_http_keeper_api

let encoded_record record = Yojson.Safe.to_string (Turn_record.to_json record)

let test_exact_lookup_outside_recent_window () =
  with_store (fun store path ->
    let original = record ~trace:"original" ~turn:1 () in
    let newer = List.init 80 (fun i -> record ~trace:"replacement" ~turn:(i + 1) ()) in
    write path (String.concat "\n" (List.map encoded_record (original :: newer)) ^ "\n");
    check bool "target outside recent page" false
      (List.exists (fun (r : Turn_record.t) -> Ids.Turn_ref.equal r.turn_ref original.turn_ref)
         (Server_keeper_turn_records.read ~store ~limit:50 |> Result.get_ok |> fst));
    match Server_keeper_turn_records.read_exact ~store ~keeper:"omega" ~turn_ref:original.turn_ref with
    | Ok (Some found, skipped) ->
        check bool "complete original identity" true (Ids.Turn_ref.equal found.turn_ref original.turn_ref);
        check int "no unrelated damage" 0 skipped
    | Ok (None, _) -> fail "exact source was restricted to recent page"
    | Error error -> fail (Server_keeper_turn_records.exact_error_to_string error))

let test_exact_corruption_keeps_known_positive () =
  with_store (fun store path ->
    let original = record ~trace:"original" ~turn:1 () in
    write path (encoded_record original ^ "\n{broken\n");
    match Server_keeper_turn_records.read_exact ~store ~keeper:"omega" ~turn_ref:original.turn_ref with
    | Ok (Some found, skipped) ->
        check bool "known source survives unrelated damage" true (Ids.Turn_ref.equal found.turn_ref original.turn_ref);
        check int "damage stays observable" 1 skipped
    | Ok (None, _) -> fail "known positive discarded"
    | Error error -> fail (Server_keeper_turn_records.exact_error_to_string error))

let test_exact_absence_and_corruption () =
  with_store (fun store path ->
    let original = record ~trace:"original" ~turn:1 () in
    write path (encoded_record original ^ "\n");
    let missing = turn_ref "absent" 1 in
    (match Server_keeper_turn_records.read_exact ~store ~keeper:"omega" ~turn_ref:missing with
     | Ok (None, 0) -> ()
     | _ -> fail "readable absence not distinguished");
    write path (encoded_record original ^ "\n{broken\n");
    (match Server_keeper_turn_records.read_exact ~store ~keeper:"omega" ~turn_ref:missing with
     | Error (Server_keeper_turn_records.Uncertain_absence { unidentified_rows = 1 }) -> ()
     | _ -> fail "unidentified row became proven absence");
    let malformed_target = match Turn_record.to_json original with
      | `Assoc fields -> `Assoc (List.remove_assoc "blocks" fields)
      | _ -> fail "record fixture is not an object" in
    write path (Yojson.Safe.to_string malformed_target ^ "\n");
    match Server_keeper_turn_records.read_exact ~store ~keeper:"omega" ~turn_ref:original.turn_ref with
    | Error (Server_keeper_turn_records.Invalid_target_record _) -> ()
    | _ -> fail "malformed named target was skipped")

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path

let rec mkdir_p path =
  if not (Sys.file_exists path) then (mkdir_p (Filename.dirname path); Unix.mkdir path 0o700)

let with_exact_api fn =
  let base = Filename.temp_dir "exact-turn-api-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () ->
    let config = Masc.Workspace.default_config base in
    check string "isolated workspace" (Unix.realpath base) (Unix.realpath config.base_path);
    let location = Dated_jsonl.Store.keeper (Masc.Workspace.dated_store_root config)
        ~keeper:"omega" Turn_records in
    let store = Dated_jsonl.open_store location in
    Fun.protect ~finally:(fun () -> Dated_jsonl.prepare_for_directory_removal store) (fun () ->
      let month = Filename.concat (Dated_jsonl.Store.dir location) "2026-10" in
      mkdir_p month;
      let path = Filename.concat month "04.jsonl" in
      let lookup ?(keeper = "omega") query =
        let target = Uri.make ~path:("/api/v1/keepers/" ^ keeper ^ "/turn-records") ~query ()
          |> Uri.to_string in
        Api.keeper_turn_record_lookup_response ~config ~keeper_name:keeper
          (Httpun.Request.create `GET target) in
      fn path lookup))

let test_exact_http_response_reaches_tui () =
  with_exact_api (fun path lookup ->
    let original = record ~trace:"source#session" ~turn:1 () in
    let newer = record ~trace:"other" ~turn:1 () in
    write path (encoded_record original ^ "\n" ^ encoded_record newer ^ "\n{broken\n");
    let query = [ "turn_ref", [ Ids.Turn_ref.to_string original.turn_ref ] ] in
    match lookup query with
    | Some (`OK, json) ->
        (match Inspector.decode_exact_turn_record ~expected_keeper:"omega"
                 ~expected_turn_ref:original.turn_ref json with
         | Error detail -> fail detail
         | Ok reading ->
             check bool "original survives HTTP encoding and decoding" true
               (Ids.Turn_ref.equal reading.record.turn_ref original.turn_ref);
             check int "partial history metadata retained" 1 reading.skipped_rows);
        (match Inspector.decode_exact_turn_record ~expected_keeper:"omega"
                 ~expected_turn_ref:newer.turn_ref json with
         | Error _ -> () | Ok _ -> fail "another trace accepted as source");
        (match Inspector.decode_exact_turn_record ~expected_keeper:"foreign"
                 ~expected_turn_ref:original.turn_ref json with
         | Error _ -> () | Ok _ -> fail "another Keeper accepted as source");
        let invalids = match json with
          | `Assoc fields ->
              [ `Assoc (("keeper", `String "omega") :: fields)
              ; `Assoc (("entries", `List []) :: List.remove_assoc "entries" fields)
              ; `Assoc (("skipped_rows", `Int (-1)) :: List.remove_assoc "skipped_rows" fields)
              ; `Assoc (("entries", `List
                  [ `Assoc [ "record", Turn_record.to_json newer; "diff_vs_prev", `Null ] ])
                  :: List.remove_assoc "entries" fields)
              ; `Assoc (("entries", `List
                  [ `Assoc [ "record", Turn_record.to_json original; "diff_vs_prev", `Null ]
                  ; `Assoc [ "record", Turn_record.to_json newer; "diff_vs_prev", `Null ] ])
                  :: List.remove_assoc "entries" fields)
              ]
          | _ -> fail "HTTP success is not an object" in
        List.iter (fun invalid ->
          match Inspector.decode_exact_turn_record ~expected_keeper:"omega"
                  ~expected_turn_ref:original.turn_ref invalid with
          | Error _ -> () | Ok _ -> fail "ambiguous exact reading accepted") invalids
    | _ -> fail "exact HTTP helper did not return the source")

let test_exact_http_failure_states () =
  with_exact_api (fun path lookup ->
    let original = record ~trace:"original" ~turn:1 () in
    let query = [ "turn_ref", [ Ids.Turn_ref.to_string original.turn_ref ] ] in
    check bool "no exact query preserves recent handler" true (lookup [] = None);
    List.iter (fun invalid -> match lookup invalid with
      | Some (`Bad_request, _) -> () | _ -> fail "invalid exact query reached history")
      [ [ "turn_ref", [] ]; [ "turn_ref", [ "" ] ]; [ "turn_ref", [ "bad" ] ]
      ; query @ query; [ "turn_ref", [ "original#1"; "other#1" ] ] ];
    write path "";
    (match lookup query with
     | Some (`Not_found, _) -> () | _ -> fail "readable absence is not 404");
    write path "{broken\n";
    (match lookup query with
     | Some (`Service_unavailable, _) -> () | _ -> fail "uncertain absence is not 503");
    write path (encoded_record { original with keeper = "foreign" } ^ "\n");
    (match lookup query with
     | Some (`Service_unavailable, _) -> () | _ -> fail "foreign target accepted");
    Sys.remove path;
    Unix.mkdir path 0o700;
    match lookup query with
    | Some (`Service_unavailable, _) -> () | _ -> fail "unreadable history is not 503")

let () =
  Eio_main.run (fun _ ->
    run "Memory input storage boundary"
      ["recorded input", [
        test_case "corrupt latest cannot become older input" `Quick test_corrupt_latest_is_not_an_older_input;
        test_case "storage failure is not empty" `Quick test_storage_failure_is_not_empty_memory;
        test_case "valid store reaches input summary" `Quick test_valid_store_reaches_input_summary];
       "exact original turn", [
        test_case "outside recent window" `Quick test_exact_lookup_outside_recent_window;
        test_case "known positive survives unrelated damage" `Quick test_exact_corruption_keeps_known_positive;
        test_case "absence and named corruption differ" `Quick test_exact_absence_and_corruption;
        test_case "production HTTP response reaches strict TUI decoder" `Quick test_exact_http_response_reaches_tui;
        test_case "query and storage failures remain distinct" `Quick test_exact_http_failure_states]])
