(** Pin for the [pull-request:] evidence form (masc#28989).

    The cross-verifier could only inspect local artifacts, so a keeper's
    Draft PR — the natural deliverable of dev work — was "a note, not
    proof" and three genuinely-completed submissions were rejected. The
    store now parses [pull-request:<canonical GitHub URL>] into a typed
    locator, fetches an independent snapshot through an inspector the
    composition root installs, and persists it as typed evidence.

    Pins: strict URL parsing (anything else is Unresolvable at submit),
    typed absence when no inspector is installed, snapshot serialization
    round-trip, and the completion-review boundary accepting the form. *)

open Alcotest
module Store = Workspace_verification_store

let classify = Store.classify_evidence_reference

let test_reference_parsing () =
  (match classify "pull-request:https://github.com/jeong-sik/masc/pull/28988" with
   | Store.Pull_request_reference { owner; repo; number } ->
     check string "owner" "jeong-sik" owner;
     check string "repo" "masc" repo;
     check int "number" 28988 number
   | _ -> fail "canonical pull-request reference must parse");
  List.iter
    (fun reference ->
      match classify reference with
      | Store.Unresolvable_reference -> ()
      | _ -> failf "%S must be unresolvable" reference)
    [ "pull-request:https://gitlab.com/o/r/pull/1"
    ; "pull-request:http://github.com/o/r/pull/1"
    ; "pull-request:https://github.com/o/r/pull/abc"
    ; "pull-request:https://github.com/o/r/pull/0"
    ; "pull-request:https://github.com/o/r/pull/1/files"
    ; "pull-request:https://github.com/o/r/issues/1"
    ; "pull-request:https://github.com/o/pull/1"
    ; "pull-request:"
    ]

let fake_snapshot url : Store.pull_request_snapshot =
  { url
  ; state = "open"
  ; merged = false
  ; draft = true
  ; head_sha = "abcdef1234"
  ; title = "fix: example"
  ; diff = "diff --git a/x b/x"
  ; diff_bytes = 18
  ; diff_truncated = false
  }

let snapshot_items references =
  Store.snapshot_submitted_evidence_json
    ~base_path:"/nonexistent-base-for-pull-request-items"
    ~worker:"pin-worker"
    references

let decode_items json =
  match Store.submitted_evidence_identity_lines json with
  | Ok lines -> lines
  | Error detail -> fail detail

let test_snapshot_and_roundtrip () =
  let reference = "pull-request:https://github.com/jeong-sik/masc/pull/28988" in
  (* Before any inspector is installed the reference stays typed absence,
     never a silent pass. This case must run before the install below. *)
  (match snapshot_items [ reference ] with
   | `List [ item ] ->
     (match Store.submitted_evidence_item_of_yojson item with
      | Ok
          (Store.Evidence_pull_request_unreadable
            { reason = Store.Pull_request_inspector_uninstalled; _ }) -> ()
      | Ok _ -> fail "uninstalled inspector must yield typed absence"
      | Error detail -> fail detail)
   | _ -> fail "expected one snapshot item");
  Store.install_pull_request_inspector (fun locator ->
    Ok (fake_snapshot (Store.pull_request_locator_url locator)));
  match snapshot_items [ reference; "note:done" ] with
  | `List [ pr_item; _note_item ] as json ->
    (match Store.submitted_evidence_item_of_yojson pr_item with
     | Ok (Store.Evidence_pull_request { reference = persisted; snapshot }) ->
       check string "reference survives" reference persisted;
       check string "url spelled from the locator"
         "https://github.com/jeong-sik/masc/pull/28988" snapshot.url;
       check string "state" "open" snapshot.state;
       check bool "draft" true snapshot.draft;
       check int "diff bytes" 18 snapshot.diff_bytes
     | Ok _ -> fail "expected a pull-request snapshot item"
     | Error detail -> fail detail);
    let lines = decode_items json in
    check int "two identity lines" 2 (List.length lines);
    (match lines with
     | first :: _ ->
       check bool "identity line names the reference and state" true
         (Astring.String.is_infix ~affix:"(open, head abcdef1234)" first)
     | [] -> fail "expected identity lines")
  | _ -> fail "expected two snapshot items"

let test_fetch_failure_roundtrip () =
  Store.install_pull_request_inspector (fun _ ->
    Error (Store.Pull_request_http_status 404));
  match snapshot_items [ "pull-request:https://github.com/o/r/pull/9" ] with
  | `List [ item ] ->
    (match Store.submitted_evidence_item_of_yojson item with
     | Ok
         (Store.Evidence_pull_request_unreadable
           { reason = Store.Pull_request_http_status 404; _ }) -> ()
     | Ok _ -> fail "expected a typed 404 fetch failure"
     | Error detail -> fail detail)
  | _ -> fail "expected one snapshot item"

let test_completion_review_accepts_the_form () =
  check bool "valid pull-request reference is resolvable" false
    (Masc_task_handlers.Tool_task_completion_review.unresolvable_evidence_ref
       "pull-request:https://github.com/jeong-sik/masc/pull/28988");
  check bool "malformed pull-request reference stays unresolvable" true
    (Masc_task_handlers.Tool_task_completion_review.unresolvable_evidence_ref
       "pull-request:https://example.com/pr/1")

let () =
  run
    "workspace_pull_request_evidence"
    [ ( "pull-request-evidence"
      , [ test_case "reference parsing" `Quick test_reference_parsing
        ; test_case
            "snapshot and roundtrip"
            `Quick
            test_snapshot_and_roundtrip
        ; test_case
            "fetch failure roundtrip"
            `Quick
            test_fetch_failure_roundtrip
        ; test_case
            "completion review accepts the form"
            `Quick
            test_completion_review_accepts_the_form
        ] )
    ]
