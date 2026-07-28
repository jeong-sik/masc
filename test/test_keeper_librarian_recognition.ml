(* Recognition apply semantics (masc#26122 acceptance criteria):
   - Reinforce updates the existing row in place (no new row; last_verified_at
     and reinforcement_count move) — re-observation is NOT an append;
   - Forget removes a row and Merge collapses rows — the store can shrink
     (no monotonic-growth invariant);
   - Add appends; Revise rewrites in place preserving first_seen;
   - out-of-range and doubly-targeted indices are typed rejections leaving
     the store unchanged;
   - merge gates (claim_kind / valid_until representability) reject without
     collapsing metadata.
   All checks drive the pure [Keeper_librarian_recognition.apply]; no IO. *)

open Alcotest
module Recognition = Masc.Keeper_librarian_recognition
module Consolidation = Masc.Keeper_memory_os_consolidation
module Ledger = Masc.Keeper_librarian_recognition_ledger
module Librarian = Masc.Keeper_librarian
module Librarian_runtime = Masc.Keeper_librarian_runtime
module Recognition_operator = Masc.Keeper_librarian_recognition_operator
module Memory_io = Masc.Keeper_memory_os_io
module Recall = Masc.Keeper_memory_os_recall
module Types = Masc.Keeper_memory_os_types
module Keeper_fs = Masc.Keeper_fs

let now = 2_000_000.0

let fact ?(claim = "c") ?(category = Types.Fact) ?claim_kind ?claim_id
      ?(first_seen = 1_000_000.0) ?valid_until ?(reinforcement_count = 0) ()
  : Types.fact
  =
  { Types.claim
  ; category
  ; claim_kind
  ; source = { Types.trace_id = "t"; turn = 1; tool_call_id = None }
  ; observed_by = []
  ; first_seen
  ; valid_until
  ; last_verified_at = None
  ; schema_version = Types.schema_version
  ; claim_id
  ; reinforcement_count
  }
;;

let claims facts = List.map (fun (f : Types.fact) -> f.Types.claim) facts

let apply operations facts = Recognition.apply ~now ~operations facts

let episode ?(claims = []) () : Types.episode =
  { trace_id = "trace-current"
  ; generation = 7
  ; episode_summary = "recognition publication"
  ; claims
  ; open_items = [ "follow up" ]
  ; constraints = [ "preserve evidence" ]
  ; preserved_tool_refs = []
  ; source_turn_range = Some (1, 1)
  ; created_at = now
  ; valid_until = None
  ; terminal_marker = None
  ; schema_version = Types.schema_version
  }
;;

let merge ?claim_id ?(source_turn = 9) group =
  Recognition.Merge { group; claim_id; source_turn }
;;

let test_reinforce_updates_in_place () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" ~reinforcement_count:2 () ] in
  let result = apply [ Recognition.Reinforce { index = 1; source_turn = 9 } ] store in
  check int "row count unchanged" 2 (List.length result.Recognition.facts);
  check (list string) "claims unchanged" [ "a"; "b" ] (claims result.Recognition.facts);
  let reinforced = List.nth result.Recognition.facts 1 in
  check int "reinforcement_count incremented" 3 reinforced.Types.reinforcement_count;
  check (option (float 0.0)) "last_verified_at set to now" (Some now)
    reinforced.Types.last_verified_at;
  check (float 0.0) "first_seen preserved" 1_000_000.0 reinforced.Types.first_seen;
  check int "reinforce produces no episode claims" 0
    (List.length result.Recognition.recognized_facts);
  check (list string) "applied" [ "applied" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_forget_shrinks_store () =
  let store = [ fact ~claim:"keep" (); fact ~claim:"drop" () ] in
  let result = apply [ Recognition.Forget { index = 1; reason = "superseded" } ] store in
  check (list string) "store shrank to the survivor" [ "keep" ]
    (claims result.Recognition.facts)
;;

let test_merge_collapses_rows () =
  let store =
    [ fact ~claim:"first wording" ~first_seen:1_000.0 ~reinforcement_count:1 ()
    ; fact ~claim:"untouched" ()
    ; fact ~claim:"second wording" ~first_seen:2_000.0 ~reinforcement_count:2 ()
    ]
  in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 2 ]
          ; consolidated_claim = "one merged claim"
          ; category = Types.Lesson
          }
      ]
      store
  in
  (* 3 -> 2: merged row takes the earliest member's slot. *)
  check (list string) "merged row anchors at earliest member"
    [ "one merged claim"; "untouched" ]
    (claims result.Recognition.facts);
  let merged = List.hd result.Recognition.facts in
  check (float 0.0) "first_seen is min of members" 1_000.0 merged.Types.first_seen;
  check int "reinforcement history converges (1+2)" 3 merged.Types.reinforcement_count;
  check (list string) "merged row is the episode claim" [ "one merged claim" ]
    (claims result.Recognition.recognized_facts)
;;

let test_revise_rewrites_in_place () =
  let store =
    [ fact ~claim:"old conclusion" ~claim_id:"old-slug" ~reinforcement_count:3 () ]
  in
  let result =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "new conclusion"
          ; category = None
          ; claim_id = Some "new-slug"
          ; claim_kind_update = Recognition.Keep_claim_kind
          ; valid_until_update = Recognition.Set_valid_for_days 7
          ; source_turn = 9
          }
      ]
      store
  in
  check int "row count unchanged" 1 (List.length result.Recognition.facts);
  let revised = List.hd result.Recognition.facts in
  check string "claim rewritten" "new conclusion" revised.Types.claim;
  check (option string) "claim_id replaced" (Some "new-slug") revised.Types.claim_id;
  check (float 0.0) "first_seen preserved" 1_000_000.0 revised.Types.first_seen;
  check bool "valid_until derived from valid_for_days" true
    (revised.Types.valid_until = Some (Types.valid_until_of_days ~now 7));
  check int "revision resets reinforcement count" 0 revised.Types.reinforcement_count;
  check (list string) "revised row is the episode claim" [ "new conclusion" ]
    (claims result.Recognition.recognized_facts)
;;

let test_revise_null_semantics_clear_expiry () =
  let store = [ fact ~valid_until:9_000_000.0 () ] in
  let result =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "durable revision"
          ; category = None
          ; claim_id = None
          ; claim_kind_update = Recognition.Keep_claim_kind
          ; valid_until_update = Recognition.Clear_valid_until
          ; source_turn = 9
          }
      ]
      store
  in
  let revised = List.hd result.Recognition.facts in
  check (option (float 0.0)) "explicit null clears expiry" None revised.Types.valid_until
;;

let test_revise_null_claim_id_clears_stale_slug () =
  (* The slug identifies the conclusion and revise means the conclusion
     changed: a null claim_id is "no stable slug for the corrected
     conclusion", never "inherit the superseded conclusion's identity". *)
  let store = [ fact ~claim:"old conclusion" ~claim_id:"old-slug" () ] in
  let result =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "corrected conclusion"
          ; category = None
          ; claim_id = None
          ; claim_kind_update = Recognition.Keep_claim_kind
          ; valid_until_update = Recognition.Keep_valid_until
          ; source_turn = 9
          }
      ]
      store
  in
  let revised = List.hd result.Recognition.facts in
  check (option string) "stale slug does not survive the revision" None
    revised.Types.claim_id
;;

let test_revise_claim_kind_tri_state () =
  let base = fact ~claim_kind:Types.External_state () in
  let revise claim_kind_update =
    apply
      [ Recognition.Revise
          { index = 0
          ; claim = "corrected"
          ; category = None
          ; claim_id = None
          ; claim_kind_update
          ; valid_until_update = Recognition.Keep_valid_until
          ; source_turn = 17
          }
      ]
      [ base ]
    |> fun result -> List.hd result.Recognition.facts
  in
  check (option string) "absent preserves kind"
    (Some "external_state")
    (Option.map Types.claim_kind_to_string
       (revise Recognition.Keep_claim_kind).Types.claim_kind);
  check (option string) "null clears kind" None
    (Option.map Types.claim_kind_to_string
       (revise Recognition.Clear_claim_kind).Types.claim_kind);
  check (option string) "value replaces kind"
    (Some "durable_knowledge")
    (Option.map Types.claim_kind_to_string
       (revise (Recognition.Set_claim_kind Types.Durable_knowledge)).Types.claim_kind)
;;

let test_merge_uses_authored_claim_id_and_current_turn () =
  let result =
    apply
      [ merge
          ~claim_id:"merged-conclusion"
          ~source_turn:42
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "merged"
          ; category = Types.Lesson
          }
      ]
      [ fact ~claim_id:"historical-a" (); fact ~claim_id:"historical-b" () ]
  in
  let merged = List.hd result.Recognition.facts in
  check (option string) "merge stores the authored conclusion id"
    (Some "merged-conclusion")
    merged.Types.claim_id;
  check (list int) "episode provenance uses the current operation turn"
    [ 42 ]
    result.Recognition.applied_source_turns
;;

let test_rewrite_failure_never_commits_publication () =
  let prepared = ref false
  and rewritten = ref false
  and committed = ref false in
  match
    Ledger.publish
      ~prepare:(fun () ->
        prepared := true;
        Ok ())
      ~rewrite:(fun () ->
        rewritten := true;
        Error "injected rewrite failure")
      ~episode:(fun () -> Ok ())
      ~event:(fun () -> Ok ())
      ~commit:(fun () ->
        committed := true;
        Ok Ledger.Terminal_durable)
  with
  | Error (Ledger.Rewrite_failed "injected rewrite failure") ->
    check bool "prepare is durable first" true !prepared;
    check bool "rewrite was attempted" true !rewritten;
    check bool "failed rewrite has no committed marker" false !committed
  | Error _ -> fail "unexpected publication failure"
  | Ok _ -> fail "injected rewrite failure unexpectedly committed"
;;

let test_terminal_remove_after_unlink_is_typed_success () =
  let remove_error : Keeper_fs.durable_remove_error =
    { removed = true
    ; failure = Keeper_fs.Parent_directory_fsync, "injected fsync failure"
    }
  in
  let expected_detail = Keeper_fs.durable_remove_error_to_string remove_error in
  (match
     Ledger.For_testing.terminal_outcome_of_remove_result (Error remove_error)
   with
   | Ok (Ledger.Terminal_durable_marker_clear_uncertain detail) ->
     check string "uncertain durability detail is preserved" expected_detail detail
   | Ok Ledger.Terminal_durable ->
     fail "removed marker with failed parent fsync was flattened to durable"
   | Error detail ->
     fail ("terminal durable publication was misclassified as failed: " ^ detail));
  match
    Ledger.publish
      ~prepare:(fun () -> Ok ())
      ~rewrite:(fun () -> Ok ())
      ~episode:(fun () -> Ok ())
      ~event:(fun () -> Ok ())
      ~commit:(fun () ->
        Ledger.For_testing.terminal_outcome_of_remove_result
          (Error remove_error))
  with
  | Ok (Ledger.Terminal_durable_marker_clear_uncertain detail) ->
    check string "publication preserves terminal outcome" expected_detail detail
  | Ok Ledger.Terminal_durable ->
    fail "publish flattened uncertain marker durability"
  | Error _ ->
    fail "terminal row durability must not be reported as a recoverable prepare failure"
;;

let test_publication_rows_distinguish_prepared_from_committed () =
  let before = [ fact ~claim:"before" () ] in
  let operation = Recognition.Add (fact ~claim:"after" ()) in
  let applied = apply [ operation ] before in
  let episode = episode ~claims:applied.Recognition.recognized_facts () in
  let publication_id =
    Ledger.publication_id
      ~keeper_id:"keeper-a"
      ~trace_id:"trace-current"
      ~generation:7
      ~store_before:before
      ~operations:[ operation ]
      ~dispositions:applied.Recognition.dispositions
      ~store_after:applied.Recognition.facts
      ~episode
      ~facts_rewrite_required:true
  in
  let state = function
    | `Assoc fields ->
      (match List.assoc_opt "publication_state" fields with
       | Some (`String value) -> value
       | _ -> fail "publication_state missing")
    | _ -> fail "publication row must be an object"
  in
  let prepared =
    Ledger.prepared_to_json
      ~publication_id
      ~keeper_id:"keeper-a"
      ~trace_id:"trace-current"
      ~generation:7
      ~store_before:before
      ~operations:[ operation ]
      ~dispositions:applied.Recognition.dispositions
      ~store_after:applied.Recognition.facts
      ~episode
      ~facts_rewrite_required:true
      ~now
      ()
  in
  let committed =
    Ledger.committed_to_json
      ~publication_id
      ~keeper_id:"keeper-a"
      ~trace_id:"trace-current"
      ~generation:7
      ~now
      ()
  in
  check string "pre-rewrite evidence is not published" "prepared" (state prepared);
  check string "post-rewrite marker is explicit" "committed" (state committed)
;;

let test_read_admission_recovers_every_publication_boundary_exactly_once () =
  let run boundary =
    let marker = Filename.temp_file ("recognition-" ^ boundary) ".tmp" in
    Sys.remove marker;
    let keepers_dir = Filename.concat marker "keepers" in
    let masc_root = marker in
    Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
      let keeper_id = "keeper-recovery" in
      let before = [ fact ~claim:"before" () ] in
      let operation = Recognition.Add (fact ~claim:"after" ()) in
      let applied = apply [ operation ] before in
      let episode = episode ~claims:applied.Recognition.recognized_facts () in
      let publication_id =
        Ledger.publication_id
          ~keeper_id
          ~trace_id:episode.trace_id
          ~generation:episode.generation
          ~store_before:before
          ~operations:[ operation ]
          ~dispositions:applied.Recognition.dispositions
          ~store_after:applied.Recognition.facts
          ~episode
          ~facts_rewrite_required:true
      in
      Memory_io.rewrite_facts_atomically ~keeper_id before;
      (match
         Ledger.append_prepared
           ~masc_root
           ~publication_id
           ~keeper_id
           ~trace_id:episode.trace_id
           ~generation:episode.generation
           ~store_before:before
           ~operations:[ operation ]
           ~dispositions:applied.Recognition.dispositions
           ~store_after:applied.Recognition.facts
           ~episode
           ~facts_rewrite_required:true
           ~now
           ()
       with
       | Ok () -> ()
       | Error detail -> fail ("prepare fixture failed: " ^ detail));
      (match
         Memory_io.rewrite_facts_atomically
           ~keeper_id
           [ fact ~claim:"concurrent-third-state" () ]
       with
       | exception Memory_io.Recognition_publication_pending _ -> ()
       | () -> fail "concurrent fact writer crossed a pending publication");
      check
        (list string)
        "blocked concurrent writer preserves the before snapshot"
        [ "before" ]
        (claims (Memory_io.read_facts_all ~keeper_id));
      if not (String.equal boundary "after_prepare")
      then
        Memory_io.with_recognition_fact_transaction
          ~masc_root
          ~keeper_id
          ~on_timeout:(fun detail -> fail detail)
          (fun ~rewrite ~masc_root:_ -> rewrite applied.Recognition.facts);
      if
        String.equal boundary "after_episode"
        || String.equal boundary "after_event"
        || String.equal boundary "after_commit"
      then
        (match
           Memory_io.ensure_recognition_episode
             ~keeper_id
             ~publication_id
             episode
         with
         | Ok _ -> ()
         | Error detail -> fail ("episode fixture failed: " ^ detail));
      if String.equal boundary "after_event" || String.equal boundary "after_commit"
      then
        (match
           Memory_io.ensure_recognition_event ~keeper_id ~publication_id episode
         with
         | Ok _ -> ()
         | Error detail -> fail ("event fixture failed: " ^ detail));
      if String.equal boundary "after_commit"
      then
        (match
           Ledger.append_committed
             ~masc_root
             ~publication_id
             ~keeper_id
             ~trace_id:episode.trace_id
             ~generation:episode.generation
             ~now
             ()
         with
         | Ok _ -> ()
         | Error detail -> fail ("commit fixture failed: " ^ detail));
      List.iter
        (fun turn ->
           ignore
             (Recall.render_if_enabled
                ~keeper_id
                ~now:(now +. Float.of_int turn)
                ~trace_id:"restart-read"
                ~turn
                ~masc_root
                ()))
        [ 1; 2 ];
      (match
         Ledger.recover_pending
           ~masc_root
           ~keeper_id
           ~current_store:
             (if String.equal boundary "after_prepare"
              then before
              else applied.Recognition.facts)
           ~now:(now +. 2.0)
           ()
       with
       | Ok Ledger.No_pending_publication -> ()
       | Ok _ -> fail "read admission did not settle the publication"
       | Error detail -> fail ("post-read publication check failed: " ^ detail));
      (match Memory_io.read_facts_all_strict ~keeper_id with
       | Ok facts ->
         check
           (list string)
           "facts match the crash boundary"
           (if String.equal boundary "after_prepare"
            then [ "before" ]
            else [ "before"; "after" ])
           (claims facts)
       | Error detail -> fail ("fact read failed: " ^ detail));
      let expected_artifacts =
        if String.equal boundary "after_prepare" then 0 else 1
      in
      (match Memory_io.read_episode_files_all_strict ~keeper_id with
       | Ok episodes ->
         check int
           (boundary ^ " episode count")
           expected_artifacts
           (List.length episodes)
       | Error detail -> fail ("episode read failed: " ^ detail));
      check int (boundary ^ " event count") expected_artifacts
        (List.length (Memory_io.read_events_tail ~keeper_id ~n:10)))
  in
  List.iter
    run
    [ "after_prepare"; "after_facts"; "after_episode"; "after_event"; "after_commit" ]
;;

let test_zero_op_read_admission_completes_equal_digest_publication () =
  let run boundary =
    let marker = Filename.temp_file ("recognition-zero-" ^ boundary) ".tmp" in
    Sys.remove marker;
    let keepers_dir = Filename.concat marker "keepers" in
    let masc_root = marker in
    Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
      let keeper_id = "keeper-zero-recovery" in
      let facts = [ fact ~claim:"unchanged" () ] in
      let episode = episode () in
      let publication_id =
        Ledger.publication_id
          ~keeper_id
          ~trace_id:episode.trace_id
          ~generation:episode.generation
          ~store_before:facts
          ~operations:[]
          ~dispositions:[]
          ~store_after:facts
          ~episode
          ~facts_rewrite_required:false
      in
      Memory_io.rewrite_facts_atomically ~keeper_id facts;
      (match
         Ledger.append_prepared
           ~masc_root
           ~publication_id
           ~keeper_id
           ~trace_id:episode.trace_id
           ~generation:episode.generation
           ~store_before:facts
           ~operations:[]
           ~dispositions:[]
           ~store_after:facts
           ~episode
           ~facts_rewrite_required:false
           ~now
           ()
       with
       | Ok () -> ()
       | Error detail -> fail ("zero-op prepare fixture failed: " ^ detail));
      if String.equal boundary "after_episode"
         || String.equal boundary "after_event"
         || String.equal boundary "after_commit"
      then
        (match
           Memory_io.ensure_recognition_episode
             ~keeper_id
             ~publication_id
             episode
         with
         | Ok _ -> ()
         | Error detail -> fail ("zero-op episode fixture failed: " ^ detail));
      if String.equal boundary "after_event" || String.equal boundary "after_commit"
      then
        (match
           Memory_io.ensure_recognition_event ~keeper_id ~publication_id episode
         with
         | Ok _ -> ()
         | Error detail -> fail ("zero-op event fixture failed: " ^ detail));
      if String.equal boundary "after_commit"
      then
        (match
           Ledger.append_committed
             ~masc_root
             ~publication_id
             ~keeper_id
             ~trace_id:episode.trace_id
             ~generation:episode.generation
           ~now
             ()
         with
         | Ok _ -> ()
         | Error detail -> fail ("zero-op commit fixture failed: " ^ detail));
      List.iter
        (fun turn ->
           ignore
             (Recall.render_if_enabled
                ~keeper_id
                ~now:(now +. Float.of_int turn)
                ~trace_id:"zero-restart-read"
                ~turn
                ~masc_root
                ()))
        [ 1; 2 ];
      (match
         Ledger.recover_pending
           ~masc_root
           ~keeper_id
           ~current_store:facts
           ~now:(now +. 3.0)
           ()
       with
       | Ok Ledger.No_pending_publication -> ()
       | Ok _ -> fail "zero-op read admission did not settle the publication"
       | Error detail -> fail ("zero-op publication check failed: " ^ detail));
      check
        (list string)
        "zero-op facts remain byte-equivalent"
        [ "unchanged" ]
        (claims (Memory_io.read_facts_all ~keeper_id));
      (match Memory_io.read_episode_files_all_strict ~keeper_id with
       | Ok episodes ->
         check int (boundary ^ " zero-op episode exactly once") 1
           (List.length episodes)
       | Error detail -> fail ("zero-op episode read failed: " ^ detail));
      check int (boundary ^ " zero-op event exactly once") 1
        (List.length (Memory_io.read_events_tail ~keeper_id ~n:10)))
  in
  List.iter run [ "after_prepare"; "after_episode"; "after_event"; "after_commit" ]
;;

let test_no_pending_recovery_does_not_scan_dated_history () =
  let marker = Filename.temp_file "recognition-o1-recovery" ".tmp" in
  Sys.remove marker;
  Unix.mkdir marker 0o700;
  let ledger_dir = Ledger.base_dir ~masc_root:marker in
  Unix.mkdir ledger_dir 0o700;
  (* A strict Dated_jsonl history scan would reject this non-date directory.
     With no per-keeper pending pointer, recovery must return in O(1) without
     opening or validating the append-only audit history. *)
  Unix.mkdir (Filename.concat ledger_dir "historical-junk") 0o700;
  match
    Ledger.recover_pending
      ~masc_root:marker
      ~keeper_id:"keeper-without-pending"
      ~current_store:[]
      ~now
      ()
  with
  | Ok Ledger.No_pending_publication -> ()
  | Ok _ -> fail "recovery invented a pending publication"
  | Error detail -> fail ("recovery scanned unrelated dated history: " ^ detail)
;;

let test_recognition_event_ensure_does_not_scan_legacy_history () =
  let marker = Filename.temp_file "recognition-event-o1" ".tmp" in
  Sys.remove marker;
  Memory_io.For_testing.with_keepers_dir marker (fun () ->
    let keeper_id = "keeper-event-o1" in
    let legacy_path = Memory_io.events_path ~keeper_id in
    let oc = open_out_bin legacy_path in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{malformed legacy history}\n");
    let event = episode () in
    List.iter
      (fun () ->
         match
           Memory_io.ensure_recognition_event
             ~keeper_id
             ~publication_id:"event-publication"
             event
         with
         | Ok () -> ()
         | Error detail -> fail ("recognition event ensure failed: " ^ detail))
      [ (); () ];
    let event_dir =
      Filename.concat
        (Filename.concat marker keeper_id)
        "recognition-events"
    in
    check int "replay leaves one publication-addressed event shard" 1
      (Sys.readdir event_dir |> Array.length))
;;

let test_canonical_audit_reader_deduplicates_crash_window_rows () =
  let masc_root = Filename.temp_file "recognition-audit-dedupe" ".tmp" in
  Sys.remove masc_root;
  Unix.mkdir masc_root 0o700;
  let before = [ fact ~claim:"before" () ] in
  let operation = Recognition.Add (fact ~claim:"after" ()) in
  let applied = apply [ operation ] before in
  let event = episode ~claims:applied.Recognition.recognized_facts () in
  let publication_id =
    Ledger.publication_id
      ~keeper_id:"audit-dedupe"
      ~trace_id:event.trace_id
      ~generation:event.generation
      ~store_before:before
      ~operations:[ operation ]
      ~dispositions:applied.Recognition.dispositions
      ~store_after:applied.Recognition.facts
      ~episode:event
      ~facts_rewrite_required:true
  in
  let prepared =
    Ledger.prepared_to_json
      ~publication_id
      ~keeper_id:"audit-dedupe"
      ~trace_id:event.trace_id
      ~generation:event.generation
      ~store_before:before
      ~operations:[ operation ]
      ~dispositions:applied.Recognition.dispositions
      ~store_after:applied.Recognition.facts
      ~episode:event
      ~facts_rewrite_required:true
      ~now
      ()
  in
  let committed =
    Ledger.committed_to_json
      ~publication_id
      ~keeper_id:"audit-dedupe"
      ~trace_id:event.trace_id
      ~generation:event.generation
      ~now
      ()
  in
  let audit = Dated_jsonl.create ~base_dir:(Ledger.base_dir ~masc_root) () in
  List.iter (Dated_jsonl.append audit) [ prepared; prepared; committed; committed ];
  match Ledger.read_all_canonical ~masc_root with
  | Error detail -> fail ("canonical audit read failed: " ^ detail)
  | Ok rows ->
    check int "two logical states survive four physical rows" 2
      (List.length rows)
;;

let test_recovery_reasserts_prepared_after_retention_prune () =
  let masc_root = Filename.temp_file "recognition-pruned-prepared" ".tmp" in
  Sys.remove masc_root;
  let keepers_dir = Filename.concat masc_root "config/keepers" in
  Memory_io.For_testing.with_memory_roots
    ~keepers_dir
    ~masc_root
    (fun () ->
       let keeper_id = "pruned-prepared" in
       let event = episode () in
       let publication_id =
         Ledger.publication_id
           ~keeper_id
           ~trace_id:event.trace_id
           ~generation:event.generation
           ~store_before:[]
           ~operations:[]
           ~dispositions:[]
           ~store_after:[]
           ~episode:event
           ~facts_rewrite_required:false
       in
       (match
          Ledger.append_prepared
            ~masc_root
            ~publication_id
            ~keeper_id
            ~trace_id:event.trace_id
            ~generation:event.generation
            ~store_before:[]
            ~operations:[]
            ~dispositions:[]
            ~store_after:[]
            ~episode:event
            ~facts_rewrite_required:false
            ~now
            ()
        with
        | Ok () -> ()
        | Error detail -> fail ("prepare fixture failed: " ^ detail));
       let audit = Dated_jsonl.create ~base_dir:(Ledger.base_dir ~masc_root) () in
       Sys.remove (Dated_jsonl.current_file_path audit);
       (match Ledger.read_all_canonical ~masc_root with
        | Ok [] -> ()
        | Ok rows ->
          failf "prune fixture left %d audit rows" (List.length rows)
        | Error detail -> fail ("post-prune audit read failed: " ^ detail));
       (match
          Ledger.recover_pending
            ~masc_root
            ~keeper_id
            ~current_store:[]
            ~now:(now +. 1.0)
            ()
        with
        | Ok (Ledger.Recovered_committed (recovered_id, _)) ->
          check string "same pending publication recovered"
            publication_id recovered_id
        | Ok Ledger.No_pending_publication ->
          fail "pruned prepared row made pending publication disappear"
        | Ok (Ledger.Recovered_aborted _) ->
          fail "metadata-only pending publication was aborted"
        | Error detail -> fail ("recovery failed: " ^ detail));
       match Ledger.read_all_canonical ~masc_root with
       | Error detail -> fail ("canonical audit read failed: " ^ detail)
       | Ok rows ->
         let states =
           List.map
             (function
               | `Assoc fields ->
                 (match List.assoc_opt "publication_state" fields with
                  | Some (`String state) -> state
                  | Some _ | None -> fail "audit row has no publication state")
               | _ -> fail "audit row is not an object")
             rows
         in
         check (list string)
           "recovery restores prepared evidence before terminal row"
           [ "prepared"; "committed" ]
           states)
;;

let test_explicit_operator_repair_actions_settle_pending_third_state () =
  let run action expected_claims expected_state expected_artifacts =
    let base_path = Filename.temp_file "recognition-third-state-repair" ".tmp" in
    Sys.remove base_path;
    let masc_root =
      Masc.Workspace_utils.masc_root_dir_from
        ~base_path
        ~cluster_name:(Masc.Env_config_core.cluster_name ())
    in
    let keepers_dir = Filename.concat base_path "keepers" in
    Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
      let keeper_id = "keeper-third-state-repair" in
      let before = [ fact ~claim:"before" () ] in
      let operation = Recognition.Add (fact ~claim:"after" ()) in
      let applied = apply [ operation ] before in
      let event = episode ~claims:applied.Recognition.recognized_facts () in
      let publication_id =
        Ledger.publication_id
          ~keeper_id
          ~trace_id:event.trace_id
          ~generation:event.generation
          ~store_before:before
          ~operations:[ operation ]
          ~dispositions:applied.Recognition.dispositions
          ~store_after:applied.Recognition.facts
          ~episode:event
          ~facts_rewrite_required:true
      in
      let third_state = [ fact ~claim:"operator-observed-third-state" () ] in
      Memory_io.rewrite_facts_atomically ~keeper_id third_state;
      (match
       Ledger.append_prepared
           ~masc_root
           ~publication_id
           ~keeper_id
           ~trace_id:event.trace_id
           ~generation:event.generation
           ~store_before:before
           ~operations:[ operation ]
           ~dispositions:applied.Recognition.dispositions
           ~store_after:applied.Recognition.facts
           ~episode:event
           ~facts_rewrite_required:true
           ~now
           ()
       with
       | Ok () -> ()
       | Error detail -> fail ("third-state fixture failed: " ^ detail));
      (match
         Ledger.recover_pending_classified
           ~masc_root
           ~keeper_id
           ~current_store:third_state
           ~now:(now +. 1.0)
           ()
       with
       | Error (Ledger.Pending_publication_third_state _) -> ()
       | Error error ->
         fail
           ("wrong recovery classification: "
            ^ Ledger.recovery_error_to_string error)
       | Ok _ -> fail "third-state publication recovered heuristically");
      (match
         Librarian_runtime.repair_pending_publication
           ~base_path
           ~keeper_id
           ~action
           ()
       with
       | Ok (Ledger.Repaired_aborted (repaired_id, _))
       | Ok (Ledger.Repaired_committed (repaired_id, _)) ->
         check string "same publication repaired" publication_id repaired_id
       | Error _ -> fail "explicit repair failed");
      check (list string) "repair selected exact store image"
        expected_claims
        (claims (Memory_io.read_facts_all ~keeper_id));
      (match
         Ledger.recover_pending
           ~masc_root
           ~keeper_id
           ~current_store:(Memory_io.read_facts_all ~keeper_id)
           ~now:(now +. 3.0)
           ()
       with
       | Ok Ledger.No_pending_publication -> ()
       | Ok _ -> fail "restart found a repaired pending publication"
       | Error detail -> fail ("repaired restart failed: " ^ detail));
      (match Ledger.read_all_canonical ~masc_root with
       | Ok rows ->
         let states =
           List.map
             Yojson.Safe.Util.(fun row -> row |> member "publication_state" |> to_string)
             rows
         in
         check (list string) "repair audit is terminal"
           [ "prepared"; expected_state ]
           states
       | Error detail -> fail ("repair audit read failed: " ^ detail));
      check int "repair artifact count" expected_artifacts
        (List.length (Memory_io.read_events_tail ~keeper_id ~n:10)))
  in
  run Ledger.Abort_preserving_current
    [ "operator-observed-third-state" ] "aborted" 0;
  run Ledger.Restore_store_before [ "before" ] "aborted" 0;
  run Ledger.Settle_store_after [ "before"; "after" ] "committed" 1
;;

let test_repeated_third_state_recovery_does_not_grow_prepared_audit () =
  let masc_root = Filename.temp_file "recognition-third-state-growth" ".tmp" in
  Sys.remove masc_root;
  let keeper_id = "keeper-third-state-growth" in
  let before = [ fact ~claim:"before" () ] in
  let operation = Recognition.Add (fact ~claim:"after" ()) in
  let applied = apply [ operation ] before in
  let event = episode ~claims:applied.Recognition.recognized_facts () in
  let publication_id =
    Ledger.publication_id
      ~keeper_id
      ~trace_id:event.trace_id
      ~generation:event.generation
      ~store_before:before
      ~operations:[ operation ]
      ~dispositions:applied.Recognition.dispositions
      ~store_after:applied.Recognition.facts
      ~episode:event
      ~facts_rewrite_required:true
  in
  (match
     Ledger.append_prepared
       ~masc_root
       ~publication_id
       ~keeper_id
       ~trace_id:event.trace_id
       ~generation:event.generation
       ~store_before:before
       ~operations:[ operation ]
       ~dispositions:applied.Recognition.dispositions
       ~store_after:applied.Recognition.facts
       ~episode:event
       ~facts_rewrite_required:true
       ~now
       ()
   with
   | Ok () -> ()
  | Error detail -> fail ("third-state growth fixture failed: " ^ detail));
  let audit = Dated_jsonl.create ~base_dir:(Ledger.base_dir ~masc_root) () in
  (* A different Keeper's damaged shared audit row must not enter this
     Keeper's marker-owned recovery path. *)
  Fs_compat.append_file
    (Dated_jsonl.current_file_path audit)
    "{not valid recognition audit json\n";
  check int "fixture has prepared and unrelated malformed rows" 2
    (Dated_jsonl.count_entries_uncached audit);
  List.iter
    (fun attempt ->
       match
         Ledger.recover_pending_classified
           ~masc_root
           ~keeper_id
           ~current_store:[ fact ~claim:"third-state" () ]
           ~now:(now +. Float.of_int attempt)
           ()
       with
       | Error (Ledger.Pending_publication_third_state _) -> ()
       | Error error ->
         fail
           ("wrong repeated recovery classification: "
            ^ Ledger.recovery_error_to_string error)
       | Ok _ -> fail "third-state recovery unexpectedly terminalized")
    [ 1; 2; 3 ];
  check int "repeated reads neither scan nor append audit rows" 2
    (Dated_jsonl.count_entries_uncached audit)
;;

let test_pending_third_state_blocks_provider_admission () =
  let base_path = Filename.temp_file "recognition-preflight-latch" ".tmp" in
  Sys.remove base_path;
  let masc_root =
    Masc.Workspace_utils.masc_root_dir_from
      ~base_path
      ~cluster_name:(Masc.Env_config_core.cluster_name ())
  in
  let keepers_dir = Filename.concat base_path "keepers" in
  Memory_io.For_testing.with_keepers_dir keepers_dir (fun () ->
    let keeper_id = "keeper-preflight-latch" in
    let before = [ fact ~claim:"before" () ] in
    let operation = Recognition.Add (fact ~claim:"after" ()) in
    let applied = apply [ operation ] before in
    let event = episode ~claims:applied.Recognition.recognized_facts () in
    let publication_id =
      Ledger.publication_id
        ~keeper_id
        ~trace_id:event.trace_id
        ~generation:event.generation
        ~store_before:before
        ~operations:[ operation ]
        ~dispositions:applied.Recognition.dispositions
        ~store_after:applied.Recognition.facts
        ~episode:event
        ~facts_rewrite_required:true
    in
    Memory_io.rewrite_facts_atomically
      ~keeper_id
      [ fact ~claim:"third-state" () ];
    (match
       Ledger.append_prepared
         ~masc_root
         ~publication_id
         ~keeper_id
         ~trace_id:event.trace_id
         ~generation:event.generation
         ~store_before:before
         ~operations:[ operation ]
         ~dispositions:applied.Recognition.dispositions
         ~store_after:applied.Recognition.facts
         ~episode:event
         ~facts_rewrite_required:true
         ~now
         ()
     with
     | Ok () -> ()
     | Error detail -> fail ("preflight latch fixture failed: " ^ detail));
    let provider_calls = ref 0 in
    Eio_main.run
    @@ fun env ->
    let input : Librarian.input =
      { trace_id = "preflight-must-not-dispatch"
      ; generation = 1
      ; messages = []
      ; store = []
      }
    in
    match
      Librarian_runtime.For_testing.extract_and_append_with
        ~clock:(Eio.Stdenv.clock env)
        ~base_path
        ~keeper_id
        ~extract:(fun ~generation:_ _ ->
          incr provider_calls;
          fail "provider callback crossed a pending-publication latch")
        input
    with
    | Error error
      when Librarian_runtime.extraction_error_kind error
           = Librarian_runtime.Pending_publication_blocked ->
      check int "provider was not called" 0 !provider_calls
    | Error error ->
      fail
        ("wrong preflight error: "
         ^ Librarian_runtime.extraction_error_to_string error)
    | Ok _ -> fail "third-state preflight admitted provider extraction")
;;

let test_operator_repair_request_is_strict_and_typed () =
  let parses action expected =
    match
      Recognition_operator.request_of_yojson
        (`Assoc [ "action", `String action ])
    with
    | Ok actual when actual = expected -> ()
    | Ok _ -> fail ("repair action decoded incorrectly: " ^ action)
    | Error detail -> fail ("repair action rejected: " ^ detail)
  in
  parses "abort_preserving_current" Ledger.Abort_preserving_current;
  parses "restore_store_before" Ledger.Restore_store_before;
  parses "settle_store_after" Ledger.Settle_store_after;
  List.iter
    (fun json ->
       match Recognition_operator.request_of_yojson json with
       | Error _ -> ()
       | Ok _ -> fail "invalid repair request crossed the typed parser")
    [ `Assoc [ "action", `String "guess" ]
    ; `Assoc
        [ "action", `String "settle_store_after"; "unexpected", `Bool true ]
    ; `Assoc []
    ; `String "settle_store_after"
    ]
;;

let test_pending_guard_uses_authoritative_root_matrix () =
  let base = Filename.temp_file "recognition-root-matrix" ".tmp" in
  Sys.remove base;
  Unix.mkdir base 0o700;
  let cases =
    [ ( "default"
      , Filename.concat (Filename.concat base ".masc") "config/keepers"
      , Filename.concat base ".masc" )
    ; ( "explicit-config"
      , Filename.concat base "external-config/keepers"
      , Filename.concat base ".masc" )
    ; ( "nondefault-cluster"
      , Filename.concat base "cluster-config/keepers"
      , Filename.concat base ".masc/clusters/blue" )
    ]
  in
  List.iter
    (fun (label, keepers_dir, masc_root) ->
       Memory_io.For_testing.with_memory_roots
         ~keepers_dir
         ~masc_root
         (fun () ->
            let keeper_id = "root-" ^ label in
            let store = [ fact ~claim:"guarded-before" () ] in
            let event = episode () in
            let publication_id =
              Ledger.publication_id
                ~keeper_id
                ~trace_id:event.trace_id
                ~generation:event.generation
                ~store_before:store
                ~operations:[]
                ~dispositions:[]
                ~store_after:store
                ~episode:event
                ~facts_rewrite_required:false
            in
            (match
               Ledger.append_prepared
                 ~masc_root
                 ~publication_id
                 ~keeper_id
                 ~trace_id:event.trace_id
                 ~generation:event.generation
                 ~store_before:store
                 ~operations:[]
                 ~dispositions:[]
                 ~store_after:store
                 ~episode:event
                 ~facts_rewrite_required:false
                 ~now
                 ()
             with
             | Ok () -> ()
             | Error detail -> fail (label ^ ": prepare failed: " ^ detail));
            match Memory_io.append_fact ~keeper_id (fact ~claim:"third-state" ()) with
            | exception Memory_io.Recognition_publication_pending _ -> ()
            | () -> fail (label ^ ": writer missed authoritative pending root")))
    cases
;;

let test_recalled_reinforcement_is_rejected_by_provenance () =
  let store = [ fact ~claim:"recalled" ~reinforcement_count:3 () ] in
  let result =
    Recognition.apply
      ~recalled_reinforcement_indices:[ 0 ]
      ~now
      ~operations:[ Recognition.Reinforce { index = 0; source_turn = 9 } ]
      store
  in
  check int "recalled echo does not refresh count" 3
    (List.hd result.Recognition.facts).Types.reinforcement_count;
  check (list string) "recalled echo has typed disposition"
    [ "rejected_recalled_echo" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_add_appends () =
  let store = [ fact ~claim:"existing" () ] in
  let result = apply [ Recognition.Add (fact ~claim:"brand new" ()) ] store in
  check (list string) "added at the end" [ "existing"; "brand new" ]
    (claims result.Recognition.facts)
;;

let test_out_of_range_rejects_without_change () =
  let store = [ fact ~claim:"only" () ] in
  let result =
    apply
      [ Recognition.Forget { index = 5; reason = "r" }
      ; Recognition.Reinforce { index = -1; source_turn = 0 }
      ]
      store
  in
  check (list string) "store unchanged" [ "only" ] (claims result.Recognition.facts);
  check (list string) "both rejected"
    [ "rejected_index_out_of_bounds"; "rejected_index_out_of_bounds" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_overlapping_targets_reject_the_entire_operation_set () =
  let store = [ fact ~claim:"contested" () ] in
  let result =
    apply
      [ Recognition.Reinforce { index = 0; source_turn = 1 }
      ; Recognition.Forget { index = 0; reason = "r" }
      ]
      store
  in
  check (list string) "store is unchanged" [ "contested" ]
    (claims result.Recognition.facts);
  check (list string) "all operations are rejected as one malformed set"
    [ "rejected_target_overlap"; "rejected_target_overlap" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_kind_mismatch_rejected () =
  let store =
    [ fact ~claim:"a" ~claim_kind:Types.Durable_knowledge ()
    ; fact ~claim:"b" ~claim_kind:Types.Self_observation ()
    ]
  in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "kind mismatch preserves both members" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "typed rejection" [ "rejected_kind_mismatch" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_valid_until_mismatch_rejected () =
  let store =
    [ fact ~claim:"a" ~valid_until:3_000_000.0 (); fact ~claim:"b" () ]
  in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "valid_until mismatch preserves both members" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "typed rejection" [ "rejected_valid_until_mismatch" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_with_consumed_member_rejects_entirely () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" () ] in
  let result =
    apply
      [ Recognition.Forget { index = 0; reason = "r" }
      ; merge
          { Consolidation.member_indices = [ 0; 1 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "overlap leaves every row untouched" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "dispositions"
    [ "rejected_target_overlap"; "rejected_target_overlap" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_never_shrinks_to_free_subset () =
  (* A merge sharing one member with another operation is a malformed batch,
     not a left-to-right conflict resolution policy. *)
  let store =
    [ fact ~claim:"a" (); fact ~claim:"b" (); fact ~claim:"c" () ]
  in
  let result =
    apply
      [ Recognition.Reinforce { index = 1; source_turn = 2 }
      ; merge
          { Consolidation.member_indices = [ 0; 1; 2 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "no partial merge; all rows survive" [ "a"; "b"; "c" ]
    (claims result.Recognition.facts);
  check (list string) "batch overlap is typed"
    [ "rejected_target_overlap"; "rejected_target_overlap" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_merge_out_of_range_member_rejects_entirely () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" () ] in
  let result =
    apply
      [ merge
          { Consolidation.member_indices = [ 0; 1; 9 ]
          ; consolidated_claim = "m"
          ; category = Types.Fact
          }
      ]
      store
  in
  check (list string) "out-of-range member rejects the whole merge"
    [ "a"; "b" ]
    (claims result.Recognition.facts);
  check (list string) "typed rejection" [ "rejected_index_out_of_bounds" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_mixed_pass_shrinks_store () =
  (* One realistic pass over five rows: reinforce one, merge two, forget one,
     add one -> net 5 - 2 + 1 = 4 rows, proving write-side refinement. *)
  let store =
    [ fact ~claim:"stable lesson" ()
    ; fact ~claim:"dup wording 1" ()
    ; fact ~claim:"stale queue state" ()
    ; fact ~claim:"dup wording 2" ()
    ; fact ~claim:"still true constraint" ()
    ]
  in
  let result =
    apply
      [ Recognition.Reinforce { index = 0; source_turn = 3 }
      ; merge
          { Consolidation.member_indices = [ 1; 3 ]
          ; consolidated_claim = "the deduplicated lesson"
          ; category = Types.Lesson
          }
      ; Recognition.Forget { index = 2; reason = "queue state is ephemeral" }
      ; Recognition.Add (fact ~claim:"new external fact" ())
      ]
      store
  in
  check (list string) "refined store"
    [ "stable lesson"
    ; "the deduplicated lesson"
    ; "still true constraint"
    ; "new external fact"
    ]
    (claims result.Recognition.facts);
  check (list string) "all applied"
    [ "applied"; "applied"; "applied"; "applied" ]
    (List.map Recognition.disposition_label result.Recognition.dispositions)
;;

let test_empty_operations_identity () =
  let store = [ fact ~claim:"a" (); fact ~claim:"b" () ] in
  let result = apply [] store in
  check (list string) "no ops, identical store" [ "a"; "b" ]
    (claims result.Recognition.facts);
  check int "no dispositions" 0 (List.length result.Recognition.dispositions)
;;

let () =
  run "keeper_librarian_recognition"
    [
      ( "apply",
        [
          test_case "reinforce updates in place, adds no row" `Quick
            test_reinforce_updates_in_place;
          test_case "forget shrinks the store" `Quick test_forget_shrinks_store;
          test_case "merge collapses rows" `Quick test_merge_collapses_rows;
          test_case "revise rewrites in place" `Quick test_revise_rewrites_in_place;
          test_case "revise null clears expiry" `Quick
            test_revise_null_semantics_clear_expiry;
          test_case "revise null claim_id clears the stale slug" `Quick
            test_revise_null_claim_id_clears_stale_slug;
          test_case "revise claim_kind is tri-state" `Quick
            test_revise_claim_kind_tri_state;
          test_case "merge keeps authored claim_id and current provenance" `Quick
            test_merge_uses_authored_claim_id_and_current_turn;
          test_case "rewrite failure never commits publication" `Quick
            test_rewrite_failure_never_commits_publication;
          test_case "terminal remove after unlink is typed success" `Quick
            test_terminal_remove_after_unlink_is_typed_success;
          test_case "publication rows distinguish prepared and committed" `Quick
            test_publication_rows_distinguish_prepared_from_committed;
          test_case
            "read admission recovers every publication boundary exactly once"
            `Quick
            test_read_admission_recovers_every_publication_boundary_exactly_once;
          test_case
            "zero-op read admission completes equal-digest publication"
            `Quick
            test_zero_op_read_admission_completes_equal_digest_publication;
          test_case
            "no-pending recovery does not scan dated history"
            `Quick
            test_no_pending_recovery_does_not_scan_dated_history;
          test_case
            "recognition event ensure does not scan legacy history"
            `Quick
            test_recognition_event_ensure_does_not_scan_legacy_history;
          test_case
            "canonical audit reader deduplicates crash-window rows"
            `Quick
            test_canonical_audit_reader_deduplicates_crash_window_rows;
          test_case
            "recovery reasserts prepared after retention prune"
            `Quick
            test_recovery_reasserts_prepared_after_retention_prune;
          test_case
            "operator repair explicitly settles pending third state"
            `Quick
            test_explicit_operator_repair_actions_settle_pending_third_state;
          test_case
            "repeated third-state recovery does not grow prepared audit"
            `Quick
            test_repeated_third_state_recovery_does_not_grow_prepared_audit;
          test_case
            "pending third state blocks provider admission"
            `Quick
            test_pending_third_state_blocks_provider_admission;
          test_case
            "operator repair request is strict and typed"
            `Quick
            test_operator_repair_request_is_strict_and_typed;
          test_case
            "pending guard uses authoritative root matrix"
            `Quick
            test_pending_guard_uses_authoritative_root_matrix;
          test_case "recalled reinforcement is rejected by provenance" `Quick
            test_recalled_reinforcement_is_rejected_by_provenance;
          test_case "add appends" `Quick test_add_appends;
          test_case "out-of-range rejects without change" `Quick
            test_out_of_range_rejects_without_change;
          test_case "overlapping targets reject the full operation set" `Quick
            test_overlapping_targets_reject_the_entire_operation_set;
          test_case "merge kind mismatch rejected" `Quick test_merge_kind_mismatch_rejected;
          test_case "merge valid_until mismatch rejected" `Quick
            test_merge_valid_until_mismatch_rejected;
          test_case "merge with consumed member rejects entirely" `Quick
            test_merge_with_consumed_member_rejects_entirely;
          test_case "merge never shrinks to free subset" `Quick
            test_merge_never_shrinks_to_free_subset;
          test_case "merge with out-of-range member rejects entirely" `Quick
            test_merge_out_of_range_member_rejects_entirely;
          test_case "mixed pass refines and shrinks" `Quick test_mixed_pass_shrinks_store;
          test_case "empty operations are identity" `Quick test_empty_operations_identity;
        ] );
    ]
