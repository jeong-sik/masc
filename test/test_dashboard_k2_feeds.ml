(** Tests for K2 decisions and memory log telemetry feeds.

    Covers:
    - evidence_refs populated from real reference lists only (not prose)
    - Limit clamping at both producer and route boundary
    - Memory log IDs are collision-resistant for same-timestamp rows
    - JSON shape matches spec:
      {id, ts, ts_unix, keeper, decision_type, summary, evidence_refs[]}
      {id, ts, ts_unix, keeper, kind, summary} *)

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

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if idx + needle_len > haystack_len
    then false
    else if String.equal (String.sub haystack idx needle_len) needle
    then true
    else loop (idx + 1)
  in
  String.equal needle "" || loop 0
;;

(* --- Decision log tests --- *)

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

let test_decisions_log_clamps_high_limit () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decision-hilimit" in
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:999 () in
  check int "clamped high limit" 200 Json.(json |> member "limit" |> to_int)
;;

let test_decisions_log_json_shape () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-decisions-shape" in
  let path = Keeper_types.keeper_decision_log_path config meta.name in
  append_jsonl
    path
    (`Assoc
        [ "ts_unix", `Float 1_234.0
        ; "keeper_name", `String meta.name
        ; "speech_act", `String "assert"
        ; "blocker", `String "missing config"
        ; "current_intention", `String "deploy"
        ]);
  let json = Dash.keeper_decisions_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let events = Json.(json |> member "events" |> to_list) in
  check int "one event" 1 (List.length events);
  let event = List.hd events in
  check bool "has id" true (Json.(event |> member "id" |> to_string) <> "");
  check string "has ts" "1970-01-01T00:20:34Z" Json.(event |> member "ts" |> to_string);
  check (float 0.001) "ts_unix" 1234.0 Json.(event |> member "ts_unix" |> to_float);
  check string "keeper" meta.name Json.(event |> member "keeper" |> to_string);
  check
    string
    "decision_type"
    "assert"
    Json.(event |> member "decision_type" |> to_string);
  check
    bool
    "summary contains blocker"
    true
    (let s = Json.(event |> member "summary" |> to_string) in
     contains_substring ~needle:"blocked" s);
  check
    bool
    "summary contains intention"
    true
    (let s = Json.(event |> member "summary" |> to_string) in
     contains_substring ~needle:"deploy" s)
;;

(* --- Memory log tests --- *)

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
  let ids = entries |> List.map (fun row -> Json.(row |> member "id" |> to_string)) in
  match ids with
  | [ first; second ] -> check bool "ids differ" true (not (String.equal first second))
  | _ -> fail "expected two memory ids"
;;

let test_memory_log_kind_mapping () =
  with_config
  @@ fun config ->
  let meta = keeper_meta "k2-memory-kind" in
  let path = Keeper_types.keeper_memory_bank_path config meta.name in
  (* progress -> episode *)
  append_jsonl
    path
    (`Assoc
        [ "schema_version", `Int 2
        ; "kind", `String "progress"
        ; "text", `String "p1"
        ; "priority", `Int 10
        ; "ts_unix", `Float 3_000.0
        ]);
  (* goal -> plan *)
  append_jsonl
    path
    (`Assoc
        [ "schema_version", `Int 2
        ; "kind", `String "goal"
        ; "text", `String "g1"
        ; "priority", `Int 10
        ; "ts_unix", `Float 3_001.0
        ]);
  (* belief -> fact *)
  append_jsonl
    path
    (`Assoc
        [ "schema_version", `Int 2
        ; "kind", `String "belief"
        ; "text", `String "b1"
        ; "priority", `Int 10
        ; "ts_unix", `Float 3_002.0
        ]);
  let json = Dash.keeper_memory_log_json ~config ~keepers:[ meta ] ~limit:10 () in
  let entries = Json.(json |> member "entries" |> to_list) in
  check int "entries" 3 (List.length entries);
  let kinds = List.map (fun e -> Json.(e |> member "kind" |> to_string)) entries in
  (* sorted newest-first: belief(3_002), goal(3_001), progress(3_000) *)
  check (list string) "kind mapping" [ "fact"; "plan"; "episode" ] kinds
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
        ; test_case "clamps high limit" `Quick test_decisions_log_clamps_high_limit
        ; test_case "json shape matches spec" `Quick test_decisions_log_json_shape
        ] )
    ; ( "memory log"
      , [ test_case
            "ids distinguish same timestamp rows"
            `Quick
            test_memory_log_ids_distinguish_same_timestamp_rows
        ; test_case "kind mapping (episode/fact/plan)" `Quick test_memory_log_kind_mapping
        ] )
    ]
;;
