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

let require_some = function
  | Some value -> value
  | None -> fail "expected current snapshot"
;;

let fact_ids facts =
  List.map Types.memory_id facts
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
  check int "retained" 0 snapshot.change.retained
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

let test_invalid_current_snapshot_fails_closed () =
  with_temp_keepers @@ fun keepers_dir ->
  let snapshot_path =
    Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"
  in
  Fs_compat.save_file snapshot_path {|{"schema":"old.memory.v0"}|};
  (match replace ~keepers_dir ~facts:[ fact () ] () with
   | Error _ -> ()
   | Ok _ -> fail "non-current snapshot was overwritten");
  check string "invalid bytes preserved"
    {|{"schema":"old.memory.v0"}|}
    (Fs_compat.load_file snapshot_path)
;;

let test_previous_path_is_not_read_or_migrated () =
  with_temp_keepers @@ fun keepers_dir ->
  let previous_path = Filename.concat keepers_dir "keeper.memory.json" in
  Fs_compat.save_file previous_path {|{"retired":"snapshot"}|};
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
   | Ok None -> ()
   | Ok (Some _) -> fail "previous path was read as current state"
   | Error message -> fail message);
  ignore (replace ~keepers_dir ~facts:[ fact () ] () |> require_ok);
  check string "previous bytes remain untouched"
    {|{"retired":"snapshot"}|}
    (Fs_compat.load_file previous_path);
  check bool "current path created"
    true
    (Sys.file_exists
       (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"))
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
    | `Assoc fields -> `Assoc (("summary", `String "retired") :: fields)
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

(* The recall byte budget is read at render time, so a snapshot that was
   within budget when written can exceed it later — the budget is an env
   knob, and facts accumulate. That arm injects nothing rather than a
   truncated block, and it is the only recall path that discards facts it
   successfully read. *)
let test_recall_over_budget_injects_no_block () =
  with_temp_keepers
  @@ fun keepers_dir ->
  let prompt_dir = Filename.concat keepers_dir "prompts" in
  Unix.mkdir prompt_dir 0o755;
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  ignore (replace ~keepers_dir ~facts:[ fact ~claim:(String.make 256 'y') () ] () |> require_ok);
  let key = Env_config.KeeperMemoryOs.recall_facts_max_bytes_env_key in
  let previous = Sys.getenv_opt key in
  let restore () =
    match previous with
    | Some value -> Unix.putenv key value
    | None -> Unix.putenv key ""
  in
  Fun.protect ~finally:restore (fun () ->
    Unix.putenv key "16";
    let rendered =
      Masc.Keeper_memory_os_recall.render_context
        ~keepers_dir
        ~keeper_id:"keeper"
        ~now:240.0
        ()
    in
    check string "over-budget recall injects no block" "" rendered);
  Unix.putenv key "1048576";
  let rendered_within_budget =
    Masc.Keeper_memory_os_recall.render_context
      ~keepers_dir
      ~keeper_id:"keeper"
      ~now:240.0
      ()
  in
  check bool "same snapshot renders when the budget allows it" true
    (String.length rendered_within_budget > 0)
;;

let test_snapshot_write_rejects_rendered_fact_payload_over_budget () =
  with_temp_keepers @@ fun keepers_dir ->
  match
    Current.replace
      ~max_fact_bytes:128
      ~keepers_dir
      ~keeper_id:"keeper"
      ~expected_revision:None
      ~now:200.0
      ~source:(source Current.Explicit_write)
      ~facts:[ fact ~claim:(String.make 256 'x') () ]
      ()
  with
  | Error message ->
    check bool "typed boundary detail" true
      (String_util.contains_substring message "actual_bytes=");
    check bool "declared budget detail" true
      (String_util.contains_substring message "max_bytes=128");
    check bool "no snapshot written" false
      (Sys.file_exists
         (Current.path_for_keepers_dir ~keepers_dir ~keeper_id:"keeper"))
  | Ok _ -> fail "oversized snapshot was committed"
;;

let test_snapshot_write_floors_nonpositive_budget () =
  with_temp_keepers @@ fun keepers_dir ->
  match
    Current.replace
      ~max_fact_bytes:0
      ~keepers_dir
      ~keeper_id:"keeper"
      ~expected_revision:None
      ~now:200.0
      ~source:(source Current.Explicit_write)
      ~facts:[ fact ~claim:"x" () ]
      ()
  with
  | Error message ->
    check bool "budget floored to one byte" true
      (String_util.contains_substring message "max_bytes=1");
    check bool "invalid zero budget not exposed" false
      (String_util.contains_substring message "max_bytes=0")
  | Ok _ -> fail "non-empty snapshot fit within the one-byte floor"
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
    |> require_ok
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
    |> require_ok
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
     |> require_ok);
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
     |> require_ok);
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
     |> require_ok);
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

(* A pre-provenance three-field row — the shape of every snapshot already on
   disk — must decode as a Legacy row instead of being rejected: last_seen
   collapses to first_seen, reinforcement to 0, and no origin is invented. A
   row mixing the two vocabularies is a shape this build does not know and
   must reject rather than read past. *)
let test_legacy_three_field_fact_row_decodes_as_legacy () =
  let strip_newer_fields fields =
    List.filter
      (fun (key, _) ->
         not (List.mem key [ "last_seen"; "reinforcement"; "origin" ]))
      fields
  in
  let legacy_row =
    match Types.fact_to_json (fact ~claim:"written before provenance" ()) with
    | `Assoc fields -> `Assoc (strip_newer_fields fields)
    | _ -> fail "fact_to_json did not produce an object"
  in
  (match Types.fact_of_json legacy_row with
   | Some decoded ->
     check bool "legacy origin declared" true (decoded.origin.kind = Types.Legacy);
     check
       bool
       "no invented trace"
       true
       (String.equal decoded.origin.trace_id "");
     check (float 0.0) "last_seen collapses to first_seen" 100.0 decoded.last_seen;
     check int "no phantom reinforcement" 0 decoded.reinforcement;
     check
       string
       "claim bytes survive the widening"
       "written before provenance"
       decoded.claim
   | None -> fail "legacy three-field row was rejected");
  let mixed_row =
    match legacy_row with
    | `Assoc fields ->
      `Assoc
        (("origin", `Assoc [ "kind", `String "authored"; "trace_id", `String "" ]) :: fields)
    | _ -> fail "unreachable"
  in
  check bool "mixed vocabulary rejects" true (Types.fact_of_json mixed_row = None)
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
    |> require_ok
  in
  check int "one row, not a duplicate" 1 (List.length snapshot.facts);
  let stored = List.hd snapshot.facts in
  check (float 0.0) "insertion time remains authoritative" 100.0 stored.first_seen;
  check (float 0.0) "observation time refreshed" 600.0 stored.last_seen;
  check int "re-observation counted" 1 stored.reinforcement;
  check bool "original origin preserved" true (stored.origin.kind = Types.Authored);
  check bool "category still updates" true (stored.category = Types.Lesson)
;;

let () =
  run
    "keeper_memory_os_current"
    [ ( "current snapshot"
      , [ test_case "fresh replace and delta" `Quick test_fresh_replace_and_delta
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
            "invalid current snapshot fails closed"
            `Quick
            test_invalid_current_snapshot_fails_closed
        ; test_case
            "previous path is not read or migrated"
            `Quick
            test_previous_path_is_not_read_or_migrated
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
            "recall over budget injects no block"
            `Quick
            test_recall_over_budget_injects_no_block
        ; test_case
            "snapshot rejects rendered facts over budget"
            `Quick
            test_snapshot_write_rejects_rendered_fact_payload_over_budget
        ; test_case
            "snapshot floors nonpositive budget"
            `Quick
            test_snapshot_write_floors_nonpositive_budget
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
            "purge plan removes memory sidecars"
            `Quick
            test_purge_plan_removes_memory_sidecars
        ; test_case
            "journal recreated after purge sequence"
            `Quick
            test_journal_recreated_after_purge_sequence
        ; test_case
            "legacy three-field row decodes as legacy"
            `Quick
            test_legacy_three_field_fact_row_decodes_as_legacy
        ; test_case
            "re-observation reinforces instead of duplicating"
            `Quick
            test_reobservation_reinforces_instead_of_duplicating
        ] )
    ]
;;
