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

let fact ?(claim = "claim") ?(claim_id = "claim-id") ?(turn = 1) () :
  Types.fact =
  { claim
  ; category = Types.Constraint
  ; source = { trace_id = "trace"; turn; tool_call_id = None }
  ; first_seen = 100.0
  ; last_verified_at = None
  ; claim_id = Some claim_id
  }
;;

let source kind =
  { Current.kind; trace_id = "trace"; generation = 7 }
;;

let replace
      ~keepers_dir
      ?(expected_revision = None)
      ?(facts = [])
      ?(summary = "summary")
      ()
  =
  Current.replace
    ~keepers_dir
    ~keeper_id:"keeper"
    ~expected_revision
    ~now:200.0
    ~source:(source Current.Librarian)
    ~summary
    ~facts
    ~open_items:[]
    ~constraints:[]
    ~preserved_tool_refs:[]
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
  List.map Types.claim_identity facts
;;

let test_fresh_replace_and_delta () =
  with_temp_keepers @@ fun keepers_dir ->
  check (option string) "fresh state absent" None
    (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
     | Ok None -> None
     | Ok (Some _) -> Some "present"
     | Error message -> Some message);
  let first = fact ~claim:"first" ~claim_id:"first" () in
  let second = fact ~claim:"second" ~claim_id:"second" () in
  let snapshot =
    replace ~keepers_dir ~facts:[ first; second ] () |> require_ok
  in
  check int "revision" 1 snapshot.revision;
  check (list string) "facts" [ "id:first"; "id:second" ] (fact_ids snapshot.facts);
  check (list string) "added" [ "id:first"; "id:second" ] (fact_ids snapshot.change.added);
  check (list string) "removed" [] (fact_ids snapshot.change.removed);
  check int "retained" 0 snapshot.change.retained
;;

let test_replace_records_exact_added_removed_and_retained () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first" ~claim_id:"first" () in
  let second = fact ~claim:"second" ~claim_id:"second" () in
  let changed_second = fact ~claim:"second revised" ~claim_id:"second" () in
  let third = fact ~claim:"third" ~claim_id:"third" () in
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
    [ "id:second"; "id:third" ]
    (fact_ids snapshot.change.added);
  check (list string) "removed identities"
    [ "id:second" ]
    (fact_ids snapshot.change.removed);
  check int "retained" 1 snapshot.change.retained
;;

let test_duplicate_identity_rejects_without_overwrite () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first" ~claim_id:"same" () in
  let duplicate = fact ~claim:"different" ~claim_id:"same" () in
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
  check (list string) "unchanged facts" [ "id:same" ] (fact_ids snapshot.facts)
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
    | `Assoc fields -> `Assoc (("legacy_store", `String "ignored") :: fields)
    | _ -> reordered
  in
  Fs_compat.save_file snapshot_path (Yojson.Safe.to_string with_unknown);
  (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id:"keeper" with
   | Error _ -> ()
   | Ok _ -> fail "current snapshot accepted an unknown field")
;;

let test_recall_preserves_selected_facts_without_local_ranking () =
  with_temp_keepers @@ fun keepers_dir ->
  let prompt_dir = Filename.concat repo_root "config/prompts" in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  let first = fact ~claim:"first memory" ~claim_id:"first" () in
  let second = fact ~claim:"second memory" ~claim_id:"second" () in
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

let test_explicit_upsert_preserves_snapshot_and_records_delta () =
  with_temp_keepers @@ fun keepers_dir ->
  let first = fact ~claim:"first" ~claim_id:"first" () in
  let second = fact ~claim:"second" ~claim_id:"second" () in
  ignore
    (replace
       ~keepers_dir
       ~facts:[ first ]
       ~summary:"librarian summary"
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
  check string "summary preserved" "librarian summary" snapshot.summary;
  check (list string) "facts" [ "id:first"; "id:second" ] (fact_ids snapshot.facts);
  check (list string) "added" [ "id:second" ] (fact_ids snapshot.change.added);
  check (list string) "removed" [] (fact_ids snapshot.change.removed);
  check int "retained" 1 snapshot.change.retained
;;

let test_explicit_keepers_dirs_do_not_cross_contaminate () =
  with_temp_keepers @@ fun first_dir ->
  with_temp_keepers @@ fun second_dir ->
  let first = fact ~claim:"first workspace" ~claim_id:"first" () in
  let second = fact ~claim:"second workspace" ~claim_id:"second" () in
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
    [ "id:first" ]
    (fact_ids (read first_dir).facts);
  check
    (list string)
    "second workspace remains isolated"
    [ "id:second" ]
    (fact_ids (read second_dir).facts)
;;

let test_stale_replace_rejects_concurrent_explicit_write () =
  with_temp_keepers @@ fun keepers_dir ->
  let initial = fact ~claim:"initial" ~claim_id:"initial" () in
  let explicit = fact ~claim:"explicit" ~claim_id:"explicit" () in
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
    [ "id:initial"; "id:explicit" ]
    (fact_ids snapshot.facts)
;;

let () =
  run
    "keeper_memory_os_current"
    [ ( "current snapshot"
      , [ test_case "fresh replace and delta" `Quick test_fresh_replace_and_delta
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
            "object order irrelevant and fields exact"
            `Quick
            test_current_snapshot_object_order_is_irrelevant_but_fields_are_exact
        ; test_case
            "recall preserves selected facts and order"
            `Quick
            test_recall_preserves_selected_facts_without_local_ranking
        ; test_case
            "explicit upsert preserves snapshot"
            `Quick
            test_explicit_upsert_preserves_snapshot_and_records_delta
        ; test_case
            "explicit keepers dirs stay isolated"
            `Quick
            test_explicit_keepers_dirs_do_not_cross_contaminate
        ; test_case
            "stale replace preserves concurrent explicit write"
            `Quick
            test_stale_replace_rejects_concurrent_explicit_write
        ] )
    ]
;;
