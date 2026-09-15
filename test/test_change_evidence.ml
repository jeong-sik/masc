(** A pull request as a form of evidence, and who reads it.

    The work this workspace produces lands in a repository, and the evidence
    grammar could read only files inside the producer's sandbox. A producer
    saying "it is in #30715" had its evidence recorded as an invalid reference,
    so neither the authority nor the operator ever saw what it named
    (RFC-0453 §3.5).

    The reference and the reading of it are split across two places, and the
    split is the point. The producer's submit boundary runs inside the backlog
    lock — [workspace_task_transitions.ml] holds it through the
    verification-request hook — and that lock is a lease with a wall-clock
    expiry, so a repository answering slowly there would put every other claim,
    release and verdict in the workspace behind it. The submit boundary
    therefore records the reference and looks at nothing. The judging lane
    holds no lock, so it is the one that asks GitHub, and it asks about the
    repository as it stands when the verdict is being formed. *)
module VS = Workspace_verification_store
module Lookup = Masc.Keeper_github_change_lookup
module Authority = Masc.Completion_authority_agent.For_testing

let check = Alcotest.check
let base_path = "/tmp/masc-change-evidence-fixture"
let worker = "goo-yang-bong"
let repository = "jeong-sik/masc"
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
    VS.submitted_evidence_identity_lines
      (`List [ VS.submitted_evidence_item_to_yojson item ])
  with
  | Ok [ line ] -> line
  | Ok lines -> Alcotest.failf "one item, %d lines" (List.length lines)
  | Error detail -> Alcotest.failf "identity line: %s" detail

let test_the_grammar_reads_a_pull_request () =
  (match classify "change:jeong-sik/masc#30715" with
   | VS.Change_reference { repository = read; pull_request } ->
     check Alcotest.string "the repository" repository read;
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
   | VS.Evidence_change { repository = kept; pull_request; lookup = _ } ->
     check Alcotest.string "the repository is kept" repository kept;
     check Alcotest.int "and the number" 30715 pull_request
   | other ->
     Alcotest.failf "a change reference must persist as one, got %s" (identity other));
  check Alcotest.string "where it used to name nothing"
    "(unreadable: invalid_reference)"
    (identity (snapshot "https://github.com/jeong-sik/masc/pull/30715"))

(* The lock argument, pinned. If a lookup is ever moved back to submission this
   is the test that has to be deleted first. *)
let test_the_submit_boundary_reads_nothing () =
  match snapshot "change:jeong-sik/masc#30715" with
  | VS.Evidence_change { lookup = VS.Change_not_looked_up; _ } as item ->
    check Alcotest.string "and the line says so"
      "change:jeong-sik/masc#30715 (not looked up)" (identity item)
  | other ->
    Alcotest.failf "the submit boundary must not look, got %s" (identity other)

(* The snapshot is persisted and read back by a different process. Each answer
   a lookup can produce has to survive that round trip, since the judge's
   record is written from it. *)
let test_a_change_round_trips () =
  List.iter
    (fun lookup ->
       let item = VS.Evidence_change { repository; pull_request = 42; lookup } in
       match
         VS.submitted_evidence_item_of_yojson (VS.submitted_evidence_item_to_yojson item)
       with
       | Ok decoded ->
         check Alcotest.string "the same item comes back" (identity item)
           (identity decoded)
       | Error detail -> Alcotest.failf "decode: %s" detail)
    [ VS.Change_not_looked_up
    ; VS.Change_lookup_failed "GitHub answered HTTP 503"
    ; VS.Change_seen
        { merged = true
        ; merge_commit = Some "c5bf793faa"
        ; title = "the authority reads the change"
        ; changed_files = 7
        }
    ; VS.Change_seen
        { merged = false; merge_commit = None; title = "still open"; changed_files = 1 }
    ]

(* A stored record whose fields disagree with the type is rejected rather than
   repaired: a change that reads back as "#0 of nowhere" is worse than one that
   fails to read. *)
let test_a_malformed_stored_change_is_refused () =
  List.iter
    (fun (label, json) ->
       match VS.submitted_evidence_item_of_yojson json with
       | Ok _ -> Alcotest.failf "%s must not decode" label
       | Error _ -> ())
    [ ( "no repository"
      , `Assoc
          [ "kind", `String "change"
          ; "pull_request", `Int 1
          ; "lookup", `String "not_looked_up"
          ] )
    ; ( "no number"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "lookup", `String "not_looked_up"
          ] )
    ; ( "number zero"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "pull_request", `Int 0
          ; "lookup", `String "not_looked_up"
          ] )
    ; ( "no lookup"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "pull_request", `Int 1
          ] )
    ; ( "a lookup nobody writes"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "pull_request", `Int 1
          ; "lookup", `String "in_progress"
          ] )
    ; ( "seen without changed_files"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "pull_request", `Int 1
          ; "lookup", `String "seen"
          ; "merged", `Bool true
          ; "title", `String "a change"
          ] )
    ; ( "a field nobody writes"
      , `Assoc
          [ "kind", `String "change"
          ; "repository", `String "a/b"
          ; "pull_request", `Int 1
          ; "lookup", `String "not_looked_up"
          ; "reviewers", `Int 3
          ] )
    ]

(* ---- the lookup itself, with the transport stubbed ---------------------- *)

let pull_body =
  `Assoc
    [ "merged", `Bool true
    ; "merge_commit_sha", `String "89abcdef"
    ; "title", `String "the authority reads the change it is judging"
    ; "changed_files", `Int 12
    ]

let answering status body ~url:_ ~headers:_ = Ok (status, body)

let looked_up ?(token = Ok "gho_fixture") http_get =
  Lookup.lookup ~http_get ~token ~repository ~pull_request:30715

let failure_detail = function
  | VS.Change_lookup_failed detail -> detail
  | VS.Change_not_looked_up -> Alcotest.fail "lookup returned 'nobody looked'"
  | VS.Change_seen _ -> Alcotest.fail "expected a failure, the lookup succeeded"

let test_a_pull_request_is_read_from_the_answer () =
  match looked_up (answering 200 (Yojson.Safe.to_string pull_body)) with
  | VS.Change_seen { merged; merge_commit; title; changed_files } ->
    check Alcotest.bool "merged" true merged;
    check Alcotest.(option string) "the merge commit" (Some "89abcdef") merge_commit;
    check Alcotest.string "the title"
      "the authority reads the change it is judging" title;
    check Alcotest.int "the file count" 12 changed_files
  | other -> Alcotest.failf "a 200 must be read: %s" (failure_detail other)

(* An open pull request has no merge commit. That is an answer, not a failure. *)
let test_an_unmerged_pull_request_is_still_an_answer () =
  let body =
    `Assoc
      [ "merged", `Bool false
      ; "merge_commit_sha", `Null
      ; "title", `String "still open"
      ; "changed_files", `Int 0
      ]
  in
  match looked_up (answering 200 (Yojson.Safe.to_string body)) with
  | VS.Change_seen { merged; merge_commit; changed_files; _ } ->
    check Alcotest.bool "not merged" false merged;
    check Alcotest.(option string) "and no merge commit" None merge_commit;
    check Alcotest.int "and no files yet" 0 changed_files
  | other -> Alcotest.failf "an open change is readable: %s" (failure_detail other)

(* Every way the ask can go wrong names itself. The authority renders this
   detail beside the question, so "0 files, not merged" must never stand in
   for "the answer did not arrive". *)
let test_every_failure_says_what_went_wrong () =
  let contains needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec scan i = i + n <= h && (String.equal (String.sub haystack i n) needle || scan (i + 1)) in
    n = 0 || scan 0
  in
  let says label needle lookup =
    let detail = failure_detail lookup in
    if not (contains needle detail)
    then Alcotest.failf "%s: %S does not name %S" label detail needle
  in
  says "a transport error" "connection refused"
    (looked_up (fun ~url:_ ~headers:_ -> Error "connection refused"));
  says "a missing change" "30715"
    (looked_up (answering 404 "{\"message\":\"Not Found\"}"));
  says "another status" "503" (looked_up (answering 503 ""));
  says "an unreadable body" "unreadable JSON" (looked_up (answering 200 "{not json"));
  says "a missing field" "changed_files"
    (looked_up
       (answering 200
          (Yojson.Safe.to_string
             (`Assoc [ "merged", `Bool true; "title", `String "t" ]))));
  says "a field of the wrong type" "merged"
    (looked_up
       (answering 200
          (Yojson.Safe.to_string
             (`Assoc
               [ "merged", `String "yes"
               ; "title", `String "t"
               ; "changed_files", `Int 1
               ]))))

(* A producer with no GitHub identity is a typed failure, and nothing is sent:
   the alternative is asking as whoever the runtime happens to be, which reads
   a repository the producer may not be allowed to see. *)
let test_no_token_asks_nobody () =
  let asked = ref 0 in
  let http_get ~url:_ ~headers:_ =
    incr asked;
    Ok (200, "{}")
  in
  let lookup = looked_up ~token:(Error "no hosts file") http_get in
  check Alcotest.string "the failure names the token"
    "no GitHub token for this producer: no hosts file" (failure_detail lookup);
  check Alcotest.int "and GitHub was not asked" 0 !asked

(* ---- who does the reading ---------------------------------------------- *)

let request : VS.request_header =
  { id = "ver-1"; task_id = "task-1"; worker; created_at = 0. }

let available items = VS.Evidence_available { request; items }

let items_of = function
  | VS.Evidence_available { items; _ } -> items
  | VS.Evidence_unavailable _ -> Alcotest.fail "the snapshot went unavailable"

let seen title =
  VS.Change_seen { merged = true; merge_commit = None; title; changed_files = 1 }

(* The judging lane replaces "nobody looked" with what it found, leaves every
   other item alone, and keeps the order the producer filed. *)
let test_the_judge_reads_the_unread_changes () =
  let asked = ref [] in
  let lookup ~repository ~pull_request =
    asked := (repository, pull_request) :: !asked;
    seen (Printf.sprintf "%s#%d" repository pull_request)
  in
  let filed =
    [ VS.Evidence_note "it is in two changes"
    ; VS.Evidence_change
        { repository; pull_request = 30715; lookup = VS.Change_not_looked_up }
    ; VS.Evidence_invalid_reference
    ; VS.Evidence_change
        { repository = "jeong-sik/kirin"
        ; pull_request = 8
        ; lookup = VS.Change_not_looked_up
        }
    ]
  in
  let read = Authority.read_changes_being_judged ~lookup (available filed) in
  check Alcotest.(list string) "each change carries what was found, in order"
    [ "note:it is in two changes"
    ; "change:jeong-sik/masc#30715 (merged)"
    ; "(unreadable: invalid_reference)"
    ; "change:jeong-sik/kirin#8 (merged)"
    ]
    (List.map identity (items_of read));
  check Alcotest.(list (pair string int)) "and each was asked for exactly once"
    [ repository, 30715; "jeong-sik/kirin", 8 ]
    (List.rev !asked)

(* An answer already in hand is not asked again, and a snapshot that never
   arrived has nothing to ask about. Both would otherwise spend a network call
   per review attempt. *)
let test_nothing_else_is_asked_about () =
  let asked = ref 0 in
  let lookup ~repository:_ ~pull_request:_ =
    incr asked;
    seen "should not happen"
  in
  let answered =
    [ VS.Evidence_change
        { repository; pull_request = 1; lookup = seen "already read" }
    ; VS.Evidence_change
        { repository
        ; pull_request = 2
        ; lookup = VS.Change_lookup_failed "GitHub answered HTTP 503"
        }
    ]
  in
  let read = Authority.read_changes_being_judged ~lookup (available answered) in
  check Alcotest.(list string) "the answers in hand are untouched"
    [ "change:jeong-sik/masc#1 (merged)"
    ; "change:jeong-sik/masc#2 (unreadable: GitHub answered HTTP 503)"
    ]
    (List.map identity (items_of read));
  let unavailable =
    VS.Evidence_unavailable { request_id = "ver-1"; reason = VS.Request_not_found }
  in
  (match Authority.read_changes_being_judged ~lookup unavailable with
   | VS.Evidence_unavailable { request_id; reason = VS.Request_not_found } ->
     check Alcotest.string "an unavailable snapshot comes back as it was" "ver-1"
       request_id
   | _ -> Alcotest.fail "an unavailable snapshot must stay unavailable");
  check Alcotest.int "and GitHub was never asked" 0 !asked

let () =
  Alcotest.run "change_evidence"
    [ ( "the reference"
      , [ Alcotest.test_case "reads a pull request" `Quick
            test_the_grammar_reads_a_pull_request
        ; Alcotest.test_case "reaches whoever reads the evidence" `Quick
            test_the_reference_reaches_the_reader
        ; Alcotest.test_case "is recorded without being read" `Quick
            test_the_submit_boundary_reads_nothing
        ] )
    ; ( "the record"
      , [ Alcotest.test_case "round trips" `Quick test_a_change_round_trips
        ; Alcotest.test_case "a malformed stored change is refused" `Quick
            test_a_malformed_stored_change_is_refused
        ] )
    ; ( "the lookup"
      , [ Alcotest.test_case "reads a pull request from the answer" `Quick
            test_a_pull_request_is_read_from_the_answer
        ; Alcotest.test_case "an unmerged change is still an answer" `Quick
            test_an_unmerged_pull_request_is_still_an_answer
        ; Alcotest.test_case "every failure says what went wrong" `Quick
            test_every_failure_says_what_went_wrong
        ; Alcotest.test_case "no token asks nobody" `Quick test_no_token_asks_nobody
        ] )
    ; ( "who reads it"
      , [ Alcotest.test_case "the judge reads the unread changes" `Quick
            test_the_judge_reads_the_unread_changes
        ; Alcotest.test_case "nothing else is asked about" `Quick
            test_nothing_else_is_asked_about
        ] )
    ]
