open Alcotest

module WS = Masc.Keeper_working_state

let evidence ?(kind = "pr") target = WS.make_evidence_ref ~kind ~target

let six_w =
  WS.make_six_w ~who:"keeper-a" ~what:"finish PR review"
    ~when_:"2026-05-21T02:00:00+09:00" ~where_:"jeong-sik/masc"
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

let test_projector_maps_snapshot_items_to_active_loops () =
  let snapshot =
    { Masc.Keeper_memory_policy.empty_keeper_state_snapshot with
      next_items = [ "finish PR"; " "; "finish PR" ]
    ; open_questions = [ "check CI?" ]
    }
  in
  let state =
    Masc.Keeper_working_state_projector.of_state_snapshot
      ~keeper_name:"keeper-a"
      ~trace_id:"trace-1"
      ~keeper_turn_id:7
      ~updated_at_iso:"2026-05-21T02:00:00+09:00"
      ~updated_at_unix:3.0
      snapshot
  in
  check int "deduped active loop count" 1 (WS.active_open_loop_count state);
  check (list string)
    "open questions do not become active loops"
    [ "finish PR" ]
    (state.WS.active_loops |> List.map (fun loop -> loop.WS.title));
  check (list string) "digest covers active loops"
    (List.map (fun loop -> loop.WS.id) state.active_loops)
    state.prompt_digest_ids;
  check bool "valid projected state" true (Result.is_ok (WS.validate state))

let test_projector_ignores_budget_synthetic_summary_as_loop () =
  let snapshot =
    Masc.Keeper_memory_policy.synthesize_state_from_run_result
      ~goal:"Fix task"
      ~tools_used:["tool_execute"]
      ~stop_reason:"budget_exhausted"
      ~response_text:"Continuation checkpoint saved; keeper remains scheduled"
  in
  let state =
    Masc.Keeper_working_state_projector.of_state_snapshot
      ~keeper_name:"keeper-a"
      ~trace_id:"trace-1"
      ~keeper_turn_id:8
      ~updated_at_iso:"2026-05-21T02:00:00+09:00"
      ~updated_at_unix:4.0
      snapshot
  in
  check int "synthetic budget summary is not an active loop" 0
    (WS.active_open_loop_count state);
  check (list string) "no prompt digest loops" [] state.prompt_digest_ids;
  check bool "valid projected state" true (Result.is_ok (WS.validate state))

(* Resume-merge / readback (ResumeFromDigest) tests.

   These reproduce and close the write-only-sidecar silent-loss bug: before the
   wire, [of_json] had zero callers, so a persisted active loop the model omits
   from the next [STATE] vanished from both the prompt and the sidecar. *)

let projected_snapshot ?(next_items = []) ?(open_questions = []) () =
  let snapshot =
    { Masc.Keeper_memory_policy.empty_keeper_state_snapshot with
      next_items
    ; open_questions
    }
  in
  Masc.Keeper_working_state_projector.of_state_snapshot
    ~keeper_name:"keeper-a"
    ~trace_id:"trace-1"
    ~keeper_turn_id:1
    ~updated_at_iso:"2026-05-21T02:00:00+09:00"
    ~updated_at_unix:3.0
    snapshot

let active_titles state =
  state.WS.active_loops |> List.map (fun loop -> loop.WS.title) |> List.sort compare

(* Silent-loss fix: a persisted active loop survives resume even when the
   current [STATE] snapshot omits it entirely. *)
let test_merge_resume_preserves_persisted_active_when_snapshot_omits () =
  let persisted = projected_snapshot ~next_items:[ "finish PR review" ] () in
  check int "persisted has one active loop" 1 (WS.active_open_loop_count persisted);
  (* Resume turn: the model re-emits a different loop and OMITS the persisted one. *)
  let current = projected_snapshot ~next_items:[ "write changelog" ] () in
  let merged = WS.merge_resume ~persisted ~current in
  check (list string) "both the persisted and current active loops survive"
    [ "finish PR review"; "write changelog" ]
    (active_titles merged);
  check bool "merged state is valid" true (Result.is_ok (WS.validate merged));
  List.iter
    (fun loop ->
      check bool
        (Printf.sprintf "active loop %s is in prompt digest" loop.WS.id)
        true
        (List.mem loop.WS.id merged.WS.prompt_digest_ids))
    merged.WS.active_loops

(* Regression guard: a loop the persisted ledger has already resolved must NOT
   resurrect on resume, even though merge carries persisted history forward. *)
let test_merge_resume_does_not_resurrect_resolved () =
  let persisted =
    capture_exn WS.empty (active_loop ~id:"loop-done" ~title:"closed work" ())
    |> fun state ->
    resolve_exn state ~loop_id:"loop-done" ~resolution_refs:[ evidence "merged" ]
  in
  check int "persisted has no active loops" 0 (WS.active_open_loop_count persisted);
  let current = projected_snapshot ~next_items:[ "new task" ] () in
  let merged = WS.merge_resume ~persisted ~current in
  check int "resolved loop is not resurrected as active" 1
    (WS.active_open_loop_count merged);
  check (list string) "only the current active loop is active" [ "new task" ]
    (active_titles merged);
  check int "resolved history carried forward" 1
    (List.length merged.WS.resolved_loops);
  check bool "merged state is valid" true (Result.is_ok (WS.validate merged))

(* Completion-by-omission must still work on a NORMAL turn (no resume merge):
   the snapshot projection alone is authoritative, so a loop the model drops
   from [STATE] clears. This is the mirror that fails under unconditional union. *)
let test_normal_turn_projection_drops_omitted_loop () =
  let turn1 = projected_snapshot ~next_items:[ "finish PR review" ] () in
  check int "turn 1 has the loop" 1 (WS.active_open_loop_count turn1);
  (* Turn 2 omits it; on a normal (non-resume) turn no merge happens, so the
     projection-only state has zero active loops — the loop is completed. *)
  let turn2 = projected_snapshot ~next_items:[] () in
  check int "turn 2 projection drops the omitted loop" 0
    (WS.active_open_loop_count turn2);
  check (list string) "no active loops remain" [] (active_titles turn2)

(* Readback through the real sidecar payload shape (working_state wrapped under
   the "working_state" key, latest filename working-state.latest.json). *)
let sidecar_payload working_state =
  `Assoc
    [ ("schema_version", `Int 1)
    ; ("keeper_name", `String "keeper-a")
    ; ("working_state", WS.to_json working_state)
    ]

let test_readback_roundtrip_through_sidecar_payload () =
  let dir = Filename.temp_file "crw_readback_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let latest_path = Filename.concat dir "working-state.latest.json" in
  let persisted = projected_snapshot ~next_items:[ "finish PR review" ] () in
  Fs_compat.save_file latest_path
    (Yojson.Safe.pretty_to_string (sidecar_payload persisted));
  match
    Masc.Keeper_agent_run_sidecar.read_persisted_working_state
      ~keeper_name:"keeper-a" ~latest_path
  with
  | None -> fail "expected readback to recover the persisted ledger"
  | Some recovered ->
    check int "recovered one active loop" 1 (WS.active_open_loop_count recovered);
    check (list string) "recovered the persisted loop" [ "finish PR review" ]
      (active_titles recovered)

let test_readback_absent_file_returns_none () =
  let dir = Filename.temp_file "crw_absent_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let latest_path = Filename.concat dir "working-state.latest.json" in
  check bool "absent file falls back to None" true
    (Masc.Keeper_agent_run_sidecar.read_persisted_working_state
       ~keeper_name:"keeper-a" ~latest_path
     = None)

let test_readback_corrupt_file_returns_none () =
  let dir = Filename.temp_file "crw_corrupt_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let latest_path = Filename.concat dir "working-state.latest.json" in
  Fs_compat.save_file latest_path "{ this is not valid json";
  check bool "corrupt file falls back to None" true
    (Masc.Keeper_agent_run_sidecar.read_persisted_working_state
       ~keeper_name:"keeper-a" ~latest_path
     = None)

(* End-to-end wire test: drive the real [save_sidecars] (the production save
   seam) so the glue — read-back path, gating, merge, write-back — is exercised,
   not just the pure components. This is the test that fails if [resume_merge] is
   inverted, the path is wrong, or the merge result is dropped. *)

let noop_manifest : Masc.Keeper_agent_run_sidecar.append_manifest_fn =
  fun ?elapsed_ms:_ ?logical_seq:_ ?status:_ ?decision:_ ?keeper_turn_id:_
      ?oas_turn_count:_ ?checkpoint_path:_ ?compaction_source:_ ~site:_ _ ->
  ()

let snapshot_with ?(next_items = []) ?(open_questions = []) () =
  { Masc.Keeper_memory_policy.empty_keeper_state_snapshot with
    next_items
  ; open_questions
  }

let save_through_sidecar ~session_dir ~resume_merge ~next_items ~keeper_turn_id =
  ignore
    (Masc.Keeper_agent_run_sidecar.save_sidecars
       ~keeper_name:"keeper-a"
       ~agent_name:"agent-a"
       ~trace_id:"trace-1"
       ~generation:0
       ~keeper_turn_id
       ~oas_turn_count:1
       ~session_dir
       ~state_snapshot:(snapshot_with ~next_items ())
       ~state_snapshot_source:"model_state_block"
       ~resume_merge
       ~append_manifest:noop_manifest
       ())

let read_latest_active_titles ~session_dir =
  let latest_path = Filename.concat session_dir "working-state.latest.json" in
  let json = Yojson.Safe.from_file latest_path in
  match WS.of_json (Yojson.Safe.Util.member "working_state" json) with
  | Error e -> fail e
  | Ok state -> active_titles state

let with_temp_session_dir f =
  let dir = Filename.temp_file "crw_session_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  f dir

(* Resume turn: turn 1 persists an active loop, turn 2 (resume_merge=true) omits
   it from the snapshot -> the latest sidecar still carries it. Without the wire
   the second save would overwrite the file with the empty projection. *)
let test_save_sidecars_resume_preserves_omitted_loop () =
  with_temp_session_dir (fun session_dir ->
      save_through_sidecar ~session_dir ~resume_merge:false
        ~next_items:[ "finish PR review" ] ~keeper_turn_id:1;
      check (list string) "turn 1 persisted the loop" [ "finish PR review" ]
        (read_latest_active_titles ~session_dir);
      save_through_sidecar ~session_dir ~resume_merge:true ~next_items:[]
        ~keeper_turn_id:2;
      check (list string)
        "resume turn preserves the omitted loop in the latest sidecar"
        [ "finish PR review" ]
        (read_latest_active_titles ~session_dir))

(* Normal turn: omission clears the loop because no merge happens. This proves
   completion-by-omission still works through the real save seam. *)
let test_save_sidecars_normal_turn_clears_omitted_loop () =
  with_temp_session_dir (fun session_dir ->
      save_through_sidecar ~session_dir ~resume_merge:false
        ~next_items:[ "finish PR review" ] ~keeper_turn_id:1;
      save_through_sidecar ~session_dir ~resume_merge:false ~next_items:[]
        ~keeper_turn_id:2;
      check (list string)
        "normal turn drops the omitted loop from the latest sidecar" []
        (read_latest_active_titles ~session_dir))

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
          test_case "projector maps snapshot items to active loops" `Quick
            test_projector_maps_snapshot_items_to_active_loops;
          test_case "projector ignores budget synthetic summary as loop" `Quick
            test_projector_ignores_budget_synthetic_summary_as_loop;
        ] );
      ( "resume_merge",
        [
          test_case "resume preserves persisted active loop when snapshot omits"
            `Quick test_merge_resume_preserves_persisted_active_when_snapshot_omits;
          test_case "resume does not resurrect resolved loop" `Quick
            test_merge_resume_does_not_resurrect_resolved;
          test_case "normal turn projection drops omitted loop" `Quick
            test_normal_turn_projection_drops_omitted_loop;
          test_case "readback roundtrips through sidecar payload" `Quick
            test_readback_roundtrip_through_sidecar_payload;
          test_case "readback of absent file returns none" `Quick
            test_readback_absent_file_returns_none;
          test_case "readback of corrupt file returns none" `Quick
            test_readback_corrupt_file_returns_none;
          test_case "save_sidecars resume preserves omitted loop" `Quick
            test_save_sidecars_resume_preserves_omitted_loop;
          test_case "save_sidecars normal turn clears omitted loop" `Quick
            test_save_sidecars_normal_turn_clears_omitted_loop;
        ] );
    ]
