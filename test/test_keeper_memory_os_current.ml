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

let inspect_snapshot_bytes ~keepers_dir ~keeper_id =
  match Current.For_testing.decode_snapshot (Fs_compat.load_file
      (Current.path_for_keepers_dir ~keepers_dir ~keeper_id)) with
  | Ok snapshot -> snapshot
  | Error rejection -> fail rejection
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

let require_ok = function
  | Ok value -> value
  | Error message -> fail message
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

let test_removal_receipt_write_failure_preserves_current_fact () =
  if Unix.geteuid () = 0 then Alcotest.skip ();
  with_temp_keepers @@ fun keepers_dir ->
  let target = fact ~claim:"must remain if archive preparation fails" () in
  let seeded = replace ~keepers_dir ~facts:[ target ] () |> require_ok in
  with_denied_mode keepers_dir 0o500 (fun () ->
    match Current.retract_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_delete ~keepers_dir ~keeper_id:"keeper" ~now:300.
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
    (Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:300.0
       ~source:(source Current.Explicit_write)
       primary_rollout
     |> require_upsert_ok);
  let joined =
    Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
    (Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
       ~keepers_dir
       ~keeper_id:"keeper"
       ~now:300.0
       ~source:(source Current.Explicit_write)
       initial_rule
     |> require_upsert_ok);
  let strengthened =
    Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
     Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
     Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
    Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
    Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
    (Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
    (Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
  check bool "plan removes cumulative unread evidence for a deleted keeper" true
    (contains Shutdown.Keeper_librarian_unread_ledger_artifact);
  check bool "plan removes the Memory epoch of a deleted Keeper" true
    (contains Shutdown.Keeper_memory_epoch_artifact);
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
    (contains Shutdown.Keeper_memory_absorbed_artifact);
  check bool "plan removes the commit log" true (contains Shutdown.Keeper_memory_log_artifact);
  check bool "plan removes the commit log's lock" true
    (contains Shutdown.Keeper_memory_log_lock_artifact);
  check bool "plan removes the writer's lock" true
    (contains Shutdown.Keeper_memory_writer_lock_artifact)
;;

let test_stale_replace_rejects_concurrent_explicit_write () =
  with_temp_keepers @@ fun keepers_dir ->
  let initial = fact ~claim:"initial" () in
  let explicit = fact ~claim:"explicit" () in
  ignore (replace ~keepers_dir ~facts:[ initial ] () |> require_ok);
  ignore
    (Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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
   repaint its origin (task-1032 loop damper). *)
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
    Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
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


let test_commit_notifications_resume_after_journal_finalization () =
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
    check (list int) "failed journal defers wake but retains committed outcome" [] !observed;
    Unix.rmdir journal;
    ignore (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require_ok);
    check (list int) "public read finalizes journal and dispatches pending wake" [1] !observed;
    (* A different keeper's unreadable snapshot fails before it can commit. *)
    let blocked = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"blocked" in
    Unix.mkdir blocked 0o700;
    (try
       match Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write ~keepers_dir ~keeper_id:"blocked" ~now:200.
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
    ignore (Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write ~keepers_dir:alias ~keeper_id:"alias-keeper" ~now:200.
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
    stop_cancel ();
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
    Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
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

let test_generic_publication_staged_recovery () =
  List.iter (fun (first_write, after_rename) -> with_temp_keepers @@ fun keepers_dir ->
    let old = fact ~claim:"previous publication" () in
    let next = fact ~claim:"next publication" () in
    if not first_write then ignore (replace ~keepers_dir ~facts:[old] () |> require_ok);
    let receipt_path = Current.publication_receipt_path ~keepers_dir ~keeper_id:"keeper" in
    let snapshot_path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let events = ref [] in
    let unsubscribe = Masc.Keeper_memory_commit_notifications.subscribe
      (fun event -> events := event.revision :: !events) in
    Fun.protect ~finally:unsubscribe @@ fun () ->
    let write_snapshot path content =
      Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
        ~sync_file:(fun _ -> if not after_rename then failwith "before rename")
        ~sync_parent:(fun _ -> failwith "after rename") path content in
    (match Current.For_testing.replace_with_publication_io
      ~on_committed:(fun _ _ -> ()) ~before_journal:(fun () -> ())
      ~write_snapshot ~sync_snapshot:(fun _ -> Error "durability unconfirmed")
      ~keepers_dir ~keeper_id:"keeper" ~now:300. ~source:(source Current.Explicit_write)
      ~facts:[next] with
     | Error _ -> () | Ok _ -> fail "injected persistence fault was hidden");
    check bool "prepared publication persists on staged failure" true (Sys.file_exists receipt_path);
    check (list int) "uncertain write sends no wake" [] !events;
    let visible = Fs_compat.load_file_opt snapshot_path in
    let read = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require_ok in
    check bool "public read completes pending recovery" false (Sys.file_exists receipt_path);
    let expected = if after_rename then Some [next] else if first_write then None else Some [old] in
    check bool "first-write absence and prior publication recover distinctly" true
      (Option.map (fun (snapshot : Current.t) -> snapshot.facts) read = expected);
    check bool "recovery never rewrites snapshot bytes" true
      (Fs_compat.load_file_opt snapshot_path = visible);
    check (list int) "only durable target recovery emits a revision wake"
      (if after_rename then [if first_write then 1 else 2] else []) !events)
    [true,false; true,true; false,false; false,true]
;;

let test_generic_publication_journal_and_notification_recovery () =
  with_temp_keepers @@ fun keepers_dir ->
  let journal = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let receipt = Current.publication_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  Unix.mkdir journal 0o700;
  let target = fact ~claim:"first durable publication with unavailable journal" () in
  let committed = replace ~keepers_dir ~facts:[target] () |> require_ok in
  check int "durable snapshot outcome survives strict journal failure" 1 committed.revision;
  check bool "journal failure preserves recovery evidence" true (Sys.file_exists receipt);
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
   | Error _ -> () | Ok _ -> fail "unfinalized publication became readable authority");
  Unix.rmdir journal;
  let wakes = ref 0 in
  let cancel = Masc.Keeper_memory_commit_notifications.subscribe (fun _ ->
      incr wakes; raise (Eio.Cancel.Cancelled (Failure "after notification dispatch"))) in
  (try
     ignore (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper");
     fail "notification cancellation was swallowed"
   with Eio.Cancel.Cancelled _ -> ());
  cancel ();
  check int "notification ran after journal finalization" 1 !wakes;
  check string "crash boundary retains pending notification phase" "notification_pending"
    Yojson.Safe.Util.(Yojson.Safe.from_file receipt |> member "phase" |> to_string);
  let journal_once = Fs_compat.load_file journal in
  let unsubscribe = Masc.Keeper_memory_commit_notifications.subscribe (fun _ -> incr wakes) in
  Fun.protect ~finally:unsubscribe @@ fun () ->
  let recovered = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require_ok in
  check bool "same committed snapshot remains current" true (recovered = Some committed);
  check int "wake is explicitly at-least-once" 2 !wakes;
  check string "exact journal finalization is idempotent" journal_once (Fs_compat.load_file journal);
  check bool "completed dispatch clears receipt" false (Sys.file_exists receipt)
;;

let test_generic_publication_journal_cancellation_keeps_producer_commit () =
  with_temp_keepers @@ fun keepers_dir ->
  let commits = ref 0 in
  (try
     ignore (Current.For_testing.replace_with_publication_io
       ~write_snapshot:Fs_compat.save_file_atomic_strict_staged
       ~sync_snapshot:Fs_compat.sync_file_and_parent_strict
       ~on_committed:(fun _ commit ->
         check bool "original producer sees durable rewrite" true (commit=Current.Rewritten);
         incr commits)
       ~before_journal:(fun () -> raise (Eio.Cancel.Cancelled (Failure "journal I/O cancelled")))
       ~keepers_dir ~keeper_id:"keeper" ~now:300. ~source:(source Current.Explicit_write)
       ~facts:[fact ()]);
     fail "journal cancellation was swallowed"
   with Eio.Cancel.Cancelled _ -> ());
  check int "durable snapshot publishes producer outcome before journal" 1 !commits;
  ignore (Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require_ok);
  check int "recovery does not replay old producer callback" 1 !commits
;;

let retire_target ~keepers_dir ~target =
  let current, current_sha256 =
    match Current.read_with_snapshot_sha256 ~keepers_dir ~keeper_id:"keeper" with
    | Ok (Some pair) -> pair
    | Ok None | Error _ -> fail "removal fixture needs a readable snapshot"
  in
  Current.retract_facts ~pass:Masc.Keeper_memory_commit_pass.Operator_delete
    ~keepers_dir ~keeper_id:"keeper"
    ~expected_revision:current.revision ~expected_snapshot_sha256:current_sha256
    ~now:300.0
    ~source:{ Current.kind = Current.Explicit_retract; trace_id = "plan-beside-its-line" }
    [ { Current.memory_id = Types.memory_id target; reason = "operator retired this claim" } ]
;;

(* A removal whose publication appended its journal line but whose own
   receipt could not be removed; dispatch then cleared the publication, so the
   removal receipt is left for the next writer (#37682). The removal runs with
   the journal unavailable and the test writes the journal itself. Returns the
   journal lines before the removal and the line its publication carried. *)
let leave_removal_receipt ~keepers_dir ~target =
  let journal_path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let earlier =
    Fs_compat.load_file journal_path
    |> String.split_on_char '\n'
    |> List.filter (fun line -> not (String.equal line ""))
  in
  Fs_compat.invalidate_cached_writer journal_path;
  Sys.remove journal_path;
  Unix.mkdir journal_path 0o700;
  (match retire_target ~keepers_dir ~target with
   | Error (Current.Retract_batch_plan_evidence_pending _) -> ()
   | Error _ | Ok _ -> fail "removal fixture did not leave its journal evidence pending");
  Unix.rmdir journal_path;
  let publication_path = Current.publication_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  let removal_line =
    Yojson.Safe.from_file publication_path
    |> Yojson.Safe.Util.member "journal"
    |> Yojson.Safe.to_string
  in
  Sys.remove publication_path;
  check bool "removal receipt is left for the next writer" true
    (Sys.file_exists (Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper"));
  earlier, removal_line
;;

let put_journal ~keepers_dir lines =
  Fs_compat.save_file
    (Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper")
    (String.concat "" (List.map (fun line -> line ^ "\n") lines))
;;

(* A committed line whose source carries [generation], one of the shapes an
   earlier build left in live journals (counted 2026-09-22 in #37682). *)
let with_source_generation line =
  match Yojson.Safe.from_string line with
  | `Assoc fields ->
    Yojson.Safe.to_string
      (`Assoc
         (List.map
            (fun (name, value) ->
               match name, value with
               | "source", `Assoc source -> name, `Assoc (source @ [ "generation", `Int 1 ])
               | _ -> name, value)
            fields))
  | _ -> fail "journal fixture line is not an object"
;;

(* A failed line carrying [cadence_deferred], which the reader stopped
   accepting in #37653. *)
let failed_line_with_cadence_deferred =
  {|{"outcome":"failed","recorded_at":350.0,"trace_id":"later-pass","kind":"lane_cancelled","detail":"cancelled","snapshot_present":true,"cadence_deferred":true}|}
;;

let write_after_removal ~keepers_dir =
  Current.upsert_fact ~pass:Masc.Keeper_memory_commit_pass.Keeper_write
    ~keepers_dir ~keeper_id:"keeper" ~now:400.
    ~source:(source Current.Explicit_write) (fact ~claim:"memory written after the removal" ())
;;

let committed_at ~revision lines =
  let open Yojson.Safe.Util in
  List.filter
    (fun line ->
       member "outcome" line = `String "committed" && member "revision" line = `Int revision)
    lines
;;

let removal_label line_present =
  if line_present then "removal line journalled" else "removal line missing"
;;

let test_removal_reconcile_reads_no_line_older_than_its_target () =
  List.iter (fun line_present ->
    with_temp_keepers @@ fun keepers_dir ->
    let label = removal_label line_present in
    let target = fact ~claim:"claim retired by an interrupted removal" () in
    ignore (replace ~keepers_dir ~facts:[ target ] () |> require_ok);
    let earlier, removal_line = leave_removal_receipt ~keepers_dir ~target in
    let older_build_line = with_source_generation (List.hd earlier) in
    put_journal ~keepers_dir
      ((older_build_line :: earlier) @ (if line_present then [ removal_line ] else []));
    let next = write_after_removal ~keepers_dir |> require_upsert_ok in
    check int (label ^ ": the next write commits") 3 next.revision;
    check bool (label ^ ": the reconcile clears the receipt") false
      (Sys.file_exists (Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper"));
    let journal = read_journal_lines ~keepers_dir in
    (match committed_at ~revision:2 journal with
     | [ line ] ->
       check bool (label ^ ": the journal holds the removal's own line once") true
         (Yojson.Safe.sort line = Yojson.Safe.sort (Yojson.Safe.from_string removal_line))
     | lines -> failf "%s: expected one removal line, got %d" label (List.length lines));
    check bool (label ^ ": the older line stays as written") true
      (List.hd journal = Yojson.Safe.from_string older_build_line))
    [ true; false ]
;;

(* An unreadable line newer than the stop may be the removal's own line, so
   it never lets the removal count as missing. The removal's exact line still
   settles the receipt beside it: a stuck receipt makes later passes fail, and
   their failure lines land after the removal's. *)
let test_removal_reconcile_reads_every_newer_line_before_calling_it_missing () =
  List.iter (fun line_present ->
    with_temp_keepers @@ fun keepers_dir ->
    let label = removal_label line_present in
    let target = fact ~claim:"claim whose removal meets an unreadable line" () in
    ignore (replace ~keepers_dir ~facts:[ target ] () |> require_ok);
    let earlier, removal_line = leave_removal_receipt ~keepers_dir ~target in
    let lines =
      earlier
      @ (if line_present then [ removal_line ] else [])
      @ [ failed_line_with_cadence_deferred ]
    in
    put_journal ~keepers_dir lines;
    let journal_path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let receipt_path = Current.retraction_plan_receipt_path ~keepers_dir ~keeper_id:"keeper" in
    let journal_before = Fs_compat.load_file journal_path in
    match line_present, write_after_removal ~keepers_dir with
    | true, Ok next ->
      check int (label ^ ": the next write commits") 3 next.revision;
      check bool (label ^ ": the exact line clears the receipt") false
        (Sys.file_exists receipt_path);
      check int (label ^ ": the removal is not journalled again") 1
        (List.length (committed_at ~revision:2 (read_journal_lines ~keepers_dir)))
    | false, Error (Current.Upsert_persistence_failed detail) ->
      check bool (label ^ ": the refusal names the unreadable line") true
        (String_util.contains_substring detail
           (Printf.sprintf
              "retraction reconciliation: memory journal line %d is undecodable"
              (List.length lines)));
      check bool (label ^ ": the receipt stays for a later writer") true
        (Sys.file_exists receipt_path);
      check string (label ^ ": the journal is unchanged") journal_before
        (Fs_compat.load_file journal_path);
      check int (label ^ ": memory stays at the removal") 2
        (inspect_snapshot_bytes ~keepers_dir ~keeper_id:"keeper").revision
    | true, Error error -> failf "%s: %s" label (Current.upsert_error_to_string error)
    | false, (Ok _ | Error (Current.Unsupported_derivation _)) ->
      failf "%s: an unreadable newer line let the removal count as missing" label)
    [ true; false ]
;;

(* A publication left pending after its snapshot replaced the prior one: the
   journal append failed, or the process stopped before the phase write after
   appending. The next read recovers it, and an older line an earlier build
   wrote must not stop that recovery (#37682). *)
let test_publication_recovery_reads_no_line_older_than_its_target () =
  List.iter (fun line_present ->
    with_temp_keepers @@ fun keepers_dir ->
    let label =
      if line_present then "publication line journalled" else "publication line missing"
    in
    ignore (replace ~keepers_dir ~facts:[ fact ~claim:"published before the stall" () ] ()
            |> require_ok);
    let journal_path = Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
    let earlier =
      Fs_compat.load_file journal_path
      |> String.split_on_char '\n'
      |> List.filter (fun line -> not (String.equal line ""))
    in
    Fs_compat.invalidate_cached_writer journal_path;
    Sys.remove journal_path;
    Unix.mkdir journal_path 0o700;
    let committed =
      replace ~keepers_dir ~expected_revision:(Some 1)
        ~facts:[ fact ~claim:"published while the journal was unavailable" () ] ()
      |> require_ok
    in
    check int (label ^ ": the snapshot is replaced") 2 committed.revision;
    Unix.rmdir journal_path;
    let publication_path = Current.publication_receipt_path ~keepers_dir ~keeper_id:"keeper" in
    let publication_line =
      Yojson.Safe.from_file publication_path
      |> Yojson.Safe.Util.member "journal"
      |> Yojson.Safe.to_string
    in
    let older_build_line = with_source_generation (List.hd earlier) in
    put_journal ~keepers_dir
      ((older_build_line :: earlier) @ (if line_present then [ publication_line ] else []));
    let recovered = Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" |> require_ok in
    check bool (label ^ ": the read returns the published snapshot") true
      (recovered = Some committed);
    check bool (label ^ ": the recovery clears the publication receipt") false
      (Sys.file_exists publication_path);
    let journal = read_journal_lines ~keepers_dir in
    (match committed_at ~revision:2 journal with
     | [ line ] ->
       check bool (label ^ ": the journal holds the publication's own line once") true
         (Yojson.Safe.sort line = Yojson.Safe.sort (Yojson.Safe.from_string publication_line))
     | lines -> failf "%s: expected one publication line, got %d" label (List.length lines));
    check bool (label ^ ": the older line stays as written") true
      (List.hd journal = Yojson.Safe.from_string older_build_line))
    [ true; false ]
;;

let test_generic_publication_conflict_preserves_stores () =
  with_temp_keepers @@ fun keepers_dir ->
  let write_snapshot path content =
    Fs_compat.Atomic_replace_for_testing.save_file_atomic_strict_staged
      ~sync_parent:(fun _ -> failwith "after rename") path content in
  ignore (Current.For_testing.replace_with_publication_io
      ~on_committed:(fun _ _ -> ()) ~before_journal:(fun () -> ())
    ~write_snapshot ~sync_snapshot:(fun _ -> Error "not synced")
    ~keepers_dir ~keeper_id:"keeper" ~now:300. ~source:(source Current.Explicit_write)
    ~facts:[fact ()]);
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" in
  let receipt = Current.publication_receipt_path ~keepers_dir ~keeper_id:"keeper" in
  let saved_receipt = Fs_compat.load_file receipt in
  Fs_compat.save_file path "{corrupt snapshot";
  (match replace ~keepers_dir ~facts:[] () with
   | Error _ -> () | Ok _ -> fail "conflicting prepared publication was overwritten");
  check string "conflict is not quarantined or replaced" "{corrupt snapshot" (Fs_compat.load_file path);
  check string "conflicting receipt is preserved exactly" saved_receipt (Fs_compat.load_file receipt);
  check bool "conflict creates no journal" false
    (Sys.file_exists (Current.journal_path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"))
;;

let () =
  run
    "keeper_memory_os_current"
    [
      ("generic publication", [
        test_case "staged first and subsequent publication recovery" `Quick test_generic_publication_staged_recovery;
        test_case "journal failure and notification cancellation recovery" `Quick test_generic_publication_journal_and_notification_recovery;
        test_case "journal cancellation retains producer commit" `Quick test_generic_publication_journal_cancellation_keeps_producer_commit;
        test_case "recovery reads no line older than its target" `Quick test_publication_recovery_reads_no_line_older_than_its_target;
        test_case "conflict preserves all stores" `Quick test_generic_publication_conflict_preserves_stores]); ( "dynamic categories", [test_case "new category survives persistence" `Quick
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
      , [ test_case "durable snapshot retains wake until journal finalization" `Quick test_commit_notifications_resume_after_journal_finalization
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
            "removal reconcile reads no line older than its target"
            `Quick
            test_removal_reconcile_reads_no_line_older_than_its_target
        ; test_case
            "removal reconcile reads every newer line before calling it missing"
            `Quick
            test_removal_reconcile_reads_every_newer_line_before_calling_it_missing
        ; test_case
            "receipt write failure preserves current fact"
            `Quick
            test_removal_receipt_write_failure_preserves_current_fact
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
            "journal recreated after purge sequence"
            `Quick
            test_journal_recreated_after_purge_sequence
        ; test_case
            "re-observation refreshes instead of duplicating"
            `Quick
            test_reobservation_refreshes_instead_of_duplicating
        ] )
    ]
;;
