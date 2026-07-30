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
    (fun () -> Current.For_testing.with_keepers_dir path (fun () -> f path))
;;

let fact ?(claim = "claim") ?(claim_id = "claim-id") ?(turn = 1) () :
  Types.fact =
  { claim
  ; category = Types.Constraint
  ; claim_kind = Some Types.Durable_knowledge
  ; source = { trace_id = "trace"; turn; tool_call_id = None }
  ; first_seen = 100.0
  ; valid_until = None
  ; last_verified_at = None
  ; schema_version = Types.schema_version
  ; claim_id = Some claim_id
  }
;;

let source kind =
  { Current.kind; trace_id = "trace"; generation = 7 }
;;

let replace ?(facts = []) ?(summary = "summary") () =
  Current.replace
    ~keeper_id:"keeper"
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
  with_temp_keepers @@ fun _ ->
  check (option string) "fresh state absent" None
    (match Current.read ~keeper_id:"keeper" with
     | Ok None -> None
     | Ok (Some _) -> Some "present"
     | Error message -> Some message);
  let first = fact ~claim:"first" ~claim_id:"first" () in
  let second = fact ~claim:"second" ~claim_id:"second" () in
  let snapshot = replace ~facts:[ first; second ] () |> require_ok in
  check int "revision" 1 snapshot.revision;
  check (list string) "facts" [ "id:first"; "id:second" ] (fact_ids snapshot.facts);
  check (list string) "added" [ "id:first"; "id:second" ] (fact_ids snapshot.change.added);
  check (list string) "removed" [] (fact_ids snapshot.change.removed);
  check int "retained" 0 snapshot.change.retained
;;

let test_replace_records_exact_added_removed_and_retained () =
  with_temp_keepers @@ fun _ ->
  let first = fact ~claim:"first" ~claim_id:"first" () in
  let second = fact ~claim:"second" ~claim_id:"second" () in
  let changed_second = fact ~claim:"second revised" ~claim_id:"second" () in
  let third = fact ~claim:"third" ~claim_id:"third" () in
  ignore (replace ~facts:[ first; second ] () |> require_ok);
  let snapshot = replace ~facts:[ first; changed_second; third ] () |> require_ok in
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
  with_temp_keepers @@ fun _ ->
  let first = fact ~claim:"first" ~claim_id:"same" () in
  let duplicate = fact ~claim:"different" ~claim_id:"same" () in
  ignore (replace ~facts:[ first ] () |> require_ok);
  (match replace ~facts:[ first; duplicate ] () with
   | Error message ->
     check bool "duplicate error"
       true
       (String.starts_with ~prefix:"duplicate Memory OS fact identity:" message)
   | Ok _ -> fail "duplicate identity was accepted");
  let snapshot = Current.read ~keeper_id:"keeper" |> require_ok |> require_some in
  check int "unchanged revision" 1 snapshot.revision;
  check (list string) "unchanged facts" [ "id:same" ] (fact_ids snapshot.facts)
;;

let test_invalid_current_snapshot_fails_closed () =
  with_temp_keepers @@ fun _ ->
  let snapshot_path = Current.path ~keeper_id:"keeper" in
  Fs_compat.save_file snapshot_path {|{"schema":"old.memory.v0"}|};
  (match replace ~facts:[ fact () ] () with
   | Error _ -> ()
   | Ok _ -> fail "non-current snapshot was overwritten");
  check string "invalid bytes preserved"
    {|{"schema":"old.memory.v0"}|}
    (Fs_compat.load_file snapshot_path)
;;

let test_current_snapshot_object_order_is_irrelevant_but_fields_are_exact () =
  with_temp_keepers @@ fun _ ->
  let written = replace ~facts:[ fact () ] () |> require_ok in
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
  let snapshot_path = Current.path ~keeper_id:"keeper" in
  Fs_compat.save_file snapshot_path (Yojson.Safe.to_string reordered);
  let decoded = Current.read ~keeper_id:"keeper" |> require_ok |> require_some in
  check int "reordered current revision" written.revision decoded.revision;
  let with_unknown =
    match reordered with
    | `Assoc fields -> `Assoc (("legacy_store", `String "ignored") :: fields)
    | _ -> reordered
  in
  Fs_compat.save_file snapshot_path (Yojson.Safe.to_string with_unknown);
  (match Current.read ~keeper_id:"keeper" with
   | Error _ -> ()
   | Ok _ -> fail "current snapshot accepted an unknown field")
;;

let test_recall_excludes_expired_facts_without_local_ranking () =
  with_temp_keepers @@ fun _ ->
  let prompt_dir = Filename.concat repo_root "config/prompts" in
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  let durable = fact ~claim:"durable memory" ~claim_id:"durable" () in
  let expired =
    { (fact ~claim:"short memory" ~claim_id:"short" ()) with
      Types.valid_until = Some 250.0
    }
  in
  ignore (replace ~facts:[ durable; expired ] () |> require_ok);
  let before =
    Masc.Keeper_memory_os_recall.render_context
      ~keeper_id:"keeper"
      ~now:240.0
      ()
  in
  check bool "unexpired fact recalled" true
    (Astring.String.is_infix ~affix:"short memory" before);
  let after =
    Masc.Keeper_memory_os_recall.render_context
      ~keeper_id:"keeper"
      ~now:300.0
      ()
  in
  check bool "expired fact not recalled" false
    (Astring.String.is_infix ~affix:"short memory" after);
  check bool "durable fact remains recalled" true
    (Astring.String.is_infix ~affix:"durable memory" after)
;;

let test_explicit_upsert_preserves_snapshot_and_records_delta () =
  with_temp_keepers @@ fun _ ->
  let first = fact ~claim:"first" ~claim_id:"first" () in
  let second = fact ~claim:"second" ~claim_id:"second" () in
  ignore (replace ~facts:[ first ] ~summary:"librarian summary" () |> require_ok);
  let snapshot =
    Current.upsert_fact
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
            "recall excludes expired facts"
            `Quick
            test_recall_excludes_expired_facts_without_local_ranking
        ; test_case
            "explicit upsert preserves snapshot"
            `Quick
            test_explicit_upsert_preserves_snapshot_and_records_delta
        ] )
    ]
;;
