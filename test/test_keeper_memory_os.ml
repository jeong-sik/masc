(** Unit tests for the Keeper Memory OS core types, I/O, and policy. *)

module Types = Masc.Keeper_memory_os_types
module Policy = Masc.Keeper_memory_os_policy
module Memory_io = Masc.Keeper_memory_os_io

let fact_fixture ~now () =
  { Types.claim = "User prefers concise responses"
  ; Types.confidence = 0.9
  ; Types.category = "preference"
  ; Types.source = { Types.trace_id = "trace-123"; Types.turn = 5; Types.tool_call_id = None }
  ; Types.access_count = 2
  ; Types.first_seen = now -. 86400.0
  ; Types.last_accessed = now -. 3600.0
  ; Types.valid_until = None
  ; Types.schema_version = Types.schema_version
  }
;;

let with_temp_keepers_dir f =
  let marker = Filename.temp_file "keeper-memory-os-" ".tmp" in
  Sys.remove marker;
  Memory_io.For_testing.with_keepers_dir marker (fun () -> f marker)
;;

let episode_fixture ~now ~trace_id ~generation ~summary =
  let fact =
    { (fact_fixture ~now ()) with
      Types.claim = summary ^ " fact"
    ; Types.source = { Types.trace_id; turn = 0; tool_call_id = None }
    ; Types.first_seen = now
    ; Types.last_accessed = now
    }
  in
  { Types.trace_id
  ; Types.generation
  ; Types.episode_summary = summary
  ; Types.claims = [ fact ]
  ; Types.open_items = []
  ; Types.constraints = []
  ; Types.preserved_tool_refs = []
  ; Types.source_turn_range = Some (0, 0)
  ; Types.created_at = now
  ; Types.schema_version = Types.schema_version
  }
;;

let test_json_roundtrip () =
  let now = 1_000_000.0 in
  let f = fact_fixture ~now () in
  let f2 = Option.get (Types.fact_of_json (Types.fact_to_json f)) in
  Alcotest.(check string) "claim round-trip" f.claim f2.Types.claim;
  Alcotest.(check (float 0.001)) "confidence round-trip" f.confidence f2.Types.confidence;
  Alcotest.(check int) "access_count round-trip" f.access_count f2.Types.access_count;
  Alcotest.(check (float 0.001)) "first_seen round-trip" f.first_seen f2.Types.first_seen;
  let e =
    { Types.trace_id = "trace-123"
    ; Types.generation = 1
    ; Types.episode_summary = "A short summary of the turn."
    ; Types.claims = [ f ]
    ; Types.open_items = [ "item1" ]
    ; Types.constraints = [ "c1" ]
    ; Types.preserved_tool_refs = [ "call_a" ]
    ; Types.source_turn_range = Some (5, 5)
    ; Types.created_at = now
    ; Types.schema_version = Types.schema_version
    }
  in
  let e2 = Option.get (Types.episode_of_json (Types.episode_to_json e)) in
  Alcotest.(check string)
    "episode summary round-trip"
    e.episode_summary
    e2.Types.episode_summary;
  Alcotest.(check int) "claims length" 1 (List.length e2.Types.claims);
  Alcotest.(check int) "open_items length" 1 (List.length e2.Types.open_items)
;;

let test_policy_score_and_retention () =
  let now = 1_000_000.0 in
  let f = fact_fixture ~now () in
  let score = Policy.score_fact ~now f in
  Alcotest.(check bool) "score positive" true (score > 0.0);
  let verdict = Policy.decide_retention score in
  Alcotest.(check bool) "high score -> KeepVerbatim" true (verdict = Policy.KeepVerbatim);
  let low =
    { f with
      Types.confidence = 0.1
    ; Types.access_count = 0
    ; Types.last_accessed = now -. 864_000.0
    }
  in
  let verdict_low = Policy.decide_retention (Policy.score_fact ~now low) in
  Alcotest.(check bool) "low score -> Discard" true (verdict_low = Policy.Discard)
;;

let test_bump_access () =
  let now = 1_000_000.0 in
  let f = fact_fixture ~now () in
  let bumped = Policy.bump_access_for_turn ~now [ f ] ~turn_text:"User prefers concise" in
  (match bumped with
   | [ got ] -> Alcotest.(check int) "access bumped" 3 got.Types.access_count
   | _ -> Alcotest.fail "expected one bumped fact");
  let not_bumped =
    Policy.bump_access_for_turn ~now [ f ] ~turn_text:"completely unrelated"
  in
  match not_bumped with
  | [ got ] -> Alcotest.(check int) "access unchanged" 2 got.Types.access_count
  | _ -> Alcotest.fail "expected one unchanged fact"
;;

let json_episode_file_count ~keeper_id =
  Memory_io.episodes_dir ~keeper_id
  |> Sys.readdir
  |> Array.to_list
  |> List.filter (fun name -> Filename.check_suffix name ".json")
  |> List.length
;;

let test_episode_files_do_not_overwrite_generation () =
  with_temp_keepers_dir (fun _keepers_dir ->
    let keeper_id = "episode-unique-keeper" in
    let first =
      episode_fixture
        ~now:1_000_000.0
        ~trace_id:"trace-same"
        ~generation:9
        ~summary:"first compaction"
    in
    let second =
      episode_fixture
        ~now:1_000_001.0
        ~trace_id:"trace-same"
        ~generation:9
        ~summary:"second compaction"
    in
    Memory_io.append_episode ~keeper_id first;
    Memory_io.append_episode ~keeper_id second;
    Alcotest.(check int) "two episode files persisted" 2 (json_episode_file_count ~keeper_id);
    match Memory_io.read_episodes_tail ~keeper_id ~n:2 with
    | [ older; newer ] ->
      Alcotest.(check string)
        "older summary retained"
        first.Types.episode_summary
        older.Types.episode_summary;
      Alcotest.(check string)
        "newer summary retained"
        second.Types.episode_summary
        newer.Types.episode_summary
    | episodes -> Alcotest.failf "expected two episodes, got %d" (List.length episodes))
;;

let test_episode_file_tail_uses_created_at_not_filename () =
  with_temp_keepers_dir (fun _keepers_dir ->
    let keeper_id = "episode-order-keeper" in
    let older =
      episode_fixture
        ~now:1_000_000.0
        ~trace_id:"trace-zz"
        ~generation:1
        ~summary:"older lexicographically last"
    in
    let newer =
      episode_fixture
        ~now:1_000_100.0
        ~trace_id:"trace-aa"
        ~generation:1
        ~summary:"newer lexicographically first"
    in
    Memory_io.append_episode ~keeper_id older;
    Memory_io.append_episode ~keeper_id newer;
    match Memory_io.read_episodes_tail ~keeper_id ~n:1 with
    | [ got ] ->
      Alcotest.(check string)
        "newest episode returned"
        newer.Types.episode_summary
        got.Types.episode_summary
    | episodes -> Alcotest.failf "expected one episode, got %d" (List.length episodes))
;;

let test_jsonl_tail_reads_last_entries () =
  with_temp_keepers_dir (fun _keepers_dir ->
    let keeper_id = "jsonl-tail-keeper" in
    let first =
      episode_fixture
        ~now:1_000_000.0
        ~trace_id:"trace-first"
        ~generation:1
        ~summary:"first event"
    in
    let second =
      episode_fixture
        ~now:1_000_100.0
        ~trace_id:"trace-second"
        ~generation:2
        ~summary:"second event"
    in
    Memory_io.append_episode_bundle ~keeper_id first;
    Memory_io.append_episode_bundle ~keeper_id second;
    Alcotest.(check int)
      "zero facts requested"
      0
      (List.length (Memory_io.read_facts_tail ~keeper_id ~n:0));
    (match Memory_io.read_facts_tail ~keeper_id ~n:1 with
     | [ fact ] ->
       Alcotest.(check string)
         "last fact returned"
         "second event fact"
         fact.Types.claim
     | facts -> Alcotest.failf "expected one fact, got %d" (List.length facts));
    match Memory_io.read_episodes_tail ~keeper_id ~n:1 with
    | [ event ] ->
      Alcotest.(check string)
        "last episode event returned"
        second.Types.episode_summary
        event.Types.episode_summary
    | events -> Alcotest.failf "expected one event, got %d" (List.length events))
;;

let () =
  Alcotest.run
    "keeper_memory_os"
    [ ( "json"
      , [ Alcotest.test_case "fact and episode round-trip" `Quick test_json_roundtrip
        ] )
    ; ( "policy"
      , [ Alcotest.test_case "score and retention" `Quick test_policy_score_and_retention
        ; Alcotest.test_case "bump access" `Quick test_bump_access
        ] )
    ; ( "io"
      , [ Alcotest.test_case
            "episode files do not overwrite generation"
            `Quick
            test_episode_files_do_not_overwrite_generation
        ; Alcotest.test_case
            "episode file tail uses created_at"
            `Quick
            test_episode_file_tail_uses_created_at_not_filename
        ; Alcotest.test_case
            "jsonl tail reads last entries"
            `Quick
            test_jsonl_tail_reads_last_entries
        ] )
    ]
;;
