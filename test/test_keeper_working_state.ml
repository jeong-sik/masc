open Alcotest

module WS = Masc_mcp.Keeper_working_state

let evidence ?(kind = "pr") target = WS.make_evidence_ref ~kind ~target

let six_w =
  WS.make_six_w ~who:"keeper-a" ~what:"finish PR review"
    ~when_:"2026-05-21T02:00:00+09:00" ~where_:"jeong-sik/masc-mcp"
    ~why:"active work must survive compaction" ~how:"track PR and CI refs"

let active_loop ?(id = "loop-1") ?(title = "PR #1") ?(refs = [ evidence "#1" ])
    () =
  WS.make_loop ~id ~title ~six_w ~evidence_refs:refs ~updated_at_unix:1.0 ()

let capture_exn state loop =
  match WS.capture_loop state loop with
  | Ok state -> state
  | Error error -> fail error

let resolve_exn state ~loop_id ~resolution_refs =
  match WS.resolve_loop state ~loop_id ~resolution_refs ~updated_at_unix:2.0 with
  | Ok state -> state
  | Error error -> fail error

let archive_exn state ~loop_id =
  match WS.archive_resolved_loop state ~loop_id with
  | Ok state -> state
  | Error error -> fail error

let test_capture_adds_active_and_prompt_digest () =
  let state = capture_exn WS.empty (active_loop ()) in
  check int "one active loop" 1 (WS.active_open_loop_count state);
  check (list string) "active loop in digest" [ "loop-1" ] state.prompt_digest_ids;
  check bool "valid" true (Result.is_ok (WS.validate state))

let test_compact_preserves_all_active_before_resolved_tail () =
  let state =
    WS.empty
    |> fun state -> capture_exn state (active_loop ~id:"active-1" ())
    |> fun state -> capture_exn state (active_loop ~id:"active-2" ())
    |> fun state ->
    resolve_exn state ~loop_id:"active-2" ~resolution_refs:[ evidence "ci-green" ]
    |> fun state -> capture_exn state (active_loop ~id:"active-3" ())
  in
  let compacted = WS.compact ~max_digest:2 state in
  check (list string) "active IDs are never dropped" [ "active-1"; "active-3" ]
    compacted.prompt_digest_ids;
  check bool "valid" true (Result.is_ok (WS.validate compacted))

let test_resolve_requires_resolution_ref () =
  let state = capture_exn WS.empty (active_loop ()) in
  match WS.resolve_loop state ~loop_id:"loop-1" ~resolution_refs:[] ~updated_at_unix:2.0 with
  | Ok _ -> fail "expected missing resolution_ref rejection"
  | Error error ->
    check bool "mentions resolution_ref" true
      (String.contains error 'r')

let test_archive_moves_resolved_loop () =
  let state =
    capture_exn WS.empty (active_loop ())
    |> fun state -> resolve_exn state ~loop_id:"loop-1" ~resolution_refs:[ evidence "merged" ]
    |> fun state -> archive_exn state ~loop_id:"loop-1"
  in
  check int "no active" 0 (List.length state.active_loops);
  check int "no resolved" 0 (List.length state.resolved_loops);
  check int "one archived" 1 (List.length state.archived_loops);
  check bool "valid" true (Result.is_ok (WS.validate state))

let test_archive_cap_keeps_recent_history () =
  let archive_with_cap state ~loop_id =
    match WS.archive_resolved_loop ~max_archived:1 state ~loop_id with
    | Ok state -> state
    | Error error -> fail error
  in
  let state =
    WS.empty
    |> fun state -> capture_exn state (active_loop ~id:"older" ())
    |> fun state -> capture_exn state (active_loop ~id:"newer" ())
    |> fun state -> resolve_exn state ~loop_id:"older" ~resolution_refs:[ evidence "old" ]
    |> fun state -> resolve_exn state ~loop_id:"newer" ~resolution_refs:[ evidence "new" ]
    |> fun state -> archive_with_cap state ~loop_id:"older"
    |> fun state -> archive_with_cap state ~loop_id:"newer"
  in
  check (list string) "keeps newest archived loop" [ "newer" ]
    (List.map (fun loop -> loop.WS.id) state.archived_loops)

let test_validate_rejects_active_missing_from_digest () =
  let state = { (capture_exn WS.empty (active_loop ())) with prompt_digest_ids = [] } in
  match WS.validate state with
  | Ok () -> fail "expected prompt digest invariant failure"
  | Error errors ->
    check bool "reports active digest miss" true
      (List.exists
         (fun error -> String.contains error 'p' && String.contains error 'd')
         errors)

let test_json_roundtrip () =
  let state =
    capture_exn WS.empty (active_loop ())
    |> fun state -> resolve_exn state ~loop_id:"loop-1" ~resolution_refs:[ evidence "closed" ]
  in
  let json = WS.to_json state in
  match WS.of_json json with
  | Error error -> fail error
  | Ok decoded ->
    check (list string) "prompt digest" state.prompt_digest_ids decoded.prompt_digest_ids;
    check int "resolved count" 1 (List.length decoded.resolved_loops);
    check bool "valid" true (Result.is_ok (WS.validate decoded))

let () =
  run "Keeper_working_state"
    [
      ( "lifecycle",
        [
          test_case "capture adds active loop and digest" `Quick
            test_capture_adds_active_and_prompt_digest;
          test_case "compact preserves active loops" `Quick
            test_compact_preserves_all_active_before_resolved_tail;
          test_case "resolve requires resolution ref" `Quick
            test_resolve_requires_resolution_ref;
          test_case "archive moves resolved loop" `Quick test_archive_moves_resolved_loop;
          test_case "archive cap keeps recent history" `Quick
            test_archive_cap_keeps_recent_history;
        ] );
      ( "validation",
        [
          test_case "active loop must appear in digest" `Quick
            test_validate_rejects_active_missing_from_digest;
          test_case "json roundtrip" `Quick test_json_roundtrip;
        ] );
    ]
