open Alcotest

module Current = Masc.Keeper_memory_os_current
module Types = Masc.Keeper_memory_os_types

let repo_root =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

let with_temp_keepers f =
  let path = Filename.temp_file "memory-os-current-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree path)
    (fun () -> f path)
;;

let fact ?(claim = "claim") () :
  Types.fact =
  { claim
  ; category = Types.Constraint
  ; first_seen = 100.0
  ; last_seen = 100.0
  ; origin = { kind = Types.Authored; trace_id = "trace" }
  ; basis = Types.Observed Types.Transcript
  }
;;

let board_ref ?comment_id post_id =
  match Types.board_ref_of_ids ~post_id ~comment_id with
  | Ok board -> board
  | Error error -> failf "board ref fixture: %s" (Types.wire_error_to_string error)
;;

let board_fact ?(claim = "board claim") ?comment_id post_id : Types.fact =
  { (fact ~claim ()) with
    basis = Types.Observed (Types.Board (board_ref ?comment_id post_id))
  }
;;

let source kind =
  { Current.kind; trace_id = "trace" }
;;

let replace
      ~keepers_dir
      ?(expected_revision = None)
      ?(facts = [])
      ?dropped_statements
      ()
  =
  Current.replace
    ?dropped_statements
    ~keepers_dir
    ~keeper_id:"keeper"
    ~expected_revision
    ~now:200.0
    ~source:(source Current.Librarian)
    ~facts
    ()
;;

let apply_disposition
      ~keepers_dir
      ?dropped_statements
      ?durable_range_id
      ?official_range_id
      ?(absorbed = [])
      ?(revisions = [])
      ?(new_claims = [])
      ()
  =
  Current.apply_disposition
    ?dropped_statements
    ?durable_range_id
    ?official_range_id
    ~absorbed
    ~revisions
    ~keepers_dir
    ~keeper_id:"keeper"
    ~now:200.0
    ~source:(source Current.Librarian)
    ~new_claims
    ()
  |> Result.map (fun (disposition : Current.disposition) -> disposition.snapshot)
;;

let require_ok = function
  | Ok value -> value
  | Error message -> fail message
;;

let rejected_files ~keepers_dir =
  Sys.readdir keepers_dir
  |> Array.to_list
  |> List.filter (fun name ->
    String.starts_with ~prefix:"keeper.memory-current.json.rejected-" name)
  |> List.sort String.compare
;;

let require_upsert_ok = function
  | Ok value -> value
  | Error error -> fail (Current.upsert_error_to_string error)
;;

let require_some = function
  | Some value -> value
  | None -> fail "expected current snapshot"
;;

let memory_snapshot_readers =
  [ "ordinary", (fun keepers_dir ->
      Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
      |> Result.map (Option.map (fun (snapshot : Current.t) -> snapshot.revision)))
  ; "source-bound", (fun keepers_dir ->
      Masc.Keeper_memory_source_current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
      |> Result.map (Option.map (fun (snapshot : Masc.Keeper_memory_source_current.t) ->
        snapshot.revision)))
  ]
;;

let check_snapshot_revisions ~keepers_dir expected =
  List.iter (fun (store, read) ->
    match read keepers_dir with
    | Ok revision -> check (option int) store expected revision
    | Error detail -> failf "%s: %s" store detail) memory_snapshot_readers
;;

let check_snapshot_read_errors ~keepers_dir =
  List.iter (fun (store, read) ->
    check bool (store ^ " preserves the read failure") true
      (Result.is_error (read keepers_dir))) memory_snapshot_readers
;;

let with_readable_memory_stores f =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
  let module Source = Masc.Keeper_memory_source_current in
  let source : Source.t =
    { revision = 1; updated_at = 200.; trace_id = "trace"; facts = []; invalidations = [] }
  in
  Out_channel.with_open_bin (Source.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper")
    (fun channel -> output_string channel (Yojson.Safe.to_string (Source.to_json source)));
  check_snapshot_revisions ~keepers_dir (Some 1);
  f keepers_dir
;;

let test_snapshot_reads_preserve_missing_directories () =
  with_temp_keepers @@ fun parent ->
  check_snapshot_revisions ~keepers_dir:(Filename.concat parent "fresh/keepers") None
;;

let test_snapshot_reads_preserve_missing_files () =
  with_temp_keepers @@ fun keepers_dir ->
  check_snapshot_revisions ~keepers_dir None
;;

let test_snapshot_reads_follow_the_writer_directory_alias () =
  with_readable_memory_stores @@ fun keepers_dir ->
  let alias = Filename.concat keepers_dir "directory-alias" in
  Unix.symlink keepers_dir alias;
  Fun.protect ~finally:(fun () -> Sys.remove alias) (fun () ->
    check_snapshot_revisions ~keepers_dir:alias (Some 1))
;;

let test_snapshot_reads_preserve_file_aliases () =
  with_readable_memory_stores @@ fun keepers_dir ->
  let paths =
    [ Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    ; Masc.Keeper_memory_source_current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    ]
  in
  List.iter (fun path ->
    let target = path ^ ".target" in
    Unix.rename path target;
    Unix.symlink target path) paths;
  check_snapshot_revisions ~keepers_dir (Some 1)
;;

let test_snapshot_reads_reject_non_directory_parents () =
  with_readable_memory_stores @@ fun keepers_dir ->
  let file = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  check_snapshot_read_errors ~keepers_dir:file;
  check_snapshot_read_errors ~keepers_dir:(Filename.concat file "child");
  check_snapshot_revisions ~keepers_dir (Some 1)
;;

let with_denied_mode path mode f =
  let previous = (Unix.stat path).Unix.st_perm in
  Unix.chmod path mode;
  Fun.protect ~finally:(fun () -> Unix.chmod path previous) f
;;

let test_snapshot_reads_preserve_parent_permission_failure () =
  (* Root bypasses this OS permission check; do not count it as exercised. *)
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_readable_memory_stores @@ fun keepers_dir ->
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  with_denied_mode keepers_dir 0o600 (fun () ->
    (match Unix.stat path with
     | exception Unix.Unix_error (Unix.EACCES, _, _) -> ()
     | _ -> fail "fixture must deny parent-directory search");
    check_snapshot_read_errors ~keepers_dir);
  check_snapshot_revisions ~keepers_dir (Some 1)
;;

let test_snapshot_reads_preserve_leaf_permission_failure () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_readable_memory_stores @@ fun keepers_dir ->
  let ordinary = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let source =
    Masc.Keeper_memory_source_current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  with_denied_mode ordinary 0o000 (fun () ->
    with_denied_mode source 0o000 (fun () ->
      check_snapshot_read_errors ~keepers_dir));
  check_snapshot_revisions ~keepers_dir (Some 1)
;;

let with_memory_read_fs fs test () =
  let previous = Fs_compat.get_fs_opt () in
  let install = function
    | None -> Fs_compat.clear_fs ()
    | Some fs -> Fs_compat.set_fs fs
  in
  install fs;
  Fun.protect ~finally:(fun () -> install previous) (fun () ->
    check bool "requested filesystem branch is active"
      (Option.is_some fs) (Fs_compat.has_fs ());
    test ())
;;

let in_memory_read_eio test () =
  Eio_main.run (fun env ->
    with_memory_read_fs (Some (Eio.Stdenv.fs env)) test ())
;;

let snapshot_read_cases =
  [ "fresh directories are absent", test_snapshot_reads_preserve_missing_directories
  ; "missing files are absent", test_snapshot_reads_preserve_missing_files
  ; "directory aliases remain readable", test_snapshot_reads_follow_the_writer_directory_alias
  ; "file aliases remain readable", test_snapshot_reads_preserve_file_aliases
  ; "non-directory parents are errors", test_snapshot_reads_reject_non_directory_parents
  ; "parent permission failure is an error", test_snapshot_reads_preserve_parent_permission_failure
  ; "leaf permission failure remains an error", test_snapshot_reads_preserve_leaf_permission_failure
  ]
;;

let fact_ids facts =
  List.map Types.memory_id facts
;;

let missing_memory_id digit = "sha256:" ^ String.make 64 digit

let derived_fact ~claim derivations =
  Types.derived
    ~claim
    ~category:Types.Fact
    ~now:100.0
    ~origin:{ kind = Types.Authored; trace_id = "trace" }
    ~derivations
  |> require_ok
;;

let read_journal_lines ~keepers_dir =
  let path =
    Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  if not (Sys.file_exists path)
  then []
  else
    Fs_compat.load_file path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> not (String.equal line ""))
    |> List.map Yojson.Safe.from_string
;;

let test_memory_id_is_exact_claim_derived_state () =
  let first = fact ~claim:"exact claim" () in
  let same_claim = { first with category = Types.Lesson } in
  let different_bytes = fact ~claim:" exact claim" () in
  check string "non-content fields do not change id"
    (Types.memory_id first)
    (Types.memory_id same_claim);
  check bool "different claim bytes change id"
    true
    (not (String.equal (Types.memory_id first) (Types.memory_id different_bytes)));
  check int "sha256 id length" 71 (String.length (Types.memory_id first))
;;

let test_derivation_contract_canonicalizes_sets_and_rejects_duplicate_rules () =
  let first = fact ~claim:"first premise" () in
  let second = fact ~claim:"second premise" () in
  let derived =
    derived_fact
      ~claim:"canonical conclusion"
      [ { rule_id = "canonical_rule"
        ; premise_ids = [ Types.memory_id second; Types.memory_id first ]
        }
      ]
  in
  (match derived.basis with
   | Types.Derived [ derivation ] ->
     check (list string) "premise set has canonical order"
       (List.sort String.compare [ Types.memory_id first; Types.memory_id second ])
       derivation.premise_ids
   | Types.Derived _ | Types.Observed _ -> fail "unexpected canonical basis");
  match
    Types.derived
      ~claim:"duplicate rules"
      ~category:Types.Fact
      ~now:100.0
      ~origin:{ kind = Types.Authored; trace_id = "trace" }
      ~derivations:
        [ { rule_id = "same_rule"; premise_ids = [ Types.memory_id first ] }
        ; { rule_id = "same_rule"; premise_ids = [ Types.memory_id second ] }
        ]
  with
  | Error _ -> ()
  | Ok _ -> fail "duplicate rule identity was accepted"
;;

let test_fresh_replace_and_delta () =
  with_temp_keepers @@ fun keepers_dir ->
  check (option string) "fresh state absent" None
    (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
     | Ok None -> None
     | Ok (Some _) -> Some "present"
     | Error message -> Some message);
  let first = fact ~claim:"first" () in
  let second = fact ~claim:"second" () in
  let snapshot =
    replace ~keepers_dir ~facts:[ first; second ] () |> require_ok
  in
  check int "revision" 1 snapshot.revision;
  check (list string) "facts" (fact_ids [ first; second ]) (fact_ids snapshot.facts);
  check (list string) "added" (fact_ids [ first; second ]) (fact_ids snapshot.change.added);
  check (list string) "removed" [] (fact_ids snapshot.change.removed);
  check int "retained" 0 snapshot.change.retained;
  check int "no support invalidations" 0 (List.length snapshot.change.invalidated)
;;

let test_support_retraction_cascades_to_fixed_point () =
  with_temp_keepers @@ fun keepers_dir ->
  let dependency = fact ~claim:"dependency is healthy" () in
  let approval = fact ~claim:"approval exists" () in
  let rollout =
    derived_fact
      ~claim:"rollout can proceed"
      [ { rule_id = "rollout_ready"
        ; premise_ids = [ Types.memory_id dependency; Types.memory_id approval ]
        }
      ]
  in
  let notification =
    derived_fact
      ~claim:"notify the release channel"
      [ { rule_id = "notify_ready_rollout"
        ; premise_ids = [ Types.memory_id rollout ]
        }
      ]
  in
  let initial = [ dependency; approval; rollout; notification ] in
  let first = replace ~keepers_dir ~facts:initial () |> require_ok in
  check (list string) "complete support closes transitively"
    (fact_ids initial)
    (fact_ids first.facts);
  check int "initial invalidations" 0 (List.length first.change.invalidated);
  let recall =
    Masc.Keeper_memory_os_recall.render_context
      ~keepers_dir
      ~keeper_id:"keeper"
      ()
  in
  check bool "automatic recall distinguishes a derived conclusion" true
    (String_util.contains_substring recall "basis=derived");
  check bool "rule identity stays on typed search surface" false
    (String_util.contains_substring recall "rollout_ready");
  let second =
    replace
      ~keepers_dir
      ~expected_revision:(Some first.revision)
      ~facts:[ approval; rollout; notification ]
      ()
    |> require_ok
  in
  check (list string) "only supported fixed point remains"
    (fact_ids [ approval ])
    (fact_ids second.facts);
  check (list string) "cascade is observable as removals"
    (fact_ids [ dependency; rollout; notification ])
    (fact_ids second.change.removed);
  (match second.change.invalidated with
   | [ rollout_invalidation; notification_invalidation ] ->
     check string "directly invalidated conclusion"
       (Types.memory_id rollout)
       (Types.memory_id rollout_invalidation.fact);
     check (list string) "direct missing premise"
       [ Types.memory_id dependency ]
       rollout_invalidation.missing_premise_ids;
     check string "transitively invalidated conclusion"
       (Types.memory_id notification)
       (Types.memory_id notification_invalidation.fact);
     check (list string) "transitive missing premise"
       [ Types.memory_id rollout ]
       notification_invalidation.missing_premise_ids
   | invalidated ->
     failf "expected two support invalidations, got %d" (List.length invalidated));
  let journal = read_journal_lines ~keepers_dir in
  let open Yojson.Safe.Util in
  check int "journal exposes both invalidations" 2
    (List.nth journal 1
     |> member "change"
     |> member "invalidated"
     |> to_list
    |> List.length);
  let fields = function
    | `Assoc fields -> List.map fst fields |> List.sort String.compare
    | _ -> fail "invalidation row was not an object"
  in
  List.nth journal 1
  |> member "change"
  |> member "invalidated"
  |> to_list
  |> List.iter (fun row ->
    check (list string) "historical invalidation fields"
      [ "fact"; "missing_premise_ids" ] (fields row))
;;

let test_batch_retraction_is_exact_atomic_and_cas_guarded () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first direct target" () in
  let second = fact ~claim:"second direct target" () in
  let retained = fact ~claim:"unaffected current fact" () in
  let dependent =
    derived_fact
      ~claim:"depends on the second target"
      [ { rule_id = "batch_dependency"
        ; premise_ids = [ Types.memory_id second ]
        }
      ]
  in
  let seeded =
    replace ~keepers_dir ~facts:[ first; second; retained; dependent ] ()
    |> require_ok
  in
  let seeded_snapshot_sha256 =
    match Current.read_with_snapshot_sha256 ~keepers_dir ~keeper_id:"keeper" with
    | Ok (Some (snapshot, snapshot_sha256)) ->
      check int "hash observation matches seed revision"
        seeded.revision snapshot.revision;
      snapshot_sha256
    | Ok None | Error _ -> fail "seeded snapshot hash is unavailable"
  in
  let direct : Current.retraction list =
    [ { memory_id = Types.memory_id first; reason = "operator plan: obsolete" }
    ; { memory_id = Types.memory_id second; reason = "operator plan: contradicted" }
    ]
  in
  let committed =
    match
      Current.retract_facts
        ~keepers_dir
        ~keeper_id:"keeper"
        ~expected_revision:seeded.revision
        ~expected_snapshot_sha256:seeded_snapshot_sha256
        ~now:300.0
        ~source:
          { Current.kind = Current.Explicit_retract
          ; trace_id = "cleanup-plan-1"
          }
        direct
    with
    | Ok snapshot -> snapshot
    | Error _ -> fail "valid exact batch was rejected"
  in
  check int "one batch advances one revision" 2 committed.revision;
  check (list string) "only the unaffected fact remains"
    [ Types.memory_id retained ]
    (fact_ids committed.facts);
  check (list string) "both direct targets and support cascade are removed"
    (fact_ids [ first; second; dependent ])
    (fact_ids committed.change.removed);
  check (list string) "only the derived row is a support invalidation"
    [ Types.memory_id dependent ]
    (List.map
       (fun (row : Current.support_invalidation) -> Types.memory_id row.fact)
       committed.change.invalidated);
  let journal = read_journal_lines ~keepers_dir in
  let open Yojson.Safe.Util in
  check int "seed plus one batch produce two commits" 2 (List.length journal);
  check (list string) "direct reasons share the batch journal commit"
    [ "operator plan: obsolete"; "operator plan: contradicted" ]
    (List.nth journal 1
     |> member "dropped"
     |> to_list
     |> List.map (fun row -> row |> member "reason" |> to_string));
  let unchanged_revision () =
    Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
    |> fun snapshot -> snapshot.Current.revision
  in
  let committed_snapshot_sha256 =
    match Current.read_with_snapshot_sha256 ~keepers_dir ~keeper_id:"keeper" with
    | Ok (Some (snapshot, snapshot_sha256)) ->
      check int "hash observation matches batch revision"
        committed.revision snapshot.revision;
      snapshot_sha256
    | Ok None | Error _ -> fail "committed snapshot hash is unavailable"
  in
  check string "commit receipt hash matches exact stored bytes"
    committed_snapshot_sha256
    (Current.snapshot_sha256 committed);
  (match
     Current.retract_facts
       ~keepers_dir
       ~keeper_id:"keeper"
       ~expected_revision:seeded.revision
       ~expected_snapshot_sha256:seeded_snapshot_sha256
       ~now:400.0
       ~source:
         { Current.kind = Current.Explicit_retract
         ; trace_id = "stale-plan"
         }
       [ { memory_id = Types.memory_id retained; reason = "stale" } ]
   with
   | Error (Current.Retract_batch_snapshot_conflict _) -> ()
   | Error _ | Ok _ -> fail "stale batch did not report a revision conflict");
  check int "stale batch changes nothing" committed.revision (unchanged_revision ());
  (match
     Current.retract_facts
       ~keepers_dir
       ~keeper_id:"keeper"
       ~expected_revision:committed.revision
       ~expected_snapshot_sha256:(String.make 64 '0')
       ~now:450.0
       ~source:
         { Current.kind = Current.Explicit_retract
         ; trace_id = "wrong-hash-plan"
         }
       [ { memory_id = Types.memory_id retained; reason = "wrong hash" } ]
   with
   | Error
       (Current.Retract_batch_snapshot_conflict
          { observed_snapshot_sha256 = Some observed; _ }) ->
     check string "conflict reports the locked snapshot hash"
       committed_snapshot_sha256 observed
   | Error _ | Ok _ -> fail "wrong snapshot hash did not fail closed");
  check int "wrong hash changes nothing" committed.revision (unchanged_revision ());
  (match
     Current.retract_facts
       ~keepers_dir
       ~keeper_id:"keeper"
       ~expected_revision:committed.revision
       ~expected_snapshot_sha256:committed_snapshot_sha256
       ~now:500.0
       ~source:
         { Current.kind = Current.Explicit_retract
         ; trace_id = "missing-plan"
         }
       [ { memory_id = missing_memory_id 'f'; reason = "not present" } ]
   with
   | Error (Current.Retract_batch_fact_not_found _) -> ()
   | Error _ | Ok _ -> fail "missing target did not fail the whole batch");
  check int "missing target changes nothing" committed.revision (unchanged_revision ());
  (match
     Current.retract_facts
       ~keepers_dir
       ~keeper_id:"keeper"
       ~expected_revision:committed.revision
       ~expected_snapshot_sha256:committed_snapshot_sha256
       ~now:600.0
       ~source:
         { Current.kind = Current.Explicit_retract
         ; trace_id = "duplicate-plan"
         }
       [ { memory_id = Types.memory_id retained; reason = "first" }
       ; { memory_id = Types.memory_id retained; reason = "second" }
       ]
   with
   | Error (Current.Retract_batch_duplicate_memory_id _) -> ()
   | Error _ | Ok _ -> fail "duplicate target did not fail the whole batch");
  check int "duplicate target changes nothing" committed.revision (unchanged_revision ());
  check int "failed batches append no journal commit" 2
    (List.length (read_journal_lines ~keepers_dir))
;;

let write_torn_journal_tail path ~prefix =
  let bytes = prefix ^ "{\"outcome\":\"committed\",\"revision\":" in
  Fs_compat.save_file path bytes;
  (match Fs_compat.read_private_jsonl_durable_locked_result path ~after:None with
   | Error (Fs_compat.Incomplete_transaction_tail _) -> ()
   | Error _ | Ok _ -> fail "fixture must expose an incomplete append tail");
  check string "general journal read leaves the torn tail unchanged" bytes
    (Fs_compat.load_file path)
;;

let check_batch_retraction_recovers_exact_reason_evidence ~torn_tail () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"reason must survive interrupted finalize" () in
  let seeded = replace ~keepers_dir ~facts:[ target ] () |> require_ok in
  let seeded_hash =
    match Current.read_with_snapshot_sha256 ~keepers_dir ~keeper_id:"keeper" with
    | Ok (Some (_, hash)) -> hash
    | Ok None | Error _ -> fail "seeded snapshot hash is unavailable"
  in
  let journal_path =
    Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  let seed_journal = Fs_compat.load_file journal_path in
  Fs_compat.invalidate_cached_writer journal_path;
  Sys.remove journal_path;
  Unix.mkdir journal_path 0o700;
  let plan_id = "cleanup-plan-interrupted-finalize" in
  let reason = "operator verified this exact claim is obsolete" in
  let request () =
    Current.retract_facts
      ~keepers_dir
      ~keeper_id:"keeper"
      ~expected_revision:seeded.revision
      ~expected_snapshot_sha256:seeded_hash
      ~now:300.0
      ~source:{ Current.kind = Current.Explicit_retract; trace_id = plan_id }
      [ { Current.memory_id = Types.memory_id target; reason } ]
  in
  (match request () with
   | Error
       (Current.Retract_batch_plan_evidence_pending
          { plan_id = observed_plan
          ; snapshot_revision
          ; snapshot_sha256
          ; detail = _
          }) ->
     check string "pending evidence names the exact plan" plan_id observed_plan;
     check int "pending evidence names the committed revision" 2 snapshot_revision;
     check bool "pending evidence carries the committed snapshot hash" true
       (String_util.is_lowercase_sha256_hex snapshot_sha256)
   | Error _ | Ok _ -> fail "journal failure did not report a committed pending plan");
  let receipt_path =
    Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper"
  in
  check bool "prepared exact plan remains durable" true
    (Sys.file_exists receipt_path);
  let open Yojson.Safe.Util in
  let prepared = Yojson.Safe.from_file receipt_path in
  check string "receipt exposes prepared state" "prepared"
    (prepared |> member "state" |> to_string);
  check string "receipt exposes the exact plan identity" plan_id
    (prepared |> member "plan_id" |> to_string);
  check string "receipt preserves the exact reason before reconciliation" reason
    (prepared |> member "dropped" |> to_list |> List.hd
     |> member "reason" |> to_string);
  let committed =
    Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
  in
  check int "snapshot replacement committed before finalize failed" 2
    committed.revision;
  check (list string) "target is absent from committed snapshot" []
    (fact_ids committed.facts);
  Unix.rmdir journal_path;
  if torn_tail then write_torn_journal_tail journal_path ~prefix:seed_journal;
  (match request () with
   | Error (Current.Retract_batch_snapshot_conflict _) -> ()
   | Error _ | Ok _ -> fail "restart reconciliation did not precede stale CAS");
  check bool "reconciled plan receipt is cleared" false
    (Sys.file_exists receipt_path);
  let journal = read_journal_lines ~keepers_dir in
  check int "complete history survives recovery" (if torn_tail then 2 else 1)
    (List.length journal);
  let removals = List.filter
      (fun line -> to_int (member "revision" line) = committed.revision) journal in
  check int "exact reason entry is appended once" 1 (List.length removals);
  let recovered = List.hd removals in
  check string "recovered journal entry retains plan identity" plan_id
    (recovered |> member "source" |> member "trace_id" |> to_string);
  check string "recovered journal entry retains exact reason" reason
    (recovered |> member "dropped" |> to_list |> List.hd
     |> member "reason" |> to_string);
  (match Current.read_dropped ~keepers_dir ~keeper_id:"keeper"
      ~current_facts:committed.facts |> require_ok with
   | [ archived ] ->
     check bool "batch recovery keeps the complete original" true
       (archived.original = target);
     check (option string) "batch recovery keeps the exact reason" (Some reason)
       archived.removal.drop_reason
   | _ -> fail "batch recovery did not restore the historical original");
  (match request () with
   | Error (Current.Retract_batch_snapshot_conflict _) -> ()
   | Error _ | Ok _ -> fail "second stale retry did not remain a conflict");
  check int "repeated retry does not duplicate recovered evidence"
    (List.length journal)
    (List.length (read_journal_lines ~keepers_dir))
;;

let test_retirement_context_rejects_stale_current () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"retired policy" () in
  let original = replace ~keepers_dir ~facts:[target] () |> require_ok in
  (match Current.retract_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
      ~source:(source Current.Explicit_retract) ~memory_id:(Types.memory_id target)
      ~reason:"operator retired this policy before prompt construction" () with
   | Ok _ -> () | Error _ -> fail "fixture retraction failed");
  (match Current.read_retirement_context ~keepers_dir ~keeper_id:"keeper"
      ~expected_revision:(Some original.revision) ~current_facts:original.facts with
   | Current.Retirement_source_changed -> ()
   | _ -> fail "stale current facts suppressed committed retirement evidence");
  let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require_ok
    |> Option.get in
  (match Current.read_retirement_context ~keepers_dir ~keeper_id:"keeper"
      ~expected_revision:(Some current.revision) ~current_facts:current.facts with
   | Current.Retirement_archive (Ok [archived]) ->
       check bool "fresh coherent archive retains the retired identity" true
         (archived.original = target)
   | _ -> fail "fresh current and retirement evidence are not coherent")
;;

let test_batch_retraction_recovers_exact_reason_evidence () =
  check_batch_retraction_recovers_exact_reason_evidence ~torn_tail:false ()
;;

let test_batch_retraction_recovers_torn_journal_tail () =
  check_batch_retraction_recovers_exact_reason_evidence ~torn_tail:true ()
;;

let check_ordinary_removals_preserve_archive_until_journal_recovery ~torn_tail () =
  let successor = fact ~claim:"replacement rule" () in
  let producers =
    [ ( "librarian"
      , "no longer needed"
      , fun ~keepers_dir ~target ~reason ->
          apply_disposition ~keepers_dir
            ~dropped_statements:[ { Types.memory_id = Types.memory_id target; reason } ]
            () |> require_ok )
    ; ( "explicit retraction"
      , "keeper withdrew this claim"
      , fun ~keepers_dir ~target ~reason ->
          match Current.retract_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
              ~source:(source Current.Explicit_retract)
              ~memory_id:(Types.memory_id target) ~reason () with
          | Ok snapshot -> snapshot
          | Error _ -> fail "ordinary retraction lost its committed outcome" )
    ; ( "supersession"
      , "superseded_by " ^ Types.memory_id successor
      , fun ~keepers_dir ~target ~reason:_ ->
          match Current.supersede_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
              ~source:(source Current.Explicit_write)
              ~superseded_memory_id:(Types.memory_id target) successor with
          | Ok (snapshot, _) -> snapshot
          | Error _ -> fail "supersession lost its committed outcome" )
    ]
  in
  List.iter (fun (label, reason, remove) ->
    with_temp_keepers @@ fun keepers_dir ->
    let target = fact ~claim:(label ^ " original with its complete conditions") () in
    ignore (replace ~keepers_dir ~facts:[ target ] () |> require_ok);
    let journal_path =
      Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    in
    let seed_journal = Fs_compat.load_file journal_path in
    Fs_compat.invalidate_cached_writer journal_path;
    Sys.remove journal_path;
    Unix.mkdir journal_path 0o700;
    let committed : Current.t = remove ~keepers_dir ~target ~reason in
    check int (label ^ " snapshot committed") 2 committed.revision;
    let read () =
      Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
      |> require_ok |> require_some
    in
    check bool (label ^ " original survives in committed snapshot") true
      ((read ()).change.removed = [ target ]);
    let receipt_path =
      Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper"
    in
    let receipt_bytes = Fs_compat.load_file receipt_path in
    let receipt = Yojson.Safe.from_string receipt_bytes in
    let open Yojson.Safe.Util in
    check bool "ordinary removal claims no exact batch plan" true
      (member "plan_id" receipt = `Null);
    check string "pending receipt preserves exact reason" reason
      (receipt |> member "dropped" |> to_list |> List.hd |> member "reason" |> to_string);
    let next_write () =
      Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
        ~source:(source Current.Explicit_write) (fact ~claim:"unrelated later memory" ())
    in
    (match next_write () with
     | Error (Current.Upsert_persistence_failed _) -> ()
     | Error _ | Ok _ -> fail "next writer overwrote unresolved removal evidence");
    check int "failed recovery keeps removed originals' snapshot" committed.revision
      (read ()).revision;
    (* Missing journal after restart must not be reported as an empty archive.
       Reading is observational: it leaves preparation for a writer to settle. *)
    Unix.rmdir journal_path;
    if torn_tail then write_torn_journal_tail journal_path ~prefix:seed_journal;
    let journal_before_read = Fs_compat.load_file_opt journal_path in
    (match Current.read_dropped ~keepers_dir ~keeper_id:"keeper"
        ~current_facts:(read ()).facts with
     | Error _ -> ()
     | Ok _ -> fail "pending archive was reported complete");
    check string "archive read leaves the receipt untouched" receipt_bytes
      (Fs_compat.load_file receipt_path);
    check (option string) "archive read leaves journal recovery to the writer"
      journal_before_read (Fs_compat.load_file_opt journal_path);
    let next = next_write () |> require_upsert_ok in
    check int "recovery precedes the next update" 3 next.revision;
    check bool "successful finalization clears preparation" false
      (Sys.file_exists receipt_path);
    let archived = Current.read_dropped ~keepers_dir ~keeper_id:"keeper"
        ~current_facts:next.facts |> require_ok in
    (match archived with
     | [ row ] ->
       check bool "archive restores the complete historical original" true
         (row.original = target);
       check (option string) "archive restores its exact reason" (Some reason)
         row.removal.drop_reason
     | _ -> fail "recovery did not expose exactly one historical original");
    ignore (next_write () |> require_upsert_ok);
    let recovered = read_journal_lines ~keepers_dir
      |> List.filter (fun line -> to_int (member "revision" line) = 2) in
    check int "restart finalizes the removal once" 1 (List.length recovered))
    producers
;;

let test_ordinary_removals_preserve_archive_until_journal_recovery () =
  check_ordinary_removals_preserve_archive_until_journal_recovery ~torn_tail:false ()
;;

let test_ordinary_removals_recover_torn_journal_tail () =
  check_ordinary_removals_preserve_archive_until_journal_recovery ~torn_tail:true ()
;;

let test_removal_receipt_write_failure_preserves_current_fact () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"must remain if archive preparation fails" () in
  let seeded = replace ~keepers_dir ~facts:[ target ] () |> require_ok in
  with_denied_mode keepers_dir 0o500 (fun () ->
    match Current.retract_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
        ~source:(source Current.Explicit_retract)
        ~memory_id:(Types.memory_id target) ~reason:"obsolete" () with
    | Error (Current.Retract_persistence_failed detail) ->
      check bool "failure occurred at receipt preparation" true
        (String_util.contains_substring detail "retraction plan receipt write failed")
    | Error _ | Ok _ -> fail "removal proceeded without preparing its archive");
  let current = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok |> require_some in
  check bool "preparation failure changes no current fact" true (current = seeded);
  check int "preparation failure records no removal commit" 1
    (List.length (read_journal_lines ~keepers_dir))
;;

let test_stale_drop_statements_prepare_no_removal_receipt () =
  with_temp_keepers @@ fun keepers_dir ->
  let kept = fact ~claim:"still current" () in
  let stale = fact ~claim:"already absent" () in
  let seeded = replace ~keepers_dir ~facts:[ kept ] () |> require_ok in
  let current = apply_disposition ~keepers_dir
      ~dropped_statements:[ { Types.memory_id = Types.memory_id stale; reason = "obsolete" } ]
      () |> require_ok in
  check int "stale drop does not rewrite the snapshot" seeded.revision current.revision;
  check bool "stale drop leaves no prepared removal" false
    (Sys.file_exists (Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper"));
  check int "stale drop invents no archived fact" 0
    (Current.read_dropped ~keepers_dir ~keeper_id:"keeper" ~current_facts:current.facts
     |> require_ok |> List.length)
;;

let test_alternate_support_path_keeps_derived_fact_current () =
  with_temp_keepers @@ fun keepers_dir ->
  let primary = fact ~claim:"primary approval" () in
  let emergency = fact ~claim:"emergency approval" () in
  let primary_rollout =
    derived_fact
      ~claim:"rollout can proceed"
      [ { rule_id = "primary_path"; premise_ids = [ Types.memory_id primary ] } ]
  in
  let emergency_rollout =
    derived_fact
      ~claim:"rollout can proceed"
      [ { rule_id = "emergency_path"; premise_ids = [ Types.memory_id emergency ] } ]
  in
  ignore (replace ~keepers_dir ~facts:[ primary; emergency ] () |> require_ok);
  ignore
    (Current.upsert_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:300.0
       ~source:(source Current.Explicit_write)
       primary_rollout
     |> require_upsert_ok);
  let joined =
    Current.upsert_fact
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:400.0
      ~source:(source Current.Explicit_write)
      emergency_rollout
    |> require_upsert_ok
  in
  let rollout = List.nth joined.facts 2 in
  (match rollout.basis with
   | Types.Derived derivations ->
     check int "re-observation joins alternate proofs" 2 (List.length derivations)
   | Types.Observed _ -> fail "derived conclusion was promoted without observation");
  let second =
    replace
      ~keepers_dir
      ~expected_revision:(Some joined.revision)
      ~facts:[ emergency; rollout ]
      ()
    |> require_ok
  in
  check (list string) "one complete proof is sufficient"
    (fact_ids [ emergency; rollout ])
    (fact_ids second.facts);
  check int "no invalidation while alternate proof survives" 0
    (List.length second.change.invalidated)
;;

let test_reverse_ordered_support_chain_reaches_fixed_point () =
  with_temp_keepers @@ fun keepers_dir ->
  let root = fact ~claim:"chain root" () in
  let chain_length = 256 in
  let rec build index premise facts =
    if index > chain_length
    then facts
    else
      let conclusion =
        derived_fact
          ~claim:(Printf.sprintf "chain conclusion %d" index)
          [ { rule_id = Printf.sprintf "chain_rule_%d" index
            ; premise_ids = [ Types.memory_id premise ]
            }
          ]
      in
      build (index + 1) conclusion (conclusion :: facts)
  in
  let reverse_topological = build 1 root [ root ] in
  let snapshot = replace ~keepers_dir ~facts:reverse_topological () |> require_ok in
  check int "whole reverse-ordered chain is supported" (chain_length + 1)
    (List.length snapshot.facts);
  check int "supported chain has no invalidations" 0
    (List.length snapshot.change.invalidated)
;;

let test_same_rule_replaces_its_premise_set () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first condition" () in
  let second = fact ~claim:"second condition" () in
  let initial_rule =
    derived_fact
      ~claim:"rule-governed conclusion"
      [ { rule_id = "governing_rule"; premise_ids = [ Types.memory_id first ] } ]
  in
  let strengthened_rule =
    derived_fact
      ~claim:"rule-governed conclusion"
      [ { rule_id = "governing_rule"
        ; premise_ids = [ Types.memory_id second; Types.memory_id first ]
        }
      ]
  in
  ignore (replace ~keepers_dir ~facts:[ first; second ] () |> require_ok);
  ignore
    (Current.upsert_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:300.0
       ~source:(source Current.Explicit_write)
       initial_rule
     |> require_upsert_ok);
  let strengthened =
    Current.upsert_fact
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:400.0
      ~source:(source Current.Explicit_write)
      strengthened_rule
    |> require_upsert_ok
  in
  let conclusion = List.nth strengthened.facts 2 in
  (match conclusion.basis with
   | Types.Derived [ derivation ] ->
     check (list string) "same rule carries only its current premise set"
       (List.sort String.compare [ Types.memory_id first; Types.memory_id second ])
       derivation.premise_ids
   | Types.Derived _ | Types.Observed _ -> fail "rule replacement changed basis shape");
  let retracted =
    replace
      ~keepers_dir
      ~expected_revision:(Some strengthened.revision)
      ~facts:[ first; conclusion ]
      ()
    |> require_ok
  in
  check (list string) "removed strengthened premise retracts conclusion"
    (fact_ids [ first ])
    (fact_ids retracted.facts)
;;

let test_unsupported_derived_upsert_has_no_effect () =
  with_temp_keepers @@ fun keepers_dir ->
  let conclusion =
    derived_fact
      ~claim:"unsupported conclusion"
      [ { rule_id = "requires_missing_fact"; premise_ids = [ missing_memory_id 'a' ] } ]
  in
  (match
     Current.upsert_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:200.0
       ~source:(source Current.Explicit_write)
       conclusion
   with
   | Error (Current.Unsupported_derivation invalidation) ->
     check (list string) "typed missing support"
       [ missing_memory_id 'a' ]
       invalidation.missing_premise_ids
   | Error error -> fail (Current.upsert_error_to_string error)
   | Ok _ -> fail "unsupported derived fact was committed");
  check bool "no snapshot revision was created" false
    (Sys.file_exists
       (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"));
  check int "no journal line was created" 0
    (List.length (read_journal_lines ~keepers_dir));
  let premise = fact ~claim:"present premise" () in
  let supported =
    derived_fact
      ~claim:"existing conclusion"
      [ { rule_id = "supported_path"; premise_ids = [ Types.memory_id premise ] } ]
  in
  let unsupported_alternative =
    derived_fact
      ~claim:"existing conclusion"
      [ { rule_id = "unsupported_path"; premise_ids = [ missing_memory_id 'b' ] } ]
  in
  let seeded = replace ~keepers_dir ~facts:[ premise; supported ] () |> require_ok in
  (match
     Current.upsert_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:300.0
       ~source:(source Current.Explicit_write)
       unsupported_alternative
   with
   | Error (Current.Unsupported_derivation _) -> ()
   | Error error -> fail (Current.upsert_error_to_string error)
   | Ok _ -> fail "unsupported alternative piggybacked on existing support");
  let unchanged =
    Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
  in
  check int "unsupported alternative creates no revision" seeded.revision unchanged.revision;
  (match (List.nth unchanged.facts 1).basis with
   | Types.Derived derivations ->
     check int "unsupported alternative is not stored" 1 (List.length derivations)
   | Types.Observed _ -> fail "derived conclusion changed basis");
  check int "only the seed commit is journaled" 1
    (List.length (read_journal_lines ~keepers_dir))
;;

let test_replace_records_exact_added_removed_and_retained () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first" () in
  let second = fact ~claim:"second" () in
  let changed_second = fact ~claim:"second revised" () in
  let third = fact ~claim:"third" () in
  ignore (replace ~keepers_dir ~facts:[ first; second ] () |> require_ok);
  let snapshot =
    replace
      ~keepers_dir
      ~expected_revision:(Some 1)
      ~facts:[ first; changed_second; third ]
      ()
    |> require_ok
  in
  check int "revision" 2 snapshot.revision;
  check (list string) "added identities"
    (fact_ids [ changed_second; third ])
    (fact_ids snapshot.change.added);
  check (list string) "removed identities"
    (fact_ids [ second ])
    (fact_ids snapshot.change.removed);
  check int "retained" 1 snapshot.change.retained
;;

let test_duplicate_identity_rejects_without_overwrite () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"same" () in
  let duplicate = fact ~claim:"same" () in
  ignore (replace ~keepers_dir ~facts:[ first ] () |> require_ok);
  (match
     replace
       ~keepers_dir
       ~expected_revision:(Some 1)
       ~facts:[ first; duplicate ]
       ()
   with
   | Error message ->
     check bool "duplicate error"
       true
       (String.starts_with ~prefix:"duplicate Memory OS fact identity:" message)
   | Ok _ -> fail "duplicate identity was accepted");
  let snapshot =
    Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
  in
  check int "unchanged revision" 1 snapshot.revision;
  check (list string) "unchanged facts" (fact_ids [ first ]) (fact_ids snapshot.facts)
;;

(* A file this build cannot decode is not this build's to destroy, and it is
   also not this build's reason to stop writing forever. It moves aside with
   its bytes intact and the write continues from fresh state.

   The earlier contract refused the write and left the file where it was, which
   is what turned one undecodable snapshot into a permanent wedge: every writer
   reads before it writes. Byte preservation is what that test was protecting
   and it still holds — at the moved-aside path. *)
let test_non_current_snapshot_is_moved_aside_not_overwritten () =
  with_temp_keepers @@ fun keepers_dir ->
  let snapshot_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  let alien = {|{"schema":"unexpected.memory"}|} in
  Fs_compat.save_file snapshot_path alien;
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  check int "the write proceeds from fresh state" 1 written.revision;
  match rejected_files ~keepers_dir with
  | [ name ] ->
    let kept = Filename.concat keepers_dir name in
    check string "alien bytes preserved" alien (Fs_compat.load_file kept);
    check
      bool
      "and the current snapshot is a different file"
      true
      (not (String.equal kept snapshot_path))
  | files ->
    fail
      (Printf.sprintf
         "expected the alien file to be kept, got [%s]"
         (String.concat "; " files))
;;

let test_snapshot_read_rejects_unsupported_current_truth () =
  with_temp_keepers @@ fun keepers_dir ->
  let unsupported =
    derived_fact
      ~claim:"unsupported file claim"
      [ { rule_id = "missing_support"; premise_ids = [ missing_memory_id 'c' ] } ]
  in
  let forged : Current.t =
    { revision = 1
    ; updated_at = 200.0
    ; source = source Current.Explicit_write
    ; facts = [ unsupported ]
    ; change = { added = [ unsupported ]; removed = []; retained = 0; invalidated = [] }
    }
  in
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  Fs_compat.save_file path (Yojson.Safe.to_string (Current.to_json forged));
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
  | Error _ -> ()
  | Ok _ -> fail "unsupported derived fact crossed the authoritative read boundary"
;;

let test_snapshot_read_rejects_forged_invalidation_evidence () =
  with_temp_keepers @@ fun keepers_dir ->
  let premise = fact ~claim:"present premise" () in
  let conclusion =
    derived_fact
      ~claim:"supported conclusion"
      [ { rule_id = "supported"; premise_ids = [ Types.memory_id premise ] } ]
  in
  let forged : Current.t =
    { revision = 1
    ; updated_at = 200.0
    ; source = source Current.Explicit_write
    ; facts = [ premise; conclusion ]
    ; change =
        { added = [ premise; conclusion ]
        ; removed = []
        ; retained = 0
        ; invalidated =
            [ { fact = conclusion; missing_premise_ids = [ missing_memory_id 'd' ] } ]
        }
    }
  in
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  Fs_compat.save_file path (Yojson.Safe.to_string (Current.to_json forged));
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
  | Error _ -> ()
  | Ok _ -> fail "forged support invalidation crossed the authoritative read boundary"
;;

let test_snapshot_read_requires_fact_basis () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let without_basis = function
    | `Assoc fields ->
      `Assoc (List.filter (fun (field, _) -> not (String.equal field "basis")) fields)
    | json -> json
  in
  let broken =
    match Current.to_json written with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (field, value) ->
              if String.equal field "facts"
              then
                match value with
                | `List facts -> field, `List (List.map without_basis facts)
                | _ -> field, value
              else field, value)
           fields)
    | json -> json
  in
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  Fs_compat.save_file path (Yojson.Safe.to_string broken);
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
  | Error _ -> ()
  | Ok _ -> fail "a fact without basis crossed the authoritative read boundary"
;;

let test_historical_snapshot_fields_remain_readable () =
  with_temp_keepers @@ fun keepers_dir ->
  (* Historical snapshot bytes must remain readable if a writer field is removed. *)
  let historical =
    {|{"revision":1,"updated_at":200.0,"source":{"kind":"librarian","trace_id":"trace"},"facts":[{"claim":"claim","category":"constraint","first_seen":100.0,"last_seen":100.0,"origin":{"kind":"authored","trace_id":"trace"},"basis":{"kind":"observed"}}],"change":{"added":[],"removed":[],"retained":1,"invalidated":[]}}|}
  in
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  Fs_compat.save_file path historical;
  let decoded =
    Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
  in
  check int "historical revision" 1 decoded.revision;
  let field_names = function
    | `Assoc fields -> List.map fst fields |> List.sort String.compare
    | _ -> fail "historical snapshot layer was not an object"
  in
  let encoded = Current.to_json decoded in
  check (list string) "snapshot writer fields"
    [ "change"; "facts"; "revision"; "source"; "updated_at" ]
    (field_names encoded);
  check (list string) "source writer fields"
    [ "kind"; "trace_id" ]
    (field_names (Yojson.Safe.Util.member "source" encoded));
  let encoded_fact =
    match Yojson.Safe.Util.member "facts" encoded |> Yojson.Safe.Util.to_list with
    | [ fact ] -> fact
    | _ -> fail "historical snapshot must retain one fact"
  in
  check (list string) "fact writer fields"
    [ "basis"; "category"; "claim"; "first_seen"; "last_seen"; "origin" ]
    (field_names encoded_fact);
  check (list string) "fact origin writer fields"
    [ "kind"; "trace_id" ]
    (field_names (Yojson.Safe.Util.member "origin" encoded_fact));
  check (list string) "fact basis writer fields"
    [ "kind" ]
    (field_names (Yojson.Safe.Util.member "basis" encoded_fact));
  check (list string) "change writer fields"
    [ "added"; "invalidated"; "removed"; "retained" ]
    (field_names (Yojson.Safe.Util.member "change" encoded))
;;

let test_current_snapshot_object_order_is_irrelevant_but_fields_are_exact () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let reordered =
    match Current.to_json written with
    | `Assoc fields ->
      `Assoc
        (List.rev_map
           (fun (name, value) ->
              match name, value with
              | ("source" | "change"), `Assoc nested ->
                name, `Assoc (List.rev nested)
              | _ -> name, value)
           fields)
    | _ -> fail "current snapshot encoder did not return an object"
  in
  let snapshot_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  Fs_compat.save_file snapshot_path (Yojson.Safe.to_string reordered);
  let decoded =
    Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
  in
  check int "reordered current revision" written.revision decoded.revision;
  let with_unknown =
    match reordered with
    | `Assoc fields -> `Assoc (("summary", `String "unexpected") :: fields)
    | _ -> reordered
  in
  Fs_compat.save_file snapshot_path (Yojson.Safe.to_string with_unknown);
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
   | Error _ -> ()
   | Ok _ -> fail "current snapshot accepted an unknown field")
;;

let test_duplicate_snapshot_fact_identity_rejects () =
  with_temp_keepers @@ fun keepers_dir ->
  let written =
    replace ~keepers_dir ~facts:[ fact ~claim:"duplicate" () ] ()
    |> require_ok
  in
  let duplicated =
    match Current.to_json written with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "facts"
              then (
                match value with
                | `List [ fact ] -> name, `List [ fact; fact ]
                | _ -> fail "snapshot facts did not contain one fact")
              else name, value)
           fields)
    | _ -> fail "current snapshot encoder did not return an object"
  in
  let snapshot_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  Fs_compat.save_file snapshot_path (Yojson.Safe.to_string duplicated);
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
  | Error _ -> ()
  | Ok _ -> fail "duplicate snapshot fact identity was accepted"
;;

let test_snapshot_read_io_error_is_returned () =
  with_temp_keepers @@ fun keepers_dir ->
  let snapshot_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  Fs_compat.mkdir_p (Filename.dirname snapshot_path);
  Unix.mkdir snapshot_path 0o700;
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
  | Error message ->
    check bool "read error contains path" true
      (String_util.contains_substring message snapshot_path)
  | Ok _ -> fail "snapshot read I/O error escaped the Result boundary"
;;

let test_recall_preserves_selected_facts_without_local_ranking () =
  with_temp_keepers @@ fun keepers_dir ->
  let prompt_dir = Filename.concat repo_root "config/prompts" in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  let first = fact ~claim:"first memory" () in
  let second = fact ~claim:"second memory" () in
  ignore
    (replace ~keepers_dir ~facts:[ first; second ] () |> require_ok);
  let rendered =
    Masc.Keeper_memory_os_recall.render_context
      ~keepers_dir
      ~keeper_id:"keeper"
      ()
  in
  let first_at = Astring.String.find_sub ~sub:"first memory" rendered in
  let second_at = Astring.String.find_sub ~sub:"second memory" rendered in
  check bool "first selected fact recalled" true (Option.is_some first_at);
  check bool "second selected fact recalled" true (Option.is_some second_at);
  check bool "snapshot order preserved" true
    (match first_at, second_at with
     | Some first_at, Some second_at -> first_at < second_at
     | _ -> false)
;;

let test_recall_tracks_empty_unavailable_and_recovery () =
  with_temp_keepers @@ fun keepers_dir ->
  let render () = Masc.Keeper_memory_os_recall.render_context
    ~keepers_dir ~keeper_id:"keeper" () in
  let absent = render () in
  check bool "absent state is explicit" true (String.length absent > 0);
  check string "absent state is stable" absent (render ());
  let first = replace ~keepers_dir ~facts:[fact ~claim:"selected current fact" ()] () |> require_ok in
  let present = render () in
  check bool "selected fact reaches recall" true
    (String_util.contains_substring present "selected current fact");
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let original = Fs_compat.load_file snapshot_path in
  Fs_compat.save_file snapshot_path "{ not json";
  let unavailable = render () in
  check bool "read failure explicitly preserves uncertainty" true
    (String_util.contains_substring unavailable "unverified");
  check bool "read failure differs from absence" true (unavailable <> absent);
  check string "failure is stable across ticks" unavailable (render ());
  Fs_compat.save_file snapshot_path original;
  check string "recovery restores exact original block" present (render ());
  ignore (replace ~keepers_dir ~expected_revision:(Some first.revision) ~facts:[] () |> require_ok);
  let empty = render () in
  check bool "cleared state explicitly withdraws prior facts" true
    (String_util.contains_substring empty "No ordinary facts are current");
  check bool "cleared state differs from unavailable" true (empty <> unavailable);
  check bool "cleared snapshot differs from absent snapshot" true (empty <> absent);
  check string "cleared state is stable across ticks" empty (render ())
;;

let test_recall_ignores_unchanged_snapshot_recommits () =
  with_temp_keepers @@ fun keepers_dir ->
  let render () = Masc.Keeper_memory_os_recall.render_context
    ~keepers_dir ~keeper_id:"keeper" () in
  let first = replace ~keepers_dir ~facts:[fact ~claim:"stable current fact" ()] () |> require_ok in
  let initial = render () in
  let second = Current.replace ~keepers_dir ~keeper_id:"keeper"
    ~expected_revision:(Some first.revision) ~now:400.0
    ~source:(source Current.Librarian) ~facts:first.facts () |> require_ok in
  check bool "recommit advances durable revision" true (second.revision > first.revision);
  check bool "recommit advances durable update time" true (second.updated_at > first.updated_at);
  check string "same facts render identically after recommit" initial (render ());
  ignore (Current.replace ~keepers_dir ~keeper_id:"keeper"
    ~expected_revision:(Some second.revision) ~now:500.0
    ~source:(source Current.Librarian) ~facts:[fact ~claim:"changed current fact" ()] () |> require_ok);
  check bool "changed fact changes model input" true (initial <> render ())
;;

let test_recall_does_not_hide_current_truth_behind_a_size_threshold () =
  with_temp_keepers
  @@ fun keepers_dir ->
  let prompt_dir = Filename.concat keepers_dir "prompts" in
  Unix.mkdir prompt_dir 0o755;
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  ignore (replace ~keepers_dir ~facts:[ fact ~claim:(String.make 256 'y') () ] () |> require_ok);
  let rendered =
    Masc.Keeper_memory_os_recall.render_context
      ~keepers_dir
      ~keeper_id:"keeper"
      ()
  in
  check bool "large current truth reaches recall" true
    (String.length rendered > 0)
;;

let test_explicit_upsert_preserves_snapshot_and_records_delta () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first" () in
  let second = fact ~claim:"second" () in
  ignore
    (replace
       ~keepers_dir
       ~facts:[ first ]
       ()
     |> require_ok);
  let snapshot =
    Current.upsert_fact
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:300.0
      ~source:(source Current.Explicit_write)
      second
    |> require_upsert_ok
  in
  check int "revision" 2 snapshot.revision;
  check (list string) "facts" (fact_ids [ first; second ]) (fact_ids snapshot.facts);
  check (list string) "added" (fact_ids [ second ]) (fact_ids snapshot.change.added);
  check (list string) "removed" [] (fact_ids snapshot.change.removed);
  check int "retained" 1 snapshot.change.retained
;;

let test_explicit_upsert_preserves_first_seen_for_same_claim () =
  with_temp_keepers @@ fun keepers_dir ->
  let initial = fact ~claim:"same claim" () in
  ignore (replace ~keepers_dir ~facts:[ initial ] () |> require_ok);
  let repeated =
    { initial with category = Types.Lesson; first_seen = 500.0 }
  in
  let snapshot =
    Current.upsert_fact
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:600.0
      ~source:(source Current.Explicit_write)
      repeated
    |> require_upsert_ok
  in
  let stored = List.hd snapshot.facts in
  check (float 0.0) "first insertion time remains authoritative" 100.0 stored.first_seen;
  check bool "direct category update is retained" true (stored.category = Types.Lesson)
;;

let test_explicit_keepers_dirs_do_not_cross_contaminate () =
  with_temp_keepers @@ fun first_dir ->
  with_temp_keepers @@ fun second_dir ->
  let first = fact ~claim:"first workspace" () in
  let second = fact ~claim:"second workspace" () in
  ignore (replace ~keepers_dir:first_dir ~facts:[ first ] () |> require_ok);
  ignore (replace ~keepers_dir:second_dir ~facts:[ second ] () |> require_ok);
  let read dir =
    Current.read_for_keepers_dir ~keepers_dir:dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
  in
  check
    (list string)
    "first workspace remains isolated"
    (fact_ids [ first ])
    (fact_ids (read first_dir).facts);
  check
    (list string)
    "second workspace remains isolated"
    (fact_ids [ second ])
    (fact_ids (read second_dir).facts)
;;

let test_every_commit_appends_one_journal_entry () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first" () in
  let second = fact ~claim:"second" () in
  ignore (replace ~keepers_dir ~facts:[ first; second ] () |> require_ok);
  ignore
    (replace
       ~keepers_dir
       ~expected_revision:(Some 1)
       ~facts:[ first ]
       ~dropped_statements:
         [ { Masc.Keeper_memory_os_types.memory_id =
               Masc.Keeper_memory_os_types.memory_id second
           ; reason = "superseded during test"
           }
         ]
       ()
     |> require_ok);
  ignore
    (Current.upsert_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:300.0
       ~source:(source Current.Explicit_write)
       second
     |> require_upsert_ok);
  let lines = read_journal_lines ~keepers_dir in
  check int "one journal line per commit" 3 (List.length lines);
  let open Yojson.Safe.Util in
  let librarian_drop = List.nth lines 1 in
  check int "revision" 2 (librarian_drop |> member "revision" |> to_int);
  check int "retained recorded" 1
    (librarian_drop |> member "change" |> member "retained" |> to_int);
  check int "removed recorded" 1
    (librarian_drop |> member "change" |> member "removed" |> to_list |> List.length);
  check string "librarian source kind" "librarian"
    (librarian_drop |> member "source" |> member "kind" |> to_string);
  let dropped = librarian_drop |> member "dropped" |> to_list in
  check int "one drop statement" 1 (List.length dropped);
  check string "drop statement names the removed fact"
    (Masc.Keeper_memory_os_types.memory_id second)
    (List.hd dropped |> member "memory_id" |> to_string);
  check string "drop statement carries the reason" "superseded during test"
    (List.hd dropped |> member "reason" |> to_string);
  check bool "statement-less commit has no dropped key" true
    (List.nth lines 0 |> member "dropped" = `Null);
  let explicit = List.nth lines 2 in
  check int "explicit revision" 3 (explicit |> member "revision" |> to_int);
  check string "explicit source kind" "explicit_write"
    (explicit |> member "source" |> member "kind" |> to_string);
  check bool "explicit commit has no dropped key" true
    (explicit |> member "dropped" = `Null)
;;

let test_rejected_commit_appends_no_journal_entry () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
  (match replace ~keepers_dir ~expected_revision:None ~facts:[] () with
   | Error _ -> ()
   | Ok _ -> fail "stale revision was accepted");
  check int "only committed revisions are journaled" 1
    (List.length (read_journal_lines ~keepers_dir))
;;

let test_invalid_drop_identity_has_no_effect () =
  with_temp_keepers @@ fun keepers_dir ->
  (match
     replace
       ~keepers_dir
       ~facts:[ fact () ]
       ~dropped_statements:
         [ { Masc.Keeper_memory_os_types.memory_id = "not-a-memory-id"
           ; reason = "invalid producer identity"
           }
         ]
       ()
   with
   | Error _ -> ()
   | Ok _ -> fail "invalid drop identity committed a snapshot");
  check bool "invalid drop writes no snapshot" false
    (Sys.file_exists
       (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"));
  check int "invalid drop writes no journal" 0
    (List.length (read_journal_lines ~keepers_dir))
;;

(* The purge hook drops the memoized journal appender before unlinking
   (Fs_compat.invalidate_cached_writer): without that, a same-process
   successor keeper would keep appending to the deleted inode and no new
   journal file would ever appear. This exercises that exact sequence. *)
let test_journal_recreated_after_purge_sequence () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact ~claim:"before purge" () ] () |> require_ok);
  let journal_path =
    Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  check bool "journal exists before purge" true (Sys.file_exists journal_path);
  Fs_compat.invalidate_cached_writer journal_path;
  Sys.remove journal_path;
  ignore
    (Current.upsert_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:300.0
       ~source:(source Current.Explicit_write)
       (fact ~claim:"after purge" ())
     |> require_upsert_ok);
  check bool "journal recreated after purge" true (Sys.file_exists journal_path);
  check int "only the post-purge commit is journaled" 1
    (List.length (read_journal_lines ~keepers_dir))
;;

(* Memory OS snapshots and the journal live in the config keepers directory,
   outside the runtime directory the purge already removes: without plan
   entries a purged keeper leaks them to a later keeper with the same name. *)
let test_purge_plan_removes_memory_sidecars () =
  let module Shutdown = Masc.Keeper_shutdown_types in
  let context = { Shutdown.requested_name = "keeper" } in
  let plan = Shutdown.dashboard_purge_artifact_plan ~keeper_name:"keeper" context in
  let contains artifact = List.exists (fun entry -> entry = artifact) plan in
  check bool "plan removes the fact snapshot" true
    (contains Shutdown.Keeper_memory_current_artifact);
  check bool "plan removes an interrupted retraction plan" true
    (contains Shutdown.Keeper_memory_retraction_plan_artifact);
  check bool "plan removes the source-bound snapshot" true
    (contains Shutdown.Keeper_memory_source_current_artifact);
  check bool "plan removes the working context recall index" true
    (contains Shutdown.Keeper_working_context_recall_artifact);
  check bool "plan removes the working context" true
    (contains Shutdown.Keeper_working_context_artifact);
  check bool "plan removes the memory journal" true
    (contains Shutdown.Keeper_memory_journal_artifact);
  check bool "plan removes the absorbed memory rows" true
    (contains Shutdown.Keeper_memory_absorbed_artifact)
;;

let durable_range_id : Current.durable_range_id =
  { receipt_scope = "runtime-cluster-a"
  ; trace_id = "trace"
  ; history_start_boundary_line = 1
  ; start_atom = 1
  ; end_atom = 2
  ; last_atom_digest = String.make 64 'a'
  ; end_boundary_line = 2
  ; boundary_lines_seen = 2
  }
;;

let official_range_id : Current.official_range_id =
  { receipt_scope = durable_range_id.receipt_scope
  ; after_boundary_line = 2
  ; turns = [ 3, Ids.Turn_ref.make ~trace_id:"official" ~absolute_turn:1
            ; 5, Ids.Turn_ref.make ~trace_id:"official" ~absolute_turn:2 ]
  }
;;

let read_official ~keepers_dir =
  Current.committed_official_range ~keepers_dir ~keeper_id:"keeper"
    ~receipt_scope:official_range_id.receipt_scope
;;

let require_official ~keepers_dir =
  match read_official ~keepers_dir with
  | Ok (Some range) ->
    check bool "exact official range" true (range = official_range_id)
  | Ok None -> fail "official receipt missing"
  | Error detail -> fail detail
;;

let rewrite_receipts ~keepers_dir transform =
  let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  let json = Yojson.Safe.from_string (Fs_compat.load_file path) in
  Fs_compat.save_file path (Yojson.Safe.to_string (transform json))
;;

let map_receipts f = function
  | `Assoc [ "receipts", `List receipts ] ->
    `Assoc [ "receipts", `List (List.map f receipts) ]
  | _ -> fail "expected receipt ledger"
;;

let map_field key f = function
  | `Assoc fields -> `Assoc (List.map (fun (name, value) ->
      name, if String.equal name key then f value else value) fields)
  | _ -> fail "expected object"
;;

let test_atom_receipt_wire_and_exclusive_identity () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (apply_disposition ~keepers_dir ~durable_range_id () |> require_ok);
  let snapshot = Fs_compat.load_file
    (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper") in
  let expected =
    `Assoc [ "receipts", `List [
      `Assoc [ "state", `String "committed"
      ; "range_id", `Assoc
          [ "receipt_scope", `String "runtime-cluster-a"
          ; "trace_id", `String "trace"
          ; "history_start_boundary_line", `Int 1
          ; "start_atom", `Int 1; "end_atom", `Int 2
          ; "last_atom_digest", `String (String.make 64 'a')
          ; "end_boundary_line", `Int 2; "boundary_lines_seen", `Int 2 ]
      ; "snapshot_revision", `Int 1
      ; "snapshot_sha256", `String Digestif.SHA256.(digest_string snapshot |> to_hex)
      ] ] ]
  in
  let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  check string "atom wire remains exact" (Yojson.Safe.to_string expected)
    (String.trim (Fs_compat.load_file path));
  (* The frozen version-1 bytes must still be accepted after a writer change. *)
  Fs_compat.save_file path (Yojson.Safe.to_string expected);
  (match Current.committed_durable_range
           ~keepers_dir ~keeper_id:"keeper"
           ~receipt_scope:durable_range_id.receipt_scope with
   | Ok (Some range) -> check bool "historical atom receipt" true
                          (range = durable_range_id)
   | Ok None -> fail "historical atom receipt missing"
   | Error detail -> fail detail);
  List.iter (fun transform ->
    Fs_compat.save_file path (Yojson.Safe.to_string (map_receipts transform expected));
    match read_official ~keepers_dir with
    | Error _ -> ()
    | Ok _ -> fail "receipt accepted both or neither identity")
    [ (function
       | `Assoc fields -> `Assoc (("official_range_id", `Null) :: fields)
       | _ -> fail "expected receipt")
    ; (function
       | `Assoc fields -> `Assoc (List.remove_assoc "range_id" fields)
       | _ -> fail "expected receipt")
    ]
;;

let test_official_receipt_survives_other_commits () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (apply_disposition ~keepers_dir ~official_range_id () |> require_ok);
  let snapshot = Fs_compat.load_file
    (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper") in
  let expected =
    `Assoc [ "receipts", `List [
      `Assoc [ "state", `String "committed"
      ; "official_range_id", `Assoc
          [ "receipt_scope", `String "runtime-cluster-a"
          ; "after_boundary_line", `Int 2
          ; "turns", `List
              (List.map (fun (line, turn_ref) ->
                `Assoc [ "line", `Int line
                       ; "turn_ref", Ids.Turn_ref.to_yojson turn_ref ])
                official_range_id.turns)
          ]
      ; "snapshot_revision", `Int 1
      ; "snapshot_sha256", `String Digestif.SHA256.(digest_string snapshot |> to_hex)
      ] ] ]
  in
  let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  check string "official wire remains exact" (Yojson.Safe.to_string expected)
    (String.trim (Fs_compat.load_file path));
  Fs_compat.save_file path (Yojson.Safe.to_string expected);
  require_official ~keepers_dir;
  ignore (apply_disposition ~keepers_dir ~durable_range_id () |> require_ok);
  ignore (apply_disposition ~keepers_dir () |> require_ok);
  require_official ~keepers_dir
;;

let test_mixed_receipt_prepared_recovery () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (apply_disposition ~keepers_dir ~durable_range_id ~official_range_id () |> require_ok);
  rewrite_receipts ~keepers_dir (function
    | `Assoc [ "receipts", `List [ first; second ] ] ->
      let open Yojson.Safe.Util in
      check string "same snapshot SHA" (first |> member "snapshot_sha256" |> to_string)
        (second |> member "snapshot_sha256" |> to_string);
      check int "same revision" (first |> member "snapshot_revision" |> to_int)
        (second |> member "snapshot_revision" |> to_int);
      map_receipts (map_field "state" (fun _ -> `String "prepared"))
        (`Assoc [ "receipts", `List [ first; second ] ])
    | _ -> fail "mixed commit did not persist both receipts");
  require_official ~keepers_dir;
  (match Current.committed_durable_range ~keepers_dir ~keeper_id:"keeper"
     ~receipt_scope:durable_range_id.receipt_scope with
   | Ok (Some range) -> check bool "atom recovered too" true (range = durable_range_id)
   | Ok None -> fail "atom receipt missing"
   | Error detail -> fail detail)
;;

let test_official_receipt_rejects_invalid_identity () =
  let invalid =
    [ { official_range_id with turns = [] }
    ; { official_range_id with turns = List.rev official_range_id.turns }
    ; { official_range_id with after_boundary_line = 3 }
    ; { official_range_id with after_boundary_line = -1 }
    ; { official_range_id with receipt_scope = " " }
    ]
  in
  List.iter (fun official_range_id ->
    with_temp_keepers @@ fun keepers_dir ->
    (match apply_disposition ~keepers_dir ~official_range_id () with
     | Error _ -> ()
     | Ok _ -> fail "invalid official identity committed");
    check bool "snapshot not created" false
      (Sys.file_exists (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"))) invalid;
  List.iter (fun turns ->
    with_temp_keepers @@ fun keepers_dir ->
    ignore (apply_disposition ~keepers_dir ~official_range_id () |> require_ok);
    rewrite_receipts ~keepers_dir
      (map_receipts (map_field "official_range_id" (map_field "turns" (fun _ -> turns))));
    match read_official ~keepers_dir with
    | Error _ -> ()
    | Ok _ -> fail "malformed persisted receipt accepted")
    [ `List []
    ; `List [ `Assoc [ "line", `Int 3; "turn_ref", `String "invalid" ] ]
    ; `List [ `Assoc [ "line", `Int 3; "turn_ref", `String "official#1"; "extra", `Bool true ] ]
    ]
;;

let require_no_committed_range ~keepers_dir label =
  match
    Current.committed_durable_range
      ~keepers_dir
      ~keeper_id:"keeper"
      ~receipt_scope:durable_range_id.receipt_scope
  with
  | Ok None -> ()
  | Ok (Some _) -> fail label
  | Error detail -> fail detail
;;

let require_committed_range ~keepers_dir label =
  match
    Current.committed_durable_range
      ~keepers_dir
      ~keeper_id:"keeper"
      ~receipt_scope:durable_range_id.receipt_scope
  with
  | Ok (Some range_id) -> range_id
  | Ok None -> fail label
  | Error detail -> fail detail
;;

let test_committed_range_receipt_rejects_absent_snapshot () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (apply_disposition ~keepers_dir ~durable_range_id () |> require_ok);
  Sys.remove (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper");
  require_no_committed_range
    ~keepers_dir
    "receipt authorized a range without a Memory snapshot";
  check bool "invalid receipt is removed" false
    (Sys.file_exists (Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper"))
;;

let test_committed_range_receipt_rejects_snapshot_rollback () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact ~claim:"before" () ] () |> require_ok);
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let prior = Fs_compat.load_file snapshot_path in
  ignore
    (apply_disposition ~keepers_dir ~durable_range_id ~new_claims:[ fact ~claim:"after" () ] ()
     |> require_ok);
  Fs_compat.save_file snapshot_path prior;
  require_no_committed_range
    ~keepers_dir
    "receipt authorized a range after snapshot revision rollback"
;;

let test_committed_range_receipt_rejects_same_revision_different_snapshot () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (apply_disposition ~keepers_dir ~durable_range_id () |> require_ok);
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let changed =
    match Yojson.Safe.from_string (Fs_compat.load_file snapshot_path) with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "updated_at" then name, `Float 201.0 else name, value)
           fields)
    | _ -> fail "Memory snapshot was not an object"
  in
  Fs_compat.save_file snapshot_path (Yojson.Safe.to_string changed);
  require_no_committed_range
    ~keepers_dir
    "receipt authorized different snapshot bytes at the same revision"
;;

let test_committed_range_receipt_survives_retract_and_replace () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"target" () in
  ignore
    (apply_disposition
       ~keepers_dir
       ~durable_range_id
       ~new_claims:[ target ]
       ()
     |> require_ok);
  (match
     Current.retract_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:201.0
       ~source:(source Current.Explicit_retract)
       ~memory_id:(Types.memory_id target)
       ~reason:"test retraction"
       ()
   with
   | Ok snapshot -> check int "retract revision" 2 snapshot.revision
   | Error _ -> fail "retract failed");
  ignore
    (require_committed_range
       ~keepers_dir
       "explicit retract erased the committed range receipt");
  ignore
    (replace ~keepers_dir ~expected_revision:(Some 2) ~facts:[] () |> require_ok);
  ignore
    (require_committed_range
       ~keepers_dir
       "replace erased the committed range receipt")
;;

let test_committed_range_receipts_are_scoped_per_runtime_cluster () =
  with_temp_keepers @@ fun keepers_dir ->
  let cluster_a = durable_range_id in
  let cluster_b =
    { durable_range_id with
      receipt_scope = "runtime-cluster-b"
    ; trace_id = "trace-b"
    ; end_atom = 3
    ; last_atom_digest = String.make 64 'b'
    ; end_boundary_line = 3
    ; boundary_lines_seen = 3
    }
  in
  ignore (apply_disposition ~keepers_dir ~durable_range_id:cluster_a () |> require_ok);
  ignore (apply_disposition ~keepers_dir ~durable_range_id:cluster_b () |> require_ok);
  let read scope =
    match
      Current.committed_durable_range
        ~keepers_dir
        ~keeper_id:"keeper"
        ~receipt_scope:scope
    with
    | Ok (Some range_id) -> range_id
    | Ok None -> failf "cluster receipt %s was replaced" scope
    | Error detail -> fail detail
  in
  check string
    "cluster A receipt survives cluster B commit"
    cluster_a.trace_id
    (read cluster_a.receipt_scope).trace_id;
  check string
    "cluster B has its own receipt"
    cluster_b.trace_id
    (read cluster_b.receipt_scope).trace_id
;;

(* A Librarian pass that changes no fact keeps the stored snapshot: the same
   revision and bytes, no commit notification, and one journal line naming the
   kept revision. Its range still commits, bound to the kept bytes, so the
   durable consumer does not read that range again. A pass that changes a fact
   writes a new revision as before. *)
let test_unchanged_pass_keeps_snapshot_and_commits_range () =
  let module Notifications = Masc.Keeper_memory_commit_notifications in
  with_temp_keepers @@ fun keepers_dir ->
  let physical_keepers_dir = Unix.realpath keepers_dir in
  let notified = ref [] in
  let stop = Notifications.subscribe (fun event ->
    if String.equal event.Notifications.keepers_dir physical_keepers_dir then
      notified := event.revision :: !notified)
  in
  Fun.protect ~finally:stop (fun () ->
    let pass ?durable_range_id ?on_committed ~now ~new_claims () =
      Current.apply_disposition ?on_committed ?durable_range_id ~absorbed:[] ~revisions:[]
        ~keepers_dir ~keeper_id:"keeper" ~now
        ~source:{ Current.kind = Current.Librarian; trace_id = Printf.sprintf "pass-%.0f" now }
        ~new_claims ()
      |> require_ok
    in
    let is_unchanged (disposition : Current.disposition) =
      match disposition.commit with
      | Current.Unchanged -> true
      | Current.Rewritten -> false
    in
    let first = pass ~now:200.0 ~new_claims:[ fact ~claim:"kept claim" () ] () in
    check bool "the first pass writes" false (is_unchanged first);
    let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let stored = Fs_compat.load_file snapshot_path in
    let journal_before = List.length (read_journal_lines ~keepers_dir) in
    let observed = ref None in
    let kept =
      pass ~durable_range_id ~now:300.0
        ~on_committed:(fun disposition -> observed := Some (is_unchanged disposition))
        ~new_claims:[ fact ~claim:"kept claim" () ] ()
    in
    check bool "a pass that restates the facts is unchanged" true (is_unchanged kept);
    check (option bool) "the pass still settles" (Some true) !observed;
    check int "the revision stays" first.snapshot.revision kept.snapshot.revision;
    check (float 0.0) "updated_at stays" 200.0 kept.snapshot.updated_at;
    check string "the snapshot bytes stay" stored (Fs_compat.load_file snapshot_path);
    check (list int) "only the writing pass notifies" [ first.snapshot.revision ] !notified;
    let journal = read_journal_lines ~keepers_dir in
    check int "the pass still gets its journal line" (journal_before + 1) (List.length journal);
    let open Yojson.Safe.Util in
    let line = List.nth journal (List.length journal - 1) in
    check int "the line names the kept revision" kept.snapshot.revision
      (line |> member "revision" |> to_int);
    check string "the line is this pass's" "pass-300"
      (line |> member "source" |> member "trace_id" |> to_string);
    check int "the line adds nothing" 0
      (line |> member "change" |> member "added" |> to_list |> List.length);
    check int "the line removes nothing" 0
      (line |> member "change" |> member "removed" |> to_list |> List.length);
    let committed_range () =
      Current.committed_durable_range ~keepers_dir ~keeper_id:"keeper"
        ~receipt_scope:durable_range_id.receipt_scope
    in
    (match committed_range () with
     | Ok (Some range) -> check bool "the range commits on the kept snapshot" true
                            (range = durable_range_id)
     | Ok None -> fail "an unchanged pass left its range uncommitted"
     | Error detail -> fail detail);
    let rewritten = pass ~now:400.0 ~new_claims:[ fact ~claim:"new claim" () ] () in
    check bool "a pass that adds a fact rewrites" false (is_unchanged rewritten);
    check int "and advances the revision" (kept.snapshot.revision + 1) rewritten.snapshot.revision;
    check bool "and replaces the bytes" false
      (String.equal stored (Fs_compat.load_file snapshot_path));
    check (list int) "and notifies"
      [ rewritten.snapshot.revision; first.snapshot.revision ] !notified;
    match committed_range () with
    | Ok (Some _) -> ()
    | Ok None -> fail "a later rewrite dropped the committed range"
    | Error detail -> fail detail)
;;

let candidate_receipt sequence request_id payload : Current.explicit_candidate_id =
  {queue_generation="candidate-generation"; request_id; sequence;
   input_sha256=Digestif.SHA256.(digest_string payload |> to_hex)}
;;

let commit_candidates ~keepers_dir ids claims =
  Current.apply_disposition ~explicit_candidate_ids:ids ~absorbed:[] ~revisions:[]
    ~keepers_dir ~keeper_id:"keeper" ~now:200. ~source:(source Current.Librarian)
    ~new_claims:claims ()
;;

let read_candidates ~keepers_dir generation =
  Current.committed_explicit_candidates ~keepers_dir ~keeper_id:"keeper"
    ~queue_generation:generation |> require_ok
;;

let test_sparse_candidate_receipts_survive_retirement () =
  with_temp_keepers @@ fun keepers_dir ->
  let a = candidate_receipt 1 "pending-a" "unresolved A" in
  let b = candidate_receipt 2 "settled-b" "B" in
  let c = candidate_receipt 3 "settled-c" "C" in
  let target = fact ~claim:"B and C establish one durable policy" () in
  let first = commit_candidates ~keepers_dir [b;c] [target] |> require_ok in
  check bool "sparse set rewrites one snapshot" true (first.commit=Current.Rewritten);
  let found = read_candidates ~keepers_dir b.queue_generation in
  check bool "only B and C have authoritative receipts" true
    (List.length found=2 && List.mem b found && List.mem c found && not (List.mem a found));
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let before = Fs_compat.load_file snapshot_path in
  let settled_a = commit_candidates ~keepers_dir [a] [] |> require_ok in
  check bool "later A settlement can keep the snapshot unchanged" true
    (settled_a.commit=Current.Unchanged);
  check string "unchanged commit preserves snapshot bytes" before (Fs_compat.load_file snapshot_path);
  let all = read_candidates ~keepers_dir b.queue_generation in
  check bool "no-change A receipt preserves B and C" true
    (List.length all=3 && List.for_all (fun id -> List.mem id all) [a;b;c]);
  (match Current.retract_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
      ~source:(source Current.Explicit_retract) ~memory_id:(Types.memory_id target)
      ~reason:"policy retired after consumption" () with
   | Ok _ -> () | Error _ -> fail "target retirement failed");
  let retired = Fs_compat.load_file snapshot_path in
  let receipt_path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  let receipts = Fs_compat.load_file receipt_path in
  List.iter (fun ids ->
    (match commit_candidates ~keepers_dir ids [target] with
     | Error _ -> () | Ok _ -> fail "consumed input resurrected retired knowledge");
    check string "replay refusal preserves retired snapshot" retired (Fs_compat.load_file snapshot_path);
    check string "replay refusal preserves receipt ledger" receipts (Fs_compat.load_file receipt_path))
    [[b]; [b;c]; [candidate_receipt 5 "fresh-during-replay" "new";b]; [{b with input_sha256=(candidate_receipt 2 "settled-b" "changed payload").input_sha256}];
     [{b with request_id="different-request-same-sequence"}]; [{b with sequence=4}]];
  check int "retirement does not forget consumed candidates" 3
    (List.length (read_candidates ~keepers_dir b.queue_generation));
  let other = {b with queue_generation="another-generation"} in
  ignore (commit_candidates ~keepers_dir [other] [] |> require_ok);
  check bool "another generation has an independent receipt" true
    (read_candidates ~keepers_dir other.queue_generation = [other]);
  check int "other generation leaves original receipts intact" 3
    (List.length (read_candidates ~keepers_dir b.queue_generation))
;;

let test_candidate_receipt_reconciliation_preserves_first_order () =
  with_temp_keepers @@ fun keepers_dir ->
  let a = candidate_receipt 1 "first" "A" in
  let b = candidate_receipt 2 "second" "B" in
  ignore (commit_candidates ~keepers_dir [a;b] [fact ~claim:"policy" ()] |> require_ok);
  ignore (apply_disposition ~keepers_dir ~durable_range_id () |> require_ok);
  let expected = read_candidates ~keepers_dir a.queue_generation in
  let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  let canonical = Fs_compat.load_file path in
  rewrite_receipts ~keepers_dir (map_field "receipts" (function
    | `List receipts ->
        let atom = List.find (fun receipt ->
          Yojson.Safe.Util.member "range_id" receipt <> `Null) receipts in
        `List (receipts @ [atom])
    | _ -> fail "expected candidate and atom receipts"));
  check bool "dedup preserves the first occurrence order" true
    (read_candidates ~keepers_dir a.queue_generation = expected);
  let reconciled = Fs_compat.load_file path in
  check string "on-disk first-occurrence order is preserved" canonical reconciled;
  check int "duplicate atom removed without dropping candidates" 3
    Yojson.Safe.Util.(Yojson.Safe.from_string reconciled |> member "receipts" |> to_list |> List.length);
  check bool "reconciled reads are idempotent" true
    (read_candidates ~keepers_dir a.queue_generation = expected);
  check string "an unchanged receipt set is not rewritten" reconciled
    (Fs_compat.load_file path)
;;

let test_candidate_set_conflict_is_atomic () =
  List.iter (fun colliding ->
    with_temp_keepers @@ fun keepers_dir ->
    let b = candidate_receipt 2 "request-b" "B" in
    let c = candidate_receipt 3 "request-c" "C" in
    ignore (replace ~keepers_dir ~facts:[fact ~claim:"prior" ()] () |> require_ok);
    let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let before = Fs_compat.load_file snapshot_path in
    (match commit_candidates ~keepers_dir [c;b;colliding b] [fact ~claim:"must not commit" ()] with
     | Error _ -> () | Ok _ -> fail "conflicting candidate set committed");
    check string "whole conflicting set leaves snapshot unchanged" before (Fs_compat.load_file snapshot_path);
    check (list string) "no innocent member acquired a receipt" []
      (List.map (fun (id : Current.explicit_candidate_id) -> id.request_id)
        (read_candidates ~keepers_dir b.queue_generation)))
    [Fun.id; (fun (b : Current.explicit_candidate_id) -> {b with sequence=4});
     (fun (b : Current.explicit_candidate_id) -> {b with request_id="different-request"});
     (fun (b : Current.explicit_candidate_id) -> {b with input_sha256=String.make 64 'f'})]
;;

let test_candidate_prepared_set_recovers_exact_snapshot () =
  List.iter (fun exact ->
    with_temp_keepers @@ fun keepers_dir ->
    let b = candidate_receipt 2 "request-b" "B" in
    let c = candidate_receipt 3 "request-c" "C" in
    ignore (commit_candidates ~keepers_dir [b;c] [fact ~claim:"settled policy" ()] |> require_ok);
    rewrite_receipts ~keepers_dir (map_receipts (fun receipt ->
      let receipt = map_field "state" (fun _ -> `String "prepared") receipt in
      if exact then receipt
      else map_field "snapshot_sha256" (fun _ -> `String (String.make 64 'f')) receipt));
    let found = read_candidates ~keepers_dir b.queue_generation in
    check bool "whole set recovers only for the exact committed snapshot" true
      (if exact then List.length found=2 && List.mem b found && List.mem c found else found=[]);
    if exact then (
      let json = Yojson.Safe.from_file
        (Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper") in
      check (list string) "recovery persists both committed states" ["committed";"committed"]
        Yojson.Safe.Util.(json |> member "receipts" |> to_list
          |> List.map (fun receipt -> receipt |> member "state" |> to_string)))) [true;false]
;;

let recall_binding sequence source_fact target : Current.admission_recall_binding =
  let request_id = Printf.sprintf "recall-source-%d" sequence in
  let row = `Assoc ["sequence",`Int sequence; "request_id",`String request_id;
    "fact",Types.fact_to_json source_fact] in
  {candidate_id=candidate_receipt sequence request_id (Yojson.Safe.to_string row);
   source_fact; target_memory_id=Types.memory_id target}
;;

let current_revision ~keepers_dir =
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
  | Ok snapshot -> Option.map (fun (current : Current.t) -> current.revision) snapshot
  | Error detail -> fail detail
;;

let commit_recall ?decided_at_revision ~keepers_dir binding claims =
  let decided_at_revision = match decided_at_revision with
    | Some revision -> revision
    | None -> current_revision ~keepers_dir in
  Current.apply_disposition ~explicit_candidate_ids:[binding.Current.candidate_id]
    ~admission_recall:{decided_at_revision; bindings=[binding]} ~absorbed:[] ~revisions:[]
    ~keepers_dir ~keeper_id:"keeper" ~now:200. ~source:(source Current.Librarian)
    ~new_claims:claims ()
;;

let read_recall ~keepers_dir =
  Current.read_with_admission_recall_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
;;

let test_admission_recall_commits_recovers_and_expires_on_retirement () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"Release R001 through R200 require two approvals." () in
  let evidence = board_fact "p-0123456789abcdef0123456789abcdef" ~claim:"R002 requires two approvals." in
  let binding = recall_binding 1 evidence target in
  let first = commit_recall ~keepers_dir binding [target] |> require_ok in
  let snapshot, found = read_recall ~keepers_dir |> require_ok in
  check bool "current target and exact Board provenance are read coherently" true
    (snapshot=Some first.snapshot && found=[binding]);
  check bool "binding also proves consumption of its original candidate" true
    (read_candidates ~keepers_dir binding.candidate_id.queue_generation=[binding.candidate_id]);
  let second = recall_binding 2 (fact ~claim:"R199 requires two approvals." ()) target in
  let unchanged = commit_recall ~keepers_dir second [] |> require_ok in
  check int "binding-only admission preserves the current snapshot revision"
    first.snapshot.revision unchanged.snapshot.revision;
  rewrite_receipts ~keepers_dir (map_receipts (map_field "state" (fun _ -> `String "prepared")));
  let _, recovered = read_recall ~keepers_dir |> require_ok in
  check bool "both source bindings recover against the exact kept snapshot" true
    (List.length recovered=2 && List.mem binding recovered && List.mem second recovered);
  (match Current.retract_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
    ~source:(source Current.Explicit_retract) ~memory_id:(Types.memory_id target)
    ~reason:"policy retired" () with
   | Ok _ -> () | Error _ -> fail "target retirement failed");
  check int "retired target has no search binding" 0
    (List.length (snd (read_recall ~keepers_dir |> require_ok)));
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
    ~source:(source Current.Explicit_write) target |> require_upsert_ok);
  check int "readding identical bytes never revives old source bindings" 0
    (List.length (snd (read_recall ~keepers_dir |> require_ok)));
  check int "retirement retains the consumed candidate receipts" 2
    (List.length (read_candidates ~keepers_dir binding.candidate_id.queue_generation))
;;

let test_admission_recall_refuses_a_target_retired_after_the_decision () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"Release R001 through R200 require two approvals." () in
  ignore (replace ~keepers_dir ~facts:[target] () |> require_ok);
  (* The decision reads Memory here. *)
  let decided = current_revision ~keepers_dir in
  (* While the model runs, the keeper retracts the target and adds the same
     claim back: the same memory_id, a new incarnation. *)
  (match Current.retract_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
    ~source:(source Current.Explicit_retract) ~memory_id:(Types.memory_id target)
    ~reason:"policy retired" () with
   | Ok _ -> () | Error _ -> fail "target retirement failed");
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
    ~source:(source Current.Explicit_write) target |> require_upsert_ok);
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let before = Fs_compat.load_file snapshot_path in
  let binding = recall_binding 1 (fact ~claim:"R002 requires two approvals." ()) target in
  (match commit_recall ~decided_at_revision:decided ~keepers_dir binding [] with
   | Error _ -> ()
   | Ok _ -> fail "a binding decided before the retirement attached to the new incarnation");
  check string "the refused binding changes no current bytes" before (Fs_compat.load_file snapshot_path);
  check int "the refused binding consumes no candidate" 0
    (List.length (read_candidates ~keepers_dir binding.candidate_id.queue_generation));
  (* A decision that read the current revision binds the re-added target. *)
  ignore (commit_recall ~keepers_dir binding [] |> require_ok);
  check int "a decision on current Memory still binds" 1
    (List.length (snd (read_recall ~keepers_dir |> require_ok)))
;;

(* A replacement without drop reasons appends its journal line best-effort.
   When that line, the older lines or the whole journal are gone, nothing
   left shows the retirement between the decision and the re-add. *)
let test_admission_recall_refuses_a_decision_across_missing_journal_revisions () =
  List.iter (fun damage ->
    with_temp_keepers @@ fun keepers_dir ->
    let target = fact ~claim:"Release R001 through R200 require two approvals." () in
    ignore (replace ~keepers_dir ~facts:[target] () |> require_ok);
    (* The decision reads Memory here. *)
    let decided = current_revision ~keepers_dir in
    let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let decision_journal = Fs_compat.load_file journal in
    ignore (replace ~keepers_dir ~expected_revision:decided ~facts:[] () |> require_ok);
    Fs_compat.invalidate_cached_writer journal;
    (match damage with
     | `Lost_line -> Fs_compat.save_file journal decision_journal
     | `Lost_prefix -> Fs_compat.save_file journal ""
     | `Lost_file -> ());
    ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
      ~source:(source Current.Explicit_write) target |> require_upsert_ok);
    (match damage with
     | `Lost_line | `Lost_prefix -> ()
     | `Lost_file -> Fs_compat.invalidate_cached_writer journal; Sys.remove journal);
    let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let before = Fs_compat.load_file snapshot_path in
    let binding = recall_binding 1 (fact ~claim:"R002 requires two approvals." ()) target in
    (match commit_recall ~decided_at_revision:decided ~keepers_dir binding [] with
     | Error _ -> ()
     | Ok _ -> fail "a journal gap let a binding attach across an unproven retirement");
    check string "the refused binding changes no current bytes" before
      (Fs_compat.load_file snapshot_path);
    check int "the refused binding consumes no candidate" 0
      (List.length (read_candidates ~keepers_dir binding.candidate_id.queue_generation));
    (* The gap lies before current Memory, so a decision on it binds and
       search finds the binding. *)
    ignore (commit_recall ~keepers_dir binding [] |> require_ok);
    check bool "a decision on current Memory still binds" true
      (snd (read_recall ~keepers_dir |> require_ok) = [binding]))
    [`Lost_line; `Lost_prefix; `Lost_file]
;;

let test_admission_recall_refuses_unbound_or_mistargeted_payloads () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"consolidated target" () in
  let binding = recall_binding 1 (fact ~claim:"original scope R002" ()) target in
  ignore (replace ~keepers_dir ~facts:[target] () |> require_ok);
  let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let before = Fs_compat.load_file snapshot_path in
  List.iter (fun (ids, binding) ->
    (match Current.apply_disposition ~explicit_candidate_ids:ids
       ~admission_recall:{decided_at_revision=current_revision ~keepers_dir; bindings=[binding]}
       ~absorbed:[] ~revisions:[] ~keepers_dir ~keeper_id:"keeper" ~now:250.
       ~source:(source Current.Librarian) ~new_claims:[] () with
     | Error _ -> () | Ok _ -> fail "invalid recall binding committed");
    check string "binding refusal changes no current bytes" before (Fs_compat.load_file snapshot_path);
    check int "binding refusal consumes no candidate" 0
      (List.length (read_candidates ~keepers_dir binding.candidate_id.queue_generation)))
    [[],binding;
     [binding.candidate_id],{binding with source_fact=fact ~claim:"changed candidate" ()};
     [binding.candidate_id],{binding with target_memory_id=Types.memory_id (fact ~claim:"absent target" ())}]
;;

let test_admission_recall_requires_complete_later_history_only_for_bindings () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"current target" () in
  let binding = recall_binding 1 (fact ~claim:"R002 evidence" ()) target in
  ignore (commit_recall ~keepers_dir binding [target] |> require_ok);
  let other = fact ~claim:"unrelated current fact" () in
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
    ~source:(source Current.Explicit_write) other |> require_upsert_ok);
  check bool "unrelated later revision preserves live binding" true
    (snd (read_recall ~keepers_dir |> require_ok)=[binding]);
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  Fs_compat.invalidate_cached_writer journal;
  Out_channel.with_open_bin journal (fun out -> output_string out "");
  (match read_recall ~keepers_dir with
   | Error _ -> () | Ok _ -> fail "missing intervening history silently revived a binding");
  (* A keeper with no bound receipts still has its ordinary current reader. *)
  with_temp_keepers @@ fun unbound_dir ->
  ignore (replace ~keepers_dir:unbound_dir ~facts:[target] () |> require_ok);
  let unbound_journal = Current.journal_path_for_keepers_dir ~keepers_dir:unbound_dir ~keeper_id:"keeper" in
  Fs_compat.invalidate_cached_writer unbound_journal;
  Out_channel.with_open_bin unbound_journal (fun out -> output_string out "malformed");
  let current, found = read_recall ~keepers_dir:unbound_dir |> require_ok in
  check bool "no binding requires no history scan" true (Option.is_some current && found=[])
;;

let test_admission_receipt_failure_preserves_direct_snapshot () =
  List.iter (fun unreadable ->
    with_temp_keepers @@ fun keepers_dir ->
    let target = fact ~claim:"direct current fact survives unavailable recall" () in
    let committed = replace ~keepers_dir ~facts:[target] () |> require_ok in
    let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
    if unreadable then Fs_compat.mkdir_p path
    else Out_channel.with_open_bin path (fun oc -> output_string oc "not-json");
    (match Current.read_with_admission_recall_status_for_keepers_dir
        ~keepers_dir ~keeper_id:"keeper" with
     | Ok (Some snapshot, Error _) ->
         check bool "independently decoded snapshot stays available" true
           (snapshot = committed)
     | Ok _ | Error _ -> fail "receipt failure hid the direct snapshot or claimed complete aliases");
    check bool "consumption remains fail-closed" true
      (Result.is_error (Current.committed_explicit_candidates
        ~keepers_dir ~keeper_id:"keeper" ~queue_generation:"generation"))) [false;true]
;;

let test_admission_recall_no_change_cannot_hide_missing_retirement_transition () =
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"R002 policy" () in
  let binding = recall_binding 1 (fact ~claim:"R002 original observation" ()) target in
  let born = commit_recall ~keepers_dir binding [target] |> require_ok in
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let birth_journal = Fs_compat.load_file journal in
  (* A replacement without drop reasons has best-effort journal delivery.
     Restore only the birth bytes to reproduce its missing transition. *)
  ignore (replace ~keepers_dir ~expected_revision:(Some born.snapshot.revision)
    ~facts:[] () |> require_ok);
  Fs_compat.invalidate_cached_writer journal;
  Fs_compat.save_file journal birth_journal;
  ignore (apply_disposition ~keepers_dir () |> require_ok);
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
    ~source:(source Current.Explicit_write) target |> require_upsert_ok);
  let rows = Fs_compat.load_jsonl journal in
  check bool "same-revision observation is explicitly unchanged" true
    (List.exists (fun json -> Yojson.Safe.Util.member "commit_effect" json = `String "unchanged") rows);
  (match read_recall ~keepers_dir with
   | Error _ -> ()
   | Ok _ -> fail "no-change journal observation concealed a missing retirement transition")
;;

let revision_evidence ~keepers_dir after_revision =
  Current.read_with_revision_evidence_for_keepers_dir
    ~keepers_dir ~keeper_id:"keeper" ~after_revision
;;

let test_declared_revision_links_survive_journal_failure () =
  List.iter (fun explicit -> with_temp_keepers @@ fun keepers_dir ->
    let original = fact ~claim:"original declared policy" () in
    let successor = fact ~claim:"revised declared policy" () in
    let seeded = replace ~keepers_dir ~facts:[original] () |> require_ok in
    let link : Types.revision =
      {superseded=Types.memory_id original; superseded_by=Types.memory_id successor} in
    let branch = fact ~claim:"separate verified policy branch" () in
    let links = if explicit then [link] else
      [link; {Types.superseded=Types.memory_id original; superseded_by=Types.memory_id branch}] in
    let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let seed_bytes = Fs_compat.load_file journal in
    Fs_compat.invalidate_cached_writer journal;
    Sys.remove journal;
    Unix.mkdir journal 0o700;
    let committed = if explicit then (
      match Current.supersede_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
        ~source:(source Current.Explicit_write) ~superseded_memory_id:link.superseded successor with
      | Ok (snapshot, _) -> snapshot | Error _ -> fail "explicit supersession failed")
      else apply_disposition ~keepers_dir ~revisions:links
        ~dropped_statements:[{Types.memory_id=Types.memory_id original;
          reason="verified policy split replaces the original"}]
        ~new_claims:[successor;branch] () |> require_ok in
    check int "replacement snapshot committed despite journal failure" (seeded.revision+1) committed.revision;
    let receipt_path = Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper" in
    let receipt = Yojson.Safe.from_file receipt_path in
    check int "prepared transaction retains each declared branch" (List.length links)
      Yojson.Safe.Util.(receipt |> member "revision_links" |> to_list |> List.length);
    (match revision_evidence ~keepers_dir seeded.revision with
     | Error _ -> () | Ok _ -> fail "unfinished lineage returned as complete evidence");
    Unix.rmdir journal;
    Fs_compat.save_file journal seed_bytes;
    (* A real subsequent writer recovers the exact committed link first. *)
    ignore (apply_disposition ~keepers_dir () |> require_ok);
    check bool "recovery clears prepared transaction" false (Sys.file_exists receipt_path);
    let current, records = revision_evidence ~keepers_dir seeded.revision |> require_ok in
    check bool "coherent successor snapshot" true
      (Option.map (fun (snapshot : Current.t) -> snapshot.facts) current=Some committed.facts);
    let transitions = List.filter (fun (row : Current.revision_evidence) ->
      row.commit_effect=Some Current.Rewritten) records in
    check bool "exact applied link recovered once" true
      (List.map (fun (row : Current.revision_evidence) -> row.revision_links) transitions=[Some links]);
    check bool "no-change reports no transition links" true
      (List.exists (fun (row : Current.revision_evidence) ->
        row.commit_effect=Some Current.Unchanged && row.revision_links=None) records)) [false;true]
;;

let test_revision_evidence_never_invents_links () =
  with_temp_keepers @@ fun keepers_dir ->
  let original = fact ~claim:"withdrawn exact identity" () in
  let seeded = replace ~keepers_dir ~facts:[original] () |> require_ok in
  ignore (replace ~keepers_dir ~expected_revision:(Some seeded.revision) ~facts:[] () |> require_ok);
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
    ~source:(source Current.Explicit_write) original |> require_upsert_ok);
  let _, records = revision_evidence ~keepers_dir seeded.revision |> require_ok in
  check bool "retire and re-add do not create an inferred successor" true
    (List.for_all (fun (row : Current.revision_evidence) -> row.revision_links=Some []) records);
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let rows = Fs_compat.load_jsonl journal |> List.map (function
    | `Assoc fields -> `Assoc (List.remove_assoc "commit_effect" (List.remove_assoc "revision_links" fields))
    | _ -> fail "fixture expected journal object") in
  Fs_compat.invalidate_cached_writer journal;
  Fs_compat.save_file journal (String.concat "\n" (List.map Yojson.Safe.to_string rows) ^ "\n");
  let _, unmarked = revision_evidence ~keepers_dir seeded.revision |> require_ok in
  check bool "unrecorded transition and links remain unknown" true
    (List.for_all (fun (row : Current.revision_evidence) ->
      row.commit_effect=None && row.revision_links=None) unmarked);
  (match revision_evidence ~keepers_dir (-1) with
   | Error _ -> () | Ok _ -> fail "negative evidence frontier accepted")
;;

let successor_recall ~keepers_dir =
  Current.read_successor_recall_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require_ok
;;

let revise_into ~keepers_dir old targets =
  let revisions = List.map (fun target ->
    {Types.superseded=Types.memory_id old; superseded_by=Types.memory_id target}) targets in
  apply_disposition ~keepers_dir ~revisions ~new_claims:targets
    ~dropped_statements:[{Types.memory_id=Types.memory_id old; reason="verified explicit correction"}] () |> require_ok
;;

let test_successor_recall_tracks_multistep_split_incarnations () =
  with_temp_keepers @@ fun keepers_dir ->
  let a = fact ~claim:"A scope covers R001 to R200" () in
  let b = fact ~claim:"B corrects R015" () in
  let c = fact ~claim:"C preserves other release policies" () in
  let d = fact ~claim:"D verifies R015 correction" () in
  let binding = recall_binding 1 (fact ~claim:"R015 original policy" ()) a in
  ignore (commit_recall ~keepers_dir binding [a] |> require_ok);
  check bool "initial binding remains direct" true
    ((successor_recall ~keepers_dir).direct_bindings=[binding]);
  ignore (revise_into ~keepers_dir a [b;c]);
  ignore (revise_into ~keepers_dir b [d]);
  let view = successor_recall ~keepers_dir in
  check int "split has two current path candidates" 2 (List.length view.successor_candidates);
  check int "retired original is never a direct binding" 0 (List.length view.direct_bindings);
  check bool "paths retain original target and historical source without adopting them" true
    (List.for_all (fun (candidate : Current.successor_recall_candidate) ->
      candidate.binding=binding && candidate.original_target=a) view.successor_candidates);
  check (list int) "chain follows revision order with no depth cut" [1;2]
    (List.map (fun (candidate : Current.successor_recall_candidate) -> List.length candidate.path)
      view.successor_candidates |> List.sort Int.compare);
  for _ = 1 to 20 do
    ignore (apply_disposition ~keepers_dir () |> require_ok);
    let cached = successor_recall ~keepers_dir in
    check bool "unchanged local observations preserve exact successor paths" true
      (cached.successor_candidates=view.successor_candidates && cached.unresolved=view.unresolved)
  done;
  let current = Option.get view.snapshot in
  ignore (replace ~keepers_dir ~expected_revision:(Some current.revision) ~facts:[c] () |> require_ok);
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:500.
    ~source:(source Current.Explicit_write) d |> require_upsert_ok);
  let after = successor_recall ~keepers_dir in
  check (list string) "re-added terminal cannot revive dead branch" [Types.memory_id c]
    (List.map (fun (candidate : Current.successor_recall_candidate) -> Types.memory_id candidate.target)
      after.successor_candidates);
  check bool "conclusive retirement remains distinct from history failure" true
    (List.exists (fun (item : Current.recall_unresolved) -> match item.reason with
      | Current.Retired_without_successor _ -> true | _ -> false) after.unresolved)
;;

let test_successor_recall_preserves_current_on_missing_history () =
  with_temp_keepers @@ fun keepers_dir ->
  let a = fact ~claim:"original target" () and b = fact ~claim:"current successor" () in
  let binding = recall_binding 1 (fact ~claim:"original source" ()) a in
  ignore (commit_recall ~keepers_dir binding [a] |> require_ok);
  ignore (revise_into ~keepers_dir a [b]);
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let original = Fs_compat.load_file journal in
  let rows = Fs_compat.load_jsonl journal in
  Fs_compat.invalidate_cached_writer journal;
  let strip keys = rows |> List.map (function
    | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (List.mem key keys)) fields)
    | json -> json) |> List.map Yojson.Safe.to_string |> String.concat "\n" in
  List.iter (fun (keys, expect_missing) ->
    Fs_compat.save_file journal (strip keys ^ "\n");
    let view = successor_recall ~keepers_dir in
    check bool "ordinary current facts survive lineage failure" true
      (Option.map (fun (snapshot : Current.t) -> snapshot.facts) view.snapshot=Some [b]);
    check int "no invented successor for incomplete evidence" 0 (List.length view.successor_candidates);
    check bool "unknown transition is distinguished from absent edge evidence" true
      (List.exists (fun (item : Current.recall_unresolved) -> match item.reason with
        | Current.Missing_transition _ -> expect_missing
        | Current.Unrecorded_lineage _ -> not expect_missing
        | _ -> false) view.unresolved))
    [["commit_effect";"revision_links"],true; ["revision_links"],false];
  Fs_compat.save_file journal "broken JSON\n";
  let broken = successor_recall ~keepers_dir in
  check bool "unreadable history does not erase ordinary snapshot" true (Option.is_some broken.snapshot);
  check bool "unreadable evidence is explicit" true
    (List.exists (fun (item : Current.recall_unresolved) -> match item.reason with
      | Current.History_unavailable _ -> true | _ -> false) broken.unresolved);
  Fs_compat.save_file journal original
;;

let test_successor_recall_rejects_phantom_target_added_later () =
  with_temp_keepers @@ fun keepers_dir ->
  let a = fact ~claim:"A original" () and b = fact ~claim:"B unrelated later addition" () in
  let c = fact ~claim:"C actual revision target" () in
  let binding = recall_binding 1 (fact ~claim:"source A" ()) a in
  ignore (commit_recall ~keepers_dir binding [a] |> require_ok);
  ignore (revise_into ~keepers_dir a [c]);
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
    ~source:(source Current.Explicit_write) b |> require_upsert_ok);
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let rows = Fs_compat.load_jsonl journal |> List.map (fun json ->
    if Yojson.Safe.Util.member "revision" json = `Int 2 then
      map_field "revision_links" (fun _ -> `List [`Assoc [
        "superseded",`String (Types.memory_id a); "superseded_by",`String (Types.memory_id b)]]) json
    else json) in
  Fs_compat.invalidate_cached_writer journal;
  Fs_compat.save_file journal (String.concat "\n" (List.map Yojson.Safe.to_string rows) ^ "\n");
  let view = successor_recall ~keepers_dir in
  check int "future unrelated addition cannot authorize past edge" 0 (List.length view.successor_candidates);
  check bool "phantom target has explicit invalid transition evidence" true
    (List.exists (fun (item : Current.recall_unresolved) ->
      item.reason=Current.Invalid_transition 2) view.unresolved)
;;

let test_prepared_receipt_before_revision_links_recovers_with_no_lineage () =
  with_temp_keepers @@ fun keepers_dir ->
  (* A receipt written before the [revision_links] field existed must decode:
     refusing it turns a leftover prepared transaction into a decode failure
     that blocks archive reads. It decodes with an empty lineage — no link is
     invented for the old writer — so the reader reports the ordinary
     pending-finalization state instead. *)
  let original = fact ~claim:"legacy prepared receipt drop reason" () in
  let legacy =
    `Assoc
      [ "plan_id", `Null
      ; "state", `String "prepared"
      ; "prior_revision", `Int 3
      ; "prior_snapshot_sha256", `String (String.make 64 'a')
      ; "target_revision", `Int 4
      ; "target_snapshot_sha256", `String (String.make 64 'b')
      ; ( "dropped"
        , `List
            [ `Assoc
                [ "memory_id", `String (Types.memory_id original)
                ; "reason", `String "verified split recorded before lineage"
                ] ] )
      ]
  in
  let path = Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string legacy) |> require_ok;
  match Current.read_dropped ~keepers_dir ~keeper_id:"keeper" ~current_facts:[] with
  | Error message ->
    check bool
      "legacy receipt reads as pending finalization, not a decode failure" true
      (String.starts_with
         ~prefix:"memory archive journal finalization pending keeper=keeper target_revision=4"
         message)
  | Ok _ -> fail "legacy prepared receipt read as a settled archive"
;;

(* An older writer may append its removal line and stop before clearing the
   receipt. Its line has no [revision_links] (a writer before [commit_effect]
   has neither key) and its receipt has no [revision_links]. Recovery reads
   that line as the rewrite and clears the receipt instead of appending the
   same revision a second time. *)
let test_legacy_removal_line_clears_legacy_receipt_once () =
  List.iter (fun missing_keys -> with_temp_keepers @@ fun keepers_dir ->
    let target = fact ~claim:"removal recorded by an older writer" () in
    let seeded = replace ~keepers_dir ~facts:[ target ] () |> require_ok in
    let seeded_hash =
      match Current.read_with_snapshot_sha256 ~keepers_dir ~keeper_id:"keeper" with
      | Ok (Some (_, hash)) -> hash
      | Ok None | Error _ -> fail "seeded snapshot hash is unavailable"
    in
    let journal_path =
      Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    in
    let seed_journal = Fs_compat.load_file journal_path in
    Fs_compat.invalidate_cached_writer journal_path;
    Sys.remove journal_path;
    Unix.mkdir journal_path 0o700;
    let request () =
      Current.retract_facts
        ~keepers_dir
        ~keeper_id:"keeper"
        ~expected_revision:seeded.revision
        ~expected_snapshot_sha256:seeded_hash
        ~now:300.0
        ~source:{ Current.kind = Current.Explicit_retract; trace_id = "legacy-removal-line" }
        [ { Current.memory_id = Types.memory_id target
          ; reason = "an older writer recorded this removal"
          } ]
    in
    (match request () with
     | Error (Current.Retract_batch_plan_evidence_pending _) -> ()
     | Error _ | Ok _ -> fail "journal failure did not leave a prepared plan");
    let receipt_path =
      Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper"
    in
    let receipt = Yojson.Safe.from_file receipt_path in
    Unix.rmdir journal_path;
    Fs_compat.save_file journal_path seed_journal;
    (* Recovery appends the exact line once; then the journal and the receipt
       are rewritten the way the older writer left them. *)
    (match request () with
     | Error (Current.Retract_batch_snapshot_conflict _) -> ()
     | Error _ | Ok _ -> fail "restart reconciliation did not precede stale CAS");
    let strip = function
      | `Assoc fields ->
        `Assoc (List.filter (fun (name, _) -> not (List.mem name missing_keys)) fields)
      | _ -> fail "fixture expected a JSON object"
    in
    let legacy_rows = List.map strip (read_journal_lines ~keepers_dir) in
    Fs_compat.invalidate_cached_writer journal_path;
    Fs_compat.save_file journal_path
      (String.concat "\n" (List.map Yojson.Safe.to_string legacy_rows) ^ "\n");
    Fs_compat.save_file_atomic_strict receipt_path
      (Yojson.Safe.to_string (strip receipt)) |> require_ok;
    (match request () with
     | Error (Current.Retract_batch_snapshot_conflict _) -> ()
     | Error _ | Ok _ -> fail "legacy receipt did not reconcile before stale CAS");
    check bool "legacy receipt is cleared" false (Sys.file_exists receipt_path);
    check int "legacy removal line is not appended again" (List.length legacy_rows)
      (List.length (read_journal_lines ~keepers_dir)))
    [ [ "revision_links" ]; [ "revision_links"; "commit_effect" ] ]
;;

let test_admission_recall_cache_invalidates_external_prefix_edit_and_growth () =
  List.iter (fun damage ->
    with_temp_keepers @@ fun keepers_dir ->
    let target = fact ~claim:"retained recall target" () in
    let binding = recall_binding 1 (fact ~claim:"source observation" ()) target in
    ignore (commit_recall ~keepers_dir binding [target] |> require_ok);
    ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
      ~source:(source Current.Explicit_write) (fact ~claim:"another current fact" ())
      |> require_upsert_ok);
    check bool "cold verification retains live binding" true
      (snd (read_recall ~keepers_dir |> require_ok)=[binding]);
    for _ = 1 to 20 do
      ignore (apply_disposition ~keepers_dir () |> require_ok);
      check bool "known unchanged append preserves verified binding" true
        (snd (read_recall ~keepers_dir |> require_ok)=[binding])
    done;
    let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let bytes = Fs_compat.load_file journal in
    (match damage with
     | `Malformed_append ->
       Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0o600 journal
         (fun oc -> output_string oc "not-json\n")
     | `Prefix_and_growth ->
       let rows = String.split_on_char '\n' bytes |> List.filter ((<>) "") in
       let edited = List.map (fun row ->
         let json = Yojson.Safe.from_string row in
         match json with
         | `Assoc fields when List.assoc_opt "revision" fields = Some (`Int 2) ->
           `Assoc (List.map (fun (name,value) ->
             name, if name="commit_effect" then `String "unchanged" else value) fields)
           |> Yojson.Safe.to_string
         | _ -> row) rows in
       (* Same inode plus growth is deliberately not trusted as an append. *)
       Out_channel.with_open_bin journal (fun oc ->
         output_string oc (String.concat "\n" (edited @ [List.hd (List.rev edited)]) ^ "\n")));
    (match read_recall ~keepers_dir with
     | Error _ -> () | Ok _ -> fail "external journal damage reused cached authority"))
    [`Malformed_append;`Prefix_and_growth]
;;

(* The receipt cache keeps a sidecar only once its ctime is more than one
   second old, so a test that expects a cached read waits longer than that
   after the last sidecar write. *)
let settle_receipt_sidecar () = Unix.sleepf 1.2

let receipt_decodes () = Current.For_testing.durable_range_receipt_decodes ()

let recall_bindings ~keepers_dir = snd (read_recall ~keepers_dir |> require_ok)

(* One bound admission, its sidecar settled, and the search that decodes and
   caches it. *)
let cached_recall_fixture ~keepers_dir =
  let target = fact ~claim:"cached receipt target" () in
  let binding = recall_binding 1 (fact ~claim:"cached receipt source" ()) target in
  ignore (commit_recall ~keepers_dir binding [target] |> require_ok);
  settle_receipt_sidecar ();
  check bool "settled search verifies the sidecar" true
    (recall_bindings ~keepers_dir = [binding]);
  target, binding
;;

let test_receipt_cache_skips_decoding_an_unchanged_sidecar () =
  with_temp_keepers @@ fun keepers_dir ->
  let _target, binding = cached_recall_fixture ~keepers_dir in
  let decoded = receipt_decodes () in
  for _ = 1 to 3 do
    check bool "repeated search keeps the binding" true
      (recall_bindings ~keepers_dir = [binding])
  done;
  check int "searches over an unchanged sidecar decode nothing" decoded (receipt_decodes ());
  ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
    ~source:(source Current.Explicit_write) (fact ~claim:"unrelated later fact" ())
    |> require_upsert_ok);
  check bool "a later snapshot revision keeps the binding" true
    (recall_bindings ~keepers_dir = [binding]);
  check int "a later revision that leaves the sidecar alone decodes nothing" decoded
    (receipt_decodes ())
;;

let test_receipt_cache_rereads_an_externally_rewritten_sidecar () =
  List.iter (fun (label, rewrite) ->
    with_temp_keepers @@ fun keepers_dir ->
    let _target, _binding = cached_recall_fixture ~keepers_dir in
    let path = Current.durable_range_receipt_path ~keepers_dir ~keeper_id:"keeper" in
    let decoded = receipt_decodes () in
    rewrite ~keepers_dir path;
    check int (label ^ ": search reports the rewritten sidecar") 0
      (List.length (recall_bindings ~keepers_dir));
    check bool (label ^ ": the rewritten sidecar was decoded") true
      (receipt_decodes () > decoded))
    [ "same inode and size", (fun ~keepers_dir path ->
        let before = Unix.lstat path in
        (* Same revision, other snapshot bytes: reconcile must drop the binding. *)
        rewrite_receipts ~keepers_dir (map_receipts (map_field "snapshot_sha256"
          (fun _ -> `String (String.make 64 'f'))));
        let after = Unix.lstat path in
        check int "rewrite keeps the inode" before.Unix.st_ino after.Unix.st_ino;
        check int "rewrite keeps the size" before.Unix.st_size after.Unix.st_size)
    ; "different size", (fun ~keepers_dir:_ path ->
        Fs_compat.save_file path {|{"receipts":[]}|}) ]
;;

let test_receipt_cache_reflects_this_process_receipt_write () =
  with_temp_keepers @@ fun keepers_dir ->
  let target, binding = cached_recall_fixture ~keepers_dir in
  let second = recall_binding 2 (fact ~claim:"second cached receipt source" ()) target in
  let decoded = receipt_decodes () in
  let admitted = commit_recall ~keepers_dir second [] |> require_ok in
  (* The snapshot keeps its revision and bytes; only the sidecar changes. *)
  check bool "binding-only admission keeps the snapshot" true
    (admitted.commit = Current.Unchanged);
  let found = recall_bindings ~keepers_dir in
  check bool "search reports both bindings" true
    (List.length found = 2 && List.mem binding found && List.mem second found);
  check bool "the rewritten sidecar was decoded" true (receipt_decodes () > decoded)
;;

let test_stale_replace_rejects_concurrent_explicit_write () =
  with_temp_keepers @@ fun keepers_dir ->
  let initial = fact ~claim:"initial" () in
  let explicit = fact ~claim:"explicit" () in
  ignore (replace ~keepers_dir ~facts:[ initial ] () |> require_ok);
  ignore
    (Current.upsert_fact
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:250.0
       ~source:(source Current.Explicit_write)
       explicit
     |> require_upsert_ok);
  (match
     replace
       ~keepers_dir
       ~expected_revision:(Some 1)
       ~facts:[ initial ]
       ()
   with
   | Error message ->
     check
       bool
       "stale revision rejected"
       true
       (String.starts_with
          ~prefix:"current Memory OS revision conflict"
          message)
   | Ok _ -> fail "stale librarian replacement overwrote a concurrent write");
  let snapshot =
    Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
    |> require_ok
    |> require_some
  in
  check int "concurrent revision preserved" 2 snapshot.revision;
  check
    (list string)
    "explicit fact preserved"
    (fact_ids [ initial; explicit ])
    (fact_ids snapshot.facts)
;;

(* Byte-identical re-observation is not duplication and not a score: the row
   count stays flat, insertion time stays authoritative, the observation time
   refreshes, and an injected copy re-observing an authored row must not
   repaint its origin (task-1032 loop damper, RFC-0418). *)
let test_reobservation_refreshes_instead_of_duplicating () =
  with_temp_keepers @@ fun keepers_dir ->
  let initial = fact ~claim:"reinforced claim" () in
  ignore (replace ~keepers_dir ~facts:[ initial ] () |> require_ok);
  let reinjected =
    { initial with
      category = Types.Lesson
    ; first_seen = 500.0
    ; last_seen = 600.0
    ; origin = { kind = Types.Injected; trace_id = "" }
    }
  in
  let snapshot =
    Current.upsert_fact
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:600.0
      ~source:(source Current.Librarian)
      reinjected
    |> require_upsert_ok
  in
  check int "one row, not a duplicate" 1 (List.length snapshot.facts);
  let stored = List.hd snapshot.facts in
  check (float 0.0) "insertion time remains authoritative" 100.0 stored.first_seen;
  check (float 0.0) "observation time refreshed" 600.0 stored.last_seen;
  check bool "original origin preserved" true (stored.origin.kind = Types.Authored);
  check bool "category still updates" true (stored.category = Types.Lesson)
;;

(* ---------- A rejection has to name the row and the field ----------

   These assert the rendered text, because the text is the whole deliverable.
   The 2026-09-01 recovery (#32239) had a snapshot the runtime refused and one
   message for all of it, so finding out which of three contract changes had
   fired meant re-implementing this decoder by hand and bisecting. Each case
   below is one of the rejections that actually happened, plus the three
   nearest neighbours. *)

let object_fields = function
  | `Assoc fields -> fields
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ ->
    fail "expected a JSON object"
;;

let field_value name fields =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> fail (Printf.sprintf "expected field %S" name)
;;

let with_field name value fields =
  List.map
    (fun (field, existing) ->
       if String.equal field name then field, value else field, existing)
    fields
;;

let without_field name fields =
  List.filter (fun (field, _) -> not (String.equal field name)) fields
;;

let overwrite_snapshot ~keepers_dir json =
  Fs_compat.save_file
    (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper")
    (Yojson.Safe.to_string json)
;;

let reject_names ~keepers_dir ~what needles =
  match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
  | Ok _ -> fail (Printf.sprintf "%s crossed the authoritative read boundary" what)
  | Error message ->
    List.iter
      (fun needle ->
         check
           bool
           (Printf.sprintf "%s names %S; message was: %s" what needle message)
           true
           (String_util.contains_substring message needle))
      needles
;;

(* One field written by a later contract turns every earlier snapshot into a
   single unexplained refusal. This is the change that took the live fleet
   down. *)
let test_rejection_names_a_missing_change_field () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let fields = object_fields (Current.to_json written) in
  let change = object_fields (field_value "change" fields) in
  overwrite_snapshot
    ~keepers_dir
    (`Assoc (with_field "change" (`Assoc (without_field "invalidated" change)) fields));
  reject_names
    ~keepers_dir
    ~what:"a change object without invalidated"
    [ "change: field set mismatch"; "missing: invalidated" ]
;;

(* A provenance token this build does not know, on one row out of many. *)
let test_rejection_names_the_row_and_field_of_an_unknown_token () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let fields = object_fields (Current.to_json written) in
  let rows =
    match field_value "facts" fields with
    | `List rows -> rows
    | _ -> fail "facts is not an array"
  in
  let repainted =
    List.map
      (fun row ->
         let row_fields = object_fields row in
         let origin = object_fields (field_value "origin" row_fields) in
         `Assoc
           (with_field
              "origin"
              (`Assoc (with_field "kind" (`String "legacy") origin))
              row_fields))
      rows
  in
  overwrite_snapshot ~keepers_dir (`Assoc (with_field "facts" (`List repainted) fields));
  reject_names
    ~keepers_dir
    ~what:"a row whose origin kind is legacy"
    [ "facts[0].origin.kind"; "does not know the token \"legacy\"" ]
;;

(* The delta lost its added rows, so the row count no longer adds up. *)
let test_rejection_names_the_retained_arithmetic () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let fields = object_fields (Current.to_json written) in
  let change = object_fields (field_value "change" fields) in
  overwrite_snapshot
    ~keepers_dir
    (`Assoc (with_field "change" (`Assoc (with_field "added" (`List []) change)) fields));
  reject_names
    ~keepers_dir
    ~what:"a delta that lost its added rows"
    [ "change.retained: 0 retained plus 0 added does not equal 1 facts" ]
;;

(* Same identity, different payload: the delta describes a row the snapshot no
   longer holds. *)
let test_rejection_names_an_added_row_that_is_not_current () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let fields = object_fields (Current.to_json written) in
  let change = object_fields (field_value "change" fields) in
  let staled =
    match field_value "added" change with
    | `List rows ->
      `List
        (List.map
           (fun row -> `Assoc (with_field "last_seen" (`Float 999.0) (object_fields row)))
           rows)
    | _ -> fail "change.added is not an array"
  in
  overwrite_snapshot
    ~keepers_dir
    (`Assoc (with_field "change" (`Assoc (with_field "added" staled change)) fields));
  reject_names
    ~keepers_dir
    ~what:"an added row that is not the current payload"
    [ "change.added:"; "is not the row facts currently holds" ]
;;

let test_rejection_names_the_index_of_a_duplicate_row () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact ~claim:"twice" () ] () |> require_ok in
  let fields = object_fields (Current.to_json written) in
  let row =
    match field_value "facts" fields with
    | `List [ row ] -> row
    | _ -> fail "expected exactly one stored row"
  in
  overwrite_snapshot
    ~keepers_dir
    (`Assoc (with_field "facts" (`List [ row; row ]) fields));
  reject_names
    ~keepers_dir
    ~what:"the same row stored twice"
    [ "facts[1]"; "appears more than once" ]
;;

let test_rejection_names_a_blank_source_trace_id () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let fields = object_fields (Current.to_json written) in
  let source_fields = object_fields (field_value "source" fields) in
  overwrite_snapshot
    ~keepers_dir
    (`Assoc
       (with_field
          "source"
          (`Assoc (with_field "trace_id" (`String "   ") source_fields))
          fields));
  reject_names
    ~keepers_dir
    ~what:"a source with a blank trace id"
    [ "source.trace_id: expected a non-blank string" ]
;;

let test_rejection_names_an_unexpected_top_level_field () =
  with_temp_keepers @@ fun keepers_dir ->
  let written = replace ~keepers_dir ~facts:[ fact () ] () |> require_ok in
  let fields = object_fields (Current.to_json written) in
  overwrite_snapshot ~keepers_dir (`Assoc (("legacy_facts", `List []) :: fields));
  reject_names
    ~keepers_dir
    ~what:"a snapshot carrying an unknown top-level field"
    [ "<root>: field set mismatch"; "unexpected: legacy_facts" ]
;;

(* ---------- An undecodable snapshot must not be a permanent wedge ----------

   Every writer reads before it writes, so refusing to write over a snapshot
   this build cannot decode left the keeper's memory both unreadable and
   unwritable: eight live keepers stayed that way through every restart on
   2026-09-01 until the files were repaired by hand. *)

let break_change_contract ~keepers_dir =
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let broken =
    match Yojson.Safe.from_string (Fs_compat.load_file path) with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (field, value) ->
              match field, value with
              | "change", `Assoc nested ->
                ( field
                , `Assoc
                    (List.filter
                       (fun (name, _) -> not (String.equal name "invalidated"))
                       nested) )
              | _ -> field, value)
           fields)
    | json -> json
  in
  let content = Yojson.Safe.to_string broken in
  Fs_compat.save_file path content;
  content
;;

(* An inline record cannot leave its constructor, so the two fields under test
   are projected here rather than returned whole. *)
let quarantined_lines ~keepers_dir =
  Current.read_journal_tail ~keepers_dir ~keeper_id:"keeper" ~limit:100
  |> List.filter_map (function
    | Ok (Current.Journal_quarantined { recorded_at = _; rejection; rejected_path }) ->
      Some (rejection, rejected_path)
    | Ok (Current.Journal_committed _ | Current.Journal_failed _) | Error _ -> None)
;;

let test_undecodable_snapshot_is_quarantined_and_the_write_proceeds () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact ~claim:"original" () ] () |> require_ok);
  let rejected_content = break_change_contract ~keepers_dir in
  check
    bool
    "a broken snapshot is unreadable before the write"
    true
    (Result.is_error (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"));
  let recovered =
    Current.upsert_fact
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:600.0
      ~source:(source Current.Explicit_write)
      (fact ~claim:"written after the wedge" ())
    |> require_upsert_ok
  in
  check int "the write restarts the revision" 1 recovered.revision;
  check
    (list string)
    "only the new row is current"
    [ "written after the wedge" ]
    (List.map (fun (f : Types.fact) -> f.claim) recovered.facts);
  (match rejected_files ~keepers_dir with
   | [ name ] ->
     check
       string
       "the rejected bytes are kept exactly as they were"
       rejected_content
       (Fs_compat.load_file (Filename.concat keepers_dir name))
   | files ->
     fail
       (Printf.sprintf
          "expected exactly one moved-aside snapshot, got [%s]"
          (String.concat "; " files)));
  match quarantined_lines ~keepers_dir with
  | [ (rejection, rejected_path) ] ->
    check
      bool
      (Printf.sprintf "the journal says what was refused: %s" rejection)
      true
      (String_util.contains_substring rejection "change: field set mismatch"
       && String_util.contains_substring rejection "missing: invalidated");
    check
      bool
      "the journal names where the bytes went"
      true
      (String_util.contains_substring rejected_path ".rejected-")
  | lines ->
    fail
      (Printf.sprintf "expected exactly one quarantine line, got %d" (List.length lines))
;;

(* Reading is an observation. A read that moved files would make every
   dashboard poll a write. *)
let test_reading_an_undecodable_snapshot_moves_nothing () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
  let rejected_content = break_change_contract ~keepers_dir in
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
   | Error _ -> ()
   | Ok _ -> fail "a broken snapshot crossed the authoritative read boundary");
  check (list string) "nothing was moved aside" [] (rejected_files ~keepers_dir);
  check
    string
    "the snapshot is still where it was"
    rejected_content
    (Fs_compat.load_file (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"));
  check int "and nothing was journaled" 0 (List.length (quarantined_lines ~keepers_dir))
;;

(* A caller holding a revision cannot have read it from a file that does not
   decode, so the concurrency contract still refuses. The quarantine happens
   first and stands: the next write succeeds. *)
let test_expected_revision_still_refuses_after_a_quarantine () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
  ignore (break_change_contract ~keepers_dir);
  (match
     replace ~keepers_dir ~expected_revision:(Some 1) ~facts:[ fact ~claim:"next" () ] ()
   with
   | Error _ -> ()
   | Ok _ -> fail "a stale expected revision was accepted after a quarantine");
  check
    int
    "the quarantine stands even though the write refused"
    1
    (List.length (rejected_files ~keepers_dir));
  let fresh =
    replace ~keepers_dir ~facts:[ fact ~claim:"fresh" () ] () |> require_ok
  in
  check int "the following write proceeds from fresh state" 1 fresh.revision
;;

let test_torn_json_is_quarantined_too () =
  with_temp_keepers @@ fun keepers_dir ->
  ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
  Fs_compat.save_file
    (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper")
    "{\"revision\": 1, \"facts\": [";
  let recovered =
    Current.upsert_fact
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:700.0
      ~source:(source Current.Explicit_write)
      (fact ~claim:"after a torn file" ())
    |> require_upsert_ok
  in
  check int "a half-written file does not wedge the keeper either" 1 recovered.revision;
  check int "and it is kept" 1 (List.length (rejected_files ~keepers_dir))
;;

(* rename replaces its destination, and [now] repeats: it is the caller's own
   observation time, so two writes in the same second carry the same value. A
   fixed name would therefore delete the snapshot an earlier quarantine kept. *)
let test_two_quarantines_at_the_same_time_keep_both_files () =
  with_temp_keepers @@ fun keepers_dir ->
  (* Both rounds write through upsert, which carries no revision expectation,
     so the fixture is about the rejected paths and nothing else. Both
     quarantines are handed the same [now], which is the collision. *)
  let write ~now ~claim =
    ignore
      (Current.upsert_fact
         ~keepers_dir
         ~keeper_id:"keeper"
         ~now
         ~source:(source Current.Explicit_write)
         (fact ~claim ())
       |> require_upsert_ok)
  in
  let quarantine_once ~claim =
    write ~now:500.0 ~claim;
    let broken = break_change_contract ~keepers_dir in
    write ~now:600.0 ~claim:(claim ^ " recovered");
    broken
  in
  let first = quarantine_once ~claim:"first" in
  let second = quarantine_once ~claim:"second" in
  check
    bool
    "the two rejected snapshots differ, so overwriting one would lose bytes"
    true
    (not (String.equal first second));
  match rejected_files ~keepers_dir with
  | [ older; newer ] ->
    let kept name = Fs_compat.load_file (Filename.concat keepers_dir name) in
    check
      (list string)
      "both rejected snapshots are still on disk"
      (List.sort String.compare [ first; second ])
      (List.sort String.compare [ kept older; kept newer ])
  | files ->
    fail
      (Printf.sprintf
         "expected both quarantines to be kept, got [%s]"
         (String.concat "; " files))
;;

(* Provenance rides the basis: an observed fact says where it was read.
   The wire keeps {"kind":"observed"} for transcript facts, so every existing
   snapshot still decodes, and adds a board object only when a Board post is
   named. The ids are checked against the Board id grammar, not for existence:
   whether the post still exists is a reader's question. *)
let test_board_provenance_survives_the_wire () =
  let round_trip fact =
    match Types.fact_of_json (Types.fact_to_json fact) with
    | Ok decoded -> decoded
    | Error error -> failf "fact did not decode: %s" (Types.wire_error_to_string error)
  in
  let transcript = fact () in
  check
    bool
    "transcript basis serializes as the bare observed object"
    true
    (Types.basis_to_json transcript.basis
     = `Assoc [ Types.wire_field_kind, `String "observed" ]);
  check bool "transcript round trip" true ((round_trip transcript).basis = transcript.basis);
  let post = board_fact "p-0123456789abcdef0123456789abcdef" in
  check bool "post round trip" true ((round_trip post).basis = post.basis);
  let comment =
    board_fact ~comment_id:"c-0123456789abcdef0123456789abcdef" "p-0123456789abcdef0123456789abcdef"
  in
  check bool "comment round trip" true ((round_trip comment).basis = comment.basis);
  check
    bool
    "memory identity is the claim bytes, not the provenance"
    true
    (String.equal (Types.memory_id post) (Types.memory_id (fact ~claim:"board claim" ())))
;;

let test_board_provenance_rejects_bad_ids () =
  let rejects label json =
    match Types.basis_of_json json with
    | Ok _ -> failf "%s: decoded a basis the Board would not accept" label
    | Error _ -> ()
  in
  rejects
    "blank post id"
    (`Assoc
       [ Types.wire_field_kind, `String "observed"
       ; Types.wire_field_board, `Assoc [ Types.wire_field_post_id, `String "" ]
       ]);
  rejects
    "post id with a space"
    (`Assoc
       [ Types.wire_field_kind, `String "observed"
       ; Types.wire_field_board, `Assoc [ Types.wire_field_post_id, `String "p-1 2" ]
       ]);
  rejects
    "unknown field inside the board object"
    (`Assoc
       [ Types.wire_field_kind, `String "observed"
       ; ( Types.wire_field_board
         , `Assoc
             [ Types.wire_field_post_id, `String "p-0123456789abcdef0123456789abcdef"
             ; "author", `String "alder"
             ] )
       ]);
  rejects
    "board object on a derived basis"
    (`Assoc
       [ Types.wire_field_kind, `String "derived"
       ; Types.wire_field_board, `Assoc [ Types.wire_field_post_id, `String "p-1" ]
       ]);
  match
    Types.board_ref_of_ids
      ~post_id:"p-0123456789abcdef0123456789abcdef"
      ~comment_id:(Some "not a comment id")
  with
  | Ok _ -> fail "a comment id the Board would not accept was decoded"
  | Error _ -> ()
;;

let test_board_reference_outranks_transcript_on_merge () =
  let post = "p-0123456789abcdef0123456789abcdef" in
  let transcript = (fact ()).basis in
  let board = (board_fact post).basis in
  check bool "transcript then board keeps the board" true
    (Current.merge_basis transcript board = board);
  check bool "board then transcript keeps the board" true
    (Current.merge_basis board transcript = board);
  let other = (board_fact "p-fedcba9876543210fedcba9876543210").basis in
  check bool "two board references to different posts keep the first" true
    (Current.merge_basis board other = board);
  let comment =
    (board_fact ~comment_id:"c-0123456789abcdef0123456789abcdef" post).basis
  in
  check bool "a comment under the same post replaces the bare post" true
    (Current.merge_basis board comment = comment);
  check bool "a bare post does not replace a comment under it" true
    (Current.merge_basis comment board = comment);
  check bool "an observation outranks a derivation" true
    (Current.merge_basis
       board
       (Types.Derived [ { rule_id = "r"; premise_ids = [ Types.memory_id (fact ()) ] } ])
     = board)
;;


(* The live shape of masc #32859. A librarian pass reads the snapshot, spends a
   provider round trip deciding what to keep, and writes. The keeper it belongs
   to records one fact of its own in that window. Both are the same keeper's
   work and neither contradicts the other: the librarian's disposition never
   mentions the new fact, because the librarian never saw it.

   Measured on the fleet before this test existed: 758 librarian passes ended
   this way, 590 of them in one week, and every one threw away a completed
   provider turn. No test contended the lock at all. *)
let test_a_keeper_write_during_a_librarian_pass_keeps_both () =
  with_temp_keepers (fun keepers_dir ->
    let curated = fact ~claim:"the librarian read this one" () in
    let base =
      replace ~keepers_dir ~facts:[ curated ] () |> require_ok
    in
    (* The librarian is now thinking, holding [base.revision]. *)
    let librarian_read_revision = base.revision in
    (* The keeper records something of its own meanwhile. *)
    let authored = fact ~claim:"the keeper wrote this meanwhile" () in
    let after_keeper =
      Current.upsert_fact
        ~keepers_dir
        ~keeper_id:"keeper"
        ~now:250.0
        ~source:(source Current.Explicit_write)
        authored
      |> function
      | Ok snapshot -> snapshot
      | Error _ -> fail "the keeper's own write must not fail"
    in
    check int "the keeper's write advanced the revision"
      (librarian_read_revision + 1)
      after_keeper.revision;
    (* The old write demanded the revision it read. It fails closed, which is
       correct for a whole-set write and is why the pass was lost. *)
    (match
       replace
         ~keepers_dir
         ~expected_revision:(Some librarian_read_revision)
         ~facts:[ curated ]
         ()
     with
     | Ok _ -> fail "a whole-set write must not overwrite a moved revision"
     | Error detail ->
       check bool "and it says why" true
         (String_util.contains_substring detail "revision conflict"));
    (* The decision itself carries no such demand: retire nothing, and say
       nothing about the fact it never saw. *)
    let committed = apply_disposition ~keepers_dir () |> require_ok in
    check (list string)
      "both the curated fact and the one written during the pass survive"
      (List.sort compare (fact_ids [ curated; authored ]))
      (List.sort compare (fact_ids committed.facts)))
;;

let test_commit_notifications_follow_all_writers_outside_locks () =
  let module Notifications = Masc.Keeper_memory_commit_notifications in
  with_temp_keepers @@ fun keepers_dir ->
  let physical_keepers_dir = Unix.realpath keepers_dir in
  let observed = ref [] in
  let unsubscribe = Notifications.subscribe (fun (event : Notifications.event) ->
    if String.equal event.keepers_dir physical_keepers_dir then (
      (* Reacquiring both locks would deadlock if a writer dispatched in its
         transaction. Reading here also checks that the notification follows
         the authoritative snapshot, not a proposed or journal-only change. *)
      let snapshot =
        Masc.Keeper_memory_os_aggregate_lock.with_lock
          ~keepers_dir ~keeper_id:event.keeper_id (fun () ->
            File_lock_eio.with_lock
              (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:event.keeper_id)
              (fun () -> Current.read_for_keepers_dir ~keepers_dir ~keeper_id:event.keeper_id))
      in
      (* Registry mutation is also safe inside a dispatched callback. *)
      let stop = Notifications.subscribe (fun _ -> ()) in
      stop ();
      observed := (event, snapshot) :: !observed))
  in
  let stop_failure = Notifications.subscribe (fun event ->
    if String.equal event.Notifications.keepers_dir physical_keepers_dir then
      raise (Failure "subscriber failure fixture"))
  in
  Fun.protect ~finally:(fun () -> unsubscribe (); stop_failure ()) (fun () ->
    let first = fact ~claim:"first committed claim" () in
    let second = fact ~claim:"second committed claim" () in
    ignore (replace ~keepers_dir ~facts:[ first ] () |> require_ok);
    (match replace ~keepers_dir ~expected_revision:(Some 0) () with
     | Error _ -> () | Ok _ -> fail "revision conflict should fail");
    ignore (apply_disposition ~keepers_dir ~new_claims:[ second ] () |> require_ok);
    ignore (Current.upsert_fact ~keepers_dir ~keeper_id:"keeper" ~now:300.
      ~source:(source Current.Explicit_write) first |> require_upsert_ok);
    (match Current.retract_fact ~keepers_dir ~keeper_id:"keeper" ~now:400.
      ~source:(source Current.Explicit_retract) ~memory_id:(Types.memory_id first)
      ~reason:"explicitly withdrawn" () with
     | Ok _ -> () | Error _ -> fail "retraction should commit");
    check int "all four central writers notify once; failure does not" 4 (List.length !observed);
    List.rev !observed |> List.iteri (fun index (event, snapshot) ->
      check int "committed revision" (index + 1) event.Notifications.revision;
      check bool "ordinary store" true (event.store = Notifications.Ordinary);
      match snapshot with
      | Ok (Some snapshot) -> check int "already readable" event.revision snapshot.Current.revision
      | Ok None | Error _ -> fail "notified snapshot was not readable");
    unsubscribe ();
    unsubscribe ();
    ignore (replace ~keepers_dir ~expected_revision:(Some 4) () |> require_ok);
    check int "unsubscribed listener stays detached" 4 (List.length !observed))
;;

let test_commit_notifications_do_not_depend_on_journal () =
  let module Notifications = Masc.Keeper_memory_commit_notifications in
  with_temp_keepers @@ fun keepers_dir ->
  let physical_keepers_dir = Unix.realpath keepers_dir in
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  Unix.mkdir journal 0o700;
  let observed = ref [] in
  let stop = Notifications.subscribe (fun event ->
    if String.equal event.Notifications.keepers_dir physical_keepers_dir then
      observed := event.revision :: !observed)
  in
  Fun.protect ~finally:stop (fun () ->
    ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
    check (list int) "snapshot commit notifies despite failed journal append" [ 1 ] !observed;
    (* A different keeper's unreadable snapshot fails before it can commit. *)
    let blocked = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"blocked" in
    Unix.mkdir blocked 0o700;
    (try
       match Current.upsert_fact ~keepers_dir ~keeper_id:"blocked" ~now:200.
         ~source:(source Current.Explicit_write) (fact ()) with
       | Error _ -> () | Ok _ -> fail "unreadable store unexpectedly committed"
     with Sys_error _ | Unix.Unix_error _ -> ());
    check (list int) "storage failure emits no commit" [ 1 ] !observed)
;;

let test_commit_notification_directory_is_physical () =
  let module Notifications = Masc.Keeper_memory_commit_notifications in
  with_temp_keepers @@ fun keepers_dir ->
  let alias = Filename.concat keepers_dir "directory-alias" in
  Unix.symlink keepers_dir alias;
  let directories = ref [] in
  let stop = Notifications.subscribe (fun event ->
    if String.equal event.Notifications.keeper_id "alias-keeper" then
      directories := event.keepers_dir :: !directories)
  in
  Fun.protect ~finally:(fun () -> stop (); Sys.remove alias) (fun () ->
    ignore (Current.upsert_fact ~keepers_dir:alias ~keeper_id:"alias-keeper" ~now:200.
      ~source:(source Current.Explicit_write) (fact ()) |> require_upsert_ok);
    check (list string) "directory alias resolves before notification"
      [ Unix.realpath keepers_dir ] !directories)
;;

let test_commit_notification_preserves_cancellation () =
  let module Notifications = Masc.Keeper_memory_commit_notifications in
  with_temp_keepers @@ fun keepers_dir ->
  let physical_keepers_dir = Unix.realpath keepers_dir in
  let observed = ref [] in
  let stop_observer = Notifications.subscribe (fun event ->
    if String.equal event.Notifications.keepers_dir physical_keepers_dir then
      observed := event.revision :: !observed)
  in
  let cancellation = Eio.Cancel.Cancelled (Failure "subscriber cancellation fixture") in
  (* Most recently registered listener runs first, exercising cancellation
     before the observer that must still learn of the committed snapshot. *)
  let stop_cancel = Notifications.subscribe (fun event ->
    if String.equal event.Notifications.keepers_dir physical_keepers_dir then
      raise cancellation)
  in
  Fun.protect ~finally:(fun () -> stop_observer (); stop_cancel ()) (fun () ->
    (try
       ignore (replace ~keepers_dir ~facts:[ fact () ] ());
       fail "subscriber cancellation was swallowed"
     with Eio.Cancel.Cancelled _ as exn ->
       check bool "same cancellation propagated" true (exn == cancellation));
    check (list int) "other subscriber still sees the real commit" [ 1 ] !observed;
    let snapshot = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
      |> require_ok |> require_some in
    check int "cancelled notification does not revoke snapshot" 1 snapshot.revision)
;;

(* A commit reads the snapshot, parses it, prints the next one and replaces the
   file. The parse and the print run on the domain pool: on the scheduler
   domain they were one 11-24 ms run per commit for files of 150-330 KB (rtev,
   2026-09-16). With the pool's only worker busy, a commit waits for it. *)
let busy_worker_polls = 50
let busy_worker_poll_interval_s = 0.01

let test_a_commit_parses_and_prints_on_the_pool () =
  with_temp_keepers
  @@ fun keepers_dir ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  (* A snapshot to read back: the parse only runs when the file is there. *)
  ignore (require_ok (replace ~keepers_dir ~facts:[ fact ~claim:"first" () ] ()));
  let previous_pool = Domain_pool_ref.get () in
  Fun.protect
    ~finally:(fun () ->
      match previous_pool with
      | None -> Domain_pool_ref.clear_for_tests ()
      | Some previous -> Domain_pool_ref.set previous)
  @@ fun () ->
  Domain_pool_ref.set (Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env));
  let occupied, occupied_u = Eio.Promise.create () in
  let release, release_u = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Domain_pool_ref.submit_cpu_or_inline (fun () ->
      Eio.Promise.resolve occupied_u ();
      Eio.Promise.await release));
  Eio.Promise.await occupied;
  let committed = ref None in
  let clock = Eio.Stdenv.clock env in
  Eio.Fiber.both
    (fun () ->
      committed
      := Some
           (replace
              ~keepers_dir
              ~expected_revision:(Some 1)
              ~facts:[ fact ~claim:"second" () ]
              ()))
    (fun () ->
      let rec wait polls =
        if polls > 0 && Option.is_none !committed
        then (
          Eio.Time.sleep clock busy_worker_poll_interval_s;
          wait (polls - 1))
      in
      wait busy_worker_polls;
      check bool "the commit waits for the busy worker" true (Option.is_none !committed);
      Eio.Promise.resolve release_u ());
  match !committed with
  | None -> fail "the commit never finished"
  | Some result ->
    let snapshot = require_ok result in
    check int "and then it is committed" 2 snapshot.Current.revision
;;

module Absorbed = Masc.Keeper_memory_absorbed

let absorbed_records ~keepers_dir =
  match Absorbed.read ~keepers_dir ~keeper_id:"keeper" with
  | Error message -> failf "absorbed store: %s" message
  | Ok lines ->
    List.map
      (fun (line, result) ->
         match result with
         | Ok record -> record
         | Error error ->
           failf "absorbed line %d: %s" line (Absorbed.read_error_to_string error))
      lines
;;

let seed_three ~keepers_dir =
  let a = fact ~claim:"A" () in
  let b = fact ~claim:"B" () in
  let c = fact ~claim:"C" () in
  let (_ : Current.t) = replace ~keepers_dir ~facts:[ a; b; c ] () |> require_ok in
  a, b, c
;;

(* RFC-0456 §4.2: a fact a new claim absorbs leaves the snapshot and its row is
   kept beside it, naming the claim that now says it and the pass that did. *)
let test_absorbed_facts_leave_the_snapshot_with_their_rows_kept () =
  with_temp_keepers @@ fun keepers_dir ->
  let a, b, c = seed_three ~keepers_dir in
  let together = fact ~claim:"A and B" () in
  let into = Types.memory_id together in
  let committed =
    apply_disposition
      ~keepers_dir
      ~absorbed:
        [ { Types.absorbed = Types.memory_id a; into }
        ; { Types.absorbed = Types.memory_id b; into }
        ]
      ~new_claims:[ together ]
      ()
    |> require_ok
  in
  check (list string) "C stays and the new claim joins"
    (List.sort compare (fact_ids [ c; together ]))
    (List.sort compare (fact_ids committed.facts));
  let records = absorbed_records ~keepers_dir in
  check (list string) "one row per absorbed fact, as the snapshot held it"
    [ "A"; "B" ]
    (List.map (fun (r : Absorbed.record) -> r.fact.claim) records);
  List.iter
    (fun (r : Absorbed.record) ->
       check string "into the new claim" into r.into;
       check string "the row's id is its fact's" (Types.memory_id r.fact) r.memory_id;
       check string "the pass's trace" "trace" r.trace_id;
       check (float 0.) "the pass's clock" 200.0 r.recorded_at)
    records
;;

(* The row is the only copy once the snapshot moves on, so a row that cannot be
   written keeps the fact where it was. *)
let test_a_failed_absorbed_write_commits_nothing () =
  with_temp_keepers @@ fun keepers_dir ->
  let a, b, c = seed_three ~keepers_dir in
  Unix.mkdir (Absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper") 0o700;
  let together = fact ~claim:"A and B" () in
  (match
     apply_disposition
       ~keepers_dir
       ~absorbed:[ { Types.absorbed = Types.memory_id a; into = Types.memory_id together } ]
       ~new_claims:[ together ]
       ()
   with
   | Ok _ -> fail "a pass whose absorbed rows cannot be written committed"
   | Error _ -> ());
  let current =
    apply_disposition ~keepers_dir () |> require_ok
  in
  check (list string) "the snapshot still holds A, B and C and not the new claim"
    (List.sort compare (fact_ids [ a; b; c ]))
    (List.sort compare (fact_ids current.facts))
;;

(* A crash during an append leaves a last line with no newline. A read reports
   it as the line it is; the pass's append cuts it back to the last complete
   row and the same pass commits. *)
let test_an_absorbing_pass_recovers_a_store_that_ends_mid_line () =
  with_temp_keepers @@ fun keepers_dir ->
  let a, b, c = seed_three ~keepers_dir in
  let path = Absorbed.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let channel = open_out_gen [ Open_wronly; Open_creat; Open_trunc ] 0o600 path in
  output_string channel "{\"recorded_at\": 1";
  close_out channel;
  let together = fact ~claim:"A and B" () in
  let current =
    apply_disposition
      ~keepers_dir
      ~absorbed:[ { Types.absorbed = Types.memory_id a; into = Types.memory_id together } ]
      ~new_claims:[ together ]
      ()
    |> require_ok
  in
  check (list string) "the snapshot holds A and B absorbed into the new claim, plus C"
    (List.sort compare (fact_ids [ b; c; together ]))
    (List.sort compare (fact_ids current.facts));
  match Absorbed.read ~keepers_dir ~keeper_id:"keeper" with
  | Error message -> failf "absorbed store: %s" message
  | Ok [ (1, Ok _) ] -> ()
  | Ok lines -> failf "expected the single recovered row, read %d lines" (List.length lines)
;;

let test_an_absorbed_fact_no_longer_current_writes_no_row () =
  with_temp_keepers @@ fun keepers_dir ->
  let _a, _b, _c = seed_three ~keepers_dir in
  let gone = fact ~claim:"retracted during the pass" () in
  let together = fact ~claim:"something new" () in
  let (_ : Current.t) =
    apply_disposition
      ~keepers_dir
      ~absorbed:[ { Types.absorbed = Types.memory_id gone; into = Types.memory_id together } ]
      ~new_claims:[ together ]
      ()
    |> require_ok
  in
  check int "no row for a fact the snapshot no longer holds" 0
    (List.length (absorbed_records ~keepers_dir))
;;

let test_absorbed_record_codec () =
  let absorbed_fact = fact ~claim:"A" () in
  let into = Types.memory_id (fact ~claim:"A and B" ()) in
  let record : Absorbed.record =
    { recorded_at = 200.0
    ; trace_id = "trace"
    ; memory_id = Types.memory_id absorbed_fact
    ; into
    ; fact = absorbed_fact
    }
  in
  (match Absorbed.record_of_json (Absorbed.record_to_json record) with
   | Ok decoded -> check bool "round trip" true (decoded = record)
   | Error error -> failf "round trip rejected: %s" (Types.wire_error_to_string error));
  let rejects label json =
    match Absorbed.record_of_json json with
    | Ok _ -> failf "%s: accepted" label
    | Error _ -> ()
  in
  let with_field name value =
    match Absorbed.record_to_json record with
    | `Assoc fields -> `Assoc (List.map (fun (k, v) -> if String.equal k name then k, value else k, v) fields)
    | _ -> fail "record_to_json is an object"
  in
  (* Neither [into] nor the fact's identity, so only the identity check can
     reject it. *)
  let unrelated = Types.memory_id (fact ~claim:"unrelated" ()) in
  rejects "an id that is not its fact's" (with_field "memory_id" (`String unrelated));
  rejects "a fact absorbed into itself" (with_field "into" (`String record.memory_id));
  rejects "an extra field"
    (match Absorbed.record_to_json record with
     | `Assoc fields -> `Assoc (("extra", `Null) :: fields)
     | _ -> fail "record_to_json is an object")
;;

let test_dynamic_category_roundtrip () =
  let category = match Types.category_of_string "architecture_decision" with
    | Some category -> category
    | None -> fail "new category rejected" in
  with_temp_keepers @@ fun keepers_dir ->
  let row = { (fact ()) with category } in
  (match replace ~keepers_dir ~facts:[row] () with
   | Ok _ -> () | Error detail -> fail detail);
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
   | Ok (Some {Current.facts = [stored]; _}) ->
     check string "persisted category retains its name" "architecture_decision"
       (Types.category_to_string stored.category);
     check string "category does not alter memory identity"
       (Types.memory_id (fact ())) (Types.memory_id stored)
   | Ok _ -> fail "stored fact missing"
   | Error detail -> fail detail);
  List.iter (fun raw ->
    check bool ("malformed category rejected: " ^ raw) true
      (Types.category_of_string raw = None))
    [""; "_topic"; "topic_"; "two__words"; "topic-name"; "topic\n"; "1topic"; "Topic";
     "all"; "source"; "dropped"]
;;

let () =
  run
    "keeper_memory_os_current"
    [ ( "dynamic categories", [test_case "new category survives persistence" `Quick
          test_dynamic_category_roundtrip] )
    ; ( "commit"
      , [ test_case "a commit parses and prints on the pool" `Quick
            test_a_commit_parses_and_prints_on_the_pool
        ] )
    ; ( "snapshot read failures"
      , List.map (fun (name, test) -> test_case name `Quick (with_memory_read_fs None test))
          snapshot_read_cases )
    ; ( "snapshot read failures Eio"
      , List.map (fun (name, test) -> test_case name `Quick (in_memory_read_eio test))
          snapshot_read_cases )
    ; ( "commit notification"
      , [ test_case "all writers notify outside locks" `Quick test_commit_notifications_follow_all_writers_outside_locks
        ; test_case "snapshot authority independent of journal" `Quick test_commit_notifications_do_not_depend_on_journal
        ; test_case "directory alias emits physical identity" `Quick test_commit_notification_directory_is_physical
        ; test_case "cancellation propagates after commit notifications" `Quick test_commit_notification_preserves_cancellation
        ] )
    ; ( "current snapshot"
      , [ test_case "fresh replace and delta" `Quick test_fresh_replace_and_delta
        ; test_case
            "derivation contract canonicalizes premise sets"
            `Quick
            test_derivation_contract_canonicalizes_sets_and_rejects_duplicate_rules
        ; test_case
            "support retraction cascades to fixed point"
            `Quick
            test_support_retraction_cascades_to_fixed_point
        ; test_case
            "batch retraction is exact atomic and CAS guarded"
            `Quick
            test_batch_retraction_is_exact_atomic_and_cas_guarded
        ; test_case
            "batch retraction recovers exact reason evidence"
            `Quick
            test_batch_retraction_recovers_exact_reason_evidence
        ; test_case "retirement context refuses stale current selection" `Quick
            test_retirement_context_rejects_stale_current
        ; test_case
            "batch retraction recovers torn journal tail"
            `Quick
            test_batch_retraction_recovers_torn_journal_tail
        ; test_case
            "ordinary removals preserve archive until journal recovery"
            `Quick
            test_ordinary_removals_preserve_archive_until_journal_recovery
        ; test_case
            "ordinary removals recover torn journal tail"
            `Quick
            test_ordinary_removals_recover_torn_journal_tail
        ; test_case
            "receipt write failure preserves current fact"
            `Quick
            test_removal_receipt_write_failure_preserves_current_fact
        ; test_case
            "stale drop statements prepare no receipt"
            `Quick
            test_stale_drop_statements_prepare_no_removal_receipt
        ; test_case
            "reverse-ordered support chain reaches fixed point"
            `Quick
            test_reverse_ordered_support_chain_reaches_fixed_point
        ; test_case
            "alternate support keeps derived fact current"
            `Quick
            test_alternate_support_path_keeps_derived_fact_current
        ; test_case
            "same rule replaces premise set"
            `Quick
            test_same_rule_replaces_its_premise_set
        ; test_case
            "unsupported derived upsert has no effect"
            `Quick
            test_unsupported_derived_upsert_has_no_effect
        ; test_case
            "memory id is exact claim derived state"
            `Quick
            test_memory_id_is_exact_claim_derived_state
        ; test_case
            "exact added removed retained"
            `Quick
            test_replace_records_exact_added_removed_and_retained
        ; test_case
            "duplicate identity rejects without overwrite"
            `Quick
            test_duplicate_identity_rejects_without_overwrite
        ; test_case
            "non-current snapshot moved aside, not overwritten"
            `Quick
            test_non_current_snapshot_is_moved_aside_not_overwritten
        ; test_case
            "unsupported current truth fails closed"
            `Quick
            test_snapshot_read_rejects_unsupported_current_truth
        ; test_case
            "forged invalidation evidence fails closed"
            `Quick
            test_snapshot_read_rejects_forged_invalidation_evidence
        ; test_case
            "fact basis is required"
            `Quick
            test_snapshot_read_requires_fact_basis
        ; test_case
            "historical snapshot fields remain readable"
            `Quick
            test_historical_snapshot_fields_remain_readable
        ; test_case
            "object order irrelevant and fields exact"
            `Quick
            test_current_snapshot_object_order_is_irrelevant_but_fields_are_exact
        ; test_case
            "duplicate snapshot fact identity rejects"
            `Quick
            test_duplicate_snapshot_fact_identity_rejects
        ; test_case
            "snapshot read I/O error is returned"
            `Quick
            test_snapshot_read_io_error_is_returned
        ; test_case
            "recall preserves selected facts and order"
            `Quick
            test_recall_preserves_selected_facts_without_local_ranking
        ; test_case
            "recall tracks absence withdrawal failure and recovery"
            `Quick
            test_recall_tracks_empty_unavailable_and_recovery
        ; test_case "recall ignores unchanged snapshot recommits" `Quick
            test_recall_ignores_unchanged_snapshot_recommits
        ; test_case
            "recall has no size threshold"
            `Quick
            test_recall_does_not_hide_current_truth_behind_a_size_threshold
        ; test_case
            "explicit upsert preserves snapshot"
            `Quick
            test_explicit_upsert_preserves_snapshot_and_records_delta
        ; test_case
            "explicit upsert preserves first seen"
            `Quick
            test_explicit_upsert_preserves_first_seen_for_same_claim
        ; test_case
            "board provenance survives the wire"
            `Quick
            test_board_provenance_survives_the_wire
        ; test_case
            "board provenance rejects ids the Board would not accept"
            `Quick
            test_board_provenance_rejects_bad_ids
        ; test_case
            "a board reference outranks the transcript on re-observation"
            `Quick
            test_board_reference_outranks_transcript_on_merge
        ; test_case
            "explicit keepers dirs stay isolated"
            `Quick
            test_explicit_keepers_dirs_do_not_cross_contaminate
        ; test_case
            "stale replace preserves concurrent explicit write"
            `Quick
            test_stale_replace_rejects_concurrent_explicit_write
        ; test_case
            "every commit appends one journal entry"
            `Quick
            test_every_commit_appends_one_journal_entry
        ; test_case
            "rejected commit appends no journal entry"
            `Quick
            test_rejected_commit_appends_no_journal_entry
        ; test_case
            "invalid drop identity has no effect"
            `Quick
            test_invalid_drop_identity_has_no_effect
        ; test_case
            "purge plan removes memory sidecars"
            `Quick
            test_purge_plan_removes_memory_sidecars
        ; test_case
            "range receipt rejects absent snapshot"
            `Quick
            test_committed_range_receipt_rejects_absent_snapshot
        ; test_case
            "range receipt rejects snapshot rollback"
            `Quick
            test_committed_range_receipt_rejects_snapshot_rollback
        ; test_case
            "range receipt rejects same revision different snapshot"
            `Quick
            test_committed_range_receipt_rejects_same_revision_different_snapshot
        ; test_case
            "range receipt survives retract and replace"
            `Quick
            test_committed_range_receipt_survives_retract_and_replace
        ; test_case "atom wire and exclusive receipt identity" `Quick
            test_atom_receipt_wire_and_exclusive_identity
        ; test_case "official receipt survives other commits" `Quick
            test_official_receipt_survives_other_commits
        ; test_case "mixed receipts recover prepared snapshot" `Quick
            test_mixed_receipt_prepared_recovery
        ; test_case "official receipt rejects invalid identity" `Quick
            test_official_receipt_rejects_invalid_identity
        ; test_case "sparse candidate receipts survive no-change and retirement" `Quick
            test_sparse_candidate_receipts_survive_retirement
        ; test_case "candidate reconciliation preserves first order" `Quick
            test_candidate_receipt_reconciliation_preserves_first_order
        ; test_case "candidate receipt set conflicts refuse the whole transaction" `Quick
            test_candidate_set_conflict_is_atomic
        ; test_case "admission recall binds provenance and never revives after retirement" `Quick
            test_admission_recall_commits_recovers_and_expires_on_retirement
        ; test_case "admission recall refuses unbound payload or absent target" `Quick
            test_admission_recall_refuses_unbound_or_mistargeted_payloads
        ; test_case "admission recall refuses a target retired after the decision" `Quick
            test_admission_recall_refuses_a_target_retired_after_the_decision
        ; test_case "admission recall refuses a decision across missing journal revisions" `Quick
            test_admission_recall_refuses_a_decision_across_missing_journal_revisions
        ; test_case "admission recall requires complete later history only for bindings" `Quick
            test_admission_recall_requires_complete_later_history_only_for_bindings
        ; test_case "receipt failure preserves direct snapshot" `Quick
            test_admission_receipt_failure_preserves_direct_snapshot
        ; test_case "recall cache refuses external prefix mutation plus growth" `Quick
            test_admission_recall_cache_invalidates_external_prefix_edit_and_growth
        ; test_case "receipt cache skips decoding an unchanged sidecar" `Quick
            test_receipt_cache_skips_decoding_an_unchanged_sidecar
        ; test_case "receipt cache rereads an externally rewritten sidecar" `Quick
            test_receipt_cache_rereads_an_externally_rewritten_sidecar
        ; test_case "receipt cache reflects this process's receipt write" `Quick
            test_receipt_cache_reflects_this_process_receipt_write
        ; test_case "unchanged journal row cannot prove a missing retirement transition" `Quick
            test_admission_recall_no_change_cannot_hide_missing_retirement_transition
        ; test_case "declared revision links survive failed journal finalization" `Quick
            test_declared_revision_links_survive_journal_failure
        ; test_case "revision evidence does not invent missing links or re-add lineage" `Quick
            test_revision_evidence_never_invents_links
        ; test_case "successor recall follows multistep splits without incarnation revival" `Quick
            test_successor_recall_tracks_multistep_split_incarnations
        ; test_case "successor lineage failures preserve ordinary current results" `Quick
            test_successor_recall_preserves_current_on_missing_history
        ; test_case "successor recall rejects phantom target added in a later revision" `Quick
            test_successor_recall_rejects_phantom_target_added_later
        ; test_case "prepared receipt before revision links recovers with no lineage" `Quick
            test_prepared_receipt_before_revision_links_recovers_with_no_lineage
        ; test_case "legacy removal line clears its legacy receipt once" `Quick
            test_legacy_removal_line_clears_legacy_receipt_once
        ; test_case "prepared candidate receipt set recovers exact snapshot only" `Quick
            test_candidate_prepared_set_recovers_exact_snapshot
        ; test_case
            "range receipts are scoped per runtime cluster"
            `Quick
            test_committed_range_receipts_are_scoped_per_runtime_cluster
        ; test_case
            "unchanged pass keeps snapshot and commits range"
            `Quick
            test_unchanged_pass_keeps_snapshot_and_commits_range
        ; test_case
            "journal recreated after purge sequence"
            `Quick
            test_journal_recreated_after_purge_sequence
        ; test_case
            "re-observation refreshes instead of duplicating"
            `Quick
            test_reobservation_refreshes_instead_of_duplicating
        ] )
    ; ( "undecodable state is not a wedge"
      , [ test_case
            "quarantine and proceed"
            `Quick
            test_undecodable_snapshot_is_quarantined_and_the_write_proceeds
        ; test_case
            "reading moves nothing"
            `Quick
            test_reading_an_undecodable_snapshot_moves_nothing
        ; test_case
            "expected revision still refuses"
            `Quick
            test_expected_revision_still_refuses_after_a_quarantine
        ; test_case "torn json too" `Quick test_torn_json_is_quarantined_too
        ; test_case
            "two quarantines at the same time keep both"
            `Quick
            test_two_quarantines_at_the_same_time_keep_both_files
        ] )
    ; ( "rejection names its cause"
      , [ test_case
            "missing change field"
            `Quick
            test_rejection_names_a_missing_change_field
        ; test_case
            "unknown token names row and field"
            `Quick
            test_rejection_names_the_row_and_field_of_an_unknown_token
        ; test_case
            "retained arithmetic"
            `Quick
            test_rejection_names_the_retained_arithmetic
        ; test_case
            "added row is not current"
            `Quick
            test_rejection_names_an_added_row_that_is_not_current
        ; test_case
            "duplicate row index"
            `Quick
            test_rejection_names_the_index_of_a_duplicate_row
        ; test_case
            "blank source trace id"
            `Quick
            test_rejection_names_a_blank_source_trace_id
        ; test_case
            "unexpected top-level field"
            `Quick
            test_rejection_names_an_unexpected_top_level_field
        ; test_case
            "a keeper writing during a librarian pass"
            `Quick
            test_a_keeper_write_during_a_librarian_pass_keeps_both
        ; test_case
            "absorbed facts leave with their rows kept"
            `Quick
            test_absorbed_facts_leave_the_snapshot_with_their_rows_kept
        ; test_case
            "a failed absorbed write commits nothing"
            `Quick
            test_a_failed_absorbed_write_commits_nothing
        ; test_case
            "an absorbing pass recovers a store that ends mid-line"
            `Quick
            test_an_absorbing_pass_recovers_a_store_that_ends_mid_line
        ; test_case
            "an absorbed fact no longer current writes no row"
            `Quick
            test_an_absorbed_fact_no_longer_current_writes_no_row
        ; test_case
            "absorbed record codec"
            `Quick
            test_absorbed_record_codec
        ] )
    ]
;;
