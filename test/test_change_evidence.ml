(** A pull request as a form of evidence.

    The work this workspace produces lands in a repository, and the evidence
    grammar could read only files inside the producer's sandbox. A producer
    saying "it is in #30715" had its evidence recorded as an invalid reference,
    so neither the authority nor the operator ever saw what it named.

    The reference is recorded, not fetched. The submit boundary runs inside the
    backlog lock, and a repository that answers slowly would hold every other
    transition in the workspace behind it. *)
module VS = Workspace_verification_store

let check = Alcotest.check
let base_path = "/tmp/masc-change-evidence-fixture"
let worker = "goo-yang-bong"

let classify reference = VS.classify_evidence_reference reference

(* Through the exported submit-boundary call, so the test exercises the path
   the producer actually takes rather than an inner helper. *)
let snapshot reference =
  match VS.snapshot_submitted_evidence_json ~base_path ~worker [ reference ] with
  | `List [ item ] ->
    (match VS.submitted_evidence_item_of_yojson item with
     | Ok item -> item
     | Error detail -> Alcotest.failf "decode: %s" detail)
  | _ -> Alcotest.fail "one reference snapshots to one item"

let identity item =
  match
    VS.submitted_evidence_identity_lines (`List [ VS.submitted_evidence_item_to_yojson item ])
  with
  | Ok [ line ] -> line
  | Ok lines -> Alcotest.failf "one item, %d lines" (List.length lines)
  | Error detail -> Alcotest.failf "identity line: %s" detail

let test_the_grammar_reads_a_pull_request () =
  (match classify "change:jeong-sik/masc#30715" with
   | VS.Change_reference { repository; pull_request } ->
     check Alcotest.string "the repository" "jeong-sik/masc" repository;
     check Alcotest.int "the number" 30715 pull_request
   | _ -> Alcotest.fail "a pull request reference must be read as one");
  (* The form is the whole grammar: anything else stays unresolvable rather
     than being guessed into a repository and a number. *)
  List.iter
    (fun reference ->
       match classify reference with
       | VS.Unresolvable_reference -> ()
       | _ -> Alcotest.failf "%s must not read as a change" reference)
    [ "change:jeong-sik#1"
    ; "change:jeong-sik/masc"
    ; "change:jeong-sik/masc#"
    ; "change:jeong-sik/masc#0"
    ; "change:jeong-sik/masc#-3"
    ; "change:jeong-sik/masc#12a"
    ; "change:/masc#1"
    ; "change:jeong-sik/#1"
    ; "change:a/b/c#1"
    ; "change:"
    ]

(* What the change was worth before this: nothing. The same string snapshotted
   as a payload-free invalid reference, and the line an operator reads said
   only that something was unreadable — not which change the producer meant. *)
let test_the_reference_reaches_the_reader () =
  let item = snapshot "change:jeong-sik/masc#30715" in
  (match item with
   | VS.Evidence_change { repository; pull_request } ->
     check Alcotest.string "the repository is kept" "jeong-sik/masc" repository;
     check Alcotest.int "and the number" 30715 pull_request
   | other ->
     Alcotest.failf "a change reference must persist as one, got %s" (identity other));
  check Alcotest.string "and the line names the change"
    "change:jeong-sik/masc#30715" (identity item);
  check Alcotest.string "where it used to name nothing"
    "(unreadable: invalid_reference)"
    (identity (snapshot "https://github.com/jeong-sik/masc/pull/30715"))

(* The snapshot is persisted and read back by a different process. *)
let test_a_change_round_trips () =
  let item = VS.Evidence_change { repository = "jeong-sik/masc"; pull_request = 42 } in
  match VS.submitted_evidence_item_of_yojson (VS.submitted_evidence_item_to_yojson item) with
  | Ok decoded ->
    check Alcotest.string "the same item comes back" (identity item) (identity decoded)
  | Error detail -> Alcotest.failf "decode: %s" detail

(* A stored record whose fields disagree with the type is rejected rather than
   repaired: a change that reads back as "#0 of nowhere" is worse than one that
   fails to read. *)
let test_a_malformed_stored_change_is_refused () =
  List.iter
    (fun (label, json) ->
       match VS.submitted_evidence_item_of_yojson json with
       | Ok _ -> Alcotest.failf "%s must not decode" label
       | Error _ -> ())
    [ "no repository", `Assoc [ "kind", `String "change"; "pull_request", `Int 1 ]
    ; "no number", `Assoc [ "kind", `String "change"; "repository", `String "a/b" ]
    ; ( "number zero"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "pull_request", `Int 0
          ] )
    ; ( "a field nobody writes"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "pull_request", `Int 1
          ; "merged", `Bool true
          ] )
    ]

let () =
  Alcotest.run "change_evidence"
    [ ( "the reference"
      , [ Alcotest.test_case "reads a pull request" `Quick
            test_the_grammar_reads_a_pull_request
        ; Alcotest.test_case "reaches whoever reads the evidence" `Quick
            test_the_reference_reaches_the_reader
        ] )
    ; ( "the record"
      , [ Alcotest.test_case "round trips" `Quick test_a_change_round_trips
        ; Alcotest.test_case "a malformed stored change is refused" `Quick
            test_a_malformed_stored_change_is_refused
        ] )
    ]
