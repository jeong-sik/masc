open Alcotest
module Coord = Masc_mcp.Coord
module Dash = Masc_mcp.Dashboard_http_keeper
module Keeper_config = Masc_mcp.Keeper_config
module Keeper_types = Masc_mcp.Keeper_types
module Json = Yojson.Safe.Util

let test_counter = ref 0

let tmpdir prefix =
  incr test_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "%s_%d_%d_%d"
         prefix
         (Unix.getpid ())
         !test_counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir
;;

let with_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = tmpdir "dashboard_k2_feeds" in
  let config = Coord.default_config base_dir in
  f config
;;

let keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ; "cascade_name", `String Keeper_config.default_cascade_name
          ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json failed: " ^ err)
;;

let append_jsonl path json =
  Keeper_types.mkdir_p (Filename.dirname path);
  Masc_mcp.Keeper_types_support.append_jsonl_line path json
;;

let strings json = json |> Json.to_list |> List.map Json.to_string

let test_decisions_log_evidence_refs_are_real_refs () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decisions" in
  let path = Keeper_types.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_000.0
        ; "keeper_name", `String meta.name
        ; "speech_act", `String "inform"
        ; "belief_summary", `String "prose belief is not an evidence ref"
        ]);
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_001.0
        ; "keeper_name", `String meta.name
        ; "speech_act", `String "request_help"
        ; "belief_summary", `String "new prose summary"
        ; ( "evidence_refs"
          , `List [ `String "trace:k2"; `String ""; `String " artifact:k2 " ] )
        ]);
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let events = Json.(json |> member "events" |> to_list) in
  check int "events" 2 (List.length events);
  match events with
  | newest :: older :: _ ->
    check
      (list string)
      "real evidence refs"
      [ "trace:k2"; "artifact:k2" ]
      Json.(newest |> member "evidence_refs" |> strings);
    check
      (list string)
      "prose summary not used as evidence"
      []
      Json.(older |> member "evidence_refs" |> strings)
  | _ -> fail "expected newest and older events"
;;

let test_decisions_log_clamps_low_limit () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-limit" in
  let path = Keeper_types.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_000.0
        ; "keeper_name", `String meta.name
        ; "speech_act", `String "inform"
        ]);
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:0 () in
  check int "clamped limit" 1 Json.(json |> member "limit" |> to_int);
  check int "one event" 1 Json.(json |> member "events" |> to_list |> List.length)
;;

let memory_row ~ts text =
  `Assoc
    [ "schema_version", `Int 2
    ; "kind", `String "goal"
    ; "text", `String text
    ; "priority", `Int 10
    ; "ts_unix", `Float ts
    ]
;;

let test_memory_log_ids_distinguish_same_timestamp_rows () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-memory" in
  let path = Keeper_types.keeper_memory_bank_path config meta.name in
  append_jsonl path (memory_row ~ts:2_000.0 "Ship K2 memory feed row alpha");
  append_jsonl path (memory_row ~ts:2_000.0 "Ship K2 memory feed row beta");
  let json = Dash.keeper_memory_log_json ~config ~keepers:[ meta ] ~limit:999 () in
  check int "clamped high limit" 200 Json.(json |> member "limit" |> to_int);
  let entries = Json.(json |> member "entries" |> to_list) in
  check int "entries" 2 (List.length entries);
  let ids = entries |> List.map Json.(fun row -> row |> member "id" |> to_string) in
  match ids with
  | [ first; second ] -> check bool "ids differ" true (not (String.equal first second))
  | _ -> fail "expected two memory ids"
;;

let () =
  run
    "dashboard_k2_feeds"
    [ ( "decision log"
      , [ test_case
            "keeps prose out of evidence refs"
            `Quick
            test_decisions_log_evidence_refs_are_real_refs
        ; test_case "clamps low limit" `Quick test_decisions_log_clamps_low_limit
        ] )
    ; ( "memory log"
      , [ test_case
            "ids distinguish same timestamp rows"
            `Quick
            test_memory_log_ids_distinguish_same_timestamp_rows
        ] )
    ]
;;
