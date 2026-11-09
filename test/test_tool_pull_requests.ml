(** keeper_pull_requests_list: the placement table, the arguments, the answer
    built from a snapshot, and the tool definition against the code. Every case
    reads a hand-built snapshot; nothing here calls GitHub. *)

module R = Masc.Repository_pulls
module P = Masc.Repository_pulls_placement
module T = Masc.Tool_pull_requests

let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)
let check_strings = Alcotest.(check (list string))
let check_ints = Alcotest.(check (list int))

(* --- fixtures --- *)

let last_review ~commit login : R.latest_review =
  { reviewer = R.Actor_user login; verdict = R.Verdict_commented; commit_oid = commit }
;;

let reviews_of ?(truncated = false) reviews = R.Reviews_read { reviews; truncated }
let no_reviews = reviews_of []
let on_head = reviews_of [ last_review ~commit:(Some "head-1") "someone" ]
let on_older_commit = reviews_of [ last_review ~commit:(Some "head-0") "someone" ]
let cut_without_head = reviews_of ~truncated:true [ last_review ~commit:(Some "head-0") "someone" ]
let cut_with_head = reviews_of ~truncated:true [ last_review ~commit:(Some "head-1") "someone" ]

let dismissed_on_head =
  reviews_of
    [ { R.reviewer = R.Actor_user "someone"
      ; verdict = R.Verdict_dismissed
      ; commit_oid = Some "head-1"
      }
    ]
;;

let pull
      ?(draft = false)
      ?(checks = R.Checks_passing)
      ?(review = R.Review_none)
      ?(mergeable = R.Mergeable)
      ?(head_oid = Some "head-1")
      ?(reviews = no_reviews)
      ?(author = None)
      ?(title = Some "title")
      number
  : R.pull_request
  =
  { repo_slug = "jeong-sik/masc"
  ; number
  ; draft
  ; checks
  ; review
  ; mergeable
  ; author
  ; title
  ; head_oid
  ; reviews
  }
;;

let repo_entry ?(slug = Some "jeong-sik/masc") id pulls : R.repository_entry =
  { repository_id = id; url = "https://github.com/" ^ id; slug; pulls }
;;

let read ~at pulls = R.Pulls_read { observed_at = at; pulls; undecodable = 0 }

let snapshot
      ?(reader = R.Reader_ready { keeper = "reader" })
      ?(keepers = R.Keepers_listed [ "code-reviewer"; "pr-updater" ])
      ?(error = None)
      repositories
  : R.snapshot
  =
  { reader; repositories_error = error; repositories; keepers; rejected_token = None }
;;

let request
      ?(repository = None)
      ?(selection = T.Needs_only)
      ?(mine = false)
      ?(limit = 20)
      ()
  : T.request
  =
  { repository; selection; mine; limit }
;;

let masc_pulls =
  [ pull ~checks:R.Checks_failing ~author:(Some "pr-updater") 101
  ; pull ~checks:R.Checks_failing ~author:(Some "code-reviewer") 102
  ; pull ~checks:R.Checks_failing ~author:(Some "stranger") 103
  ; pull ~review:R.Review_changes_requested 104
  ; pull ~mergeable:R.Conflicting 105
  ; pull ~author:(Some "code-reviewer") 106
  ; pull ~reviews:on_head 107
  ; pull ~draft:true 108
  ; pull ~checks:R.Checks_running 109
  ; pull ~reviews:cut_without_head 110
  ; pull ~mergeable:R.Mergeable_unknown 111
  ]
;;

let masc_snapshot = snapshot [ repo_entry "masc" (read ~at:1000. masc_pulls) ]

(* --- JSON reading --- *)

let member = Yojson.Safe.Util.member
let to_list = Yojson.Safe.Util.to_list
let to_int = Yojson.Safe.Util.to_int
let to_string = Yojson.Safe.Util.to_string

let entries data = data |> member "repositories" |> to_list
let first_entry data = List.hd (entries data)
let numbers_of entry = entry |> member "pulls" |> to_list |> List.map (fun row -> to_int (member "number" row))

let answered ?(caller = "code-reviewer") request snapshot =
  match T.answer ~now:1043. ~caller request snapshot with
  | Ok data -> data
  | Error _ -> Alcotest.fail "expected an answer"
;;

let refused ?(caller = "code-reviewer") request snapshot =
  match T.answer ~now:1043. ~caller request snapshot with
  | Error refusal -> refusal
  | Ok _ -> Alcotest.fail "expected a refusal"
;;

(* --- placement --- *)

let placement_cases =
  [ "draft beats failing checks", pull ~draft:true ~checks:R.Checks_failing 1, "draft"
  ; ( "failing checks beat changes requested"
    , pull ~checks:R.Checks_failing ~review:R.Review_changes_requested 2
    , "checks_failing" )
  ; ( "changes requested beat a conflict"
    , pull ~review:R.Review_changes_requested ~mergeable:R.Conflicting 3
    , "changes_requested" )
  ; ( "a conflict beats running checks"
    , pull ~checks:R.Checks_running ~mergeable:R.Conflicting 4
    , "conflicting" )
  ; "running checks are counted, not listed", pull ~checks:R.Checks_running 5, "checks_running"
  ; ( "unknown mergeability is not a conflict"
    , pull ~mergeable:R.Mergeable_unknown ~reviews:on_head 6
    , "reviewed_on_head" )
  ; "no review at all", pull 7, "unreviewed_on_head"
  ; ( "an approval of an older commit"
    , pull ~review:R.Review_approved ~reviews:on_older_commit 8
    , "unreviewed_on_head" )
  ; "a cut review list without the head", pull ~reviews:cut_without_head 9, "review_history_incomplete"
  ; "a review on the head", pull ~reviews:on_head 10, "reviewed_on_head"
  ; "no checks count like passing", pull ~checks:R.Checks_none ~reviews:on_head 11, "reviewed_on_head"
  ; "a cut list that holds the head", pull ~reviews:cut_with_head 12, "reviewed_on_head"
  ; "head commit not read", pull ~head_oid:None 13, "head_review_unknown"
  ; "review list not read", pull ~reviews:R.Reviews_not_read 14, "head_review_unknown"
  ; ( "a comment on the head while GitHub waits for an approval"
    , pull ~review:R.Review_waiting ~reviews:on_head 15
    , "awaiting_approval" )
  ; ( "a dismissed review on the head while GitHub waits for an approval"
    , pull ~review:R.Review_waiting ~reviews:dismissed_on_head 16
    , "awaiting_approval" )
  ; ( "an approved decision closes a reviewed head"
    , pull ~review:R.Review_approved ~reviews:on_head 17
    , "reviewed_on_head" )
  ; ( "waiting with no review on the head"
    , pull ~review:R.Review_waiting ~reviews:no_reviews 18
    , "unreviewed_on_head" )
  ; ( "waiting with a cut list that lacks the head"
    , pull ~review:R.Review_waiting ~reviews:cut_without_head 19
    , "review_history_incomplete" )
  ; ( "waiting with the review list not read"
    , pull ~review:R.Review_waiting ~reviews:R.Reviews_not_read 20
    , "head_review_unknown" )
  ; ( "a conflict beats awaiting approval"
    , pull ~review:R.Review_waiting ~mergeable:R.Conflicting ~reviews:on_head 21
    , "conflicting" )
  ; ( "running checks beat awaiting approval"
    , pull ~review:R.Review_waiting ~checks:R.Checks_running ~reviews:on_head 22
    , "checks_running" )
  ; ( "changes requested beat awaiting approval"
    , pull ~review:R.Review_changes_requested ~reviews:on_head 23
    , "changes_requested" )
  ]
;;

let test_placement_table () =
  List.iter
    (fun (label, pull, expected) ->
       check_string label expected (P.to_string (P.placement_of pull)))
    placement_cases
;;

let test_placements_are_ranked_in_table_order () =
  check_int "ten placements" 10 (List.length P.all);
  check_ints "rank is the position" (List.init 10 Fun.id) (List.map P.rank P.all);
  let names = List.map P.to_string P.all in
  check_int "names are distinct" 10 (List.length (List.sort_uniq String.compare names));
  check_strings
    "the first five are the ones that need work"
    [ "checks_failing"
    ; "changes_requested"
    ; "conflicting"
    ; "unreviewed_on_head"
    ; "awaiting_approval"
    ]
    (List.filteri (fun index _ -> index < 5) names)
;;

(* --- arguments --- *)

let selection_label = function
  | T.Needs_only -> "needs"
  | T.Every_placement -> "all"
  | T.Only placement -> P.to_string placement
;;

let test_defaults () =
  match T.request_of_args (`Assoc []) with
  | Error _ -> Alcotest.fail "no argument is valid"
  | Ok request ->
    Alcotest.(check (option string)) "repository" None request.repository;
    check_string "selection" "needs" (selection_label request.selection);
    check_bool "mine" false request.mine;
    check_int "limit" T.default_limit request.limit
;;

let test_explicit_arguments () =
  let args =
    `Assoc
      [ "repository", `String "jeong-sik/masc"
      ; "placement", `String "unreviewed_on_head"
      ; "mine", `Bool true
      ; "limit", `Int 5
      ]
  in
  match T.request_of_args args with
  | Error _ -> Alcotest.fail "valid arguments"
  | Ok request ->
    Alcotest.(check (option string)) "repository" (Some "jeong-sik/masc") request.repository;
    check_string "selection" "unreviewed_on_head" (selection_label request.selection);
    check_bool "mine" true request.mine;
    check_int "limit" 5 request.limit
;;

let field_names errors = List.map (fun (error : Tool_args.field_error) -> error.field) errors

let test_invalid_arguments () =
  let invalid args = match T.request_of_args args with Ok _ -> None | Error errors -> Some (field_names errors) in
  Alcotest.(check (option (list string)))
    "unknown placement"
    (Some [ "placement" ])
    (invalid (`Assoc [ "placement", `String "stale" ]));
  Alcotest.(check (option (list string)))
    "limit below the range"
    (Some [ "limit" ])
    (invalid (`Assoc [ "limit", `Int 0 ]));
  Alcotest.(check (option (list string)))
    "limit above the range"
    (Some [ "limit" ])
    (invalid (`Assoc [ "limit", `Int (T.max_limit + 1) ]));
  Alcotest.(check (option (list string)))
    "both wrong"
    (Some [ "placement"; "limit" ])
    (invalid (`Assoc [ "placement", `String ""; "limit", `Int 0 ]))
;;

let test_selection_names () =
  check_strings
    "needs, all, then every placement"
    ("needs" :: "all" :: List.map P.to_string P.all)
    T.selection_names
;;

(* --- the answer --- *)

let test_default_rows_are_the_ones_that_need_work () =
  let entry = first_entry (answered (request ()) masc_snapshot) in
  check_ints
    "placement, then the caller's own first, then number"
    [ 102; 101; 103; 104; 105; 106; 111 ]
    (numbers_of entry);
  check_int "matched" 7 (to_int (member "matched" entry));
  check_int "shown" 7 (to_int (member "shown" entry));
  check_int "open" 11 (to_int (member "open" entry));
  check_int "mergeable_unknown" 1 (to_int (member "mergeable_unknown" entry));
  check_int "age_sec" 43 (to_int (member "age_sec" entry))
;;

let test_counts_cover_every_placement () =
  let counts = first_entry (answered (request ()) masc_snapshot) |> member "counts" in
  let count name = to_int (member name counts) in
  check_strings "one count per placement" (List.map P.to_string P.all) (Yojson.Safe.Util.keys counts);
  check_int "checks_failing" 3 (count "checks_failing");
  check_int "changes_requested" 1 (count "changes_requested");
  check_int "conflicting" 1 (count "conflicting");
  check_int "unreviewed_on_head" 2 (count "unreviewed_on_head");
  check_int "draft" 1 (count "draft");
  check_int "checks_running" 1 (count "checks_running");
  check_int "reviewed_on_head" 1 (count "reviewed_on_head");
  check_int "review_history_incomplete" 1 (count "review_history_incomplete");
  check_int "head_review_unknown" 0 (count "head_review_unknown");
  check_int
    "the counts add up to the open pull requests"
    11
    (List.fold_left (fun sum placement -> sum + count (P.to_string placement)) 0 P.all)
;;

let test_selection_by_placement () =
  let rows selection = numbers_of (first_entry (answered (request ~selection ()) masc_snapshot)) in
  check_ints "one placement" [ 108 ] (rows (T.Only (P.Not_listed P.Draft)));
  check_ints
    "every placement keeps the table order"
    [ 102; 101; 103; 104; 105; 106; 111; 108; 109; 107; 110 ]
    (rows T.Every_placement)
;;

let test_mine_keeps_the_callers_pull_requests () =
  let numbers ~caller =
    numbers_of
      (first_entry
         (answered ~caller (request ~selection:T.Every_placement ~mine:true ()) masc_snapshot))
  in
  check_ints "code-reviewer" [ 102; 106 ] (numbers ~caller:"code-reviewer");
  check_ints "pr-updater" [ 101 ] (numbers ~caller:"pr-updater");
  check_ints "a Keeper with none" [] (numbers ~caller:"nobody")
;;

let test_limit_cuts_after_the_order () =
  let entry = first_entry (answered (request ~limit:3 ()) masc_snapshot) in
  check_ints "the first three" [ 102; 101; 103 ] (numbers_of entry);
  check_int "matched still counts them all" 7 (to_int (member "matched" entry));
  check_int "shown" 3 (to_int (member "shown" entry))
;;

let test_a_head_with_only_comments_stays_in_the_default_rows () =
  let pulls =
    [ pull ~review:R.Review_waiting ~reviews:on_head 1
    ; pull ~review:R.Review_approved ~reviews:on_head 2
    ; pull ~review:R.Review_none ~reviews:on_head 3
    ; pull ~review:R.Review_waiting ~reviews:no_reviews 4
    ]
  in
  let entry =
    first_entry (answered (request ()) (snapshot [ repo_entry "masc" (read ~at:1000. pulls) ]))
  in
  check_ints
    "not reviewed first, then the head that still waits for an approval"
    [ 4; 1 ]
    (numbers_of entry);
  let counts = member "counts" entry in
  check_int "awaiting_approval" 1 (to_int (member "awaiting_approval" counts));
  check_int "reviewed_on_head" 2 (to_int (member "reviewed_on_head" counts));
  (match entry |> member "pulls" |> to_list with
   | [ _; waiting ] ->
     check_string "placement" "awaiting_approval" (to_string (member "placement" waiting));
     check_string "review" "waiting" (to_string (member "review" waiting));
     check_string "head_review" "reviewed_on_head" (to_string (member "head_review" waiting))
   | other -> Alcotest.failf "expected two rows, got %d" (List.length other))
;;

let test_head_review_orders_within_a_placement () =
  let pulls =
    [ pull ~reviews:on_head ~review:R.Review_changes_requested 1
    ; pull ~reviews:cut_without_head ~review:R.Review_changes_requested 2
    ; pull ~reviews:no_reviews ~review:R.Review_changes_requested 3
    ; pull ~reviews:R.Reviews_not_read ~review:R.Review_changes_requested 4
    ]
  in
  let entry =
    first_entry (answered (request ()) (snapshot [ repo_entry "masc" (read ~at:1000. pulls) ]))
  in
  check_ints
    "not reviewed, history incomplete, reviewed, unknown"
    [ 3; 2; 1; 4 ]
    (numbers_of entry)
;;

let test_row_fields () =
  let pulls =
    [ pull
        ~title:(Some "a title")
        ~author:(Some "pr-updater")
        ~reviews:
          (reviews_of
             [ { reviewer = R.Actor_bot "a-bot"
               ; verdict = R.Verdict_approved
               ; commit_oid = Some "head-0"
               }
             ; { reviewer = R.Actor_user "a-user"
               ; verdict = R.Verdict_unrecognized "NEW_STATE"
               ; commit_oid = Some "head-1"
               }
             ])
        7
    ]
  in
  let row =
    first_entry (answered (request ~selection:T.Every_placement ()) (snapshot [ repo_entry "masc" (read ~at:1000. pulls) ]))
    |> member "pulls"
    |> to_list
    |> List.hd
  in
  check_string "placement" "reviewed_on_head" (to_string (member "placement" row));
  check_string "keeper" "pr-updater" (to_string (member "keeper" row));
  check_string "head_oid" "head-1" (to_string (member "head_oid" row));
  check_string "head_review" "reviewed_on_head" (to_string (member "head_review" row));
  let reviews = member "reviews" row in
  check_string "reviews state" "read" (to_string (member "state" reviews));
  (match to_list (member "latest" reviews) with
   | [ bot; user ] ->
     check_string "bot kind" "bot" (to_string (member "kind" (member "reviewer" bot)));
     check_string "bot verdict" "approved" (to_string (member "verdict" bot));
     check_bool "bot review is on an older commit" false (Yojson.Safe.Util.to_bool (member "on_head" bot));
     check_string "unrecognized verdict" "unrecognized" (to_string (member "verdict" user));
     check_string "raw verdict is kept" "NEW_STATE" (to_string (member "verdict_raw" user));
     check_bool "user review is on the head" true (Yojson.Safe.Util.to_bool (member "on_head" user));
     check_bool
       "no commit id is repeated"
       true
       (match user with
        | `Assoc fields -> not (List.mem_assoc "commit_oid" fields)
        | _ -> false)
   | other -> Alcotest.failf "expected two reviews, got %d" (List.length other))
;;

let test_title_is_cut_at_a_character_boundary () =
  let title_of title =
    let entry =
      first_entry
        (answered
           (request ~selection:T.Every_placement ())
           (snapshot [ repo_entry "masc" (read ~at:1000. [ pull ~title:(Some title) 1 ]) ]))
    in
    entry |> member "pulls" |> to_list |> List.hd |> member "title" |> to_string
  in
  check_string "a short title is unchanged" "short" (title_of "short");
  let ascii = title_of (String.make 200 'a') in
  check_int "ascii is cut at 120 bytes plus the marker" 123 (String.length ascii);
  let korean = title_of (String.concat "" (List.init 60 (fun _ -> "가"))) in
  check_bool "a multi-byte title stays valid UTF-8" true (String.is_valid_utf_8 korean);
  check_bool "and is cut" true (String.length korean < 180)
;;

let test_age_never_goes_negative () =
  let entry = first_entry (answered (request ()) (snapshot [ repo_entry "masc" (read ~at:2000. masc_pulls) ])) in
  check_int "an observation after now is 0 seconds old" 0 (to_int (member "age_sec" entry))
;;

(* --- what is refused --- *)

let failed = R.Pulls_failed { observed_at = 990.; failure = R.Token_rejected }

let two_repositories =
  snapshot
    [ repo_entry "masc" (read ~at:1000. masc_pulls)
    ; repo_entry ~slug:(Some "jeong-sik/other") "other" failed
    ]
;;

let test_a_failed_repository_is_shown_beside_a_read_one () =
  let data = answered (request ()) two_repositories in
  match entries data with
  | [ _; failed_entry ] ->
    check_string "state" "failed" (to_string (member "state" failed_entry));
    check_string "failure kind" "token_rejected" (to_string (member "kind" (member "failure" failed_entry)));
    check_int "age" 53 (to_int (member "age_sec" failed_entry))
  | other -> Alcotest.failf "expected two entries, got %d" (List.length other)
;;

let test_naming_a_failed_repository_fails () =
  match refused (request ~repository:(Some "jeong-sik/other") ()) two_repositories with
  | T.Nothing_read data ->
    check_string
      "the failure is in the payload"
      "failed"
      (to_string (member "state" (first_entry data)))
  | T.Unknown_repository _ | T.Keepers_unread -> Alcotest.fail "expected Nothing_read"
;;

let test_an_unknown_repository_lists_the_known_ones () =
  match refused (request ~repository:(Some "jeong-sik/nope") ()) two_repositories with
  | T.Unknown_repository { requested; registered } ->
    check_string "requested" "jeong-sik/nope" requested;
    check_strings "registered" [ "jeong-sik/masc"; "jeong-sik/other" ] registered
  | T.Nothing_read _ | T.Keepers_unread -> Alcotest.fail "expected Unknown_repository"
;;

let test_an_unready_reader_is_not_an_empty_list () =
  (match refused (request ()) (snapshot ~reader:R.Reader_not_declared []) with
   | T.Nothing_read data ->
     check_string
       "the reader state is in the payload"
       "not_declared"
       (to_string (member "state" (member "reader" data)))
   | T.Unknown_repository _ | T.Keepers_unread -> Alcotest.fail "expected Nothing_read");
  (match refused (request ()) (snapshot ~error:(Some "list unreadable") []) with
   | T.Nothing_read data ->
     check_string
       "the stored error is in the payload"
       "list unreadable"
       (to_string (member "repositories_error" data))
   | T.Unknown_repository _ | T.Keepers_unread -> Alcotest.fail "expected Nothing_read");
  (match refused (request ()) (snapshot [ repo_entry "masc" R.Pulls_not_read ]) with
   | T.Nothing_read _ -> ()
   | T.Unknown_repository _ | T.Keepers_unread -> Alcotest.fail "expected Nothing_read")
;;

let test_no_registered_repository_is_an_empty_answer () =
  let data = answered (request ()) (snapshot []) in
  check_int "no entries" 0 (List.length (entries data))
;;

let test_mine_needs_the_keeper_list () =
  let unlisted = snapshot ~keepers:R.Keepers_not_listed [ repo_entry "masc" (read ~at:1000. masc_pulls) ] in
  (match refused (request ~mine:true ()) unlisted with
   | T.Keepers_unread -> ()
   | T.Unknown_repository _ | T.Nothing_read _ -> Alcotest.fail "expected Keepers_unread");
  let data = answered (request ()) unlisted in
  check_bool "keepers_listed says the Keeper column is blank" false (Yojson.Safe.Util.to_bool (member "keepers_listed" data));
  let keepers =
    first_entry data |> member "pulls" |> to_list |> List.map (fun row -> member "keeper" row)
  in
  check_bool "no row names a Keeper" true (List.for_all (fun keeper -> keeper = `Null) keepers)
;;

(* --- the tool --- *)

let with_published snapshot body =
  R.publish snapshot;
  Fun.protect ~finally:(fun () -> R.publish R.initial) body
;;

let call ?(caller = "code-reviewer") args =
  T.handle
    ~tool_name:"keeper_pull_requests_list"
    ~start_time:(Tool_timing.start ())
    ~caller
    args
;;

let test_the_tool_reads_the_published_snapshot () =
  with_published masc_snapshot (fun () ->
    let result = call (`Assoc []) in
    check_bool "succeeds" true (Tool_result.is_success result);
    check_ints "rows" [ 102; 101; 103; 104; 105; 106; 111 ] (numbers_of (first_entry (Tool_result.data result))))
;;

let test_the_tool_fails_before_the_first_reading () =
  let result = call (`Assoc []) in
  check_bool "fails" false (Tool_result.is_success result);
  (match Tool_result.failure_class result with
   | Some Tool_result.Dependency_unavailable -> ()
   | Some _ | None -> Alcotest.fail "expected Dependency_unavailable")
;;

let test_the_tool_rejects_bad_arguments () =
  let result = call (`Assoc [ "placement", `String "stale" ]) in
  (match Tool_result.failure_class result with
   | Some Tool_result.Policy_rejection -> ()
   | Some _ | None -> Alcotest.fail "expected Policy_rejection")
;;

(* --- the definition against the code --- *)

let test_the_definition_matches_the_code () =
  let schema = Tool_schemas_misc_toml.pull_requests in
  let properties = member "properties" schema.Masc_domain.input_schema in
  check_string "name" "keeper_pull_requests_list" schema.Masc_domain.name;
  check_strings
    "parameters"
    [ "repository"; "placement"; "mine"; "limit" ]
    (Yojson.Safe.Util.keys properties);
  check_strings
    "placement enum is the code's selection names"
    T.selection_names
    (properties |> member "placement" |> member "enum" |> to_list |> List.map to_string);
  check_string "placement default" "needs" (to_string (member "default" (member "placement" properties)));
  let limit = member "limit" properties in
  check_int "limit minimum" 1 (to_int (member "minimum" limit));
  check_int "limit maximum" T.max_limit (to_int (member "maximum" limit));
  check_int "limit default" T.default_limit (to_int (member "default" limit));
  check_bool
    "other arguments are refused"
    false
    (Yojson.Safe.Util.to_bool (member "additionalProperties" schema.Masc_domain.input_schema))
;;

let test_the_operation_is_registered () =
  let name = "keeper_pull_requests_list" in
  (match Tool_schemas_misc.misc_operation_of_tool_name name with
   | Some operation ->
     check_string "wire name round trip" name (Tool_schemas_misc.misc_tool_name operation);
     (match Tool_schemas_misc.misc_registered_schema operation with
      | Some schema -> check_string "advertised schema" name schema.Masc_domain.name
      | None -> Alcotest.fail "the operation advertises no schema")
   | None -> Alcotest.fail "the wire name is not a misc operation")
;;

let () =
  Alcotest.run
    "tool_pull_requests"
    [ ( "placement"
      , [ Alcotest.test_case "the table" `Quick test_placement_table
        ; Alcotest.test_case "ranks follow the table" `Quick test_placements_are_ranked_in_table_order
        ] )
    ; ( "arguments"
      , [ Alcotest.test_case "defaults" `Quick test_defaults
        ; Alcotest.test_case "explicit" `Quick test_explicit_arguments
        ; Alcotest.test_case "invalid" `Quick test_invalid_arguments
        ; Alcotest.test_case "selection names" `Quick test_selection_names
        ] )
    ; ( "answer"
      , [ Alcotest.test_case "default rows" `Quick test_default_rows_are_the_ones_that_need_work
        ; Alcotest.test_case "counts" `Quick test_counts_cover_every_placement
        ; Alcotest.test_case "selection" `Quick test_selection_by_placement
        ; Alcotest.test_case "mine" `Quick test_mine_keeps_the_callers_pull_requests
        ; Alcotest.test_case "limit" `Quick test_limit_cuts_after_the_order
        ; Alcotest.test_case "comments only" `Quick test_a_head_with_only_comments_stays_in_the_default_rows
        ; Alcotest.test_case "head review order" `Quick test_head_review_orders_within_a_placement
        ; Alcotest.test_case "row fields" `Quick test_row_fields
        ; Alcotest.test_case "title" `Quick test_title_is_cut_at_a_character_boundary
        ; Alcotest.test_case "age" `Quick test_age_never_goes_negative
        ] )
    ; ( "refusals"
      , [ Alcotest.test_case "failed beside read" `Quick test_a_failed_repository_is_shown_beside_a_read_one
        ; Alcotest.test_case "failed named" `Quick test_naming_a_failed_repository_fails
        ; Alcotest.test_case "unknown repository" `Quick test_an_unknown_repository_lists_the_known_ones
        ; Alcotest.test_case "unready reader" `Quick test_an_unready_reader_is_not_an_empty_list
        ; Alcotest.test_case "nothing registered" `Quick test_no_registered_repository_is_an_empty_answer
        ; Alcotest.test_case "mine needs Keepers" `Quick test_mine_needs_the_keeper_list
        ] )
    ; ( "tool"
      , [ Alcotest.test_case "reads the snapshot" `Quick test_the_tool_reads_the_published_snapshot
        ; Alcotest.test_case "fails before a reading" `Quick test_the_tool_fails_before_the_first_reading
        ; Alcotest.test_case "bad arguments" `Quick test_the_tool_rejects_bad_arguments
        ] )
    ; ( "definition"
      , [ Alcotest.test_case "matches the code" `Quick test_the_definition_matches_the_code
        ; Alcotest.test_case "is registered" `Quick test_the_operation_is_registered
        ] )
    ]
;;
