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
  ; reinforcement = 0
  ; origin = { kind = Types.Authored; trace_id = "trace" }
  ; basis = Types.Observed
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
   | Types.Derived _ | Types.Observed -> fail "unexpected canonical basis");
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
      ~now:240.0
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
     |> List.length)
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
   | Types.Observed -> fail "derived conclusion was promoted without observation");
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
   | Types.Derived _ | Types.Observed -> fail "rule replacement changed basis shape");
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
   | Types.Observed -> fail "derived conclusion changed basis");
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
      ~now:240.0
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

(* An unreadable snapshot and an empty store produce the same turn: no block.
   The removed keeper.memory_os_recall.unavailable asset stated the absence to
   the keeper instead, which made "my memory is missing" a fact the turn could
   reason from. The reason is operator-only now: the MemoryOsRecallUnavailable
   counter and the warn log at the call site. *)
let test_recall_read_failure_injects_no_block () =
  with_temp_keepers @@ fun keepers_dir ->
  let prompt_dir = Filename.concat repo_root "config/prompts" in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
  let snapshot_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  let oc = open_out snapshot_path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "{ not json");
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
   | Error _ -> ()
   | Ok _ -> fail "fixture must leave the snapshot unreadable");
  let rendered =
    Masc.Keeper_memory_os_recall.render_context
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:240.0
      ()
  in
  check string "unreadable snapshot injects no recall block" "" rendered
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
      ~now:240.0
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
  check bool "plan removes the source-bound snapshot" true
    (contains Shutdown.Keeper_memory_source_current_artifact);
  check bool "plan removes the memory journal" true
    (contains Shutdown.Keeper_memory_journal_artifact)
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

(* Byte-identical re-observation is reinforcement, not duplication: the row
   count stays flat, insertion time stays authoritative, the observation time
   refreshes, the re-observation is counted, and an injected copy re-observing
   an authored row must not repaint its origin (task-1032 loop damper). *)
let test_reobservation_reinforces_instead_of_duplicating () =
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
  check int "re-observation counted" 1 stored.reinforcement;
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

let () =
  run
    "keeper_memory_os_current"
    [ ( "current snapshot"
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
            "recall read failure injects no block"
            `Quick
            test_recall_read_failure_injects_no_block
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
            "re-observation reinforces instead of duplicating"
            `Quick
            test_reobservation_reinforces_instead_of_duplicating
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
        ] )
    ]
;;
