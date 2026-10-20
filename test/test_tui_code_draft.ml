open Alcotest

module Draft = Masc_tui_code_draft
module Editor = Masc_tui_editor

let address : Draft.address =
  { base_path = "/workspace"; masc_root = "/workspace/.masc"
  ; scope = Draft.Code_scope_project; path = "src/program.ml" }

let original : Draft.source =
  { text = "\tlet original = \"cafe\204\129🙂\"\r\n"; revision = "original-revision" }

let candidate = "\tlet edited = \"한글🙂\"\r\n\000end\n"

let ok = function Ok value -> value | Error detail -> fail detail

let refused label result = check bool label true (Result.is_error result)

let retained = function
  | Draft.Retained draft -> draft
  | Draft.Ignored -> fail "current submission was ignored"
  | Draft.Committed _ -> fail "failed submission was committed"

let ignored label = function
  | Draft.Ignored -> ()
  | Draft.Retained _ | Draft.Committed _ -> fail label

let check_source label (expected : Draft.source) (actual : Draft.source) =
  check string (label ^ " bytes") expected.text actual.text;
  check string (label ^ " revision") expected.revision actual.revision

let fresh () = Draft.create ~address ~source:original
let edited () = Draft.edit candidate (fresh ()) |> ok

let test_exact_bytes_and_empty_source () =
  List.iter (fun text ->
    let source : Draft.source = { text; revision = "observed" } in
    let draft = Draft.create ~address ~source in
    check_source "captured original" source (Draft.base draft);
    check string "draft starts with exact response bytes" text (Draft.text draft);
    let changed = Draft.edit candidate draft |> ok in
    check string "candidate keeps CRLF, Unicode and NUL bytes" candidate (Draft.text changed);
    check_source "editing does not rewrite the base" source (Draft.base changed);
    let empty = Draft.edit "" changed |> ok in
    let saving, ticket = Draft.begin_save empty |> ok in
    match Draft.complete ticket (Draft.Save_succeeded "empty-revision") saving with
    | Draft.Committed actual ->
        check_source "empty source is a committed file"
          { text = ""; revision = "empty-revision" } actual
    | Draft.Ignored | Draft.Retained _ -> fail "empty draft must be saveable")
    [""; original.text; "\000\255\r\n"]

let isolated_addresses =
  [ { address with base_path = "/other" }
  ; { address with masc_root = "/workspace/other.masc" }
  ; { address with path = "src/other.ml" }
  ; { address with scope = Draft.Code_scope_keeper "alpha" }
  ; { address with scope = Draft.Code_scope_keeper "beta" }
  ; { address with scope = Draft.Code_scope_repo "alpha" }
  ; { address with scope = Draft.Code_scope_repo "beta" }
  ]

let test_address_and_ticket_isolation () =
  check bool "equal complete address" true (Draft.equal_address address { address with path = address.path });
  let _, old_ticket = Draft.begin_save (edited ()) |> ok in
  List.iter (fun other ->
    check bool "every workspace/scope/path coordinate participates" false
      (Draft.equal_address address other);
    let replacement = Draft.create ~address:other ~source:original in
    let replacement = Draft.edit "replacement candidate" replacement |> ok in
    let saving, ticket = Draft.begin_save replacement |> ok in
    ignored "a submission cannot settle another workspace address"
      (Draft.complete old_ticket (Draft.Save_succeeded "foreign") saving);
    check bool "replacement retains its full address" true
      (Draft.equal_address other (Draft.address saving));
    match Draft.complete ticket (Draft.Save_succeeded "owned") saving with
    | Draft.Committed actual -> check_source "replacement submission"
        { text = "replacement candidate"; revision = "owned" } actual
    | Draft.Ignored | Draft.Retained _ -> fail "replacement lost its own ticket")
    isolated_addresses;
  let keeper = { address with scope = Draft.Code_scope_keeper "alpha" } in
  let repo = { address with scope = Draft.Code_scope_repo "alpha" } in
  check bool "equal owner spelling does not merge Keeper and repository scopes"
    false (Draft.equal_address keeper repo)

let test_pending_submission_is_immutable () =
  let draft = edited () in
  let saving, _ = Draft.begin_save draft |> ok in
  check bool "editable draft may be discarded" true (Draft.can_discard draft);
  check bool "pending submission cannot be discarded" false (Draft.can_discard saving);
  refused "pending submission cannot be edited" (Draft.edit "changed while pending" saving);
  refused "pending submission cannot be sent twice" (Draft.begin_save saving);
  refused "pending submission cannot adopt another revision" (Draft.adopt_current saving);
  let observed = Draft.observe { text = "new server bytes"; revision = "new-server" } saving in
  check bool "observation cannot replace a pending submission" true (observed == saving);
  check_source "pending base remains original" original (Draft.base observed);
  check string "pending candidate stays exact" candidate (Draft.text observed)

let test_refusal_retry_and_duplicate_ticket () =
  let first, old_ticket = Draft.begin_save (edited ()) |> ok in
  let rejected = Draft.complete old_ticket (Draft.Save_refused "not admitted") first |> retained in
  check_source "refusal retains original" original (Draft.base rejected);
  check string "refusal retains candidate" candidate (Draft.text rejected);
  check bool "settled refused draft may be discarded" true (Draft.can_discard rejected);
  ignored "duplicate refusal cannot settle the completed submission"
    (Draft.complete old_ticket (Draft.Save_succeeded "late") rejected);
  let newer = Draft.edit "newer candidate" rejected |> ok in
  let second, current_ticket = Draft.begin_save newer |> ok in
  ignored "old success cannot settle a replacement submission"
    (Draft.complete old_ticket (Draft.Save_succeeded "late") second);
  let independent, foreign_ticket = Draft.begin_save (edited ()) |> ok in
  ignored "same address and content do not make a new ticket interchangeable"
    (Draft.complete foreign_ticket (Draft.Save_conflict "foreign") second);
  ignored "current ticket cannot settle another draft"
    (Draft.complete current_ticket (Draft.Save_succeeded "foreign") independent);
  match Draft.complete current_ticket (Draft.Save_succeeded "newer-revision") second with
  | Draft.Committed actual -> check_source "only current exact submission commits"
      { text = "newer candidate"; revision = "newer-revision" } actual
  | Draft.Ignored | Draft.Retained _ -> fail "current reply did not commit"

let test_conflict_uncertainty_require_explicit_adoption () =
  List.iter (fun outcome ->
    let saving, ticket = Draft.begin_save (edited ()) |> ok in
    let review = Draft.complete ticket outcome saving |> retained in
    check_source "review retains original base" original (Draft.base review);
    check string "review retains candidate" candidate (Draft.text review);
    check bool "settled review can be discarded" true (Draft.can_discard review);
    (match Draft.phase review, outcome with
     | Draft.Needs_review (Draft.Conflict detail, None), Draft.Save_conflict expected
     | Draft.Needs_review (Draft.Uncertain detail, None), Draft.Save_uncertain expected ->
         check string "precise review reason survives" expected detail
     | (Draft.Editable | Draft.Saving _ | Draft.Rejected _
       | Draft.Needs_review ((Draft.Conflict _ | Draft.Uncertain _), (None | Some _))),
       (Draft.Save_succeeded _ | Draft.Save_refused _ | Draft.Save_conflict _ | Draft.Save_uncertain _) ->
         fail "save failure did not retain its review reason");
    refused "review cannot retry against the stale base" (Draft.begin_save review);
    refused "adoption needs a fresh observation" (Draft.adopt_current review);
    ignored "late success cannot discharge a conflict or uncertain outcome"
      (Draft.complete ticket (Draft.Save_succeeded "late") review);
    let current : Draft.source = { text = "server changed elsewhere\r\n"; revision = "fresh-server" } in
    let observed = Draft.observe current review in
    check_source "observation alone does not adopt" original (Draft.base observed);
    check string "observation preserves candidate" candidate (Draft.text observed);
    refused "fresh observation alone cannot resave" (Draft.begin_save observed);
    let revised = Draft.edit "explicitly compared candidate\r\n" observed |> ok in
    refused "editing during comparison does not clear review" (Draft.begin_save revised);
    let adopted = Draft.adopt_current revised |> ok in
    check_source "explicit adoption supplies observed revision" current (Draft.base adopted);
    check string "adoption retains the candidate" "explicitly compared candidate\r\n" (Draft.text adopted);
    let next, next_ticket = Draft.begin_save adopted |> ok in
    ignored "previous submission remains retired after adoption"
      (Draft.complete ticket (Draft.Save_succeeded "late") next);
    match Draft.complete next_ticket (Draft.Save_succeeded "committed-after-review") next with
    | Draft.Committed actual -> check_source "acknowledgement carries submitted bytes"
        { text = "explicitly compared candidate\r\n"; revision = "committed-after-review" } actual
    | Draft.Ignored | Draft.Retained _ -> fail "adopted revision could not save")
    [Draft.Save_conflict "revision conflict"; Draft.Save_uncertain "publication may have happened"]

let test_observation_detects_changed_revision () =
  let draft = edited () in
  check bool "same-revision observation leaves the draft alone" true
    (Draft.observe original draft == draft);
  let current : Draft.source = { text = "externally edited"; revision = "changed" } in
  let observed = Draft.observe current draft in
  refused "changed revision requires review before first submission" (Draft.begin_save observed);
  check_source "base remains the originally read source" original (Draft.base observed);
  check_source "adoption uses the latest observed source" current
    (Draft.base (Draft.adopt_current observed |> ok))

let ending_testable =
  let pp formatter = function
    | Draft.Empty_source -> Format.pp_print_string formatter "empty source"
    | Draft.Final_lf -> Format.pp_print_string formatter "final LF"
    | Draft.Final_crlf -> Format.pp_print_string formatter "final CRLF"
    | Draft.No_final_newline -> Format.pp_print_string formatter "no final newline"
  in
  testable pp ( = )

let test_source_endings_are_distinct_and_exact () =
  List.iter (fun (text, expected) ->
    check ending_testable "ending describes the source's actual EOF bytes"
      expected (Draft.ending text);
    let source : Draft.source = { text; revision = "source-ending" } in
    let draft = Draft.create ~address ~source in
    let saving, ticket = Draft.begin_save draft |> ok in
    match Draft.complete ticket (Draft.Save_succeeded "saved-ending") saving with
    | Draft.Committed actual ->
        check string "EOF inspection and save never normalize source bytes" text actual.text;
        check ending_testable "committed source retains its EOF distinction"
          expected (Draft.ending actual.text)
    | Draft.Ignored | Draft.Retained _ -> fail "exact EOF source did not commit")
    [ "", Draft.Empty_source
    ; "\n", Draft.Final_lf
    ; "\r\n", Draft.Final_crlf
    ; "let x = 1\n", Draft.Final_lf
    ; "\t한글 cafe\204\129🙂\r\n", Draft.Final_crlf
    ; "let x = 1", Draft.No_final_newline
    ; "let x = 1\r", Draft.No_final_newline
    ; "let x = 1\n\r", Draft.No_final_newline
    ; "\000\255\n", Draft.Final_lf
    ; "\r\r\n", Draft.Final_crlf
    ]

let test_draft_owner_survives_transitions_but_not_replacement () =
  let original_draft = fresh () in
  let changed = Draft.edit candidate original_draft |> ok in
  let current : Draft.source = { text = "external source"; revision = "external-revision" } in
  let observed = Draft.observe current changed in
  let adopted = Draft.adopt_current observed |> ok in
  let saving, ticket = Draft.begin_save adopted |> ok in
  let rejected = Draft.complete ticket (Draft.Save_refused "not admitted") saving |> retained in
  List.iter (fun next ->
    check bool "immutable transitions keep the same draft owner" true
      (Draft.same_draft original_draft next);
    check bool "draft owner comparison is symmetric" true
      (Draft.same_draft next original_draft))
    [original_draft; changed; observed; adopted; saving; rejected];
  let replacement = Draft.create ~address:(Draft.address original_draft)
      ~source:(Draft.base original_draft) in
  check bool "identical address and source create a distinct draft owner" false
    (Draft.same_draft original_draft replacement);
  check bool "same address alone cannot reclaim an old owner" true
    (Draft.equal_address (Draft.address original_draft) (Draft.address replacement));
  let replacement = Draft.edit candidate replacement |> ok in
  let replacement, replacement_ticket = Draft.begin_save replacement |> ok in
  check bool "new immutable edits keep the replacement owner distinct" false
    (Draft.same_draft changed replacement);
  ignored "replacement cannot borrow the original save ticket"
    (Draft.complete ticket (Draft.Save_succeeded "late original") replacement);
  ignored "original owner cannot borrow replacement ticket"
    (Draft.complete replacement_ticket (Draft.Save_succeeded "foreign") saving)

let with_editor command f =
  let previous = List.map (fun name -> name, Sys.getenv_opt name) ["EDITOR"; "VISUAL"] in
  Unix.putenv "EDITOR" command;
  Unix.putenv "VISUAL" "";
  Fun.protect ~finally:(fun () -> List.iter (fun (name, value) ->
    match value with Some value -> Unix.putenv name value | None -> Unix.unsetenv name) previous) f

let write_bytes path content =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content)

let read_bytes path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let with_editor_files f =
  let dir = Filename.temp_file "code-draft-editor-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () ->
    Sys.readdir dir |> Array.iter (fun name -> Sys.remove (Filename.concat dir name));
    Unix.rmdir dir) (fun () -> f dir)

let test_editor_roundtrip_preserves_exact_source () =
  with_editor_files (fun dir ->
    let script = Filename.concat dir "editor.sh" in
    let submitted = Filename.concat dir "submitted" in
    let replacement = Filename.concat dir "replacement" in
    let temporary = Filename.concat dir "temporary-path" in
    let left_terminal = Filename.concat dir "terminal-restored" in
    let child_ran = Filename.concat dir "child-ran" in
    write_bytes replacement candidate;
    write_bytes script (Printf.sprintf
      "#!/bin/sh\nset -eu\ntest -f %s\nprintf '%%s' \"$1\" > %s\ncp \"$1\" %s\ncp %s \"$1\"\nprintf child > %s\n"
      (Filename.quote left_terminal) (Filename.quote temporary) (Filename.quote submitted)
      (Filename.quote replacement) (Filename.quote child_ran));
    let calls = ref [] in
    let result = with_editor ("/bin/sh " ^ Filename.quote script) (fun () ->
      Editor.roundtrip ~suffix:".ml"
        ~restore:(fun () -> calls := "restore" :: !calls; write_bytes left_terminal "ready")
        ~reenter:(fun () ->
          check bool "child completes before terminal reentry" true (Sys.file_exists child_ran);
          calls := "reenter" :: !calls)
        original.text) in
    (match result with
     | Ok text -> check string "editor returns exact replacement bytes" candidate text
     | Error abort -> fail (Editor.abort_detail abort));
    check string "editor receives exact original bytes" original.text (read_bytes submitted);
    check (list string) "terminal ownership brackets the child" ["reenter"; "restore"] !calls;
    check bool "owned source temporary file is removed" false (Sys.file_exists (read_bytes temporary)))

exception Restore_failed

let test_editor_reenters_after_restore_exception () =
  with_editor_files (fun dir ->
    let child_marker = Filename.concat dir "child-ran" in
    let script = Filename.concat dir "editor.sh" in
    write_bytes script ("#!/bin/sh\nprintf child > " ^ Filename.quote child_marker ^ "\n");
    let calls = ref [] in
    with_editor ("/bin/sh " ^ Filename.quote script) (fun () ->
      match Editor.roundtrip
        ~restore:(fun () -> calls := "restore" :: !calls; raise Restore_failed)
        ~reenter:(fun () -> calls := "reenter" :: !calls) original.text with
      | exception Restore_failed -> ()
      | Ok _ | Error _ -> fail "restore exception must propagate");
    check (list string) "exception still returns terminal ownership" ["reenter"; "restore"] !calls;
    check bool "child cannot run when restore fails" false (Sys.file_exists child_marker))

let () =
  run "tui-code-draft"
    [ "draft ownership",
      [ test_case "exact bytes and empty sources" `Quick test_exact_bytes_and_empty_source
      ; test_case "full address and submission isolation" `Quick test_address_and_ticket_isolation
      ; test_case "pending submission cannot edit, discard or adopt" `Quick test_pending_submission_is_immutable
      ; test_case "refusal retry rejects duplicate and foreign replies" `Quick test_refusal_retry_and_duplicate_ticket
      ; test_case "conflict and uncertainty require explicit adoption" `Quick test_conflict_uncertainty_require_explicit_adoption
      ; test_case "fresh observation cannot silently rebase edits" `Quick test_observation_detects_changed_revision
      ; test_case "EOF newline facts preserve exact bytes" `Quick test_source_endings_are_distinct_and_exact
      ; test_case "immutable draft owner survives edits but not replacement" `Quick test_draft_owner_survives_transitions_but_not_replacement
      ]
    ; "actual editor child",
      [ test_case "exact file bytes and terminal handoff" `Quick test_editor_roundtrip_preserves_exact_source
      ; test_case "restore exception still reenters" `Quick test_editor_reenters_after_restore_exception
      ]
    ]
