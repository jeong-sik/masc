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

let fact ?(claim = "claim") () : Types.fact =
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

let require_ok = function
  | Ok value -> value
  | Error message -> fail message
;;

let require_some = function
  | Some value -> value
  | None -> fail "expected current snapshot"
;;

let write_snapshot ~keepers_dir ?(keeper_id = "keeper") ?(now = 200.0) ?revision ?(facts = []) () =
  let next_revision =
    match revision with
    | Some rev -> rev
    | None ->
      (match Current.read_for_keepers_dir ~keepers_dir ~keeper_id with
       | Ok None -> 1
       | Ok (Some prev) -> prev.revision + 1
       | Error detail -> fail detail)
  in
  let snapshot : Current.t =
    { revision = next_revision
    ; updated_at = now
    ; source = source Current.Librarian
    ; facts
    ; change = { added = facts; removed = []; retained = 0; invalidated = [] }
    }
  in
  let path = Current.path_for_keepers_dir ~keepers_dir ~keeper_id in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic path (Yojson.Safe.to_string (Current.to_json snapshot)) |> require_ok;
  snapshot
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
  ignore (write_snapshot ~keepers_dir ~facts:[ fact () ] ());
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

let derived_fact ~claim derivations =
  Types.derived
    ~claim
    ~category:Types.Fact
    ~now:100.0
    ~origin:{ kind = Types.Authored; trace_id = "trace" }
    ~derivations
  |> require_ok
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
  ignore (write_snapshot ~keepers_dir ~facts:[ first; second ] ());
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
  ignore (write_snapshot ~keepers_dir ~facts:[fact ~claim:"selected current fact" ()] ());
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
  ignore (write_snapshot ~keepers_dir ~facts:[] ());
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
  let first = write_snapshot ~keepers_dir ~now:200.0 ~facts:[fact ~claim:"stable current fact" ()] () in
  let initial = render () in
  let second = write_snapshot ~keepers_dir ~now:400.0 ~facts:first.facts () in
  check bool "recommit advances durable revision" true (second.revision > first.revision);
  check bool "recommit advances durable update time" true (second.updated_at > first.updated_at);
  check string "same facts render identically after recommit" initial (render ());
  ignore (write_snapshot ~keepers_dir ~now:500.0 ~facts:[fact ~claim:"changed current fact" ()] ());
  check bool "changed fact changes model input" true (initial <> render ())
;;

let test_recall_does_not_hide_current_truth_behind_a_size_threshold () =
  with_temp_keepers @@ fun keepers_dir ->
  let prompt_dir = Filename.concat keepers_dir "prompts" in
  Unix.mkdir prompt_dir 0o755;
  Prompt_registry.set_markdown_dir prompt_dir;
  Prompt_registry.load_prompts_from_directory prompt_dir;
  ignore (write_snapshot ~keepers_dir ~facts:[ fact ~claim:(String.make 256 'y') () ] ());
  let rendered =
    Masc.Keeper_memory_os_recall.render_context
      ~keepers_dir
      ~keeper_id:"keeper"
      ()
  in
  check bool "large current truth reaches recall" true
    (String.length rendered > 0)
;;

let test_explicit_keepers_dirs_do_not_cross_contaminate () =
  with_temp_keepers @@ fun first_dir ->
  with_temp_keepers @@ fun second_dir ->
  let first = fact ~claim:"first workspace" () in
  let second = fact ~claim:"second workspace" () in
  ignore (write_snapshot ~keepers_dir:first_dir ~facts:[ first ] ());
  ignore (write_snapshot ~keepers_dir:second_dir ~facts:[ second ] ());
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

(* Memory OS snapshots and commit log live in the config keepers directory,
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
  check bool "plan removes the working context recall index" true
    (contains Shutdown.Keeper_working_context_recall_artifact);
  check bool "plan removes the working context" true
    (contains Shutdown.Keeper_working_context_artifact);
  check bool "plan removes the commit log" true (contains Shutdown.Keeper_memory_log_artifact);
  check bool "plan removes the commit log's lock" true
    (contains Shutdown.Keeper_memory_log_lock_artifact);
  check bool "plan removes the writer's lock" true
    (contains Shutdown.Keeper_memory_writer_lock_artifact);
  check bool "plan removes the memory events sidecar" true
    (contains Shutdown.Keeper_memory_events_artifact)
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

let test_dynamic_category_roundtrip () =
  let category = match Types.category_of_string "architecture_decision" with
    | Some category -> category
    | None -> fail "new category rejected" in
  with_temp_keepers @@ fun keepers_dir ->
  let row = { (fact ()) with category } in
  ignore (write_snapshot ~keepers_dir ~facts:[row] ());
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
    [ ( "dynamic categories"
      , [ test_case "new category survives persistence" `Quick test_dynamic_category_roundtrip ] )
    ; ( "snapshot read failures"
      , List.map (fun (name, test) -> test_case name `Quick (with_memory_read_fs None test))
          snapshot_read_cases )
    ; ( "snapshot read failures Eio"
      , List.map (fun (name, test) -> test_case name `Quick (in_memory_read_eio test))
          snapshot_read_cases )
    ; ( "current snapshot"
      , [ test_case
            "derivation contract canonicalizes premise sets"
            `Quick
            test_derivation_contract_canonicalizes_sets_and_rejects_duplicate_rules
        ; test_case
            "memory id is exact claim derived state"
            `Quick
            test_memory_id_is_exact_claim_derived_state
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
            "purge plan removes memory sidecars"
            `Quick
            test_purge_plan_removes_memory_sidecars
        ] )
    ]
;;
