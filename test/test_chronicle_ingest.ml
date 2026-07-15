(** Chronicle_ingest — parse, extract, group tests.
    Uses git_capture_hook_for_tests for isolated mock git output.
    @since Project Chronicle Phase 2 *)

open Alcotest

module CI = Masc.Chronicle_ingest

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

(* --- group_events tests --- *)

let test_group_single_window () =
  let events =
    [ { CI.sha = "a1"; CI.parents = []; CI.author_date = "2026-05-01T10:00:00Z"; CI.subject = "PK-100 start"; CI.files = [] }
    ; { CI.sha = "a2"; CI.parents = [ "a1" ]; CI.author_date = "2026-05-01T11:00:00Z"; CI.subject = "PK-100 continue"; CI.files = [] }
    ; { CI.sha = "a3"; CI.parents = [ "a2" ]; CI.author_date = "2026-05-01T12:00:00Z"; CI.subject = "PK-100 finish"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events events in
  check int "1 epoch" 1 (List.length epochs);
  let ep = List.hd epochs in
  check int "3 commits" 3 ep.CI.commit_count

let test_group_separate_windows () =
  let events =
    [ { CI.sha = "a1"; CI.parents = []; CI.author_date = "2026-05-01T10:00:00Z"; CI.subject = "PK-100 work"; CI.files = [] }
    ; { CI.sha = "b1"; CI.parents = []; CI.author_date = "2026-05-02T10:00:00Z"; CI.subject = "PK-200 work"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events ~time_window_days:0 events in
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
  check string "id" "2026-cluster-a1" ep.CI.id;
  check string "start_commit" "a1" ep.CI.start_commit;
  check string "end_commit" "a1" ep.CI.end_commit;
  check int "commit_count" 1 ep.CI.commit_count;
  check int "2 files" 2 (List.length ep.CI.file_paths)

let test_candidate_epoch_uses_sha () =
  let events =
    [ { CI.sha = "deadbeef1234567"; CI.parents = []; CI.author_date = "2026-03-15T10:00:00Z"; CI.subject = "random work"; CI.files = [] }
    ]
  in
  let epochs = CI.group_events events in
  let ep = List.hd epochs in
  check bool "id starts with year" (String.length ep.CI.id > 4) true;
  check bool "id contains cluster" (String.contains ep.CI.id '-') true

(* --- chronicle ingest metadata tests --- *)

let sample_epoch : CI.candidate_epoch =
  { id = "PK-999"
  ; label = "ship chronicle memory adapter"
  ; start_commit = "abcdef1234560000"
  ; end_commit = "abcdef1234569999"
  ; start_date = "2026-05-01"
  ; end_date = "2026-05-02"
  ; file_paths = [ "lib/chronicle_memory.ml"; "test/test_chronicle_ingest.ml" ]
  ; commit_count = 2
  }

let () =
  run "Chronicle_ingest" [
    ("parse_git_log", [
      test_case "empty" `Quick test_parse_empty;
      test_case "single commit" `Quick test_parse_single_commit;
      test_case "multiple commits" `Quick test_parse_multiple_commits;
    ]);
    ("group_events", [
      test_case "single time window" `Quick test_group_single_window;
      test_case "separate time windows" `Quick test_group_separate_windows;
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
      test_case "uses sha" `Quick test_candidate_epoch_uses_sha;
    ]);
  ]
