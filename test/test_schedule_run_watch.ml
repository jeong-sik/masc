open Alcotest
open Masc
module Watch = Schedule_run_watch

(* --- Fixtures --- *)

let repo_exn raw =
  match Watch.repo_of_string raw with
  | Ok repo -> repo
  | Error detail -> fail detail
;;

let target ?attempt run_id =
  { Watch.repo = repo_exn "jeong-sik/masc"; run_id; run_attempt = attempt }
;;

let json_of raw = Yojson.Safe.from_string raw

(* Answers of GET /repos/jeong-sik/masc/actions/runs/{id}[/attempts/{n}] read on
   2026-11-05, cut to the fields a reader could use. *)
let completed_attempt =
  {|{"conclusion":"success","created_at":"2026-11-04T19:20:01Z","event":"pull_request","html_url":"https://github.com/jeong-sik/masc/actions/runs/41895911884","id":41895911884,"name":"PR type-check (dune build @check)","repository":{"full_name":"jeong-sik/masc"},"run_attempt":1,"run_number":852,"run_started_at":"2026-11-04T19:20:01Z","status":"completed","updated_at":"2026-11-04T19:29:25Z"}|}
;;

let in_progress_run =
  {|{"conclusion":null,"created_at":"2026-11-05T14:11:18Z","event":"pull_request","html_url":"https://github.com/jeong-sik/masc/actions/runs/42042570610","id":42042570610,"name":"PR type-check (dune build @check)","repository":{"full_name":"jeong-sik/masc"},"run_attempt":1,"run_number":1866,"run_started_at":"2026-11-05T14:11:18Z","status":"in_progress","updated_at":"2026-11-05T14:12:04Z"}|}
;;

(* The body GitHub sends for a run that does not exist. Its [status] is the
   string "404", so reading it as a run says "not finished". *)
let not_found_body =
  {|{"message":"Not Found","documentation_url":"https://docs.github.com/rest/actions/workflow-runs#get-a-workflow-run","status":"404"}|}
;;

let observation_to_string = function
  | Watch.Not_completed -> "not completed"
  | Watch.Completed None -> "completed, no conclusion"
  | Watch.Completed (Some conclusion) -> "completed " ^ Watch.conclusion_to_string conclusion
;;

let read_to_string = function
  | Ok observation -> observation_to_string observation
  | Error detail -> "error: " ^ detail
;;

let is_error = function
  | Ok _ -> false
  | Error _ -> true
;;

(* --- Repository and URL --- *)

let test_repo_names () =
  List.iter
    (fun raw -> check bool raw true (Result.is_ok (Watch.repo_of_string raw)))
    [ "jeong-sik/masc"; "a/b"; "a-b/c_d.e"; "Owner1/Repo.Name-2" ];
  List.iter
    (fun raw -> check bool raw true (is_error (Watch.repo_of_string raw)))
    [ ""
    ; "masc"
    ; "a/b/c"
    ; "/b"
    ; "a/"
    ; "a/.."
    ; "../b"
    ; "./b"
    ; "a/b c"
    ; "a/b?x=1"
    ; "a/b#frag"
    ; "a/b%2Fc"
    ; "a\\b/c"
    ; "ａ/b"
    ]
;;

let url_target raw =
  match Watch.target_of_run_url raw with
  | Ok target -> Watch.describe_target target
  | Error detail -> "error: " ^ detail
;;

let test_run_urls () =
  check
    string
    "run url"
    "jeong-sik/masc run 41895911884"
    (url_target "https://github.com/jeong-sik/masc/actions/runs/41895911884");
  check
    string
    "attempt url"
    "jeong-sik/masc run 41895911884 attempt 2"
    (url_target "https://github.com/jeong-sik/masc/actions/runs/41895911884/attempts/2");
  check
    string
    "trailing slash, query, fragment and padding"
    "jeong-sik/wkbl run 7"
    (url_target "  https://github.com/jeong-sik/wkbl/actions/runs/7/?pr=48805#summary \n");
  List.iter
    (fun raw ->
      let text = url_target raw in
      check bool raw true (String.starts_with ~prefix:"error: " text))
    [ ""
    ; "http://github.com/jeong-sik/masc/actions/runs/1"
    ; "https://github.com.evil.example/jeong-sik/masc/actions/runs/1"
    ; "https://gitlab.com/jeong-sik/masc/actions/runs/1"
    ; "https://github.com/jeong-sik/masc/actions/runs/0"
    ; "https://github.com/jeong-sik/masc/actions/runs/-3"
    ; "https://github.com/jeong-sik/masc/actions/runs/abc"
    ; "https://github.com/jeong-sik/masc/actions/runs/0x10"
    ; "https://github.com/jeong-sik/masc/actions/runs/1_000"
    ; "https://github.com/jeong-sik/masc/actions/runs/99999999999999999999999"
    ; "https://github.com/jeong-sik/masc/actions/runs/1/attempts/0"
    ; "https://github.com/jeong-sik/masc/actions/runs/1/attempts/x"
    ; "https://github.com/jeong-sik/masc/actions/runs/1/job/9"
    ; "https://github.com/jeong-sik/masc/pull/12"
    ; "https://github.com/jeong-sik/masc/actions/runs"
    ; "https://github.com/jeong-sik/actions/runs/1"
    ; "https://github.com/jeong-sik/../actions/runs/1"
    ; "https://github.com/jeong-sik/masc/actions/runs/1/../2"
    ]
;;

let test_url_round_trip () =
  let raw = "https://github.com/jeong-sik/masc/actions/runs/41895911884/attempts/2" in
  match Watch.target_of_run_url raw with
  | Error detail -> fail detail
  | Ok target -> check string "target_url" raw (Watch.target_url target)
;;

(* --- Payload field --- *)

let test_target_json () =
  let round t =
    match Watch.target_of_yojson (Watch.target_to_yojson t) with
    | Ok back -> Watch.target_url back
    | Error detail -> "error: " ^ detail
  in
  check string "latest attempt" (Watch.target_url (target 5)) (round (target 5));
  check string "attempt 3" (Watch.target_url (target ~attempt:3 5)) (round (target ~attempt:3 5));
  check
    string
    "latest attempt has no run_attempt field"
    {|{"repo":"jeong-sik/masc","run_id":5}|}
    (Yojson.Safe.to_string (Watch.target_to_yojson (target 5)));
  List.iter
    (fun raw ->
      check bool raw true (is_error (Watch.target_of_yojson (json_of raw))))
    [ {|{"repo":"jeong-sik/masc"}|}
    ; {|{"run_id":5}|}
    ; {|{"repo":"jeong-sik/masc","run_id":"5"}|}
    ; {|{"repo":"jeong-sik/masc","run_id":5.0}|}
    ; {|{"repo":"jeong-sik/masc","run_id":0}|}
    ; {|{"repo":"jeong-sik/masc","run_id":5,"run_attempt":0}|}
    ; {|{"repo":"jeong-sik/masc","run_id":5,"run_attempt":null}|}
    ; {|{"repo":"jeong-sik/masc","run_id":5,"url":"https://github.com"}|}
    ; {|{"repo":"jeong-sik/masc","repo":"jeong-sik/wkbl","run_id":5}|}
    ; {|{"repo":"jeong-sik","run_id":5}|}
    ; {|{"repo":5,"run_id":5}|}
    ; {|[]|}
    ; {|"https://github.com/jeong-sik/masc/actions/runs/5"|}
    ]
;;

(* --- What GitHub answers --- *)

let test_observation_fixtures () =
  check
    string
    "completed attempt"
    "completed success"
    (read_to_string
       (Watch.observation_of_run_json (target ~attempt:1 41895911884) (json_of completed_attempt)));
  check
    string
    "completed run without naming the attempt"
    "completed success"
    (read_to_string
       (Watch.observation_of_run_json (target 41895911884) (json_of completed_attempt)));
  check
    string
    "in progress"
    "not completed"
    (read_to_string (Watch.observation_of_run_json (target 42042570610) (json_of in_progress_run)))
;;

let test_observation_refuses_a_different_run () =
  check
    bool
    "another run id"
    true
    (is_error (Watch.observation_of_run_json (target 1) (json_of completed_attempt)));
  check
    bool
    "another attempt"
    true
    (is_error
       (Watch.observation_of_run_json (target ~attempt:2 41895911884) (json_of completed_attempt)));
  check
    bool
    "a 404 body is not a run that has not finished"
    true
    (is_error (Watch.observation_of_run_json (target 1) (json_of not_found_body)))
;;

let answer fields = `Assoc (("id", `Int 9) :: fields)

let test_observation_values () =
  let read fields = read_to_string (Watch.observation_of_run_json (target 9) (answer fields)) in
  check
    string
    "success"
    "completed success"
    (read [ "status", `String "completed"; "conclusion", `String "success" ]);
  List.iter
    (fun conclusion ->
      check
        string
        conclusion
        ("completed " ^ conclusion)
        (read [ "status", `String "completed"; "conclusion", `String conclusion ]))
    [ "failure"
    ; "cancelled"
    ; "skipped"
    ; "timed_out"
    ; "neutral"
    ; "action_required"
    ; "stale"
    ; "startup_failure"
    ; "something_new"
    ];
  check
    string
    "a conclusion nobody named stays as it came"
    "completed something_new"
    (read [ "status", `String "completed"; "conclusion", `String "something_new" ]);
  check
    string
    "null conclusion"
    "completed, no conclusion"
    (read [ "status", `String "completed"; "conclusion", `Null ]);
  check
    string
    "absent conclusion"
    "completed, no conclusion"
    (read [ "status", `String "completed" ]);
  List.iter
    (fun status ->
      check
        string
        status
        "not completed"
        (read [ "status", `String status; "conclusion", `Null ]))
    [ "queued"; "in_progress"; "waiting"; "requested"; "pending"; "something_new"; "" ];
  List.iter
    (fun (label, fields) ->
      check bool label true (is_error (Watch.observation_of_run_json (target 9) (answer fields))))
    [ "status absent", [ "conclusion", `Null ]
    ; "status null", [ "status", `Null ]
    ; "status a number", [ "status", `Int 404 ]
    ; "status a list", [ "status", `List [ `String "completed" ] ]
    ; "conclusion a number", [ "status", `String "completed"; "conclusion", `Int 1 ]
    ];
  check
    bool
    "an answer that is not an object"
    true
    (is_error (Watch.observation_of_run_json (target 9) (`List [])))
;;

let test_read_failure_permanence () =
  let permanent =
    [ Watch.Not_visible
    ; Watch.Token_rejected
    ; Watch.Forbidden
    ; Watch.Response_unreadable "not json"
    ; Watch.Reader_unavailable "no pr_reader declared"
    ; Watch.Http_status 301
    ; Watch.Http_status 400
    ; Watch.Http_status 409
    ; Watch.Http_status 422
    ; Watch.Http_status 499
    ]
  in
  let passing =
    [ Watch.Rate_limited { reset_at = Some 1.0 }
    ; Watch.Rate_limited { reset_at = None }
    ; Watch.Transport_failed "curl exit code 28"
    ; Watch.Reader_not_ready "the declaration is being written"
    ; Watch.Http_status 408
    ; Watch.Http_status 425
    ; Watch.Http_status 500
    ; Watch.Http_status 502
    ; Watch.Http_status 503
    ]
  in
  List.iter
    (fun failure ->
      check bool (Watch.read_failure_to_string failure) true (Watch.read_failure_is_permanent failure))
    permanent;
  List.iter
    (fun failure ->
      check
        bool
        (Watch.read_failure_to_string failure)
        false
        (Watch.read_failure_is_permanent failure))
    passing
;;

(* --- The wake text --- *)

(* A Keeper reads the first two lines: what became of the run, then the run's
   URL. Its own message follows an empty line, unchanged. The facts are
   compared; the sentences around them are not. *)
let test_wake_message () =
  let t = target ~attempt:2 41895911884 in
  List.iter
    (fun (label, settled, facts) ->
      match String.split_on_char '\n' (Watch.wake_message t settled ~original:"merge if green") with
      | [ headline; url; ""; original ] ->
        check bool (label ^ ": the marker leads") true
          (String.starts_with ~prefix:"[github_run_watch] " headline);
        List.iter
          (fun fact ->
            check
              bool
              (label ^ ": the headline has " ^ fact)
              true
              (String_util.contains_substring headline fact))
          (Watch.describe_target t :: facts);
        check string (label ^ ": the run URL") (Watch.target_url t) url;
        check string (label ^ ": the Keeper's message") "merge if green" original
      | lines ->
        failf
          "%s: expected the headline, the URL, an empty line and the message, got %d lines"
          label
          (List.length lines))
    [ "completed", Watch.Run_completed (Some Watch.Failure), [ "failure" ]
    ; "no conclusion", Watch.Run_completed None, []
    ; ( "unreadable"
      , Watch.Run_unreadable Watch.Not_visible
      , [ Watch.read_failure_to_string Watch.Not_visible ] )
    ]
;;

(* --- Payload --- *)

let keeper_wake ?(extra = []) ~message watch =
  let watch_fields =
    match watch with
    | None -> []
    | Some t -> [ Watch.watch_field, Watch.target_to_yojson t ]
  in
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc
          ([ "keeper_name", `String "k-1"; "message", `String message ] @ extra @ watch_fields) )
    ]
;;

let test_watch_of_payload () =
  (match Watch.watch_of_payload (keeper_wake ~message:"m" None) with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "a payload without a watch has none");
  (match Watch.watch_of_payload (keeper_wake ~message:"m" (Some (target 9))) with
   | Ok (Some found) -> check string "the watch" (Watch.target_url (target 9)) (Watch.target_url found)
   | Ok None | Error _ -> fail "the watch is read");
  let other_kind =
    `Assoc
      [ "kind", `String "masc.lane_act"
      ; "body", `Assoc [ Watch.watch_field, Watch.target_to_yojson (target 9) ]
      ]
  in
  (match Watch.watch_of_payload other_kind with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "only a Keeper wake carries a watch");
  let invalid =
    `Assoc
      [ "kind", `String Schedule_supported_kinds.keeper_wake
      ; ( "body"
        , `Assoc
            [ "keeper_name", `String "k-1"
            ; "message", `String "m"
            ; Watch.watch_field, `String "https://github.com/jeong-sik/masc/actions/runs/9"
            ] )
      ]
  in
  check bool "a watch that is not an object" true (is_error (Watch.watch_of_payload invalid))
;;

let test_settle_payload () =
  let extra = [ "title", `String "t"; "urgency", `String "low" ] in
  let payload = keeper_wake ~extra ~message:"merge if green" (Some (target 9)) in
  match Watch.settle_payload payload (target 9) (Watch.Run_completed (Some Watch.Success)) with
  | Error detail -> fail detail
  | Ok settled ->
    let expected =
      keeper_wake
        ~extra
        ~message:
          (Watch.wake_message
             (target 9)
             (Watch.Run_completed (Some Watch.Success))
             ~original:"merge if green")
        None
    in
    check
      string
      "the watch is gone, the message is prefixed and the rest is as it was"
      (Yojson.Safe.to_string expected)
      (Yojson.Safe.to_string settled);
    (match Watch.watch_of_payload settled with
     | Ok None -> ()
     | Ok (Some _) | Error _ -> fail "a settled payload carries no watch");
    check
      bool
      "no message"
      true
      (is_error
         (Watch.settle_payload
            (`Assoc
              [ "kind", `String Schedule_supported_kinds.keeper_wake
              ; "body", `Assoc [ "keeper_name", `String "k-1" ]
              ])
            (target 9)
            (Watch.Run_completed None)));
    check
      bool
      "not a Keeper wake"
      true
      (is_error
         (Watch.settle_payload
            (`Assoc [ "kind", `String "masc.lane_act"; "body", `Assoc [] ])
            (target 9)
            (Watch.Run_completed None)))
;;

let () =
  run
    "schedule_run_watch"
    [ ( "target"
      , [ test_case "repository names" `Quick test_repo_names
        ; test_case "run urls" `Quick test_run_urls
        ; test_case "url round trip" `Quick test_url_round_trip
        ; test_case "payload field json" `Quick test_target_json
        ] )
    ; ( "answer"
      , [ test_case "real answers" `Quick test_observation_fixtures
        ; test_case "another run is refused" `Quick test_observation_refuses_a_different_run
        ; test_case "status and conclusion" `Quick test_observation_values
        ; test_case "which failures can pass" `Quick test_read_failure_permanence
        ] )
    ; ( "payload"
      , [ test_case "wake message" `Quick test_wake_message
        ; test_case "watch of a payload" `Quick test_watch_of_payload
        ; test_case "settle a payload" `Quick test_settle_payload
        ] )
    ]
;;
