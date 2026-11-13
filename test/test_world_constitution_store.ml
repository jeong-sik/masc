(** Ledger tests for the world constitution (RFC-0442). *)

open Masc.World_constitution_types
module Store = Masc.World_constitution_store

let with_world f =
  let path = Filename.temp_file "world-constitution-" ".dir" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree path) (fun () -> f path)

let article ?(id = Article_id.generate ()) ?(author = "lane-smith") ?(at = 1.0) text =
  match
    make ~id ~text ~author ~at ~evidence:[]
  with
  | Ok article -> article
  | Error invalid ->
    Alcotest.failf "article rejected: %s" (invalid_to_string invalid)

let end_offset ~base_path =
  match Store.load ~base_path ~resolve_subject:(fun _ -> true) with
  | Ok ledger -> ledger.Store.end_offset
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let add ~base_path article =
  match
    Store.append_at ~base_path
      ~expected_end_offset:(end_offset ~base_path)
      (Added article)
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error)

let remove ~base_path (article : t) =
  match
    Store.append_at ~base_path
      ~expected_end_offset:(end_offset ~base_path)
      (Removed { id = article.id; by = "critic"; at = 9.0; reason = None })
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error)

let replace ~base_path ?(by = "critic") superseded article =
  match
    Store.append_at ~base_path
      ~expected_end_offset:(end_offset ~base_path)
      (Replaced
         { superseded = List.map (fun (retired : t) -> retired.id) superseded
         ; article
         ; by
         ; at = 9.0
         ; reason = None
         })
  with
  | Ok () -> ()
  | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error)

let load_or_fail ?(resolve_subject = fun _ -> true) ~base_path () =
  match Store.load ~base_path ~resolve_subject with
  | Ok ledger -> ledger
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let texts (ledger : Store.ledger) = List.map (fun (a : t) -> a.text) ledger.articles

let load_articles_or_fail ?(resolve_subject = fun _ -> true) ~base_path () =
  match Store.load_articles ~base_path ~resolve_subject with
  | Ok articles -> articles
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let article_texts articles = List.map (fun (a : t) -> a.text) articles

let test_ledger_path_is_base_path_scoped () =
  Alcotest.(check string)
    "ledger sits under the world's own .masc"
    "/tmp/a-world/.masc/constitution/articles.jsonl"
    (Store.ledger_path ~base_path:"/tmp/a-world")

let test_a_world_without_a_ledger_has_no_articles () =
  with_world (fun base_path ->
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check int) "no articles" 0 (List.length ledger.articles);
      Alcotest.(check int) "no history" 0 (List.length ledger.entries);
      Alcotest.(check int) "nothing rejected" 0 (List.length ledger.rejected);
      Alcotest.(check int) "nothing isolated" 0 (List.length ledger.isolated))

let test_written_norms_come_back_in_order () =
  with_world (fun base_path ->
      add ~base_path (article "first norm");
      add ~base_path (article "second norm");
      Alcotest.(check (list string))
        "order of writing is kept" [ "first norm"; "second norm" ]
        (texts (load_or_fail ~base_path ())))

let test_removing_takes_a_norm_out_of_force () =
  with_world (fun base_path ->
      let doomed = article "a norm someone took back" in
      add ~base_path (article "a norm that stays");
      add ~base_path doomed;
      remove ~base_path doomed;
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check (list string))
        "only the surviving norm is held" [ "a norm that stays" ] (texts ledger);
      Alcotest.(check int) "nothing was rejected" 0 (List.length ledger.rejected))

let test_rewriting_a_held_norm_edits_it_in_place () =
  with_world (fun base_path ->
      let original = article "a norm with a typo" in
      add ~base_path original;
      add ~base_path (article "a trailing norm");
      let edited =
        match
          make ~id:original.id ~text:"a norm without a typo" ~author:"critic"
            ~at:5.0 ~evidence:[]
        with
        | Ok edited -> edited
        | Error invalid ->
          Alcotest.failf "%s" (invalid_to_string invalid)
      in
      add ~base_path edited;
      Alcotest.(check (list string))
        "the edit lands in place, not at the end"
        [ "a norm without a typo"; "a trailing norm" ]
        (texts (load_or_fail ~base_path ())))

let test_a_norm_written_again_after_removal_returns_at_the_end () =
  with_world (fun base_path ->
      let disputed = article "a disputed norm" in
      add ~base_path disputed;
      add ~base_path (article "an undisputed norm");
      remove ~base_path disputed;
      add ~base_path disputed;
      Alcotest.(check (list string))
        "the world changed its mind, and that is when"
        [ "an undisputed norm"; "a disputed norm" ]
        (texts (load_or_fail ~base_path ())))

(* Two keepers reading the same world, one writing first. The second decided
   something from what it read -- the byte ceiling is decided exactly this way
   -- so its write must not land on a ledger it never saw. *)
let test_a_write_built_on_a_stale_read_is_refused () =
  with_world (fun base_path ->
      add ~base_path (article "first norm");
      let stale = end_offset ~base_path in
      add ~base_path (article "a norm written by someone else");
      match
        Store.append_at ~base_path ~expected_end_offset:stale
          (Added (article "a norm decided from the old ledger"))
      with
      | Error (Store.Ledger_moved { expected; actual }) ->
        Alcotest.(check int) "it names the read it was built on" stale expected;
        Alcotest.(check bool) "and where the ledger actually ends" true
          (actual > stale);
        Alcotest.(check (list string))
          "the stale write did not land"
          [ "first norm"; "a norm written by someone else" ]
          (texts (load_or_fail ~base_path ()))
      | Ok () -> Alcotest.fail "a write built on a stale read landed"
      | Error other ->
        Alcotest.failf "wrong error: %s" (Store.append_error_to_string other))

let test_articles_only_load_folds_the_same_articles () =
  with_world (fun base_path ->
      add ~base_path (article "a norm that stays");
      let doomed = article "a norm someone took back" in
      add ~base_path doomed;
      remove ~base_path doomed;
      Alcotest.(check (list string))
        "ordinary loads fold what the full load folds"
        (texts (load_or_fail ~base_path ()))
        (article_texts (load_articles_or_fail ~base_path ())))

let test_articles_only_load_of_a_missing_ledger_is_empty () =
  with_world (fun base_path ->
      Alcotest.(check int) "no ledger, no articles" 0
        (List.length (load_articles_or_fail ~base_path ())))

let held_or_fail ?(resolve_subject = fun _ -> true) ~base_path () : Store.held_projection =
  match Store.load_held ~base_path ~resolve_subject with
  | Ok held -> held
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let articles_at_or_fail ?(resolve_subject = fun _ -> true) ~base_path position =
  match Store.load_articles_at ~base_path ~resolve_subject position with
  | Ok articles -> articles
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let article_values articles =
  List.map (fun (article : t) -> Article_id.to_string article.id, article.text) articles

let check_articles label expected actual =
  Alcotest.(check (list (pair string string))) label
    (article_values expected) (article_values actual)

let check_loads ?(status = Store.Resolved) ~base_path ~resolve_subject expected =
  let ledger = load_or_fail ~base_path ~resolve_subject () in
  check_articles "full replay holds the resolved articles" expected ledger.articles;
  check_articles "articles-only replay agrees" expected
    (load_articles_or_fail ~base_path ~resolve_subject ());
  let held = held_or_fail ~base_path ~resolve_subject () in
  check_articles "held replay agrees" expected held.Store.articles;
  Alcotest.(check bool) "the projection reports its isolation status" true
    (held.status = status);
  (match articles_at_or_fail ~base_path ~resolve_subject held.at with
   | Some articles -> check_articles "position replay agrees" expected articles
   | None -> Alcotest.fail "the position just read no longer matches the ledger");
  ledger, held.at

let check_isolation ~line_number ~subject ~article_ids (ledger : Store.ledger) =
  match ledger.isolated with
  | [ isolated ] ->
      Alcotest.(check int) "the unresolved line is identified" line_number isolated.line_number;
      Alcotest.(check string) "the unresolved subject is identified" subject isolated.subject;
      let ids = List.map Article_id.to_string in
      Alcotest.(check (list string)) "all affected ids are identified"
        (List.sort_uniq String.compare (ids article_ids))
        (List.sort_uniq String.compare (ids isolated.article_ids))
  | others ->
      Alcotest.failf "expected one isolated line, got %d" (List.length others)

(* RFC-0491 §3.2: a System's basis names the ledger position it was read at.
   Later writes only append, so that position reads back the same articles,
   an edit in place included. *)
let test_a_position_reads_back_the_articles_held_then () =
  with_world (fun base_path ->
      let kept = article "a norm that stays" in
      add ~base_path kept;
      let held = held_or_fail ~base_path () in
      let then_articles = held.Store.articles and position = held.at in
      add ~base_path (article "a norm written later");
      remove ~base_path kept;
      (match
         make ~id:kept.id ~text:"a norm that stays, edited" ~author:"lane-smith" ~at:2.0
           ~evidence:[]
       with
       | Ok edited -> add ~base_path edited
       | Error invalid -> Alcotest.failf "article rejected: %s" (invalid_to_string invalid));
      Alcotest.(check (option (list string))) "the position folds what was held then"
        (Some (article_texts then_articles))
        (Option.map article_texts (articles_at_or_fail ~base_path position));
      let now = held_or_fail ~base_path () in
      Alcotest.(check bool) "resolved edits and removals keep a resolved projection" true
        (now.Store.status = Store.Resolved);
      Alcotest.(check bool) "the ledger grew past it" true
        (now.Store.at.end_offset > position.Store.end_offset))

let test_a_position_the_ledger_no_longer_begins_with_reads_nothing () =
  with_world (fun base_path ->
      add ~base_path (article "a norm that stays");
      let position = (held_or_fail ~base_path ()).Store.at in
      Alcotest.(check bool) "a longer position than the ledger" true
        (Option.is_none
           (articles_at_or_fail ~base_path
              { position with Store.end_offset = position.Store.end_offset + 1 }));
      Out_channel.with_open_bin (Store.ledger_path ~base_path) (fun channel ->
        output_string channel "");
      add ~base_path (article "a norm written over the old bytes");
      add ~base_path (article "and another, so the ledger is long enough to compare");
      Alcotest.(check bool) "bytes that no longer hash the same" true
        (Option.is_none (articles_at_or_fail ~base_path position)))

let test_a_line_that_does_not_decode_is_reported_not_dropped () =
  with_world (fun base_path ->
      add ~base_path (article "a readable norm");
      let channel =
        open_out_gen [ Open_append; Open_text ] 0o600
          (Store.ledger_path ~base_path)
      in
      output_string channel "{\"kind\":\"added\",\"article\":{}}\n";
      close_out channel;
      add ~base_path (article "another readable norm");
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check (list string))
        "readable norms survive the broken line"
        [ "a readable norm"; "another readable norm" ]
        (texts ledger);
      match ledger.rejected with
      | [ rejected ] ->
        Alcotest.(check int) "names the offending line" 2 rejected.line_number;
        Alcotest.(check string) "a line inside the file ends with its newline"
          "newline_terminated" (Store.line_end_to_string rejected.line_end);
        Alcotest.(check bool)
          "carries a reason" true
          (String.length rejected.detail > 0)
      | others ->
        Alcotest.failf "expected one rejection, got %d" (List.length others))

(* An append that stopped before its newline leaves the file's last line
   unterminated. The norms before it still fold, and the cut line is reported
   as the last line rather than as one written whole. *)
let test_an_unterminated_last_line_is_reported_as_such () =
  with_world (fun base_path ->
      add ~base_path (article "a readable norm");
      let channel =
        open_out_gen [ Open_append; Open_text ] 0o600
          (Store.ledger_path ~base_path)
      in
      output_string channel "{\"kind\":\"added\",\"artic";
      close_out channel;
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check (list string))
        "the norm before the cut still holds" [ "a readable norm" ] (texts ledger);
      match ledger.rejected with
      | [ rejected ] ->
        Alcotest.(check int) "names the cut line" 2 rejected.line_number;
        Alcotest.(check string) "the cut line has no newline"
          "unterminated_final_line" (Store.line_end_to_string rejected.line_end)
      | others ->
        Alcotest.failf "expected one rejection, got %d" (List.length others))

let append_bytes ~base_path bytes =
  let channel =
    open_out_gen [ Open_append; Open_creat; Open_binary ] 0o600
      (Store.ledger_path ~base_path)
  in
  output_string channel bytes;
  close_out channel

(* A server that died inside an append leaves a last line with no newline.
   The next article is still written: the unfinished line is cut and the
   lines before it are kept byte for byte (#37117). *)
let test_an_article_is_added_after_an_unfinished_last_line () =
  with_world (fun base_path ->
      add ~base_path (article "a norm written before the crash");
      let before = Fs_compat.load_file (Store.ledger_path ~base_path) in
      append_bytes ~base_path "{\"kind\":";
      let held = held_or_fail ~base_path () in
      add ~base_path (article "a norm written after the crash");
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check (list string)) "both norms are held"
        [ "a norm written before the crash"; "a norm written after the crash" ]
        (texts ledger);
      Alcotest.(check int) "the unfinished line is gone" 0
        (List.length ledger.rejected);
      let after = Fs_compat.load_file (Store.ledger_path ~base_path) in
      Alcotest.(check string) "the lines before it are kept" before
        (String.sub after 0 (String.length before));
      Alcotest.(check int) "the ledger ends at the new line" (String.length after)
        ledger.end_offset;
      Alcotest.(check (option (list string)))
        "a position read beside the unfinished line still folds"
        (Some [ "a norm written before the crash" ])
        (Option.map article_texts (articles_at_or_fail ~base_path held.Store.at)))

(* The same holds when the crash hit the very first append. *)
let test_an_article_is_added_to_a_ledger_that_is_only_an_unfinished_line () =
  with_world (fun base_path ->
      Fs_compat.mkdir_p (Filename.dirname (Store.ledger_path ~base_path));
      append_bytes ~base_path "{\"kind\":";
      add ~base_path (article "the first norm");
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check (list string)) "the norm is held" [ "the first norm" ]
        (texts ledger);
      Alcotest.(check int) "the unfinished line is gone" 0
        (List.length ledger.rejected))

(* Bytes with no newline are not a move even when they read as one: the next
   append cuts them, so holding them now would show a norm that then
   vanishes. *)
let test_an_unfinished_last_line_that_reads_whole_is_not_held () =
  with_world (fun base_path ->
      add ~base_path (article "a readable norm");
      let whole = Fs_compat.load_file (Store.ledger_path ~base_path) in
      append_bytes ~base_path (String.sub whole 0 (String.length whole - 1));
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check int) "one norm, not two moves" 1 (List.length ledger.entries);
      Alcotest.(check int) "the ledger ends before the unfinished line"
        (String.length whole) ledger.end_offset;
      match ledger.rejected with
      | [ rejected ] ->
        Alcotest.(check string) "reported as the unfinished last line"
          "unterminated_final_line" (Store.line_end_to_string rejected.line_end)
      | others ->
        Alcotest.failf "expected one rejection, got %d" (List.length others))

(* RFC-0504: one line retires a bundle and names its replacement, so the
   ledger keeps which norm replaced which. *)
let test_replacing_retires_the_bundle_and_adds_the_replacement () =
  with_world (fun base_path ->
      let first = article "a norm with an older twin" in
      let second = article "the older twin" in
      add ~base_path first;
      add ~base_path second;
      replace ~base_path [ first; second ] (article "the merged norm");
      let ledger = load_or_fail ~base_path () in
      Alcotest.(check (list string))
        "only the replacement is held" [ "the merged norm" ] (texts ledger);
      Alcotest.(check int) "every move stays in the history" 3
        (List.length ledger.entries);
      Alcotest.(check int) "nothing was rejected" 0 (List.length ledger.rejected);
      Alcotest.(check int) "nothing was isolated" 0 (List.length ledger.isolated))

let test_replacing_keeps_unrelated_norms_in_place () =
  with_world (fun base_path ->
      let first = article "a norm with an older twin" in
      let unrelated = article "an unrelated norm" in
      let second = article "the older twin" in
      add ~base_path first;
      add ~base_path unrelated;
      add ~base_path second;
      replace ~base_path [ first; second ] (article "the merged norm");
      Alcotest.(check (list string))
        "the unrelated norm stays where it was, the merge lands last"
        [ "an unrelated norm"; "the merged norm" ]
        (texts (load_or_fail ~base_path ())))

(* RFC-0504 §2.4: a line whose subject the roster does not resolve folds out
   of the live set and is reported beside the rejected lines, never dropped
   quietly. *)
let test_a_line_from_outside_the_roster_is_isolated_not_dropped () =
  with_world (fun base_path ->
      add ~base_path (article "a norm the world holds");
      add ~base_path (article ~author:"codex-operator" "a norm from outside the tool");
      let ledger =
        load_or_fail ~base_path
          ~resolve_subject:(String.equal "lane-smith") ()
      in
      Alcotest.(check (list string))
        "only the roster's norm is held" [ "a norm the world holds" ] (texts ledger);
      Alcotest.(check int) "the decoded history keeps both lines" 2
        (List.length ledger.entries);
      (match ledger.isolated with
      | [ isolated ] ->
        Alcotest.(check int) "names the isolated line" 2 isolated.line_number;
        Alcotest.(check string) "names the unresolved subject" "codex-operator"
          isolated.subject
      | others ->
        Alcotest.failf "expected one isolated line, got %d" (List.length others)))

let test_an_unresolved_removal_withholds_without_erasing_history () =
  with_world (fun base_path ->
      let withdrawn = article "a norm taken back by a former keeper" in
      let unrelated = article "an unrelated norm" in
      add ~base_path withdrawn;
      add ~base_path unrelated;
      let resolve_subject = String.equal "lane-smith" in
      let _, before_removal =
        check_loads ~base_path ~resolve_subject [ withdrawn; unrelated ] in
      remove ~base_path withdrawn;
      let ledger, isolated_position =
        check_loads ~base_path ~resolve_subject ~status:Store.Isolated_history [ unrelated ] in
      let removal =
        Removed { id = withdrawn.id; by = "critic"; at = 9.0; reason = None } in
      Alcotest.(check bool) "the addition and unresolved removal remain in history" true
        (ledger.entries = [ Added withdrawn; Added unrelated; removal ]);
      Alcotest.(check int) "the decoded removal is not a rejection" 0
        (List.length ledger.rejected);
      check_isolation ~line_number:3 ~subject:"critic"
        ~article_ids:[ withdrawn.id ] ledger;
      add ~base_path withdrawn;
      let readopted, _ =
        check_loads ~base_path ~resolve_subject ~status:Store.Isolated_history
          [ unrelated; withdrawn ] in
      Alcotest.(check bool) "readoption appends without erasing the unresolved history" true
        (readopted.entries = ledger.entries @ [ Added withdrawn ]);
      check_isolation ~line_number:3 ~subject:"critic"
        ~article_ids:[ withdrawn.id ] readopted;
      (match articles_at_or_fail ~base_path ~resolve_subject isolated_position with
       | Some articles -> check_articles "readoption does not rewrite the isolated prefix"
           [ unrelated ] articles
       | None -> Alcotest.fail "readoption invalidated the earlier ledger prefix");
      match articles_at_or_fail ~base_path ~resolve_subject before_removal with
      | Some articles -> check_articles "the pre-removal prefix retains its historical articles"
          [ withdrawn; unrelated ] articles
      | None -> Alcotest.fail "the pre-removal ledger prefix was lost")

let test_an_unresolved_replacement_withholds_every_affected_id () =
  List.iter (fun collides ->
    with_world (fun base_path ->
      let first = article "the first superseded norm" in
      let unrelated = article "an unrelated norm" in
      let second = article "the second superseded norm" in
      let collision = article "the old norm at the replacement id" in
      let originals =
        [ first; unrelated; second ] @ if collides then [ collision ] else [] in
      List.iter (add ~base_path) originals;
      let replacement =
        article ~id:(if collides then collision.id else Article_id.generate ())
          "an unresolved replacement" in
      replace ~base_path ~by:"former-keeper" [ first; second ] replacement;
      let ledger, _ =
        check_loads ~base_path ~resolve_subject:(String.equal "lane-smith")
          ~status:Store.Isolated_history [ unrelated ] in
      check_isolation ~line_number:(List.length originals + 1) ~subject:"former-keeper"
        ~article_ids:[ first.id; second.id; replacement.id ] ledger;
      Alcotest.(check bool) "the replacement keeps its complete decoded history" true
        (ledger.entries =
          List.map (fun article -> Added article) originals
          @ [ Replaced { superseded = [ first.id; second.id ]; article = replacement;
                         by = "former-keeper"; at = 9.0; reason = None } ])))
    [ false; true ]

let test_an_unresolved_edit_does_not_revive_the_previous_text () =
  with_world (fun base_path ->
      let original = article "the previous text" in
      let unrelated = article "an unrelated norm" in
      let edit = article ~id:original.id ~author:"unknown-author" "the disputed edit" in
      add ~base_path original;
      add ~base_path unrelated;
      add ~base_path edit;
      let ledger, _ =
        check_loads ~base_path ~resolve_subject:(String.equal "lane-smith")
          ~status:Store.Isolated_history [ unrelated ] in
      Alcotest.(check bool) "both versions remain in history" true
        (ledger.entries = [ Added original; Added unrelated; Added edit ]);
      check_isolation ~line_number:3 ~subject:"unknown-author"
        ~article_ids:[ original.id ] ledger;
      let repeated =
        article ~id:original.id ~author:"another-unknown-author" "another disputed edit" in
      add ~base_path repeated;
      let repeated_ledger, _ =
        check_loads ~base_path ~resolve_subject:(String.equal "lane-smith")
          ~status:Store.Isolated_history [ unrelated ] in
      Alcotest.(check bool) "repeated isolation preserves every disputed edit" true
        (repeated_ledger.entries = ledger.entries @ [ Added repeated ]);
      Alcotest.(check (list (pair int string))) "both unresolved lines remain reported"
        [ 3, "unknown-author"; 4, "another-unknown-author" ]
        (List.map (fun (line : Store.isolated_line) -> line.line_number, line.subject)
           repeated_ledger.isolated))

let test_a_resolved_replacer_cannot_admit_an_unresolved_author () =
  with_world (fun base_path ->
      let original = article "the superseded norm" in
      let unrelated = article "an unrelated norm" in
      let replacement = article ~author:"unknown-author" "the disputed replacement" in
      add ~base_path original;
      add ~base_path unrelated;
      replace ~base_path ~by:"critic" [ original ] replacement;
      let resolve_subject subject = List.mem subject [ "lane-smith"; "critic" ] in
      let ledger, _ =
        check_loads ~base_path ~resolve_subject
          ~status:Store.Isolated_history [ unrelated ] in
      check_isolation ~line_number:3 ~subject:"unknown-author"
        ~article_ids:[ original.id; replacement.id ] ledger;
      Alcotest.(check bool) "the resolved mover and unresolved author remain in history" true
        (ledger.entries =
          [ Added original; Added unrelated;
            Replaced { superseded = [ original.id ]; article = replacement;
                       by = "critic"; at = 9.0; reason = None } ]))

let test_articles_only_load_folds_out_isolated_lines () =
  with_world (fun base_path ->
      add ~base_path (article "a norm the world holds");
      add ~base_path (article ~author:"codex-operator" "a norm from outside the tool");
      Alcotest.(check (list string))
        "the prompt load holds the roster's norm only" [ "a norm the world holds" ]
        (article_texts
           (load_articles_or_fail ~base_path
              ~resolve_subject:(String.equal "lane-smith") ())))

let () =
  Alcotest.run "world_constitution_store"
    [ ( "paths",
        [ Alcotest.test_case "ledger is base-path scoped" `Quick
            test_ledger_path_is_base_path_scoped;
        ] );
      ( "folding",
        [ Alcotest.test_case "a world without a ledger has no articles" `Quick
            test_a_world_without_a_ledger_has_no_articles;
          Alcotest.test_case "written norms come back in order" `Quick
            test_written_norms_come_back_in_order;
          Alcotest.test_case "removing takes a norm out of force" `Quick
            test_removing_takes_a_norm_out_of_force;
          Alcotest.test_case "rewriting a held norm edits it in place" `Quick
            test_rewriting_a_held_norm_edits_it_in_place;
          Alcotest.test_case "a norm written again after removal returns last"
            `Quick test_a_norm_written_again_after_removal_returns_at_the_end;
          Alcotest.test_case "a write built on a stale read is refused" `Quick
            test_a_write_built_on_a_stale_read_is_refused;
          Alcotest.test_case "articles-only load folds the same articles" `Quick
            test_articles_only_load_folds_the_same_articles;
          Alcotest.test_case "articles-only load of a missing ledger is empty"
            `Quick test_articles_only_load_of_a_missing_ledger_is_empty;
          Alcotest.test_case "a position reads back the articles held then" `Quick
            test_a_position_reads_back_the_articles_held_then;
          Alcotest.test_case "a position the ledger no longer begins with reads nothing"
            `Quick test_a_position_the_ledger_no_longer_begins_with_reads_nothing;
          Alcotest.test_case "replacing retires the bundle, adds the replacement"
            `Quick test_replacing_retires_the_bundle_and_adds_the_replacement;
          Alcotest.test_case "replacing keeps unrelated norms in place" `Quick
            test_replacing_keeps_unrelated_norms_in_place;
        ] );
      ( "isolation",
        [ Alcotest.test_case "a line from outside the roster is isolated, not dropped"
            `Quick test_a_line_from_outside_the_roster_is_isolated_not_dropped;
          Alcotest.test_case "an unresolved removal withholds without erasing history" `Quick
            test_an_unresolved_removal_withholds_without_erasing_history;
          Alcotest.test_case "an unresolved replacement withholds every affected id" `Quick
            test_an_unresolved_replacement_withholds_every_affected_id;
          Alcotest.test_case "an unresolved edit does not revive the previous text" `Quick
            test_an_unresolved_edit_does_not_revive_the_previous_text;
          Alcotest.test_case "a resolved replacer cannot admit an unresolved author" `Quick
            test_a_resolved_replacer_cannot_admit_an_unresolved_author;
          Alcotest.test_case "articles-only load folds out isolated lines" `Quick
            test_articles_only_load_folds_out_isolated_lines;
        ] );
      ( "rejections",
        [ Alcotest.test_case "a broken line is reported, not dropped" `Quick
            test_a_line_that_does_not_decode_is_reported_not_dropped;
          Alcotest.test_case "an unterminated last line is reported as such" `Quick
            test_an_unterminated_last_line_is_reported_as_such;
          Alcotest.test_case "an article is added after an unfinished last line" `Quick
            test_an_article_is_added_after_an_unfinished_last_line;
          Alcotest.test_case
            "an article is added to a ledger that is only an unfinished line" `Quick
            test_an_article_is_added_to_a_ledger_that_is_only_an_unfinished_line;
          Alcotest.test_case "an unfinished last line that reads whole is not held" `Quick
            test_an_unfinished_last_line_that_reads_whole_is_not_held;
        ] );
    ]
