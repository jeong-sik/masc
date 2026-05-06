(** Chronicle_ingest — parse, extract, group tests.
    Uses git_capture_hook_for_tests for isolated mock git output.
    @since Project Chronicle Phase 2 *)

open Alcotest

module CI = Masc_mcp.Chronicle_ingest
module CM = Masc_mcp.Chronicle_memory

(* --- parse_git_log tests --- *)

let sample_log =
  "abc0001\000\0002026-05-01T10:00:00+09:00\000feat: add PK-123 types\n\
   lib/chronicle_types.ml\n\
   lib/chronicle_types.mli\n\
   \n\
   abc0002\000abc0001\0002026-05-01T11:00:00+09:00\000fix: PK-123 typo\n\
   lib/chronicle_types.ml\n\
   \n\
   abc0003\000abc0002\0002026-05-02T09:00:00+09:00\000chore: unrelated cleanup\n\
   scripts/helper.sh\n"

let test_parse_empty () =
  let events = CI.parse_git_log "" in
  check int "empty input" 0 (List.length events)

let test_parse_single_commit () =
  let log = "abc0001\000\0002026-05-01T10:00:00+09:00\000initial commit\n\
             lib/foo.ml\n" in
  let events = CI.parse_git_log log in
  check int "1 commit" 1 (List.length events);
  let ev = List.hd events in
  check string "sha" "abc0001" ev.CI.sha;
  check int "no parents" 0 (List.length ev.CI.parents);
  check string "date" "2026-05-01T10:00:00+09:00" ev.CI.author_date;
  check string "subject" "initial commit" ev.CI.subject;
  check int "1 file" 1 (List.length ev.CI.files);
  check string "file" "lib/foo.ml" (List.hd ev.CI.files)

let test_parse_multiple_commits () =
  let events = CI.parse_git_log sample_log in
  check int "3 commits" 3 (List.length events);
  let first = List.hd events in
  check string "first sha" "abc0001" first.CI.sha;
  check int "first has 2 files" 2 (List.length first.CI.files);
  let second = List.nth events 1 in
  check int "second has 1 parent" 1 (List.length second.CI.parents);
  check string "parent sha" "abc0001" (List.hd second.CI.parents)

(* --- extract_goal_ids tests --- *)

let test_extract_from_subject () =
  let ev = { CI.sha = "a"; CI.parents = []; CI.author_date = ""; CI.subject = "feat: PK-12345 new module"; CI.files = [] } in
  let ids = CI.extract_goal_ids ev in
  check int "1 goal id" 1 (List.length ids);
  check string "goal id" "PK-12345" (List.hd ids)

let test_extract_task_pattern () =
  let ev = { CI.sha = "a"; CI.parents = []; CI.author_date = ""; CI.subject = "task-42 cleanup"; CI.files = [] } in
  let ids = CI.extract_goal_ids ev in
  check bool "contains task-42" (List.mem "task-42" ids) true

let test_extract_hash_pattern () =
  let ev = { CI.sha = "a"; CI.parents = []; CI.author_date = ""; CI.subject = "fix issue #789"; CI.files = [] } in
  let ids = CI.extract_goal_ids ev in
  check bool "contains #789" (List.mem "#789" ids) true

let test_extract_from_files () =
  let ev = { CI.sha = "a"; CI.parents = []; CI.author_date = ""; CI.subject = "misc"; CI.files = [ "planning/task-059/context.json"; "lib/core.ml" ] } in
  let ids = CI.extract_goal_ids ev in
  check bool "extracts task-059 from path" (List.mem "task-059" ids) true

let test_extract_no_match () =
  let ev = { CI.sha = "a"; CI.parents = []; CI.author_date = ""; CI.subject = "misc cleanup"; CI.files = [ "README.md" ] } in
  let ids = CI.extract_goal_ids ev in
  check int "no goal ids" 0 (List.length ids)

let test_extract_dedup () =
  let ev = { CI.sha = "a"; CI.parents = []; CI.author_date = ""; CI.subject = "PK-100 fix"; CI.files = [ "planning/PK-100/plan.md" ] } in
  let ids = CI.extract_goal_ids ev in
  check int "deduplicated" 1 (List.length ids)

(* --- group_events tests --- *)

let test_group_single_goal () =
  let events =
    [ { CI.sha = "a1"; CI.parents = []; CI.author_date = "2026-05-01T10:00:00Z"; CI.subject = "PK-100 start"; CI.files = [] }
    ; { CI.sha = "a2"; CI.parents = [ "a1" ]; CI.author_date = "2026-05-01T11:00:00Z"; CI.subject = "PK-100 continue"; CI.files = [] }
    ; { CI.sha = "a3"; CI.parents = [ "a2" ]; CI.author_date = "2026-05-01T12:00:00Z"; CI.subject = "PK-100 finish"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events events in
  check int "1 epoch" 1 (List.length epochs);
  let ep = List.hd epochs in
  check int "3 commits" 3 ep.CI.commit_count;
  check bool "has PK-100 goal" (List.mem "PK-100" ep.CI.goal_ids) true

let test_group_separate_goals () =
  let events =
    [ { CI.sha = "a1"; CI.parents = []; CI.author_date = "2026-05-01T10:00:00Z"; CI.subject = "PK-100 work"; CI.files = [] }
    ; { CI.sha = "b1"; CI.parents = []; CI.author_date = "2026-05-02T10:00:00Z"; CI.subject = "PK-200 work"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events events in
  check int "2 epochs" 2 (List.length epochs)

let test_group_ungrouped_by_time () =
  let events =
    [ { CI.sha = "a1"; CI.parents = []; CI.author_date = "2026-05-01T10:00:00Z"; CI.subject = "cleanup 1"; CI.files = [] }
    ; { CI.sha = "a2"; CI.parents = []; CI.author_date = "2026-05-02T10:00:00Z"; CI.subject = "cleanup 2"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events ~time_window_days:7 events in
  check int "1 time-grouped epoch" 1 (List.length epochs)

let test_group_ungrouped_outside_window () =
  let events =
    [ { CI.sha = "a1"; CI.parents = []; CI.author_date = "2026-05-01T10:00:00Z"; CI.subject = "cleanup 1"; CI.files = [] }
    ; { CI.sha = "a2"; CI.parents = []; CI.author_date = "2026-06-01T10:00:00Z"; CI.subject = "cleanup 2"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events ~time_window_days:7 events in
  check int "2 separate epochs" 2 (List.length epochs)

let test_group_empty () =
  let epochs = CI.group_events [] in
  check int "empty" 0 (List.length epochs)

(* --- git_capture_hook integration --- *)

let test_ingest_range_mock () =
  let mock_hook ~workdir:_ args =
    match args with
    | [ "log"; "--format=%H%x00%P%x00%aI%x00%s"; "--name-only"; "abc..def" ] ->
      Some (Unix.WEXITED 0, sample_log)
    | _ -> None
  in
  CI.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CI.clear_git_capture_hook_for_tests ())
    (fun () ->
      let epochs =
        CI.ingest_range
          ~workdir:"/fake/repo"
          ~from:"abc"
          ~to_:"def"
          ()
      in
      check bool "at least 1 epoch" true (List.length epochs >= 1))

let test_ingest_since_no_change () =
  let mock_hook ~workdir:_ = function
    | [ "rev-parse"; "HEAD" ] ->
      Some (Unix.WEXITED 0, "samecommit\n")
    | _ -> None
  in
  CI.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CI.clear_git_capture_hook_for_tests ())
    (fun () ->
      let epochs =
        CI.ingest_since
          ~workdir:"/fake/repo"
          ~last_commit:"samecommit"
          ()
      in
      check int "no change = empty" 0 (List.length epochs))

(* --- candidate_epoch fields --- *)

let test_candidate_epoch_fields () =
  let events =
    [ { CI.sha = "a1"; CI.parents = []; CI.author_date = "2026-05-01T10:00:00Z"; CI.subject = "feat: PK-999 new feature"; CI.files = [ "lib/a.ml"; "lib/b.ml" ] }
    ]
  in
  let epochs = CI.group_events events in
  check int "1 epoch" 1 (List.length epochs);
  let ep = List.hd epochs in
  check string "id" "PK-999" ep.CI.id;
  check string "start_commit" "a1" ep.CI.start_commit;
  check string "end_commit" "a1" ep.CI.end_commit;
  check int "commit_count" 1 ep.CI.commit_count;
  check int "2 files" 2 (List.length ep.CI.file_paths)

let test_candidate_epoch_no_goal_uses_sha () =
  let events =
    [ { CI.sha = "deadbeef1234567"; CI.parents = []; CI.author_date = "2026-03-15T10:00:00Z"; CI.subject = "random work"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events events in
  let ep = List.hd epochs in
  check bool "id starts with year" (String.length ep.CI.id > 4) true;
  check bool "id contains cluster" (String.contains ep.CI.id '-') true

(* --- chronicle memory injection tests --- *)

let sample_epoch : CI.candidate_epoch =
  { id = "PK-999"
  ; label = "ship chronicle memory adapter"
  ; start_commit = "abcdef1234560000"
  ; end_commit = "abcdef1234569999"
  ; start_date = "2026-05-01"
  ; end_date = "2026-05-02"
  ; goal_ids = [ "PK-999"; "task-123" ]
  ; file_paths = [ "lib/chronicle_memory.ml"; "test/test_chronicle_ingest.ml" ]
  ; commit_count = 2
  }

let metadata_string key metadata =
  match List.assoc_opt key metadata with
  | Some (`String value) -> Some value
  | _ -> None

let metadata_list key metadata =
  match List.assoc_opt key metadata with
  | Some (`List values) ->
      values
      |> List.filter_map (function
           | `String value -> Some value
           | _ -> None)
  | _ -> []

let metadata_context_string key metadata =
  match List.assoc_opt "context" metadata with
  | Some (`Assoc fields) ->
      (match List.assoc_opt key fields with
       | Some (`String value) -> Some value
       | _ -> None)
  | _ -> None

let test_chronicle_memory_episode_shape () =
  let episode =
    CM.episode_of_candidate ~timestamp:42.0 ~keeper_name:"sangsu" sample_epoch
  in
  check string "deterministic id"
    "git-chronicle-PK-999-abcdef123456" episode.id;
  check (float 0.001) "timestamp" 42.0 episode.timestamp;
  check string "participant" "sangsu" (List.hd episode.participants);
  check string "event type" "git_chronicle"
    (Option.value ~default:""
       (metadata_string "event_type" episode.metadata));
  check string "source context" "git_chronicle"
    (Option.value ~default:""
       (metadata_context_string "source" episode.metadata));
  check string "epoch id context" "PK-999"
    (Option.value ~default:""
       (metadata_context_string "epoch_id" episode.metadata));
  check bool "goal ids metadata"
    true
    (List.mem "task-123" (metadata_list "goal_ids" episode.metadata));
  let expected_summary =
    "Git chronicle PK-999: ship chronicle memory adapter (2 commits; files: \
     lib/chronicle_memory.ml, test/test_chronicle_ingest.ml)"
  in
  check string "summary includes structured commit count" expected_summary
    episode.action

let test_chronicle_memory_default_timestamp_uses_epoch_end_date () =
  let episode = CM.episode_of_candidate ~keeper_name:"sangsu" sample_epoch in
  let tm = Unix.gmtime episode.timestamp in
  check int "year" 2026 (tm.Unix.tm_year + 1900);
  check int "month" 5 (tm.Unix.tm_mon + 1);
  check int "day" 2 tm.Unix.tm_mday;
  check int "hour" 0 tm.Unix.tm_hour;
  check int "minute" 0 tm.Unix.tm_min

let test_chronicle_memory_store_recall () =
  let memory = Agent_sdk.Memory.create () in
  let expected =
    CM.episode_of_candidate ~keeper_name:"sangsu" sample_epoch
  in
  let stored =
    CM.store_candidate_epochs ~memory ~keeper_name:"sangsu" [ sample_epoch ]
  in
  check int "stored count" 1 stored;
  let recalled =
    Agent_sdk.Memory.recall_episodes memory ~now:expected.timestamp ~limit:10 ()
  in
  check int "recalled count" 1 (List.length recalled);
  let episode = List.hd recalled in
  check string "recalled id"
    "git-chronicle-PK-999-abcdef123456" episode.id;
  check string "recalled event type" "git_chronicle"
    (Option.value ~default:""
       (metadata_string "event_type" episode.metadata))

let test_chronicle_memory_store_timestamp_override () =
  let memory = Agent_sdk.Memory.create () in
  CM.store_candidate_epoch ~timestamp:84.0 ~memory ~keeper_name:"sangsu"
    sample_epoch;
  let episode =
    Agent_sdk.Memory.recall_episodes memory ~now:84.0 ~limit:10 () |> List.hd
  in
  check (float 0.001) "stored timestamp override" 84.0 episode.timestamp

let () =
  run "Chronicle_ingest" [
    ("parse_git_log", [
      test_case "empty" `Quick test_parse_empty;
      test_case "single commit" `Quick test_parse_single_commit;
      test_case "multiple commits" `Quick test_parse_multiple_commits;
    ]);
    ("extract_goal_ids", [
      test_case "PK pattern" `Quick test_extract_from_subject;
      test_case "task pattern" `Quick test_extract_task_pattern;
      test_case "hash pattern" `Quick test_extract_hash_pattern;
      test_case "from file path" `Quick test_extract_from_files;
      test_case "no match" `Quick test_extract_no_match;
      test_case "dedup" `Quick test_extract_dedup;
    ]);
    ("group_events", [
      test_case "single goal cluster" `Quick test_group_single_goal;
      test_case "separate goals" `Quick test_group_separate_goals;
      test_case "ungrouped by time window" `Quick test_group_ungrouped_by_time;
      test_case "outside time window" `Quick test_group_ungrouped_outside_window;
      test_case "empty" `Quick test_group_empty;
    ]);
    ("mock_git", [
      test_case "ingest_range" `Quick test_ingest_range_mock;
      test_case "ingest_since no change" `Quick test_ingest_since_no_change;
    ]);
    ("candidate_epoch", [
      test_case "fields" `Quick test_candidate_epoch_fields;
      test_case "no-goal uses sha" `Quick test_candidate_epoch_no_goal_uses_sha;
    ]);
    ("chronicle_memory", [
      test_case "episode shape" `Quick test_chronicle_memory_episode_shape;
      test_case "default timestamp uses epoch end date" `Quick
        test_chronicle_memory_default_timestamp_uses_epoch_end_date;
      test_case "store recall" `Quick test_chronicle_memory_store_recall;
      test_case "store timestamp override" `Quick
        test_chronicle_memory_store_timestamp_override;
    ]);
  ]
